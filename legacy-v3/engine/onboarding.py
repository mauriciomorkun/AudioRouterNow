"""
onboarding.py — First-Run Wizard für AudioRouterNow.

Wird einmalig nach der ersten erfolgreichen Installation aufgerufen.
Erklärt dem User was installiert wurde und führt ihn durch die ersten Schritte.

Nutzt rumps.alert (blockierend, modal) — wird nach rumps-App-Init aufgerufen.
"""

import logging

logger = logging.getLogger(__name__)


def run_first_run_wizard(app, config) -> None:
    """
    Zeigt den dreistufigen First-Run-Wizard via blockierenden rumps.alert-Dialogen.

    Macht KEINE Annahmen über den App-State — nur rumps.alert + Config-Update.
    Muss nach rumps-App-Init aufgerufen werden (rumps.alert braucht einen
    laufenden App-Context).

    Args:
        app:    laufende rumps-App-Instanz (aktuell ungenutzt, für künftige Erweiterung).
        config: AppConfig-Instanz; bei Abschluss wird onboarding_done=True gesetzt.
    """
    try:
        import rumps
    except ImportError:
        # Test-Umgebung o.ä. ohne rumps — graceful skip.
        logger.debug("rumps nicht verfügbar — First-Run-Wizard übersprungen")
        return

    # Schritt 1 — Willkommen & Was wurde installiert
    rumps.alert(
        title="Welcome to AudioRouterNow 🎛️",
        message=(
            "AudioRouterNow routes your Mac's audio to multiple outputs simultaneously.\n\n"
            "What was installed:\n"
            "  • HAL Audio Driver — a virtual audio device (no kernel extension)\n"
            "  • Helper Daemon — runs in the background, routes audio to your devices\n\n"
            "Both components run locally. No internet connection required.\n"
            "No data leaves your Mac."
        ),
        ok="Next →",
    )

    # Schritt 2 — Outputs wählen
    rumps.alert(
        title="Step 1 of 2 — Choose your outputs",
        message=(
            "Click the 🎛️ icon in your menu bar and check the devices "
            "you want audio routed to.\n\n"
            "You can select multiple outputs — AudioRouterNow plays to all of them at once.\n\n"
            "Tip: Your selection is saved automatically."
        ),
        ok="Next →",
    )

    # Schritt 3 — You're set (erklärt den automatischen Switch)
    rumps.alert(
        title="Step 2 of 2 — You're set!",
        message=(
            "When you select an output, AudioRouterNow automatically becomes "
            "your system audio device.\n\n"
            "Play any audio — music, video, system sounds — "
            "and it will route to your selected outputs.\n\n"
            "The status indicator at the top of the menu shows what's happening:\n"
            "  🟢 Routing active\n"
            "  🟡 Ready (select an output or check system audio)\n"
            "  🔴 No output selected\n\n"
            "That's it. Enjoy! 🎧"
        ),
        ok="Let's go!",
    )

    config.onboarding_done = True
    logger.info("First-Run-Wizard abgeschlossen")
