# AudioRouterNow — Python Engine (Phase 2)

Die Python Routing Engine empfaengt Audio-Daten vom HAL-Treiber via Unix Socket
und leitet sie an beliebige Core Audio Output-Devices weiter.

---

## Voraussetzungen

- macOS 11 (Big Sur) oder neuer
- Python 3.10 oder neuer
- HAL-Treiber installiert (siehe `../driver/README.md`)

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

---

## Starten

### Menu Bar Widget (empfohlen)

```bash
source .venv/bin/activate
python menu_bar_app.py
```

Das Widget erscheint in der Menueleiste als `🔇` (gestoppt) oder `🎛️` (aktiv).

### CLI (fuer Testing)

```bash
# Alle verfuegbaren Devices anzeigen
python cli.py --list-devices

# Routing starten (ein oder mehrere Outputs)
python cli.py --output "Komplete Audio 6"
python cli.py --output "Komplete Audio 6" --output "AirPods Pro"

# HAL-Treiber-Verbindung testen
python cli.py --test-socket
```

---

## Funktionsweise

```
macOS System-Audio
      |
      v
  HAL-Treiber (AudioRouterNow.driver)
      |  Unix Socket /tmp/audiorouter.sock
      |  Float32 PCM, 512 Frames × 2ch × 4 Bytes = 4096 Bytes/Block
      v
  SocketReceiver (socket_receiver.py)
      |  numpy-Array (512, 2) float32
      v
  RoutingEngine (routing_engine.py)
      |  sounddevice.OutputStream pro Output-Device
      |  Channel-Duplikation fuer > 2 Ausgaenge
      +---> Komplete Audio 6 (6ch)
      +---> AirPods Pro (2ch)
      +---> MacBook Pro Lautsprecher (2ch)
      ...
```

---

## Dateien

| Datei | Beschreibung |
|---|---|
| `socket_receiver.py` | Unix Socket Server, empfaengt PCM vom HAL-Treiber |
| `routing_engine.py` | Verteilt Frames auf Output-Devices |
| `device_manager.py` | Core Audio Device-Liste + Hot-plug-Erkennung |
| `config.py` | Persistente Konfiguration (~/.audiorouter/config.json) |
| `menu_bar_app.py` | macOS Menu Bar Widget (rumps) |
| `cli.py` | Terminal-Interface fuer Testing |
| `requirements.txt` | Python-Abhaengigkeiten |

---

## Konfiguration

Die Konfiguration wird automatisch in `~/.audiorouter/config.json` gespeichert:

```json
{
  "output_device_names": ["Komplete Audio 6", "AirPods Pro"],
  "sample_rate": 48000,
  "buffer_size": 512
}
```

---

## Troubleshooting

### HAL-Treiber verbindet sich nicht

```bash
# Core Audio neu starten (als Administrator)
sudo killall -9 coreaudiod
```

### Device wird nicht erkannt

```bash
python cli.py --list-devices
```

### Kein Ton, obwohl Routing aktiv

1. In macOS Systemeinstellungen > Ton pruefen ob "Audio Router" als Ausgabe gewaehlt ist
2. Oder im Menu Bar Widget: "System-Audio → Audio Router" klicken
