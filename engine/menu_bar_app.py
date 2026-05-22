"""
MenuBarApp — macOS Menu Bar Widget fuer AudioRouterNow.

Zeigt Status in der Menueleiste und erlaubt:
  - Routing starten / stoppen
  - Output-Devices waehlen (mehrere gleichzeitig moeglich)
  - System-Audio nativ auf "Audio Router" umschalten (kein externes Tool noetig)
  - Hot-plug: neue Devices werden automatisch im Menu angezeigt

Menu-Struktur:
  🎛️ AudioRouterNow
  ─────────────────────────
  Status: Aktiv / Gestoppt
  ─────────────────────────
  ▶ Routing starten / ⏹ stoppen
  ─────────────────────────
  System-Audio → Audio Router
  ─────────────────────────
  OUTPUT DEVICES:
    ☑ Komplete Audio 6 — 6ch
    ☐ MacBook Pro Lautsprecher — 2ch
    ...
  ─────────────────────────
  Beenden

Abhaengigkeiten: rumps, sounddevice, numpy
Keine externen Tools noetig — System-Audio-Umschaltung via nativen osascript/AppleScript.
"""

import logging
import sys
import webbrowser
from typing import Dict, List

import rumps

from audio_device_control import set_default_output_device
from config import AppConfig, load_config, save_config
from device_manager import AudioDevice, DeviceManager
from routing_engine import OutputTarget, RoutingEngine
from socket_receiver import SocketReceiver

logger = logging.getLogger(__name__)

# Name des virtuellen Audio-Devices (muss mit HAL-Treiber uebereinstimmen)
AUDIO_ROUTER_DEVICE_NAME = "Audio Router"

# Donation
DONATION_URL = "https://www.buymeacoffee.com/mauriciomorkun"
DONATION_HINT_DELAY = 15  # Sekunden nach erstem erfolgreichem Routing


class AudioRouterApp(rumps.App):
    """
    Haupt-Applikation: verbindet alle Komponenten und stellt das Menu bereit.
    """

    def __init__(self):
        super().__init__("🔇", quit_button=None)

        # Konfiguration laden
        self._config: AppConfig = load_config()

        # Aktive Output-Device-Namen (fuer Toggle-Logik)
        self._active_device_names: set = set(self._config.output_device_names)

        # Channel-Offsets pro Device (device_name -> channel_offset)
        self._device_offsets: Dict[str, int] = dict(self._config.output_device_offsets)

        # --- Komponenten ---
        self._routing_engine = RoutingEngine(on_status=self._on_routing_status)
        self._socket_receiver = SocketReceiver(on_frames=self._routing_engine.on_frames)
        self._device_manager = DeviceManager(on_devices_changed=self._on_devices_changed)

        # --- Menu-Items ---
        self._status_item = rumps.MenuItem("⚫ Gestoppt")
        self._status_item.set_callback(None)

        self._toggle_btn = rumps.MenuItem(
            "▶  Routing starten", callback=self._toggle_routing
        )

        self._switch_audio_btn = rumps.MenuItem(
            "System-Audio → Audio Router", callback=self._switch_system_audio
        )

        self._output_header = rumps.MenuItem("OUTPUT DEVICES:")
        self._output_header.set_callback(None)

        self._quit_btn = rumps.MenuItem("Beenden", callback=self._quit_app)

        # Donation-Menu-Items
        self._donation_btn = rumps.MenuItem(
            "☕  Support AudioRouterNow", callback=self._open_donation
        )
        self._donation_footer = rumps.MenuItem("Made with ♥ by Mauricio · free forever")
        self._donation_footer.set_callback(None)

        # Device-Menu-Items (werden dynamisch befuellt)
        self._device_menu_items: Dict[str, rumps.MenuItem] = {}

        # --- Thread-sichere Update-Flags ---
        # rumps.Timer funktioniert nur im Haupt-Thread.
        # Hintergrund-Threads (DeviceManager, RoutingEngine) setzen nur Flags —
        # ein einziger Haupt-Thread-Timer liest sie aus.
        self._pending_status: tuple | None = None
        self._device_update_pending: bool = False
        self._donation_hint_at: float | None = None  # timestamp wenn zu zeigen

        # Haupt-Thread UI-Update-Timer (alle 0.25s — liest pending Flags)
        self._ui_timer = rumps.Timer(self._process_pending_updates, 0.25)
        self._ui_timer.start()

        # Komponenten starten
        self._device_manager.start()   # Befüllt _known_devices via _scan_devices()
        self._socket_receiver.start()

        # Menu aufbauen + gespeicherte Devices wiederherstellen
        # (NACH start() — damit _known_devices bereits befüllt ist)
        self._restore_saved_outputs()

    # ------------------------------------------------------------------
    # Menu aufbauen
    # ------------------------------------------------------------------

    def _build_menu(self):
        """Baut das komplette Menu neu auf."""
        self.menu.clear()

        items = [
            self._status_item,
            None,  # Trennlinie
            self._toggle_btn,
            None,
            self._switch_audio_btn,
            None,
            self._output_header,
        ]

        # Aktuell bekannte Devices hinzufuegen
        devices = self._device_manager.get_output_devices()
        self._device_menu_items.clear()

        for device in sorted(devices, key=lambda d: d.name):
            item = self._make_device_menu_item(device)
            self._device_menu_items[device.name] = item
            items.append(item)

        if not devices:
            no_dev = rumps.MenuItem("  (keine Devices gefunden)")
            no_dev.set_callback(None)
            items.append(no_dev)

        items += [
            None,
            self._donation_btn,
            self._donation_footer,
            None,
            self._quit_btn,
        ]

        self.menu = items

    def _make_device_menu_item(self, device: AudioDevice) -> rumps.MenuItem:
        """Erstellt ein Menu-Item fuer ein Output-Device."""
        is_active = device.name in self._active_device_names

        if device.max_output_channels <= 2:
            # Simple 2-channel device: no submenu, behavior unchanged
            checkmark = "☑" if is_active else "☐"
            title = f"{checkmark}  {device.name} — {device.max_output_channels}ch"
            item = rumps.MenuItem(
                title,
                callback=lambda sender, d=device: self._toggle_device(sender, d),
            )
            return item

        # Multi-channel device: show active pair in title + submenu for pair selection
        current_offset = self._device_offsets.get(device.name, 0)
        checkmark = "☑" if is_active else "☐"
        title = (
            f"{checkmark}  {device.name} — "
            f"Ch {current_offset + 1}-{current_offset + 2}"
        )
        item = rumps.MenuItem(
            title,
            callback=lambda sender, d=device: self._toggle_device(sender, d),
        )

        # Build submenu: one entry per stereo pair
        num_pairs = device.max_output_channels // 2
        for pair_idx in range(num_pairs):
            offset = pair_idx * 2
            pair_label = f"Ch {offset + 1}-{offset + 2}"
            selected = (offset == current_offset) and is_active
            pair_mark = "☑" if selected else "☐"
            sub_item = rumps.MenuItem(
                f"{pair_mark}  {pair_label}",
                callback=lambda sender, d=device, o=offset: self._select_channel_pair(sender, d, o),
            )
            item[pair_label] = sub_item

        return item

    # ------------------------------------------------------------------
    # Callbacks
    # ------------------------------------------------------------------

    def _toggle_routing(self, sender):
        """Startet oder stoppt das Routing."""
        if self._routing_engine.is_running:
            self._routing_engine.stop()
            self._socket_receiver.stop()
        else:
            # Ausgaenge konfigurieren bevor gestartet wird
            self._apply_active_outputs()
            self._socket_receiver.start()
            # System-Audio automatisch auf "Audio Router" setzen
            set_default_output_device(AUDIO_ROUTER_DEVICE_NAME)
            success = self._routing_engine.start()
            if not success:
                rumps.alert(
                    title="AudioRouterNow — Kein Ausgabegeraet",
                    message=(
                        "Bitte zuerst ein Ausgabegeraet auswaehlen:\n\n"
                        "Klicke auf ein Geraet in der OUTPUT-DEVICES-Liste "
                        "um es mit ☑ zu markieren, dann 'Routing starten'."
                    ),
                )

    def _toggle_device(self, sender, device: AudioDevice):
        """Schaltet ein Output-Device an oder aus."""
        if device.name in self._active_device_names:
            self._active_device_names.discard(device.name)
        else:
            self._active_device_names.add(device.name)

        # Menu-Item aktualisieren
        is_active = device.name in self._active_device_names
        checkmark = "☑" if is_active else "☐"
        if device.max_output_channels <= 2:
            sender.title = f"{checkmark}  {device.name} — {device.max_output_channels}ch"
        else:
            current_offset = self._device_offsets.get(device.name, 0)
            sender.title = (
                f"{checkmark}  {device.name} — "
                f"Ch {current_offset + 1}-{current_offset + 2}"
            )

        # Engine neu konfigurieren
        self._apply_active_outputs()

        # Konfiguration speichern
        self._config.output_device_offsets = dict(self._device_offsets)
        self._config.output_device_names = list(self._active_device_names)
        save_config(self._config)

    def _select_channel_pair(self, sender, device: AudioDevice, offset: int):
        """Aktiviert ein Device und setzt das Kanal-Paar (channel_offset)."""
        # Activate device
        self._active_device_names.add(device.name)
        # Set channel offset
        self._device_offsets[device.name] = offset
        # Update config
        self._config.output_device_offsets = dict(self._device_offsets)
        self._config.output_device_names = list(self._active_device_names)
        save_config(self._config)
        # Rebuild menu to reflect changes
        self._build_menu()
        # Reconfigure routing
        self._apply_active_outputs()

    def _switch_system_audio(self, sender):
        """
        Setzt macOS System-Audio-Ausgang auf 'Audio Router' via CoreAudio API.
        Funktioniert auf allen macOS-Versionen ohne AppleScript oder externe Tools.
        """
        success, error_msg = set_default_output_device(AUDIO_ROUTER_DEVICE_NAME)

        if success:
            rumps.notification(
                title="AudioRouterNow",
                subtitle="",
                message="System-Audio wurde auf 'Audio Router' umgestellt.",
            )
        else:
            rumps.alert(
                title="Fehler beim Umschalten",
                message=(
                    f"System-Audio konnte nicht umgestellt werden:\n\n{error_msg}"
                ),
            )

    def _open_donation(self, sender):
        """Oeffnet die Buy Me a Coffee Seite im Browser."""
        webbrowser.open(DONATION_URL)

    def _quit_app(self, sender):
        """Stoppt alle Komponenten und beendet die Applikation."""
        self._ui_timer.stop()
        self._routing_engine.stop()
        self._socket_receiver.stop()
        self._device_manager.stop()
        save_config(self._config)
        rumps.quit_application()

    # ------------------------------------------------------------------
    # Status-Callbacks von Komponenten
    # ------------------------------------------------------------------

    def _on_routing_status(self, is_running: bool, message: str):
        """
        Wird vom RoutingEngine-Thread aufgerufen — setzt nur ein Flag.
        Der Haupt-Thread-Timer (_ui_timer) verarbeitet es thread-sicher.
        """
        import time
        self._pending_status = (is_running, message)

        # Donation-Hint: Timestamp merken, Haupt-Thread zeigt es spaeter
        if is_running and not self._config.donation_hint_shown:
            self._config.donation_hint_shown = True
            save_config(self._config)
            self._donation_hint_at = time.monotonic() + DONATION_HINT_DELAY

    def _on_devices_changed(self, new_devices: list):
        """
        Wird vom DeviceManager-Thread aufgerufen — setzt nur ein Flag.
        Der Haupt-Thread-Timer (_ui_timer) baut das Menu neu auf.
        """
        self._device_update_pending = True

    def _process_pending_updates(self, timer):
        """
        Laeuft alle 0.25s im Haupt-Thread (MacOS Main RunLoop).
        Verarbeitet alle pending Updates von Hintergrund-Threads thread-sicher.
        """
        import time

        # Device-Liste aktualisieren
        if self._device_update_pending:
            self._device_update_pending = False
            self._build_menu()

        # Routing-Status aktualisieren
        status = self._pending_status
        if status is not None:
            self._pending_status = None
            is_running, _ = status
            if is_running:
                self.title = "🎛️"
                self._toggle_btn.title = "⏹  Routing stoppen"
                self._status_item.title = "🟢 Aktiv"
            else:
                self.title = "🔇"
                self._toggle_btn.title = "▶  Routing starten"
                self._status_item.title = "⚫ Gestoppt"

        # Donation-Hint anzeigen (einmalig, nach Delay)
        hint_at = self._donation_hint_at
        if hint_at is not None and time.monotonic() >= hint_at:
            self._donation_hint_at = None
            rumps.notification(
                title="AudioRouterNow is working 🎛️",
                subtitle="",
                message=(
                    "Hi, I'm Mauricio — I built this on my own. "
                    "It's free and always will be. "
                    "If it saves you time, you can support via ☕ in the menu."
                ),
            )

    # ------------------------------------------------------------------
    # Interne Hilfsmethoden
    # ------------------------------------------------------------------

    def _apply_active_outputs(self):
        """
        Konfiguriert die RoutingEngine anhand der aktiven Device-Namen.
        Loest Device-Namen zu aktuellen Indizes auf.
        """
        devices = self._device_manager.get_output_devices()
        targets: List[OutputTarget] = []

        for device in devices:
            if device.name in self._active_device_names:
                targets.append(
                    OutputTarget(
                        device_index=device.index,
                        device_name=device.name,
                        channel_count=device.max_output_channels,
                        channel_offset=self._device_offsets.get(device.name, 0),
                    )
                )

        self._routing_engine.set_outputs(targets)

        if targets:
            names = ", ".join(t.device_name for t in targets)
            logger.info(f"Aktive Outputs: {names}")
        else:
            logger.info("Keine Outputs konfiguriert")

    def _restore_saved_outputs(self):
        """
        Stellt gespeicherte Output-Devices beim Start wieder her.
        Sucht Devices anhand des gespeicherten Namens (Substring-Matching).
        Baut das Menu immer neu auf — auch auf Fresh Install ohne gespeicherte Devices.
        """
        if self._config.output_device_names:
            restored = self._device_manager.get_devices_by_names(
                self._config.output_device_names
            )
            # Aktive Devices auf die gefundenen setzen
            self._active_device_names = {d.name for d in restored}
            # Channel-Offsets wiederherstellen
            self._device_offsets = dict(self._config.output_device_offsets)

            if restored:
                names = ", ".join(d.name for d in restored)
                logger.info(f"Output-Devices aus Konfiguration wiederhergestellt: {names}")

        # Menu immer aufbauen (zeigt alle bekannten Devices, auch ohne gespeicherte Auswahl)
        self._build_menu()


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    )

    # Erster Start: HAL-Treiber pruefen und ggf. installieren
    from first_launch import check_and_install
    if not check_and_install():
        sys.exit(1)

    app = AudioRouterApp()
    app.run()


if __name__ == "__main__":
    main()
