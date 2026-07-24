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
    # Default True → NSStackView-Popover (bleibt nach Klicks offen).
    # False → klassisches NSMenu (Fallback).
    use_popover_menu: bool = True
    # One-Time-Migration v3.4.3: erzwingt NSPopover fuer Bestands-User, die noch
    # den alten Default use_popover_menu=False gespeichert haben. Fehlt der Key in
    # der Config (alle Versionen < 3.4.3), feuert die Migration einmalig in
    # from_dict(). Danach bleibt der Key True und eine manuelle Rueckstellung auf
    # use_popover_menu=False wird respektiert (kein erneutes Ueberschreiben).
    popover_migrated: bool = True

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
        # One-Time-Migration v3.4.3 (NSPopover-Zwang fuer Bestands-User):
        # Get-Default fuer popover_migrated ist hier BEWUSST False (anders als der
        # Dataclass-Default True). Fehlt der Key, ist es eine Alt-Config (< 3.4.3)
        # → Migration feuert und erzwingt use_popover_menu=True. Idempotent:
        # erneutes Ausfuehren setzt nur True. Ist der Key bereits True, wird eine
        # manuelle use_popover_menu=False-Wahl respektiert.
        popover_migrated = bool(data.get("popover_migrated", False))
        use_popover_menu = bool(data.get("use_popover_menu", True))
        if not popover_migrated:
            use_popover_menu = True
            popover_migrated = True
        return cls(
            output_device_names=data.get("output_device_names", []),
            sample_rate=int(data.get("sample_rate", 48000)),
            auto_sample_rate=bool(data.get("auto_sample_rate", True)),
            buffer_size=int(data.get("buffer_size", 512)),
            donation_hint_shown=bool(data.get("donation_hint_shown", False)),
            onboarding_done=bool(data.get("onboarding_done", False)),
            safe_take_mode=bool(data.get("safe_take_mode", False)),
            output_device_offsets=offsets,
            use_popover_menu=use_popover_menu,
            popover_migrated=popover_migrated,
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
        # One-Time-Migration v3.4.3 SOFORT persistieren, damit der NSPopover-Zwang
        # auch bei einem spaeteren Force-Quit/Crash erhalten bleibt — sonst feuerte
        # die Migration bei jedem Start neu und ueberschriebe eine spaetere
        # manuelle use_popover_menu=False-Wahl. Nur wenn der Key zuvor fehlte.
        if "popover_migrated" not in data:
            save_config(config)
        return config
    except (json.JSONDecodeError, KeyError, TypeError) as e:
        logger.warning(f"Konfigurationsdatei konnte nicht gelesen werden: {e} — Standardwerte")
        return AppConfig()


def save_config(config: AppConfig):
    """
    Speichert die Konfiguration in ~/.audiorouter/config.json.

    Erstellt das Verzeichnis falls es nicht existiert.

    Merge-Save: Liest zuerst die existierende Datei und erhält alle
    unbekannten Felder (Forward-Compatibility). Bekannte Felder werden
    mit dem aktuellen Wert überschrieben. So gehen Felder neuerer App-
    Versionen (z.B. use_popover_menu) nicht verloren wenn eine ältere
    Version die Config speichert.
    """
    # M9: Atomares Schreiben via Temp-Datei + rename().
    # rename() ist auf macOS/POSIX atomar (gleiche Partition) — ein Absturz
    # während des Schreibens hinterlässt entweder die alte oder die neue
    # vollständige Datei, nie ein korrumpiertes Halb-JSON.
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        # Forward-Compat: Bestehende Felder lesen, um unbekannte zu erhalten.
        existing: dict = {}
        if CONFIG_FILE.exists():
            try:
                with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                    existing = json.load(f)
            except (json.JSONDecodeError, OSError):
                existing = {}
        # Merge: unbekannte Felder aus existing erhalten, bekannte überschreiben.
        merged = {**existing, **config.to_dict()}
        tmp_path = CONFIG_FILE.with_suffix(".tmp")
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(merged, f, indent=2, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        tmp_path.replace(CONFIG_FILE)  # atomares rename (POSIX garantiert)
        logger.debug(f"Konfiguration gespeichert: {CONFIG_FILE}")
    except OSError as e:
        logger.error(f"Konfiguration konnte nicht gespeichert werden: {e}")
