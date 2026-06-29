"""
Config — Persistente Konfiguration fuer AudioRouterNow.

Speichert und laedt Einstellungen als JSON in ~/.audiorouter/config.json.

Gespeicherte Felder:
  - output_device_names: Liste von Device-Namen (nicht Indizes!)
  - sample_rate: Sample Rate in Hz
  - buffer_size: Buffer-Groesse in Frames

Hinweis: Device-Namen statt Indizes werden gespeichert, weil Indizes sich
nach einem Neustart oder beim An-/Abstecken von Devices aendern koennen.
"""

import json
import logging
import os
import tempfile
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Dict, List

logger = logging.getLogger(__name__)

# Verzeichnis fuer Konfigurationsdateien
CONFIG_DIR = Path.home() / ".audiorouter"
CONFIG_FILE = CONFIG_DIR / "config.json"


@dataclass
class AppConfig:
    """Alle persistenten Einstellungen der Applikation."""
    output_device_names: List[str] = field(default_factory=list)
    sample_rate: int = 48000
    auto_sample_rate: bool = True
    buffer_size: int = 512
    # Donation-Hinweis: wird einmalig nach erstem erfolgreichen Routing gezeigt
    donation_hint_shown: bool = False
    # First-Run-Wizard: wird einmalig nach der ersten Installation gezeigt
    onboarding_done: bool = False
    # Tranche B: Safe-Take-Modus — deaktiviert alle Heilungseingriffe
    safe_take_mode: bool = False
    # Channel-Offsets pro Device: device_name -> Liste aktiver Offsets
    # (0 = Ch 1-2, 2 = Ch 3-4, 4 = Ch 5-6, ...)
    # Mehrere Offsets = mehrere Kanal-Paare gleichzeitig aktiv
    output_device_offsets: Dict[str, List[int]] = field(default_factory=dict)
    # NSPopover-Migration (Option B): Feature-Flag fuer den Popover-Modus.
    # Default False → klassisches NSMenu (verhaltensidentisch zu v3.4.x).
    # True → NSStackView-Popover, der nach Klicks geoeffnet bleibt.
    use_popover_menu: bool = False

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "AppConfig":
        # Migration: altes Format war Dict[str, int], neues ist Dict[str, List[int]]
        raw_offsets = data.get("output_device_offsets", {})
        offsets: Dict[str, List[int]] = {}
        for k, v in raw_offsets.items():
            if isinstance(v, list):
                offsets[k] = [int(x) for x in v]
            else:
                offsets[k] = [int(v)]   # altes Single-Int-Format migrieren
        return cls(
            output_device_names=data.get("output_device_names", []),
            sample_rate=int(data.get("sample_rate", 48000)),
            auto_sample_rate=bool(data.get("auto_sample_rate", True)),
            buffer_size=int(data.get("buffer_size", 512)),
            donation_hint_shown=bool(data.get("donation_hint_shown", False)),
            onboarding_done=bool(data.get("onboarding_done", False)),
            safe_take_mode=bool(data.get("safe_take_mode", False)),
            output_device_offsets=offsets,
            use_popover_menu=bool(data.get("use_popover_menu", False)),
        )


def load_config() -> AppConfig:
    """
    Laedt die Konfiguration aus ~/.audiorouter/config.json.

    Falls die Datei nicht existiert oder ungueltiges JSON enthaelt,
    wird eine Standard-Konfiguration zurueckgegeben.
    """
    if not CONFIG_FILE.exists():
        logger.debug("Keine Konfigurationsdatei gefunden — Standardwerte werden verwendet")
        return AppConfig()

    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        config = AppConfig.from_dict(data)
        logger.info(f"Konfiguration geladen: {config.output_device_names}")
        return config
    except (json.JSONDecodeError, KeyError, TypeError) as e:
        logger.warning(f"Konfigurationsdatei konnte nicht gelesen werden: {e} — Standardwerte")
        return AppConfig()


def save_config(config: AppConfig):
    """
    Speichert die Konfiguration in ~/.audiorouter/config.json.

    Erstellt das Verzeichnis falls es nicht existiert.
    """
    # M9: Atomares Schreiben via Temp-Datei + rename().
    # rename() ist auf macOS/POSIX atomar (gleiche Partition) — ein Absturz
    # während des Schreibens hinterlässt entweder die alte oder die neue
    # vollständige Datei, nie ein korrumpiertes Halb-JSON.
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        tmp_path = CONFIG_FILE.with_suffix(".tmp")
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(config.to_dict(), f, indent=2, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        tmp_path.replace(CONFIG_FILE)  # atomares rename (POSIX garantiert)
        logger.debug(f"Konfiguration gespeichert: {CONFIG_FILE}")
    except OSError as e:
        logger.error(f"Konfiguration konnte nicht gespeichert werden: {e}")
