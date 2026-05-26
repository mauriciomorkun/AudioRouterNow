"""
RoutingEngine — Verteilt PCM-Audio vom Unix Socket an Output-Devices.

Empfaengt numpy-Arrays von SocketReceiver und schreibt sie gleichzeitig
auf alle konfigurierten Output-Devices via sounddevice.OutputStream.

Multi-Output-Logik:
  - Pro physischem Device genau EIN OutputStream (CoreAudio erlaubt keine zwei
    parallelen Streams auf dasselbe Device).
  - Der Stream wird mit so vielen Kanaelen geoeffnet wie noetig, um alle
    ausgewaehlten Kanal-Paare abzudecken (z.B. Ch 1-2 + Ch 5-6 → 6 Kanaele).
  - Im Callback wird dasselbe Stereo-Signal in jeden ausgewaehlten Kanal-Paar-
    Bereich geschrieben (outdata[:, offset:offset+2] = stereo_frame).

Thread-Sicherheit:
  - start/stop/set_outputs sind thread-safe (Lock)
  - Frame-Daten werden ueber Queue an jeden OutputStream weitergeleitet
"""

import queue
import threading
import logging
import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional

import numpy as np
import sounddevice as sd

from audio_device_control import get_default_output_volume, get_default_output_muted

logger = logging.getLogger(__name__)

SAMPLE_RATE = 48000
BLOCK_SIZE = 512

# Maximale Puffer-Tiefe pro Output-Stream (Frames, nicht Bytes).
# 32 × 512 Frames / 48000 Hz ≈ 341 ms Buffer — fuer Musik-Wiedergabe
# (kein Live-Monitoring) absolut akzeptabel und glaettet kurze
# GIL-Pausen / Thread-Scheduling-Jitter aus.
QUEUE_DEPTH = 32


@dataclass
class OutputTarget:
    """Beschreibt ein konfiguriertes Output-Device mit einem Kanal-Paar."""
    device_index: int
    device_name: str
    channel_count: int       # Gesamtkanalzahl des physischen Devices
    channel_offset: int = 0  # Startkanal des gewuenschten Paares (0 = Ch 1-2, 2 = Ch 3-4, ...)


@dataclass
class _StreamState:
    """Interner Zustand eines aktiven Output-Streams (ein Stream pro physischem Device)."""
    device_index: int
    device_name: str                       # Name des physischen Devices (fuer Logging)
    stream: sd.OutputStream
    frame_queue: "queue.Queue[Optional[np.ndarray]]"
    offsets: List[int]                     # Aktive Kanal-Paar-Offsets fuer diesen Stream


class RoutingEngine:
    """
    Verteilt eingehende PCM-Frames auf mehrere Output-Devices.

    Pro physischem Device wird genau ein OutputStream geoeffnet.
    Mehrere Kanal-Paare desselben Devices werden in einem einzigen
    Multi-Channel-Stream bedient.

    Verwendung:
        engine = RoutingEngine(on_status=mein_callback)
        engine.set_outputs([
            OutputTarget(0, "Komplete Audio 6 Ch 1-2", 6, channel_offset=0),
            OutputTarget(0, "Komplete Audio 6 Ch 3-4", 6, channel_offset=2),
        ])
        engine.start()
        engine.stop()
    """

    def __init__(self, on_status: Optional[Callable[[bool, str], None]] = None):
        self._on_status = on_status
        self._lock = threading.Lock()
        self._running = False
        # Ein Stream pro physischem Device (device_index als Key)
        self._streams: Dict[int, _StreamState] = {}
        self._targets: List[OutputTarget] = []

        # Volume-Cache: CoreAudio-Abfrage ist teuer (pyobjc-Syscall, mehrere ms).
        # Sie darf NICHT im Audio-Hot-Path (on_frames) stattfinden — sonst
        # blockiert der SocketReceiver-Thread, der Unix-Socket-Buffer laeuft
        # voll, der Treiber droppt Frames → Glitches.
        # Loesung: separater Hintergrund-Thread (_volume_poll_thread)
        # aktualisiert die Cache-Werte alle 50 ms; on_frames liest sie nur.
        self._cached_volume: float = 1.0
        self._cached_muted: bool = False
        self._VOLUME_POLL_INTERVAL: float = 0.05   # 50 ms
        self._volume_thread: Optional[threading.Thread] = None

    # ------------------------------------------------------------------
    # Oeffentliche API
    # ------------------------------------------------------------------

    def set_outputs(self, targets: List[OutputTarget]):
        """
        Konfiguriert die Output-Devices.

        Kann auch waehrend des Betriebs aufgerufen werden: bestehende Streams
        werden gestoppt, neue mit aktueller Konfiguration gestartet.
        """
        with self._lock:
            self._targets = list(targets)
            if self._running:
                self._stop_all_streams_locked()
                self._start_all_streams_locked()

    def start(self) -> bool:
        """
        Startet alle konfigurierten Output-Streams.

        Returns:
            True wenn mindestens ein Stream erfolgreich gestartet wurde.
        """
        with self._lock:
            if self._running:
                return True
            self._running = True
            ok = self._start_all_streams_locked()
            if ok:
                # Volume-Polling-Thread starten — haelt die Cache-Werte
                # ausserhalb des Audio-Hot-Paths aktuell.
                self._volume_thread = threading.Thread(
                    target=self._volume_poll_loop,
                    name="audiorouter-volume-poll",
                    daemon=True,
                )
                self._volume_thread.start()
                logger.info("RoutingEngine gestartet")
                self._notify_status(True, "Routing aktiv")
            else:
                self._running = False
                self._notify_status(False, "Kein Output-Device verfuegbar")
            return ok

    def stop(self):
        """Stoppt alle aktiven Output-Streams."""
        with self._lock:
            if not self._running:
                return
            self._stop_all_streams_locked()
            self._running = False
            volume_thread = self._volume_thread
            self._volume_thread = None
        # Volume-Polling-Thread sauber beenden — _running ist bereits False,
        # also bricht die Schleife beim naechsten Tick ab.
        if volume_thread and volume_thread.is_alive():
            volume_thread.join(timeout=1.0)
        logger.info("RoutingEngine gestoppt")
        self._notify_status(False, "Routing gestoppt")

    def _volume_poll_loop(self):
        """
        Hintergrund-Thread: aktualisiert Volume- und Mute-Cache periodisch.

        Laeuft ausserhalb des Audio-Hot-Paths, damit teure pyobjc-Calls
        nach Core Audio den SocketReceiver-Thread nicht blockieren.
        """
        while self._running:
            try:
                self._cached_muted  = get_default_output_muted()
                self._cached_volume = get_default_output_volume()
            except Exception as e:
                # Bei Fehlern (z.B. waehrend Device-Wechsel) altes Cache
                # behalten und weitermachen — kein Audio-Stop.
                logger.debug(f"Volume-Poll Fehler (ignoriert): {e}")
            time.sleep(self._VOLUME_POLL_INTERVAL)

    def on_frames(self, frames: np.ndarray):
        """
        Empfaengt einen Frame-Block vom SocketReceiver und verteilt ihn.

        Wird aus dem SocketReceiver-Thread aufgerufen — darf nicht blockieren.
        Frames die nicht in die Queue passen werden verworfen (kein Backpressure).

        Args:
            frames: numpy-Array (BLOCK_SIZE, 2) Float32 — Stereo
        """
        if not self._running:
            return

        # Volume-Scaling via Cache — die teure CoreAudio-Abfrage laeuft
        # im separaten _volume_poll_loop, hier nur Read.
        if self._cached_muted or self._cached_volume <= 0.0:
            scaled = np.zeros_like(frames)
        elif self._cached_volume < 0.999:
            # Multiplikation mit einem np.float32-Skalar erzeugt nur
            # EIN temporaeres Float32-Array statt zwei (frames*float +
            # .astype). Spart Alloc/GC pro Frame.
            scaled = frames * np.float32(self._cached_volume)
        else:
            scaled = frames   # vol == 1.0 → keine Kopie nötig

        # Snapshot der aktiven Streams (kein Lock im Hot-Path)
        streams = list(self._streams.values())

        for state in streams:
            try:
                state.frame_queue.put_nowait(scaled)
            except queue.Full:
                # Puffer voll — Frame dieses Outputs verwerfen
                pass

    @property
    def is_running(self) -> bool:
        return self._running

    @property
    def active_output_names(self) -> List[str]:
        """Gibt die Namen der aktuell aktiven Output-Devices zurueck."""
        with self._lock:
            return [s.device_name for s in self._streams.values()]

    # ------------------------------------------------------------------
    # Interne Methoden (werden immer unter self._lock aufgerufen)
    # ------------------------------------------------------------------

    def _start_all_streams_locked(self) -> bool:
        """
        Startet einen OutputStream pro physischem Device.

        Targets mit demselben device_index werden zu einem einzigen
        Multi-Channel-Stream zusammengefasst.
        """
        # Targets nach device_index gruppieren
        device_groups: Dict[int, List[OutputTarget]] = defaultdict(list)
        for target in self._targets:
            device_groups[target.device_index].append(target)

        any_started = False
        for device_index, group in device_groups.items():
            if self._start_stream_for_device_locked(device_index, group):
                any_started = True
        return any_started

    def _start_stream_for_device_locked(
        self, device_index: int, targets: List[OutputTarget]
    ) -> bool:
        """
        Oeffnet einen einzigen OutputStream fuer ein physisches Device.

        Der Stream hat so viele Kanaele wie noetig, um alle ausgewaehlten
        Kanal-Paare abzudecken. Der Callback schreibt dasselbe Stereo-Signal
        in jeden ausgewaehlten Paar-Bereich.

        Returns:
            True bei Erfolg.
        """
        if device_index in self._streams:
            return True  # bereits aktiv

        offsets = sorted({t.channel_offset for t in targets})
        # Look up the clean device name via sounddevice instead of string-splitting
        try:
            device_name = sd.query_devices(device_index)["name"]
        except Exception:
            device_name = targets[0].device_name  # fallback

        # Minimale Kanalzahl: hoechster Offset + 2
        n_channels = max(o + 2 for o in offsets)

        frame_queue: "queue.Queue[Optional[np.ndarray]]" = queue.Queue(
            maxsize=QUEUE_DEPTH
        )

        # Offsets als lokale Kopie fuer den Closure
        active_offsets = list(offsets)

        def _callback(
            outdata: np.ndarray, frames: int, time_info, status: sd.CallbackFlags
        ):
            """sounddevice-Callback — laeuft auf einem internen RT-Thread."""
            if status:
                logger.debug(f"sounddevice Status [{device_name}]: {status}")

            try:
                raw = frame_queue.get_nowait()
            except queue.Empty:
                outdata.fill(0)
                return

            if raw is None:
                outdata.fill(0)
                raise sd.CallbackStop()

            # Dasselbe Stereo-Signal in alle aktiven Kanal-Paare schreiben
            outdata.fill(0)
            for offset in active_offsets:
                outdata[:, offset : offset + 2] = raw

        try:
            stream = sd.OutputStream(
                device=device_index,
                samplerate=SAMPLE_RATE,
                blocksize=BLOCK_SIZE,
                dtype="float32",
                channels=n_channels,
                callback=_callback,
                latency="low",
            )
            stream.start()

            self._streams[device_index] = _StreamState(
                device_index=device_index,
                device_name=device_name,
                stream=stream,
                frame_queue=frame_queue,
                offsets=offsets,
            )
            pairs_str = ", ".join(f"Ch {o+1}-{o+2}" for o in offsets)
            logger.info(
                f"Output-Stream gestartet: {device_name} "
                f"[{pairs_str}] ({n_channels}ch, Index {device_index})"
            )
            return True

        except Exception as e:
            logger.error(
                f"Output-Stream konnte nicht gestartet werden [{device_name}]: {e}"
            )
            return False

    def _stop_all_streams_locked(self):
        """Stoppt alle aktiven Output-Streams."""
        for idx in list(self._streams.keys()):
            self._stop_stream_locked(idx)

    def _stop_stream_locked(self, device_index: int):
        """Stoppt einen einzelnen Output-Stream."""
        state = self._streams.pop(device_index, None)
        if state is None:
            return

        try:
            state.frame_queue.put_nowait(None)
        except queue.Full:
            pass

        try:
            state.stream.stop(ignore_errors=True)
            state.stream.close(ignore_errors=True)
        except Exception as e:
            logger.warning(
                f"Fehler beim Stoppen von Stream [{state.device_name}]: {e}"
            )

        pairs_str = ", ".join(f"Ch {o+1}-{o+2}" for o in state.offsets)
        logger.info(f"Output-Stream gestoppt: {state.device_name} [{pairs_str}]")

    def _notify_status(self, is_running: bool, message: str):
        """Ruft den Status-Callback auf (falls vorhanden)."""
        if self._on_status:
            try:
                self._on_status(is_running, message)
            except Exception as e:
                logger.error(f"Fehler im Status-Callback: {e}")
