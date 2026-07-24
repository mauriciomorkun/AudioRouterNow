# AudioRouterNow — Python Engine (v2.0)

Die Python Engine ist in v2.0 ausschliesslich fuer UI und Konfiguration zustaendig.
Das Audio-Routing selbst uebernimmt der native C-Helper-Daemon (`AudioRouterNowHelper`)
ueber POSIX Shared Memory und CoreAudio direkt.

---

## Voraussetzungen

- macOS 11 (Big Sur) oder neuer
- Python 3.10 oder neuer
- HAL-Treiber installiert (siehe `../driver/README.md`)
- Helper-Binary vorhanden (siehe `../helper/`)

---

## Setup

### 1. Virtual Environment erstellen und aktivieren

```bash
cd /Users/mauriciomorkun/Desktop/AudioRouterNow/engine
python3 -m venv .venv
source .venv/bin/activate
```

### 2. Abhaengigkeiten installieren

```bash
pip install -r requirements.txt
```

> Hinweis: `sounddevice` und `numpy` sind in v2.0 keine Abhaengigkeiten mehr.
> Das Audio-Routing laeuft vollstaendig im nativen C-Helper.

---

## Starten

### Menu Bar Widget (empfohlen)

```bash
source .venv/bin/activate
python menu_bar_app.py
```

Das Widget erscheint in der Menueleiste als `🔇` (gestoppt) oder `🎛️` (aktiv).

### CLI (Diagnose und Konfiguration)

```bash
# Alle verfuegbaren CoreAudio-Devices mit UIDs anzeigen
python cli.py --list-devices

# Helper-Daemon pruefen
python cli.py --ping

# Helper-Status abfragen
python cli.py --status

# Output-Streams konfigurieren (UID aus --list-devices entnehmen)
python cli.py --set-outputs AppleHDAEngineOutput:0
python cli.py --set-outputs AppleHDAEngineOutput:0 AppleUSBAudio:2

# Helper-Daemon starten / stoppen
python cli.py --start-helper
python cli.py --stop-helper
```

---

## Architektur v2.0

```
macOS System-Audio
      |
      v
  HAL-Treiber (AudioRouterNow.driver)
      |  POSIX Shared Memory Ring Buffer (SHM)
      |  Float32 PCM
      v
  AudioRouterNowHelper  (C-Daemon, nativer CoreAudio)
      |  Config-Socket: /tmp/audiorouter.config.sock  (JSON-Lines)
      |  Python sendet: ping / get_status / set_outputs / shutdown
      |  CoreAudio direkt pro Output-Device
      +---> Komplete Audio 6 (6ch)
      +---> AirPods Pro (2ch)
      +---> MacBook Pro Lautsprecher (2ch)
      ...

  Python (Engine)
      |  UI + Konfiguration via HelperClient
      +---> Menu Bar Widget (menu_bar_app.py)
      +---> CLI (cli.py)
```

### Vergleich v1 vs. v2.0

| Schicht | v1 (Legacy) | v2.0 (aktuell) |
|---------|------------|----------------|
| Audio-Transport | Unix Socket (PCM-Bytes) | POSIX SHM Ring Buffer |
| Audio-Ausgabe | Python `sounddevice` | C-Daemon + CoreAudio direkt |
| Konfiguration | Python-intern | JSON-Lines Unix Socket |
| Python-Deps | sounddevice, numpy | nur ctypes (stdlib) |

---

## Dateien

| Datei | Beschreibung |
|---|---|
| `helper_client.py` | Steuert den C-Helper-Daemon via `/tmp/audiorouter.config.sock` |
| `device_manager.py` | CoreAudio Device-Liste + Hot-plug-Erkennung (ctypes, kein sounddevice) |
| `config.py` | Persistente Konfiguration (`~/.audiorouter/config.json`) |
| `menu_bar_app.py` | macOS Menu Bar Widget (rumps) |
| `cli.py` | Terminal-Interface fuer Diagnose und Konfiguration (v2.0) |
| `requirements.txt` | Python-Abhaengigkeiten |
| `socket_receiver.py` | **LEGACY** — v1, nicht mehr aktiv genutzt |
| `routing_engine.py` | **LEGACY** — v1, nicht mehr aktiv genutzt |

---

## Konfiguration

Die Konfiguration wird automatisch in `~/.audiorouter/config.json` gespeichert:

```json
{
  "outputs": [
    {"uid": "AppleHDAEngineOutput:1,0,1,1:0", "ch_offset": 0},
    {"uid": "AppleUSBAudio:1,0,0,0:0", "ch_offset": 0}
  ]
}
```

UIDs sind persistent ueber Reboot und Replug. Devices und UIDs anzeigen:

```bash
python cli.py --list-devices
```

---

## Troubleshooting

### Helper antwortet nicht

```bash
# Erreichbarkeit pruefen
python cli.py --ping

# Helper manuell starten
python cli.py --start-helper

# Logs pruefen
tail -f /tmp/audiorouter.helper.log
tail -f /tmp/audiorouter.helper.err
```

### Core Audio neu starten

```bash
sudo killall -9 coreaudiod
```

### Device wird nicht erkannt

```bash
python cli.py --list-devices
```

### Kein Ton, obwohl Routing aktiv

1. In macOS Systemeinstellungen > Ton pruefen ob "Audio Router" als Ausgabe gewaehlt ist
2. Oder im Menu Bar Widget: "System-Audio → Audio Router" klicken
3. Helper-Status pruefen: `python cli.py --status`
