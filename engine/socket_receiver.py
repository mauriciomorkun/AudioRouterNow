"""
SocketReceiver — Unix Domain Socket Server fuer den AudioRouterNow HAL-Treiber.

Der HAL-Treiber verbindet sich als Client zu diesem Server und sendet
interleaved Float32-Stereo-PCM-Daten ohne Header oder Framing:
  - 512 Frames × 2 Channels × 4 Bytes = 4096 Bytes pro Block
  - Sample Rate: 48000 Hz (Standard), konfigurierbar

Architektur:
  - Laeuft in einem eigenen Daemon-Thread
  - Empfaengt Rohdaten, wandelt sie in numpy-Arrays um
  - Uebergibt jeden Frame-Block via Callback an die RoutingEngine
  - Bei Verbindungstrennung: sofort wieder auf neue Verbindung warten
  - Thread-sicheres Start/Stop
"""

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
        Haupt-Loop: baut den Server-Socket auf, akzeptiert Verbindungen
        vom HAL-Treiber und liest Frame-Bloecke.

        Bei Verbindungstrennung oder Fehlern wird automatisch eine neue
        Verbindung angenommen (Reconnect-Logic).
        """
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
                # Auf neue Verbindung warten
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    # Kein neuer Client — weiter warten
                    continue
                except OSError:
                    # Socket wurde von stop() geschlossen
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

        Liest genau BLOCK_SIZE_BYTES (4096 Bytes) pro Iteration, wandelt
        die Rohdaten in ein numpy-Array um und uebergibt es an den Callback.
        Bei Verbindungsabbruch oder Fehler wird der Loop beendet.
        """
        conn.settimeout(2.0)
        recv_buffer = bytearray()

        try:
            while self._running:
                # Fehlende Bytes nachfordern bis ein vollstaendiger Block da ist
                while len(recv_buffer) < BLOCK_SIZE_BYTES:
                    try:
                        chunk = conn.recv(BLOCK_SIZE_BYTES - len(recv_buffer))
                    except socket.timeout:
                        # Kein Daten innerhalb Timeout — pruefen ob Routing noch laeuft
                        if not self._running:
                            return
                        continue

                    if not chunk:
                        # Treiber hat Verbindung geschlossen
                        return
                    recv_buffer.extend(chunk)

                # Einen vollstaendigen Block verarbeiten.
                # Optimierung: kein bytearray-Slicing (erzeugt 93x/s neue
                # Objekte → GC-Pressure → GIL-Pausen → Audio-Glitches).
                # Stattdessen: numpy direkt aus dem Buffer lesen, kopieren,
                # dann in-place per `del` die ersten N Bytes entfernen.
                frames = np.frombuffer(
                    recv_buffer,
                    dtype=np.float32,
                    count=FRAMES_PER_BLOCK * CHANNELS,
                ).reshape(FRAMES_PER_BLOCK, CHANNELS).copy()
                # In-place Loeschung der gerade konsumierten Bytes —
                # keine neue bytearray-Allocation.
                del recv_buffer[:BLOCK_SIZE_BYTES]

                # Callback aufrufen (RoutingEngine)
                try:
                    self._on_frames(frames)
                except Exception as e:
                    logger.error(f"Fehler im Frame-Callback: {e}")

        except OSError as e:
            logger.warning(f"Socket-Verbindung unterbrochen: {e}")
        finally:
            try:
                conn.close()
            except OSError:
                pass
