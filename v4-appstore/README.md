# AudioRouterNow v4.0 — App Store Edition (Planung)

Dieses Verzeichnis enthält den Implementierungsplan für AudioRouterNow v4.0,
eine komplett neue Architektur basierend auf macOS Process Taps (14.2+).

**Status:** Planung / Vorab-Phase
**Ziel:** Mac App Store Distribution ohne Admin-Installation

Hauptdokument: [PLAN.md](PLAN.md)

## Wichtigste Unterschiede zu v3.x

| v3.x (aktuell) | v4.0 (geplant) |
|----------------|----------------|
| HAL-Plugin (C) | Process Tap (Swift) |
| C-Daemon + Python UI | Reine Swift App |
| Admin-Installation | Kein Installer |
| Gatekeeper-Warnung | App Store |
| macOS 11+ | macOS 14.2+ |
