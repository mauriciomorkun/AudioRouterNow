"""
healer.py — Self-Healing Layer Tranche B: Sanfte Out-of-RT-Heilung.

Verarbeitet SystemHealth-Objekte aus health.py und löst gezielt
reconnect_output-Befehle aus — mit exponentiellem Backoff und Circuit Breaker.

Alle Entscheidungen im Python-Brain. Der Helper-C-Code ist reiner Aktuator.
Safe-Take-Modus deaktiviert alle Heilungseingriffe.
"""
from __future__ import annotations
import logging
import time
from dataclasses import dataclass, field
from typing import Dict, Optional, Tuple

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
    failures: int = 0
    open_until: float = 0.0   # monotonic; kein Versuch solange now < open_until
    tripped: bool = False      # endgültig aufgegeben
    stall_samples: int = 0     # wie viele Polls in Folge dieses Output stalled ist


class Healer:
    """
    Policy-Engine für Self-Healing.

    Wird aus dem health-poll-Thread (200ms) aufgerufen.
    Thread-safety: Alle State-Zugriffe nur im health-poll-Thread — kein Lock nötig.
    """

    def __init__(self, helper_client, safe_take_getter):
        """
        helper_client: HelperClient-Instanz
        safe_take_getter: callable() → bool (True = Safe-Take aktiv)
        """
        self._helper = helper_client
        self._safe_take = safe_take_getter
        self._breakers: Dict[Tuple[str, int], CircuitBreaker] = {}

    def process(self, health: SystemHealth) -> None:
        """Verarbeitet einen SystemHealth-Snapshot und löst ggf. Heilung aus."""
        if self._safe_take():
            return  # Python-seitige Safe-Take-Doppelsperre

        for output in health.outputs:
            self._process_output(output)

    def _process_output(self, output: OutputHealth) -> None:
        key = (output.uid, output.ch_offset)
        cb = self._breakers.setdefault(key, CircuitBreaker(
            uid=output.uid, ch_offset=output.ch_offset))

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
            if resp and resp.get("ok"):
                logger.info("Healer: reconnect_output OK für '%s' Ch%d",
                            output.name, output.ch_offset + 1)
                # Stall-Samples zurücksetzen — warten ob es hält
                cb.stall_samples = 0
            else:
                err = resp.get("error", "unknown") if resp else "no_response"
                logger.warning("Healer: reconnect_output fehlgeschlagen für '%s' Ch%d: %s",
                               output.name, output.ch_offset + 1, err)
        except Exception as e:
            logger.warning("Healer: reconnect_output Exception für '%s' Ch%d: %s",
                           output.name, output.ch_offset + 1, e)

        # Backoff-Wartezeit setzen
        cb.failures += 1
        backoff = BACKOFF_SECONDS[min(cb.failures - 1, len(BACKOFF_SECONDS) - 1)]
        cb.open_until = now + backoff
        logger.debug("Healer: nächster Versuch frühestens in %.1fs", backoff)

    def tripped_outputs(self):
        """Gibt Liste der Trip-Breaker zurück (für Notification)."""
        return [(cb.uid, cb.ch_offset) for cb in self._breakers.values() if cb.tripped]
