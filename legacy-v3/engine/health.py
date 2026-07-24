"""
health.py — Self-Healing Layer Tranche A: Telemetrie + Health-Monitor.

Liest periodisch get_status()-Daten aus und berechnet einen dreistufigen
Health-Zustand (healthy/degraded/critical) mit Hysterese.

Kein Eingriff in den Audio-Pfad — rein observierend.
"""
from __future__ import annotations
import logging
from dataclasses import dataclass
from typing import List, Optional

logger = logging.getLogger(__name__)

# Kapazität des Rings in Frames (Stereo = 2 channels)
ARN_RING_CAPACITY_FRAMES = 16384 // 2  # = 8192 Frames

# Hysterese-Schwellen
DEGRADE_STREAK   = 2   # Samples in Folge für healthy→degraded
IMPROVE_STREAK   = 5   # Samples in Folge für degraded/critical→healthy
POLL_INTERVAL_S  = 0.2 # 200ms

# ioproc_age_ms unter diesem Wert = IOProc läuft
IOPROC_ALIVE_MS  = 500


@dataclass
class OutputHealth:
    uid: str
    name: str
    ch_offset: int
    underruns_abs: int        # absoluter Zähler aus get_status
    underruns_delta: int      # neu seit letztem Poll (berechnet)
    stalled: bool
    src_ratio_q20: int        # raw Q20-Wert
    src_ratio_ppm: float      # Abweichung von Nominal in ppm
    recovery_count: int


@dataclass
class SystemHealth:
    level: str                          # "healthy" | "degraded" | "critical"
    ring_frames: int
    ring_fill_ratio: float              # 0.0 – 1.0
    ioproc_alive: bool
    reconnect_count: int
    ioproc_age_ms: int
    outputs: List[OutputHealth]
    reasons: List[str]


class HealthMonitor:
    """
    Aggregiert get_status()-Telemetrie zu einem Health-Level mit Hysterese.

    Thread-safe: _current_health wird mit GIL-atomarer Zuweisung gesetzt.
    Kein Lock nötig für einfache Objekt-Reads durch den Main-Thread.
    """

    def __init__(self):
        self._current_health: Optional[SystemHealth] = None
        self._raw_level_streak: int = 0
        self._current_reported_level: str = "healthy"
        self._last_raw_level: str = "healthy"
        # Pro Output: letzter absoluter underruns-Wert (für Delta-Berechnung)
        self._last_underruns: dict = {}   # key: (uid, ch_offset) -> int
        self._last_reconnect_count: int = 0

    @property
    def health(self) -> Optional[SystemHealth]:
        return self._current_health

    @property
    def level(self) -> str:
        return self._current_reported_level

    @staticmethod
    def _level_ord(level: str) -> int:
        return {"healthy": 0, "degraded": 1, "critical": 2}.get(level, 0)

    def update(self, status: dict, audio_flowing: bool) -> SystemHealth:
        """
        Verarbeitet einen get_status()-Dict und aktualisiert den Health-Zustand.
        Gibt das neue SystemHealth-Objekt zurück.
        audio_flowing: True wenn ring_frames > 0 (Audio läuft gerade)
        """
        # ── Rohdaten parsen ────────────────────────────────────────────
        ring_frames    = int(status.get("ring_frames", 0))
        ring_fill      = ring_frames / ARN_RING_CAPACITY_FRAMES
        # B2-Fix: Wenn ioproc_age_ms fehlt (alter Helper ohne Tranche-A-Counter),
        # auf True defaulten — kein false-positive Critical gegen alte Binaries.
        _ioproc_age_raw = status.get("ioproc_age_ms", None)
        ioproc_age_ms  = int(_ioproc_age_raw) if _ioproc_age_raw is not None else 0
        reconnect_count = int(status.get("reconnect_count", 0))

        # ioproc_alive: nur relevant wenn Audio fließt (sonst keepalive-only).
        # Wenn der Helper das Feld nicht kennt (alt), nehmen wir alive=True an.
        if _ioproc_age_raw is None:
            ioproc_alive = True
        else:
            ioproc_alive = (ioproc_age_ms < IOPROC_ALIVE_MS) if audio_flowing else True

        outputs: List[OutputHealth] = []
        reasons: List[str] = []
        # Der C-Helper emittiert das Per-Output-Array unter dem Schlüssel
        # "active" (siehe get_status-Handler). "outputs" als Fallback für
        # eventuelle künftige Formate.
        raw_outputs = status.get("active", status.get("outputs", []))

        for o in raw_outputs:
            uid        = str(o.get("uid", ""))
            name       = str(o.get("name", ""))
            ch_offset  = int(o.get("ch_offset", 0))
            stalled    = bool(o.get("stalled", False))
            underruns  = int(o.get("underruns", 0))
            # Der Helper sendet "src_ratio" als float (z.B. 1.0884). Falls ein
            # künftiger Build "src_ratio_q20" als raw-Q20 liefert, wird dieser
            # bevorzugt. Andernfalls aus dem float-Ratio rekonstruieren.
            if "src_ratio_q20" in o:
                ratio_q20 = int(o.get("src_ratio_q20", 1 << 20))
            else:
                ratio_q20 = int(round(float(o.get("src_ratio", 1.0)) * (1 << 20)))
            rec_count  = int(o.get("recovery_count", 0))

            # Delta-Berechnung (robust gegen Helper-Neustart → Counter-Reset)
            key = (uid, ch_offset)
            prev = self._last_underruns.get(key, underruns)
            delta = max(0, underruns - prev)
            self._last_underruns[key] = underruns

            # ppm-Abweichung vom Nominal (1<<20 = 1.0)
            nominal = 1 << 20
            ppm = ((ratio_q20 - nominal) / nominal) * 1_000_000.0

            oh = OutputHealth(
                uid=uid, name=name, ch_offset=ch_offset,
                underruns_abs=underruns, underruns_delta=delta,
                stalled=stalled, src_ratio_q20=ratio_q20,
                src_ratio_ppm=ppm, recovery_count=rec_count,
            )
            outputs.append(oh)

            # Gründe sammeln — M2: stabile Kategorie-Keys ohne dynamische Zahlen
            # (title/action_key-Vergleiche im UI bleiben dadurch stabil, kein
            # Flackern). Konkrete Werte gehen ins Debug-Log.
            if stalled:
                reasons.append(f"Output '{name}' Ch{ch_offset+1}-{ch_offset+2}: stalled")
            if delta > 0:
                reasons.append(f"Output '{name}' Ch{ch_offset+1}-{ch_offset+2}: underruns detected")
                logger.debug("Health: '%s' Ch%d: %d new underrun(s)",
                             name, ch_offset + 1, delta)
            if abs(ppm) > 600:
                reasons.append(f"Output '{name}': SRC drift elevated (near limit)")
                logger.debug("Health: '%s' SRC drift %+.0f ppm", name, ppm)

        # Reconnect-Delta
        reconnect_delta = max(0, reconnect_count - self._last_reconnect_count)
        self._last_reconnect_count = reconnect_count
        if reconnect_delta > 0:
            # M2: stabiler Key — Anzahl ins Debug-Log.
            reasons.append("SHM reconnected")
            logger.debug("Health: SHM reconnected (%dx)", reconnect_delta)

        if not ioproc_alive and audio_flowing:
            reasons.append("IOProc not responding (age > 500ms)")

        if ring_fill < 0.10:
            # M2: stabiler Key — Füllstand ins Debug-Log.
            reasons.append("Ring buffer critically low")
            logger.debug("Health: ring fill %.0f%%", ring_fill * 100.0)
        elif ring_fill > 0.95:
            reasons.append("Ring buffer nearly full")
            logger.debug("Health: ring fill %.0f%%", ring_fill * 100.0)

        # ── Roh-Level-Klassifikation (vor Hysterese) ──────────────────
        any_stalled    = any(o.stalled for o in outputs)
        any_underrun   = any(o.underruns_delta > 0 for o in outputs)
        any_drift      = any(abs(o.src_ratio_ppm) > 600 for o in outputs)
        fill_critical  = (ring_fill < 0.10 or ring_fill > 0.95) and audio_flowing

        if (not ioproc_alive and audio_flowing) or any_stalled or reconnect_delta > 0:
            raw_level = "critical"
        elif any_underrun or any_drift or fill_critical:
            raw_level = "degraded"
        else:
            raw_level = "healthy"

        # ── Hysterese ─────────────────────────────────────────────────
        # Streak des aktuellen raw_level mitzählen.
        if raw_level != self._last_raw_level:
            self._raw_level_streak = 1
            self._last_raw_level = raw_level
        else:
            self._raw_level_streak += 1

        raw_ord     = self._level_ord(raw_level)
        current_ord = self._level_ord(self._current_reported_level)

        if raw_ord > current_ord:
            # Verschlechterung: schnell reagieren (DEGRADE_STREAK Samples).
            if self._raw_level_streak >= DEGRADE_STREAK:
                logger.info("Health: %s → %s | %s",
                            self._current_reported_level, raw_level,
                            "; ".join(reasons[:2]))
                self._current_reported_level = raw_level
        elif raw_ord < current_ord:
            # Verbesserung: langsam reagieren (IMPROVE_STREAK Samples) — kein Flackern.
            if self._raw_level_streak >= IMPROVE_STREAK:
                logger.info("Health: recovered to %s", raw_level)
                self._current_reported_level = raw_level

        sh = SystemHealth(
            level=self._current_reported_level,
            ring_frames=ring_frames,
            ring_fill_ratio=ring_fill,
            ioproc_alive=ioproc_alive,
            reconnect_count=reconnect_count,
            ioproc_age_ms=ioproc_age_ms,
            outputs=outputs,
            reasons=reasons,
        )
        self._current_health = sh
        return sh
