"""
RoutingEngine — Verteilt PCM-Audio vom Unix Socket an Output-Devices.

Empfaengt numpy-Arrays von SocketReceiver und schreibt sie gleichzeitig
auf alle konfigurierten Output-Devices via sounddevice.OutputStream.

Multi-Output-Logik:
  - Pro Output-Device ein eigener OutputStream
  - Derselbe Frame-Buffer wird zu jedem Output geschrieben
  - Channel-Duplikation: bei >2 Ausgaenge wird L/R auf alle Kanal-Paare
    dupliziert (Out1=L, Out2=R, Out3=L, Out4=R, ...)

Thread-Sicherheit:
  - start/stop/reconfigure sind thread-safe (Lock)
  - Frame-Daten werden ueber Queue an jeden OutputStream weitergeleitet
"""

import queue
import threading
import logging
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple

import numpy as np
import sounddevice as sd

logger = logging.getLogger(__name__)

SAMPLE_RATE = 48000
BLOCK_SIZE = 512

# Maximale Puffer-Tiefe pro Output-Stream (Frames, nicht Bytes)
# Mehr Puffer = mehr Latenz, aber weniger Dropouts
QUEUE_DEPTH = 8


@dataclass
class OutputTarget:
    """Beschreibt ein konfiguriertes Output-Device."""
    device_index: int
    device_name: str
    channel_count: int
    channel_offset: int = 0


@dataclass
class _StreamState:
    """Interner Zustand eines aktiven Output-Streams."""
    target: OutputTarget
    stream: sd.OutputStream
    frame_queue: "queue.Queue[Optional[np.ndarray]]"


def _build_output_frame(
    input_frames: np.ndarray,
    output_channels: int,
) -> np.ndarray:
    """
    Passt einen Stereo-Eingangsframe an die Kanalzahl des Ausgangs an.

    Bei 2 Ausgaengen: direkte Kopie.
    Bei mehr Ausgaengen: L/R auf alle Kanal-Paare duplizieren.
    Bei 1 Ausgang: Mono-Mix aus L+R.

    Args:
        input_frames: numpy-Array (N, 2) Float32
        output_channels: Ziel-Kanalzahl des Output-Devices

    Returns:
        numpy-Array (N, output_channels) Float32
    """
    n_frames = input_frames.shape[0]

    if output_channels == 2:
        return input_frames.copy()

    if output_channels == 1:
        # Mono-Downmix
        out = np.mean(input_frames, axis=1, keepdims=True).astype(np.float32)
        return out

    # Mehr als 2 Kanaele: L/R-Muster wiederholen
    out = np.zeros((n_frames, output_channels), dtype=np.float32)
    for i in range(output_channels):
        # Gerade Indizes (0, 2, 4, ...) -> Links, ungerade -> Rechts
        out[:, i] = input_frames[:, i % 2]
    return out


class RoutingEngine:
    """
    Verteilt eingehende PCM-Frames auf mehrere Output-Devices.

    Verwendung:
        engine = RoutingEngine(on_status=mein_callback)
        engine.set_outputs([OutputTarget(0, "Komplete Audio 6", 6)])
        engine.start()
        # ... engine.on_frames(frames) wird intern von SocketReceiver aufgerufen
        engine.stop()
    """

    def __init__(self, on_status: Optional[Callable[[bool, str], None]] = None):
        """
        Args:
            on_status: Optionaler Callback bei Status-Aenderungen.
                       Signatur: on_status(is_running: bool, message: str)
        """
        self._on_status = on_status
        self._lock = threading.Lock()
        self._running = False
        self._streams: Dict[int, _StreamState] = {}  # device_index -> StreamState
        self._targets: List[OutputTarget] = []

    # ------------------------------------------------------------------
    # Oeffentliche API
    # ------------------------------------------------------------------

    def set_outputs(self, targets: List[OutputTarget]):
        """
        Konfiguriert die Output-Devices.

        Kann auch waehrend des Betriebs aufgerufen werden: bestehende Streams
        werden gestoppt, neue gestartet.
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
        logger.info("RoutingEngine gestoppt")
        self._notify_status(False, "Routing gestoppt")

    def on_frames(self, frames: np.ndarray):
        """
        Empfaengt einen Frame-Block vom SocketReceiver und verteilt ihn.

        Wird aus dem SocketReceiver-Thread aufgerufen — darf nicht blockieren.
        Frames die nicht in die Queue passen werden verworfen (kein Backpressure).

        Args:
            frames: numpy-Array (512, 2) Float32
        """
        if not self._running:
            return

        # Snapshot der aktiven Streams (kein Lock im Hot-Path)
        streams = list(self._streams.values())

        for state in streams:
            try:
                state.frame_queue.put_nowait(frames)
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
            return [s.target.device_name for s in self._streams.values()]

    # ------------------------------------------------------------------
    # Interne Methoden (werden immer unter self._lock aufgerufen)
    # ------------------------------------------------------------------

    def _start_all_streams_locked(self) -> bool:
        """Startet einen OutputStream pro konfiguriertem Target."""
        any_started = False
        for target in self._targets:
            if self._start_stream_locked(target):
                any_started = True
        return any_started

    def _start_stream_locked(self, target: OutputTarget) -> bool:
        """
        Startet einen einzelnen OutputStream.

        Returns:
            True bei Erfolg.
        """
        if target.device_index in self._streams:
            return True  # bereits aktiv

        frame_queue: "queue.Queue[Optional[np.ndarray]]" = queue.Queue(
            maxsize=QUEUE_DEPTH
        )

        def _callback(outdata: np.ndarray, frames: int,
                      time_info, status: sd.CallbackFlags):
            """sounddevice-Callback — laeuft auf einem internen RT-Thread."""
            if status:
                logger.debug(f"sounddevice Status [{target.device_name}]: {status}")

            try:
                raw = frame_queue.get_nowait()
            except queue.Empty:
                # Kein Frame verfuegbar — Stille ausgeben
                outdata.fill(0)
                return

            if raw is None:
                # Sentinel — Stream soll enden
                outdata.fill(0)
                raise sd.CallbackStop()

            # Channel-Anpassung
            output_channels = outdata.shape[1]
            adapted = _build_output_frame(raw, output_channels)
            np.copyto(outdata, adapted, casting="unsafe")

        try:
            # Always open a 2-channel stream; use channel_selectors to pick
            # the correct pair when the device has more than 2 channels.
            stream_kwargs: dict = dict(
                device=target.device_index,
                samplerate=SAMPLE_RATE,
                blocksize=BLOCK_SIZE,
                dtype="float32",
                channels=2,
                callback=_callback,
                latency="low",
            )
            if target.channel_offset > 0:
                stream_kwargs["channel_selectors"] = [
                    target.channel_offset,
                    target.channel_offset + 1,
                ]
            stream = sd.OutputStream(**stream_kwargs)
            stream.start()
            self._streams[target.device_index] = _StreamState(
                target=target,
                stream=stream,
                frame_queue=frame_queue,
            )
            logger.info(
                f"Output-Stream gestartet: {target.device_name} "
                f"(2ch @ offset {target.channel_offset}, Index {target.device_index})"
            )
            return True
        except Exception as e:
            logger.error(
                f"Output-Stream konnte nicht gestartet werden "
                f"[{target.device_name}]: {e}"
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

        # Sentinel in Queue legen damit der Callback sauber endet
        try:
            state.frame_queue.put_nowait(None)
        except queue.Full:
            pass

        try:
            state.stream.stop(ignore_errors=True)
            state.stream.close(ignore_errors=True)
        except Exception as e:
            logger.warning(f"Fehler beim Stoppen von Stream [{state.target.device_name}]: {e}")

        logger.info(f"Output-Stream gestoppt: {state.target.device_name}")

    def _notify_status(self, is_running: bool, message: str):
        """Ruft den Status-Callback auf (falls vorhanden)."""
        if self._on_status:
            try:
                self._on_status(is_running, message)
            except Exception as e:
                logger.error(f"Fehler im Status-Callback: {e}")
