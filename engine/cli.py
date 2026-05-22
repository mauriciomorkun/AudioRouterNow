"""
CLI — Terminal-Interface fuer AudioRouterNow (Testing und Diagnose).

Verwendung:
    python cli.py --list-devices
    python cli.py --output "Komplete Audio 6" --output "AirPods Pro"
    python cli.py --test-socket

Ohne Argumente: Zeigt Hilfe an.
"""

import argparse
import logging
import signal
import socket
import sys
import time

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
logger = logging.getLogger(__name__)


def cmd_list_devices():
    """Listet alle verfuegbaren Output-Devices auf."""
    # Importiere hier damit CLI auch ohne alle Abhaengigkeiten lauffaehig bleibt
    try:
        import sounddevice as sd
    except ImportError:
        print("FEHLER: sounddevice nicht installiert. Bitte: pip install sounddevice")
        sys.exit(1)

    print("\nVerfuegbare Audio-Devices:")
    print("-" * 60)

    devices = sd.query_devices()
    has_output = False

    for i, dev in enumerate(devices):
        in_ch = int(dev["max_input_channels"])
        out_ch = int(dev["max_output_channels"])
        sr = int(dev["default_samplerate"])

        if out_ch > 0:
            marker = "  >> "  # Output-Device hervorheben
            has_output = True
        else:
            marker = "     "

        print(
            f"{marker}[{i:2}]  {dev['name']:<40}  "
            f"In:{in_ch}  Out:{out_ch}  SR:{sr} Hz"
        )

    if not has_output:
        print("  (keine Output-Devices gefunden)")

    print()


def cmd_test_socket():
    """Prueft ob der HAL-Treiber eine Verbindung aufbaut."""
    from socket_receiver import SOCKET_PATH, BLOCK_SIZE_BYTES

    print(f"Starte Unix Socket Server auf {SOCKET_PATH} ...")
    print("Warte auf Verbindung vom HAL-Treiber (Ctrl+C zum Abbrechen)...")
    print()

    import os
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    server.listen(1)
    server.settimeout(30.0)

    try:
        conn, _ = server.accept()
        print("HAL-Treiber verbunden!")
        print(f"Empfange Daten... (erwarte {BLOCK_SIZE_BYTES} Bytes pro Block)")
        print()

        blocks_received = 0
        start_time = time.time()
        recv_buffer = bytearray()

        conn.settimeout(5.0)
        try:
            while blocks_received < 50:  # max. 50 Bloecke testen
                while len(recv_buffer) < BLOCK_SIZE_BYTES:
                    chunk = conn.recv(BLOCK_SIZE_BYTES - len(recv_buffer))
                    if not chunk:
                        break
                    recv_buffer.extend(chunk)

                if len(recv_buffer) < BLOCK_SIZE_BYTES:
                    break

                block = bytes(recv_buffer[:BLOCK_SIZE_BYTES])
                recv_buffer = recv_buffer[BLOCK_SIZE_BYTES:]
                blocks_received += 1

                if blocks_received % 10 == 0:
                    elapsed = time.time() - start_time
                    blocks_per_sec = blocks_received / elapsed
                    print(
                        f"  {blocks_received} Bloecke empfangen  "
                        f"({blocks_per_sec:.1f} Bloecke/s, "
                        f"{blocks_per_sec * 512:.0f} Frames/s)"
                    )
        except socket.timeout:
            print("Timeout — keine Daten empfangen.")
        finally:
            conn.close()

        if blocks_received > 0:
            print(f"\nERFOLG: {blocks_received} Bloecke empfangen — HAL-Treiber funktioniert!")
        else:
            print("\nFEHLER: Verbindung hergestellt, aber keine Daten empfangen.")

    except socket.timeout:
        print("FEHLER: Kein HAL-Treiber verbunden innerhalb von 30 Sekunden.")
        print("Ist der Treiber in /Library/Audio/Plug-Ins/HAL/ installiert?")
        print("Pruefe: sudo killall -9 coreaudiod  (startet Core Audio neu)")
        sys.exit(1)
    finally:
        server.close()
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)


def cmd_start_routing(output_names: list):
    """Startet das Routing zu den angegebenen Output-Devices."""
    try:
        from device_manager import DeviceManager
        from routing_engine import OutputTarget, RoutingEngine
        from socket_receiver import SocketReceiver
    except ImportError as e:
        print(f"FEHLER: Abhaengigkeit fehlt: {e}")
        print("Bitte: pip install -r requirements.txt")
        sys.exit(1)

    print(f"Suche Devices: {output_names}")

    # Device-Manager einmalig starten um aktuelle Device-Liste zu erhalten
    dm = DeviceManager()
    dm.start()
    time.sleep(0.2)  # kurz warten bis initiales Scan abgeschlossen

    targets = []
    for name in output_names:
        device = dm.find_device_by_name(name)
        if device is None:
            print(f"  NICHT GEFUNDEN: '{name}'")
            print("  Verfuegbare Devices: python cli.py --list-devices")
        else:
            targets.append(
                OutputTarget(
                    device_index=device.index,
                    device_name=device.name,
                    channel_count=device.max_output_channels,
                )
            )
            print(f"  Gefunden: {device.name} ({device.max_output_channels}ch, Index {device.index})")

    if not targets:
        print("\nFEHLER: Kein Output-Device gefunden. Abbruch.")
        dm.stop()
        sys.exit(1)

    engine = RoutingEngine()
    engine.set_outputs(targets)

    receiver = SocketReceiver(on_frames=engine.on_frames)

    def shutdown(sig, frame):
        print("\nStoppe Routing...")
        engine.stop()
        receiver.stop()
        dm.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    receiver.start()

    if engine.start():
        print("\nRouting aktiv. Ctrl+C zum Beenden.")
        print("Output-Devices:")
        for t in targets:
            print(f"  - {t.device_name} ({t.channel_count}ch)")
        print()

        while True:
            time.sleep(1)
    else:
        print("\nFEHLER: Routing konnte nicht gestartet werden.")
        receiver.stop()
        dm.stop()
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="AudioRouterNow CLI — Diagnose und Testing",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Beispiele:
  python cli.py --list-devices
  python cli.py --output "Komplete Audio 6" --output "AirPods Pro"
  python cli.py --test-socket
        """,
    )

    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="Alle verfuegbaren Audio-Devices anzeigen",
    )
    parser.add_argument(
        "--output",
        action="append",
        metavar="DEVICE_NAME",
        dest="outputs",
        help="Output-Device hinzufuegen (kann mehrfach angegeben werden)",
    )
    parser.add_argument(
        "--test-socket",
        action="store_true",
        help="Unix Socket Server starten und auf HAL-Treiber-Verbindung testen",
    )

    args = parser.parse_args()

    if args.list_devices:
        cmd_list_devices()
        return

    if args.test_socket:
        cmd_test_socket()
        return

    if args.outputs:
        cmd_start_routing(args.outputs)
        return

    # Keine Argumente — Hilfe anzeigen
    parser.print_help()


if __name__ == "__main__":
    main()
