# AudioRouterNow — Installer Build

## Voraussetzungen

- macOS 11 (Big Sur) oder neuer
- Python 3.10+ (`python3 --version`)
- Xcode Command Line Tools (`xcode-select --install`)
- Fertig kompilierter HAL-Treiber: `../driver/build/AudioRouterNow.driver`

Treiber bauen falls noch nicht vorhanden:
```bash
cd ../driver && make
```

## Build

```bash
cd installer
./build.sh
```

Das Script:
1. Erstellt Python venv unter `.venv/`
2. Installiert App-Dependencies und PyInstaller
3. Baut `AudioRouterNow.app` (standalone, kein Python noetig)
4. Signiert die App (ad-hoc)
5. Erstellt `~/Desktop/AudioRouterNow.dmg`

Dauer: ~3–5 Minuten (beim ersten Mal laenger wegen Downloads).

## Ergebnis

`~/Desktop/AudioRouterNow.dmg` — dieser DMG kann auf jeden Mac
mit macOS 11+ kopiert und installiert werden.

## Installation auf einem neuen Mac

1. `AudioRouterNow.dmg` oeffnen
2. `AudioRouterNow.app` in `Applications` ziehen
3. App starten
4. Beim ersten Start: macOS fragt einmalig nach dem Passwort → HAL-Treiber wird automatisch installiert
5. Fertig — `🎛️` erscheint in der Menueleiste

## Ordnerstruktur nach dem Build

```
installer/
├── .venv/              ← Python-Umgebung (von build.sh erstellt)
├── build_output/       ← PyInstaller Zwischen-Artefakte
├── dist/
│   └── AudioRouterNow.app   ← Fertige .app
├── AudioRouterNow.spec ← PyInstaller Konfiguration
├── build.sh            ← Build-Script
└── README.md
```

## Neuen Build erstellen

Build-Artefakte loeschen und neu bauen:
```bash
rm -rf dist/ build_output/
./build.sh
```
