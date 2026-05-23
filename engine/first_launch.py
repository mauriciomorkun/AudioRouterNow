"""
first_launch.py — HAL driver check and automatic installation on first launch.

On app startup this module checks whether AudioRouterNow.driver is already
installed at /Library/Audio/Plug-Ins/HAL/.

If not: a one-time macOS password prompt via AppleScript installs the driver
and restarts coreaudiod so Core Audio recognises the new device.
"""

import logging
import os
import subprocess
import sys
from pathlib import Path

logger = logging.getLogger(__name__)

DRIVER_NAME = "AudioRouterNow.driver"
DRIVER_INSTALL_PATH = Path("/Library/Audio/Plug-Ins/HAL") / DRIVER_NAME


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
