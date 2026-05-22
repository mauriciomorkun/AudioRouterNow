"""
first_launch.py — HAL-Treiber-Prüfung und automatische Installation beim ersten Start.

Beim Start der App prüft dieses Modul ob AudioRouterNow.driver bereits unter
/Library/Audio/Plug-Ins/HAL/ installiert ist.

Falls nicht: einmalige macOS-Passwortabfrage via AppleScript → Treiber wird
installiert → coreaudiod wird neu gestartet.
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
    Gibt den Pfad zum .driver Bundle zurück — je nachdem ob frozen (PyInstaller)
    oder im Development-Modus.

    PyInstaller (frozen):
        sys._MEIPASS enthält alle eingebetteten Ressourcen.
        Das driver Bundle liegt direkt darin als AudioRouterNow.driver/.

    Development:
        Relativ zum engine/-Verzeichnis: ../driver/build/AudioRouterNow.driver
    """
    if getattr(sys, "frozen", False):
        # PyInstaller-Bundle: _MEIPASS ist das temporäre Entpack-Verzeichnis
        meipass = Path(sys._MEIPASS)  # type: ignore[attr-defined]
        return meipass / DRIVER_NAME
    else:
        # Development: engine/ liegt neben driver/
        engine_dir = Path(__file__).resolve().parent
        return engine_dir.parent / "driver" / "build" / DRIVER_NAME


def is_driver_installed() -> bool:
    """
    Prüft ob AudioRouterNow.driver in /Library/Audio/Plug-Ins/HAL/ existiert.

    Returns:
        True wenn das .driver Bundle am Zielpfad vorhanden ist.
    """
    installed = DRIVER_INSTALL_PATH.exists()
    logger.debug(
        "Treiber-Check: %s → %s",
        DRIVER_INSTALL_PATH,
        "vorhanden" if installed else "nicht vorhanden",
    )
    return installed


def install_driver() -> tuple[bool, str]:
    """
    Installiert den HAL-Treiber mit Administrator-Rechten via AppleScript.

    Der Befehl wird über 'osascript -e' ausgeführt. macOS zeigt dem User
    einen Passwort-Dialog. Nach erfolgreichem Install wird coreaudiod
    neu gestartet damit Core Audio den neuen Treiber erkennt.

    Returns:
        (True, "") bei Erfolg.
        (False, fehlermeldung) bei Fehler.
    """
    source = _get_driver_source_path()

    if not source.exists():
        msg = (
            f"Treiber-Quelldatei nicht gefunden: {source}\n"
            "Bitte AudioRouterNow neu installieren."
        )
        logger.error(msg)
        return False, msg

    # AppleScript: cp -r kopiert das gesamte .driver Bundle (Verzeichnis),
    # killall coreaudiod startet den Audio-Daemon neu.
    # '|| true' verhindert einen Exit-Code-Fehler falls coreaudiod
    # sich gerade selbst neu startet.
    shell_cmd = (
        f"cp -r '{source}' '{DRIVER_INSTALL_PATH}' "
        f"&& killall coreaudiod || true"
    )

    applescript = (
        f'do shell script "{shell_cmd}" with administrator privileges'
    )

    logger.info("Starte Treiber-Installation via AppleScript...")
    logger.debug("AppleScript: %s", applescript)

    try:
        result = subprocess.run(
            ["osascript", "-e", applescript],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except subprocess.TimeoutExpired:
        msg = "Zeitüberschreitung bei der Treiber-Installation (60s)."
        logger.error(msg)
        return False, msg
    except FileNotFoundError:
        msg = "osascript nicht gefunden — ist dies ein Mac?"
        logger.error(msg)
        return False, msg

    if result.returncode != 0:
        stderr = result.stderr.strip()
        # AppleScript Fehlercode -128 = User hat Passwortabfrage abgebrochen
        if "-128" in stderr:
            msg = "Installation abgebrochen — das Passwort wurde nicht eingegeben."
        else:
            msg = f"Treiber-Installation fehlgeschlagen:\n{stderr}"
        logger.error("Installation fehlgeschlagen (rc=%d): %s", result.returncode, stderr)
        return False, msg

    logger.info("Treiber erfolgreich installiert nach: %s", DRIVER_INSTALL_PATH)
    return True, ""


def check_and_install() -> bool:
    """
    Hauptfunktion: Prüft ob der Treiber installiert ist und installiert ihn bei Bedarf.

    Ablauf:
    1. Treiber vorhanden? → True (sofort)
    2. Nicht vorhanden → install_driver() aufrufen
    3. Fehler → rumps.alert anzeigen → False zurückgeben
    4. Erfolg → True

    Returns:
        True wenn der Treiber bereit ist (bereits vorhanden oder gerade installiert).
        False wenn der User die Installation abgebrochen hat oder ein Fehler aufgetreten ist.
    """
    if is_driver_installed():
        logger.info("Treiber bereits installiert — kein Eingriff nötig.")
        return True

    logger.info("Treiber nicht gefunden — starte Installation.")

    # rumps ist noch nicht initialisiert wenn check_and_install() aufgerufen wird,
    # daher verwenden wir subprocess+osascript für den Hinweis-Dialog.
    # rumps.alert() funktioniert erst nachdem die App gestartet ist.
    # Wir nutzen hier einen nativen macOS-Dialog via osascript.
    _show_install_dialog()

    success, error_msg = install_driver()

    if not success:
        _show_error_dialog(error_msg)
        return False

    # Sicherheits-Check: Ist der Treiber jetzt wirklich da?
    if not is_driver_installed():
        msg = (
            "Der Treiber wurde installiert, ist aber nicht am erwarteten Pfad:\n"
            f"{DRIVER_INSTALL_PATH}\n\n"
            "Bitte starte AudioRouterNow erneut."
        )
        _show_error_dialog(msg)
        return False

    logger.info("Treiber-Installation abgeschlossen und verifiziert.")
    return True


# ---------------------------------------------------------------------------
# Hilfsfunktionen — native macOS Dialoge via osascript
# ---------------------------------------------------------------------------

def _show_install_dialog() -> None:
    """
    Zeigt einen Hinweis-Dialog bevor die Passwortabfrage erscheint.
    Der User weiß dadurch warum macOS nach dem Passwort fragt.
    """
    script = (
        'display dialog "AudioRouterNow muss den Audio-Treiber installieren.\\n\\n'
        "macOS wird nach Ihrem Passwort fragen — "
        'das ist einmalig und notwendig." '
        'buttons {"OK"} default button "OK" '
        'with title "AudioRouterNow — Treiber-Installation" '
        'with icon note'
    )
    try:
        subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            timeout=30,
        )
    except Exception:
        # Dialog-Fehler ist unkritisch — Installation wird trotzdem versucht
        pass


def _show_error_dialog(message: str) -> None:
    """
    Zeigt einen Fehler-Dialog mit der übergebenen Meldung.
    Wird aufgerufen wenn die Installation fehlschlägt.
    """
    safe_message = message.replace('"', "'").replace("\n", "\\n")
    script = (
        f'display dialog "{safe_message}" '
        'buttons {"OK"} default button "OK" '
        'with title "AudioRouterNow — Fehler" '
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
