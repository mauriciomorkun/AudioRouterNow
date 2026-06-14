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
  Help ▶
    What's running in the background…
    ─────────────────────────
    Open documentation
    Check for Updates…          ← öffnet github.com/…/releases (Sparkle kommt in v3.5)
    ─────────────────────────
    Save Diagnostic Report…
    ─────────────────────────
    Uninstall AudioRouterNow…
  ─────────────────────────
  Quit
"""

import fcntl
import logging
import os
import queue
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
    # P1: Event-driven Volume
    register_volume_listener,
    unregister_volume_listener,
    set_default_output_volume,
    set_muted,
    get_default_output_volume,
    get_default_output_muted,
)
from config import AppConfig, CONFIG_FILE, load_config, save_config
from device_manager import AudioDevice, DeviceManager
from health import HealthMonitor
from healer import Healer
import first_launch
from first_launch import DRIVER_INSTALL_PATH, is_driver_installed
from helper_client import CONFIG_SOCKET, HelperClient, OutputSpec
import diagnostic

logger = logging.getLogger(__name__)

# Name des virtuellen Devices (muss mit HAL-Treiber uebereinstimmen)
AUDIO_ROUTER_DEVICE_NAME = "Audio Router"

# Donation
DONATION_URL = "https://www.buymeacoffee.com/mauriciomorkun"
DONATION_HINT_DELAY = 15

# Documentation
DOCUMENTATION_URL = "https://github.com/mauriciomorkun/AudioRouterNow#readme"

# Updates
RELEASES_URL = "https://github.com/mauriciomorkun/AudioRouterNow/releases"

# Single-instance lock
_LOCK_DIR = Path.home() / ".audiorouter"
_LOCK_FILE = _LOCK_DIR / "audiorouter.lock"
_lock_fd = None

# P3: coreaudiod-Watchdog — Flag-Datei geschrieben vom C Helper bei CPU-Spin >90% >5s
_SPIN_FLAG_PATH = Path.home() / ".audiorouter" / "coreaudiod_spin.flag"


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
            rumps.MenuItem("Check for Updates…", callback=self._check_for_updates),
            None,
            rumps.MenuItem("Save Diagnostic Report…", callback=self._save_diagnostic_report),
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
        self._reconfigure_attempts: int = 0  # Fix-3: Retry-Zähler mit Backoff
        self._coreaudiod_spin_detected: bool = False  # P3: Flag für Watchdog-Trip-Dialog

        # K2: Thread-safe pending actions (consumed on main thread via UI timer)
        self._pending_notifications: list = []  # list of (title, message) tuples
        self._pending_notifications_lock = threading.Lock()
        self._needs_reconnect_autostart: bool = False

        # Status-Zeile: letzter (title, action_key)-Wert zum Flacker-Schutz
        self._last_status_cache = (None, None)

        # H4: Reconcile-Grace — Drift muss 3 Polls in Folge bestehen, bevor
        # die interne Auswahl korrigiert/persistiert wird (transiente Helper-
        # Zustaende direkt nach set_outputs sollen nicht persistieren).
        self._reconcile_drift_count: int = 0

        # N3: Bereits notifizierte Circuit-Breaker-Trips (uid, ch_offset).
        self._notified_trips: set = set()

        # M5: Health-Startup-Grace — in den ersten 3 Poll-Iterationen wird
        # kein "critical" gemeldet (Helper/SHM brauchen beim Start kurz).
        self._initial_health_grace: int = 3

        # M4: Media-Key-Volume-Queue — serialisiert Volume-Aenderungen in
        # EINEM Worker-Thread statt einem Thread pro Tastendruck (verhindert
        # Races bei schnellen Key-Repeats).
        self._volume_queue = queue.Queue()
        self._volume_worker = threading.Thread(
            target=self._volume_worker_loop, daemon=True, name="volume-worker")
        self._volume_worker.start()

        # P8: Zentraler Status-Cache. Der health-poll-Loop (200ms) ruft ohnehin
        # regelmaessig get_status auf — andere Stellen (_compute_status,
        # _process_pending_updates) lesen den Cache statt eigene Socket-Connects
        # zu oeffnen. Dict-Zuweisung ist GIL-atomar; kein zusaetzliches Lock noetig.
        self._status_cache: dict | None = None
        self._status_cache_ts: float = 0.0

        # H-8: is_audio_router_default() (synchroner CoreAudio-Call) wird vom
        # health-poll-Thread (200ms, NICHT Main-Thread) gecacht. _compute_status()
        # liest nur den Cache — kein Mach-IPC auf dem 0.5s-UI-Timer-Tick.
        self._router_is_default: bool = False

        # Main-thread UI-Timer
        self._ui_timer = rumps.Timer(self._process_pending_updates, 0.5)
        self._ui_timer.start()

        # P1: Event-driven Volume — CoreAudio Property-Listener statt
        # osascript-Polling. Der Listener feuert bei jeder Lautstaerke-Aenderung
        # des Standard-Ausgabegeraets; ein periodischer Poll-Thread entfaellt.
        try:
            register_volume_listener(self._on_volume_changed)
        except Exception as e:
            logger.debug("Volume-Listener konnte nicht registriert werden: %s", e)

        # Tranche A: Health-Monitor
        self._health_monitor = HealthMonitor()
        self._health_level: str = "healthy"   # GIL-atomare Zuweisung reicht
        self._health_poll_stop = threading.Event()
        self._health_poll_thread = threading.Thread(
            target=self._health_poll_loop, name="health-poll", daemon=True)
        self._health_poll_thread.start()

        # Tranche B: Healer (Safe-Take-aware)
        self._healer = Healer(
            helper_client=self._helper,
            safe_take_getter=lambda: getattr(self._config, 'safe_take_mode', False)
        )

        # P10: Treiber-ABI-Version gegen App-Erwartung pruefen (einmalig beim
        # Start gecacht — kein File-Read pro Status-Tick). Bei Mismatch zeigt
        # _compute_status eine "Driver update required"-Zeile.
        try:
            self._driver_abi_ok = first_launch.driver_abi_matches()
            if not self._driver_abi_ok:
                logger.warning(
                    "Driver-ABI-Mismatch: installiert=%s, erwartet=%d",
                    first_launch.get_installed_driver_abi_version(),
                    first_launch.APP_EXPECTED_ABI_VERSION,
                )
        except Exception as e:
            logger.debug("ABI-Check fehlgeschlagen: %s", e)
            self._driver_abi_ok = True  # fail-open: keine Falsch-Alarme

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

        # Tranche B: Safe-Take State nach Helper-Start synchronisieren
        if self._config.safe_take_mode:
            self._helper.set_safe_take(True)

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
        # Fortschritts-Fenster schließen (blieb nach Treiber-Install offen)
        first_launch.close_active_progress_window()
        if not self._config.onboarding_done:
            from onboarding import run_first_run_wizard
            run_first_run_wizard(self, self._config)
            save_config(self._config)  # onboarding_done=True persistieren

    # ------------------------------------------------------------------
    # Menu building
    # ------------------------------------------------------------------

    @staticmethod
    def _format_sample_rate(sr: int) -> str:
        """N5: Einheitliche kHz-Formatierung (44.1 kHz / 48 kHz / …)."""
        if sr % 1000 == 0:
            return f"{sr // 1000} kHz"
        return f"{sr / 1000:.1f} kHz"

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
            label = f"{mark}  {self._format_sample_rate(rate)}"
            sr_item = rumps.MenuItem(
                label,
                callback=lambda sender, r=rate: self._set_sample_rate(r),
            )
            items.append(sr_item)

        # Tranche B: Safe-Take-Modus
        safe_mark = "[x]" if self._config.safe_take_mode else "[ ]"
        safe_item = rumps.MenuItem(
            f"{safe_mark}  Safe mode (no auto-healing)",
            callback=self._toggle_safe_take,
        )

        items += [
            None,
            safe_item,
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

    def _toggle_safe_take(self, sender):
        self._config.safe_take_mode = not self._config.safe_take_mode
        save_config(self._config)
        self._helper.set_safe_take(self._config.safe_take_mode)
        logger.info("Safe-Take: %s", "aktiviert" if self._config.safe_take_mode else "deaktiviert")
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
        best = None
        for rate in preferred:
            if all(rate in rates for rates in device_rates):
                best = rate
                break
        if best is None:
            # H3: Kein gemeinsamer Schnitt aller Geraete — statt blind 48 kHz
            # die Rate mit maximaler Abdeckung waehlen (meiste Geraete
            # unterstuetzen sie; bei Gleichstand gewinnt die hoehere Rate).
            coverage = {
                rate: sum(1 for rates in device_rates if rate in rates)
                for rate in preferred
            }
            best = max(preferred, key=lambda r: coverage[r])
            if coverage[best] == 0:
                best = 48000  # Sicherheitsnetz — sollte nie eintreten
            logger.warning(
                "Auto Sample-Rate: keine gemeinsame Rate aller %d Geraete — "
                "waehle %d Hz (unterstuetzt von %d/%d Geraeten)",
                len(active), best, coverage.get(best, 0), len(active),
            )
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
        sr_str = self._format_sample_rate(self._config.sample_rate)

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

    def _check_for_updates(self, sender):
        """Öffnet die GitHub-Releases-Seite im Browser.

        Sparkle auto-updates sind für v3.5 geplant. Bis dahin manuelle Prüfung.
        rumps.alert() gibt 1 zurück wenn OK geklickt, 0 bei Cancel.
        """
        from version import APP_VERSION
        response = rumps.alert(
            title="Check for Updates",
            message=(
                f"You are running AudioRouterNow v{APP_VERSION}.\n\n"
                "Click OK to open the GitHub Releases page and check for a newer version."
            ),
            ok="Open GitHub Releases",
            cancel="Cancel",
        )
        if response:
            webbrowser.open(RELEASES_URL)

    def _save_diagnostic_report(self, sender):
        """Generiert Diagnostic Report im Hintergrund und öffnet Mail.app.

        Läuft in einem Thread — der Main-Thread (rumps/AppKit) blockiert nicht,
        auch wenn sysctl, Disk-Read oder osascript langsam antworten.
        """
        def _run():
            try:
                path = diagnostic.generate_report(self._helper)
            except Exception as exc:
                # K2: kein rumps.notification aus Background-Thread — enqueuen
                self._enqueue_notification(
                    "AudioRouterNow — Diagnostic Report",
                    f"Could not generate report: {exc}",
                )
                return

            mail_ok = diagnostic.open_mail_with_report(path)
            if mail_ok:
                self._enqueue_notification(
                    "AudioRouterNow",
                    "Diagnostic Report ready — Mail is open, "
                    "describe your issue and click Send.",
                )
            else:
                # Fallback: Datei im Finder markieren + Notification mit Anweisung
                diagnostic.reveal_in_finder(path)
                self._enqueue_notification(
                    "AudioRouterNow — Diagnostic Report",
                    f"Saved: {path.name} — Mail could not be opened. "
                    f"Please send the file to {diagnostic.DEVELOPER_EMAIL}",
                )

        threading.Thread(target=_run, name="diagnostic-report", daemon=True).start()

    def _uninstall(self, sender):
        if not first_launch._show_uninstall_confirm():
            return
        # Helper und Routing stoppen
        self._ui_timer.stop()
        # P1: Volume-Listener abmelden (event-driven, kein Poll-Thread mehr)
        try:
            unregister_volume_listener()
        except Exception:
            pass
        # Tranche A: Health-Poll-Thread sauber beenden
        if hasattr(self, '_health_poll_stop'):
            self._health_poll_stop.set()
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
        # P1: Volume-Listener abmelden (event-driven, kein Poll-Thread mehr)
        try:
            unregister_volume_listener()
        except Exception:
            pass
        # Tranche A: Health-Poll-Thread sauber beenden
        if hasattr(self, '_health_poll_stop'):
            self._health_poll_stop.set()
        self._device_manager.stop()
        # Helper sauber beenden — verhindert Orphan-Prozesse.
        # Der Helper stoppt seinen Keep-Alive IOProc im Cleanup selbst.
        self._helper.shutdown()
        save_config(self._config)
        rumps.quit_application()

    # ------------------------------------------------------------------
    # Background-callbacks
    # ------------------------------------------------------------------

    def _on_devices_changed(self, new_devices: list):
        self._device_update_pending = True

    def _enqueue_notification(self, title: str, message: str) -> None:
        """K2: Thread-safe — Notification für den Main-Thread einreihen.
        Background-Threads dürfen rumps.notification nicht direkt aufrufen;
        der UI-Timer (_process_pending_updates) konsumiert die Queue."""
        with self._pending_notifications_lock:
            self._pending_notifications.append((title, message))

    def _process_pending_updates(self, timer):
        # K2: Pending notifications vom Main-Thread senden
        with self._pending_notifications_lock:
            pending = self._pending_notifications[:]
            self._pending_notifications.clear()
        for title, message in pending:
            rumps.notification(title, "", message)

        # K2: Pending reconnect autostart (vom spin-reconnect-Thread gesetzt)
        if self._needs_reconnect_autostart:
            self._needs_reconnect_autostart = False
            self._auto_start_if_configured()

        # P3: coreaudiod-Watchdog-Trip-Dialog (muss auf Main-Thread laufen).
        if self._coreaudiod_spin_detected:
            self._coreaudiod_spin_detected = False
            self._show_coreaudiod_spin_dialog()

        # Device-Liste aktualisieren
        if self._device_update_pending:
            self._device_update_pending = False
            self._build_menu()

        # F8: Status-Update via Status-Cache statt blockierendem Socket-Ping
        # auf dem Main-Thread — der health-poll-Loop (200ms) befuellt den Cache.
        alive_now = self._cached_status(max_age=1.5) is not None
        if alive_now != self._helper_alive:
            old_alive = self._helper_alive
            self._helper_alive = alive_now
            # _update_status_ui() wird unten bei jedem Tick aufgerufen.
            # Helper went from dead → alive (e.g., slow start, or respawn succeeded)
            if alive_now and not old_alive:
                logger.info("Helper jetzt erreichbar — Outputs neu konfigurieren")
                # H4: Healer-Zustand + Trip-Notifications zuruecksetzen — der
                # neue Helper-Prozess kennt die alten Breaker-Trips nicht.
                self._healer.reset_all()
                self._notified_trips.clear()
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

        # Fix-3: Leichtgewichtiger Retry — nur _apply_active_outputs(),
        # KEIN disruptives _auto_start_if_configured() (das würde Default-Output
        # wiederholt neu setzen und laufende Streams unterbrechen).
        if self._needs_reconfigure and alive_now:
            if self._reconfigure_attempts < 5:
                # P8: Cache lesen statt eigenem Socket-Connect. Faellt der Cache
                # leer aus (z.B. Helper gerade erst hochgefahren), gilt das als
                # "noch nicht ready" — der naechste Timer-Tick versucht es erneut.
                status = self._cached_status()
                if status is not None and status.get('ready') is not False:
                    self._reconfigure_attempts += 1
                    logger.info(
                        "Helper SHM bereit — Outputs neu konfigurieren (Retry %d/5)",
                        self._reconfigure_attempts,
                    )
                    if self._apply_active_outputs():
                        self._needs_reconfigure = False
                        self._reconfigure_attempts = 0
            else:
                logger.warning(
                    "Outputs-Retry erschöpft (5/5) — Helper antwortet nicht mit ready"
                )
                self._needs_reconfigure = False
                self._reconfigure_attempts = 0

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

        # P1: Volume-Sync ist jetzt event-driven (CoreAudio Property-Listener,
        # siehe _on_volume_changed). Kein Poll-Thread, kein osascript mehr.

    def _on_volume_changed(self):
        """P1: CoreAudio-Listener-Callback bei Lautstaerke-Aenderung des
        Standard-Ausgabegeraets. Laeuft auf einem CoreAudio-Thread.

        Wenn das Standard-Ausgabegeraet Audio Router ist, hat die Aenderung den
        Driver bereits via SetPropertyData → gVolume → volume_q16 erreicht; es
        ist nichts weiter zu tun. Der Callback dient als Ersatz fuer den
        frueheren osascript-Poll und kann hier fuer UI-Reaktionen genutzt
        werden. Bewusst schlank gehalten (kein Subprozess, kein Blockieren)."""
        try:
            logger.debug("Volume-Aenderung erkannt (event-driven)")
        except Exception:
            pass

    def _health_poll_loop(self):
        """Tranche A: Daemon-Thread für Health-Telemetrie (200ms Intervall).
        Rein observierend — kein Eingriff in den Audio-Pfad."""
        while not self._health_poll_stop.wait(0.2):
            # M5: Startup-Grace — erste Iterationen kein "critical" melden
            # (Helper/SHM sind beim App-Start noch nicht zwingend bereit).
            grace = self._initial_health_grace > 0
            if grace:
                self._initial_health_grace -= 1

            # P3/K1: coreaudiod-Watchdog-Trip ZUERST erkennen — Flag-Datei
            # prüfen, VOR get_status (der Helper kann bei Spin haengen).
            # Nur lesen wenn noch kein Trip gemeldet (Dialog läuft gerade).
            if not self._coreaudiod_spin_detected and _SPIN_FLAG_PATH.exists():
                try:
                    _SPIN_FLAG_PATH.unlink()   # sofort löschen — kein Doppel-Dialog
                except OSError:
                    pass
                self._coreaudiod_spin_detected = True   # Main-Thread zeigt Dialog

            # K1: get_status IMMER aufrufen — kein _helper_alive-Guard davor.
            # Der alte Guard verhinderte, dass der Cache je befuellt wurde,
            # wenn alive=False war (Deadlock: alive haengt am Cache, F8).
            try:
                status = self._helper.get_status(timeout=0.15)
            except Exception as e:
                logger.debug("health_poll_loop get_status Fehler: %s", e)
                status = None

            if status is None:
                # P8: Cache invalidieren — Helper antwortet nicht.
                self._status_cache = None
                self._health_level = "degraded" if grace else "critical"
                continue

            # P8: Frischen Status zentral cachen fuer _compute_status /
            # _process_pending_updates (vermeidet zusaetzliche Socket-Connects).
            self._status_cache = status
            self._status_cache_ts = time.monotonic()

            # H-8: is_audio_router_default() hier im Background-Thread cachen —
            # CoreAudio-Syscall nie auf dem 0.5s-UI-Timer-Tick.
            try:
                self._router_is_default = is_audio_router_default()
            except Exception:
                pass

            # K1: Exception-Guard um health_monitor.update()
            sh = None
            try:
                audio_flowing = int(status.get("ring_frames", 0)) > 0
                sh = self._health_monitor.update(status, audio_flowing)
                level = sh.level
                if grace and level == "critical":
                    level = "degraded"   # M5: Startup-Grace
                self._health_level = level   # GIL-atomare Zuweisung
            except Exception as e:
                logger.debug("health_poll_loop health_monitor Fehler: %s", e)

            if sh is None:
                continue

            # Tranche B: Heilung anstoßen — K1: eigener Exception-Guard
            try:
                prev_tripped = set(self._healer.tripped_outputs())
                self._healer.process(sh)
                # Tripped-Outputs → Notification (einmalig pro Trip-Ereignis)
                # N3: _notified_trips wird in __init__ initialisiert.
                # Breaker, die sich erholt haben: aus dem Notified-Set entfernen
                current_tripped = set(self._healer.tripped_outputs())
                recovered = prev_tripped - current_tripped
                self._notified_trips -= recovered
                # Neue Trips notifizieren
                new_trips = current_tripped - self._notified_trips
                for (uid, ch_off) in new_trips:
                    # M6: Im Breaker gespeicherten Device-Namen nutzen — der
                    # Output kann zum Trip-Zeitpunkt bereits aus sh.outputs
                    # verschwunden sein.
                    dev_name = self._healer.breaker_name(uid, ch_off) or uid
                    self._notified_trips.add((uid, ch_off))
                    # K2: kein rumps.notification aus Background-Thread — enqueuen
                    self._enqueue_notification(
                        "AudioRouterNow — Output unreachable",
                        f"'{dev_name}' Ch{ch_off+1}-{ch_off+2} could not be recovered. "
                        "Reconnect the device or restart via menu.",
                    )
            except Exception as e:
                logger.debug("health_poll_loop healer Fehler: %s", e)

    def _cached_status(self, max_age: float = 1.0) -> dict | None:
        """P8: Liefert den vom health-poll-Loop befuellten Status-Cache, sofern
        nicht aelter als max_age Sekunden. Vermeidet eigene Socket-Connects in
        haeufig aufgerufenen Pfaden (UI-Timer, Status-Berechnung)."""
        cache = self._status_cache
        if cache is None:
            return None
        if (time.monotonic() - self._status_cache_ts) > max_age:
            return None
        return cache

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

        # 0. P10: Treiber-ABI inkompatibel → alles andere zweitrangig.
        if not getattr(self, "_driver_abi_ok", True):
            return ("🔴  Driver update required — click to reinstall", "reinstall_driver")

        # 1. Helper tot → alles andere irrelevant
        if not helper_alive:
            return ("⚠️  Helper not responding — click to restart", "restart_helper")

        # 2. Helper lebt, aber kein Output gewaehlt
        if not outputs_selected:
            return ("🔴  No output selected — pick a device below", None)

        # 3. routed_here pruefen — H-8: Cache aus health-poll-Thread, kein
        #    synchroner CoreAudio-Call auf dem Main-Thread (0.5s-UI-Tick).
        routed_here = self._router_is_default
        if not routed_here:
            return ("🟡  System audio not routed here — click to fix", "switch_audio")

        # 4. audio_flowing — P8: Status aus dem zentralen Cache lesen (vom
        #    health-poll-Loop alle 200ms aktualisiert) statt eigenem Socket-Connect.
        audio_flowing = False
        status = self._cached_status()
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

        # Tranche A: Health-Ampel in den Routing-Status integrieren
        health_level = getattr(self, '_health_level', 'healthy')
        if health_level == "critical":
            icon_override = "🔴"
        elif health_level == "degraded":
            icon_override = "🟡"
        else:
            icon_override = "🟢"

        # Tooltip mit Health-Reason (falls vorhanden)
        sh = getattr(self._health_monitor, 'health', None) if hasattr(self, '_health_monitor') else None
        reason_suffix = ""
        if sh and sh.reasons and health_level != "healthy":
            reason_suffix = f" — {sh.reasons[0]}"

        return (f"{icon_override}  Routing active — {names_str}{reason_suffix}", None)

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
        elif action_key == "reinstall_driver":
            self._reinstall_driver(sender)

    def _reinstall_driver(self, sender):
        """P10: Treiber bei ABI-Mismatch neu installieren (Klick auf Status-Zeile)."""
        try:
            success, error_msg = first_launch.install_driver()
            if success and first_launch.driver_abi_matches():
                self._driver_abi_ok = True
                rumps.alert(
                    title="AudioRouterNow",
                    message="Driver updated. Please restart AudioRouterNow to "
                            "complete the update.",
                    ok="OK",
                )
            else:
                rumps.alert(
                    title="AudioRouterNow — Driver update failed",
                    message=(error_msg or "The driver ABI version still does not match.")
                            + "\n\nPlease reinstall AudioRouterNow.",
                    ok="OK",
                )
        except Exception as e:
            logger.error("Driver-Reinstall fehlgeschlagen: %s", e)

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

    def _show_coreaudiod_spin_dialog(self):
        """P3: Zeigt Recovery-Dialog nach erkanntem coreaudiod CPU-Spin.

        Der Watchdog im Helper hat coreaudiod bei >90% CPU über >5s erkannt,
        alle eigenen IOProcs gestoppt und die Flag-Datei geschrieben.
        Wir bieten dem Nutzer einen kontrollierten Neustart des Audio-Systems an.
        """
        import subprocess
        response = rumps.alert(
            title="AudioRouterNow — Audio System Hung",
            message=(
                "The audio system (coreaudiod) was detected spinning at high CPU.\n\n"
                "AudioRouterNow has stopped its audio outputs to prevent a system freeze.\n\n"
                "Restart the audio system to restore normal operation?"
            ),
            ok="Restart Audio System",
            cancel="Dismiss",
        )
        if response == 1:
            try:
                result = subprocess.run(
                    [
                        "osascript", "-e",
                        'do shell script "launchctl kickstart -k system/com.apple.audio.coreaudiod"'
                        ' with administrator privileges',
                    ],
                    capture_output=True,
                    timeout=30,
                )
                if result.returncode == 0:
                    logger.info("coreaudiod erfolgreich neu gestartet via osascript")
                    rumps.notification(
                        title="AudioRouterNow",
                        subtitle="",
                        message="Audio system restarted. Reconnecting outputs…",
                    )
                    # Outputs nach kurzer Pause neu verbinden.
                    # K2: kein _auto_start_if_configured() aus Background-Thread —
                    # Flag setzen, der UI-Timer ruft es auf dem Main-Thread auf.
                    def _reconnect():
                        import time as _time
                        _time.sleep(3.0)
                        self._needs_reconnect_autostart = True
                    threading.Thread(target=_reconnect, name="spin-reconnect", daemon=True).start()
                else:
                    err = result.stderr.decode(errors="replace").strip()
                    logger.warning("coreaudiod-Neustart fehlgeschlagen: %s", err)
                    rumps.alert(
                        title="AudioRouterNow — Restart Failed",
                        message="Could not restart the audio system.\n\n"
                                "Please restart your Mac if the issue persists.",
                        ok="OK",
                    )
            except Exception as e:
                logger.error("coreaudiod-Neustart Exception: %s", e)

    def _handle_media_key(self, event):
        """
        Interceptiert macOS Media Keys (Volume Up/Down/Mute).

        Keyboard-Volume-Keys senden NSSystemDefined-Events mit subtype 8.
        Sie erreichen virtuelle HAL-Devices nicht direkt — dieser Handler
        verarbeitet sie manuell: liest den aktuellen Output-Volume, passt
        ihn an und setzt ihn direkt via CoreAudio (P1 — was den Driver's
        SetPropertyData korrekt triggert und volume_q16 im SHM aktualisiert).

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

            # M4: Key-Code in die Volume-Queue legen — der Event-Handler kehrt
            # sofort zurueck, der Worker-Thread serialisiert die Aenderungen
            # (kein Thread pro Tastendruck mehr → keine Read/Write-Races bei
            # schnellen Key-Repeats).
            self._volume_queue.put(key_code)
        except Exception as exc:
            logger.debug(f"_handle_media_key Fehler: {exc}")

    def _volume_worker_loop(self):
        """M4: Worker-Thread — verarbeitet Media-Key-Volume-Aenderungen
        seriell aus der Queue. None als Sentinel beendet den Loop."""
        while True:
            key_code = self._volume_queue.get()
            if key_code is None:
                break
            try:
                self._apply_media_key_volume(key_code)
            except Exception as exc:
                logger.debug("Volume-Worker Fehler: %s", exc)

    @staticmethod
    def _apply_media_key_volume(kc: int) -> None:
        """P1/M4: Volume direkt via CoreAudio setzen (kein osascript-Subprozess)."""
        try:
            current = get_default_output_volume()  # 0.0–1.0
        except Exception:
            return

        STEP = 1.0 / 15.0  # ~15 Stufen wie macOS-Standard
        if kc == 3:    # Volume Up (NX_KEYTYPE_SOUND_UP)
            new_vol = min(1.0, current + STEP)
            set_default_output_volume(new_vol)
        elif kc == 2:  # Volume Down (NX_KEYTYPE_SOUND_DOWN)
            new_vol = max(0.0, current - STEP)
            set_default_output_volume(new_vol)
        elif kc == 7:  # Mute (NX_KEYTYPE_MUTE) — toggeln
            # H1: Echten Mute-Zustand lesen statt aus der Lautstaerke zu raten —
            # bei Volume>0 UND gemutetem Device toggelte der alte Code falsch.
            muted_now = get_default_output_muted()
            set_muted(not muted_now)
            new_vol = current if muted_now else 0.0
        else:
            return
        logger.debug("Media Key: volume %.0f%% → %.0f%%",
                     current * 100.0, new_vol * 100.0)

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

    def _apply_active_outputs(self) -> bool:
        """
        Sendet die aktuelle Output-Konfiguration an den Helper.
        Gibt True bei Erfolg zurück, False wenn Helper noch nicht bereit (not_ready).
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
            return False
        self._needs_reconfigure = False
        if resp is None:
            logger.warning("Helper antwortet nicht — bitte prüfen")
        else:
            logger.info(f"Outputs an Helper gesendet ({len(specs)}): ok={resp.get('ok')}")
            # P2: Menue-Zustand mit den TATSAECHLICH aktiven Outputs des Helpers
            # abgleichen. Wenn z.B. ein Output nicht startbar war (Device weg,
            # SR-Mismatch), korrigieren wir die interne Auswahl, damit das Menue
            # nicht "aktiv" anzeigt was real nicht laeuft.
            self._reconcile_active_outputs(resp)

        # Donation-Hint Trigger bei erstem erfolgreichen Setup
        if specs and not self._config.donation_hint_shown:
            self._config.donation_hint_shown = True
            save_config(self._config)
            self._donation_hint_at = time.monotonic() + DONATION_HINT_DELAY

        return True

    def _reconcile_active_outputs(self, resp: dict) -> None:
        """P2: Gleicht die interne Auswahl (_active_device_names / _device_offsets)
        mit den TATSAECHLICH aktiven Outputs des Helpers (resp['active']) ab.

        Der Helper ist die Autoritaet darueber, was real laeuft: konnte ein
        gewuenschter Output nicht gestartet werden (Device verschwunden,
        IOProc-Fehler), taucht er nicht in 'active' auf. Bei Divergenz korrigieren
        wir die interne Auswahl, persistieren sie und bauen das Menue auf dem
        Main-Thread neu (via _device_update_pending, das der UI-Timer konsumiert).
        """
        active = resp.get('active')
        if not isinstance(active, list):
            return

        # Tatsaechlich aktive (uid, ch_offset)-Tupel + uid→name Mapping vom Helper.
        actual: set[tuple[str, int]] = set()
        uid_to_name: dict[str, str] = {}
        for entry in active:
            try:
                uid = str(entry['uid'])
                off = int(entry['ch_offset'])
            except (KeyError, TypeError, ValueError):
                continue
            actual.add((uid, off))
            name = entry.get('name')
            if name:
                uid_to_name[uid] = str(name)

        # Erwartete (uid, ch_offset)-Tupel aus dem internen Zustand bilden.
        devices = self._device_manager.get_output_devices()
        name_to_uid = {d.name: d.uid for d in devices}
        expected: set[tuple[str, int]] = set()
        for dev_name in self._active_device_names:
            uid = name_to_uid.get(dev_name)
            if not uid:
                continue
            for off in self._device_offsets.get(dev_name, [0]):
                expected.add((uid, int(off)))

        if actual == expected:
            self._reconcile_drift_count = 0   # H4: Uebereinstimmung — Zaehler reset
            return  # Kein Drift — nichts zu tun.

        # H4: Grace-Period — Drift muss 3 Mal in Folge bestehen, bevor wir
        # persistieren und die UI anpassen (transiente Zustaende direkt nach
        # set_outputs/Device-Reinit sollen die Config nicht zerstoeren).
        self._reconcile_drift_count += 1
        if self._reconcile_drift_count < 3:
            logger.debug("P2/H4: Output-Drift erkannt (%d/3) — warte auf Bestaetigung",
                         self._reconcile_drift_count)
            return
        self._reconcile_drift_count = 0

        logger.info("P2: Output-Drift erkannt — erwartet=%s, tatsaechlich=%s — korrigiere",
                    sorted(expected), sorted(actual))

        # Internen Zustand auf die tatsaechlich aktiven Outputs zurueckbauen.
        new_names: set[str] = set()
        new_offsets: Dict[str, List[int]] = {}
        # uid→name auch aus dem aktuellen Device-Scan ergaenzen (fuer Namen, die
        # der Helper nicht mitgeliefert hat).
        uid_to_name_scan = {d.uid: d.name for d in devices}
        for (uid, off) in actual:
            name = uid_to_name.get(uid) or uid_to_name_scan.get(uid)
            if not name:
                # Unbekanntes Device — koennen wir nicht im Menue darstellen, ueberspringen.
                continue
            new_names.add(name)
            new_offsets.setdefault(name, []).append(off)

        for n in new_offsets:
            new_offsets[n] = sorted(set(new_offsets[n]))

        self._active_device_names = new_names
        self._device_offsets = new_offsets

        # Persistieren.
        self._config.output_device_names = list(self._active_device_names)
        self._config.output_device_offsets = {
            k: list(v) for k, v in self._device_offsets.items()
        }
        save_config(self._config)

        # Menue auf dem Main-Thread neu bauen (UI-Timer konsumiert das Flag).
        self._device_update_pending = True

    def _auto_start_if_configured(self):
        """
        Stellt beim App-Start sicher dass Audio Router aktiv läuft.

        Reihenfolge (Fix-4):
          1. Keep-Alive IOProc starten → gDeviceIsRunning=1 BEVOR Default-Switch
          2. Default-Output idempotent auf Audio Router setzen (nur wenn nötig)
          3. Beste Sample-Rate anwenden
          4. Helper-Outputs konfigurieren

        Durch Schritt 1 findet Apple Music/Spotify beim Default-Switch (Schritt 2)
        ein bereits laufendes Device vor und öffnet seinen Stream sofort.
        """
        if not self._active_device_names:
            logger.info("Auto-start: keine gespeicherten Devices")
            self._update_status_ui()
            return

        logger.info("Auto-start: lade Outputs %s", ", ".join(self._active_device_names))

        # Keep-Alive wird vom C-Helper verwaltet (ab v2.6) — kein Python-ctypes-Callback.
        # Default-Output idempotent setzen (nur wenn nötig).
        if not is_audio_router_default():
            set_default_output_device(AUDIO_ROUTER_DEVICE_NAME)
            set_default_system_output_device(AUDIO_ROUTER_DEVICE_NAME)
        else:
            logger.debug("Auto-start: Audio Router bereits Default — kein Switch nötig")

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

            # Keep-Alive wird vom C-Helper verwaltet — kein Python-ctypes-Thread nötig.

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


def _ensure_secure_base_dir() -> None:
    """MC-5/P11: ~/.audiorouter MUSS mode=0700 haben — C-Helper prüft das."""
    _LOCK_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(_LOCK_DIR, 0o700)


def _acquire_instance_lock() -> None:
    global _lock_fd
    _ensure_secure_base_dir()
    try:
        # F9: Lock-File via os.open() + O_CREAT mit mode=0600 — kein "w"-Open,
        # das das Lock-File einer laufenden Instanz vor dem flock leeren würde.
        fd = os.open(str(_LOCK_FILE), os.O_RDWR | os.O_CREAT, 0o600)
        _lock_fd = os.fdopen(fd, "r+")
        fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        _lock_fd.seek(0)
        _lock_fd.truncate()
        _lock_fd.write(str(os.getpid()))
        _lock_fd.flush()
    except IOError:
        rumps.alert(
            title="AudioRouterNow",
            message="AudioRouterNow is already running. Check the menu bar icon.",
        )
        sys.exit(0)


def _setup_file_logging() -> None:
    _ensure_secure_base_dir()
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
