"""
MenuBarApp — macOS menu bar widget for AudioRouterNow.

Phase 3+4+5: Steuert den nativen C-Helper über den Config-Socket.
Keine Python-Audio-Dependencies mehr (kein sounddevice, kein numpy).

Menu structure:
  AudioRouterNow
  ─────────────────────────
  Status: Active / Stopped
  ─────────────────────────
  System Audio → Audio Router
  ─────────────────────────
  OUTPUT DEVICES:
    [x] Komplete Audio 6 — Ch 1-2, Ch 5-6
    [ ] MacBook Pro Speakers — 2ch
    ...
  ─────────────────────────
  Quit
"""

import fcntl
import logging
import os
import sys
import time
import webbrowser
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Dict, List

import rumps

from audio_device_control import set_default_output_device
from config import AppConfig, load_config, save_config
from device_manager import AudioDevice, DeviceManager
from helper_client import HelperClient, OutputSpec

logger = logging.getLogger(__name__)

# Name des virtuellen Devices (muss mit HAL-Treiber uebereinstimmen)
AUDIO_ROUTER_DEVICE_NAME = "Audio Router"

# Donation
DONATION_URL = "https://www.buymeacoffee.com/mauriciomorkun"
DONATION_HINT_DELAY = 15

# Single-instance lock
_LOCK_DIR = Path.home() / ".audiorouter"
_LOCK_FILE = _LOCK_DIR / "audiorouter.lock"
_lock_fd = None


class AudioRouterApp(rumps.App):
    """Hauptanwendung — Menu-Bar UI, steuert den Helper über Socket."""

    def __init__(self):
        super().__init__("🔇", quit_button=None)

        # Konfiguration laden
        self._config: AppConfig = load_config()

        # Aktive Device-Namen + ChannelOffsets (aus Config)
        self._active_device_names: set = set(self._config.output_device_names)
        self._device_offsets: Dict[str, List[int]] = {
            k: list(v) for k, v in self._config.output_device_offsets.items()
        }

        # Komponenten
        self._helper = HelperClient()
        self._device_manager = DeviceManager(on_devices_changed=self._on_devices_changed)

        # Menu-Items
        self._status_item = rumps.MenuItem("Stopped")
        self._status_item.set_callback(None)

        self._switch_audio_btn = rumps.MenuItem(
            "System Audio → Audio Router", callback=self._switch_system_audio
        )

        self._output_header = rumps.MenuItem("OUTPUT DEVICES:")
        self._output_header.set_callback(None)

        self._quit_btn = rumps.MenuItem("Quit", callback=self._quit_app)
        self._donation_btn = rumps.MenuItem(
            "Support AudioRouterNow", callback=self._open_donation
        )
        self._donation_footer = rumps.MenuItem("Made with love by Mauricio — free forever")
        self._donation_footer.set_callback(None)

        self._device_menu_items: Dict[str, rumps.MenuItem] = {}

        # Thread-safe Update-Flags
        self._device_update_pending: bool = False
        self._donation_hint_at: float | None = None
        self._helper_alive: bool = False

        # Main-thread UI-Timer
        self._ui_timer = rumps.Timer(self._process_pending_updates, 0.5)
        self._ui_timer.start()

        # Komponenten starten
        self._device_manager.start()

        # Helper starten (falls noch nicht via launchd aktiv)
        helper_ok = self._helper.ensure_running()
        if not helper_ok:
            logger.error("Helper konnte nicht gestartet werden")
            rumps.alert(
                title="AudioRouterNow — Helper Error",
                message=(
                    "The audio routing helper could not be started.\n\n"
                    "Please reinstall AudioRouterNow."
                ),
            )

        # Menu aufbauen + Outputs wiederherstellen
        self._restore_saved_outputs()
        self._auto_start_if_configured()

    # ------------------------------------------------------------------
    # Menu building
    # ------------------------------------------------------------------

    def _build_menu(self):
        self.menu.clear()

        items = [
            self._status_item,
            None,
            self._switch_audio_btn,
            None,
            self._output_header,
        ]

        devices = self._device_manager.get_output_devices()
        self._device_menu_items.clear()

        for device in sorted(devices, key=lambda d: d.name):
            item = self._make_device_menu_item(device)
            self._device_menu_items[device.name] = item
            items.append(item)

        if not devices:
            no_dev = rumps.MenuItem("  (no devices found)")
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
        is_active = device.name in self._active_device_names

        if device.max_output_channels <= 2:
            checkmark = "[x]" if is_active else "[ ]"
            title = f"{checkmark}  {device.name} — {device.max_output_channels}ch"
            item = rumps.MenuItem(
                title,
                callback=lambda sender, d=device: self._toggle_device(sender, d),
            )
            return item

        # Multi-channel: Submenu für Channel-Paare
        active_offsets = self._device_offsets.get(device.name, [])
        checkmark = "[x]" if is_active and active_offsets else "[ ]"

        if is_active and active_offsets:
            pairs_str = ", ".join(f"Ch {o + 1}-{o + 2}" for o in sorted(active_offsets))
            title = f"{checkmark}  {device.name} — {pairs_str}"
        else:
            title = f"{checkmark}  {device.name} — {device.max_output_channels}ch"

        item = rumps.MenuItem(
            title,
            callback=lambda sender, d=device: self._toggle_device(sender, d),
        )

        num_pairs = device.max_output_channels // 2
        for pair_idx in range(num_pairs):
            offset = pair_idx * 2
            pair_label = f"Ch {offset + 1}-{offset + 2}"
            selected = (offset in active_offsets) and is_active
            pair_mark = "[x]" if selected else "[ ]"
            sub_item = rumps.MenuItem(
                f"{pair_mark}  {pair_label}",
                callback=lambda sender, d=device, o=offset: self._toggle_channel_pair(sender, d, o),
            )
            item[pair_label] = sub_item

        return item

    # ------------------------------------------------------------------
    # Callbacks
    # ------------------------------------------------------------------

    def _toggle_device(self, sender, device: AudioDevice):
        if device.name in self._active_device_names:
            self._active_device_names.discard(device.name)
            self._device_offsets.pop(device.name, None)
        else:
            self._active_device_names.add(device.name)
            if device.max_output_channels > 2:
                self._device_offsets[device.name] = [0]

        self._save_and_apply()
        self._build_menu()

    def _toggle_channel_pair(self, sender, device: AudioDevice, offset: int):
        offsets = self._device_offsets.get(device.name, [])
        if offset in offsets:
            offsets = [o for o in offsets if o != offset]
        else:
            offsets = sorted(offsets + [offset])

        if offsets:
            self._device_offsets[device.name] = offsets
            self._active_device_names.add(device.name)
        else:
            self._device_offsets.pop(device.name, None)
            self._active_device_names.discard(device.name)

        self._save_and_apply()
        self._build_menu()

    def _switch_system_audio(self, sender):
        success, error_msg = set_default_output_device(AUDIO_ROUTER_DEVICE_NAME)
        if success:
            rumps.notification(
                title="AudioRouterNow", subtitle="",
                message="System audio switched to 'Audio Router'.",
            )
        else:
            rumps.alert(
                title="AudioRouterNow — Switch Failed",
                message=f"Could not switch system audio:\n\n{error_msg}",
            )

    def _open_donation(self, sender):
        webbrowser.open(DONATION_URL)

    def _quit_app(self, sender):
        self._ui_timer.stop()
        self._device_manager.stop()
        # Helper NUR herunterfahren wenn wir ihn selbst gestartet haben.
        # Bei launchd-Verwaltung: Helper läuft weiter und wird neu gestartet.
        # → shutdown() ist sicher, wir machen es nicht (Helper laeuft als Daemon weiter).
        # Optionaler Aufruf hier könnte launchd zu Re-spawn triggern.
        save_config(self._config)
        rumps.quit_application()

    # ------------------------------------------------------------------
    # Background-callbacks
    # ------------------------------------------------------------------

    def _on_devices_changed(self, new_devices: list):
        self._device_update_pending = True

    def _process_pending_updates(self, timer):
        # Device-Liste aktualisieren
        if self._device_update_pending:
            self._device_update_pending = False
            self._build_menu()

        # Status-Update via Helper-Ping
        alive_now = self._helper.ping()
        if alive_now != self._helper_alive:
            self._helper_alive = alive_now
            self._update_status_ui()

        # Donation-Hint einmalig nach Verzögerung
        hint_at = self._donation_hint_at
        if hint_at is not None and time.monotonic() >= hint_at:
            self._donation_hint_at = None
            rumps.notification(
                title="AudioRouterNow is working",
                subtitle="",
                message=(
                    "Hi, I'm Mauricio — I built this on my own. "
                    "It's free and always will be. "
                    "If it saves you time, support via the menu."
                ),
            )

    def _update_status_ui(self):
        # Status reflektiert: Helper läuft UND mind. ein Output ist aktiv
        outputs_active = bool(self._active_device_names)
        if self._helper_alive and outputs_active:
            self.title = "ARN"
            self._status_item.title = "Active"
        elif self._helper_alive:
            self.title = "arn"
            self._status_item.title = "Helper running — no outputs"
        else:
            self.title = "off"
            self._status_item.title = "Helper offline"

    # ------------------------------------------------------------------
    # Helper-Integration
    # ------------------------------------------------------------------

    def _apply_active_outputs(self):
        """
        Sendet die aktuelle Output-Konfiguration an den Helper.
        """
        devices = self._device_manager.get_output_devices()
        # Name → UID Lookup
        name_to_uid = {d.name: d.uid for d in devices}

        specs: List[OutputSpec] = []
        for dev_name in self._active_device_names:
            uid = name_to_uid.get(dev_name)
            if not uid:
                logger.debug(f"Device '{dev_name}' nicht im aktuellen Scan — ueberspringe")
                continue

            dev = next((d for d in devices if d.uid == uid), None)
            if dev is None:
                continue

            if dev.max_output_channels <= 2:
                specs.append(OutputSpec(uid=uid, ch_offset=0))
            else:
                offsets = self._device_offsets.get(dev_name, [0])
                for off in offsets:
                    specs.append(OutputSpec(uid=uid, ch_offset=off))

        resp = self._helper.set_outputs(specs)
        if resp is None:
            logger.warning("Helper antwortet nicht — bitte prüfen")
        else:
            logger.info(f"Outputs an Helper gesendet ({len(specs)}): ok={resp.get('ok')}")

        # Donation-Hint Trigger bei erstem erfolgreichen Setup
        if specs and not self._config.donation_hint_shown:
            self._config.donation_hint_shown = True
            save_config(self._config)
            self._donation_hint_at = time.monotonic() + DONATION_HINT_DELAY

    def _auto_start_if_configured(self):
        if not self._active_device_names:
            logger.info("Auto-start: keine gespeicherten Devices")
            self._update_status_ui()
            return

        logger.info("Auto-start: lade Outputs %s", ", ".join(self._active_device_names))
        set_default_output_device(AUDIO_ROUTER_DEVICE_NAME)
        self._apply_active_outputs()
        self._update_status_ui()

    def _save_and_apply(self):
        self._config.output_device_offsets = {
            k: list(v) for k, v in self._device_offsets.items()
        }
        self._config.output_device_names = list(self._active_device_names)
        save_config(self._config)
        self._apply_active_outputs()
        self._update_status_ui()

    def _restore_saved_outputs(self):
        if self._config.output_device_names:
            restored = self._device_manager.get_devices_by_names(
                self._config.output_device_names
            )
            self._active_device_names = {d.name for d in restored}
            self._device_offsets = {
                k: list(v) for k, v in self._config.output_device_offsets.items()
            }
            if restored:
                logger.info("Outputs aus Config wiederhergestellt: %s",
                            ", ".join(d.name for d in restored))

        self._build_menu()


def _acquire_instance_lock() -> None:
    global _lock_fd
    _LOCK_DIR.mkdir(parents=True, exist_ok=True)
    try:
        _lock_fd = open(_LOCK_FILE, "w")
        fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        _lock_fd.write(str(os.getpid()))
        _lock_fd.flush()
    except IOError:
        rumps.alert(
            title="AudioRouterNow",
            message="AudioRouterNow is already running. Check the menu bar icon.",
        )
        sys.exit(0)


def _setup_file_logging() -> None:
    log_dir = Path.home() / ".audiorouter" / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    file_handler = RotatingFileHandler(
        log_dir / "audiorouter.log",
        maxBytes=5 * 1024 * 1024,
        backupCount=3,
        encoding="utf-8",
    )
    file_handler.setFormatter(
        logging.Formatter("%(asctime)s %(name)-20s %(levelname)-8s %(message)s")
    )
    logging.getLogger().addHandler(file_handler)


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    )
    _setup_file_logging()
    _acquire_instance_lock()

    from first_launch import check_and_install
    if not check_and_install():
        sys.exit(1)

    app = AudioRouterApp()
    app.run()


if __name__ == "__main__":
    main()
