"""
CLI — Terminal-Interface fuer AudioRouterNow v2.0 (Diagnose und Steuerung).

v2.0: Audio laeuft ueber den nativen C-Helper-Daemon (AudioRouterNowHelper).
Python ist nur noch fuer UI und Konfiguration via Unix-Socket zustaendig.
sounddevice, SocketReceiver und RoutingEngine sind NICHT mehr Teil dieses CLIs.

Verwendung:
    python cli.py --list-devices
    python cli.py --status
    python cli.py --ping
    python cli.py --set-outputs AppleHDAEngineOutput:0 AppleUSBAudio:2
    python cli.py --start-helper
    python cli.py --stop-helper

Hinweis: --test-socket (v1) wurde durch --ping ersetzt.
"""

import argparse
import logging
import sys

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger(__name__)


def cmd_list_devices():
    """Listet alle verfuegbaren CoreAudio Output-Devices mit UIDs auf."""
    try:
        from device_manager import DeviceManager
    except ImportError as e:
        print(f"FEHLER: device_manager konnte nicht importiert werden: {e}")
        sys.exit(1)

    dm = DeviceManager()
    dm.start()
    devices = dm.get_output_devices()
    dm.stop()

    if not devices:
        print("Keine Output-Devices gefunden (>= 2 Kanaele benoetigt).")
        return

    print()
    print("Verfuegbare CoreAudio Output-Devices:")
    print("-" * 72)
    print(f"  {'#':<4}  {'Name':<36}  {'Ch':>4}  {'SR':>8}  UID")
    print("-" * 72)

    for i, dev in enumerate(devices):
        sr_str = f"{dev.default_samplerate:.0f} Hz" if dev.default_samplerate else "unbekannt"
        print(
            f"  {i:<4}  {dev.name:<36}  {dev.max_output_channels:>4}  "
            f"{sr_str:>8}  {dev.uid}"
        )

    print()
    print(f"{len(devices)} Device(s) gefunden.")
    print()
    print("Tipp: UID verwenden mit --set-outputs <uid>:<ch_offset>")
    print()


def cmd_status():
    """Fragt den Helper-Status via Config-Socket ab."""
    try:
        from helper_client import HelperClient
    except ImportError as e:
        print(f"FEHLER: helper_client konnte nicht importiert werden: {e}")
        sys.exit(1)

    helper = HelperClient()
    status = helper.get_status()

    if status is None:
        print("FEHLER: Kein Status vom Helper erhalten. Laeuft der Helper?")
        print("  Tipp: python cli.py --ping")
        print("  Tipp: python cli.py --start-helper")
        sys.exit(1)

    print()
    print("Helper-Status:")
    print("-" * 40)
    for key, value in status.items():
        print(f"  {key}: {value}")
    print()


def cmd_ping():
    """Prueft ob der Helper-Daemon erreichbar ist."""
    try:
        from helper_client import HelperClient
    except ImportError as e:
        print(f"FEHLER: helper_client konnte nicht importiert werden: {e}")
        sys.exit(1)

    helper = HelperClient()
    ok = helper.ping()

    if ok:
        print("Helper erreichbar (pong empfangen).")
    else:
        print("FEHLER: Helper antwortet nicht.")
        print("  Tipp: python cli.py --start-helper")
        sys.exit(1)


def cmd_set_outputs(uid_offset_pairs: list):
    """
    Konfiguriert die Output-Streams des Helpers.

    Erwartet eine Liste von 'uid:ch_offset'-Strings.
    """
    try:
        from helper_client import HelperClient, OutputSpec
    except ImportError as e:
        print(f"FEHLER: helper_client konnte nicht importiert werden: {e}")
        sys.exit(1)

    outputs = []
    for pair in uid_offset_pairs:
        parts = pair.rsplit(":", 1)
        if len(parts) != 2:
            print(f"FEHLER: Ungaeltiges Format '{pair}' — erwartet uid:ch_offset")
            sys.exit(1)
        uid, ch_offset_str = parts
        try:
            ch_offset = int(ch_offset_str)
        except ValueError:
            print(f"FEHLER: ch_offset muss eine Ganzzahl sein ('{pair}')")
            sys.exit(1)
        outputs.append(OutputSpec(uid=uid, ch_offset=ch_offset))

    if not outputs:
        print("FEHLER: Keine gueltigen uid:ch_offset-Paare angegeben.")
        sys.exit(1)

    helper = HelperClient()
    print(f"Setze {len(outputs)} Output(s):")
    for o in outputs:
        print(f"  UID={o.uid}  ch_offset={o.ch_offset}")

    result = helper.set_outputs(outputs)

    if result is None:
        print("FEHLER: Keine Antwort vom Helper.")
        sys.exit(1)

    print()
    print("Antwort vom Helper:")
    for key, value in result.items():
        print(f"  {key}: {value}")
    print()


def cmd_start_helper():
    """Startet den Helper-Daemon (falls noch nicht aktiv)."""
    try:
        from helper_client import HelperClient
    except ImportError as e:
        print(f"FEHLER: helper_client konnte nicht importiert werden: {e}")
        sys.exit(1)

    helper = HelperClient()
    print("Starte Helper-Daemon...")
    ok = helper.ensure_running()

    if ok:
        print("Helper laeuft.")
    else:
        print("FEHLER: Helper konnte nicht gestartet werden.")
        print("  Logs: /tmp/audiorouter.helper.log")
        print("  Fehler: /tmp/audiorouter.helper.err")
        sys.exit(1)


def cmd_stop_helper():
    """Sendet Shutdown-Kommando an den Helper-Daemon."""
    try:
        from helper_client import HelperClient
    except ImportError as e:
        print(f"FEHLER: helper_client konnte nicht importiert werden: {e}")
        sys.exit(1)

    helper = HelperClient()
    print("Sende Shutdown an Helper...")
    helper.shutdown()
    print("Shutdown-Kommando gesendet.")
    print("Hinweis: Wenn launchd den Helper verwaltet, wird er ggf. neu gestartet.")


def main():
    parser = argparse.ArgumentParser(
        description="AudioRouterNow CLI v2.0 — Diagnose und Steuerung",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Beispiele:
  python cli.py --list-devices
  python cli.py --ping
  python cli.py --status
  python cli.py --set-outputs AppleHDAEngineOutput:0 AppleUSBAudio:2
  python cli.py --start-helper
  python cli.py --stop-helper

Hinweis: --test-socket (v1) wurde durch --ping ersetzt.
         --output / RoutingEngine / sounddevice sind in v2.0 entfallen.
        """,
    )

    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="Alle verfuegbaren CoreAudio Output-Devices mit UIDs anzeigen",
    )
    parser.add_argument(
        "--status",
        action="store_true",
        help="Helper-Status via Config-Socket abfragen",
    )
    parser.add_argument(
        "--ping",
        action="store_true",
        help="Prueft ob der Helper-Daemon erreichbar ist (ersetzt --test-socket)",
    )
    parser.add_argument(
        "--set-outputs",
        nargs="+",
        metavar="UID:CH_OFFSET",
        help="Output-Streams konfigurieren (uid:ch_offset, ein oder mehrere)",
    )
    parser.add_argument(
        "--start-helper",
        action="store_true",
        help="Helper-Daemon starten (falls nicht aktiv)",
    )
    parser.add_argument(
        "--stop-helper",
        action="store_true",
        help="Shutdown-Kommando an Helper senden",
    )

    # Verstecktes v1-Argument fuer Rueckwaerts-Hinweis
    parser.add_argument(
        "--test-socket",
        action="store_true",
        help=argparse.SUPPRESS,  # v1-Deprecation, nicht in Hilfe anzeigen
    )
    parser.add_argument(
        "--output",
        action="append",
        metavar="DEVICE_NAME",
        dest="outputs_v1",
        help=argparse.SUPPRESS,  # v1-Deprecation, nicht in Hilfe anzeigen
    )

    args = parser.parse_args()

    # v1-Deprecation-Hinweise
    if args.test_socket:
        print("HINWEIS: --test-socket ist in v2.0 nicht mehr verfuegbar.")
        print("         Verwende stattdessen: python cli.py --ping")
        print()
        cmd_ping()
        return

    if args.outputs_v1:
        print("HINWEIS: --output / RoutingEngine ist in v2.0 entfallen.")
        print("         Der Helper-Daemon uebernimmt das Audio-Routing.")
        print("         Verwende --set-outputs <uid>:<ch_offset> zum Konfigurieren.")
        print("         Devices anzeigen: python cli.py --list-devices")
        sys.exit(1)

    if args.list_devices:
        cmd_list_devices()
        return

    if args.status:
        cmd_status()
        return

    if args.ping:
        cmd_ping()
        return

    if args.set_outputs:
        cmd_set_outputs(args.set_outputs)
        return

    if args.start_helper:
        cmd_start_helper()
        return

    if args.stop_helper:
        cmd_stop_helper()
        return

    # Keine Argumente — Hilfe anzeigen
    parser.print_help()


if __name__ == "__main__":
    main()
