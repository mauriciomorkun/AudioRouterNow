"""
helper_client.py — Steuert den AudioRouterNowHelper über den Config-Socket.

Der Helper-Daemon ist eine native C-Binary, die unter
~/Library/LaunchAgents/com.audiorouter.now.helper.plist (oder manuell)
laeuft und Audio-Frames aus dem SHM-Ring an CoreAudio-Geraete weiterleitet.

Protokoll: JSON-Lines über Unix Domain Socket /tmp/audiorouter.config.sock
"""

import json
import logging
import os
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

logger = logging.getLogger(__name__)

CONFIG_SOCKET = str(Path.home() / ".audiorouter" / "audiorouter.config.sock")
# P3: Per-Launch Auth-Token, vom Helper nach ~/.audiorouter/helper.token (0600) geschrieben.
TOKEN_PATH = str(Path.home() / ".audiorouter" / "helper.token")
CONNECT_TIMEOUT = 2.0
READ_TIMEOUT = 5.0
QUICK_TIMEOUT = 0.5
# H2: Kurzer Timeout für Menü-Aktionen, die synchron auf dem Main-Thread
# senden (set_outputs, set_sample_rate, …) — ein hängender Helper darf die
# UI nicht einfrieren.
MENU_ACTION_TIMEOUT = 1.0

# P3: Kommandos, die das Auth-Token mitschicken muessen (privilegiert).
_PRIVILEGED_CMDS = {"shutdown", "set_outputs", "set_sample_rate",
                    "reconnect_output", "set_safe_take"}


@dataclass
class OutputSpec:
    """Beschreibt einen aktiven Output-Stream."""
    uid: str
    ch_offset: int


def _find_helper_binary() -> Optional[Path]:
    """
    Sucht das Helper-Binary an plausiblen Pfaden:
      1. PyInstaller-Bundle:       <Resources>/AudioRouterNow.driver/Contents/MacOS/AudioRouterNowHelper
      2. Installierter HAL-Pfad:   /Library/Audio/Plug-Ins/HAL/AudioRouterNow.driver/Contents/MacOS/...
      3. Development:              <project>/helper/build/AudioRouterNowHelper
    """
    candidates: List[Path] = []

    # PyInstaller: Bundle ist in sys._MEIPASS/AudioRouterNow.driver/
    if getattr(sys, "frozen", False):
        meipass = Path(getattr(sys, "_MEIPASS"))  # type: ignore[attr-defined]
        candidates.append(meipass / "AudioRouterNow.driver" / "Contents" / "MacOS" / "AudioRouterNowHelper")

    # Standard-Installation
    candidates.append(Path("/Library/Audio/Plug-Ins/HAL/AudioRouterNow.driver/Contents/MacOS/AudioRouterNowHelper"))

    # Development
    engine_dir = Path(__file__).resolve().parent
    candidates.append(engine_dir.parent / "helper" / "build" / "AudioRouterNowHelper")

    for c in candidates:
        if c.exists() and os.access(c, os.X_OK):
            return c
    return None


class HelperClient:
    """
    Client für den Helper-Daemon.

    Aufgaben:
      - Spawnt den Helper-Prozess (falls noch nicht via launchd aktiv)
      - Sendet Konfigurations-Kommandos über den Unix-Socket
      - Liefert Status zurueck (ping, get_status, set_outputs, shutdown)
    """

    def __init__(self):
        self._proc: Optional[subprocess.Popen] = None
        self._lock = threading.Lock()
        self._spawn_lock = threading.Lock()   # schützt nur den Helper-Spawn-Prozess
        self._spawned_by_us = False
        # P3: Auth-Token beim Start laden (kann beim ersten Aufruf noch fehlen,
        # wird dann lazy/bei auth-Fehler nachgeladen).
        self._auth_token: Optional[str] = None
        self._load_token()

    # ------------------------------------------------------------------
    # P3: Auth-Token
    # ------------------------------------------------------------------

    def _load_token(self) -> Optional[str]:
        """Laedt das Auth-Token aus ~/.audiorouter/helper.token.
        Gibt das Token zurueck (oder None, wenn nicht lesbar)."""
        try:
            with open(TOKEN_PATH, "r", encoding="ascii") as f:
                tok = f.read().strip()
            self._auth_token = tok if tok else None
        except OSError:
            self._auth_token = None
        return self._auth_token

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def ensure_running(self) -> bool:
        """
        Stellt sicher, dass der Helper läuft UND routing-bereit ist.

        P1-C FIX: self._lock wird NICHT mehr für die gesamte Startup-Sequenz
        gehalten (zuvor bis zu 25s). Ein separater _spawn_lock schützt den
        Spawn-Prozess, self._lock wird nur für kurze Socket-Checks gehalten.

        Phasen:
          1. Socket erreichbar?  → warte auf SHM-bereit → return True
          Falls Socket tot: Helper spawnen (unter _spawn_lock), dann Phasen 1+2.
        """
        # Schneller Check ohne langen Lock
        if self._is_socket_alive():
            logger.info("Helper Socket erreichbar — warte auf SHM-Bereitschaft")
            if self._wait_for_ready():
                return True
            logger.warning("Helper Socket erreichbar, SHM-Timeout — App retries via Timer")
            return True

        # Helper muss gespawnt werden — _spawn_lock verhindert Doppel-Spawn
        with self._spawn_lock:
            # Double-checked: vielleicht hat ein paralleler Thread den Helper
            # gerade gespawnt waehrend wir auf _spawn_lock warteten.
            if self._is_socket_alive():
                logger.info("Helper wurde von parallelem Thread gestartet — weiter zu Phase 2")
                if self._wait_for_ready():
                    return True
                return True

            binary = _find_helper_binary()
            if binary is None:
                logger.error("Helper-Binary nicht gefunden")
                return False

            logger.info(f"Helper wird gespawnt: {binary}")
            try:
                log_dir = Path.home() / "Library" / "Logs" / "AudioRouterNow"
                log_dir.mkdir(parents=True, exist_ok=True)
                log_out = open(log_dir / "helper.log", "ab", buffering=0)
                log_err = open(log_dir / "helper.err", "ab", buffering=0)
                try:
                    proc = subprocess.Popen(
                        [str(binary)],
                        stdout=log_out,
                        stderr=log_err,
                        stdin=subprocess.DEVNULL,
                        start_new_session=True,
                    )
                finally:
                    log_out.close()
                    log_err.close()
                with self._lock:
                    self._proc = proc
                    self._spawned_by_us = True
            except OSError as e:
                logger.error(f"Helper konnte nicht gestartet werden: {e}")
                return False

            # Phase 1: Warte bis Socket erreichbar (max 15s) — OHNE self._lock
            deadline = time.monotonic() + 15.0
            while time.monotonic() < deadline:
                if self._is_socket_alive():
                    logger.info("Helper-Socket erreichbar")
                    break
                time.sleep(0.1)
            else:
                logger.error("Helper gestartet, aber Socket nicht erreichbar")
                return False

            # Phase 2: Warte bis SHM-Ring bereit (max 10s) — OHNE self._lock
            if self._wait_for_ready():
                logger.info("Helper vollständig bereit (Socket + SHM)")
                return True

            logger.warning("Helper Socket OK, SHM-Timeout — App retries via Timer")
            return True

    def _wait_for_ready(self, timeout: float = 10.0) -> bool:
        """
        Wartet bis get_status() → ready:true meldet (SHM verbunden).
        Gibt True zurück wenn bereit, False bei Timeout.

        P1-C: Ruft _send_no_lock() auf — darf NICHT unter self._lock aufgerufen
        werden (würde Deadlock verursachen). ensure_running() hält self._lock
        daher nicht mehr während dieser Methode läuft.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                status = self._send_no_lock({"cmd": "get_status"})
                if status.get("ready") is not False:
                    return True
            except Exception:
                pass
            time.sleep(0.2)
        return False

    def shutdown(self) -> None:
        """
        Sendet shutdown-Kommando an den Helper.
        Wenn wir den Helper selbst gespawnt haben, warten wir auf Ende.
        Wenn launchd den Helper verwaltet, wird er ggf. neu gestartet.
        """
        # M7: Nur der Socket-Send läuft unter self._lock — das (potenziell
        # sekundenlange) proc.wait()/terminate() danach NICHT, damit andere
        # Threads den Client nicht blockiert vorfinden.
        with self._lock:
            try:
                # P3: shutdown ist privilegiert — Token mitschicken (inline, da
                # wir bereits self._lock halten; _send_privileged wuerde re-locken).
                payload = {"cmd": "shutdown"}
                if self._auth_token:
                    payload["token"] = self._auth_token
                resp = self._send_no_lock(payload)
                if resp.get("error") == "auth":
                    self._load_token()
                    if self._auth_token:
                        payload["token"] = self._auth_token
                    self._send_no_lock(payload)
            except Exception as e:
                logger.debug(f"Shutdown-Send schlug fehl: {e}")

            proc = None
            if self._spawned_by_us and self._proc is not None:
                proc = self._proc
                self._proc = None
                self._spawned_by_us = False

        if proc is not None:
            try:
                proc.wait(timeout=3.0)
            except subprocess.TimeoutExpired:
                logger.warning("Helper reagiert nicht auf shutdown — terminate()")
                try:
                    proc.terminate()
                    proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    logger.warning("Helper ignoriert SIGTERM — sende SIGKILL")
                    proc.kill()
                    try:
                        proc.wait(timeout=2.0)
                    except Exception:
                        pass
                except Exception:
                    pass

    # ------------------------------------------------------------------
    # Commands
    # ------------------------------------------------------------------

    def ping(self, timeout: Optional[float] = QUICK_TIMEOUT) -> bool:
        """H2: Default-Timeout QUICK_TIMEOUT (0.5s) — ping wird vom UI-Timer
        auf dem Main-Thread aufgerufen und darf nicht lange blockieren."""
        try:
            resp = self._send({"cmd": "ping"}, timeout=timeout)
            return bool(resp.get("ok") and resp.get("pong"))
        except Exception:
            return False

    def get_status(self, timeout: Optional[float] = None) -> Optional[dict]:
        """
        Fragt den Helper-Status ab.

        Args:
            timeout: Optionaler Override fuer Connect- und Read-Timeout (Sekunden).
                     Nuetzlich fuer haeufige UI-Polls, damit ein haengender Helper
                     den Main-Thread nicht blockiert. None = Standard-Timeouts.
        """
        try:
            return self._send({"cmd": "get_status"}, timeout=timeout)
        except Exception as e:
            logger.warning(f"get_status fehlgeschlagen: {e}")
            return None

    def get_status_quick(self) -> Optional[dict]:
        """
        Schneller Status-Poll für den Main-Thread / UI-Updates.

        Verwendet kurzen Timeout (0.5s) damit die UI nicht einfriert wenn der
        Helper hängt. Liefert None bei Timeout statt zu blockieren.
        """
        try:
            return self._send({"cmd": "get_status"}, timeout=QUICK_TIMEOUT)
        except Exception:
            return None

    def set_outputs(self, outputs: List[OutputSpec],
                    timeout: Optional[float] = MENU_ACTION_TIMEOUT) -> Optional[dict]:
        payload = {
            "cmd": "set_outputs",
            "outputs": [{"uid": o.uid, "ch_offset": int(o.ch_offset)} for o in outputs],
        }
        try:
            return self._send_privileged(payload, timeout=timeout)
        except Exception as e:
            logger.warning(f"set_outputs fehlgeschlagen: {e}")
            return None

    def set_sample_rate(self, rate: int,
                        timeout: Optional[float] = MENU_ACTION_TIMEOUT) -> Optional[dict]:
        payload = {"cmd": "set_sample_rate", "rate": rate}
        try:
            return self._send_privileged(payload, timeout=timeout)
        except Exception as e:
            logger.warning(f"set_sample_rate fehlgeschlagen: {e}")
            return None

    def reconnect_output(self, uid: str, ch_offset: int,
                         timeout: Optional[float] = MENU_ACTION_TIMEOUT) -> Optional[dict]:
        """Sendet reconnect_output-Befehl an den Helper (Tranche B)."""
        payload = {"cmd": "reconnect_output", "uid": uid, "ch_offset": int(ch_offset)}
        try:
            return self._send_privileged(payload, timeout=timeout)
        except Exception as e:
            logger.warning(f"reconnect_output fehlgeschlagen: {e}")
            return None

    def set_safe_take(self, enabled: bool,
                      timeout: Optional[float] = MENU_ACTION_TIMEOUT) -> Optional[dict]:
        """Aktiviert/deaktiviert Safe-Take-Modus im Helper (Tranche B)."""
        payload = {"cmd": "set_safe_take", "enabled": 1 if enabled else 0}
        try:
            return self._send_privileged(payload, timeout=timeout)
        except Exception as e:
            logger.warning(f"set_safe_take fehlgeschlagen: {e}")
            return None

    # ------------------------------------------------------------------
    # Internal — Socket-Kommunikation
    # ------------------------------------------------------------------

    def _is_socket_alive(self) -> bool:
        if not os.path.exists(CONFIG_SOCKET):
            return False
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(CONNECT_TIMEOUT)
                s.connect(CONFIG_SOCKET)
                s.sendall(b'{"cmd":"ping"}\n')
                s.settimeout(READ_TIMEOUT)
                resp = s.recv(1024)
            return b'"pong":true' in resp
        except OSError:
            return False

    def _send(self, payload: dict, timeout: Optional[float] = None) -> dict:
        with self._lock:
            return self._send_no_lock(payload, timeout=timeout)

    def _send_privileged(self, payload: dict, timeout: Optional[float] = None) -> dict:
        """P3: Sendet ein privilegiertes Kommando MIT Auth-Token. Bei
        {"error":"auth"} wird das Token neu geladen und EINMAL erneut versucht
        (deckt einen Helper-Neustart ab, der ein neues Token erzeugt hat)."""
        with self._lock:
            if self._auth_token:
                payload = {**payload, "token": self._auth_token}
            resp = self._send_no_lock(payload, timeout=timeout)
            if resp.get("error") == "auth":
                # Token koennte veraltet sein (Helper neu gestartet) — neu laden + 1x retry.
                logger.info("Auth-Fehler — Token wird neu geladen und Request wiederholt")
                self._load_token()
                if self._auth_token:
                    payload = {**payload, "token": self._auth_token}
                resp = self._send_no_lock(payload, timeout=timeout)
            return resp

    def _send_no_lock(self, payload: dict, timeout: Optional[float] = None) -> dict:
        connect_to = timeout if timeout is not None else CONNECT_TIMEOUT
        read_to = timeout if timeout is not None else READ_TIMEOUT
        line = (json.dumps(payload) + "\n").encode("utf-8")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(connect_to)
            s.connect(CONFIG_SOCKET)
            s.sendall(line)
            s.settimeout(read_to)
            buf = b""
            while b"\n" not in buf:
                chunk = s.recv(8192)
                if not chunk:
                    break
                buf += chunk
                if len(buf) > 1_000_000:
                    raise RuntimeError("Helper-Antwort zu lang")
        line_str = buf.split(b"\n", 1)[0].decode("utf-8", errors="replace")
        try:
            return json.loads(line_str)
        except json.JSONDecodeError as e:
            raise RuntimeError(f"Helper-Antwort kein valides JSON: {line_str!r}") from e
