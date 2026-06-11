"""
healer.py — Self-Healing Layer Tranche B: Sanfte Out-of-RT-Heilung.

Verarbeitet SystemHealth-Objekte aus health.py und löst gezielt
reconnect_output-Befehle aus — mit exponentiellem Backoff und Circuit Breaker.

Alle Entscheidungen im Python-Brain. Der Helper-C-Code ist reiner Aktuator.
Safe-Take-Modus deaktiviert alle Heilungseingriffe.
"""
from __future__ import annotations
import logging
import threading
import time
from dataclasses import dataclass
from typing import Dict, Tuple

from health import SystemHealth, OutputHealth

logger = logging.getLogger(__name__)

# Backoff-Schema in Sekunden (exponentiell, nach 5 Versuchen Circuit Breaker)
BACKOFF_SECONDS = [0.5, 1.0, 2.0, 4.0, 8.0]
MAX_ATTEMPTS    = 5

# Wie viele Stall-Samples (à 200ms) bevor Reconnect ausgelöst wird
# (interne C-Recovery hat bis dahin keine Wirkung gezeigt)
STALL_PERSIST_SAMPLES = 3  # 3 × 200ms = 600ms


@dataclass
class CircuitBreaker:
    uid: str
    ch_offset: int
    name: str = ""             # M6: Device-Name (für Trip-Notifications)
    failures: int = 0
    open_until: float = 0.0   # monotonic; kein Versuch solange now < open_until
    tripped: bool = False      # endgültig aufgegeben
    stall_samples: int = 0     # wie viele Polls in Folge dieses Output stalled ist


class Healer:
    """
    Policy-Engine für Self-Healing.

    Wird aus dem health-poll-Thread (200ms) aufgerufen.
    H-6: threading.Lock schützt alle public Methoden — process() läuft im
    health-poll-Thread, reset_all() wird vom UI-Timer-Thread aufgerufen.
    """

    def __init__(self, helper_client, safe_take_getter):
        """
        helper_client: HelperClient-Instanz
        safe_take_getter: callable() → bool (True = Safe-Take aktiv)
        """
        self._helper = helper_client
        self._safe_take = safe_take_getter
        self._breakers: Dict[Tuple[str, int], CircuitBreaker] = {}
        # M1: Eviction-Karenz — zählt Aufrufe in Folge, in denen ein Breaker-Key
        # nicht mehr in health.outputs vorkam. Eviction erst ab 2.
        self._evict_pending: Dict[Tuple[str, int], int] = {}
        # H-6: Thread-Safety — process()/tripped_outputs()/breaker_name() laufen
        # im health-poll-Thread; reset_all() kommt vom UI-Timer-Thread.
        self._lock = threading.Lock()

    def process(self, health: SystemHealth) -> None:
        """Verarbeitet einen SystemHealth-Snapshot und löst ggf. Heilung aus."""
        with self._lock:
            # M1: Breaker-Eviction — Breaker entfernen, deren Output nicht mehr in
            # health.outputs vorkommt (Karenz: erst nach 2 aufeinanderfolgenden
            # Aufrufen ohne den Output, damit transiente Lücken nicht evicten).
            current_keys = {(o.uid, o.ch_offset) for o in health.outputs}
            for key in list(self._breakers.keys()):
                if key in current_keys:
                    self._evict_pending.pop(key, None)
                    continue
                misses = self._evict_pending.get(key, 0) + 1
                if misses >= 2:
                    logger.debug("Healer: Breaker %s evicted (Output nicht mehr aktiv)", key)
                    self._breakers.pop(key, None)
                    self._evict_pending.pop(key, None)
                else:
                    self._evict_pending[key] = misses

            if self._safe_take():
                return  # Python-seitige Safe-Take-Doppelsperre

            for output in health.outputs:
                self._process_output(output)

    def _process_output(self, output: OutputHealth) -> None:
        key = (output.uid, output.ch_offset)
        cb = self._breakers.get(key)
        if cb is None:
            # M6: Device-Name beim ersten Anlegen merken (für Trip-Notifications).
            cb = CircuitBreaker(uid=output.uid, ch_offset=output.ch_offset,
                                name=output.name)
            self._breakers[key] = cb
        elif output.name and not cb.name:
            cb.name = output.name

        if not output.stalled:
            # Output gesund — Breaker zurücksetzen
            if cb.stall_samples > 0 or cb.failures > 0:
                logger.debug("Healer: %s Ch%d erholt — Breaker reset",
                             output.name, output.ch_offset + 1)
                cb.stall_samples = 0
                cb.failures = 0
                cb.open_until = 0.0
                cb.tripped = False
            return

        # Output ist stalled
        cb.stall_samples += 1

        if cb.tripped:
            return  # Circuit Breaker offen — keine weiteren Versuche

        if cb.stall_samples < STALL_PERSIST_SAMPLES:
            return  # Noch warten — interne C-Recovery könnte noch greifen

        now = time.monotonic()
        if now < cb.open_until:
            return  # Backoff-Wartezeit noch nicht abgelaufen

        if cb.failures >= MAX_ATTEMPTS:
            cb.tripped = True
            logger.error(
                "Healer: Circuit Breaker für '%s' Ch%d ausgelöst nach %d Versuchen — "
                "manuelle Intervention nötig",
                output.name, output.ch_offset + 1, MAX_ATTEMPTS
            )
            return

        # Heilversuch
        logger.info("Healer: reconnect_output für '%s' Ch%d (Versuch %d/%d)",
                    output.name, output.ch_offset + 1, cb.failures + 1, MAX_ATTEMPTS)
        try:
            resp = self._helper.reconnect_output(output.uid, output.ch_offset)
        except Exception as e:
            logger.warning("Healer: reconnect_output Exception für '%s' Ch%d: %s",
                           output.name, output.ch_offset + 1, e)
            resp = None

        if resp is not None and resp.get("ok") is True:
            logger.info("Healer: reconnect_output OK für '%s' Ch%d",
                        output.name, output.ch_offset + 1)
            # Stall-Samples zurücksetzen — warten ob es hält
            cb.stall_samples = 0
            return

        if resp is not None:
            logger.warning("Healer: reconnect_output fehlgeschlagen für '%s' Ch%d: %s",
                           output.name, output.ch_offset + 1,
                           resp.get("error", "unknown"))

        # M1: failures NUR bei Misserfolg erhöhen + Backoff-Wartezeit setzen.
        cb.failures += 1
        backoff = BACKOFF_SECONDS[min(cb.failures - 1, len(BACKOFF_SECONDS) - 1)]
        cb.open_until = now + backoff
        logger.debug("Healer: nächster Versuch frühestens in %.1fs", backoff)

    def tripped_outputs(self):
        """Gibt Liste der Trip-Breaker zurück (für Notification)."""
        with self._lock:
            return [(cb.uid, cb.ch_offset) for cb in self._breakers.values() if cb.tripped]

    def breaker_name(self, uid: str, ch_offset: int) -> str:
        """M6: Gespeicherter Device-Name eines Breakers ('' wenn unbekannt)."""
        with self._lock:
            cb = self._breakers.get((uid, ch_offset))
            return cb.name if cb else ""

    def reset_all(self) -> None:
        """M1: Setzt alle Circuit Breaker zurück (z.B. nach Helper-Respawn)."""
        with self._lock:
            if self._breakers:
                logger.info("Healer: reset_all — %d Breaker zurückgesetzt", len(self._breakers))
            self._breakers.clear()
            self._evict_pending.clear()
