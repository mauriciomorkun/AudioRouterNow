"""
first_launch.py — HAL driver check and automatic installation on first launch.

On app startup this module checks whether AudioRouterNow.driver is already
installed at /Library/Audio/Plug-Ins/HAL/.

If not: a one-time macOS password prompt via AppleScript installs the driver
and restarts coreaudiod so Core Audio recognises the new device.
"""

import logging
import os
import shutil
import subprocess
import sys
from pathlib import Path

logger = logging.getLogger(__name__)

DRIVER_NAME = "AudioRouterNow.driver"
DRIVER_INSTALL_PATH = Path("/Library/Audio/Plug-Ins/HAL") / DRIVER_NAME

LAUNCHD_PLIST_NAME  = "com.audiorouter.now.helper.plist"
LAUNCHD_LABEL       = "com.audiorouter.now.helper"
LAUNCHD_AGENTS_DIR  = Path.home() / "Library" / "LaunchAgents"
LAUNCHD_INSTALL_PATH = LAUNCHD_AGENTS_DIR / LAUNCHD_PLIST_NAME

# P10: Vom App-Build erwartete Treiber-ABI-Version. MUSS mit kDriverABIVersion
# in driver/src/AudioRouterNowDriver.c uebereinstimmen. Bei jeder ABI-relevanten
# Aenderung (shared_ring.h-Layout, Property-Modell) BEIDE Stellen hochzaehlen.
APP_EXPECTED_ABI_VERSION = 1
ABI_VERSION_FILE_NAME = "abi_version"


def _read_abi_version_file(bundle_path: Path) -> int | None:
    """P10: Liest Contents/Resources/abi_version aus einem .driver-Bundle.
    Gibt die ABI-Version als int zurueck, oder None wenn nicht lesbar/parsebar
    (z.B. alter Treiber ohne abi_version-Datei)."""
    f = bundle_path / "Contents" / "Resources" / ABI_VERSION_FILE_NAME
    try:
        txt = f.read_text(encoding="ascii").strip()
        return int(txt)
    except (OSError, ValueError):
        return None


def get_installed_driver_abi_version() -> int | None:
    """P10: ABI-Version des aktuell INSTALLIERTEN Treibers (oder None)."""
    return _read_abi_version_file(DRIVER_INSTALL_PATH)


def driver_abi_matches() -> bool:
    """P10: True, wenn der installierte Treiber ABI-kompatibel mit dieser App ist.

    Fehlt die abi_version-Datei (alter Treiber vor P10), gilt das als Mismatch —
    der Treiber sollte dann neu installiert werden, damit beide Seiten dieselbe
    shared_ring.h-ABI verwenden."""
    installed = get_installed_driver_abi_version()
    if installed is None:
        return False
    return installed == APP_EXPECTED_ABI_VERSION


def _get_driver_source_path() -> Path:
    """
    Returns the path to the .driver bundle — depending on whether the app is
    frozen (PyInstaller) or running in development mode.

    PyInstaller (frozen):
        sys._MEIPASS contains all embedded resources.
        The driver bundle lives directly inside as AudioRouterNow.driver/.

    Development:
        Relative to the engine/ directory: ../driver/build/AudioRouterNow.driver
    """
    if getattr(sys, "frozen", False):
        meipass = Path(sys._MEIPASS)  # type: ignore[attr-defined]
        return meipass / DRIVER_NAME
    else:
        engine_dir = Path(__file__).resolve().parent
        return engine_dir.parent / "driver" / "build" / DRIVER_NAME


def is_driver_installed() -> bool:
    """
    Checks whether AudioRouterNow.driver exists at /Library/Audio/Plug-Ins/HAL/.

    Returns:
        True if the .driver bundle is present at the target path.
    """
    installed = DRIVER_INSTALL_PATH.exists()
    logger.debug(
        "Driver check: %s → %s",
        DRIVER_INSTALL_PATH,
        "present" if installed else "not found",
    )
    return installed


def install_driver() -> tuple[bool, str]:
    """
    Installs the HAL driver with administrator privileges via AppleScript.

    The command is run via 'osascript -e'. macOS shows the user a password
    dialog. After a successful install, coreaudiod is restarted so Core Audio
    recognises the new driver.

    Returns:
        (True, "") on success.
        (False, error_message) on failure.
    """
    source = _get_driver_source_path()

    if not source.exists():
        msg = (
            f"Driver source not found: {source}\n"
            "Please reinstall AudioRouterNow."
        )
        logger.error(msg)
        return False, msg

    # AppleScript: cp -r copies the entire .driver bundle (directory),
    # killall coreaudiod restarts the audio daemon.
    # '|| true' prevents an exit-code error if coreaudiod is already restarting.
    shell_cmd = (
        f"cp -r '{source}' '{DRIVER_INSTALL_PATH}' "
        f"&& killall coreaudiod || true"
    )

    applescript = (
        f'do shell script "{shell_cmd}" with administrator privileges'
    )

    logger.info("Starting driver installation via AppleScript...")
    logger.debug("AppleScript: %s", applescript)

    try:
        result = subprocess.run(
            ["osascript", "-e", applescript],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except subprocess.TimeoutExpired:
        msg = "Timeout during driver installation (60s)."
        logger.error(msg)
        return False, msg
    except FileNotFoundError:
        msg = "osascript not found — is this a Mac?"
        logger.error(msg)
        return False, msg

    if result.returncode != 0:
        stderr = result.stderr.strip()
        # AppleScript error code -128 = user cancelled the password prompt
        if "-128" in stderr:
            msg = "Installation cancelled — password was not entered."
        else:
            msg = f"Driver installation failed:\n{stderr}"
        logger.error("Installation failed (rc=%d): %s", result.returncode, stderr)
        return False, msg

    logger.info("Driver successfully installed at: %s", DRIVER_INSTALL_PATH)

    # Sign the installed driver (ad-hoc, best-effort)
    logger.info("Signing installed driver (ad-hoc)...")
    subprocess.run(
        ["codesign", "--force", "--deep", "--sign", "-", str(DRIVER_INSTALL_PATH)],
        check=False,
        capture_output=True,
    )

    return True, ""


def _get_launchd_plist_source() -> Path:
    """
    Returns the path to the launchd plist bundled inside the INSTALLED driver.

    The plist lives at:
        /Library/Audio/Plug-Ins/HAL/AudioRouterNow.driver/Contents/Resources/
            com.audiorouter.now.helper.plist
    """
    return DRIVER_INSTALL_PATH / "Contents" / "Resources" / LAUNCHD_PLIST_NAME


def is_launchd_agent_installed() -> bool:
    """
    Checks whether the launchd plist has been copied to ~/Library/LaunchAgents/.

    Returns:
        True if LAUNCHD_INSTALL_PATH exists on disk.
    """
    installed = LAUNCHD_INSTALL_PATH.exists()
    logger.debug(
        "LaunchAgent check: %s → %s",
        LAUNCHD_INSTALL_PATH,
        "present" if installed else "not found",
    )
    return installed


def _ensure_no_launchd_agent() -> None:
    """
    Ensures the Helper is NOT managed by launchd — the app manages the helper
    lifecycle directly via ensure_running().

    If a launchd agent is registered or the plist exists, it is removed to
    prevent dual-helper conflicts (two helpers splitting the ring buffer).
    """
    uid = os.getuid()

    # If launchd has the service registered, unload and disable it
    try:
        list_result = subprocess.run(
            ["launchctl", "list", LAUNCHD_LABEL],
            capture_output=True, text=True, timeout=10,
        )
        if list_result.returncode == 0:
            logger.info("LaunchAgent '%s' is registered — disabling to prevent dual-helper conflict.", LAUNCHD_LABEL)
            subprocess.run(
                ["launchctl", "bootout", f"gui/{uid}", str(LAUNCHD_INSTALL_PATH)],
                capture_output=True, timeout=15,
            )
    except Exception as exc:
        logger.debug("launchctl list/bootout: %s", exc)

    # Remove plist from LaunchAgents to prevent re-registration on next login
    if LAUNCHD_INSTALL_PATH.exists():
        try:
            LAUNCHD_INSTALL_PATH.unlink()
            logger.info("LaunchAgent plist removed: %s (app manages helper directly)", LAUNCHD_INSTALL_PATH)
        except OSError as exc:
            logger.warning("Could not remove LaunchAgent plist: %s", exc)


def check_and_install() -> bool:
    """
    Main entry point: checks whether the driver is installed and installs it
    if needed.

    Flow:
    1. Driver present? → True (return immediately)
    2. Not present → call install_driver()
    3. Error → show error dialog → return False
    4. Success → True

    Returns:
        True if the driver is ready (already present or just installed).
        False if the user cancelled the installation or an error occurred.
    """
    if is_driver_installed():
        # P10: ABI-Version pruefen. Stimmt sie nicht (oder fehlt sie, alter
        # Treiber), den Treiber neu installieren — sonst koennten App und
        # Treiber inkompatible shared_ring.h-Layouts verwenden.
        if driver_abi_matches():
            logger.info("Driver already installed and ABI-compatible — no action needed.")
            _ensure_no_launchd_agent()
            return True

        installed_abi = get_installed_driver_abi_version()
        logger.warning(
            "Driver ABI mismatch: installed=%s, expected=%d — reinstalling driver.",
            installed_abi, APP_EXPECTED_ABI_VERSION,
        )
        _show_install_dialog()
        success, error_msg = install_driver()
        if not success:
            _show_error_dialog(error_msg)
            return False
        if not driver_abi_matches():
            _show_error_dialog(
                "The driver was reinstalled but the ABI version still does not match.\n\n"
                f"Installed: {get_installed_driver_abi_version()}, "
                f"expected: {APP_EXPECTED_ABI_VERSION}.\n\n"
                "Please restart AudioRouterNow."
            )
            return False
        logger.info("Driver reinstalled — ABI now matches.")
        _ensure_no_launchd_agent()
        return True

    logger.info("Driver not found — starting installation.")

    # rumps is not yet initialised when check_and_install() is called,
    # so we use subprocess + osascript for the info dialog.
    _show_install_dialog()

    success, error_msg = install_driver()

    if not success:
        _show_error_dialog(error_msg)
        return False

    # Safety check: is the driver actually there now?
    if not is_driver_installed():
        msg = (
            "The driver was installed but is missing at the expected path:\n"
            f"{DRIVER_INSTALL_PATH}\n\n"
            "Please restart AudioRouterNow."
        )
        _show_error_dialog(msg)
        return False

    logger.info("Driver installation completed and verified.")

    # Clean up any launchd agent — app manages helper directly
    _ensure_no_launchd_agent()

    return True


# ---------------------------------------------------------------------------
# Helper functions — native macOS dialogs via osascript
# ---------------------------------------------------------------------------

def uninstall_all() -> tuple[bool, str]:
    """
    Removes all AudioRouterNow components — the inverse of install_driver().

    Order (critical):
      1. Stop helper daemon (helper_client.shutdown, or pkill fallback; max 2s grace)
      2. Deactivate LaunchAgent (reuses _ensure_no_launchd_agent)
      3. Remove POSIX shared memory segment (/audiorouter_shm)
      4. Remove HAL driver + killall coreaudiod (requires admin via osascript)
      5. Remove config dir (~/.audiorouter/)
      6. Remove logs (~/Library/Logs/AudioRouterNow/)
      7. Remove helper log (/tmp/audiorouter.helper.log)
      8. Remove control socket (/tmp/audiorouter.config.sock)

    Individual step failures are logged and do NOT abort the whole uninstall.
    Only step 4 (admin dialog) lets the user cancel.

    Returns:
        (True, success_message) on completion (driver removed or already absent).
        (False, "Cancelled by user") if the user cancelled the admin prompt.
    """
    # Imports are local to avoid a hard import cycle at module load time and to
    # keep the install path lightweight.
    import time

    try:
        from config import CONFIG_DIR
    except Exception:
        CONFIG_DIR = Path.home() / ".audiorouter"

    try:
        from helper_client import CONFIG_SOCKET
    except Exception:
        CONFIG_SOCKET = "/tmp/audiorouter.config.sock"

    logger.info("Starting full uninstall of AudioRouterNow...")

    # --- Step 1: Stop the helper daemon -------------------------------------
    try:
        from helper_client import HelperClient
        client = HelperClient()
        client.shutdown()
        logger.info("Uninstall step 1: helper shutdown sent.")
    except Exception as exc:
        logger.warning("Uninstall step 1: helper shutdown failed: %s", exc)

    # Give the helper a moment to exit, then force-kill any stragglers.
    time.sleep(2.0)
    try:
        subprocess.run(
            ["pkill", "-f", "AudioRouterNowHelper"],
            capture_output=True,
            timeout=5,
        )
        logger.info("Uninstall step 1: pkill AudioRouterNowHelper done.")
    except Exception as exc:
        logger.warning("Uninstall step 1: pkill failed: %s", exc)

    # --- Step 2: Deactivate LaunchAgent -------------------------------------
    try:
        _ensure_no_launchd_agent()
        logger.info("Uninstall step 2: LaunchAgent deactivated.")
    except Exception as exc:
        logger.warning("Uninstall step 2: LaunchAgent deactivation failed: %s", exc)

    # --- Step 3: Remove POSIX shared memory segment -------------------------
    # /audiorouter_shm — see helper/shared_ring.h (ARN_SHM_NAME).
    # Note: on macOS shm_unlink() of a missing segment raises OSError with
    # errno EINVAL (22) or ENOENT (2), not FileNotFoundError — treat both as
    # "already absent" so we don't emit a misleading warning.
    import errno as _errno
    try:
        try:
            import _posixshmem  # type: ignore[import-not-found]
            try:
                _posixshmem.shm_unlink("/audiorouter_shm")
                logger.info("Uninstall step 3: SHM segment unlinked (/audiorouter_shm).")
            except OSError as oexc:
                if oexc.errno in (_errno.ENOENT, _errno.EINVAL):
                    logger.info("Uninstall step 3: SHM segment already absent.")
                else:
                    raise
        except (ImportError, ModuleNotFoundError):
            # Fallback: multiprocessing's shared_memory uses the same syscall.
            from multiprocessing import shared_memory
            try:
                shm = shared_memory.SharedMemory(name="audiorouter_shm")
                shm.close()
                shm.unlink()
                logger.info("Uninstall step 3: SHM segment unlinked via shared_memory.")
            except (FileNotFoundError, OSError):
                logger.info("Uninstall step 3: SHM segment already absent.")
    except Exception as exc:
        logger.warning("Uninstall step 3: SHM unlink failed: %s", exc)

    # --- Step 4: Remove HAL driver (requires admin) -------------------------
    if DRIVER_INSTALL_PATH.exists():
        shell_cmd = (
            f"rm -rf '{DRIVER_INSTALL_PATH}' "
            f"&& killall coreaudiod || true"
        )
        applescript = (
            f'do shell script "{shell_cmd}" with administrator privileges'
        )
        logger.info("Uninstall step 4: removing HAL driver via AppleScript...")
        try:
            result = subprocess.run(
                ["osascript", "-e", applescript],
                capture_output=True,
                text=True,
                timeout=60,
            )
        except subprocess.TimeoutExpired:
            logger.error("Uninstall step 4: timeout removing driver (60s).")
            return False, "Timeout while removing the audio driver (60s)."
        except FileNotFoundError:
            logger.error("Uninstall step 4: osascript not found.")
            return False, "osascript not found — is this a Mac?"

        if result.returncode != 0:
            stderr = result.stderr.strip()
            # AppleScript error code -128 = user cancelled the password prompt
            if "-128" in stderr:
                logger.info("Uninstall step 4: cancelled by user at admin prompt.")
                return False, "Cancelled by user"
            logger.error("Uninstall step 4: driver removal failed: %s", stderr)
            return False, f"Could not remove the audio driver:\n{stderr}"

        logger.info("Uninstall step 4: HAL driver removed.")
    else:
        logger.info("Uninstall step 4: HAL driver already absent — skipping.")

    # --- Step 5: Remove config directory ------------------------------------
    try:
        shutil.rmtree(CONFIG_DIR, ignore_errors=True)
        logger.info("Uninstall step 5: config dir removed (%s).", CONFIG_DIR)
    except Exception as exc:
        logger.warning("Uninstall step 5: config dir removal failed: %s", exc)

    # --- Step 6: Remove logs ------------------------------------------------
    try:
        logs_dir = Path.home() / "Library" / "Logs" / "AudioRouterNow"
        shutil.rmtree(logs_dir, ignore_errors=True)
        logger.info("Uninstall step 6: logs dir removed (%s).", logs_dir)
    except Exception as exc:
        logger.warning("Uninstall step 6: logs dir removal failed: %s", exc)

    # --- Step 7: Remove helper log ------------------------------------------
    try:
        helper_log = Path("/tmp/audiorouter.helper.log")
        if helper_log.exists():
            helper_log.unlink()
            logger.info("Uninstall step 7: helper log removed.")
    except Exception as exc:
        logger.warning("Uninstall step 7: helper log removal failed: %s", exc)

    # --- Step 8: Remove control socket --------------------------------------
    try:
        socket_path = Path(CONFIG_SOCKET)
        if socket_path.exists():
            socket_path.unlink()
            logger.info("Uninstall step 8: control socket removed (%s).", socket_path)
    except Exception as exc:
        logger.warning("Uninstall step 8: control socket removal failed: %s", exc)

    logger.info("Uninstall complete.")
    return True, "All AudioRouterNow components removed."


# ---------------------------------------------------------------------------
# Helper functions — native macOS dialogs via osascript
# ---------------------------------------------------------------------------

def _show_uninstall_confirm() -> bool:
    """
    Shows a confirmation dialog before the uninstall runs.

    Returns:
        True  if the user clicked "Uninstall".
        False if the user clicked "Cancel" or the dialog failed.
    """
    script = (
        'display dialog "Are you sure you want to uninstall AudioRouterNow?\\n\\n'
        'This will remove the audio driver, helper daemon and all settings." '
        'buttons {"Cancel", "Uninstall"} default button "Cancel" '
        'cancel button "Cancel" '
        'with title "AudioRouterNow — Uninstall" '
        'with icon caution'
    )
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except Exception as exc:
        logger.warning("Uninstall confirm dialog failed: %s", exc)
        return False

    # rc != 0 → user pressed Cancel (osascript error -128) or dialog error
    if result.returncode != 0:
        return False
    return "Uninstall" in result.stdout


def _show_install_dialog() -> None:
    """
    Shows an info dialog before the password prompt appears so the user
    knows why macOS is asking for their password.
    """
    script = (
        'display dialog "AudioRouterNow needs to install the audio driver.\\n\\n'
        "macOS will ask for your password — "
        'this is a one-time step." '
        'buttons {"OK"} default button "OK" '
        'with title "AudioRouterNow — Driver Installation" '
        'with icon note'
    )
    try:
        subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            timeout=30,
        )
    except Exception:
        # Dialog failure is non-critical — installation proceeds regardless
        pass


def _show_error_dialog(message: str) -> None:
    """
    Shows an error dialog with the given message.
    Called when installation fails.
    """
    safe_message = message.replace('"', "'").replace("\n", "\\n")
    script = (
        f'display dialog "{safe_message}" '
        'buttons {"OK"} default button "OK" '
        'with title "AudioRouterNow — Error" '
        'with icon stop'
    )
    try:
        subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            timeout=30,
        )
    except Exception:
        pass
