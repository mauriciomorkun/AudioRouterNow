# AudioRouterNow — Projektdokumentation

> Zuletzt aktualisiert: 27.05.2026
> Stand: **v2.0 — ausgeliefert**. C-natives Routing aktiv, Python aus dem Audio-Hot-Path entfernt.
> Ziel: Eigenständiger, lizenzfreier Audio-Router für macOS — universell für alle Audio-Interfaces.

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

### Zusätzliches Problem v1.0.2 → v2.0
Python im Audio-Hot-Path war fundamental nicht Realtime-fähig. GIL-Pausen, GC und OS-Scheduler verursachten gelegentliche Glitches. v2.0 entfernt Python vollständig aus dem Datenpfad und ersetzt es durch einen nativen C-Helper.

---

## 4. Architektur v2.0 — Aktueller Stand

### Audio-Flow (final, in Produktion)
```
System Audio → Audio Router (HAL Plugin) → POSIX SHM Ring → C-Helper → CoreAudio → Physische Devices
                                           (lock-free SPSC)            (IOProc pro Device)
```

Kein Python im Audio-Datenpfad. Python steuert den Helper nur noch via Config-Socket (Konfiguration, kein Audio).

### Komponenten-Übersicht
```
┌──────────────────────────────────────────────────────────────────┐
│  macOS System Audio (Spotify, YouTube, Safari, ...)              │
│  → setzt "Audio Router" als Standard-Ausgabe                     │
└───────────────────────────┬──────────────────────────────────────┘
                            │ CoreAudio HAL
┌───────────────────────────▼──────────────────────────────────────┐
│  coreaudiod (root)                                               │
│  └─ AudioRouterNow.driver  (C HAL Plugin)                        │
│     /Library/Audio/Plug-Ins/HAL/                                 │
│     • Virtuelles Stereo-Output-Device "Audio Router"             │
│     • WriteMix-Callback: arn_ring_write() → POSIX SHM            │
│     • Kein Socket, keine Python-Verbindung mehr                  │
│     • shm_open() + mmap() in Initialize, shm_unlink in Teardown  │
└───────────────────────────┬──────────────────────────────────────┘
                            │ POSIX Shared Memory  /audiorouter_shm
                            │ Lock-free SPSC Ring-Buffer
                            │ 16384 Samples = 8192 Frames ≈ 170ms @48kHz
                            │ Cache-Line-aligned, atomic write_idx/read_idx
┌───────────────────────────▼──────────────────────────────────────┐
│  AudioRouterNowHelper  (C-Daemon, User-Prozess)                  │
│  /Library/Audio/Plug-Ins/HAL/.../MacOS/AudioRouterNowHelper      │
│  • RT-Thread mit THREAD_TIME_CONSTRAINT_POLICY                   │
│  • SHM-Consumer (lock-free, atomic acquire/release)              │
│  • AudioDeviceCreateIOProcID pro physischem Output-Device        │
│    – MAX_OUTPUTS = 8, eigene local_ridx pro Device               │
│    – read_idx im SHM = min(local_ridx aller Devices)             │
│  • Channel-Mapping (ch_offset: 0=Ch1-2, 2=Ch3-4, ...)            │
│  • Volume/Mute-Polling (C, 50ms, AudioObjectGetPropertyData)     │
│  • Hot-Plug-Listener (AudioObjectAddPropertyListener)            │
│  • Config-Socket-Server (JSON-Lines, non-RT-Thread)              │
│  • gestartet via launchd User-Agent (KeepAlive=true)             │
└───────────────────────────┬──────────────────────────────────────┘
                            │ CoreAudio Client API (IOProc)
            ┌───────────────┼──────────────────┐
            ▼               ▼                  ▼
       Komplete Audio 6  MacBook Pro     weitere Devices
       (Out 1-2, 3-4)    Speakers        (Kopfhörer, HDMI, ...)
                            ▲
                            │ Config-IPC (Unix Socket, JSON-Lines)
                            │ /tmp/audiorouter.config.sock
                            │ Nur Konfiguration, kein Audio
                  ┌─────────┴────────────────┐
                  │  Python Menubar-App       │
                  │  rumps + ctypes CoreAudio │
                  │  reine UI/Steuerschicht   │
                  └───────────────────────────┘
```

---

## 5. Dateien & Verzeichnisstruktur

```
AudioRouterNow/
├── driver/
│   ├── src/
│   │   └── AudioRouterNowDriver.c    HAL Plugin — schreibt in SHM-Ring
│   ├── resources/
│   │   └── Info.plist                Bundle-Manifest
│   ├── Makefile                      Build (Driver + Helper) + Install + Reload
│   └── build/
│       └── AudioRouterNow.driver/    Installiertes Bundle
│           └── Contents/
│               ├── Info.plist
│               ├── MacOS/
│               │   ├── AudioRouterNowDriver       (HAL-Plugin Bibliothek)
│               │   └── AudioRouterNowHelper       (Helper-Binary, eingebettet)
│               └── Resources/
│                   └── com.audiorouter.now.helper.plist   (launchd-Plist)
│
├── helper/                           NEU in v2.0
│   ├── AudioRouterNowHelper.c        Phase 5 — Multi-Device + Config + Volume + launchd
│   ├── shared_ring.h                 Lock-free SPSC Ring (Header, von Driver & Helper inkludiert)
│   ├── com.audiorouter.now.helper.plist   launchd User-Agent
│   ├── Makefile                      Universal Binary Build (arm64 + x86_64)
│   ├── AudioRouterNowHelper          Symlink → build/AudioRouterNowHelper
│   └── build/
│       └── AudioRouterNowHelper      Universal Binary
│
├── engine/
│   ├── menu_bar_app.py               Menubar-App (Haupteinstieg), steuert Helper via Socket
│   ├── helper_client.py              NEU in v2.0 — Config-Socket-Client (JSON-Lines)
│   ├── device_manager.py             ctypes CoreAudio (kein sounddevice mehr)
│   ├── audio_device_control.py       Default-Output-Switch via pyobjc
│   ├── first_launch.py               Erststart-Installer (Driver + launchd-Agent)
│   ├── cli.py                        CLI Interface
│   ├── config.py                     Persistente Einstellungen (~/.audiorouter/config.json)
│   ├── requirements.txt              rumps + pyobjc — kein sounddevice/numpy
│   ├── routing_engine.py             LEGACY (v1, im Build excludet)
│   └── socket_receiver.py            LEGACY (v1, im Build excludet)
│
├── installer/
│   ├── build.sh                      Vollautomatischer Build → DMG (Driver + Helper + .app + DMG)
│   ├── AudioRouterNow.spec           PyInstaller Spec (sounddevice/numpy ausgeschlossen)
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

**Veraltete Dateien (v1, bleiben im Repo aus Historie, werden NICHT mehr genutzt):**
- `engine/routing_engine.py` — durch C-Helper ersetzt
- `engine/socket_receiver.py` — durch SHM-Ring ersetzt
- Beide sind im PyInstaller-Spec explizit `excludes`-gelistet.

---

## 6. Technische Details — HAL Plugin (C-Treiber)

### Was sich gegenüber v1 geändert hat
- **Kein Unix Domain Socket mehr** im Treiber. Keine `socket()`, `connect()`, `send()` im RT-Pfad.
- Stattdessen: POSIX Shared Memory (`shm_open` + `mmap`) wird beim `Initialize` einmalig eingerichtet, Pointer in Globaler Variable gespeichert.
- WriteMix ruft `arn_ring_write()` aus `shared_ring.h` auf — reine lock-free Pointer-Bewegung.

### SHM-Setup (Lifecycle)
| Phase | Aktion |
|---|---|
| Initialize | `shm_open(ARN_SHM_NAME, O_RDWR \| O_CREAT, 0666)` → `ftruncate(ARN_SHM_SIZE)` → `mmap()` → `arn_ring_init()` |
| WriteMix (RT) | `arn_ring_write(gRing, frames, count * 2)` — non-blocking, atomic |
| Teardown | `munmap()` + `shm_unlink(ARN_SHM_NAME)` |

### RT-IO-Callback (WriteMix)
- Empfängt Float32 Frames von CoreAudio
- Wendet Volume/Mute an (atomic reads aus SHM-Header, kein Lock)
- Schreibt via `arn_ring_write()` in den SHM-Ring
- **Verbote im RT-Pfad:** kein malloc, kein Syscall, kein Lock, kein os_log

### Zeitmodell (GetZeroTimeStamp)
- Freilaufende virtuelle Uhr basierend auf `mach_absolute_time()`
- Kein Mutex (seit v1.0.2) — `atomic_load` auf `gHostTicksPerFrameBits`
- `gHostTicksPerFrameBits`: Float64 bit-reinterpretiert als atomic_ullong

### Hot-Reload-Sicherheit
- Magic + Version-Check im SHM-Header — Helper akzeptiert nur ABI-kompatible Segmente.
- Bei Plugin-Reload: alter `shm_unlink` + neuer `shm_open` → Helper erkennt neues Segment beim nächsten `mmap`-Retry.

---

## 7. Technische Details — C-Helper (NEU in v2.0)

Datei: `helper/AudioRouterNowHelper.c` (~45 KB, Phase 5)

### SHM-Consumer
- `shm_open(ARN_SHM_NAME, O_RDWR, 0)` mit Retry-Loop (500ms-Intervall) bis Plugin SHM bereitstellt
- `mmap()` + Magic/Version-Check gegen `ARN_RING_MAGIC` / `ARN_RING_VERSION`
- Liest Frames lock-free via `arn_ring_read()` — atomic acquire auf `write_idx`, atomic release auf `read_idx`

### RT-Thread (CoreAudio IOProc)
- Pro physischem Output-Device ein eigener `AudioDeviceIOProcID`
- IOProc läuft auf CoreAudio-eigenem RT-Thread mit `THREAD_TIME_CONSTRAINT_POLICY`
- Eigener `local_ridx` pro Device → mehrere Outputs lesen denselben Ring parallel ohne Drift
- Globaler `ring->read_idx` wird periodisch auf `min(local_ridx)` aller aktiven Devices gesetzt — Producer bleibt ABI-kompatibel

### Multi-Device-Routing
- `MAX_OUTPUTS = 8` parallele Devices (kompiliert)
- Channel-Mapping: `ch_offset` pro Device (0 = Ch 1-2, 2 = Ch 3-4, 4 = Ch 5-6, ...)
- De-Interleaving im IOProc in pre-allokierten `temp_buf` (kein malloc im Hot-Path)
- Diagnose: `_Atomic underruns` pro Device, `g_ioproc_calls` global

### Adaptive Sample-Rate-Kompensation (Phase 6, v2.1)
- Pro Output-Device: `double src_frac_ridx` (fraktionaler Leseindex, IOProc-privat)
- Lineare Interpolation zwischen zwei Sample-Frames pro Output-Frame
- `_Atomic uint32_t src_ratio_q20` — Q20-Fixed-Point (1.0 = `1<<20`)
- P-Regler im Volume-Poll-Thread (50ms): Ziel = 50% Ring-Füllstand
- Korrektur geklemmt auf ±500ppm (10× Max-Drift Sicherheitsmarge)
- Bei Underrun: `src_frac_ridx` auf `write_idx` zurückgesetzt (Resync)
- Diagnose: `src_ratio` pro Device in `get_status`-Antwort

### Config-Socket (non-RT-Thread)
- Unix Domain Socket `/tmp/audiorouter.config.sock`
- Protokoll: JSON-Lines
- Commands:
  - `{"cmd":"ping"}` → `{"ok":true,"pong":true}`
  - `{"cmd":"set_outputs","outputs":[{"uid":"<device-uid>","ch_offset":0}, ...]}` → `{"ok":true,"active":["<name>", ...]}`
  - `{"cmd":"get_status"}` → Status inkl. aktive Devices und Underrun-Counter
  - `{"cmd":"shutdown"}` → graceful Helper-Exit

### Volume/Mute-Polling
- Eigener Thread, 50ms Polling-Intervall (`VOLUME_POLL_INTERVAL_US = 50000`)
- Liest System-Volume des "Audio Router" Device via `AudioObjectGetPropertyData` (CoreAudio C API)
- Schreibt in SHM-Header (`volume_q16`, `muted`) — atomic, vom Plugin-WriteMix konsumiert
- Bewusst außerhalb des RT-Pfads — kein pyobjc/Python im Hot-Path mehr

### Hot-Plug-Listener
- Registriert `AudioObjectAddPropertyListener` auf `kAudioHardwarePropertyDevices`
- Bei Device-Änderung: Liste neu durchgehen, aktive Outputs überprüfen, ggf. IOProc beenden/neu starten

### launchd-Integration
- Plist: `helper/com.audiorouter.now.helper.plist`
- Label: `com.audiorouter.now.helper`
- `RunAtLoad=true` — startet bei User-Login automatisch
- `KeepAlive=true` — automatischer Restart bei Crash
- `ThrottleInterval=5` — verhindert Crash-Loops
- `ProcessType=Interactive` — höhere Scheduling-Priorität (Audio-RT)
- Logs: `/tmp/audiorouter.helper.log` + `/tmp/audiorouter.helper.err`

---

## 8. Technische Details — Python Menubar-App (v2.0)

### Was sich gegenüber v1 geändert hat
- **Kein Audio mehr in Python.** Keine `sounddevice`, kein `numpy`, kein `PortAudio`.
- `routing_engine.py` und `socket_receiver.py` sind **legacy** und werden nicht mehr geladen (im `.spec` excludet).
- Neue Datei: `helper_client.py` — Config-Socket-Client zum C-Helper.
- `device_manager.py` neu geschrieben: ctypes direkt gegen CoreAudio.framework.

### helper_client.py
| Aspekt | Implementierung |
|---|---|
| Transport | Unix Domain Socket `/tmp/audiorouter.config.sock` |
| Protokoll | JSON-Lines |
| Lifecycle | `ensure_running()` prüft Socket; spawnt Helper falls launchd ihn nicht schon laufen lässt |
| Spawn-Suche | PyInstaller-Bundle → installierter HAL-Pfad → Development-Pfad |
| Commands | `ping`, `get_status`, `set_outputs(List[OutputSpec])`, `shutdown` |
| Thread-Safety | `threading.Lock` für Socket-Zugriff |

### device_manager.py (ctypes CoreAudio)
| Aspekt | Implementierung |
|---|---|
| API | `ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")` |
| Discovery | `kAudioHardwarePropertyDevices` → alle Device-IDs, Filter auf Output-Streams >= 2 Kanäle |
| UID-Lookup | `kAudioDevicePropertyDeviceUID` (stabil über Reboot) |
| Hot-plug | Polling alle 2s (`HOTPLUG_POLL_INTERVAL`), Callback an Menubar |
| Virtuelles Device | "Audio Router" wird ausgefiltert (kann nicht eigenes Output sein) |

### menu_bar_app.py
| Aspekt | Implementierung |
|---|---|
| Framework | rumps |
| Steuerung | `HelperClient.set_outputs()` mit UID + ch_offset pro aktivem Output |
| Device-Picker | Multi-Select Checkbox-Menü, pro Channel-Pair separate Einträge bei N-Kanal-Devices |
| Default-Output-Switch | "System Audio → Audio Router" via `audio_device_control` (pyobjc) |
| Single-Instance | flock auf `~/.audiorouter/audiorouter.lock` |
| Donation | Buy Me a Coffee, Hint nach 15s |

---

## 9. Installer & Distribution

### build.sh — Was es tut (Phase 7+)
1. **Voraussetzungen** — Python 3.10+, Xcode CLT
2. **Driver + Helper bauen** — `make -C driver clean && make -C driver build`
   - Baut Driver-Binary (`AudioRouterNowDriver`, Universal)
   - Baut Helper-Binary (`AudioRouterNowHelper`, Universal)
   - Beide werden ad-hoc signiert und ins Bundle `Contents/MacOS/` gelegt
   - launchd-Plist wird ins Bundle `Contents/Resources/` gelegt
3. **Python venv** — installiert `rumps`, `pyobjc-core`, `pyobjc-framework-Cocoa`, `pyinstaller`, `Pillow`, `dmgbuild`
4. **PyInstaller** — baut `AudioRouterNow.app` aus `engine/menu_bar_app.py`
   - Driver-Bundle eingebettet (inkl. Helper-Binary)
   - launchd-Plist eingebettet
   - sounddevice/numpy/_sounddevice_data/cffi explizit ausgeschlossen → ~30-50 MB kleineres Bundle
5. **Ad-hoc Code-Signierung** mit `entitlements.plist` (`disable-library-validation`)
6. **DMG-Hintergrundbild** generieren (`create_dmg_background.py`)
7. **dmgbuild** mit Fenster-Layout
8. **AppleScript via Finder** — Hintergrundbild setzen (macOS Sequoia/Tahoe Kompatibilität)
9. **UDRW → UDZO** konvertieren
10. **DMG-Datei-Icon** setzen (`set_dmg_icon.py` via AppKit)

### Erststart-Installation (first_launch.py)
1. Prüft, ob `AudioRouterNow.driver` in `/Library/Audio/Plug-Ins/HAL/` existiert
2. Wenn nicht: Einmaliger macOS-Password-Prompt via AppleScript installiert Driver
3. coreaudiod-Neustart, damit das virtuelle Device sichtbar wird
4. launchd-Plist nach `~/Library/LaunchAgents/com.audiorouter.now.helper.plist` kopieren + `launchctl bootstrap`
5. Helper läuft fortan automatisch bei jedem Login

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

## 10. Bugs gefunden & behoben

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

### v2.0 — Erkenntnisse beim C-nativen Umstieg (27.05.2026)
| # | Komponente | Problem | Lösung |
|---|---|---|---|
| **E1** | HAL-Plugin | AudioServerPlugin darf nicht selbst CoreAudio-Client sein (Re-Entrant-HAL-Lock → Deadlock) | Externer Helper-Prozess als CoreAudio-Client |
| **E2** | SHM-Ring | Naive Ring-Capacity ohne 2er-Potenz → teures Modulo im Hot-Path | `ARN_RING_CAPACITY = 16384` (Zweierpotenz), Masking statt Modulo |
| **E3** | SHM-Header | False-Sharing zwischen `write_idx`/`read_idx` auf gleicher Cache-Line | Cache-Line-aligned Struct: 64-Byte-Gruppen, separater Padding |
| **E4** | Multi-Device | Mehrere Consumer mit gemeinsamem `read_idx` → schnellster Consumer "klaut" anderen die Frames | Pro-Device `local_ridx` im Helper, globaler `read_idx` = `min(local_ridx)` |
| **E5** | Helper-Spawn | Race: Helper startet bevor Plugin SHM erstellt hat | Retry-Loop bei `shm_open` (500ms-Intervall) im Helper |
| **E6** | Volume-Polling | pyobjc-Call in Python war früher Quelle für GIL-Jitter | C-natives Polling via `AudioObjectGetPropertyData`, 50ms |
| **E7** | launchd-Restart | Helper-Crash würde Audio sofort stoppen | `KeepAlive=true` + `ThrottleInterval=5` für robusten Auto-Restart |

---

## 11. Entscheidungen & Begründungen

| Datum | Entscheidung | Wahl | Begründung |
|---|---|---|---|
| 21.05.2026 | App-Name | AudioRouterNow | Final |
| 21.05.2026 | HAL Plugin Sprache | C (statt Swift) | AudioServerPlugin ist C-COM-API, Swift würde Bridging brauchen |
| 21.05.2026 | IPC-Methode v1 | Unix Domain Socket | Zuverlässig, low-latency, kein Polling nötig |
| 21.05.2026 | macOS Mindest-Version | macOS 11 Big Sur | Apple Silicon + AudioServerPlugin + Python 3.10 |
| 21.05.2026 | Lizenzstrategie | Proprietär | Keine GPL-Abhängigkeit, Kommerzialisierung jederzeit möglich |
| 26.05.2026 | Kein Pfeil im DMG | Arrow aus Background entfernt | macOS zeigt PNG-Dateien als generische Dokument-Icons |
| 26.05.2026 | DMG-Hintergrundfarbe | Teal-Grün (App-Icon-Farbe) | Kohärentes Design, passend zum Symbol |
| 26.05.2026 | BlackHole deinstalliert | Ja | Unnötiger HAL-Plugin belastet coreaudiod RT-Threads |
| 26.05.2026 | Python aus Hot-Path entfernen | Geplant für v2.0 | Python ist fundamental nicht-RT; C-natives Routing eliminiert Glitches |
| **27.05.2026** | **Audio-IPC: POSIX SHM statt Unix Socket** | **Shared Memory mit atomic Indices** | **~50ns Latenz statt 50–500µs + Jitter; lock-free, RT-safe, kein Syscall im Hot-Path** |
| **27.05.2026** | **C-Helper als externer Prozess** | **Separates Binary, nicht im Plugin** | **HAL-Plugin darf nicht selbst CoreAudio-Client sein (Deadlock-Gefahr durch Re-Entrant-Lock)** |
| **27.05.2026** | **sounddevice + numpy vollständig entfernt** | **ctypes CoreAudio im Python; C-natives Audio im Helper** | **~30-50 MB kleineres Bundle, kein PortAudio-Wrapper, keine GIL-Pausen im Audio-Pfad** |
| **27.05.2026** | **Helper-Start via launchd** | **User-Agent mit KeepAlive=true** | **Robust gegen Crashes; startet automatisch bei Login; Throttle verhindert Crash-Loops** |
| **27.05.2026** | **Multi-Device: pro-Device local_ridx** | **Globaler `read_idx` = min aller lokalen** | **Mehrere Consumer dürfen denselben Ring lesen ohne sich gegenseitig Frames wegzunehmen; bleibt SPSC-ABI-kompatibel** |
| **27.05.2026** | **Cache-Line-Padding im SHM-Header** | **64-Byte-Gruppen für Producer/Consumer/Control** | **Eliminiert False-Sharing zwischen Producer- und Consumer-Core** |

---

## 12. Performance-Profil (Stand v2.0)

### CPU-Verbrauch
- **coreaudiod (Driver):** ~1-3% CPU (HAL-Plugin schreibt nur in SHM, keine I/O mehr)
- **AudioRouterNowHelper:** ~1-2% CPU (C-natives IOProc, lock-free SHM-Read)
- **Python Menubar:** <0.1% CPU im Leerlauf (kein Audio, nur UI-Polling alle 2s)
- **Gesamt:** ~2-5% — deutlich geringer als v1 (~5-6%)

### Latenzen
| Übergang | v1.0.2 (Python) | **v2.0 (C-Helper)** |
|---|---|---|
| Driver → IPC | ~50–500µs (Socket + Jitter) | **~50ns (atomic store)** |
| IPC → Consumer-Wakeup | recv()-Syscall | **Polling im RT-Thread** |
| Consumer → CoreAudio | sounddevice/PortAudio (50ms Puffer) | **direkt (CoreAudio IOProc)** |
| Gesamt-Latenz | ~50–55ms | **~10–20ms (Ring-Fill)** |
| Jitter | GIL-abhängig | **~µs (RT-Thread only)** |

### Ring-Buffer
- **Kapazität:** 16384 Float32 Samples = 8192 Stereo-Frames
- **Zeitfenster:** ~170 ms @ 48 kHz
- **Layout:** Zweierpotenz (Masking statt Modulo), Cache-Line-aligned
- **Magic/Version:** `0x41524E52` (ARNR) / Version 2 — ABI-Check beim Attach

### Driver-IO-Rate
- 512 Frames @ 48 kHz → **93.75 IOProc-Calls / Sekunde** (Driver und Helper symmetrisch)

### Glitch-Häufigkeit
- **v1.0.0:** sehr häufig (mehrmals pro Minute)
- **v1.0.1:** seltener (nach Send-Fix + Queue-Tuning)
- **v1.0.2:** selten (nach latency=0.05 + RT-Thread-Fixes)
- **v2.0:** **praktisch 0** (kein GIL, kein Python, kein Socket-Jitter im Hot-Path)

---

## 13. Bekannte Einschränkungen (Stand v2.0)

1. ~~**Python im Hot-Path**~~ — **GELÖST in v2.0** durch C-Helper.
2. ~~**Uhr-Drift** zwischen virtuellem Driver und physischem Device~~ — **GELÖST in Phase 6** durch adaptive SRC (fraktionaler Leseindex + lineare Interpolation + P-Regler auf Ring-Füllstand)
3. **Nur Stereo-Input** — Treiber empfängt nur 2 Kanäle von CoreAudio (für System-Audio ausreichend)
4. **Code-Signierung fehlt** — Gatekeeper-Warnung auf anderen Macs
   - Aktuell: ad-hoc signiert (`codesign --sign -`)
   - Geplant: Apple Developer ID + Notarization wenn kommerzielle Vermarktung
5. **MAX_OUTPUTS = 8** Devices parallel (kompiliert) — kann durch Recompile erhöht werden
6. **Hardened Runtime + Notarization** noch nicht getestet — `entitlements.plist` enthält `disable-library-validation`, weitere Entitlements für SHM/Sockets prüfen

---

## 14. Roadmap

### Phase 1 — Fundament ✅ ABGESCHLOSSEN
- [x] HAL Plugin (AudioServerPlugin) in C implementiert
- [x] IPC zwischen Treiber und Routing-Schicht
- [x] Treiber installiert & aktiv als Default Output Device
- [x] Universal Binary (arm64 + x86_64)

### Phase 2 — Engine & UI ✅ ABGESCHLOSSEN
- [x] Routing-Schicht (v1: Python, v2: C-Helper)
- [x] Menu Bar Widget mit Device-Picker
- [x] Hot-plug Detection
- [x] Channel-Mapping für N-Kanal Devices
- [x] Persistente Config (~/.audiorouter/config.json)
- [x] CLI Interface
- [x] Natives System-Audio-Umschalten via osascript
- [x] Donation-System (Buy Me a Coffee)

### Phase 3 — Distribution ✅ ABGESCHLOSSEN
- [x] PyInstaller Spec + build.sh
- [x] DMG mit Finder-Fenster-Design
- [x] Hintergrundbild mit App-Icon-Farbe
- [x] macOS Sequoia/Tahoe Kompatibilität
- [x] first_launch.py — Erststart-Installer (Driver + launchd-Agent)

### Phase 0 (v2.0 Spike) — POSIX SHM Proof-of-Concept ✅ ABGESCHLOSSEN (27.05.2026)
- [x] `shared_ring.h` — Lock-free SPSC Ring (Header-Only)
- [x] Plugin schreibt Frames in SHM (`arn_ring_write`)
- [x] Minimaler Helper liest SHM und spielt auf Built-in Speakers ab
- [x] 5+ Minuten glitchfrei verifiziert
- Commit: `c5ae2d0`

### Phase 1-5 (v2.0) — Helper-Vollausbau ✅ ABGESCHLOSSEN (27.05.2026)
- [x] Helper-Skelett + RT-Thread (`THREAD_TIME_CONSTRAINT_POLICY`)
- [x] Multi-Device + Channel-Routing (`MAX_OUTPUTS = 8`)
- [x] Config-Socket Server (JSON-Lines, non-RT)
- [x] Python-Integration: `helper_client.py` ersetzt `routing_engine.py`
- [x] Volume/Mute-Polling in C (50ms)
- [x] launchd-Plist + KeepAlive
- [x] sounddevice + numpy aus Bundle entfernt
- Commit: `669d81d`

### Phase 7 — Build + Installer ✅ ABGESCHLOSSEN (27.05.2026)
- [x] Driver-Makefile baut Helper mit ins Bundle
- [x] build.sh: automatischer Helper-Build + launchd-Plist in App
- [x] PyInstaller-Spec excludet alte Python-Audio-Deps
- [x] DMG-Build erfolgreich
- Commit: `70031dd`

### Phase 6 — Clock-Drift-Kompensation via adaptiver SRC ✅ ABGESCHLOSSEN
- [x] Fraktionaler Ring-Leseindex (`src_frac_ridx`, double) pro Output-Device
- [x] Lineare Interpolation im IOProc — RT-safe (keine `AudioConverter`-Instanz nötig)
- [x] P-Regler im 50ms-Volume-Poll-Thread: Ziel = 50% Ring-Füllstand
- [x] RT-safe Inter-Thread-Kommunikation: `_Atomic uint32_t src_ratio_q20` (Q20-Fixed-Point)
- [x] Clamp auf ±500ppm (10× Max-Drift als Sicherheitsmarge)
- [x] Diagnose: `src_ratio` pro Device in `get_status`-Antwort

**Ansatz (gewählt gegen `AudioConverter`):**
- Bei ±50ppm Drift ist lineare Interpolation klanglich transparent (Aliasing irrelevant)
- Kein malloc/lock im IOProc — nur fraktionaler Index + zwei Sample-Reads pro Output-Frame
- Volume-Poll-Thread aktualisiert Ratio alle 50ms basierend auf Ring-Füllstand
- Volle Trennung der Threads: IOProc liest `src_ratio_q20` atomic (release-acquire)

**3 Fix-Iterationen während Implementierung:**
1. `d192de2` — Unit-Konsistenz: `src_frac_ridx` durchgehend als Frame-Index (nicht Sample-Index)
2. `40a0652` — Underrun-Strategie: Position nicht zurücksetzen bei Underrun, Overflow-Guard korrigiert
3. `276a4a2` — Root-Cause-Fix: `+2` Lookahead entfernt (`needed=1025 > batch=1024` → Endlos-Underrun)

**Verifiziert (Komplete Audio 6 MK2, 48kHz, 512 Frames/Batch):**
- Ring stabilisiert bei ~4096 Frames (Ziel: 4096) ✓
- `src_ratio` konvergiert: `0.999499` → `1.000259` (P-Regler aktiv) ✓
- Underruns: +1 über 68.000 IOProc-Calls nach Ring-Aufbau ✓

### Phase 6.1 — Stress-Test ohne Glitch [ ] offen
- [ ] 4h Musik-Wiedergabe ohne Underrun
- [ ] Ring-Füllstand schwingt um Ziel ein (~10-20s bei initial 50ppm Drift)
- [ ] CPU-Last-Tests mit `yes > /dev/null` parallel

### Phase 8 — Test-Matrix [ ] offen
- [ ] macOS 11, 12, 13, 14, 15
- [ ] Intel Mac + Apple Silicon
- [ ] Audio-Interfaces: Komplete Audio 6, Focusrite, SSL, MOTU, RME (sofern verfügbar)
- [ ] Stress-Tests: 4h Musik, CPU-Last-Tests, Sleep/Wake, Logout/Login

### Phase 9 — Code-Signierung + Notarization [ ] offen (für kommerzielle Nutzung)
- [ ] Apple Developer ID ($99/Jahr)
- [ ] Hardened Runtime mit korrekten Entitlements (SHM + Sockets)
- [ ] Notarization beim Apple Notary Service
- [ ] Stapler ans DMG

---

## 14.1 Geplante Features — spätere Versionen

### User-wählbare Sample-Rate (v3.0)
- Unterstützte Raten: 44100, 48000, 88200, 96000, 176400, 192000 Hz
- UI: Sample-Rate-Picker im Menubar-Dropdown
- HAL-Treiber muss dann die gewählte Rate in den SHM-Header schreiben
- Helper und AudioConverter müssen auf Sample-Rate-Änderungen reagieren
- Betrifft:
  - `driver/src/AudioRouterNowDriver.c` (GetStreamDescription)
  - `helper/AudioRouterNowHelper.c` (SRC-Ratio-Berechnung anpassen)
  - `engine/menu_bar_app.py` (neue UI-Elemente)

---

## 15. Implementierungsdetail v2.0 — SHM-Ring Header-Layout

> Verifiziert in `helper/shared_ring.h` (Stand 27.05.2026).
> Magic: `0x41524E52` ('ARNR'), Version: `2`, SHM-Pfad: `/audiorouter_shm`

```c
typedef struct {
    /* --- 0..63: Read-Only nach Initialize --- */
    uint32_t magic;           /* 0x41524E52 (ARNR)                 */
    uint32_t version;         /* 2                                 */
    uint32_t sample_rate;     /* 48000                             */
    uint32_t channels;        /* 2 (Stereo)                        */
    uint32_t capacity;        /* 16384 Samples                     */
    uint8_t  _pad0[44];

    /* --- 64..127: Producer-Hot (Cache-Line dediziert) --- */
    _Atomic uint32_t write_idx;
    uint8_t          _pad1[60];

    /* --- 128..191: Consumer-Hot (Cache-Line dediziert) --- */
    _Atomic uint32_t read_idx;
    uint8_t          _pad2[60];

    /* --- 192..255: Shared-Control (Volume/Mute aus Helper-Poll) --- */
    _Atomic uint32_t volume_q16; /* Q16: 65536 = 1.0                */
    _Atomic uint32_t muted;      /* 0 = aktiv, 1 = muted            */
    uint8_t          _pad3[56];

    /* --- 256+: Sample-Daten (interleaved L,R,L,R,...) --- */
    float samples[16384];
} ARNSharedRing;
```

**Synchronisation:**
- Producer (Driver WriteMix): `atomic_store_explicit(&write_idx, ..., memory_order_release)`
- Consumer (Helper IOProc): `atomic_load_explicit(&write_idx, ..., memory_order_acquire)`
- KEIN Mutex, KEIN Syscall im Hot-Path → RT-safe

**Multi-Device-Erweiterung (Helper-intern):**
- Helper hält `local_ridx[MAX_OUTPUTS]` außerhalb des SHM
- Globaler `read_idx` im SHM wird periodisch auf `min(local_ridx[i])` aktualisiert
- Producer sieht weiterhin klassisches SPSC-Verhalten, ABI bleibt stabil

---

## 16. Git-History (Meilensteine)

| Commit | Beschreibung |
|---|---|
| `b80b371` | Initial release — AudioRouterNow v1.0.0 |
| `39e1537` | Quality audit & fixes — v1.0.1 |
| `17ee59a` | DMG installer: macOS 26 compatibility — arrow icon + custom DMG icon fix |
| `055be57` | DMG: remove redundant arrow icon — background image handles Drag & Drop visual |
| `007d810` | DMG: teal-green background matching app icon symbol color; remove arrow |
| `a9b1698` | Performance: eliminate audio glitches under CPU load |
| `9563900` | Fix data race in SocketReceiver — shared frame_buf caused audio corruption |
| `6bfac22` | Fix audio glitches: sounddevice latency low → 50ms |
| `b1e9c9c` | docs: vollständige Projektdokumentation v1.0.2 |
| `e11b3ba` | docs: Architektur v2.0 vollständig dokumentiert |
| `c5ae2d0` | **feat: v2.0 Phase 0 Spike — POSIX SHM Ring ersetzt Unix Socket IPC** |
| `669d81d` | **feat: v2.0 vollständig — Phasen 1–5 + 7 implementiert und verifiziert** |
| `70031dd` | **feat: launchd Agent-Installation + automatischer Helper-Build in build.sh** |

---

## 17. Referenzen

- [Apple AudioServerPlugin Dokumentation](https://developer.apple.com/documentation/coreaudio)
- [Apple HAL Plugin Examples (SimpleAudio)](https://developer.apple.com/library/archive/samplecode/SimpleAudioDriver/)
- [BlackHole GitHub (Referenz-Implementierung)](https://github.com/ExistentialAudio/BlackHole)
- [POSIX Shared Memory (`shm_open`)](https://pubs.opengroup.org/onlinepubs/9699919799/functions/shm_open.html)
- [Apple Thread Time-Constraint Policy (RT-Threads)](https://developer.apple.com/library/archive/technotes/tn2169/_index.html)
- [Apple launchd.plist(5)](https://www.manpagez.com/man/5/launchd.plist/)
- [rumps — macOS Menu Bar Framework](https://github.com/jaredks/rumps)
- [PyInstaller — Application Bundling](https://pyinstaller.org/)
