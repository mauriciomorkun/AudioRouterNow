"""
DeviceManager — Verwaltet Core Audio Output-Devices und Hot-plug-Erkennung.

Aufgaben:
  - Listet alle Output-faehigen Core Audio Devices auf
  - Filtert das eigene virtuelle "Audio Router" Device heraus
  - Erkennt neu angeschlossene oder entfernte Devices (Hot-plug)
  - Informiert Listener via Callback bei Device-Listen-Aenderungen
  - Laeuft Hot-plug-Polling in einem Daemon-Thread (alle 2 Sekunden)
"""

import threading
import logging
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional

import sounddevice as sd

logger = logging.getLogger(__name__)

# Name des eigenen virtuellen Devices — wird aus der Output-Liste herausgefiltert
VIRTUAL_DEVICE_NAME = "Audio Router"

# Polling-Intervall fuer Hot-plug-Erkennung (Sekunden)
HOTPLUG_POLL_INTERVAL = 2.0


@dataclass(frozen=True)
class AudioDevice:
    """Repraesentiert ein verfuegbares Core Audio Output-Device."""
    index: int
    name: str
    max_output_channels: int
    default_samplerate: float

    def __str__(self) -> str:
        return f"{self.name} ({self.max_output_channels}ch)"


class DeviceManager:
    """
    Verwaltet die Liste der verfuegbaren Output-Devices.

    Verwendung:
        manager = DeviceManager(on_devices_changed=mein_callback)
        manager.start()
        devices = manager.get_output_devices()
        manager.stop()
    """

    def __init__(
        self,
        on_devices_changed: Optional[Callable[[List[AudioDevice]], None]] = None,
    ):
        """
        Args:
            on_devices_changed: Callback, der aufgerufen wird wenn sich die
                                Device-Liste aendert. Uebergibt die neue Liste.
        """
        self._on_devices_changed = on_devices_changed
        self._lock = threading.Lock()
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._known_devices: Dict[int, AudioDevice] = {}  # index -> device

    def start(self):
        """Startet Hot-plug-Polling im Hintergrund-Thread."""
        with self._lock:
            if self._running:
                return
            self._running = True
            # Initialen Device-Scan durchfuehren
            self._scan_devices()
            # Polling-Thread starten
            self._thread = threading.Thread(
                target=self._poll_loop,
                name="audiorouter-device-manager",
                daemon=True,
            )
            self._thread.start()
            logger.info("DeviceManager gestartet")

    def stop(self):
        """Stoppt Hot-plug-Polling."""
        with self._lock:
            if not self._running:
                return
            self._running = False

        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=HOTPLUG_POLL_INTERVAL + 1.0)
        self._thread = None
        logger.info("DeviceManager gestoppt")

    def get_output_devices(self) -> List[AudioDevice]:
        """
        Gibt die aktuelle Liste aller verfuegbaren Output-Devices zurueck.

        Das eigene virtuelle "Audio Router" Device ist nicht enthalten.
        """
        with self._lock:
            return list(self._known_devices.values())

    def find_device_by_name(self, name: str) -> Optional[AudioDevice]:
        """
        Sucht ein Device anhand seines Namens (Substring-Suche, case-insensitiv).

        Returns:
            Das erste passende Device oder None.
        """
        with self._lock:
            name_lower = name.lower()
            for device in self._known_devices.values():
                if name_lower in device.name.lower():
                    return device
        return None

    def get_devices_by_names(self, names: List[str]) -> List[AudioDevice]:
        """
        Gibt alle Devices zurueck, deren Name einem der angegebenen Namen entspricht.

        Verwendet Substring-Suche (case-insensitiv). Gut geeignet um gespeicherte
        Device-Namen aus der Config wiederherzustellen.
        """
        result = []
        for name in names:
            device = self.find_device_by_name(name)
            if device is not None:
                result.append(device)
        return result

    def refresh(self) -> List[AudioDevice]:
        """
        Erzwingt einen sofortigen Device-Scan und gibt die neue Liste zurueck.
        Nuetzlich nach manuellen Konfigurations-Aenderungen.
        """
        with self._lock:
            self._scan_devices()
            return list(self._known_devices.values())

    # ------------------------------------------------------------------
    # Interne Methoden
    # ------------------------------------------------------------------

    def _query_output_devices(self) -> Dict[int, AudioDevice]:
        """
        Fragt sounddevice nach allen verfuegbaren Output-Devices.

        Filtert:
          - Devices ohne Output-Kanaele
          - Unser eigenes virtuelles "Audio Router" Device

        Returns:
            Dict von device_index -> AudioDevice
        """
        result: Dict[int, AudioDevice] = {}
        try:
            devices = sd.query_devices()
            for i, dev in enumerate(devices):
                # Nur Devices mit Output-Kanaelen
                if dev["max_output_channels"] <= 0:
                    continue
                # Eigenes virtuelles Device ausschliessen
                if VIRTUAL_DEVICE_NAME.lower() in dev["name"].lower():
                    continue
                result[i] = AudioDevice(
                    index=i,
                    name=dev["name"],
                    max_output_channels=int(dev["max_output_channels"]),
                    default_samplerate=float(dev["default_samplerate"]),
                )
        except Exception as e:
            logger.error(f"Fehler beim Abfragen der Audio-Devices: {e}")
        return result

    def _scan_devices(self):
        """
        Fuehrt einen Device-Scan durch und ermittelt Aenderungen.

        Muss unter self._lock aufgerufen werden.
        Ruft on_devices_changed auf wenn sich etwas geaendert hat.
        """
        new_devices = self._query_output_devices()

        # Vergleiche mit bekannten Devices
        old_keys = set(self._known_devices.keys())
        new_keys = set(new_devices.keys())

        added = new_keys - old_keys
        removed = old_keys - new_keys

        if added or removed:
            self._known_devices = new_devices
            device_list = list(new_devices.values())

            if added:
                names = [new_devices[i].name for i in added]
                logger.info(f"Neue Audio-Devices erkannt: {', '.join(names)}")
            if removed:
                names = [self._known_devices.get(i, AudioDevice(i, f"#{i}", 0, 0.0)).name
                         for i in removed]
                logger.info(f"Audio-Devices entfernt: {', '.join(names)}")

            # Callback auserhalb des Locks aufrufen
            if self._on_devices_changed:
                # Callback wird nach Lock-Freigabe aufgerufen (s. _poll_loop)
                return device_list
        else:
            # Keine Aenderung
            self._known_devices = new_devices

        return None

    def _poll_loop(self):
        """
        Polling-Thread: prueft alle HOTPLUG_POLL_INTERVAL Sekunden auf
        Aenderungen der Device-Liste.
        """
        import time

        while self._running:
            time.sleep(HOTPLUG_POLL_INTERVAL)
            if not self._running:
                break

            changed_list = None
            with self._lock:
                changed_list = self._scan_devices()

            # Callback ausserhalb des Locks aufrufen
            if changed_list is not None and self._on_devices_changed:
                try:
                    self._on_devices_changed(changed_list)
                except Exception as e:
                    logger.error(f"Fehler im on_devices_changed-Callback: {e}")
