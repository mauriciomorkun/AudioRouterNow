# AudioRouterNow — Projektdokumentation

> Zuletzt aktualisiert: 26.05.2026
> Ziel: Eigenständiger, lizenzfreier Audio-Router für macOS — universell für alle Audio-Interfaces

---

## 1. Ausgangslage & Problem

**Hardware:** Native Instruments Komplete Audio 6 MK2
**Problem:** macOS routet System-Audio standardmäßig nur zu Out 1/2. Die Outputs Out 3/4 bleiben stumm.
**Ziel:** System-Audio gleichzeitig auf alle gewünschten Outputs routen — auf jedem Mac, ohne technische Vorkenntnisse.

---

## 2. Vorversion v1 (`~/audio-router/`)

Ein funktionierendes Python-Projekt, das dieses Problem löste — aber mit Abhängigkeit zu BlackHole.

### Audio-Flow v1
```
macOS System Audio → BlackHole 2ch → AudioEngine (Python) → Komplete Audio 6
                                                              ├── Out 1/2 ✓
                                                              └── Out 3/4 ✓
```

### Abhängigkeiten v1 (Probleme)
- **BlackHole 2ch** — GPL-3.0 Lizenz → keine kommerzielle Nutzung ohne Lizenz
- **SwitchAudioSource** — CLI-Abhängigkeit
- **Kernel Extension (kext)** → manuelle Security-Genehmigung + Neustart nötig

---

## 3. Warum v2? — AudioRouterNow

### Lizenzproblem
BlackHole ist **GPL-3.0**: Private Nutzung erlaubt, kommerzielle Nutzung nicht.

### UX-Problem
Kernel Extension (kext) = manuelle Security-Genehmigung in Systemeinstellungen + System-Neustart.

### Lösung: Apple AudioServerPlugin statt kext

| | BlackHole (kext) | AudioRouterNow (AudioServerPlugin) |
|---|---|---|
| Kernel Extension | Ja | **Nein** |
| Security-Genehmigung | Ja (manuell) | **Nein** |
| System-Neustart | Ja | **Nein** |
| Lizenz | GPL-3.0 | **100% proprietär** |

---

## 4. Architektur v2 — Aktueller Stand

### Komponenten-Übersicht

```
┌──────────────────────────────────────────────────────────┐
│  macOS System Audio (Spotify, YouTube, etc.)             │
│  → setzt "Audio Router" als Standard-Ausgabe             │
└─────────────────────────┬────────────────────────────────┘
                          │ CoreAudio HAL
┌─────────────────────────▼────────────────────────────────┐
│  AudioRouterNow.driver  (C — AudioServerPlugin)          │
│  /Library/Audio/Plug-Ins/HAL/                            │
│                                                          │
│  • Virtuelles Stereo-Output-Device "Audio Router"        │
│  • WriteMix-Callback: empfängt Float32 PCM von CoreAudio │
│  • Sendet Frames non-blocking via Unix Domain Socket     │
│  • Connector-Thread: hält Socket-Verbindung zur Engine  │
│  • 1730 Zeilen C, Universal Binary (arm64 + x86_64)      │
└─────────────────────────┬────────────────────────────────┘
                          │ Unix Domain Socket /tmp/audiorouter.sock
                          │ 512 Frames × 2ch × Float32 = 4096 Bytes/Block
┌─────────────────────────▼────────────────────────────────┐
│  Python Routing Engine  (engine/)                        │
│                                                          │
│  socket_receiver.py                                      │
│  • Unix Socket Server (wartet auf Treiber-Verbindung)    │
│  • Thread-Priorität: QOS_CLASS_USER_INTERACTIVE          │
│  • recv_into() in festen Staging-Buffer (zero-copy recv) │
│  • .copy() pro Frame (notwendig für Queue-Thread-Safety) │
│                                                          │
│  routing_engine.py                                       │
│  • Queue pro Output-Device (QUEUE_DEPTH=64, ~683ms)      │
│  • Ein sounddevice.OutputStream pro physischem Device    │
│  • Volume-Polling in separatem Thread (50ms Interval)    │
│  • latency=0.05 (50ms Ausgabe-Puffer)                    │
│                                                          │
│  menu_bar_app.py                                         │
│  • Menubar-Widget mit Device-Picker                      │
│  • Hot-plug Detection (polling alle 2s)                  │
│  • Persistente Config (~/.audiorouter/config.json)       │
└─────────────────────────┬────────────────────────────────┘
                          │ sounddevice / PortAudio / CoreAudio
        ┌─────────────────┼──────────────────────┐
        ▼                 ▼                      ▼
  Komplete Audio 6   MacBook Pro          Beliebige weitere
  (Out 1-2, 3-4)     Lautsprecher         Audio-Interfaces
```

### Audio-Flow v2
```
System Audio → Audio Router (virtuell) → Unix Socket → Python → sounddevice → Physisches Gerät
```

---

## 5. Dateien & Verzeichnisstruktur

```
AudioRouterNow/
├── driver/
│   ├── src/
│   │   └── AudioRouterNowDriver.c    1730 Zeilen — HAL Plugin
│   ├── Info.plist                    Bundle-Manifest
│   ├── Makefile                      Build + Install + Reload
│   └── build/
│       └── AudioRouterNow.driver/    Installiertes Bundle
│
├── engine/
│   ├── menu_bar_app.py               Menubar-App (Haupteinstieg)
│   ├── routing_engine.py             Audio-Routing via sounddevice
│   ├── socket_receiver.py            Unix Socket Server
│   ├── device_manager.py             Hot-plug + Device-Discovery
│   ├── audio_device_control.py       Volume/Mute via CoreAudio (pyobjc)
│   ├── first_launch.py               Erststart-Installer
│   ├── cli.py                        CLI Interface
│   ├── config.py                     Persistente Einstellungen
│   └── requirements.txt
│
├── installer/
│   ├── build.sh                      Vollautomatischer Build → DMG
│   ├── AudioRouterNow.spec           PyInstaller Spec
│   ├── dmg_settings.py               DMG-Fenster-Konfiguration
│   ├── create_dmg_background.py      Hintergrundbild-Generator
│   ├── dmg_background.png            Generiertes Hintergrundbild
│   ├── AudioRouterNow.icns           App-Icon
│   ├── AudioRouterNow_dmg.icns       DMG-Datei-Icon
│   ├── set_dmg_icon.py               DMG-Icon-Setter (AppKit)
│   ├── entitlements.plist            Code-Signing Entitlements
│   └── .venv/                        Build-venv
│
└── projekt.md                        Diese Datei
```

---

## 6. Technische Details — HAL Plugin (C-Treiber)

### Protokoll: Unix Domain Socket IPC
- **Socket-Pfad:** `/tmp/audiorouter.sock`
- **Format:** Interleaved Float32 Stereo, kein Header/Framing
- **Blockgröße:** 512 Frames × 2 Channels × 4 Bytes = **4096 Bytes/Block**
- **Rate:** 48000 Hz → 93,75 Blöcke/Sekunde
- **Sende-Modus:** `MSG_DONTWAIT` (non-blocking, RT-safe)

### Connector-Thread (nicht-RT)
- Baut Socket-Verbindung zur Python Engine auf
- Reconnect alle 500ms wenn keine Verbindung
- Schließt FDs aus dem `gClosePendingFD`-Slot (RT-safe handoff)

### RT-IO-Callback (WriteMix)
- Empfängt Float32 Frames von CoreAudio
- Wendet Volume/Mute an (atomic reads, kein Lock)
- Sendet via `ipc_send_rt()` non-blocking
- **Verbote im RT-Pfad:** kein malloc, kein blocking IO, kein Lock, kein os_log

### Zeitmodell (GetZeroTimeStamp)
- Freilaufende virtuelle Uhr basierend auf `mach_absolute_time()`
- Kein Mutex mehr (seit v1.0.2) — `atomic_load` auf `gHostTicksPerFrameBits`
- `gHostTicksPerFrameBits`: Float64 bit-reinterpretiert als atomic_ullong

---

## 7. Technische Details — Python Engine

### socket_receiver.py
| Aspekt | Implementierung |
|---|---|
| Thread | Daemon-Thread, QOS_CLASS_USER_INTERACTIVE |
| Empfang | `recv_into()` in feste `memoryview(bytearray)` |
| Frame-Übergabe | `.copy()` → neues Array pro Frame (Thread-Safety für Queue) |
| Reconnect | automatisch bei Verbindungsabbruch |

### routing_engine.py
| Aspekt | Implementierung |
|---|---|
| Queue pro Device | `queue.Queue(maxsize=64)` → ~683ms Puffer |
| Ausgabe-Latenz | `latency=0.05` (50ms) → Puffer gegen GIL-Jitter |
| Volume-Polling | separater Thread, 50ms Interval (CoreAudio pyobjc-Call nicht im Hot-Path) |
| Multi-Channel | Ein Stream pro physischem Device, mehrere Kanal-Paare in einem Stream |

### Bekannte Architektur-Einschränkung
Python sitzt im Audio-Datenpfad zwischen zwei CoreAudio-Stacks. Python-Threads sind **nicht Realtime-fähig** — GIL, GC-Pausen und OS-Scheduler können jederzeit Verzögerungen verursachen. Die 50ms-Latenz-Einstellung mildert dies, löst es aber nicht fundamental.

→ **Geplant für v2.0:** Routing direkt im C-Treiber (Python nur noch UI/Config)

---

## 8. Installer & Distribution

### build.sh — Was es tut
1. Python venv erstellen + Dependencies installieren
2. PyInstaller: `AudioRouterNow.app` aus `engine/menu_bar_app.py` bauen
3. Ad-hoc Code-Signierung (Entitlements: `disable-library-validation`)
4. DMG-Hintergrundbild generieren (`create_dmg_background.py`)
5. `dmgbuild`: DMG mit Fenster-Layout erstellen
6. AppleScript via Finder: Hintergrundbild setzen (macOS Sequoia Kompatibilität)
7. UDRW → UDZO konvertieren
8. DMG-Datei-Icon setzen (`set_dmg_icon.py` via AppKit)

### DMG-Fenster-Design
- **Fenstergröße:** 680×440pt
- **Hintergrundbild:** 1360×880px @2x (Retina)
- **Hintergrundfarbe:** Teal-Grün `RGB(25, 220, 168)` — passend zum App-Icon-Symbol
- **Icons:** AudioRouterNow.app (links, x=160pt) + Applications (rechts, x=520pt)
- **Kein Pfeil** im DMG-Fenster

### macOS Sequoia / Tahoe Kompatibilitäts-Fixes
- **Hintergrund-Problem:** dmgbuild schreibt Legacy-HFS+-Alias → macOS Tahoe löst ihn nicht auf
- **Lösung:** UDRW mounten ohne `-nobrowse` → Finder setzt Hintergrund via AppleScript (NSURL-Bookmark)
- **Icon-Positions-Problem:** AppleScript `set position` verwendet physische Pixel (@2x) → Icons landen falsch
- **Lösung:** `set position` aus AppleScript entfernt, dmgbuild schreibt Positionen in DS_Store

---

## 9. Bugs gefunden & behoben

### v1.0.1 — Audio-Glitches (26.05.2026)

| Bug | Datei | Problem | Fix |
|---|---|---|---|
| **Bug 1** | `AudioRouterNowDriver.c` | Partial-Send silently dropped → korruptes Framing | Partial-Send detektiert, FD zurückgesetzt |
| **Bug 2** | `routing_engine.py` | QUEUE_DEPTH=8 → 85ms Puffer zu wenig | QUEUE_DEPTH=32→64 |
| **Bug 3** | `routing_engine.py` | Volume-Abfrage (pyobjc) im Audio-Hot-Path → blockiert SocketReceiver | Ausgelagert in separaten Poll-Thread (50ms) |
| **Bug 4** | `socket_receiver.py` | `bytearray.extend()` 93x/s → GC-Pressure → GIL-Pausen | `recv_into()` + `memoryview` |
| **Bug 5** | `routing_engine.py` | `(frames * vol).astype(float32)` → 2x Allokation | `frames * np.float32(vol)` |

### v1.0.2 — RT-Thread Sicherheit (26.05.2026)

| Bug | Datei | Problem | Fix |
|---|---|---|---|
| **Bug 6** | `AudioRouterNowDriver.c` | `pthread_mutex_lock` in `GetZeroTimeStamp` → Priority-Inversion auf RT-Thread | Ersetzt durch `atomic_load` auf `gHostTicksPerFrameBits` |
| **Bug 7** | `AudioRouterNowDriver.c` | `close()` + `os_log()` im RT-Pfad → kann blockieren | FD in `gClosePendingFD`-Slot, Connector-Thread schließt |
| **Bug 8** | `socket_receiver.py` | Pre-allocated `self._frame_buf` + `scaled=frames` (kein Copy bei vol=1.0) → Data-Race: Queue enthält Referenz auf überschriebenen Buffer | `.copy()` pro Frame, `self._frame_buf` entfernt |
| **Bug 9** | `routing_engine.py` | `latency="low"` = 1.9ms Ausgabe-Puffer → bei jeder >2ms GIL-Pause: Underrun → Glitch | `latency=0.05` (50ms) |

---

## 10. Entscheidungen & Begründungen

| Datum | Entscheidung | Wahl | Begründung |
|---|---|---|---|
| 21.05.2026 | App-Name | AudioRouterNow | Final |
| 21.05.2026 | HAL Plugin Sprache | C (statt Swift) | AudioServerPlugin ist C-COM-API, Swift würde Bridging brauchen |
| 21.05.2026 | IPC-Methode | Unix Domain Socket | Zuverlässig, low-latency, kein Polling nötig |
| 21.05.2026 | macOS Mindest-Version | macOS 11 Big Sur | Apple Silicon + AudioServerPlugin + Python 3.10 |
| 21.05.2026 | Lizenzstrategie | Proprietär | Keine GPL-Abhängigkeit, Kommerzialisierung jederzeit möglich |
| 26.05.2026 | Kein Pfeil im DMG | Arrow aus Background entfernt | macOS zeigt PNG-Dateien als generische Dokument-Icons |
| 26.05.2026 | DMG-Hintergrundfarbe | Teal-Grün (App-Icon-Farbe) | Kohärentes Design, passend zum Symbol |
| 26.05.2026 | BlackHole deinstalliert | Ja | Unnötiger HAL-Plugin belastet coreaudiod RT-Threads |
| 26.05.2026 | Python aus Hot-Path entfernen | Geplant für v2.0 | Python ist fundamental nicht-RT; C-natives Routing eliminiert Glitches |

---

## 11. Performance-Profil (Stand v1.0.2)

### CPU-Verbrauch
- **coreaudiod (Treiber):** ~3% CPU (normal für aktiven HAL-Plugin)
- **Python Engine:** ~2-3% CPU bei Musik-Wiedergabe
- **Gesamt:** ~5-6% — akzeptabel

### Latenzen
- **Treiber → Python:** ~0-5ms (Unix Socket, praktisch 0 auf idle System)
- **Python → sounddevice → CoreAudio:** 50ms (bewusst gewählt für Stabilität)
- **Gesamt-Latenz:** ~50-55ms (für Musik-Wiedergabe irrelevant)

### Glitch-Häufigkeit nach Fixes
- **vor v1.0.1:** sehr häufig (mehrmals pro Minute)
- **nach v1.0.1:** weniger häufig
- **nach v1.0.2 (latency fix):** selten bis nicht mehr vorhanden

---

## 12. Bekannte Einschränkungen (Stand v1.0.2)

1. **Python im Hot-Path:** Fundamental nicht-RT, GIL-Pausen unvermeidbar
   → geplant: v2.0 mit C-nativem Routing
2. **Uhr-Drift:** Virtueller Treiber und physisches Device haben separate Uhren
   → Bei sehr langen Sessions könnte Queue über/unterlaufen (noch nicht beobachtet)
3. **Nur Stereo-Input:** Treiber empfängt nur 2 Kanäle von CoreAudio
   → für System-Audio (immer Stereo) ausreichend
4. **Code-Signierung fehlt:** Gatekeeper-Warnung auf anderen Macs
   → geplant: Apple Developer ID ($99/Jahr) wenn Vermarktung

---

## 13. Roadmap

### ✅ Phase 1 — Fundament (abgeschlossen)
- [x] HAL Plugin (AudioServerPlugin) in C implementiert — 1730 Zeilen
- [x] Unix Socket IPC zwischen Treiber und Python Engine
- [x] Treiber installiert & aktiv als Default Output Device
- [x] Universal Binary (arm64 + x86_64)

### ✅ Phase 2 — Engine & UI (abgeschlossen)
- [x] Python Routing Engine (socket_receiver.py + routing_engine.py)
- [x] Menu Bar Widget mit Device-Picker
- [x] Hot-plug Detection (device_manager.py)
- [x] Channel-Mapping für N-Kanal Devices
- [x] Persistente Config (~/.audiorouter/config.json)
- [x] CLI Interface
- [x] Natives System-Audio-Umschalten via osascript
- [x] Donation-System (Buy Me a Coffee)

### ✅ Phase 3 — Distribution (abgeschlossen)
- [x] PyInstaller Spec + build.sh
- [x] DMG mit Finder-Fenster-Design
- [x] Hintergrundbild mit App-Icon-Farbe
- [x] macOS Sequoia/Tahoe Kompatibilität
- [x] first_launch.py — Erststart-Installer

### 🔄 Phase 4 — Architektur-Refactoring (geplant v2.0)
- [ ] **C-natives Routing im Treiber** — Python aus Hot-Path entfernen
  - Treiber öffnet CoreAudio Output-Streams direkt
  - Python Engine wird reine Konfigurations-Schicht (IPC nur für Settings)
  - Eliminiert GIL-bedingte Glitches fundamental
  - Detailplan: siehe Abschnitt 14

### ⏳ Phase 5 — Qualität & Release (offen)
- [ ] Code-Signierung (Apple Developer ID)
- [ ] Notarisierung (Apple Notarization)
- [ ] End-to-End Test: macOS 11, 12, 13, 14, 15
- [ ] Testen auf Intel Mac + Apple Silicon
- [ ] Testen mit verschiedenen Audio-Interfaces (Focusrite, SSL, etc.)

---

## 14. Architektur v2.0 — C-natives Routing (vollständiger Plan)

> Analysiert und ausgearbeitet: 26.05.2026
> Status: **Dokumentiert, bereit zur Implementierung**

---

### 14.1 Kern-Erkenntnis: Was NICHT geht

**Der HAL-Plugin kann NICHT selbst CoreAudio-Client sein.**

Ein AudioServerPlugin läuft als In-Process-Server innerhalb von `coreaudiod`.
Wenn es selbst `AudioDeviceCreateIOProcID` oder `AudioDeviceStart` aufruft,
versucht es denselben internen HAL-Lock zweimal zu nehmen → Deadlock.
Apple verbietet das explizit (AudioServerPlugin.h, TN2091, WWDC 2013 Session 602).

Kein bekanntes HAL-Plugin (BlackHole, Soundflower, Loopback, RogueAmoeba ACE)
macht das. Alle nutzen externe Prozesse für Audio-Routing.

**Gleiches gilt für AudioQueue und alle anderen CoreAudio-Client-APIs.**

---

### 14.2 Was BlackHole macht (und warum es unser Problem nicht löst)

BlackHole ist reines Loopback — kein Router:
- `DoIOOperation/WriteMix`: schreibt Frames in einen prozessinternen Ring-Buffer in coreaudiod
- `DoIOOperation/ReadInput`: liest aus demselben Ring-Buffer
- Audio fließt von App-A (Output auf BlackHole) → BlackHole → App-B (Input von BlackHole, z.B. DAW)
- BlackHole routet NICHT selbst an Hardware — das übernimmt der externe Client (DAW, oder v1: Python)

v1 von AudioRouterNow nutzte BlackHole genau so: BlackHole = virtueller Output, Python = Client
der BlackHole-Input liest und an Hardware schickt. Ohne externen Client ist BlackHole stumm.

**v2.0 folgt demselben Muster** — nur ersetzt ein eigener C-Helper die Python-Schicht.

---

### 14.3 Gewählte Architektur: HAL-Plugin als Producer, C-Helper als RT-Consumer

```
┌──────────────────────────────────────────────────────────────────┐
│  macOS System Audio (Spotify, YouTube, Safari, ...)              │
└───────────────────────────┬──────────────────────────────────────┘
                            │ CoreAudio HAL
┌───────────────────────────▼──────────────────────────────────────┐
│  coreaudiod (root)                                               │
│  └─ AudioRouterNow.driver  (C HAL Plugin)                        │
│     • DoIOOperation/WriteMix → schreibt Frames in SHM-Ring       │
│     • Kein Socket, keine Python-Verbindung mehr                  │
│     • POSIX shm_open() + mmap() beim Initialize                  │
└───────────────────────────┬──────────────────────────────────────┘
                            │ POSIX Shared Memory
                            │ Lock-free SPSC Ring-Buffer
                            │ ~8192 Frames ≈ 170ms @48kHz
                            │ Atomic write_idx / read_idx
┌───────────────────────────▼──────────────────────────────────────┐
│  AudioRouterNowHelper  (C Daemon, User-Prozess, nicht root)      │
│  • RT-Thread mit THREAD_TIME_CONSTRAINT_POLICY                   │
│  • Liest Frames aus SHM-Ring (atomic, lock-free)                 │
│  • AudioDeviceCreateIOProcID pro physischem Output-Device        │
│  • Verteilt Frames an N Devices + Channel-Mapping                │
│  • Volume/Mute-Polling via C (AudioObjectGetPropertyData)        │
│  • Config-Socket-Server (JSON-Lines, non-RT-Thread)              │
│  • gestartet via launchd User-Agent (KeepAlive=true)             │
└───────────────────────────┬──────────────────────────────────────┘
                            │ CoreAudio Client API
            ┌───────────────┼──────────────────┐
            ▼               ▼                  ▼
       Komplete Audio 6  MacBook Pro     weitere Devices
       (Out 1-2, 3-4)    Speakers        (Kopfhörer, HDMI, ...)
                            ▲
                            │ Config-IPC (Unix Socket, JSON-Lines)
                            │ Nur Konfiguration, kein Audio
                  ┌─────────┴────────────────┐
                  │  Python Menubar-App       │
                  │  (rumps, Device-Picker)   │
                  │  nur noch UI + Config     │
                  └───────────────────────────┘
```

---

### 14.4 IPC: Warum POSIX Shared Memory (und nicht Socket)

| Mechanismus | RT-safe? | Latenz | Für Audio? |
|---|---|---|---|
| Unix Socket (aktuell) | bedingt | 50–500µs + Jitter | suboptimal |
| **POSIX SHM + atomic Index** | **JA** | **~50ns** | **✅ Empfohlen** |
| POSIX Semaphore (`sem_post`) | NEIN | — | ❌ kann blockieren |
| Mach Port (`mach_msg`) | NEIN | ~5–50µs | ❌ kann blockieren |
| `dispatch_semaphore_signal` | JA | ~100ns | als Wake-up OK |

**Shared Memory Layout (`shared_ring.h`):**
```c
typedef struct {
    uint32_t magic;           // ABI-Version-Check
    uint32_t sample_rate;     // 48000
    uint32_t channel_count;   // 2
    uint32_t frame_capacity;  // 8192

    atomic_uint write_idx;    // Producer bumpt (memory_order_release)
    atomic_uint read_idx;     // Consumer bumpt (memory_order_acquire)

    float    volume;          // atomic read/write
    uint32_t muted;           // atomic read/write

    float    frames[];        // frame_capacity * channel_count Float32
} ARNSharedRing;
```

---

### 14.5 Config-IPC: Python Menubar ↔ Helper

**Mechanismus:** Unix Domain Socket `/tmp/audiorouter.config.sock`, JSON-Lines, non-RT

**Protokoll:**
```json
// Python → Helper (Konfiguration setzen)
{"cmd": "set_outputs", "outputs": [
  {"device_uid": "AppleHDAEngine:1B,0,1,2:0", "channels": [0,1]},
  {"device_uid": "NI-Komplete-Audio-6-UID",   "channels": [0,1]},
  {"device_uid": "NI-Komplete-Audio-6-UID",   "channels": [2,3]}
]}

// Helper → Python (Response)
{"ok": true, "active": ["MacBook Pro Speakers", "Komplete Audio 6 Ch 1-2", "Ch 3-4"]}
{"ok": false, "error": "device_uid not found"}

// Sonstige Commands
{"cmd": "ping"}
{"cmd": "shutdown"}
```

**Wichtig:** Device-UIDs statt Indizes (UIDs sind stabil über Reboots).

---

### 14.6 Clock-Drift Strategie

Virtueller Treiber und physisches Device haben separate Uhren (Crystal-Oszillator-Drift ~50ppm).
Bei 48kHz: max ~2.4ms/Minute Drift. Bei 30min Wiedergabe: ~72ms möglicher Drift.

**v2.0: Pragmatischer Ansatz**
- Großer Ring-Buffer (8192 Frames = 170ms) als Puffer-Reserve
- Bei Underflow (Ring leer): Stille einfügen (selten, maximal einmal pro Stunde)
- Akzeptabel für Musik-Wiedergabe

**v2.1: Saubere Lösung (geplant)**
- `AudioConverter` mit variabler Output-Sample-Rate
- Drift-Messung via Ring-Fill-Level → adaptive Rate-Anpassung
- Entspricht Apple-empfohlener Methode für asynchrone Audio-Streams

---

### 14.7 Komponenten: was bleibt / wird geändert / fällt weg / kommt neu

#### ✅ Bleibt unverändert
| Datei | Warum |
|---|---|
| `engine/menu_bar_app.py` | Nur kleine Änderung: Helper-Spawn + Config-Socket statt RoutingEngine |
| `engine/device_manager.py` | Hot-plug Detection (sounddevice/PortAudio) bleibt |
| `engine/config.py` | Minimal: Device-UID statt Index |
| `engine/first_launch.py` | Unverändert |
| `engine/cli.py` | Unverändert |
| `engine/audio_device_control.py` | Optional für UI-Anzeige |

#### 🔄 Wird modifiziert
| Datei | Änderung |
|---|---|
| `driver/src/AudioRouterNowDriver.c` | Socket-Code (~150 Zeilen) raus, SHM-Ring (~200 Zeilen) rein |
| `driver/Makefile` | SHM-Header einbinden |
| `installer/build.sh` | Helper-Binary kompilieren, ins Bundle packen |
| `installer/AudioRouterNow.spec` | sounddevice/numpy/PortAudio entfernen (~30-50MB kleiner) |
| `engine/menu_bar_app.py` | Helper-Spawn + Config-Socket-Client statt RoutingEngine |

#### ❌ Wird gelöscht
| Datei | Grund |
|---|---|
| `engine/routing_engine.py` (385 Zeilen) | Ersetzt durch C-Helper |
| `engine/socket_receiver.py` (240 Zeilen) | SHM ersetzt Socket für Audio-Frames |

#### 🆕 Neu
| Datei | Inhalt |
|---|---|
| `helper/shared_ring.h` | Lock-free SPSC Ring-Buffer Layout + atomic ops (~150 Zeilen) |
| `helper/AudioRouterNowHelper.c` | C-Daemon: SHM-Consumer, CoreAudio-Client, Config-Server (~700 Zeilen) |
| `helper/Makefile` | Universal Binary Build |
| `installer/com.audiorouter.now.helper.plist` | launchd User-Agent (KeepAlive=true) |

---

### 14.8 Risiken & Mitigation

| # | Risiko | W'keit | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Clock-Drift → Underruns bei langen Sessions | hoch | mittel | 170ms Ring-Buffer; v2.1: AudioConverter SRC |
| R2 | Helper crashed → kein Audio | mittel | hoch | launchd `KeepAlive=true`, automatischer Restart |
| R3 | Helper startet bevor SHM-Segment existiert | hoch | mittel | Retry-Loop beim `shm_open` (wie aktueller Connector-Thread) |
| R4 | SHM-Segment leakt nach Crash | mittel | niedrig | `shm_unlink` in Plugin-Destructor + Helper-Cleanup |
| R5 | RT-Thread im Helper kriegt keine Priority | hoch | hoch | `THREAD_TIME_CONSTRAINT_POLICY` explizit setzen — **kritisch** |
| R6 | Plugin/Helper ABI-Mismatch nach Update | niedrig | hoch | Magic/Version im SHM-Header, Helper prüft beim mmap |
| R7 | Multi-User: zwei Sessions → zwei Helpers → SHM-Konflikt | mittel | mittel | SHM-Pfad per-UID: `/audiorouter.shm.<uid>` |
| R8 | Sample-Rate-Wechsel zur Laufzeit | mittel | mittel | Header-Field signalisiert Helper → rebuild OutputStream |
| R9 | malloc/lock im RT-Thread unbemerkt eingebaut | mittel | hoch | Debug: `os_signpost` + Latenz-Histogramm |
| R10 | Notarization: Hardened Runtime erlaubt kein shm? | niedrig | mittel | `com.apple.security.cs.disable-library-validation` + Test |

---

### 14.9 Implementierungs-Phasen

| Phase | Inhalt | Dauer | Exit-Kriterium |
|---|---|---|---|
| **0 — Spike** | Minimaler Sinuston: Plugin schreibt in SHM, Helper liest + spielt ab. Beweist Machbarkeit. | 1–2 Tage | 5 Min Sinuston ohne Glitch |
| **1 — Helper-Skelett** | RT-Thread + `THREAD_TIME_CONSTRAINT_POLICY`, ein Device hardcoded, SHM-Verbindung | 3–4 Tage | Spotify → Audio Router → Built-in Speakers ohne Python |
| **2 — Multi-Device + Channel-Routing** | N parallele OutputStreams, Channel-Mapping, Hot-Plug-Listener | 3–4 Tage | Komplete Audio 6 Out 1-2 + Out 3-4 + Built-in parallel |
| **3 — Config-Socket + Python-Integration** | JSON-Lines-Server im Helper, menu_bar_app.py angepasst | 2–3 Tage | Device-Picker in Menubar steuert Helper end-to-end |
| **4 — Volume/Mute in C, Python-Deps raus** | CoreAudio-Volume-Polling in C, sounddevice/numpy aus Bundle | 1–2 Tage | Helper läuft selbständig wenn Python crashed |
| **5 — launchd + Robustheit** | launchd User-Agent, KeepAlive, SHM-Cleanup, Version-Check | 2–3 Tage | Reboot-Test, Crash-Test, Logout/Login-Test bestanden |
| **6 — Clock-Drift SRC** *(v2.1)* | AudioConverter mit variabler Rate, Drift-Messung | 3–5 Tage | 4h Musik ohne Glitch |
| **7 — Build + Installer** | build.sh + .spec anpassen, Helper ins Bundle, launchd-Plist | 2 Tage | DMG-Build auf jungfräulichem Mac funktioniert |
| **8 — Test-Matrix** | macOS 11–15, Intel + ARM, verschiedene Interfaces, Stress-Tests | 2–3 Tage | Alle Kombinationen 30min ohne Glitch |

**Gesamt v2.0 (Phase 0–5 + 7–8): ~18–24 Arbeitstage**
**Gesamt inkl. v2.1 (Phase 6): ~22–29 Arbeitstage**

---

### 14.10 Nächster Schritt

**Phase 0 — Spike** beginnen:
1. `helper/shared_ring.h` — Lock-free Ring-Buffer Header
2. Plugin-Patch: schreibt Silence/Frames in SHM (WriteMix)
3. Minimaler Helper: liest SHM, spielt auf Built-in Speakers ab
4. Ergebnis verifizieren: Glitch-frei für 5+ Minuten?
5. Wenn JA → Phase 1 beginnen

---

## 15. Git-History (Meilensteine)

| Commit | Beschreibung |
|---|---|
| `39e1537` | Quality audit & fixes — v1.0.1 |
| `17ee59a` | DMG installer: macOS 26 compatibility — arrow icon + custom DMG icon fix |
| `055be57` | DMG: remove redundant arrow icon — background image handles Drag & Drop visual |
| `007d810` | DMG: teal-green background matching app icon symbol color; remove arrow |
| `a9b1698` | Performance: eliminate audio glitches under CPU load |
| `9563900` | Fix data race in SocketReceiver — shared frame_buf caused audio corruption |
| `6bfac22` | Fix audio glitches: sounddevice latency low → 50ms |

---

## 16. Referenzen

- [Apple AudioServerPlugin Dokumentation](https://developer.apple.com/documentation/coreaudio)
- [Apple HAL Plugin Examples (SimpleAudio)](https://developer.apple.com/library/archive/samplecode/SimpleAudioDriver/)
- [BlackHole GitHub (Referenz-Implementierung)](https://github.com/ExistentialAudio/BlackHole)
- [sounddevice Python Library](https://python-sounddevice.readthedocs.io/)
- [rumps — macOS Menu Bar Framework](https://github.com/jaredks/rumps)
- [PortAudio — Cross-Platform Audio I/O](http://www.portaudio.com/)
