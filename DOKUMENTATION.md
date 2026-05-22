# AudioRouterNow — Vollständige Projektdokumentation

> Stand: 22.05.2026 (aktualisiert: Channel-Auswahl, IPC-Fix, Build-Fixes, Thread-Safety)
> Status: Voll funktionsfähig — Routing, Channel-Auswahl, HAL-IPC, DMG-Installer alle getestet

---

## Inhaltsverzeichnis

1. [Was ist AudioRouterNow?](#1-was-ist-audiorouter-now)
2. [Warum wurde es gebaut?](#2-warum-wurde-es-gebaut)
3. [Gesamtarchitektur](#3-gesamtarchitektur)
4. [Phase 1 — HAL-Treiber](#4-phase-1--hal-treiber)
5. [Phase 2 — Python Engine & Menu Bar](#5-phase-2--python-engine--menu-bar)
6. [Phase 3 — Installer & DMG](#6-phase-3--installer--dmg)
7. [Projektstruktur](#7-projektstruktur)
8. [Installation & Erster Start](#8-installation--erster-start)
9. [Entwicklung: Lokal testen](#9-entwicklung-lokal-testen)
10. [Technische Entscheidungen](#10-technische-entscheidungen)
11. [Roadmap & offene Punkte](#11-roadmap--offene-punkte)
12. [Donation-System](#12-donation-system)
13. [Session 22.05.2026 — Bugfixes & Features](#13-session-22052026--bugfixes--features)

---

## 1. Was ist AudioRouterNow?

AudioRouterNow ist eine macOS Menu-Bar-App die System-Audio auf beliebige Audio-Interfaces routet — gleichzeitig auf mehrere Outputs.

**Beispiel:** macOS-Systemklang soll auf Out 1/2 UND Out 3/4 eines externen Interfaces (z.B. Native Instruments Komplete Audio 6) gleichzeitig ausgegeben werden. macOS unterstützt das von Haus aus nicht — AudioRouterNow löst dieses Problem.

**Was der User sieht:**
- Ein kleines `🎛️`-Symbol in der macOS Menueleiste
- Klick → Liste aller angeschlossenen Audio-Interfaces erscheint
- Gewünschte Outputs anhaken → Routing startet sofort
- Kein Terminal, kein Neustart, kein technisches Vorwissen nötig

---

## 2. Warum wurde es gebaut?

### Vorgeschichte: Version 1 (`~/audio-router/`)

Im Mai 2026 wurde eine erste Python-Lösung gebaut die BlackHole 2ch als virtuellen Audio-Treiber nutzt. Diese Version funktioniert, hat aber zwei grundlegende Probleme:

**Problem 1 — Lizenz:**  
BlackHole ist unter **GPL-3.0** lizenziert. Eine kommerzielle Nutzung ohne Lizenz-Vereinbarung mit ExistentialAudio ist nicht erlaubt.

**Problem 2 — Schlechte User Experience:**  
BlackHole ist eine Kernel Extension (kext). Installation erfordert:
1. Manuelle Genehmigung in macOS Systemeinstellungen → Datenschutz & Sicherheit
2. System-Neustart
3. Erst danach ist die App nutzbar

### Die Lösung: AudioRouterNow

Eigener virtueller Audio-Treiber auf Basis von **Apple AudioServerPlugin** — kein Fremdcode, keine Kernel Extension, kein Neustart. Vollständig im Besitz des Entwicklers, kommerziell verwertbar.

| | BlackHole (v1) | AudioRouterNow (v2) |
|---|---|---|
| Lizenz | GPL-3.0 ❌ | Proprietär ✅ |
| Kernel Extension | Ja ❌ | Nein ✅ |
| Security-Approval | Ja, manuell ❌ | Nein ✅ |
| Neustart nötig | Ja ❌ | Nein ✅ |
| Alle Interfaces | Fix ❌ | Konfigurierbar ✅ |
| Kommerziell | Nein ❌ | Ja ✅ |

---

## 3. Gesamtarchitektur

```
┌─────────────────────────────────────────────────────┐
│                   macOS System                      │
│                                                     │
│  Beliebige App         Systemeinstellungen → Ton    │
│  (Spotify, YouTube...) Output: "Audio Router" ←──  │
└────────────┬────────────────────────────────────────┘
             │ PCM Float32, 48kHz, Stereo, 512 Frames
             ▼
┌─────────────────────────────────────────────────────┐
│         AudioRouterNow.driver                       │
│         (Apple AudioServerPlugin — C)               │
│                                                     │
│  • Virtuelles Output-Device "Audio Router"          │
│  • Installiert in /Library/Audio/Plug-Ins/HAL/      │
│  • Geladen von coreaudiod (kein Neustart nötig)     │
│  • Leitet Audio via Unix Socket weiter              │
└────────────┬────────────────────────────────────────┘
             │ Unix Domain Socket: /tmp/audiorouter.sock
             │ Float32 PCM, 4096 bytes/Block
             ▼
┌─────────────────────────────────────────────────────┐
│         Python Engine (socket_receiver.py)          │
│         Empfängt PCM-Frames vom Treiber             │
└────────────┬────────────────────────────────────────┘
             │ numpy arrays
             ▼
┌─────────────────────────────────────────────────────┐
│         RoutingEngine (routing_engine.py)           │
│         Verteilt Frames auf Output-Devices          │
│                                                     │
│  sounddevice.OutputStream  sounddevice.OutputStream │
│       Out 1/2 + Out 3/4         AirPods             │
│       (Komplete Audio 6)        (Bluetooth)         │
└─────────────────────────────────────────────────────┘
             ▲
             │ Device-Liste, Hot-plug Events
┌────────────┴────────────────────────────────────────┐
│         DeviceManager (device_manager.py)           │
│         Polling alle 2s, Callback bei Änderung      │
└─────────────────────────────────────────────────────┘
             ▲
             │ User-Interaktion
┌────────────┴────────────────────────────────────────┐
│         Menu Bar Widget (menu_bar_app.py)           │
│         rumps App, LSUIElement=True                 │
│                                                     │
│  🎛️ AudioRouterNow                                  │
│  ─────────────────────────                          │
│  🟢 Aktiv                                           │
│  ⏹ Routing stoppen                                  │
│  System-Audio → Audio Router                        │
│  OUTPUT DEVICES:                                    │
│    ☑ Komplete Audio 6 — 6ch                        │
│    ☐ MacBook Pro Lautsprecher                       │
│    ☐ AirPods Pro                                    │
│  Beenden                                            │
└─────────────────────────────────────────────────────┘
```

### Thread-Architektur

```
Main Thread:            rumps App Loop (Menu Bar UI)
SocketReceiver Thread:  Unix Socket Server + PCM-Empfang
DeviceManager Thread:   Hot-plug Polling alle 2 Sekunden
OutputStream Threads:   sounddevice interne RT-Threads (je Output)
```

---

## 4. Phase 1 — HAL-Treiber

### Was gebaut wurde

**Datei:** `driver/src/AudioRouterNowDriver.c` — 1686 Zeilen C-Code

Ein vollständiger Apple AudioServerPlugin-Treiber der:
- Ein virtuelles Stereo-Output-Device "Audio Router" in Core Audio erstellt
- **Kein Kernel Extension** — läuft als HAL Plugin in User Space
- Kein Neustart, keine Security-Genehmigung erforderlich
- Unterstützt Sample Rates: 44100, 48000, 96000 Hz
- Buffer Size: 512 Frames
- Leitet PCM-Daten non-blocking via Unix Domain Socket weiter

### Technische Details

**Objektmodell (statisch, 6 Objekte):**
```
PlugIn (ID 1)
└── Box (ID 2)
    └── Device (ID 3) — "Audio Router"
        ├── Output-Stream (ID 4) — 2ch Float32
        ├── Volume-Control (ID 5)
        └── Mute-Control (ID 6)
```

**IPC-Design (RT-sicher):**
- `DoIOOperation` (Realtime-Thread): nur non-blocking `send(..., MSG_DONTWAIT)` — kein malloc, kein Blocking
- Separater Connector-Thread: verwaltet Socket-Verbindung, reconnect alle 500ms
- `SO_NOSIGPIPE` verhindert SIGPIPE wenn Python nicht lauscht

**Build:**
```bash
cd driver
make                # baut Universal Binary (arm64 + x86_64)
sudo make install   # installiert nach /Library/Audio/Plug-Ins/HAL/
sudo make reload    # killall coreaudiod → Treiber wird geladen
```

**Ergebnis:** `driver/build/AudioRouterNow.driver` — Universal Binary, ad-hoc signiert

---

## 5. Phase 2 — Python Engine & Menu Bar

### Was gebaut wurde

**7 Module, ~1400 Zeilen Python** in `engine/`

#### `socket_receiver.py` (~200 Zeilen)
- Unix Domain Socket **Server** (bind + listen + accept)
- **`os.chmod(SOCKET_PATH, 0o777)` nach bind()** — kritisch: HAL-Treiber läuft als `_coreaudiod` (UID 202), braucht Write-Permission um connect() aufzurufen
- Empfängt Float32 PCM-Blöcke vom HAL-Treiber (4096 bytes = 512 frames × 2ch × 4 bytes)
- Reconnect-Logic: nach Verbindungstrennung sofort wieder `accept()`
- Läuft in eigenem Daemon-Thread
- Gibt `numpy` arrays weiter via Callback

#### `routing_engine.py` (~310 Zeilen)
- Empfängt numpy arrays von SocketReceiver
- Schreibt gleichzeitig zu mehreren `sounddevice.OutputStream`-Instanzen
- **Channel-Offset-Support**: `OutputTarget.channel_offset` + `channel_selectors` in sounddevice — routet zu beliebigem Stereo-Paar eines N-Kanal-Devices
- Öffnet immer 2-Kanal-Streams (Stereo); `channel_selectors=[offset, offset+1]` wählt das gewünschte Paar
- Queue-basierter Hot-Path: kein Blocking im Realtime-Pfad
- Thread-safe: `start()`, `stop()`, `reconfigure()` mit Lock

#### `device_manager.py` (235 Zeilen)
- Listet alle Core Audio Output-Devices via `sounddevice`
- Filtert eigenes "Audio Router" Virtual Device heraus
- **Hot-plug**: Polling alle 2 Sekunden, Callback bei Änderung
- Gibt zurück: `AudioDevice(index, name, max_output_channels, default_samplerate)`

#### `menu_bar_app.py` (~420 Zeilen)
- rumps Menu Bar App (`LSUIElement=True` → kein Dock-Icon)
- Device-Checkboxen: mehrere Outputs gleichzeitig wählbar
- **Channel-Auswahl**: Multi-Channel-Devices (>2ch) zeigen Untermenü mit Stereo-Paaren (Ch 1-2, Ch 3-4, …)
- Hot-plug → Menu automatisch neu aufbauen
- **Natives System-Audio-Umschalten** via CoreAudio ctypes (`audio_device_control.py`) — kein externes Tool, kein AppleScript
- Gespeicherte Output-Devices + Channel-Offsets beim Start wiederherstellen
- Thread-Safety: Hintergrund-Threads setzen nur Flags — einziger Haupt-Thread-Timer (0.25s) verarbeitet Updates
- Donation-System (permanenter Menüpunkt + einmaliger Hint)

#### `config.py` (~90 Zeilen)
- Liest/schreibt `~/.audiorouter/config.json`
- Speichert Device-**Namen** (nicht Indizes — robust bei Neustart)
- `output_device_offsets: Dict[str, int]` — Channel-Offset pro Device (0 = Ch 1-2, 2 = Ch 3-4, etc.)
- `donation_hint_shown: bool` — einmaliger Hint-Flag
- Graceful Fallback bei fehlender oder korrupter Config

#### `audio_device_control.py` (~120 Zeilen) — NEU
- Ersetzt AppleScript (`tell sound preferences`) das in macOS 26 entfernt wurde
- Direkte CoreAudio-Aufrufe via Python ctypes — kein externes Tool
- `set_default_output_device(name)` — setzt macOS System-Audio-Ausgang
- `get_all_coreaudio_output_devices()` — listet alle Output-Devices
- Verwendet `AudioObjectGetPropertyData` / `AudioObjectSetPropertyData` direkt

#### `first_launch.py` (223 Zeilen)
- Prüft ob HAL-Treiber installiert ist
- Falls nicht: nativer macOS-Dialog via `osascript` → Passwortabfrage
- Installiert Treiber mit `with administrator privileges`
- Startet `coreaudiod` neu
- Kein Terminal, kein manueller Schritt

#### `cli.py` (256 Zeilen)
```bash
python cli.py --list-devices                          # alle Devices anzeigen
python cli.py --output "Komplete Audio 6"             # routing starten
python cli.py --output "KA6" --output "AirPods Pro"  # mehrere Outputs
python cli.py --test-socket                           # HAL-Treiber-Verbindung testen
```

---

## 6. Phase 3 — Installer & DMG

### Was gebaut wurde

**3 Dateien** in `installer/`

#### `AudioRouterNow.spec`
PyInstaller-Konfiguration:
- Entry Point: `engine/menu_bar_app.py`
- HAL-Treiber Bundle eingebettet (`datas`)
- **`target_arch="arm64"`** (nicht `universal2` — cffi hat keine fat binary)
- `LSUIElement=True` → kein Dock-Icon
- Bundle ID: `com.audiorouter.now`
- Alle Hidden Imports für rumps, sounddevice, pyobjc, audio_device_control
- `entitlements_file` → `entitlements.plist` (für Code Signing)
- **Keine `.py`-Dateien in `datas`** — codesign schlägt fehl bei nicht-signierbaren Dateien

#### `build.sh`
Vollautomatisches Build-Script:
1. Python venv erstellen (`.venv/`)
2. Dependencies + PyInstaller + Pillow installieren
3. `AudioRouterNow.app` bauen (arm64)
4. **Ad-hoc Code Signing** (kein `--deep`; `.dylib`, `.so`, Python Framework einzeln signieren; dann Bundle mit Entitlements)
5. **DMG-Hintergrundbild** generieren (Pillow, 620×400px, Drag-Arrow)
6. DMG als UDRW erstellen → AppleScript für Icon-Layout → UDZO komprimieren
7. Ausgabe: `~/Desktop/AudioRouterNow.dmg`

```bash
cd installer && ./build.sh
```

**Bekannte Besonderheit beim Installieren:**
```bash
# RICHTIG — altes .app zuerst löschen:
rm -rf /Applications/AudioRouterNow.app
cp -r dist/AudioRouterNow.app /Applications/AudioRouterNow.app

# FALSCH — cp -r ohne rm erstellt verschachteltes .app:
cp -r dist/AudioRouterNow.app /Applications/AudioRouterNow.app  # ← erzeugt .app/.app!
```

#### `entitlements.plist` — NEU
Code-Signing-Entitlements für ad-hoc Signing ohne Apple Developer ID:
```xml
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
```
**Warum nötig:** PyInstaller bündelt Homebrew-Python mit dessen Team-ID. macOS Sequoia+ (und macOS 26) verweigern das Laden wenn Team-ID des Bundles von Libraries abweicht. `disable-library-validation` erlaubt gemischte Team-IDs.

#### `create_dmg_background.py` — NEU
Generiert das DMG-Hintergrundbild (620×400px) mit Pillow:
- Dunkler macOS-Stil-Gradient
- Blauer Pfeil von App-Icon (links) zu Applications-Ordner (rechts)
- "Drag to install" Text

#### User Experience nach Installation

```
Schritt 1: AudioRouterNow.dmg oeffnen
           → App in Applications ziehen

Schritt 2: App starten (Doppelklick)
           → "AudioRouterNow muss den Audio-Treiber installieren"
           → [OK] klicken → macOS Passwortdialog erscheint
           → Passwort eingeben

Schritt 3: "🎛️" erscheint in der Menueleiste
           → Fertig — kein Neustart, kein Terminal
```

---

## 7. Projektstruktur

```
~/Desktop/AudioRouterNow/
│
├── DOKUMENTATION.md        ← Diese Datei
│
├── driver/                 ← Phase 1: HAL-Treiber (C)
│   ├── src/
│   │   └── AudioRouterNowDriver.c   (1686 Zeilen)
│   ├── resources/
│   │   └── Info.plist
│   ├── build/
│   │   └── AudioRouterNow.driver/   ← Fertig kompiliert ✅
│   ├── Makefile
│   └── README.md
│
├── engine/                 ← Phase 2: Python App
│   ├── menu_bar_app.py         (~420 Zeilen) — Menu Bar Widget + Channel-Auswahl
│   ├── routing_engine.py       (~310 Zeilen) — Audio-Routing + Channel-Offset
│   ├── socket_receiver.py      (~200 Zeilen) — Unix Socket Server (chmod 0o777)
│   ├── device_manager.py       (235 Zeilen)  — Device Discovery
│   ├── first_launch.py         (223 Zeilen)  — Erststart-Installer
│   ├── config.py               (~90 Zeilen)  — Config (inkl. device_offsets)
│   ├── audio_device_control.py (~120 Zeilen) — CoreAudio ctypes (NEU)
│   ├── cli.py                  (256 Zeilen)  — Terminal Interface
│   ├── requirements.txt
│   └── README.md
│
└── installer/              ← Phase 3: Build & Distribution
    ├── AudioRouterNow.spec         ← PyInstaller (arm64, entitlements)
    ├── build.sh                    ← Build-Script (vollautomatisch)
    ├── entitlements.plist          ← Code-Signing-Entitlements (NEU)
    ├── create_dmg_background.py    ← DMG-Hintergrundbild-Generator (NEU)
    └── README.md
```

---

## 8. Installation & Erster Start

### Neuen Mac einrichten (Enduser)

1. `AudioRouterNow.dmg` öffnen
2. `AudioRouterNow.app` in `Applications` ziehen
3. App aus Applications starten
4. macOS-Passwortdialog: Passwort eingeben (einmalig)
5. `🎛️` erscheint in der Menueleiste

### Audio-Routing einrichten

1. Auf `🎛️` klicken
2. Unter "OUTPUT DEVICES" gewünschte Interfaces anhaken
3. "System-Audio → Audio Router" klicken (oder manuell in Systemeinstellungen → Ton → Audio Router wählen)
4. "Routing starten" klicken
5. Audio läuft nun auf allen gewählten Outputs

---

## 9. Entwicklung: Lokal testen

### Voraussetzungen installieren

```bash
cd engine
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### HAL-Treiber installieren

```bash
cd driver
make
sudo make install
sudo make reload
```

Prüfen ob Device erkannt wird:
```bash
python3 -c "import sounddevice; print([d for d in sounddevice.query_devices() if 'Audio Router' in d['name']])"
```

Erwartete Ausgabe: `[{'name': 'Audio Router', ..., 'max_output_channels': 2, ...}]`

### App starten

```bash
cd engine
source .venv/bin/activate
python menu_bar_app.py
```

### IPC testen (ohne Menu Bar)

```bash
cd engine
source .venv/bin/activate
python cli.py --test-socket
```

Dann in macOS System Audio auf "Audio Router" schalten — der CLI zeigt empfangene Datenpakete.

### DMG bauen

```bash
cd installer
./build.sh
# Ergebnis: ~/Desktop/AudioRouterNow.dmg
```

---

## 10. Technische Entscheidungen

### AudioServerPlugin statt Kernel Extension
Apple-eigene API seit macOS 10.14. Läuft in User Space als HAL Plugin. Kein kext, kein Security-Approval, kein Neustart. Perfekt für Redistribution.

### C statt Swift für den Treiber
Die AudioServerPlugin-API ist eine C COM-Schnittstelle mit Funktionszeigern. Reines C ist stabiler, hat keine Swift-Runtime-Abhängigkeit in `coreaudiod`, und ist einfacher als Universal Binary zu bauen.

### Unix Domain Socket für IPC
Zuverlässig, low-latency, funktioniert problemlos zwischen C (Treiber in coreaudiod) und Python. Non-blocking auf Treiber-Seite verhindert Blocking im RT-Thread.

### Python für Engine & UI
Bestehende sounddevice + rumps Expertise aus v1. Schnelle Entwicklung, gute macOS-Integration via pyobjc. PyInstaller macht es standalone.

### Device-Namen statt Indizes in Config
Core Audio ändert Device-Indizes bei jedem Systemstart. Namen bleiben stabil → robuste Config.

### macOS 11 (Big Sur) als Minimum
Erste Version mit Apple Silicon Support. Deckt ~95% aller aktiven Macs ab (2026). AudioServerPlugin voll unterstützt.

### Keine externen Tools — CoreAudio ctypes statt SwitchAudioSource/AppleScript

**Verlauf:**
1. Version 1: `SwitchAudioSource` (Homebrew) für System-Audio-Umschaltung — externe Abhängigkeit
2. Version 2a: `osascript / tell sound preferences` — kein externes Tool, aber AppleScript
3. Version 2b (aktuell): Direkter CoreAudio-Aufruf via Python ctypes

**Warum kein AppleScript mehr:**
`tell sound preferences` wurde in **macOS 26** aus System Events entfernt. Fehler:
```
syntax error: "Identifier" kann nicht diesem "Identifier" folgen. (-2740)
```

**Aktuelle Lösung: `audio_device_control.py`**
```python
# AudioObjectSetPropertyData direkt via ctypes
CoreAudio = ctypes.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
prop = _AudioObjectPropertyAddress(
    mSelector=0x644F7574,  # 'dOut' — kAudioHardwarePropertyDefaultOutputDevice
    mScope=0x676C6F62,     # 'glob'
    mElement=0
)
CoreAudio.AudioObjectSetPropertyData(kAudioObjectSystemObject, ...)
```
Vorteile: Kein externes Tool, kein AppleScript, kompatibel mit allen macOS-Versionen, direkte API.

### Unix Domain Socket Permissions — kritischer Fix

**Problem:** HAL-Treiber läuft als Prozess `_coreaudiod` (UID 202, Gruppe `_coreaudiod`). Die Python Engine läuft als normaler User. Der Socket wurde mit Standard-Umask `0755` (`srwxr-xr-x`) erstellt — "others" hat `r-x` (kein Write).

**Unix-Domain-Socket-Regel:** `connect()` braucht **Write-Permission** auf der Socket-Datei.

**Symptom:** `_coreaudiod` konnte sich nie verbinden → kein Audio, obwohl App "Aktiv" zeigte.

**Fix:** In `socket_receiver.py` nach `server.bind(SOCKET_PATH)`:
```python
os.chmod(SOCKET_PATH, 0o777)  # _coreaudiod (anderen User) connect() erlauben
```

### Thread-Safety: Pending-Flags statt rumps.Timer aus Hintergrund-Threads

**Problem:** `DeviceManager` und `RoutingEngine` riefen `rumps.Timer(callback, 0.0).start()` aus ihren Background-Threads auf. `NSTimer.scheduledTimerWithTimeInterval` schedult in den RunLoop des **aktuellen Threads** — Background-Threads haben keinen aktiven RunLoop. Timer feuerten nie.

**Symptom:** Status-Updates und Device-Liste-Updates wurden nie im UI angezeigt.

**Fix:** Einziger Haupt-Thread-Timer (0.25s) in `menu_bar_app.__init__`, Hintergrund-Threads setzen nur atomare Flags:
```python
# Background thread:
self._device_update_pending = True     # kein Timer, nur Flag

# Main thread (alle 0.25s):
def _process_pending_updates(self, timer):
    if self._device_update_pending:
        self._device_update_pending = False
        self._build_menu()
```

### Channel-Auswahl via sounddevice channel_selectors

Für Multi-Channel-Devices (>2ch) öffnet die RoutingEngine immer einen 2-Kanal-Stream mit `channel_selectors`:
```python
stream = sd.OutputStream(
    device=target.device_index,
    channels=2,
    channel_selectors=[target.channel_offset, target.channel_offset + 1],
    samplerate=48000, ...
)
```
Beispiel: Ch 3-4 eines 6ch-Devices → `channel_selectors=[2, 3]` (0-indexed).

### PyInstaller Code Signing auf macOS 26 (ohne Developer ID)

**Problem:** PyInstaller bündelt Homebrew-Python mit Homebrew Team-ID. macOS Sequoia/26 verweigert das Laden bei Team-ID-Konflikt (Fehler: `mapping process and mapped file have different Team IDs`).

**Lösung:**
1. `entitlements.plist` mit `com.apple.security.cs.disable-library-validation`
2. Signing ohne `--deep` (scheitert an `.dist-info` Verzeichnissen von pip)
3. Manuelles Bottom-Up Signing: `.dylib` → `.so` → Python Framework → Executable → Bundle

**`target_arch="arm64"` statt `universal2`:**
`cffi` und andere C-Extensions liegen nur als `arm64` vor (kein fat binary) → `universal2` Build schlägt fehl mit `IncompatibleBinaryArchError`.

---

## 11. Roadmap & offene Punkte

### Erledigt ✅
- [x] HAL-Treiber (AudioServerPlugin, C, Universal Binary)
- [x] Unix Socket IPC
- [x] Python Routing Engine (multi-output, N-channel)
- [x] Menu Bar Widget mit Device-Picker
- [x] Hot-plug Detection
- [x] Persistente Konfiguration (Device-Namen + Channel-Offsets)
- [x] First-Launch-Installer (kein Terminal)
- [x] CLI Interface
- [x] PyInstaller Build (arm64, entitlements)
- [x] DMG Installer (mit Hintergrundbild + Drag-Arrow)
- [x] Donation-System (Buy Me a Coffee, einmaliger Hint, Menu-Footer)
- [x] Natives System-Audio-Umschalten via CoreAudio ctypes (kein AppleScript, kein externes Tool)
- [x] IPC-Fix: Socket chmod(0o777) — HAL-Treiber (_coreaudiod) kann verbinden
- [x] Thread-Safety-Fix: Pending-Flags statt NSTimer aus Background-Threads
- [x] Bug-Fix: Device-Liste erscheint beim Start (build_menu nach device_manager.start())
- [x] Channel-Auswahl: Stereo-Paar-Untermenü für Multi-Channel-Devices
- [x] Build-Fix: Verschachteltes .app bei Installation verhindert (rm -rf vor cp)

### Ausstehend 🔲
- [ ] **Testen** — Treiber installieren + App starten + End-to-End Test
- [ ] **Apple Developer ID** — für Gatekeeper-Kompatibilität auf fremden Macs ($99/Jahr)
- [ ] **Notarisierung** — Apple Notarization für saubere Distribution
- [ ] **App-Icon** — eigenes Icon statt Standard
- [ ] **GitHub-Repo** — Open Source Veröffentlichung (GitHub-Account erstellen)
- [ ] **Auto-Update** — Sparkle Framework oder manueller Update-Check
- [ ] **Testen auf Intel Mac** — Universal Binary verifizieren
- [ ] **Testen auf macOS 11/12/13** — Kompatibilität sicherstellen

---

## 12. Donation-System

### Ziel & Philosophie

AudioRouterNow ist **kostenlos und bleibt es**. Das Donation-System dient ausschliesslich der Anerkennung — kein Monetarisierungsziel, kein Druck. Entscheidung basiert auf einem LLM-Council (5 unabhängige Berater-Perspektiven, 21.05.2026).

### Plattform

| Plattform | URL |
|---|---|
| **Buy Me a Coffee** | [buymeacoffee.com/mauriciomorkun](https://www.buymeacoffee.com/mauriciomorkun) |

Begründung: Kein GitHub-Account nötig, einfache Einrichtung, einmaliger Zahlungslink, keine Abo-Dynamik. GitHub Sponsors bleibt optional für später (sobald GitHub-Account vorhanden).

### Design-Entscheidungen (Council-Empfehlungen)

| Entscheidung | Umgesetzt | Begründung |
|---|---|---|
| **3-Tage-Reminder** | ❌ Gestrichen | Zeit-Trigger = Nag-Ware, 1-Sterne-Reviews |
| **Wert-basierter Hint** | ✅ Einmalig | Erst nach erstem erfolgreichen Routing |
| **Kein Wunschbetrag im UI** | ✅ | Kein Preisdruck, kein Tarif-Gefühl |
| **Kein Usage-Tracking** | ✅ | Vertrauensbasis der Zielgruppe nicht brechen |
| **Permanenter Menüpunkt** | ✅ | Immer sichtbar, nie aufdringlich |
| **Persönlicher Ton** | ✅ | "Hi, I'm Mauricio" — kein Marketing |

### Implementierung

#### Geänderte Dateien

**`engine/config.py`**
- Neues Feld in `AppConfig`: `donation_hint_shown: bool = False`
- Wird auf `True` gesetzt sobald der Hint einmal gezeigt wurde
- Persistiert in `~/.audiorouter/config.json` → Hint erscheint **nie wieder**

**`engine/menu_bar_app.py`**
- Neue Konstanten:
  ```python
  DONATION_URL = "https://www.buymeacoffee.com/mauriciomorkun"
  DONATION_HINT_DELAY = 15  # Sekunden nach erstem Routing
  ```
- Neuer permanenter Menüpunkt: `☕  Support AudioRouterNow` → öffnet BMAC im Browser
- Neuer Footer (nicht klickbar): `Made with ♥ by Mauricio · free forever`
- Einmaliger Hint-Trigger in `_on_routing_status()`: beim ersten `is_running=True`
- Hint-Anzeige via `rumps.notification()` nach 15 Sekunden Delay

#### Menu-Struktur (nach Änderung)

```
🎛️ AudioRouterNow
─────────────────────────
🟢 Aktiv
─────────────────────────
⏹ Routing stoppen
─────────────────────────
System-Audio → Audio Router
─────────────────────────
OUTPUT DEVICES:
  ☑ Komplete Audio 6 — 6ch
  ☐ MacBook Pro Lautsprecher
─────────────────────────
☕  Support AudioRouterNow       ← öffnet buymeacoffee.com/mauriciomorkun
Made with ♥ by Mauricio · free forever
─────────────────────────
Beenden
```

#### Einmaliger Hint (macOS Notification)

Wird ausgelöst: **erstes erfolgreiches Routing**, 15 Sekunden nach Start.
Erscheint: **genau einmal**, danach dauerhaft deaktiviert.

```
AudioRouterNow is working 🎛️
──────────────────────────────
Hi, I'm Mauricio — I built this on my own.
It's free and always will be.
If it saves you time, you can support via ☕ in the menu.
```

#### Logik-Ablauf

```
Erster Start
    │
    ├─ Routing startet erfolgreich (is_running = True)
    │       │
    │       ├─ donation_hint_shown == False?
    │       │       │
    │       │       ├─ Ja → hint_shown = True speichern
    │       │       │        → Timer 15s → Notification zeigen
    │       │       │
    │       │       └─ Nein → nichts tun (nie wieder)
    │
Alle weiteren Starts → donation_hint_shown == True → kein Hint
```

### Steuerlicher Hinweis

Donations über Buy Me a Coffee sind in Deutschland **einkommensteuerlich meldepflichtige Einnahmen**. Bei regelmässigen oder grösseren Beträgen Kleinunternehmerregelung oder Gewerbeanmeldung prüfen. Nicht für Donations, aber für spätere Kommerzialisierung relevant.

---

## 13. Session 22.05.2026 — Bugfixes & Features

### Überblick

In dieser Session wurden 4 kritische Bugs behoben und 1 Feature implementiert. Die App ist jetzt vollständig funktionsfähig — Audio fließt vom HAL-Treiber durch die Python Engine zu den physischen Ausgabegeräten.

---

### Bug 1: "(keine Devices gefunden)" — Device-Liste leer beim Start

**Symptom:** Das Widget startete, aber die OUTPUT DEVICES Liste zeigte "(keine Devices gefunden)" obwohl Interfaces angeschlossen waren.

**Root Cause:** `_build_menu()` wurde in `__init__` aufgerufen **bevor** `_device_manager.start()` — der `_known_devices` Cache war noch leer. Dazu: `_restore_saved_outputs()` hatte einen Early-Return bei fehlenden gespeicherten Devices (Fresh Install) und rief `_build_menu()` nie auf.

**Fix in `menu_bar_app.py`:**
```python
# Vorher (falsche Reihenfolge):
self._build_menu()            # ← _known_devices leer
self._device_manager.start()  # ← befüllt _known_devices
self._restore_saved_outputs() # ← early return bei Fresh Install

# Nachher (korrekt):
self._device_manager.start()   # ← befüllt _known_devices zuerst
self._socket_receiver.start()
self._restore_saved_outputs()  # ← ruft _build_menu() immer auf (kein early return mehr)
```

`_restore_saved_outputs()` ruft jetzt immer `_build_menu()` am Ende auf — unabhängig davon ob gespeicherte Devices vorhanden sind oder nicht.

---

### Bug 2: Thread-Safety — UI-Updates kamen nie an

**Symptom:** Status-Änderungen (Aktiv/Gestoppt) und Device-Liste-Updates wurden im UI nicht reflektiert.

**Root Cause:** `_on_routing_status()` und `_on_devices_changed()` riefen `rumps.Timer(callback, 0.0).start()` aus Background-Threads auf. `NSTimer` muss im Main RunLoop laufen — Background-Threads haben keinen.

**Fix:** Einziger Polling-Timer im Main Thread, Background-Threads setzen nur Flags:
```python
self._ui_timer = rumps.Timer(self._process_pending_updates, 0.25)
self._ui_timer.start()  # läuft im Main Thread's NSRunLoop

def _on_devices_changed(self, new_devices):
    self._device_update_pending = True  # kein Timer-Aufruf

def _process_pending_updates(self, timer):
    if self._device_update_pending:
        self._device_update_pending = False
        self._build_menu()
```

---

### Bug 3: Kein Ton — HAL-Treiber verbindet sich nicht zum Socket

**Symptom:** App zeigte "Aktiv", Routing lief, aber kein Audio kam aus den gewählten Interfaces.

**Diagnose:**
```bash
lsof /tmp/audiorouter.sock
# Zeigte nur die Python App als Server — kein Client-Eintrag
ls -la /tmp/audiorouter.sock
# srwxr-xr-x 1 mauriciomorkun wheel → "others": r-x (kein Write!)
id _coreaudiod
# uid=202(_coreaudiod) gid=202(_coreaudiod) → NICHT in wheel-Gruppe
```

**Root Cause:** `connect()` auf Unix-Domain-Sockets braucht Write-Permission. `_coreaudiod` (UID 202) fällt unter "others" → `r-x` → kein Write → `connect()` verweigert. HAL-Treiber konnte nie eine Verbindung aufbauen.

**Fix in `socket_receiver.py`:**
```python
server.bind(SOCKET_PATH)
os.chmod(SOCKET_PATH, 0o777)  # ← NEU: _coreaudiod darf jetzt connect()
server.listen(1)
```

**Verifikation nach Fix:**
```bash
lsof /tmp/audiorouter.sock
# COMMAND   PID           USER  FD   TYPE  …
# AudioRout 73552  mauricio…   4u  unix  …  ← Server (listen)
# AudioRout 73552  mauricio…   5u  unix  …  ← akzeptierte Verbindung vom HAL-Treiber ✓
```

---

### Bug 4: AppleScript `tell sound preferences` — macOS 26 entfernt

**Symptom:** System-Audio-Umschaltung schlug fehl mit:
```
syntax error: "Identifier" kann nicht diesem "Identifier" folgen. (-2740)
```

**Root Cause:** Apple hat `sound preferences` aus System Events Scripting-Dictionary in **macOS 26** entfernt.

**Fix:** Neue Datei `engine/audio_device_control.py` — direkte CoreAudio-Aufrufe via Python ctypes:
```python
CoreAudio = ctypes.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
# AudioObjectSetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, sizeof(AudioObjectID), &deviceID)
```

Keine externe Abhängigkeit, kein AppleScript, kompatibel mit allen macOS-Versionen.

---

### Feature: Channel-Auswahl für Multi-Channel-Devices

**Was wurde gebaut:**

Für Audio-Interfaces mit mehr als 2 Kanälen zeigt das Untermenü jetzt wählbare Stereo-Paare:

```
☑  Komplete Audio 6 MK2 — Ch 1-2  ▶
     ☑  Ch 1-2
     ☐  Ch 3-4
     ☐  Ch 5-6
☐  MacBook Pro-Lautsprecher — 2ch
```

**Geänderte Dateien:**

| Datei | Änderung |
|---|---|
| `routing_engine.py` | `OutputTarget.channel_offset: int = 0`; `sd.OutputStream` mit `channel_selectors=[offset, offset+1]`; immer 2-Kanal-Stream |
| `config.py` | `output_device_offsets: Dict[str, int]` — Channel-Offset pro Device persistent |
| `menu_bar_app.py` | `_device_offsets` Dict; `_make_device_menu_item()` baut Untermenü für >2ch; `_select_channel_pair()` Callback |

**Verhalten:**
- Klick auf Kanal-Paar im Untermenü → aktiviert Device + setzt Paar
- Klick auf Gerätenamen (Elternelement) → togglet Device an/aus (Paar bleibt erhalten)
- Auswahl wird persistent gespeichert (`~/.audiorouter/config.json`)

---

### Sonstiger Fix: Verschachteltes .app bei Installation

**Problem:** `cp -r source.app /Applications/dest.app` erstellt `dest.app/source.app` wenn das Zielverzeichnis schon existiert.

**Fix:** Immer erst `rm -rf /Applications/AudioRouterNow.app` vor dem Kopieren:
```bash
rm -rf /Applications/AudioRouterNow.app
cp -r dist/AudioRouterNow.app /Applications/AudioRouterNow.app
```
