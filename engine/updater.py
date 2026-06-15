"""
updater.py — Sparkle 2.9.3 Auto-Update-Integration via PyObjC.

Bindet Sparkle's SPUStandardUpdaterController in die rumps-basierte
NSApplication ein. Sparkle.framework wird zur Laufzeit aus dem
App-Bundle (Contents/Frameworks/Sparkle.framework) geladen.

Lifecycle / GC-Sicherheit:
  - SparkleUpdater wird von AudioRouterApp als self._updater gehalten
    (starke Referenz über gesamte App-Laufzeit).
  - Der SPUStandardUpdaterController wird als self._controller gehalten.
  - startUpdater wird explizit aufgerufen (startingUpdater=False im init),
    damit wir Fehler kontrolliert behandeln können.

Im Dev-Mode (kein eingebettetes Sparkle.framework) degradiert die Klasse
sauber: is_available() == False, und der Aufrufer faellt auf den
Browser-Fallback zurueck.
"""

import logging
import os
import sys

logger = logging.getLogger(__name__)

# Sparkle ist nur im gebauten .app-Bundle vorhanden (Contents/Frameworks/).
# Im Dev-Mode (python menu_bar_app.py) fehlt es → sauber degradieren.
_SPARKLE_AVAILABLE = False
_SPUStandardUpdaterController = None

try:
    import objc
    from Foundation import NSBundle

    # Sparkle.framework explizit aus dem Bundle laden, falls eingebettet.
    # In der gebauten App liegt es unter Contents/Frameworks/Sparkle.framework.
    _frameworks_dir = None
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        # PyInstaller: _MEIPASS zeigt auf den internen Daten-Ordner.
        # Sparkle.framework liegt in Contents/Frameworks/ (Geschwister von MacOS/).
        exe_dir = os.path.dirname(sys.executable)              # …/Contents/MacOS
        _frameworks_dir = os.path.join(
            os.path.dirname(exe_dir), "Frameworks"             # …/Contents/Frameworks
        )

    _loaded = False
    if _frameworks_dir:
        _sparkle_path = os.path.join(_frameworks_dir, "Sparkle.framework")
        if os.path.isdir(_sparkle_path):
            _bundle = NSBundle.bundleWithPath_(_sparkle_path)
            if _bundle is not None and _bundle.load():
                _loaded = True
                logger.info("Sparkle.framework geladen: %s", _sparkle_path)
            else:
                logger.warning(
                    "Sparkle.framework konnte nicht geladen werden: %s", _sparkle_path
                )

    if _loaded:
        # Symbole nach erfolgreichem Laden aufloesen.
        _SPUStandardUpdaterController = objc.lookUpClass(
            "SPUStandardUpdaterController"
        )
        _SPARKLE_AVAILABLE = _SPUStandardUpdaterController is not None

except Exception as exc:  # noqa: BLE001
    logger.info("Sparkle nicht verfuegbar (Dev-Mode oder Ladefehler): %s", exc)
    _SPARKLE_AVAILABLE = False


def is_available() -> bool:
    """True, wenn Sparkle.framework geladen und SPUStandardUpdaterController
    verfuegbar ist. False im Dev-Mode → Aufrufer nutzt Browser-Fallback."""
    return _SPARKLE_AVAILABLE


class SparkleUpdater:
    """Kapselt den SPUStandardUpdaterController.

    Eine Instanz pro App. Muss vom Aufrufer als starke Referenz gehalten
    werden (z.B. self._updater in AudioRouterApp), sonst raeumt der GC den
    Controller ab und Sparkle-Timer/Delegates feuern nicht mehr.
    """

    def __init__(self):
        self._controller = None
        self._started = False

        if not _SPARKLE_AVAILABLE:
            logger.debug(
                "SparkleUpdater init uebersprungen — Sparkle nicht verfuegbar"
            )
            return

        try:
            # startingUpdater=False → wir starten manuell via start(), um
            # Fehler (z.B. fehlende SUFeedURL) kontrolliert zu behandeln.
            # updaterDelegate / userDriverDelegate = None → Standardverhalten.
            self._controller = _SPUStandardUpdaterController.alloc().initWithStartingUpdater_updaterDelegate_userDriverDelegate_(
                False, None, None
            )
            logger.info("SPUStandardUpdaterController erstellt")
        except Exception as exc:  # noqa: BLE001
            logger.error(
                "SPUStandardUpdaterController-Init fehlgeschlagen: %s", exc
            )
            self._controller = None

    def start(self) -> bool:
        """Startet den Updater (liest Info.plist: SUFeedURL, SUPublicEDKey,
        SUEnableAutomaticChecks, SUScheduledCheckInterval).

        Gibt True bei Erfolg zurueck."""
        if self._controller is None:
            return False
        if self._started:
            return True
        try:
            updater = self._controller.updater()
            # Sparkle 2.x API: startUpdater:(NSError**)error — gibt (BOOL, NSError) zurück.
            # PyObjC-Mangling: startUpdater_ mit None als Error-Pointer.
            ok, err = updater.startUpdater_(None)
            if not ok:
                logger.error(
                    "Sparkle startUpdater fehlgeschlagen: %s",
                    err.localizedDescription() if err else "unbekannter Fehler",
                )
                return False
            self._started = True
            logger.info("Sparkle-Updater gestartet (automatische Checks aktiv)")
            return True
        except Exception as exc:  # noqa: BLE001
            logger.error("Sparkle startUpdater fehlgeschlagen: %s", exc)
            return False

    def check_for_updates(self) -> bool:
        """Manuelle Update-Pruefung (Menue „Check for Updates…").
        Gibt False zurueck wenn Sparkle nicht verfuegbar → Browser-Fallback."""
        if self._controller is None:
            return False
        try:
            self._controller.checkForUpdates_(None)
            return True
        except Exception as exc:  # noqa: BLE001
            logger.error("Sparkle checkForUpdates fehlgeschlagen: %s", exc)
            return False
