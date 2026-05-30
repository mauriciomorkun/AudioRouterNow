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
import threading
import time
import webbrowser
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Dict, List

import rumps
from AppKit import NSEvent, NSSystemDefinedMask

from audio_device_control import (
    set_default_output_device,
    set_default_system_output_device,
    get_device_supported_sample_rates,
    is_audio_router_default,
    SUPPORTED_SAMPLE_RATES,
)
from config import AppConfig, CONFIG_FILE, load_config, save_config
from device_manager import AudioDevice, DeviceManager
import first_launch
from first_launch import DRIVER_INSTALL_PATH, is_driver_installed
from helper_client import CONFIG_SOCKET, HelperClient, OutputSpec

logger = logging.getLogger(__name__)

# Name des virtuellen Devices (muss mit HAL-Treiber uebereinstimmen)
AUDIO_ROUTER_DEVICE_NAME = "Audio Router"

# Donation
DONATION_URL = "https://www.buymeacoffee.com/mauriciomorkun"
DONATION_HINT_DELAY = 15

# Documentation
DOCUMENTATION_URL = "https://github.com/mauriciomorkun/AudioRouterNow#readme"

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

        # Help-Untermenü (None als Separator — konsistent mit _build_menu)
        self._help_menu = rumps.MenuItem("Help")
        self._help_menu.update([
            rumps.MenuItem("What's running in the background…", callback=self._show_background_info),
            None,
            rumps.MenuItem("Open documentation", callback=self._open_documentation),
            None,
            rumps.MenuItem("Uninstall AudioRouterNow…", callback=self._uninstall),
        ])

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
        self._needs_reconfigure: bool = False  # set when set_outputs gets not_ready

        # Status-Zeile: letzter (title, action_key)-Wert zum Flacker-Schutz
        self._last_status_cache = (None, None)

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

        # Media Key Interceptor — fängt Volume-Tasten ab und verarbeitet
        # sie manuell via CoreAudio. Keyboard-Volume-Keys erreichen virtuelle
        # HAL-Devices (wie Audio Router) nicht direkt — dieser Interceptor
        # überbrückt die Lücke ohne Accessibility-Permissions.
        self._media_key_monitor = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            NSSystemDefinedMask, self._handle_media_key
        )

        # First-Run Wizard (einmalig nach Installation)
        if not self._config.onboarding_done:
            from onboarding import run_first_run_wizard
            run_first_run_wizard(self, self._config)
            save_config(self._config)  # onboarding_done=True persistieren

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

        # Sample Rate Sektion
        items.append(None)
        sr_header = rumps.MenuItem("SAMPLE RATE:")
        sr_header.set_callback(None)
        items.append(sr_header)

        auto_mark = "[x]" if self._config.auto_sample_rate else "[ ]"
        auto_item = rumps.MenuItem(
            f"{auto_mark}  Auto",
            callback=self._toggle_auto_sample_rate,
        )
        items.append(auto_item)

        current_sr = self._config.sample_rate
        for rate in SUPPORTED_SAMPLE_RATES:
            mark = "[x]" if (not self._config.auto_sample_rate and rate == current_sr) else "[ ]"
            if rate % 1000 == 0:
                label = f"{mark}  {rate // 1000} kHz"
            else:
                label = f"{mark}  {rate / 1000:.1f} kHz"
            sr_item = rumps.MenuItem(
                label,
                callback=lambda sender, r=rate: self._set_sample_rate(r),
            )
            items.append(sr_item)

        items += [
            None,
            self._help_menu,
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

    def _toggle_auto_sample_rate(self, sender):
        self._config.auto_sample_rate = not self._config.auto_sample_rate
        save_config(self._config)
        if self._config.auto_sample_rate:
            self._apply_best_sample_rate()
        self._build_menu()

    def _set_sample_rate(self, rate: int):
        self._config.auto_sample_rate = False
        self._config.sample_rate = rate
        save_config(self._config)
        resp = self._helper.set_sample_rate(rate)
        if not resp or not resp.get("ok"):
            err = resp.get("error", "unknown") if resp else "helper not reachable"
            rumps.alert(
                title="AudioRouterNow — Sample Rate",
                message=f"Could not set sample rate:\n{err}",
            )
        self._build_menu()

    def _apply_best_sample_rate(self):
        """Auto-Detection: beste gemeinsame SR aller aktiven Output-Devices."""
        if not self._config.auto_sample_rate:
            return
        devices = self._device_manager.get_output_devices()
        active = [d for d in devices if d.name in self._active_device_names]
        if not active:
            return
        # Bevorzugte Reihenfolge: hoechste zuerst
        preferred = [192000, 176400, 96000, 88200, 48000, 44100]
        device_rates = []
        for dev in active:
            rates = get_device_supported_sample_rates(dev.uid)
            device_rates.append(set(rates))
        # Beste gemeinsame Rate ermitteln
        best = 48000
        for rate in preferred:
            if all(rate in rates for rates in device_rates):
                best = rate
                break
        # Fix 3c: Nur wenn sich die optimale SR wirklich von der aktuellen
        # Config-SR unterscheidet wird der Helper benachrichtigt. Sonst loest
        # set_sample_rate() unnoetig einen disruptiven SR-Reinit aller Outputs
        # aus (z.B. wenn nur die MacBook-Speaker entfernt werden, die optimale
        # gemeinsame SR sich dadurch aber nicht aendert).
        if best == self._config.sample_rate:
            logger.debug("Auto Sample-Rate: %d Hz unveraendert — kein Reinit", best)
            return
        self._config.sample_rate = best
        save_config(self._config)
        resp = self._helper.set_sample_rate(best)
        if resp and resp.get("ok"):
            logger.info(f"Auto Sample-Rate: {best} Hz")
        else:
            logger.warning(f"Auto Sample-Rate {best} Hz fehlgeschlagen: {resp}")

    def _switch_system_audio(self, sender):
        success, error_msg = set_default_output_device(AUDIO_ROUTER_DEVICE_NAME)
        # System Output ebenfalls auf Audio Router setzen —
        # macOS Keyboard-Volume-Tasten folgen dem System Output.
        # Ohne diesen Schritt zeigt der HUD eine leere Lautstärke-Spur.
        set_default_system_output_device(AUDIO_ROUTER_DEVICE_NAME)
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

    def _show_background_info(self, sender):
        """Zeigt einen Infodialog mit dynamischen System-/Routing-Daten."""
        # --- HAL Audio Driver ---
        try:
            driver_installed = is_driver_installed()
        except Exception:
            driver_installed = os.path.exists(str(DRIVER_INSTALL_PATH))
        driver_status = "Installed" if driver_installed else "Not found"

        # --- Helper Daemon ---
        proc = getattr(self._helper, "_proc", None)
        if proc is not None:
            helper_status = f"Running (PID {proc.pid})"
        elif self._helper_alive:
            helper_status = "Running (managed externally)"
        else:
            helper_status = "Not running"

        # --- Audio Routing ---
        sr_hz = self._config.sample_rate
        if sr_hz % 1000 == 0:
            sr_str = f"{sr_hz // 1000} kHz"
        else:
            sr_str = f"{sr_hz / 1000:.1f} kHz"

        names = sorted(self._active_device_names)
        if not names:
            outputs_str = "none"
        elif len(names) > 3:
            outputs_str = ", ".join(names[:3]) + ", …"
        else:
            outputs_str = ", ".join(names)

        # Latenz: ARN_RING_CAPACITY=16384 / 2 / 48000 * 1000 ≈ 171 ms
        latency_str = "≤ 171 ms (ring buffer)"

        message = (
            "HAL Audio Driver\n"
            f"  Location: {DRIVER_INSTALL_PATH}\n"
            f"  Status: {driver_status}\n"
            "\n"
            "Helper Daemon\n"
            f"  Status: {helper_status}\n"
            f"  Socket: {CONFIG_SOCKET}\n"
            "\n"
            "Audio Routing\n"
            f"  Sample Rate: {sr_str}\n"
            f"  Active Outputs: {outputs_str}\n"
            f"  Expected latency: {latency_str}\n"
            "\n"
            f"Configuration: {CONFIG_FILE}\n"
            "App log: ~/.audiorouter/logs/audiorouter.log\n"
            "Helper log: ~/Library/Logs/AudioRouterNow/\n"
            "\n"
            "For full technical details open the documentation\n"
            "(Help → Open documentation)."
        )

        rumps.alert(
            title="AudioRouterNow — What's running",
            message=message,
            ok="Close",
        )

    def _open_documentation(self, sender):
        import pathlib

        # Lokale DOKUMENTATION.md im Dev-Mode bevorzugen
        local_doc = pathlib.Path(__file__).parent.parent / "DOKUMENTATION.md"
        if local_doc.exists():
            import subprocess
            subprocess.run(["open", str(local_doc)])
        else:
            webbrowser.open(DOCUMENTATION_URL)

    def _uninstall(self, sender):
        if not first_launch._show_uninstall_confirm():
            return
        # Helper und Routing stoppen
        self._ui_timer.stop()
        try:
            self._helper.shutdown()
        except Exception:
            pass
        # Uninstall ausführen
        success, msg = first_launch.uninstall_all()
        if success:
            rumps.alert(
                title="AudioRouterNow Uninstalled",
                message="All components removed.\n\nDrag AudioRouterNow.app to Trash to complete the uninstall.",
                ok="Done",
            )
            rumps.quit_application()
        else:
            rumps.alert(title="Uninstall incomplete", message=msg, ok="OK")
            self._ui_timer.start()  # Timer wieder starten falls abgebrochen

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
            old_alive = self._helper_alive
            self._helper_alive = alive_now
            # _update_status_ui() wird unten bei jedem Tick aufgerufen.
            # Helper went from dead → alive (e.g., slow start, or respawn succeeded)
            if alive_now and not old_alive:
                logger.info("Helper jetzt erreichbar — Outputs neu konfigurieren")
                self._auto_start_if_configured()
            # Helper went from alive → dead → try to respawn
            elif not alive_now and old_alive:
                logger.warning("Helper nicht mehr erreichbar — versuche Neustart")
                def _respawn():
                    ok = self._helper.ensure_running()
                    if ok:
                        logger.info("Helper erfolgreich neugestartet")
                    else:
                        logger.error("Helper-Neustart fehlgeschlagen")
                threading.Thread(target=_respawn, name="helper-respawn", daemon=True).start()

        # Status-Zeile bei JEDEM Tick aktualisieren — nicht nur bei Helper-
        # Zustandswechsel. Noetig damit z.B. externes Umstellen des System-
        # Audio-Outputs (routed_here) zeitnah erkannt wird. Caching in
        # _update_status_ui verhindert unnoetiges Neu-Rendern.
        self._update_status_ui()

        # Retry set_outputs wenn Helper noch nicht SHM-bereit war
        if self._needs_reconfigure and alive_now:
            status = self._helper.get_status()
            if status is not None and status.get('ready') is not False:
                logger.info("Helper SHM bereit — Outputs neu konfigurieren (retry)")
                self._auto_start_if_configured()

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

        # Volume-Sync-Fallback: Keyboard-Volume-Keys erreichen virtuelle HAL-
        # Devices nicht immer direkt. Dieser Poll erkennt System-Volume-
        # Änderungen und re-applied sie via osascript, was den Driver's
        # SetPropertyData triggert und volume_q16 im SHM synchron hält.
        self._poll_volume_sync()

    def _poll_volume_sync(self):
        """Fallback: Wenn Keyboard-Volume-Keys den Driver nicht direkt erreichen,
        erkennt dieser Poll die Änderung und triggert volume_q16 via osascript."""
        try:
            import subprocess
            r = subprocess.run(['osascript', '-e',
                'output volume of (get volume settings)'],
                capture_output=True, text=True, timeout=0.3)
            new_vol = int(r.stdout.strip())
            old_vol = getattr(self, '_last_polled_vol', new_vol)
            self._last_polled_vol = new_vol
            if new_vol != old_vol:
                # Volume hat sich geändert — via osascript setzen triggert Driver
                subprocess.run(['osascript', '-e',
                    f'set volume output volume {new_vol}'],
                    capture_output=True, timeout=0.3)
        except Exception:
            pass

    def _compute_status(self) -> tuple[str, object]:
        """
        Berechnet den aktuellen Systemzustand und liefert (title, action_key).

        action_key ist ein String, der _status_action zur Dispatch-Entscheidung
        dient ("restart_helper" / "switch_audio"), oder None wenn die Zeile
        nicht klickbar ist.

        Eingangssignale in Prioritaet:
          1. helper_alive
          2. outputs_selected
          3. routed_here  (System-Default-Output == Audio Router)
          4. audio_flowing (get_status: ring_frames > 0)
        """
        helper_alive = self._helper_alive
        outputs_selected = bool(self._active_device_names)

        # 1. Helper tot → alles andere irrelevant
        if not helper_alive:
            return ("⚠️  Helper not responding — click to restart", "restart_helper")

        # 2. Helper lebt, aber kein Output gewaehlt
        if not outputs_selected:
            return ("🔴  No output selected — pick a device below", None)

        # 3. routed_here pruefen (System-Default == Audio Router)
        routed_here = is_audio_router_default()
        if not routed_here:
            return ("🟡  System audio not routed here — click to fix", "switch_audio")

        # 4. audio_flowing — get_status NUR wenn helper_alive AND outputs_selected.
        #    Kurzer Timeout, damit ein haengender Helper den 0.5s-Timer nicht blockiert.
        audio_flowing = False
        status = self._helper.get_status(timeout=0.2)
        if status is not None:
            try:
                audio_flowing = int(status.get("ring_frames", 0)) > 0
            except (TypeError, ValueError):
                audio_flowing = False

        if not audio_flowing:
            return ("🟡  Ready — play something to start routing", None)

        # 5. Routing aktiv → Device-Namen anhaengen
        names = sorted(self._active_device_names)
        if len(names) > 2:
            names_str = f"{len(names)} devices"
        else:
            names_str = ", ".join(names)
        return (f"🟢  Routing active — {names_str}", None)

    def _status_action(self, sender):
        """
        Dispatcher fuer Klicks auf die Status-Zeile. Fuehrt die zum aktuell
        gecachten Zustand passende Aktion aus.
        """
        _, action_key = self._last_status_cache
        if action_key == "restart_helper":
            self._restart_helper(sender)
        elif action_key == "switch_audio":
            self._switch_system_audio(sender)

    def _restart_helper(self, sender):
        """
        Startet den Helper neu (analog zur _respawn-Logik in
        _process_pending_updates) in einem Thread, damit die UI nicht blockiert.
        """
        def _restart():
            ok = self._helper.ensure_running()
            if ok:
                logger.info("Helper erfolgreich neugestartet (manuell via Status-Zeile)")
            else:
                logger.error("Manueller Helper-Neustart fehlgeschlagen")
        threading.Thread(target=_restart, name="helper-manual-restart", daemon=True).start()

    def _handle_media_key(self, event):
        """
        Interceptiert macOS Media Keys (Volume Up/Down/Mute).

        Keyboard-Volume-Keys senden NSSystemDefined-Events mit subtype 8.
        Sie erreichen virtuelle HAL-Devices nicht direkt — dieser Handler
        verarbeitet sie manuell: liest den aktuellen Output-Volume, passt
        ihn an und setzt ihn via osascript (was den Driver's SetPropertyData
        korrekt triggert und volume_q16 im SHM aktualisiert).

        Key-Codes (NX_KEYTYPE_*): 2=Volume Down, 3=Volume Up, 7=Mute.
        data1-Format: bits 31-16 = key code, bits 15-8 = key state (0xA=down).
        """
        try:
            if event.type() != 14:   # NSSystemDefined
                return
            if event.subtype() != 8:  # Media key subtype
                return
            data = event.data1()
            key_code  = (data & 0xFFFF0000) >> 16
            key_state = (data & 0x0000FF00) >> 8
            if key_state != 0xA:      # Nur Key-Down verarbeiten
                return

            import subprocess
            # Aktuellen Volume lesen
            result = subprocess.run(
                ['osascript', '-e', 'output volume of (get volume settings)'],
                capture_output=True, text=True, timeout=1,
            )
            try:
                current = int(result.stdout.strip())
            except ValueError:
                return

            STEP = 7  # ~15 Stufen von 0 bis 100
            if key_code == 3:    # Volume Up (NX_KEYTYPE_SOUND_UP)
                new_vol = min(100, current + STEP)
            elif key_code == 2:  # Volume Down (NX_KEYTYPE_SOUND_DOWN)
                new_vol = max(0, current - STEP)
            elif key_code == 7:  # Mute (NX_KEYTYPE_MUTE)
                new_vol = 0 if current > 0 else 50
            else:
                return

            subprocess.run(
                ['osascript', '-e', f'set volume output volume {new_vol}'],
                capture_output=True, timeout=1,
            )
            logger.debug(f"Media Key: volume {current}% → {new_vol}%")
        except Exception as exc:
            logger.debug(f"_handle_media_key Fehler: {exc}")

    def _update_status_ui(self):
        title, action_key = self._compute_status()

        # Menueleisten-Icon spiegelt den Zustand (erstes Zeichen des Titles).
        icon = title[:1]

        # Flacker-Schutz: nur neu setzen wenn sich (title, action_key) aendert.
        if (title, action_key) == self._last_status_cache:
            return
        self._last_status_cache = (title, action_key)

        self.title = icon
        self._status_item.title = title
        if action_key is None:
            self._status_item.set_callback(None)
        else:
            self._status_item.set_callback(self._status_action)

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
        if resp is not None and resp.get('error') == 'not_ready':
            # Helper socket is up but SHM not yet ready — schedule retry via timer
            logger.info("Helper SHM noch nicht bereit — warte auf Bereitschaft (auto-retry)")
            self._needs_reconfigure = True
            return
        self._needs_reconfigure = False
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
        # System Output ebenfalls auf Audio Router setzen — Keyboard-Volume-
        # Tasten folgen dem System Output ('sOut'). Symmetrisch zu dOut.
        set_default_system_output_device(AUDIO_ROUTER_DEVICE_NAME)
        self._apply_best_sample_rate()
        self._apply_active_outputs()
        self._update_status_ui()

    def _save_and_apply(self):
        had_outputs_before = bool(self._config.output_device_names)

        self._config.output_device_offsets = {
            k: list(v) for k, v in self._device_offsets.items()
        }
        self._config.output_device_names = list(self._active_device_names)
        save_config(self._config)

        # Auto-Switch: wenn der User das erste Output aktiviert,
        # System-Audio automatisch auf "Audio Router" umschalten.
        # Kein manueller Klick auf "System Audio → Audio Router" nötig.
        if self._active_device_names and not had_outputs_before:
            set_default_output_device(AUDIO_ROUTER_DEVICE_NAME)
            set_default_system_output_device(AUDIO_ROUTER_DEVICE_NAME)
            logger.info("Auto-Switch: System-Audio auf Audio Router umgestellt")

            # StartIO-Trigger: Default-Output kurz togglen zwingt coreaudiod,
            # den IO-Stack für "Audio Router" frisch aufzubauen → StartIO wird
            # aufgerufen → Driver schreibt Frames in den Ring.
            # Helper-Reconnect allein reicht nicht — StartIO kommt von coreaudiod,
            # nicht vom Helper.
            def _trigger_start_io():
                import time, subprocess, os
                time.sleep(1.0)
                status = self._helper.get_status(timeout=1.0)
                if status and status.get("ring_frames", 0) == 0:
                    logger.info("StartIO-Trigger: Ring leer — spiele stilles Audio")
                    # Einen stummen Sound über Audio Router abspielen.
                    # Das öffnet einen CoreAudio-Client auf dem virtuellen Device
                    # → coreaudiod ruft StartIO auf → Driver beginnt zu schreiben.
                    # afplay nutzt den Default Output (Audio Router).
                    silent = "/System/Library/Sounds/Funk.aiff"
                    if not os.path.exists(silent):
                        silent = "/System/Library/Sounds/Pop.aiff"
                    subprocess.run(
                        ["afplay", "-v", "0", silent],
                        capture_output=True, timeout=5,
                    )
                    time.sleep(0.3)
                    # Falls Ring immer noch leer: Output-Toggle als Fallback
                    status2 = self._helper.get_status(timeout=1.0)
                    if status2 and status2.get("ring_frames", 0) == 0:
                        logger.info("StartIO-Trigger: afplay reichte nicht — togglee Output")
                        subprocess.run(
                            ["SwitchAudioSource", "-s", "MacBook Pro-Lautsprecher", "-t", "output"],
                            capture_output=True, timeout=2,
                        )
                        time.sleep(0.8)
                        subprocess.run(
                            ["SwitchAudioSource", "-s", AUDIO_ROUTER_DEVICE_NAME, "-t", "output"],
                            capture_output=True, timeout=2,
                        )
                        subprocess.run(
                            ["SwitchAudioSource", "-s", AUDIO_ROUTER_DEVICE_NAME, "-t", "system"],
                            capture_output=True, timeout=2,
                        )
                    logger.info("StartIO-Trigger: abgeschlossen")
            threading.Thread(target=_trigger_start_io, daemon=True, name="start-io-trigger").start()

        self._apply_active_outputs()
        if self._config.auto_sample_rate:
            self._apply_best_sample_rate()
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
