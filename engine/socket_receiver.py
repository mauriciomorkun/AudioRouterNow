"""
SocketReceiver — Unix Domain Socket Server fuer den AudioRouterNow HAL-Treiber.

Der HAL-Treiber verbindet sich als Client zu diesem Server und sendet
interleaved Float32-Stereo-PCM-Daten ohne Header oder Framing:
  - 512 Frames × 2 Channels × 4 Bytes = 4096 Bytes pro Block
  - Sample Rate: 48000 Hz (Standard), konfigurierbar

Architektur:
  - Laeuft in einem eigenen Daemon-Thread mit QOS_CLASS_USER_INTERACTIVE
  - Empfaengt Rohdaten in einen pre-allokierten Ring-Buffer
  - Uebergibt jeden Frame-Block via Callback an die RoutingEngine
  - Bei Verbindungstrennung: sofort wieder auf neue Verbindung warten
  - Thread-sicheres Start/Stop

Performance-Optimierungen:
  - Thread-Prioritaet: QOS_CLASS_USER_INTERACTIVE via ctypes (macOS)
    → verhindert GIL-Starvation unter CPU-Last
  - Pre-allokierter numpy-Array (FRAMES_PER_BLOCK, CHANNELS) wird
    wiederverwendet → 0 Heap-Allokationen im Empfangs-Hot-Path
  - recv_buffer als feste memoryview — kein bytearray-Slicing
"""

import ctypes
import ctypes.util
import socket
import os
import threading
import logging
import numpy as np
from typing import Callable, Optional

logger = logging.getLogger(__name__)

# Protokoll-Konstanten (muessen mit dem HAL-Treiber uebereinstimmen)
SOCKET_PATH = "/tmp/audiorouter.sock"
FRAMES_PER_BLOCK = 512
CHANNELS = 2
BYTES_PER_SAMPLE = 4  # Float32
BLOCK_SIZE_BYTES = FRAMES_PER_BLOCK * CHANNELS * BYTES_PER_SAMPLE  # 4096


def _boost_thread_priority() -> bool:
    """
    Hebt die QoS-Klasse des aktuellen Threads auf USER_INTERACTIVE.

    Verhindert, dass macOS den SocketReceiver-Thread unter CPU-Last
    verdraengt — das waere die Hauptursache fuer Frame-Drops.
    Schlaegt lautlos fehl (z.B. auf nicht-macOS-Plattformen).
    """
    try:
        # pthread_set_qos_class_self_np ist macOS-spezifisch
        lib = ctypes.CDLL(ctypes.util.find_library("pthread") or "libpthread.dylib")
        # QOS_CLASS_USER_INTERACTIVE = 0x21 (33), relative_priority = 0
        QOS_CLASS_USER_INTERACTIVE = 0x21
        result = lib.pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        return result == 0
    except Exception:
        return False


class SocketReceiver:
    """
    Unix Domain Socket Server.

    Wartet auf Verbindungen vom HAL-Treiber und leitet empfangene
    PCM-Frames via Callback weiter.
    """

    def __init__(self, on_frames: Callable[[np.ndarray], None]):
        """
        Initialisiert den SocketReceiver.

        Args:
            on_frames: Callback, der fuer jeden empfangenen Frame-Block
                       aufgerufen wird. Uebergibt ein numpy-Array der
                       Form (512, 2) mit dtype=float32.
        """
        self._on_frames = on_frames
        self._thread: Optional[threading.Thread] = None
        self._running = False
        self._lock = threading.Lock()
        # Referenz auf den Server-Socket fuer sauberes Shutdown
        self._server_socket: Optional[socket.socket] = None

        # Pre-allokierter Ausgabe-Array — wird pro Frame wiederverwendet.
        # np.frombuffer + copy entfaellt vollstaendig: raw bytes werden
        # direkt in diesen Array geschrieben (np.copyto aus memoryview).
        self._frame_buf: np.ndarray = np.zeros(
            (FRAMES_PER_BLOCK, CHANNELS), dtype=np.float32
        )

    def start(self):
        """Startet den Socket-Server in einem Hintergrund-Thread."""
        with self._lock:
            if self._running:
                return
            self._running = True
            self._thread = threading.Thread(
                target=self._server_loop,
                name="audiorouter-socket-receiver",
                daemon=True,
            )
            self._thread.start()
            logger.info("SocketReceiver gestartet (wartet auf HAL-Treiber)")

    def stop(self):
        """Stoppt den Socket-Server sauber."""
        with self._lock:
            if not self._running:
                return
            self._running = False
            # Server-Socket schliessen, damit accept() sofort aufwacht
            if self._server_socket:
                try:
                    self._server_socket.close()
                except OSError:
                    pass
                self._server_socket = None

        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=3.0)
        self._thread = None
        logger.info("SocketReceiver gestoppt")

    def _cleanup_socket_file(self):
        """Entfernt eine eventuell vorhandene alte Socket-Datei."""
        try:
            if os.path.exists(SOCKET_PATH):
                os.unlink(SOCKET_PATH)
        except OSError as e:
            logger.warning(f"Konnte Socket-Datei nicht entfernen: {e}")

    def _server_loop(self):
        """
        Haupt-Loop: Thread-Prioritaet erhoehen, Server-Socket aufbauen,
        Verbindungen akzeptieren.

        Bei Verbindungstrennung oder Fehlern wird automatisch eine neue
        Verbindung angenommen (Reconnect-Logic).
        """
        # Thread-Prioritaet so frueh wie moeglich erhoehen —
        # noch bevor der erste accept() laeuft.
        if _boost_thread_priority():
            logger.info("SocketReceiver: Thread-Prioritaet auf USER_INTERACTIVE gesetzt")
        else:
            logger.warning("SocketReceiver: Thread-Prioritaet konnte nicht erhoeht werden")

        self._cleanup_socket_file()

        try:
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(SOCKET_PATH)
            # Permissions auf 0777 setzen, damit _coreaudiod (anderer User)
            # connect() aufrufen darf. Unix-Domain-Sockets brauchen Write-
            # Permission fuer den Connector — Standard-Umask wuerde 0755
            # erzeugen, was _coreaudiod den Zugriff verweigert.
            os.chmod(SOCKET_PATH, 0o777)
            server.listen(1)
            # Timeout damit wir regelmaessig pruefen ob _running noch True ist
            server.settimeout(1.0)

            with self._lock:
                self._server_socket = server

            logger.info(f"Unix Socket Server bereit: {SOCKET_PATH}")
        except OSError as e:
            logger.error(f"Socket-Server konnte nicht gestartet werden: {e}")
            self._running = False
            return

        try:
            while self._running:
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break

                logger.info("HAL-Treiber verbunden — empfange Audio-Daten")
                self._receive_loop(conn)
                logger.info("HAL-Treiber Verbindung getrennt — warte auf erneute Verbindung")
        finally:
            self._cleanup_socket_file()
            logger.debug("Socket-Server beendet")

    def _receive_loop(self, conn: socket.socket):
        """
        Empfangs-Loop fuer eine aktive Treiber-Verbindung.

        Liest genau BLOCK_SIZE_BYTES (4096 Bytes) per recv_into() direkt
        in den pre-allokierten numpy-Buffer — keine Heap-Allokation im
        Hot-Path. Bei Verbindungsabbruch oder Fehler wird der Loop beendet.
        """
        conn.settimeout(2.0)

        # Empfangs-Staging-Buffer: feste Groesse, wird direkt per
        # recv_into() befuellt — kein bytearray-Extend, kein Slicing.
        raw_buf   = bytearray(BLOCK_SIZE_BYTES)
        mv        = memoryview(raw_buf)
        bytes_in  = 0

        try:
            while self._running:
                # Fehlende Bytes direkt in raw_buf schreiben (zero-copy recv)
                while bytes_in < BLOCK_SIZE_BYTES:
                    try:
                        n = conn.recv_into(
                            mv[bytes_in:],
                            BLOCK_SIZE_BYTES - bytes_in,
                        )
                    except socket.timeout:
                        if not self._running:
                            return
                        continue

                    if not n:
                        return  # Treiber hat Verbindung geschlossen
                    bytes_in += n

                # Vollstaendigen Block in pre-allokierten numpy-Array kopieren.
                # np.frombuffer(mv, ...) erzeugt eine view (kein Copy);
                # np.copyto schreibt sie zero-copy in self._frame_buf.
                np.copyto(
                    self._frame_buf,
                    np.frombuffer(mv, dtype=np.float32).reshape(
                        FRAMES_PER_BLOCK, CHANNELS
                    ),
                )
                bytes_in = 0  # Buffer zuruecksetzen — keine Allokation

                # Callback aufrufen (RoutingEngine)
                try:
                    self._on_frames(self._frame_buf)
                except Exception as e:
                    logger.error(f"Fehler im Frame-Callback: {e}")

        except OSError as e:
            logger.warning(f"Socket-Verbindung unterbrochen: {e}")
        finally:
            try:
                conn.close()
            except OSError:
                pass
