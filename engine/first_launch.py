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


def install_launchd_agent() -> tuple[bool, str]:
    """
    Installs the Helper launchd User Agent — no administrator privileges required.

    Steps:
    1. Create ~/Library/LaunchAgents/ if it does not exist.
    2. Copy the plist from the installed driver bundle into LaunchAgents/.
    3. Bootstrap the agent with `launchctl bootstrap gui/<uid> <plist>`.
       Falls back to `launchctl load <plist>` if bootstrap fails.

    Returns:
        (True, "")            on success.
        (False, error_message) on failure.
    """
    source = _get_launchd_plist_source()

    if not source.exists():
        msg = (
            f"LaunchAgent plist not found in driver bundle: {source}\n"
            "The driver may not be fully installed yet."
        )
        logger.warning(msg)
        return False, msg

    try:
        LAUNCHD_AGENTS_DIR.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        msg = f"Failed to create LaunchAgents directory: {exc}"
        logger.warning(msg)
        return False, msg

    try:
        shutil.copy2(source, LAUNCHD_INSTALL_PATH)
        logger.info("LaunchAgent plist copied to: %s", LAUNCHD_INSTALL_PATH)
    except OSError as exc:
        msg = f"Failed to copy LaunchAgent plist: {exc}"
        logger.warning(msg)
        return False, msg

    uid = os.getuid()

    # Try modern bootstrap API first (macOS 11+)
    try:
        result = subprocess.run(
            ["launchctl", "bootstrap", f"gui/{uid}", str(LAUNCHD_INSTALL_PATH)],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0:
            logger.info("LaunchAgent bootstrapped successfully (gui/%d).", uid)
            return True, ""
        logger.warning(
            "launchctl bootstrap failed (rc=%d): %s — trying legacy load.",
            result.returncode,
            result.stderr.strip(),
        )
    except Exception as exc:
        logger.warning("launchctl bootstrap raised an exception: %s — trying legacy load.", exc)

    # Fallback: legacy load (macOS 10.x compatibility)
    try:
        result = subprocess.run(
            ["launchctl", "load", str(LAUNCHD_INSTALL_PATH)],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0:
            logger.info("LaunchAgent loaded via legacy launchctl load.")
            return True, ""
        msg = f"launchctl load failed (rc={result.returncode}): {result.stderr.strip()}"
        logger.warning(msg)
        return False, msg
    except Exception as exc:
        msg = f"launchctl load raised an exception: {exc}"
        logger.warning(msg)
        return False, msg


def unload_launchd_agent() -> None:
    """
    Unloads and removes the Helper launchd User Agent.

    Called during a clean uninstall. All errors are silently ignored so that
    the uninstall path never fails because of a launchd edge case.
    """
    uid = os.getuid()

    # Attempt modern bootout first; ignore return code
    try:
        subprocess.run(
            ["launchctl", "bootout", f"gui/{uid}", str(LAUNCHD_INSTALL_PATH)],
            capture_output=True,
            timeout=15,
        )
    except Exception:
        # Legacy fallback: launchctl unload
        try:
            subprocess.run(
                ["launchctl", "unload", str(LAUNCHD_INSTALL_PATH)],
                capture_output=True,
                timeout=15,
            )
        except Exception:
            pass

    try:
        if LAUNCHD_INSTALL_PATH.exists():
            LAUNCHD_INSTALL_PATH.unlink()
            logger.info("LaunchAgent plist removed: %s", LAUNCHD_INSTALL_PATH)
    except OSError as exc:
        logger.warning("Could not remove LaunchAgent plist: %s", exc)


def _check_and_install_launchd_agent() -> None:
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
        logger.info("Driver already installed — no action needed.")
        # Clean up any launchd agent — app manages helper directly
        _check_and_install_launchd_agent()
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
    _check_and_install_launchd_agent()

    return True


# ---------------------------------------------------------------------------
# Helper functions — native macOS dialogs via osascript
# ---------------------------------------------------------------------------

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
