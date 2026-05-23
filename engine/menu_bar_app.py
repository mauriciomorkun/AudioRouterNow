"""
MenuBarApp — macOS menu bar widget for AudioRouterNow.

Shows status in the menu bar and allows:
  - Starting / stopping routing
  - Selecting output devices (multiple simultaneously)
  - Switching system audio natively to "Audio Router" (no external tools needed)
  - Hot-plug: new devices appear in the menu automatically

Menu structure:
  🎛️ AudioRouterNow
  ─────────────────────────
  Status: Active / Stopped
  ─────────────────────────
  ▶ Start Routing / ⏹ Stop Routing
  ─────────────────────────
  System Audio → Audio Router
  ─────────────────────────
  OUTPUT DEVICES:
    ☑ Komplete Audio 6 — 6ch
    ☐ MacBook Pro Speakers — 2ch
    ...
  ─────────────────────────
  Quit

Dependencies: rumps, sounddevice, numpy
No external tools needed — system audio switching via native CoreAudio API.
"""

import fcntl
import logging
import os
import sys
import webbrowser
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Dict, List

import rumps

from audio_device_control import set_default_output_device
from config import AppConfig, load_config, save_config
from device_manager import AudioDevice, DeviceManager
from routing_engine import OutputTarget, RoutingEngine
from socket_receiver import SocketReceiver

logger = logging.getLogger(__name__)

# Name of the virtual audio device (must match the HAL driver)
AUDIO_ROUTER_DEVICE_NAME = "Audio Router"

# Donation
DONATION_URL = "https://www.buymeacoffee.com/mauriciomorkun"
DONATION_HINT_DELAY = 15  # seconds after first successful routing

# Single-instance lock
_LOCK_DIR = Path.home() / ".audiorouter"
_LOCK_FILE = _LOCK_DIR / "audiorouter.lock"
_lock_fd = None  # Keep global reference to prevent GC closing the file


class AudioRouterApp(rumps.App):
    """
    Main application: connects all components and provides the menu.
    """

    def __init__(self):
        super().__init__("🔇", quit_button=None)

        # Load configuration
        self._config: AppConfig = load_config()

        # Active output device names (for toggle logic)
        self._active_device_names: set = set(self._config.output_device_names)

        # Active channel offsets per device (device_name -> list of active offsets)
        # Multiple offsets = multiple channel pairs active simultaneously
        self._device_offsets: Dict[str, List[int]] = {
            k: list(v) for k, v in self._config.output_device_offsets.items()
        }

        # --- Components ---
        self._routing_engine = RoutingEngine(on_status=self._on_routing_status)
        self._socket_receiver = SocketReceiver(on_frames=self._routing_engine.on_frames)
        self._device_manager = DeviceManager(on_devices_changed=self._on_devices_changed)

        # --- Menu items ---
        self._status_item = rumps.MenuItem("⚫ Stopped")
        self._status_item.set_callback(None)

        self._toggle_btn = rumps.MenuItem(
            "▶  Start Routing", callback=self._toggle_routing
        )

        self._switch_audio_btn = rumps.MenuItem(
            "System Audio → Audio Router", callback=self._switch_system_audio
        )

        self._output_header = rumps.MenuItem("OUTPUT DEVICES:")
        self._output_header.set_callback(None)

        self._quit_btn = rumps.MenuItem("Quit", callback=self._quit_app)

        # Donation menu items
        self._donation_btn = rumps.MenuItem(
            "☕  Support AudioRouterNow", callback=self._open_donation
        )
        self._donation_footer = rumps.MenuItem("Made with ♥ by Mauricio · free forever")
        self._donation_footer.set_callback(None)

        # Device menu items (populated dynamically)
        self._device_menu_items: Dict[str, rumps.MenuItem] = {}

        # --- Thread-safe update flags ---
        # rumps.Timer only works on the main thread.
        # Background threads (DeviceManager, RoutingEngine) only set flags —
        # a single main-thread timer reads them.
        self._pending_status: tuple | None = None
        self._device_update_pending: bool = False
        self._donation_hint_at: float | None = None  # timestamp when to show

        # Main-thread UI update timer (every 0.25s — reads pending flags)
        self._ui_timer = rumps.Timer(self._process_pending_updates, 0.25)
        self._ui_timer.start()

        # Start components
        self._device_manager.start()   # Populates _known_devices via _scan_devices()
        self._socket_receiver.start()

        # Build menu + restore saved devices
        # (AFTER start() — so _known_devices is already populated)
        self._restore_saved_outputs()

        # Auto-start: begin routing immediately if saved devices exist
        self._auto_start_if_configured()

    # ------------------------------------------------------------------
    # Menu building
    # ------------------------------------------------------------------

    def _build_menu(self):
        """Rebuilds the entire menu from scratch."""
        self.menu.clear()

        items = [
            self._status_item,
            None,  # separator
            self._toggle_btn,
            None,
            self._switch_audio_btn,
            None,
            self._output_header,
        ]

        # Add currently known devices
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
        """Creates a menu item for an output device."""
        is_active = device.name in self._active_device_names

        if device.max_output_channels <= 2:
            # Simple stereo device: no submenu
            checkmark = "☑" if is_active else "☐"
            title = f"{checkmark}  {device.name} — {device.max_output_channels}ch"
            item = rumps.MenuItem(
                title,
                callback=lambda sender, d=device: self._toggle_device(sender, d),
            )
            return item

        # Multi-channel device: title shows active pairs, submenu allows multi-select
        active_offsets = self._device_offsets.get(device.name, [])
        checkmark = "☑" if is_active and active_offsets else "☐"

        if is_active and active_offsets:
            pairs_str = ", ".join(
                f"Ch {o + 1}-{o + 2}" for o in sorted(active_offsets)
            )
            title = f"{checkmark}  {device.name} — {pairs_str}"
        else:
            title = f"{checkmark}  {device.name} — {device.max_output_channels}ch"

        item = rumps.MenuItem(
            title,
            callback=lambda sender, d=device: self._toggle_device(sender, d),
        )

        # Submenu: one entry per stereo pair, each independently toggleable
        num_pairs = device.max_output_channels // 2
        for pair_idx in range(num_pairs):
            offset = pair_idx * 2
            pair_label = f"Ch {offset + 1}-{offset + 2}"
            selected = (offset in active_offsets) and is_active
            pair_mark = "☑" if selected else "☐"
            sub_item = rumps.MenuItem(
                f"{pair_mark}  {pair_label}",
                callback=lambda sender, d=device, o=offset: self._toggle_channel_pair(sender, d, o),
            )
            item[pair_label] = sub_item

        return item

    # ------------------------------------------------------------------
    # Callbacks
    # ------------------------------------------------------------------

    def _toggle_routing(self, sender):
        """Starts or stops routing."""
        if self._routing_engine.is_running:
            self._routing_engine.stop()
            self._socket_receiver.stop()
        else:
            # Configure outputs before starting
            self._apply_active_outputs()
            self._socket_receiver.start()
            # Automatically switch system audio to "Audio Router"
            set_default_output_device(AUDIO_ROUTER_DEVICE_NAME)
            success = self._routing_engine.start()
            if not success:
                rumps.alert(
                    title="AudioRouterNow — No Output Device",
                    message=(
                        "Please select an output device first:\n\n"
                        "Click a device in the OUTPUT DEVICES list "
                        "to check it with ☑, then click 'Start Routing'."
                    ),
                )

    def _toggle_device(self, sender, device: AudioDevice):
        """Toggles an output device on or off (main checkbox)."""
        if device.name in self._active_device_names:
            # Deactivate: remove all channel pairs
            self._active_device_names.discard(device.name)
            self._device_offsets.pop(device.name, None)
        else:
            # Activate: pre-select default Ch 1-2 (offset 0)
            self._active_device_names.add(device.name)
            if device.max_output_channels > 2:
                self._device_offsets[device.name] = [0]

        self._save_and_apply()
        self._build_menu()

    def _toggle_channel_pair(self, sender, device: AudioDevice, offset: int):
        """
        Toggles a single channel pair on or off (submenu checkbox).
        Multiple pairs can be active simultaneously.
        """
        offsets = self._device_offsets.get(device.name, [])

        if offset in offsets:
            offsets = [o for o in offsets if o != offset]
        else:
            offsets = sorted(offsets + [offset])

        if offsets:
            # At least one pair active → device active
            self._device_offsets[device.name] = offsets
            self._active_device_names.add(device.name)
        else:
            # No pairs active → deactivate device
            self._device_offsets.pop(device.name, None)
            self._active_device_names.discard(device.name)

        self._save_and_apply()
        self._build_menu()

    def _switch_system_audio(self, sender):
        """
        Sets the macOS system audio output to 'Audio Router' via CoreAudio API.
        Works on all macOS versions without AppleScript or external tools.
        """
        success, error_msg = set_default_output_device(AUDIO_ROUTER_DEVICE_NAME)

        if success:
            rumps.notification(
                title="AudioRouterNow",
                subtitle="",
                message="System audio switched to 'Audio Router'.",
            )
        else:
            rumps.alert(
                title="AudioRouterNow — Switch Failed",
                message=(
                    f"Could not switch system audio:\n\n{error_msg}"
                ),
            )

    def _open_donation(self, sender):
        """Opens the Buy Me a Coffee page in the browser."""
        webbrowser.open(DONATION_URL)

    def _quit_app(self, sender):
        """Stops all components and exits the application."""
        self._ui_timer.stop()
        self._routing_engine.stop()
        self._socket_receiver.stop()
        self._device_manager.stop()
        save_config(self._config)
        rumps.quit_application()

    # ------------------------------------------------------------------
    # Status callbacks from components
    # ------------------------------------------------------------------

    def _on_routing_status(self, is_running: bool, message: str):
        """
        Called by the RoutingEngine thread — sets a flag only.
        The main-thread timer (_ui_timer) processes it in a thread-safe manner.
        """
        import time
        self._pending_status = (is_running, message)

        # Donation hint: record timestamp, main thread shows it later
        if is_running and not self._config.donation_hint_shown:
            self._config.donation_hint_shown = True
            save_config(self._config)
            self._donation_hint_at = time.monotonic() + DONATION_HINT_DELAY

    def _on_devices_changed(self, new_devices: list):
        """
        Called by the DeviceManager thread — sets a flag only.
        The main-thread timer (_ui_timer) rebuilds the menu.
        """
        self._device_update_pending = True

    def _process_pending_updates(self, timer):
        """
        Runs every 0.25s on the main thread (macOS main run loop).
        Processes all pending updates from background threads in a thread-safe way.
        """
        import time

        # Refresh device list if needed
        if self._device_update_pending:
            self._device_update_pending = False
            self._build_menu()

        # Update routing status
        status = self._pending_status
        if status is not None:
            self._pending_status = None
            is_running, _ = status
            if is_running:
                self.title = "🎛️"
                self._toggle_btn.title = "⏹  Stop Routing"
                self._status_item.title = "🟢 Active"
            else:
                self.title = "🔇"
                self._toggle_btn.title = "▶  Start Routing"
                self._status_item.title = "⚫ Stopped"

        # Show donation hint once, after delay
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
    # Internal helpers
    # ------------------------------------------------------------------

    def _apply_active_outputs(self):
        """
        Configures the RoutingEngine based on the active device names.
        Creates one OutputTarget per active channel pair per device.
        """
        devices = self._device_manager.get_output_devices()
        targets: List[OutputTarget] = []

        for device in devices:
            if device.name not in self._active_device_names:
                continue

            if device.max_output_channels <= 2:
                # Simple stereo device: one target, no offset
                targets.append(
                    OutputTarget(
                        device_index=device.index,
                        device_name=device.name,
                        channel_count=device.max_output_channels,
                        channel_offset=0,
                    )
                )
            else:
                # Multi-channel: one target per active channel pair
                offsets = self._device_offsets.get(device.name, [0])
                for offset in offsets:
                    targets.append(
                        OutputTarget(
                            device_index=device.index,
                            device_name=f"{device.name} Ch {offset + 1}-{offset + 2}",
                            channel_count=device.max_output_channels,
                            channel_offset=offset,
                        )
                    )

        self._routing_engine.set_outputs(targets)

        if targets:
            names = ", ".join(t.device_name for t in targets)
            logger.info("Active outputs: %s", names)
        else:
            logger.info("No outputs configured")

    def _auto_start_if_configured(self):
        """
        Automatically starts routing on app launch if output devices were
        previously selected and saved.

        Condition: at least one active device in _active_device_names
        (populated by _restore_saved_outputs).
        """
        if not self._active_device_names:
            logger.info("Auto-start: no saved devices — waiting for manual selection")
            return

        logger.info("Auto-start: starting routing with: %s", ", ".join(self._active_device_names))

        # Switch system audio to "Audio Router"
        set_default_output_device(AUDIO_ROUTER_DEVICE_NAME)

        # Configure outputs and start routing
        self._apply_active_outputs()
        success = self._routing_engine.start()

        if not success:
            logger.warning("Auto-start: routing could not be started")

    def _save_and_apply(self):
        """Saves the current selection and reconfigures the RoutingEngine."""
        self._config.output_device_offsets = {
            k: list(v) for k, v in self._device_offsets.items()
        }
        self._config.output_device_names = list(self._active_device_names)
        save_config(self._config)
        self._apply_active_outputs()

    def _restore_saved_outputs(self):
        """
        Restores saved output devices on startup.
        Looks up devices by saved name (substring matching).
        Always rebuilds the menu — even on a fresh install with no saved devices.
        """
        if self._config.output_device_names:
            restored = self._device_manager.get_devices_by_names(
                self._config.output_device_names
            )
            # Set active devices to those found
            self._active_device_names = {d.name for d in restored}
            # Restore channel offsets (Dict[str, List[int]])
            self._device_offsets = {
                k: list(v) for k, v in self._config.output_device_offsets.items()
            }

            if restored:
                names = ", ".join(d.name for d in restored)
                logger.info("Output devices restored from config: %s", names)

        # Always build the menu (shows all known devices, even without saved selection)
        self._build_menu()


def _acquire_instance_lock() -> None:
    """
    Ensures only one instance of AudioRouterNow runs at a time.
    Uses an exclusive file lock on ~/.audiorouter/audiorouter.lock.
    Exits with a user-visible alert if another instance is already running.
    """
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
    """
    Adds a rotating file handler to the root logger.
    Logs are written to ~/.audiorouter/logs/audiorouter.log (max 5 MB × 3 files).
    """
    log_dir = Path.home() / ".audiorouter" / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)

    file_handler = RotatingFileHandler(
        log_dir / "audiorouter.log",
        maxBytes=5 * 1024 * 1024,  # 5 MB
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

    # Set up file logging before anything else
    _setup_file_logging()

    # Ensure only one instance runs
    _acquire_instance_lock()

    # First launch: check and install HAL driver if needed
    from first_launch import check_and_install
    if not check_and_install():
        sys.exit(1)

    app = AudioRouterApp()
    app.run()


if __name__ == "__main__":
    main()
