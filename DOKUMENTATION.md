# AudioRouterNow — Vollständige Projekt-Dokumentation

**Stand:** 30. Mai 2026  
**Version:** 2.3.0  
**Autor:** Mauricio Morkun  
**Lizenz:** MIT  

---

## Inhaltsverzeichnis

1. [Projektübersicht](#1-projektübersicht)
2. [Systemarchitektur](#2-systemarchitektur)
3. [HAL-Treiber (driver/)](#3-hal-treiber-driver)
4. [Engine (engine/)](#4-engine-engine)
5. [Installer (installer/)](#5-installer-installer)
6. [Konfiguration & Persistenz](#6-konfiguration--persistenz)
7. [Volume & Mute — Signalweg](#7-volume--mute--signalweg)
8. [Multi-Channel Multi-Output Routing](#8-multi-channel-multi-output-routing)
9. [Build & Installation](#9-build--installation)
10. [Implementierte Features (Entwicklungs-Chronik)](#10-implementierte-features-entwicklungs-chronik)
11. [Bekannte Limitierungen](#11-bekannte-limitierungen)
12. [Dateistruktur](#12-dateistruktur)
13. [Qualitäts-Audit & Fixes — 23. Mai 2026](#13-qualitäts-audit--fixes--23-mai-2026)
14. [Native C Helper — Architektur v2.0](#14-native-c-helper--architektur-v20)
15. [5-Wave Bugfix-Plan — Mai 2026](#15-5-wave-bugfix-plan--mai-2026)
16. [Volume-Keyboard-Fix — Mai 2026](#16-volume-keyboard-fix--mai-2026)
17. [Sandbox-Compliance Fix — v2.1 (29. Mai 2026)](#17-sandbox-compliance-fix--v21-29-mai-2026)
18. [User-Onboarding & UX-Layer (v2.2)](#18-user-onboarding--ux-layer-v22)
19. [Bugfix-Welle v2.3 — Initialisierungsreihenfolge & Stabilität (30. Mai 2026)](#19-bugfix-welle-v23--initialisierungsreihenfolge--stabilität-30-mai-2026)

---

## 1. Projektübersicht

AudioRouterNow ist eine **kostenlose, Open-Source macOS Menu-Bar-App**, die System-Audio gleichzeitig auf mehrere Audio-Interfaces leitet. Der Benutzer wählt beliebig viele Ausgabegeräte und Kanal-Paare — der Ton erscheint auf allen gleichzeitig, in Echtzeit.

### Kernprinzip (v2.0)

```
macOS System-Audio
       │
       ▼
[Audio Router] ← virtuelles Gerät (HAL-Treiber)
       │
       │  POSIX Shared Memory (/audiorouter_shm)
       │  Lock-Free Ring Buffer — Float32 PCM, 48kHz, 16384 Samples
       ▼
[C Helper: AudioRouterNowHelper] ← CoreAudio IOProc pro Device
       │
       ├──► Komplete Audio 6  Ch 1-2  (CoreAudio IOProc, SRC, volume_q16)
       ├──► Komplete Audio 6  Ch 3-4  (selber Helper, anderer ch_offset)
       ├──► MacBook Lautsprecher      (CoreAudio IOProc)
       └──► Focusrite Scarlett        (CoreAudio IOProc)
```

### Technische Alleinstellungsmerkmale gegenüber Alternativen (z.B. BlackHole)

| Merkmal | AudioRouterNow | BlackHole |
|---------|---------------|-----------|
| Kein Neustart nach Installation | ✅ | ❌ |
| Keine Kernel Extension (kext) | ✅ | ❌ |
| Universell (arm64 + x86_64) | ✅ | ✅ |
| Mehrere Ausgaben gleichzeitig | ✅ | ❌ (erfordert Multi-Output-Gerät) |
| Kanal-Paar Auswahl | ✅ | ❌ |
| Volume HUD (Lautstärke-Anzeige) | ✅ | ❌ |
| Menu-Bar Widget | ✅ | ❌ |
| Native CoreAudio HAL Plugin | ✅ | ✅ |

---

## 2. Systemarchitektur

Das Projekt besteht ab v2.0 aus vier unabhängigen Schichten:

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: Installer (.dmg)                                   │
│  PyInstaller → .app │ build.sh │ DMG-Background │ ICNS Icons │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: Python Engine (UI + Koordination)                  │
│  menu_bar_app.py │ config.py │ device_manager.py            │
│  audio_device_control.py │ helper_client.py                 │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│  Layer 1b: C Helper (AudioRouterNowHelper)                   │
│  AudioRouterNowHelper.c │ shared_ring.h                     │
│  Pro-Device CoreAudio IOProc │ Unix Domain Socket Config    │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│  Layer 1a: C HAL-Treiber (AudioServerPlugin)                │
│  AudioRouterNowDriver.c → AudioRouterNow.driver             │
│  Installiert in /Library/Audio/Plug-Ins/HAL/                │
└─────────────────────────────────────────────────────────────┘
```

Die v1-Architektur (Python Socket + `sounddevice`) wurde vollständig durch den nativen C Helper ersetzt. `socket_receiver.py` und `routing_engine.py` existieren nicht mehr.

### Datenfluss im Detail

1. **User spielt Audio ab** → macOS routet Audio an "Audio Router" (Standard-Ausgabe)
2. **HAL-Treiber `DoIOOperation`** empfängt `WriteMix`-Callback mit Float32-PCM
3. **Treiber schreibt Samples** via `arn_ring_write()` in SHM Ring-Buffer (`write_idx` atomic release)
4. **C Helper IOProc** (pro Output-Device): liest via `src_frac_ridx` (fraktional, SRC), skaliert mit `volume_q16`, schreibt in physisches Device
5. **`volume_poll_thread`** (alle 50ms): aktualisiert SRC-Ratio (P-Regler), setzt `ring->read_idx` = min(alle local_ridx)

### Thread-Modell

| Thread | Erstellt von | Aufgabe |
|--------|-------------|---------|
| Main Thread (rumps RunLoop) | macOS | UI, Menu, Timer |
| coreaudiod IO Thread | macOS HAL | DoIOOperation → Ring-Write |
| `arn-ioproc-<device>` (pro Device) | CoreAudio | IOProc → Ring-Read + SRC |
| `arn-volume-poll` | C Helper | SRC-Ratio, read_idx, SHM-Reconnect |
| `arn-config-accept` | C Helper | Unix Socket Config-Listener |
| `arn_shm_retry_thread` | HAL-Treiber | Hintergrund-Retry alle 500ms bis Helper SHM anlegt (v2.1) |
| `audiorouter-device-scanner` | DeviceManager | Hot-Plug Erkennung |

---

## 3. HAL-Treiber (driver/)

### Dateien

| Datei | Beschreibung |
|-------|-------------|
| `src/AudioRouterNowDriver.c` | Vollständiger Treiber (~1700 Zeilen C) |
| `resources/Info.plist` | Bundle-Manifest, CFPlugIn-Factory-UUID |
| `Makefile` | Universal-Binary Build, Install, Reload |

### Technologie: Apple AudioServerPlugin

Das HAL-Plugin ist eine **C-COM-API** (`AudioServerPlugInDriverInterface` Vtable mit 23 Funktionen). `coreaudiod` lädt die dylib automatisch beim Start aus `/Library/Audio/Plug-Ins/HAL/`. Kein Swift, kein kext, kein Reboot erforderlich.

### Objekt-Modell (statisch)

```
PlugIn (ID=1)
  └── Box (ID=2)
        └── Device "Audio Router" (ID=3)
              ├── Stream Output (ID=4)  — Float32, Stereo, 48kHz
              ├── Volume Control (ID=5) — Scalar 0.0–1.0, dB -96–0
              └── Mute Control (ID=6)   — Bool
```

### IPC-Architektur (POSIX Shared Memory)

Der RT-IO-Callback darf **niemals blockieren**. Ab v2.0 wird kein Syscall und kein Lock im Hot-Path verwendet — der Treiber schreibt direkt in einen POSIX Shared Memory Ring Buffer:

- **`arn_ring_write()`** in `shared_ring.h`: prüft verfügbaren Platz (`capacity - (write_idx - read_idx)`), schreibt Samples, atomic release store auf `write_idx`
- **`gSHMRing`**: globaler Pointer auf `ARNSharedRing`, gemapt via `mmap()` nach `shm_open()`

**Ab v2.1 — SHM-Ownership-Umkehr (Sandbox-Compliance):**

Der `_coreaudiod`-Prozess, der AudioServerPlugins lädt, läuft in einer Apple-Sandbox. Diese Sandbox blockiert `shm_open(O_CREAT)` — der Treiber kann das SHM-Segment nicht selbst anlegen. Außerdem scheitert `fchmod()` still und `umask(0)` hat keine Wirkung im Sandbox-Kontext.

**Lösung:** Architektur-Umkehr:
- **Helper erstellt das SHM** beim Start — er läuft als normaler User ohne Sandbox-Einschränkungen. `fchmod(fd, 0666)` setzt die Permissions für Cross-User-Zugriff.
- **Driver verbindet sich nur** — `shm_open(O_RDWR, 0)` ohne `O_CREAT`. Kein Schreibzugriff auf Segment-Erstellung.
- **Hintergrund-Retry-Thread (`arn_shm_retry_thread`)**: Falls der Helper beim Driver-Load noch nicht gestartet ist, startet der Treiber einen Retry-Thread der alle 500ms `arn_shm_init()` aufruft bis `gSHMRing` gesetzt ist.
- **`arn_shm_cleanup()`** unlinkt das SHM nicht mehr — der Helper ist Eigentümer und verwaltet den Lifecycle.

Der C Helper liest auf der anderen Seite des Ring Buffers — kein Python, kein Socket im Audio-Pfad.

### Volume & Mute im Treiber

In `SetPropertyData` (non-RT, unter `gStateMutex`):

```c
_Atomic float gVolume;   // Q16-Wert wird atomar in SHM geschrieben

// Bei ScalarValue oder DecibelValue:
atomic_store_explicit(&gVolume, v, memory_order_release);
uint32_t q16 = (uint32_t)(v * 65536.0f);
if (gSHMRing) atomic_store_explicit(&gSHMRing->volume_q16, q16, memory_order_release);
```

Das RT-Scaling (`samples[i] *= vol`) im `DoIOOperation`-Callback wurde entfernt (Wave 2 Fix, 28. Mai 2026) — der C Helper übernimmt die einzige Volume-Skalierung via `volume_q16`.

### Volume HUD — PropertiesChanged

Damit macOS die System-Lautstärke-Anzeige (HUD) aktualisiert, muss der Treiber `gPlugInHost->PropertiesChanged()` aufrufen. Implementiert in `SetPropertyData` für alle drei settable Properties:

```c
// Nach gVolume-Änderung (ScalarValue oder DecibelValue):
AudioObjectPropertyAddress volProps[] = {
    { kAudioLevelControlPropertyScalarValue,  kAudioObjectPropertyScopeGlobal, 0 },
    { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, 0 },
};
gPlugInHost->PropertiesChanged(gPlugInHost, kObjectID_Volume_Output, 2, volProps);

// Nach gMute-Änderung:
AudioObjectPropertyAddress muteProps[] = {
    { kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, 0 },
};
gPlugInHost->PropertiesChanged(gPlugInHost, kObjectID_Mute_Output, 1, muteProps);
```

### Build

```bash
cd driver
make                          # Universal Binary (arm64 + x86_64)
sudo make install             # → /Library/Audio/Plug-Ins/HAL/AudioRouterNow.driver
sudo make reload              # killall coreaudiod → Treiber wird neu geladen
```

Compiler-Flags: `-arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -O2 -fvisibility=hidden -std=c11`

---

## 4. Engine (engine/)

### Dateien

| Datei | Beschreibung |
|-------|-------------|
| `menu_bar_app.py` | rumps App, Menu-Logik, UI-Updates |
| `helper_client.py` | Startet und kommuniziert mit `AudioRouterNowHelper` |
| `audio_device_control.py` | CoreAudio ctypes: Device-Auswahl, Volume, Mute |
| `device_manager.py` | Hot-Plug-Erkennung, Device-Liste |
| `config.py` | JSON-Persistenz (`~/.audiorouter/config.json`) |
| `first_launch.py` | Treiber-Prüfung beim ersten Start |
| `cli.py` | CLI-Interface (Debug) |
| `requirements.txt` | Python-Abhängigkeiten |

> `routing_engine.py` und `socket_receiver.py` wurden in Phase 7 (Wave 5) entfernt — v1-Relikte der Python-Socket-Architektur.

### menu_bar_app.py

**Klasse:** `AudioRouterApp(rumps.App)`

#### Initialisierung

```python
def __init__(self):
    super().__init__("🔇", quit_button=None)
    self._config: AppConfig = load_config()
    self._active_device_names: set = set(self._config.output_device_names)
    self._device_offsets: Dict[str, List[int]] = {...}  # device → aktive Kanal-Offsets

    self._routing_engine = RoutingEngine(on_status=self._on_routing_status)
    self._socket_receiver = SocketReceiver(on_frames=self._routing_engine.on_frames)
    self._device_manager = DeviceManager(on_devices_changed=self._on_devices_changed)

    self._ui_timer = rumps.Timer(self._process_pending_updates, 0.25)
    # ...
    self._restore_saved_outputs()
    self._auto_start_if_configured()   # Auto-Start wenn Devices gespeichert
```

#### Thread-Safety-Pattern

rumps läuft auf dem macOS Main RunLoop. Hintergrund-Threads dürfen UI-Elemente **nicht direkt** ändern. Lösung: Flag-basiertes Deferred-Update-System:

```python
# Hintergrund-Thread (RoutingEngine, DeviceManager):
self._pending_status = (is_running, message)   # nur Flag setzen
self._device_update_pending = True              # nur Flag setzen

# Main-Thread-Timer (alle 250ms):
def _process_pending_updates(self, timer):
    if self._device_update_pending:
        self._build_menu()                      # UI-Änderung im Main-Thread
    if self._pending_status:
        self.title = "🎛️"  # oder "🔇"
```

#### Multi-Channel Device-Menu

Für Devices mit >2 Kanälen wird ein **Submenu** mit einem Eintrag pro Stereo-Paar erstellt. Jedes Paar ist unabhängig togglebar (Mehrfach-Auswahl):

```
☑  Komplete Audio 6 — Ch 1-2, Ch 3-4        ← Haupteintrag
   ├── ☑  Ch 1-2                              ← Submenu-Eintrag
   ├── ☑  Ch 3-4                              ← Submenu-Eintrag
   └── ☐  Ch 5-6                              ← Submenu-Eintrag
```

```python
def _toggle_channel_pair(self, sender, device: AudioDevice, offset: int):
    offsets = self._device_offsets.get(device.name, [])
    if offset in offsets:
        offsets = [o for o in offsets if o != offset]   # entfernen
    else:
        offsets = sorted(offsets + [offset])             # hinzufügen

    if offsets:
        self._device_offsets[device.name] = offsets
        self._active_device_names.add(device.name)
    else:
        self._device_offsets.pop(device.name, None)
        self._active_device_names.discard(device.name)

    self._save_and_apply()
    self._build_menu()
```

#### Auto-Start

```python
def _auto_start_if_configured(self):
    """Startet Routing automatisch wenn Devices aus letzter Session gespeichert."""
    if not self._active_device_names:
        return   # Erststart: warte auf manuelle Auswahl

    set_default_output_device(AUDIO_ROUTER_DEVICE_NAME)  # "Audio Router"
    self._apply_active_outputs()
    self._routing_engine.start()
```

Beim **ersten Start** (keine gespeicherten Devices) passiert nichts — der User muss manuell auswählen. Beim **zweiten Start** (Devices gespeichert) startet alles automatisch.

### routing_engine.py

**Kernproblem:** CoreAudio erlaubt pro physischem Device **nur einen aktiven OutputStream**. Wenn zwei Streams auf dasselbe Device öffnen, scheitert der zweite mit einem Fehler.

**Lösung:** Ein einziger Multi-Channel-Stream pro physischem Device. Alle aktiven Kanal-Paare werden in **einem Callback** bedient.

```python
@dataclass
class OutputTarget:
    device_index: int
    device_name: str
    channel_count: int
    channel_offset: int = 0   # 0=Ch1-2, 2=Ch3-4, 4=Ch5-6

@dataclass
class _StreamState:
    device_index: int
    device_name: str
    stream: sd.OutputStream
    frame_queue: Queue[Optional[np.ndarray]]
    offsets: List[int]        # alle aktiven Kanal-Paar-Offsets dieses Streams
```

**Stream-Öffnung** (Targets nach `device_index` gruppiert):

```python
n_channels = max(o + 2 for o in offsets)   # minimal nötige Kanalzahl

def _callback(outdata, frames, time_info, status):
    raw = frame_queue.get_nowait()           # Frame aus Queue (non-blocking)
    outdata.fill(0)
    for offset in active_offsets:
        outdata[:, offset:offset+2] = raw   # Stereo in jedes Kanal-Paar
```

**Volume-Scaling** im Hot-Path (50ms Cache, kein CoreAudio-Syscall pro Frame):

```python
def on_frames(self, frames: np.ndarray):
    now = time.monotonic()
    if now - self._volume_last_checked > 0.05:   # 50ms
        self._volume_last_checked = now
        self._cached_muted  = get_default_output_muted()
        self._cached_volume = get_default_output_volume()

    if self._cached_muted or self._cached_volume <= 0.0:
        scaled = np.zeros_like(frames)
    elif self._cached_volume < 0.999:
        scaled = (frames * self._cached_volume).astype(np.float32)
    else:
        scaled = frames   # vol == 1.0 → keine Kopie nötig

    for state in self._streams.values():
        state.frame_queue.put_nowait(scaled)   # non-blocking, Frame verwerfen bei Full
```

### socket_receiver.py

- **Socket:** `AF_UNIX, SOCK_STREAM`, Pfad `/tmp/audiorouter.sock`
- **Permissions:** `chmod 0o777` — nötig damit `_coreaudiod` (anderer User) connecten darf
- **Block-Protokoll:** Genau 4096 Bytes pro Block (512 Frames × 2 Ch × 4 Bytes Float32)
- **Reconnect:** Bei Verbindungstrennung sofort wieder auf neue Verbindung warten
- **Shutdown:** `server.close()` weckt `accept()` auf → sauberer Stop

### audio_device_control.py

Direkte CoreAudio-Aufrufe via `ctypes` (kein AppleScript, kein externes Tool). Funktioniert auf allen macOS-Versionen einschließlich macOS 26+.

**Funktionen:**

| Funktion | Beschreibung |
|----------|-------------|
| `set_default_output_device(name)` | Setzt macOS Standard-Ausgabe auf benanntes Device |
| `get_all_coreaudio_output_devices()` | Listet alle CoreAudio Output-Devices |
| `get_default_output_volume()` | Liest `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (0.0–1.0) |
| `get_default_output_muted()` | Liest `kAudioDevicePropertyMute` |
| `_get_default_output_device_id()` | Interne Hilfsfunktion: Device-ID des Standard-Outputs |

**CoreAudio-Konstanten:**

```python
_kAudioHardwareServiceDeviceProperty_VirtualMainVolume = 0x766D766C  # 'vmvl'
_kAudioDevicePropertyMute                              = 0x6D757465  # 'mute'
_kAudioHardwarePropertyDefaultOutputDevice             = 0x644F7574  # 'dOut'
_kAudioObjectPropertyScopeOutput                       = 0x6F757470  # 'outp'
```

**Fail-Open-Prinzip:** Alle Volume/Mute-Leseoperationen geben bei Fehler `1.0` / `False` zurück — kein unbeabsichtigtes Muting bei CoreAudio-Fehler.

---

## 5. Installer (installer/)

### Dateien

| Datei | Beschreibung |
|-------|-------------|
| `build.sh` | Haupt-Build-Script: venv → PyInstaller → Signierung → DMG |
| `AudioRouterNow.spec` | PyInstaller-Spec mit `icon=AudioRouterNow.icns` |
| `create_dmg_background.py` | Generiert DMG-Hintergrundbild mit weißen Labels |
| `entitlements.plist` | `com.apple.security.cs.disable-library-validation = true` |
| `AudioRouterNow.icns` | App-Icon (teal Routing-Baum, alle Größen) |
| `AudioRouterNow_dmg.icns` | DMG-Datei-Icon (App-Icon + Teal Download-Badge) |

### build.sh — Ablauf

```
1. Voraussetzungen prüfen (python3, clang, DRIVER_BUILD vorhanden)
2. Python venv erstellen / prüfen (.venv/)
3. requirements.txt installieren
4. PyInstaller + Pillow installieren
5. PyInstaller Build → dist/AudioRouterNow.app
6. Ad-hoc Code-Signierung (bottom-up, ohne --deep):
   a. xattr -cr (Extended Attributes entfernen)
   b. Alle .dylib Dateien signieren
   c. Alle .so Dateien signieren
   d. Python Shared Library signieren (überschreibt Homebrew Team-ID)
   e. MacOS/AudioRouterNow executable signieren (mit Entitlements)
   f. .app Bundle signieren (mit Entitlements)
7. DMG-Hintergrundbild generieren (create_dmg_background.py)
8. DMG erstellen:
   a. Staging-Verzeichnis: .app + Applications-Symlink + .background/
   b. hdiutil create (UDRW)
   c. Mounten
   d. Volume-Icon setzen (.VolumeIcon.icns + xattr kHasCustomIcon=0x0400)
   e. Fenster-Layout via AppleScript (background picture, icon positions, text size 10)
   f. Aushängen + konvertieren zu UDZO (komprimiert)
9. DMG-Datei-Icon setzen (AppKit NSWorkspace.setIcon_forFile_options_)
```

### Code-Signierung — Warum ohne --deep?

PyInstaller bündelt Homebrew-Python (andere Team-ID als die App). macOS Sequoia+ verweigert das Laden bei Team-ID-Konflikten. `--deep` scheitert zudem an `dist-info`-Verzeichnissen von pip-Paketen (keine validen Code-Bundles).

**Lösung:** Manuelles Bottom-Up-Signing:
1. Alle `.dylib` einzeln signieren
2. Alle `.so` einzeln signieren
3. Python Shared Library signieren (Team-ID-Override)
4. Executable mit Entitlements signieren
5. Bundle-Toplevel signieren

**Entitlements:** `com.apple.security.cs.disable-library-validation = true` — erlaubt das Laden von Bibliotheken mit verschiedenen Team-IDs.

### DMG-Layout

```
Fenster: 680×440pt (Bounds: {200, 120, 880, 560})
Icon-Größe: 100pt
Icon-Positionen:
  AudioRouterNow.app  →  (160, 210) pt
  Applications →         →  (520, 210) pt
```

### DMG-Hintergrundbild (create_dmg_background.py)

**Dimensions:** 1360×880px (@2x für Retina, entspricht 680×440pt Fenster)

**Design:**
- Dunkler vertikaler Gradient: `rgb(12,14,16)` → `rgb(18,22,24)`
- Subtiler Teal-Radialglow (Gaußscher Blur, Radius 500px) in der Fenstermitte
- Teal-Linie am oberen Rand (2px, abgestuft)
- **Weiße Label-Texte** direkt ins Bild gezeichnet an den exakten Icon-Positionen:
  - "AudioRouterNow" — Helvetica 26px, zentriert bei X=320px, Y=552px
  - "Applications" — Helvetica 26px, zentriert bei X=1040px, Y=552px

**Warum Labels im Bild?**  
macOS Finder rendert Icon-Labels immer in der System-Farbe (grau in Light Mode, helles Grau in Dark Mode) — unabhängig vom Hintergrundbild. Es gibt keine öffentliche API (AppleScript, .DS_Store, plist), um die Label-Textfarbe zu überschreiben.  
**Workaround:** Finder-Labels auf `text size 10` (Minimum, kaum sichtbar) setzen; weiße Labels ins Hintergrundbild an die exakten Pixel-Positionen zeichnen. Ergebnis: weiße, lesbare Labels auf dunklem Hintergrund — unabhängig vom System-Erscheinungsbild des Users.

### Icons

#### App-Icon (AudioRouterNow.icns)

Teal Routing-Baum auf dunklem Hintergrund mit abgerundeten Ecken. Nach Feedback um 90° nach links rotiert (ausgewogenere Komposition). Alle Größen: 16, 32, 64, 128, 256, 512, 1024px inkl. @2x Retina-Varianten.

#### DMG-Datei-Icon (AudioRouterNow_dmg.icns)

App-Icon + Teal Download-Badge:
- Kreisrunder Teal-Hintergrund (`rgb(0,180,160)`)
- Weißer Pfeil nach unten, mittig im Kreis, ausreichend groß
- Badge positioniert unten-mittig des App-Icons (leicht über der unteren Kante)
- Gesetzt auf die `.dmg`-Datei via AppKit `NSWorkspace.setIcon_forFile_options_`

---

## 6. Konfiguration & Persistenz

**Datei:** `~/.audiorouter/config.json`

```json
{
  "output_device_names": ["Komplete Audio 6", "MacBook Pro Lautsprecher"],
  "sample_rate": 48000,
  "buffer_size": 512,
  "donation_hint_shown": true,
  "output_device_offsets": {
    "Komplete Audio 6": [0, 2],
    "MacBook Pro Lautsprecher": []
  }
}
```

**`output_device_offsets`:** Dict von Device-Name → Liste aktiver Kanal-Offsets:
- `0` = Ch 1-2 (Offset 0)
- `2` = Ch 3-4 (Offset 2)
- `4` = Ch 5-6 (Offset 4)
- `[]` = kein Kanal-Paar gewählt (nur bei Stereo-Devices irrelevant)

**Migration:** Altes Format hatte `int` statt `List[int]`. `AppConfig.from_dict()` migriert automatisch:

```python
for k, v in raw_offsets.items():
    if isinstance(v, list):
        offsets[k] = [int(x) for x in v]
    else:
        offsets[k] = [int(v)]   # altes Format: int → [int]
```

Device-**Namen** statt Indizes werden gespeichert, weil sich Indizes nach Neustart oder Geräte-Wechsel ändern können.

---

## 7. Volume & Mute — Signalweg

Ab v2.0 läuft die Lautstärkesteuerung auf **zwei klar getrennten Ebenen** — ohne Python-Polling und ohne doppelte Skalierung.

### Ebene 1: HAL-Treiber (C, SetPropertyData)

Wenn der User die Tastatur-Lautstärketasten drückt:
1. macOS schreibt über `SetPropertyData` → `kAudioLevelControlPropertyScalarValue` oder `kAudioLevelControlPropertyDecibelValue` in `gVolume`
2. Treiber berechnet Q16-Wert und schreibt ihn **atomar** in SHM: `atomic_store_explicit(&gSHMRing->volume_q16, q16, memory_order_release)`
3. Treiber ruft `gPlugInHost->PropertiesChanged()` → macOS zeigt Volume-HUD
4. `DoIOOperation` schreibt unveränderte (unskalierte) Samples in den Ring Buffer

### Ebene 2: C Helper IOProc (RT-Thread, pro Device)

Der IOProc des C Helpers liest `volume_q16` atomar aus dem SHM und skaliert die Samples beim Lesen:

```c
uint32_t vol_q16 = atomic_load_explicit(&ring->volume_q16, memory_order_acquire);
float scale = (float)vol_q16 / 65536.0f;
// … Sample-by-Sample: out[i] = in[i] * scale
```

Kein Python-Polling. Keine doppelte Skalierung. Volume-Änderung ist innerhalb eines IOProc-Zyklus (~1ms) wirksam.

### Vollständiger Signalweg

```
Tastatur-Lautstärketaste
        │
        ▼
macOS → SetPropertyData → gVolume (Treiber, non-RT)
        │                      │
        │                      ▼
        │               gSHMRing->volume_q16 (atomic release)
        │                      │
        ▼                      │
PropertiesChanged()            │
Volume-HUD erscheint           │
                               │
DoIOOperation (RT-Thread)      │
Samples → Ring Buffer          │
(kein Scaling)                 │
        │                      │
        ▼                      ▼
        ┌──── POSIX Shared Memory Ring Buffer ────┐
        │                                         │
        ▼                                         ▼
 C Helper IOProc                           volume_poll_thread
 liest Samples via SRC                     (alle 50ms)
 skaliert mit volume_q16                   SRC-Ratio P-Regler
        │                                  read_idx aktualisieren
 ┌──────┴──────┐
 ▼             ▼
Device A    Device B
CoreAudio   CoreAudio
IOProc      IOProc
```

---

## 8. Multi-Channel Multi-Output Routing

### Problem: CoreAudio One-Stream-Limit

CoreAudio erlaubt auf einem physischen Device **nur einen aktiven `OutputStream`**. Der Versuch, einen zweiten zu öffnen, scheitert sofort.

**Falsche Lösung:** Pro Kanal-Paar einen eigenen Stream → zweiter schlägt fehl.

### Lösung: Ein Multi-Channel-Stream pro physischem Device

```python
# Alle Targets für dasselbe physische Device zusammenfassen:
device_groups: Dict[int, List[OutputTarget]] = defaultdict(list)
for target in self._targets:
    device_groups[target.device_index].append(target)

# Pro Device einen Stream mit der nötigen Kanalzahl öffnen:
offsets = sorted({t.channel_offset for t in targets})
n_channels = max(o + 2 for o in offsets)   # z.B. Ch 1-2 + Ch 5-6 → 6 Kanäle

# Im Callback alle aktiven Kanal-Paare bedienen:
def _callback(outdata, frames, time_info, status):
    raw = frame_queue.get_nowait()   # (512, 2) float32
    outdata.fill(0)
    for offset in active_offsets:
        outdata[:, offset:offset+2] = raw   # Stereo in Ch 1-2 AND Ch 5-6
```

### Beispiel

User wählt: **Komplete Audio 6 — Ch 1-2 + Ch 3-4** und **MacBook Lautsprecher**

→ 2 Streams werden geöffnet:
- Stream A: `Komplete Audio 6`, 4 Channels → schreibt in `[:,0:2]` UND `[:,2:4]`
- Stream B: `MacBook Pro`, 2 Channels → schreibt in `[:,0:2]`

Kein gleichzeitiger Versuch, dasselbe Device zweimal zu öffnen.

---

## 9. Build & Installation

### Voraussetzungen

- macOS 11.0+
- Python 3.10+
- Xcode Command Line Tools: `xcode-select --install`

### Treiber bauen und installieren

```bash
cd AudioRouterNow/driver
make                                     # Kompiliert Universal Binary
sudo make install                        # → /Library/Audio/Plug-Ins/HAL/
sudo make reload                         # killall coreaudiod → Treiber aktiv
```

### App bauen (.dmg)

```bash
cd AudioRouterNow/installer
chmod +x build.sh
./build.sh
# → ~/Desktop/AudioRouterNow.dmg
```

Der Build-Prozess dauert ~2–5 Minuten (PyInstaller bündelt ~200MB Python-Runtime).

### Installation auf einem neuen Mac

1. `AudioRouterNow.dmg` öffnen
2. `AudioRouterNow.app` in `Applications` ziehen
3. App starten → macOS fragt einmalig nach Passwort (Treiber-Installation)
4. Fertig — `🎛️` erscheint in der Menüleiste

### Treiber-Update (nach C-Quellcode-Änderungen)

```bash
cd driver
make
sudo make install && sudo make reload
```

---

## 10. Implementierte Features (Entwicklungs-Chronik)

### Phase 1: Grundsystem

- **HAL-Treiber** (`AudioRouterNowDriver.c`): Virtuelles Audio-Device "Audio Router", vollständige COM-Vtable (23 Funktionen), IO-Callback (`DoIOOperation`), Unix Socket IPC mit Connector-Thread
- **SocketReceiver** (`socket_receiver.py`): Unix Domain Socket Server, PCM-Empfang, Float32→numpy, Reconnect-Logik
- **RoutingEngine** (`routing_engine.py`): sounddevice OutputStreams, Frame-Verteilung via Queue
- **MenuBarApp** (`menu_bar_app.py`): rumps App, Basis-Menu, Device-Auswahl, System-Audio-Umschalten via CoreAudio ctypes

### Phase 2: Multi-Channel Multi-Output

**Problem:** User konnte mehrere Interfaces wählen, aber nicht mehrere Kanal-Paare desselben Interfaces — `sd.OutputStream` schlug beim zweiten Versuch auf demselben Device fehl.

**Implementierung:**
- `_device_offsets: Dict[str, List[int]]` — mehrere Offsets pro Device speichern
- RoutingEngine: `defaultdict`-Gruppierung nach `device_index` → ein einziger Multi-Channel-Stream
- Menu: Submenu pro Multi-Channel-Device; jedes Kanal-Paar unabhängig togglebar
- `config.py`: Migration `int` → `List[int]`

### Phase 3: Volume-Steuerung (Tastatur-Lautstärke)

**Problem 1:** Lautstärke-Tasten hatten keine Wirkung auf "Audio Router".

**Ursache:** `gVolume` wurde zwar in `SetPropertyData` gesetzt, aber in `DoIOOperation` nie auf den PCM-Buffer angewandt.

**Fix:** In-place Float32-Scaling in `DoIOOperation` (RT-sicher, kein Lock).

**Problem 2:** Volume-HUD erschien nicht / zeigte immer vollen Balken.

**Ursache:** `gPlugInHost->PropertiesChanged()` wurde nach Volume-Änderung nie aufgerufen. macOS weiß dadurch nicht, dass sich der Wert geändert hat.

**Fix:** `PropertiesChanged()` für Volume (ScalarValue + DecibelValue) und Mute nach jeder `SetPropertyData`-Änderung aufrufen.

**Problem 3:** Python-seitige Volume-Skalierung fehlte.

**Fix:** `audio_device_control.py` um `get_default_output_volume()` und `get_default_output_muted()` via CoreAudio ctypes erweitert; 50ms-Cache in `routing_engine.py`.

### Phase 4: Auto-Start beim App-Start

**Problem:** User musste nach jedem App-Start manuell "Routing starten" klicken.

**Implementierung:** `_auto_start_if_configured()` in `AudioRouterApp.__init__()`:
- Wenn `_active_device_names` nicht leer (aus gespeicherter Config): sofort starten
- Wenn leer (Erststart oder gelöschte Config): warten auf manuelle Auswahl
- Sicherheit für Erstnutzer: beim ersten Start passiert gar nichts automatisch

### Phase 5: Icons & Visual Identity

**App-Icon:**
- Teal Routing-Baum (Dreieck → Äste → Kreise) auf dunklem Hintergrund mit abgerundeten Ecken
- Nach User-Feedback um 90° nach links rotiert
- In PyInstaller-Spec integriert: `icon=str(Path(SPECPATH) / "AudioRouterNow.icns")`
- Volume-HUD zeigt App-Icon statt Standard-Lautsprecher

**DMG-Datei-Icon (`AudioRouterNow_dmg.icns`):**
- Mehrere Iterationen: zu kleiner Kreis → zu kleine Pfeilspitze → zu großer Badge → finale Version: Kreis mittig-unten, Pfeil groß und zentriert im Kreis
- Gesetzt via AppKit `NSWorkspace.setIcon_forFile_options_` in `build.sh`

### Phase 6: DMG-Installer Design

**Iteration 1:** Hintergrundbild mit Titel, Untertitel, Drag-Pfeil, dekorativen Kurven, Footer.  
**Problem:** Fenster öffnete zu klein (Titel abgeschnitten). DMG-Hintergrundbild ist ein statisches Bitmap ohne CSS-Layout-Engine.

**Entscheidung:** "Option A" — schlichtes, responsives Design ohne positionsabhängige Textelemente.

**Iteration 2:** Nur Gradient + Teal-Glow.  
**Problem:** Icon-Labels (Finder-gesteuert) erschienen dunkelgrau auf schwarzem Hintergrund — kaum lesbar.

**Ursache:** macOS Finder rendert Icon-Labels in der System-Farbe unabhängig vom Hintergrundbild. Keine öffentliche API zum Überschreiben.

**Endlösung:** Finder-Labels auf `text size 10` (Minimum), weiße Labels direkt ins Hintergrundbild an die berechneten Pixel-Positionen gezeichnet.

### Phase 7: Architektur-Migration — Native C Helper (Mai 2026)

**Motivation:** Die v1-Architektur (Python `SocketReceiver` + `sounddevice`) hatte mehrere strukturelle Schwächen: Python-GIL-Druckschwankungen im Audio-Pfad, Socket-Latenz (~1ms + Jitter), doppeltes Volume-Scaling (Treiber + Python), sowie Abhängigkeit von `numpy`/`sounddevice` im RT-kritischen Pfad.

**Migration:**

Die gesamte IPC-Schicht wurde ersetzt. Der neue Datenpfad:

```
Driver → POSIX Shared Memory (Lock-Free Ring Buffer) → C Helper (AudioRouterNowHelper) → CoreAudio IOProc
```

- **`shared_ring.h`** definiert `ARNSharedRing` (Struct, version 3, cache-line aligned): Header, Producer-Hot (`write_idx`), Consumer-Hot (`read_idx`), Shared-Control (`volume_q16`, `muted`), und `samples[16384]` float32
- **`AudioRouterNowHelper.c`**: Universal Binary (arm64 + x86_64), registriert pro Output-Device einen CoreAudio IOProc, liest Samples mit fraktionalem SRC aus dem Ring Buffer
- **`helper_client.py`**: Python-Seite — startet den Helper-Prozess, sendet `set_outputs`-Konfiguration via Unix Domain Socket
- **Gelöscht:** `engine/socket_receiver.py`, `engine/routing_engine.py`

### Phase 8: 5-Wave Bugfix + Volume-Keyboard-Fix (Mai 2026)

Nach der Architektur-Migration wurden in zwei Bugfix-Runden alle identifizierten Probleme behoben. Details in Abschnitt 15 (5-Wave Bugfix-Plan) und Abschnitt 16 (Volume-Keyboard-Fix).

### Phase 9: v2.1 Sandbox-Compliance (29. Mai 2026)

**Problem:** Nach jedem Neustart kein Audio — SHM-Segment wurde beim Driver-Load nie erfolgreich erstellt.

**Root Cause:** Der `_coreaudiod`-Prozess läuft in einer Apple-Sandbox, die `shm_open(O_CREAT)` blockiert. Außerdem scheitert `fchmod()` still und `umask(0)` hat keine Wirkung im Sandbox-Kontext — das SHM-Segment konnte weder angelegt noch für den User-Prozess (Helper) zugänglich gemacht werden.

**Fix (Commit 7c11697):** Architektur-Umkehr — Helper erstellt SHM, Driver verbindet sich nur. Neuer Retry-Thread im Driver für den Startup-Race. Makefile: `sudo make install` kopiert Helper automatisch in beide Pfade (HAL-Plugin-Dir + App-Bundle).

Details in Abschnitt 17 (Sandbox-Compliance Fix).

### Phase 10 — v2.2 User-Onboarding (29. Mai 2026)

5 Features implementiert, die die App vom rein technisch-funktionalen Zustand zu einer für Endnutzer verständlichen, selbsterklärenden Anwendung machen. Während die Phasen 1–9 die Audio-Engine korrekt zum Laufen brachten, schließt Phase 10 die Lücke zwischen "es funktioniert" und "der User versteht was passiert".

1. **Zustandsbewusste Status-Zeile** (commit `68fca0a`, Fixes `2ac8c36`) — 5-Zustands-Anzeige im Menü, klickbar bei behebbaren Problemen
2. **README v2.1 Architektur-Drift-Fix** (commit `0cc7699`) — veraltete Python-Socket-Architektur ersetzt durch aktuelles SHM-Diagramm
3. **First-Run Wizard** (commit `2813822`) — dreistufiger Onboarding-Dialog beim ersten Start
4. **Vollständige Deinstallation** (commit `c7e525b`) — `uninstall_all()` entfernt alle Komponenten in 8 Schritten
5. **Help-Menü** (commit `471089b`) — Untermenü mit Background-Info, Doku-Link und Uninstall

Details in Abschnitt 18 (User-Onboarding & UX-Layer).

### Phase 11 — v2.3 Stabilitäts-Bugfixes (30. Mai 2026)

Nach den UX-Erweiterungen der v2.2 traten unter realen Nutzungsbedingungen drei neue Bugkategorien auf — alle Folgen der v2.2-Architekturänderung (Helper erstellt SHM, Driver verbindet sich), die neue Initialisierungs-Reihenfolge-Probleme einführte. In dieser Session wurden behoben:

- **Initialisierungsreihenfolge-Fixes:** `_auto_start_if_configured()` setzt jetzt sowohl Default Output ('dOut') als auch System Output ('sOut') — Keyboard-Volume-Tasten folgen 'sOut' und waren zuvor inaktiv.
- **SR-Reinit-Entkopplung:** `_apply_best_sample_rate()` und `sr_reinit_all_outputs()` lösen keinen disruptiven Stop/Start aller Outputs mehr aus, wenn sich die effektive Sample-Rate nicht ändert; `AudioDeviceStart` erhält Retry-Logik.
- **Volume-Synchronisation:** Neuer Media-Key-Interceptor (`_handle_media_key`) und Fallback-Poller (`_poll_volume_sync`) halten `volume_q16` zuverlässig synchron, auch wenn Volume-Tasten das virtuelle HAL-Device nicht direkt erreichen.
- **StartIO Lazy-Init:** `_trigger_start_io` erzwingt nach Neuinstallation den IO-Stack-Aufbau (kein Audio mehr bei `write_idx == 0`).
- **Stale-SHM-Erkennung:** `arn_shm_watch_thread` im Driver erkennt Helper-Neustarts (neue Inode) und biegt `gSHMRing` atomar auf das neue Segment um.

Vollständige Details in Abschnitt 19 (Bugfix-Welle v2.3).

**Überblick:**
- Wave 1: Atomic Memory Model (Data Races eliminiert, `_Atomic` überall)
- Wave 2: Volume Double-Scaling Fix (Treiber-RT-Scaling entfernt, Helper übernimmt)
- Wave 3: Security & Validation (Socket/SHM Permissions, bounds checks)
- Wave 4: Driver Reload Safety (`arn_shm_init()` reload-sicher)
- Wave 5: Dead Code Removal (`socket_receiver.py`, `routing_engine.py`, LaunchD-Reste)
- Volume-Keyboard-Fix: `volume_poll_thread` überschrieb `volume_q16` alle 50ms zurück auf 100% — behoben durch Entfernen des `get_default_output_volume_c()`-Aufrufs

---

## 11. Bekannte Limitierungen

### macOS Finder Icon-Label-Textfarbe

macOS Finder erlaubt es **nicht**, die Textfarbe von Icon-Labels programmatisch zu setzen. Die Farbe folgt immer dem System-Erscheinungsbild. Keine API (AppleScript, `.DS_Store`, plist) überschreibt dies zuverlässig.

**Workaround:** Weiße Labels ins Hintergrundbild eingezeichnet. Finder-Labels auf Minimum.

### Treiber-Installation erfordert sudo

Apple-AudioServerPlugin-Bundles müssen in `/Library/Audio/Plug-Ins/HAL/` liegen — root-geschützt. `coreaudiod` muss danach neu gestartet werden. User wird einmalig beim ersten App-Start nach Passwort gefragt.

### sounddevice-Puffertiefe

`QUEUE_DEPTH = 8` → maximaler Puffer: 8×512/48000 ≈ 85ms. Bei Audio-Aussetzern oder überlastetem System können Frames verworfen werden (gewolltes Non-Backpressure-Verhalten).

### Python-Laufzeit im DMG

PyInstaller bündelt die gesamte Python-Runtime (~200MB). Das `.dmg` ist entsprechend groß. Keine externe Python-Installation auf dem Ziel-Mac nötig.

### Sample-Rate: 48 kHz fest

Der Treiber ist auf **48000 Hz** fixiert. `GetPropertyData` für `kAudioDevicePropertyAvailableNominalSampleRates` gibt ausschließlich 48000 Hz zurück; `SetPropertyData` lehnt alle anderen Raten mit `kAudioHardwareUnsupportedOperationError` ab. Die Python Engine ist ebenfalls auf `SAMPLE_RATE = 48000` und `BLOCK_SIZE = 512` fest konfiguriert. Diese Entscheidung vermeidet Pitch-Shift und Audio-Drift bei Sample-Rate-Wechsel (vorheriges Risiko, jetzt dauerhaft eliminiert). 48 kHz ist der Industriestandard für Computer-Audio-Routing.

---

## 12. Dateistruktur

```
AudioRouterNow/
├── LICENSE                              MIT License
├── README.md                            Kurz-Dokumentation (GitHub)
├── DOKUMENTATION.md                     Diese vollständige Dokumentation
│
├── driver/
│   ├── Makefile                         Universal-Binary Build + Install + Reload
│   ├── resources/
│   │   └── Info.plist                   CFPlugIn Bundle-Manifest + Factory-UUID
│   ├── src/
│   │   └── AudioRouterNowDriver.c       HAL AudioServerPlugin (~1700 Zeilen C)
│   └── build/
│       └── AudioRouterNow.driver/       Kompiliertes Bundle
│           └── Contents/
│               ├── Info.plist
│               └── MacOS/
│                   └── AudioRouterNowDriver    (Universal Binary arm64+x86_64)
│
├── engine/
│   ├── requirements.txt                 numpy, sounddevice, rumps, pyobjc-framework-*
│   ├── menu_bar_app.py                  Haupt-App (rumps), Menu, UI-Logik, Auto-Start
│   ├── routing_engine.py                Multi-Device OutputStream, Frame-Verteilung, Vol-Cache
│   ├── socket_receiver.py               Unix Socket Server, PCM-Empfang, Float32→numpy
│   ├── audio_device_control.py          CoreAudio ctypes: Volume, Mute, Device-Switch
│   ├── device_manager.py                Hot-Plug Erkennung, Device-Liste
│   ├── config.py                        JSON-Persistenz ~/.audiorouter/config.json
│   ├── first_launch.py                  Treiber-Prüfung + Installation beim Erststart
│   └── cli.py                           Debug-CLI
│
└── installer/
    ├── build.sh                         Haupt-Build-Script (venv+PyInstaller+Sign+DMG)
    ├── AudioRouterNow.spec              PyInstaller-Spec (icon, hidden imports, datas)
    ├── entitlements.plist               disable-library-validation (Homebrew-Python-Fix)
    ├── create_dmg_background.py         DMG-Hintergrundbild: Gradient+Glow+weiße Labels
    ├── AudioRouterNow.icns              App-Icon alle Größen (16–1024px + @2x)
    └── AudioRouterNow_dmg.icns          DMG-Datei-Icon (App-Icon + Teal Download-Badge)
```

---

*Dokumentation zuletzt aktualisiert am 30. Mai 2026 — AudioRouterNow v2.3.0*

---

## 13. Qualitäts-Audit & Fixes — 23. Mai 2026

Am 23. Mai 2026 wurde ein vollständiger Code-Audit des gesamten Projekts durchgeführt (alle 28 Dateien analysiert). Anschließend wurden alle identifizierten Probleme behoben. Die folgende Übersicht dokumentiert jeden Fix, seine Ursache und sein Resultat.

---

### Bereich: Korrektheit & Bugs

#### Fix 1 — Logging-Bug in `device_manager.py`

**Problem:** In `_scan_devices()` wurde `self._known_devices = new_devices` zugewiesen (Zeile 193) *bevor* die Namen der entfernten Devices abgerufen wurden. Danach griff der Log-Code auf `self._known_devices` zu — das jetzt schon `new_devices` war — und fand die entfernten Devices nicht mehr. Statt des echten Namens (z.B. "Focusrite Scarlett 2i2") erschien `#3` im Log.

**Fix:** Die Namen der entfernten Devices werden jetzt *vor* der Zuweisung gesichert:
```python
removed_names = [self._known_devices[i].name for i in removed if i in self._known_devices]
self._known_devices = new_devices  # Zuweisung danach
```

**Resultat:** Entfernte Devices erscheinen mit ihrem echten Namen im Log — essenziell für Debugging.

---

#### Fix 2 — Fragiler String-Split in `routing_engine.py`

**Problem:** Zum Ermitteln des physischen Device-Namens wurde folgender Code verwendet:
```python
device_name = targets[0].device_name.split(" Ch ")[0]
```
`OutputTarget.device_name` enthält für Multi-Channel-Devices den formatierten String `"Gerätname Ch 1-2"`. Das Split funktioniert nur, solange kein Gerätename selbst `" Ch "` enthält (z.B. "Yamaha AG Ch Control" würde falsch gesplittet).

**Fix:** Saubere Abfrage via sounddevice:
```python
try:
    device_name = sd.query_devices(device_index)["name"]
except Exception:
    device_name = targets[0].device_name  # Fallback
```

**Resultat:** Robuste Namensermittlung unabhängig vom String-Format des `device_name`-Feldes.

---

#### Fix 3 — Sample-Rate-Mismatch eliminiert

**Problem:** Der Treiber bot laut `kAudioDevicePropertyAvailableNominalSampleRates` die Raten 44100, 48000 und 96000 Hz an und akzeptierte Änderungen. Die Python-Engine war fest auf `SAMPLE_RATE = 48000` konfiguriert. Wenn ein User in `Audio MIDI Setup` auf 44.1 kHz oder 96 kHz umstellte, lief die Engine weiterhin mit 48000 Hz → Pitch-Shift und Audio-Drift.

**Fix:** Der Treiber bietet ausschließlich 48000 Hz an:
- `GetPropertyData` für `kAudioDevicePropertyAvailableNominalSampleRates`: nur `{min: 48000.0, max: 48000.0}`
- `SetPropertyData` für `kAudioDevicePropertyNominalSampleRate`: lehnt alle Raten ≠ 48000 mit `kAudioHardwareUnsupportedOperationError` ab

**Resultat:** Sample-Rate-Mismatch dauerhaft eliminiert. 48 kHz ist der Standard für Computer-Audio-Routing (BlackHole, Loopback, SoundFlower ebenfalls Standard-48kHz).

---

#### Fix 4 — Driver-Signierung nach Installation

**Problem:** In `first_launch.py` wurde der Treiber mit `cp -r` nach `/Library/Audio/Plug-Ins/HAL/` kopiert, aber anschließend nicht signiert. Unter macOS Sequoia (15+) ist `coreaudiod` strenger mit unsignierten HAL-Plugins und kann das Laden verweigern.

**Fix:** Nach der Installation wird sofort signiert:
```python
subprocess.run(
    ["codesign", "--force", "--deep", "--sign", "-", str(DRIVER_INSTALL_PATH)],
    check=False, capture_output=True,
)
```
`check=False`: Ad-hoc-Signierung ist Best-Effort — ein Fehler hier ist weniger schlimm als ein abgebrochener Install.

**Resultat:** Der installierte Treiber ist ad-hoc signiert. `coreaudiod` lädt ihn zuverlässig.

---

#### Fix 5 — Driver-Icon-Inkonsistenz im HAL-Treiber

**Problem:** In `GetPropertyDataSize()` war ein Case für `kAudioDevicePropertyIcon` vorhanden (lieferte `sizeof(CFURLRef)`), aber in `GetPropertyData()` gab es keinen entsprechenden Handler. Der Aufrufer bekam eine Größe zurück, aber beim Abrufen des Wertes einen Fehler. Inkonsistent und verwirrend.

**Fix:** Den `kAudioDevicePropertyIcon`-Case aus `GetPropertyDataSize()` entfernt. Das virtuelle Device zeigt jetzt das System-Default-Icon (Lautsprecher) in Audio MIDI Setup — korrekt und konsistent.

**Resultat:** Keine falsche API-Zusage mehr; Driver-Verhalten ist intern konsistent.

---

### Bereich: Code-Qualität

#### Fix 6 — Toter Code entfernt (`audio_device_control.py`)

**Problem:** Die Funktion `get_all_coreaudio_output_devices()` (~70 Zeilen) war in `audio_device_control.py` definiert, wurde aber an keiner Stelle im Projekt aufgerufen. Enthielt außerdem eine unbenutzte lokale Variable `out_scope_addr`.

**Fix:** Die gesamte Funktion wurde entfernt.

**Resultat:** Sauberere Codebase, kein toter Code der zukünftige Entwickler verwirrt.

---

### Bereich: Robustheit & User Experience

#### Fix 7 — Single-Instance-Check

**Problem:** Startete der User die App doppelt, entstanden zwei stille Menu-Bar-Icons. Die zweite Instanz scheiterte beim `bind()` auf den Unix Socket und lief als "stumme" App weiter.

**Fix:** Lockfile-basierter Single-Instance-Check am App-Start via `fcntl.flock()`:
```python
_lock_fd = open(_LOCK_FILE, "w")
fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)  # Nicht-blockierend
```
Bei laufender Instanz: `IOError` → Hinweis-Alert → `sys.exit(0)`.

Die Lock-Datei liegt unter `~/.audiorouter/audiorouter.lock` und enthält die PID der laufenden Instanz.

**Resultat:** Doppelstart zeigt eine freundliche Fehlermeldung; kein stilles Duplikat.

---

#### Fix 8 — File-Logging

**Problem:** Logs gingen ausschließlich in die macOS Console (stdout/stderr vom Prozess). Wenn ein User einen Bug meldete, war es unmöglich zu diagnostizieren was auf seinem Mac passiert war.

**Fix:** Rotating File Handler in `main()` eingerichtet, vor allen anderen Operationen:
```python
file_handler = RotatingFileHandler(
    Path.home() / ".audiorouter" / "logs" / "audiorouter.log",
    maxBytes=5 * 1024 * 1024,  # 5 MB
    backupCount=3,
    encoding="utf-8",
)
```

Logs unter: `~/.audiorouter/logs/audiorouter.log` (max. 3 × 5 MB = 15 MB).

**Resultat:** Bei Bug-Reports: "Bitte schick mir `~/.audiorouter/logs/audiorouter.log`" — sofortiger Diagnosezugang.

---

### Bereich: Internationalisierung

#### Fix 9 — Komplette Übersetzung auf Englisch

**Problem:** Die App hatte einen Sprachmix: Menütexte und Fehlermeldungen auf Deutsch (mit inkonsistenten Umlaut-Workarounds wie "Ausgabegeraet"), Donation-Texte auf Englisch. Das README war Englisch. Das ergab eine inkonsistente, unprofessionelle User-Erfahrung.

**Betroffene Dateien und Änderungen:**

| Datei | Geändert |
|-------|---------|
| `engine/menu_bar_app.py` | Alle Menu-Labels, Alerts, Notifications → Englisch |
| `engine/first_launch.py` | Alle Dialoge, Fehlermeldungen, Log-Messages → Englisch |
| `driver/src/AudioRouterNowDriver.c` | Alle `os_log()`-Messages → Englisch |
| `installer/AudioRouterNow.spec` | `NSMicrophoneUsageDescription` → Englisch |

**Beispiele:**

| Vorher | Nachher |
|--------|---------|
| `"⚫ Gestoppt"` | `"⚫ Stopped"` |
| `"▶  Routing starten"` | `"▶  Start Routing"` |
| `"Beenden"` | `"Quit"` |
| `"Kein Ausgabegeraet"` | `"No Output Device"` |
| `"Zeitüberschreitung"` | `"Timeout"` |
| `"IPC: mit Python Engine verbunden"` | `"IPC: connected to Python engine"` |

**Resultat:** Konsistente englische UI durch alle Schichten — von der C-Treiber-Log-Ausgabe bis zum macOS-Dialog.

---

### Bereich: Assets & Repository

#### Fix 10 — Fehlende Assets in Git gestagt

**Problem:** `installer/AudioRouterNow.icns`, `installer/AudioRouterNow_dmg.icns`, `installer/dmg_settings.py` und `projekt.md` waren nicht in Git eingecheckt. Ein `git clone` gefolgt von `build.sh` schlug sofort fehl.

**Fix:** `git add` der vier fehlenden Dateien.

**Resultat:** Das Repository ist vollständig — frischer Clone → Build funktioniert.

---

### Bereich: Dokumentation

#### Fix 11 — README-Faktencheck

**Korrekturen:**
1. *"compiled driver is included in repo"* entfernt (war falsch — `.gitignore` schloss `build/` aus). Stattdessen: expliziter Hinweis dass `make` im `driver/`-Verzeichnis ausgeführt werden muss.
2. *"MIT / Proprietary"* in der BlackHole-Vergleichstabelle → `"MIT"` (Lizenz ist ausschließlich MIT).
3. Intel-Hinweis präzisiert: nicht nur der Driver, sondern die gesamte App muss für Intel neu gebaut werden.
4. Usage-Section: Deutsche Strings `"System-Audio → Audio Router"` und `"Routing starten"` auf Englisch korrigiert.
5. Doppelter redundanter Note über Driver-Build zusammengefasst.

---

### Bereich: Wontfix / Bewusste Entscheidungen

| Thema | Entscheidung |
|-------|-------------|
| **Notarization** | Apple Developer Account ($99/Jahr) noch nicht vorhanden. Blocker für breite Öffentlichkeit, aber nicht für persönliche Nutzung oder geschlossene Beta. |
| **Tests** | Werden nach dem ersten öffentlichen Release nachgezogen — keine Blocker für v1.0. |
| **Auto-Update** | v1.1-Feature. Zu komplex (GitHub Releases API, UI-Flow, Offline-Handling) für v1.0. |
| **PDF-Template-Icons** in Menu Bar | v1.1-Polish. Emoji-Icons funktionieren in Light und Dark Mode. |
| **Driver-Icon** (echte CFURLRef) | v1.1. Aktuell: generisches Lautsprecher-Icon in Audio MIDI Setup. |

---

### Zustand nach dem Audit

| Bereich | Status |
|---------|--------|
| Code (Python Engine) | ✅ Bereinigt — alle bekannten Bugs gefixt |
| Code (C Driver) | ✅ Bereinigt — Sample-Rate fixiert, Icon-Inkonsistenz entfernt |
| Architektur | ✅ Unverändert solide |
| Sprache | ✅ Konsistent Englisch |
| Robustheit | ✅ Single-Instance, File-Logging, Driver-Signierung |
| Repository | ✅ Alle Assets in Git |
| Dokumentation | ✅ Auf aktuellem Stand |
| Release-Readiness | ⚠️ Notarization fehlt noch (Apple Developer Account benötigt) |

**Nächster Schritt für Public Release:** Apple Developer Program beitreten → Notarization-Workflow in `build.sh` integrieren → DMG mit `xcrun notarytool submit` + `stapler staple` veröffentlichen.

---

## 14. Native C Helper — Architektur v2.0

Der `AudioRouterNowHelper` ist das Herzstück der v2.0-Architektur. Er ersetzt den gesamten Python-Audio-Pfad durch einen nativen C-Prozess mit direktem CoreAudio-Zugriff.

### Übersicht

- **Datei:** `helper/AudioRouterNowHelper.c`
- **Header:** `driver/src/shared_ring.h` (geteilt mit Treiber)
- **Binary:** Universal Binary (arm64 + x86_64)
- **Start:** Durch `helper_client.py` beim App-Start
- **Logs:** `~/Library/Logs/AudioRouterNow/helper.log` und `helper.err`

### POSIX Shared Memory — ARNSharedRing

Der Ring Buffer (`/audiorouter_shm`) ist ein POSIX SHM-Segment mit dem Struct `ARNSharedRing` (version 3). Cache-line aligned (64 Bytes pro Gruppe) für lock-free Producer/Consumer:

| Offset | Name | Typ | Beschreibung |
|--------|------|-----|-------------|
| 0 | Read-Only-Header | struct | magic `0x41524E52`, version 3, `_Atomic` sample_rate, channels, capacity=16384, sr_change_gen |
| 64 | Producer-Hot | struct | `write_idx` — `_Atomic uint32_t`, vom Treiber-RT-Thread geschrieben |
| 128 | Consumer-Hot | struct | `read_idx` — `_Atomic uint32_t`, Minimum aller `local_ridx` (gesetzt von `volume_poll_thread`) |
| 192 | Shared-Control | struct | `volume_q16` — Q16 fixed-point (65536 = 100%); `muted` — `_Atomic uint32_t` |
| 256 | samples[16384] | float32[] | Interleaved L,R,L,R… (~170ms @ 48kHz Stereo) |

**Ring Buffer Eigenschaften:**
- Kapazität `ARN_RING_CAPACITY = 16384` — power-of-2 für bitweise Masking (kein Modulo)
- Producer: `arn_ring_write()` — atomic release store auf `write_idx` nach dem Schreiben
- Consumer: liest via `src_frac_ridx` (fraktionaler Index) für Sample Rate Conversion
- Available frames: `capacity - (write_idx - read_idx)` — wraps safely bei 32-bit overflow

### Per-Device Struct — DeviceOutput

Jedes Output-Device hat eine eigene Instanz:

```c
typedef struct {
    AudioDeviceID device_id;
    AudioDeviceIOProcID ioproc_id;
    uint32_t      ch_offset;           // Kanal-Offset (0=Ch1-2, 2=Ch3-4, …)
    _Atomic uint32_t local_ridx;       // Diese Device's Leseposition im Ring
    double        src_frac_ridx;       // Fraktionaler Frame-Index für SRC
    _Atomic uint32_t src_ratio_q20;    // Q20 SRC-Ratio (geschrieben von volume_poll_thread)
    uint32_t      src_ring_target;     // Ziel-Füllstand für SRC P-Regler
} DeviceOutput;
```

### IOProc — Audio-Hot-Path

Der CoreAudio-IOProc wird von `coreaudiod` im RT-Kontext aufgerufen (pro Device, pro Buffer-Periode):

1. Liest `write_idx` atomar (acquire) aus SHM
2. Berechnet verfügbare Frames: `avail = write_idx - local_ridx`
3. Liest `src_ratio_q20` atomar — bestimmt wie viele Ring-Samples pro Output-Frame konsumiert werden
4. Fraktionale SRC via lineare Interpolation: `src_frac_ridx += ratio` pro Output-Frame
5. Liest `volume_q16` atomar, berechnet `scale = vol_q16 / 65536.0f`
6. Schreibt skalierte Samples in `outdata` an `ch_offset`
7. Aktualisiert `local_ridx` atomar (release)

Bei Underrun (zu wenig Daten): Stille ausgeben, `src_frac_ridx` nicht weiterbewegen.

### volume_poll_thread

Läuft alle 50ms (`arn-volume-poll`), nicht im RT-Kontext:

1. **SHM-Reconnect-Guard:** Prüft magic + version. Falls Treiber neu geladen wurde (neues magic oder Versions-Mismatch): SHM neu mappen
2. **SRC-Ratio per Device:** P-Regler — vergleicht aktuellen Füllstand (`write_idx - local_ridx`) mit `src_ring_target`; passt `src_ratio_q20` an (Nachziehen wenn zu leer, Verlangsamen wenn zu voll)
3. **`update_global_read_idx()`:** Setzt `ring->read_idx` = Minimum aller aktiven `local_ridx` → der Treiber weiß damit, wie viel Platz im Ring frei ist

> `get_default_output_volume_c()` und `get_default_output_muted_c()` wurden entfernt (Volume-Keyboard-Fix, 29. Mai 2026) — Volume wird ausschließlich vom Treiber's `SetPropertyData` gesteuert.

### Config-Protokoll (Unix Domain Socket)

Der Helper lauscht auf `/tmp/audiorouter.config.sock` (permissions 0600). Python `helper_client.py` sendet Konfigurationsänderungen als JSON:

```json
{
  "command": "set_outputs",
  "outputs": [
    {"device_id": 73, "ch_offset": 0},
    {"device_id": 73, "ch_offset": 2},
    {"device_id": 46, "ch_offset": 0}
  ]
}
```

Der Helper registriert/deregistriert IOProcs dynamisch basierend auf den empfangenen `outputs`.

### Build

```bash
cd helper
clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
      -O2 -std=c11 -framework CoreAudio -framework AudioToolbox \
      -o AudioRouterNowHelper AudioRouterNowHelper.c
```

---

## 15. 5-Wave Bugfix-Plan — Mai 2026

Am 28. Mai 2026 (commit `6d8a36d`) wurden fünf aufeinander aufbauende Bugfix-Wellen implementiert.

---

### Wave 1 — Atomic Memory Model

**Problem:** Data Races im C Helper und im Treiber — `local_ridx`, `g_running`, `gVolume` etc. wurden von mehreren Threads ohne korrekte Memory-Order gelesen/geschrieben.

**Fixes im C Helper (`AudioRouterNowHelper.c`):**
- `DeviceOutput.local_ridx` → `_Atomic uint32_t` (war `uint32_t` — Data Race mit IOProc auf `volume_poll_thread`)
- `g_running`, `g_config_running`, `g_volume_running`, `g_shm_ready` → `static atomic_int`
- Alle Zugriffe: `atomic_load_explicit(..., memory_order_acquire)` / `atomic_store_explicit(..., memory_order_release)`

**Fix in `shared_ring.h`:**
```c
// Guard vor Division wenn channels == 0 (z.B. während SHM-Init):
if (ring->channels == 0) return 0u;
uint32_t frames = total_samples / ring->channels;
```

**Fix im Treiber (`AudioRouterNowDriver.c`):**
- `gVolume` → `static _Atomic float`
- `gMuted` → `static _Atomic bool`

**Resultat:** Alle identifizierten Data Races eliminiert. Thread Sanitizer zeigt keine Warnungen mehr.

---

### Wave 2 — Volume Double-Scaling Fix

**Problem:** Volume wurde zweifach angewandt:
1. Treiber-RT skalierte Samples in `DoIOOperation` mit `gVolume` (z.B. 50%)
2. Helper IOProc skalierte dieselben Samples nochmals mit `volume_q16` (50%)
→ Effektive Lautstärke: 50% × 50% = **25%** — Benutzer erlebt drastisch zu leise Wiedergabe.

**Fix:** RT-Scaling im Treiber-`DoIOOperation` vollständig entfernt. Der Treiber schreibt unveränderte (volle) Samples in den Ring Buffer. Ausschließlich der Helper skaliert.

**Fix im `SetPropertyData`-Handler (Treiber):**
```c
// ScalarValue oder DecibelValue geändert:
float v = /* neuer Wert */;
atomic_store_explicit(&gVolume, v, memory_order_release);
if (gSHMRing) {
    uint32_t q16 = (uint32_t)(v * 65536.0f);
    atomic_store_explicit(&gSHMRing->volume_q16, q16, memory_order_release);
}
```

**Resultat:** Volume-Tastatur und Slider funktionieren linear und korrekt. 50% Slider = 50% Lautstärke.

---

### Wave 3 — Security & Validation

**Problem:** SHM und Config-Socket waren world-accessible; fehlende Bounds-Checks bei `ch_offset` erlaubten out-of-bounds Kanal-Zugriffe.

**Fixes:**

```c
// Config-Socket: nur Owner darf connecten
chmod(CONFIG_SOCKET_PATH, 0600);

// SHM: Gruppe darf lesen/schreiben, Other nicht
shm_open(ARN_SHM_NAME, O_CREAT | O_RDWR, 0660);  // war 0666
```

In `output_add_locked()` — Bounds Check:
```c
// ch_offset darf nicht größer sein als die tatsächliche Output-Kanalzahl des Devices
if (ch_offset + 2 > device_output_channels) {
    os_log_error(logger, "ch_offset %u out of bounds for device %u (%u ch)",
                 ch_offset, device_id, device_output_channels);
    return;
}
```

In `parse_outputs()` — Clamp:
```c
if ((int32_t)ch_offset < 0 || ch_offset > 32) ch_offset = 0;
```

**Resultat:** Config-Socket ist auf den App-Owner beschränkt. Ungültige `ch_offset`-Werte führen zu keinem Out-of-Bounds-Zugriff mehr.

---

### Wave 4 — Driver Reload Safety

**Problem:** `sudo killall coreaudiod` (oder automatischer Neustart nach Absturz) reinitialisierte den Treiber. Der alte `arn_shm_init()` machte `memset(0)` auf das gesamte SHM-Segment — inkl. der `write_idx`/`read_idx` Counters. Der C Helper lief mit veralteten Counter-Werten weiter → Ring Buffer Corruption.

**Fix:** `arn_shm_init()` komplett überarbeitet:

```c
int arn_shm_init(void) {
    int fd = shm_open(ARN_SHM_NAME, O_CREAT | O_RDWR, 0660);
    // Prüfe existing segment:
    if (ring->magic == ARN_MAGIC && ring->version == ARN_VERSION) {
        // Gültiges Segment — flush: write_idx auf read_idx setzen
        uint32_t ridx = atomic_load_explicit(&ring->read_idx, memory_order_acquire);
        atomic_store_explicit(&ring->write_idx, ridx, memory_order_release);
        // sr_change_gen inkrementieren → Helper merkt Reload
        atomic_fetch_add_explicit(&ring->sr_change_gen, 1, memory_order_release);
    } else {
        // Ungültig oder falsche Version → shm_unlink + neu erstellen
        shm_unlink(ARN_SHM_NAME);
        // … fresh create mit memset(0) + magic/version setzen
    }
}
```

Der `volume_poll_thread` im Helper prüft `sr_change_gen` — bei Änderung mappt er SHM neu.

**Resultat:** `sudo killall coreaudiod` korrumpiert den Ring Buffer nicht mehr. Der Helper erholt sich automatisch innerhalb von ≤50ms (nächster `volume_poll_thread`-Zyklus).

---

### Wave 5 — Dead Code Removal

**Gelöschte Dateien:**
- `engine/socket_receiver.py` — v1 Unix Socket Server (Python)
- `engine/routing_engine.py` — v1 sounddevice OutputStream Manager (Python)

**Entfernte Funktionen aus `engine/first_launch.py`:**
- `install_launchd_agent()` — installierte einen LaunchD-Agent (v1-Architektur, unnötig)
- `unload_launchd_agent()` — entlud den LaunchD-Agent
- `_check_and_install_launchd_agent` umbenannt zu `_ensure_no_launchd_agent` (stellt sicher dass kein alter Agent mehr aktiv ist)

**Entfernte Funktion aus `engine/audio_device_control.py`:**
- `set_audio_router_sample_rate()` — setzte Sample Rate via CoreAudio; mit fixem 48kHz obsolet

**Log-Dateipfad geändert:**
- Alt: `/tmp/audiorouter.helper.log`
- Neu: `~/Library/Logs/AudioRouterNow/helper.log` und `helper.err` (macOS-konform, mit `Console.app` einsehbar)

**Resultat:** Codebase bereinigt. Keine v1-Relikte mehr. Klare Trennung zwischen Helper-Logs (Systemlogs-Verzeichnis) und App-Logs (`~/.audiorouter/logs/`).

---

## 16. Volume-Keyboard-Fix — Mai 2026

Am 29. Mai 2026 (commit `ea18bd7`) wurde ein kritischer Bug behoben, der Tastatur-Lautstärkeregler unwirksam machte.

### Root Cause

**Symptom:** Tastatur-Lautstärketasten zeigten das macOS Volume-HUD korrekt an, hatten aber keinen hörbaren Effekt auf die Wiedergabe. Volume-Slider in der Menu Bar hatte ebenfalls keinen Effekt.

**Ursache:** Im `volume_poll_thread` (alle 50ms) befanden sich zwei Aufrufe:

```c
float vol   = get_default_output_volume_c();    // ← Bug
bool  muted = get_default_output_muted_c();     // ← Bug
if (gSHMRing) {
    atomic_store_explicit(&gSHMRing->volume_q16,
                          (uint32_t)(vol * 65536.0f),
                          memory_order_release);
    atomic_store_explicit(&gSHMRing->muted, muted, memory_order_release);
}
```

`get_default_output_volume_c()` fragte `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (`0x766D766C 'vmvl'`) vom **ARN Virtual Device** ab. Das ARN-Device exponiert diese Property nicht → Fallback `1.0f` wurde zurückgegeben. Damit überschrieb `volume_poll_thread` alle 50ms das von `SetPropertyData` korrekt gesetzte `volume_q16` zurück auf 65536 (= 100%).

**Ablauf des Bugs:**

```
Tastendruck → SetPropertyData → volume_q16 = 32768 (50%)  ← korrekt
                                     ↓ (≤50ms später)
volume_poll_thread → get_default_output_volume_c() → 1.0f (Fallback)
                  → volume_q16 = 65536 (100%)  ← überschreibt!
```

### Fix

Entfernt aus `volume_poll_thread`:
- `get_default_output_volume_c()` und ihre gesamte Implementierung
- `get_default_output_muted_c()` und ihre gesamte Implementierung
- Den aufrufenden Block (SHM-Überschreib-Logik)

Der `volume_poll_thread` enthält jetzt ausschließlich:
1. SHM-Reconnect-Guard (magic/version prüfen)
2. SRC-Ratio-Update per Device (P-Regler)
3. `update_global_read_idx()` (ring->read_idx = min aller local_ridx)

**Volume-Kontrolle** liegt damit ausschließlich beim Treiber's `SetPropertyData`-Handler — sowohl für den ScalarValue- als auch den DecibelValue-Property-Pfad. Jede Änderung wird sofort und dauerhaft in `gSHMRing->volume_q16` geschrieben.

### Resultat

- Tastatur-Lautstärketasten: sofort hörbar, kein 50ms-Reset mehr
- Volume-Slider im Menu Bar: funktioniert korrekt in beide Richtungen
- Mute-Taste: funktioniert korrekt
- HUD-Anzeige: unverändert korrekt (war nie betroffen, da `PropertiesChanged()` weiterhin aufgerufen wird)

---

## 17. Sandbox-Compliance Fix — v2.1 (29. Mai 2026)

Commit `7c11697` — 29. Mai 2026.

### Symptom

Nach jedem Neustart des Systems (oder nach `sudo killall coreaudiod`) kein Audio über "Audio Router". Das SHM-Segment `/audiorouter_shm` wurde beim Treiber-Load nie erfolgreich erstellt, obwohl `arn_shm_init()` aufgerufen wurde.

### Root Cause — Apple AudioServerPlugin Sandbox

Der `_coreaudiod`-Prozess, der HAL-Plugins lädt, läuft in einer Apple-Sandbox. Diese Sandbox blockiert folgende Syscalls:

| Syscall | Ergebnis im Sandbox-Kontext |
|---------|----------------------------|
| `shm_open(O_CREAT)` | `EPERM` — Segment kann nicht erstellt werden |
| `fchmod(fd, 0666)` | Scheitert still — Permissions werden nicht gesetzt |
| `umask(0)` vor `shm_open` | Keine Wirkung — Sandbox ignoriert `umask`-Änderungen |

Da der Driver das Segment nicht anlegen konnte, blieb `gSHMRing = NULL`. Der Helper startete, versuchte sich mit `shm_open(O_RDWR)` zu verbinden, fand das Segment aber ebenfalls nicht — kein Audio.

Das Problem trat nach jedem Neustart auf, weil beim ersten App-Start (User-Prozess, keine Sandbox) das SHM zufällig noch existieren konnte (Relikt aus einer vorherigen Session). Nach Neustart war das POSIX SHM aus dem Kernel entfernt.

### Fix — Architektur-Umkehr

**Vorher (v2.0):** Driver erstellt SHM → Helper verbindet sich  
**Nachher (v2.1):** Helper erstellt SHM → Driver verbindet sich

#### Helper (`AudioRouterNowHelper.c`)

Der Helper (läuft als normaler User `mauriciomorkun`, keine Sandbox) erstellt das Segment proaktiv beim Start:

```c
int fd = shm_open(ARN_SHM_NAME, O_CREAT | O_RDWR, 0600);
ftruncate(fd, ARN_SHM_SIZE);
fchmod(fd, 0666);   // Cross-User-Zugriff für _coreaudiod
arn_ring_init(ring);
```

`fchmod(fd, 0666)` setzt die Permissions nach `ftruncate` — notwendig damit `_coreaudiod` (anderer Unix-User) später lesend und schreibend zugreifen kann. Die initiale `O_CREAT`-Permission `0600` genügt nicht.

#### Driver (`AudioRouterNowDriver.c`)

`arn_shm_init()` verwendet nur noch `O_RDWR` ohne `O_CREAT`:

```c
int fd = shm_open(ARN_SHM_NAME, O_RDWR, 0);
if (fd < 0) {
    os_log(gLog, "SHM: Noch nicht vorhanden (errno=%d) — warte auf Helper", errno);
    return;   // Retry-Thread übernimmt
}
```

Falls `shm_open` `ENOENT` zurückgibt (Helper noch nicht gestartet), kehrt die Funktion sofort zurück — kein Fehler, nur abwarten.

`arn_shm_cleanup()` ruft **kein** `shm_unlink()` mehr auf — der Helper ist Eigentümer des Segments und verwaltet dessen Lifecycle.

#### Hintergrund-Retry-Thread

Da der Treiber beim `ARN_Initialize`-Callback geladen wird (vor dem Helper-Start), wird ein Retry-Thread gestartet:

```c
static pthread_t  gSHMRetryThread  = 0;
static atomic_int gSHMRetryRunning = 0;

static void *arn_shm_retry_thread(void *arg) {
    while (atomic_load_explicit(&gSHMRetryRunning, memory_order_acquire)) {
        usleep(500000);   /* 500 ms */
        if (gSHMRing != NULL) break;
        arn_shm_init();
        if (gSHMRing != NULL) {
            os_log(gLog, "SHM: Retry erfolgreich — Driver mit Helper-Ring verbunden");
            break;
        }
    }
    return NULL;
}
```

Der Thread läuft bis `gSHMRing` gesetzt ist. `arn_shm_cleanup()` setzt `gSHMRetryRunning = 0` und joined den Thread beim Entladen des Treibers.

#### Makefile-Fix

`sudo make install` kopiert den Helper-Binary jetzt automatisch in beide relevanten Pfade:

1. `/Library/Audio/Plug-Ins/HAL/AudioRouterNow.driver/Contents/MacOS/AudioRouterNowHelper` — für den LaunchAgent der beim Login startet
2. Den App-Bundle-Pfad — für `helper_client.py` beim direkten App-Start

Damit ist sichergestellt, dass nach einem `sudo make install` der Helper sofort verfügbar ist, ohne dass er separat kopiert werden muss.

### Ablauf nach dem Fix (Normalfall)

```
System-Neustart
       │
       ▼
coreaudiod startet → AudioRouterNow.driver laden → ARN_Initialize()
       │
       ├── arn_shm_init() → ENOENT (Helper noch nicht da) → return
       └── arn_shm_retry_thread starten (500ms-Intervall)

       │ (kurz danach)
       ▼
LaunchAgent / App startet AudioRouterNowHelper
       │
       ├── shm_open(O_CREAT) → Segment anlegen
       ├── fchmod(fd, 0666)  → Permissions setzen
       └── arn_ring_init()   → Ring initialisieren

       │ (≤500ms später)
       ▼
arn_shm_retry_thread: arn_shm_init() → shm_open(O_RDWR) → Erfolg
gSHMRing gesetzt → Retry-Thread beendet sich
       │
       ▼
Audio-Routing aktiv ✅
```

### Resultat

- Nach jedem Neustart sofort Audio verfügbar (sobald Helper gestartet ist)
- Kein manuelles Eingreifen oder Treiber-Reload erforderlich
- Startup-Race zwischen Driver-Load und Helper-Start robust abgefangen (≤500ms Latenz)

---

## 18. User-Onboarding & UX-Layer (v2.2)

29. Mai 2026 — fünf Features, die die App von einem technisch korrekten Werkzeug zu einer für Endnutzer selbsterklärenden Anwendung machen.

### 18.1 Kontext & Motivation

Bis v2.1 war die gesamte Projekt-Dokumentation entwickler-orientiert: SHM-Layouts, Atomic-Memory-Order, IOProc-Hot-Path. Für die Korrektheit der Audio-Engine essenziell — aber ein Endnutzer, der die App startet, fand **keine Orientierung**: Was wurde installiert? Läuft es überhaupt? Was tue ich, wenn kein Ton kommt?

Eine Opus-Reflektionsrunde identifizierte ein **3-Layer-Modell** der Nutzer-Bedürfnisse:

| Layer | Frage des Users | Antwort vor v2.2 |
|-------|----------------|------------------|
| **Layer 0** | "Funktioniert es gerade?" | Keine — Menü zeigte nur statische Geräteliste |
| **Layer 1** | "Es geht nicht — was tue ich?" | Keine — kein Troubleshooting, kein Uninstall |
| **Layer 2** | "Wie ist das gebaut?" | Vollständig (DOKUMENTATION.md) |

Layer 2 war übererfüllt, Layer 0 und 1 fehlten komplett. Die fünf Features schließen genau diese Lücke.

**Grösster Impact:** die **zustandsbewusste Status-Zeile** (Layer 0). Sie beantwortet die häufigste Frage ("Geht es gerade?") direkt im Menü, ohne dass der User Logs öffnen oder raten muss.

### 18.2 Feature 1: Zustandsbewusste Status-Zeile

Die oberste Menüzeile spiegelt jetzt den realen Systemzustand wider. Fünf Zustände mit konkreten, handlungsorientierten Titeln:

| Symbol | Title | action_key | Klickbar |
|--------|-------|-----------|----------|
| ⚠️ | `Helper not responding — click to restart` | `restart_helper` | ✅ startet Helper neu |
| 🔴 | `No output selected — pick a device below` | `None` | — |
| 🟡 | `System audio not routed here — click to fix` | `switch_audio` | ✅ schaltet System-Audio um |
| 🟡 | `Ready — play something to start routing` | `None` | — |
| 🟢 | `Routing active — <Geräte>` | `None` | — |

Das Menüleisten-Icon spiegelt den Zustand: das erste Zeichen des Titles wird als Icon gesetzt (⚠️/🔴/🟡/🟢).

#### Technische Umsetzung

`_compute_status() -> tuple[str, object]` wertet vier Eingangssignale in fester Prioritätsreihenfolge aus:

1. **`helper_alive`** — `self._helper_alive` (gepingt im Timer)
2. **`outputs_selected`** — `bool(self._active_device_names)`
3. **`routed_here`** — `is_audio_router_default()` (System-Default == "Audio Router")
4. **`audio_flowing`** — `int(status.get("ring_frames", 0)) > 0`

Der vierte Punkt nutzt bewusst **`ring_frames > 0`** als Signal für tatsächlich fließendes Audio — **nicht** ein "active"-Flag des Helpers. Ein registrierter Output ist nicht dasselbe wie abgespieltes Audio; nur ein gefüllter Ring Buffer beweist, dass Samples durchlaufen.

```python
audio_flowing = False
status = self._helper.get_status(timeout=0.2)
if status is not None:
    try:
        audio_flowing = int(status.get("ring_frames", 0)) > 0
    except (TypeError, ValueError):
        audio_flowing = False
```

#### Timer-Integration & Performance

- **0.5s-Timer** (`_ui_timer`): `_process_pending_updates` ruft bei **jedem** Tick `_update_status_ui()` auf — nicht nur bei Helper-Zustandswechsel. Nötig, damit z.B. externes Umstellen des System-Audio-Outputs zeitnah erkannt wird.
- **Cache-Mechanismus gegen Flackern:** `_update_status_ui()` vergleicht `(title, action_key)` mit `self._last_status_cache` und rendert nur bei Änderung neu. Verhindert unnötiges Neusetzen von `self.title` und Menü-Callbacks bei jedem 0.5s-Tick.
- **0.2s Timeout für `get_status()`:** Der `get_status`-Aufruf in Schritt 4 verwendet `timeout=0.2`. Ohne diesen Timeout könnte ein hängender Helper den 0.5s-Timer für bis zu 0.4s (Default-Timeout) blockieren und damit die gesamte UI einfrieren. `get_status` wird zudem **nur** aufgerufen, wenn `helper_alive AND outputs_selected AND routed_here` — die teure Abfrage entfällt in allen Fehlerzuständen.

Klick-Dispatch über `_status_action()`: liest `action_key` aus dem Cache und ruft `_restart_helper()` bzw. `_switch_system_audio()` auf. Bei `action_key is None` ist die Zeile nicht klickbar (`set_callback(None)`).

### 18.3 Feature 2: README v2.1 (Architektur-Drift)

Das README enthielt noch die veraltete v1-Architektur (Python `SocketReceiver` + `sounddevice` über Unix Domain Socket) — ein **Architektur-Drift** gegenüber dem realen Code, der seit Phase 7 auf POSIX Shared Memory + C Helper läuft.

**Korrekturen:**
- Veraltetes Python-Socket-Diagramm ersetzt durch das aktuelle **SHM-Diagramm** (Driver → Lock-Free Ring Buffer → C Helper → CoreAudio IOProc)
- Neue Sektion **"What gets installed"** — listet HAL-Treiber und Helper-Daemon für den Endnutzer auf
- Neue Sektion **Troubleshooting** — nennt **beide** Log-Pfade: `~/.audiorouter/logs/audiorouter.log` (App) und `~/Library/Logs/AudioRouterNow/` (Helper)
- Neue Sektion **Uninstall** — verweist auf den Menüpunkt im Help-Untermenü

### 18.4 Feature 3: First-Run Wizard

**Datei:** `engine/onboarding.py` — `run_first_run_wizard(app, config) -> None`

Dreistufiger Onboarding-Flow via blockierende `rumps.alert`-Dialoge (modal). Wird nach der rumps-App-Init aufgerufen, da `rumps.alert` einen laufenden App-Context braucht:

1. **Welcome** — "Welcome to AudioRouterNow 🎛️": erklärt was installiert wurde (HAL Audio Driver + Helper Daemon), betont "no internet required, no data leaves your Mac" → Button "Next →"
2. **Choose outputs** — "Step 1 of 2": fordert den User auf, das 🎛️-Icon zu klicken und Geräte zu wählen; weist auf Mehrfachauswahl und automatisches Speichern hin → Button "Next →"
3. **You're set** — "Step 2 of 2": erklärt den automatischen System-Audio-Switch und die Bedeutung der Status-Indikatoren (🟢/🟡/🔴) → Button "Let's go!"

#### Einmaliger Trigger via Config-Flag

`AppConfig` hat ein neues Feld `onboarding_done: bool = False` (in `config.py`, inkl. `from_dict`-Migration). Der Trigger in `AudioRouterApp.__init__()`:

```python
if not self._config.onboarding_done:
    from onboarding import run_first_run_wizard
    run_first_run_wizard(self, self._config)
    save_config(self._config)  # onboarding_done=True persistieren
```

`run_first_run_wizard` setzt am Ende `config.onboarding_done = True`; die App persistiert via `save_config`. Beim nächsten Start wird der Wizard übersprungen. `onboarding.py` macht **keine Annahmen über den App-State** — nur `rumps.alert` + Config-Update — und kapselt den `import rumps` in ein `try/except`, um in Test-Umgebungen ohne rumps graceful zu überspringen.

#### PyInstaller-Integration

`installer/AudioRouterNow.spec` wurde um `"onboarding"` in den `hiddenimports` ergänzt — da das Modul nur per lazy `from onboarding import …` innerhalb der `if`-Bedingung geladen wird, würde PyInstaller es sonst nicht erkennen und nicht ins Bundle aufnehmen.

### 18.5 Feature 4: Vollständige Deinstallation

**Funktion:** `first_launch.uninstall_all() -> tuple[bool, str]` — die exakte Inverse von `install_driver()`.

Acht Schritte in **kritischer Reihenfolge** (Helper stoppen, bevor seine Ressourcen entfernt werden):

| # | Schritt | Mechanismus |
|---|---------|-------------|
| 1 | Helper-Daemon stoppen | `helper_client.shutdown()` + `pkill -f AudioRouterNowHelper` (2s Grace) |
| 2 | LaunchAgent deaktivieren | `_ensure_no_launchd_agent()` (bootout + plist entfernen) |
| 3 | POSIX SHM entfernen | `_posixshmem.shm_unlink("/audiorouter_shm")` |
| 4 | HAL-Treiber + `killall coreaudiod` | `osascript … with administrator privileges` |
| 5 | Config-Verzeichnis | `shutil.rmtree(~/.audiorouter/)` |
| 6 | Logs | `shutil.rmtree(~/Library/Logs/AudioRouterNow/)` |
| 7 | Helper-Log | `unlink(/tmp/audiorouter.helper.log)` |
| 8 | Control-Socket | `unlink(/tmp/audiorouter.config.sock)` |

**Fehlertoleranz:** Einzelne Schritt-Fehler werden geloggt und brechen die Deinstallation **nicht** ab. Nur Schritt 4 (Admin-Dialog) erlaubt dem User einen Abbruch — AppleScript-Fehlercode `-128` (Cancel) wird erkannt und als `(False, "Cancelled by user")` zurückgegeben.

**Admin-Rechte** für Schritt 4 analog zur Installation: `do shell script "rm -rf '<driver>' && killall coreaudiod || true" with administrator privileges`. macOS zeigt einmalig den Passwort-Dialog — dieselbe Mechanik wie beim Install.

**macOS-spezifische `shm_unlink`-Behandlung:** Auf macOS wirft `shm_unlink()` für ein nicht existierendes Segment einen `OSError` mit errno **`EINVAL` (22)** oder **`ENOENT` (2)** — **nicht** `FileNotFoundError`. Beide werden als "bereits entfernt" behandelt, damit keine irreführende Warnung erscheint:

```python
except OSError as oexc:
    if oexc.errno in (_errno.ENOENT, _errno.EINVAL):
        logger.info("Uninstall step 3: SHM segment already absent.")
    else:
        raise
```

Ein Fallback über `multiprocessing.shared_memory` greift, falls `_posixshmem` nicht importierbar ist.

**Menüpunkt:** "Uninstall AudioRouterNow…" im Help-Untermenü. `_uninstall()` zeigt zuerst einen Bestätigungsdialog (`_show_uninstall_confirm()`), stoppt den UI-Timer und den Helper, ruft `uninstall_all()` auf und beendet die App bei Erfolg. Bei Abbruch (`success == False`) wird der Timer wieder gestartet.

### 18.6 Feature 5: Help-Menü

Neues Untermenü **"Help"** mit drei Einträgen (jeweils durch Separator getrennt):

1. **"What's running in the background…"** → `_show_background_info()`
2. **"Open documentation"** → `_open_documentation()`
3. **"Uninstall AudioRouterNow…"** → `_uninstall()` (siehe 18.5)

#### `_show_background_info()` — dynamischer Status-Dialog

Erzeugt zur Laufzeit einen Infodialog mit echten System-/Routing-Daten — nicht statischem Text:

- **HAL Audio Driver:** Pfad (`DRIVER_INSTALL_PATH`) + Status ("Installed" / "Not found" via `is_driver_installed()`)
- **Helper Daemon:** Status mit **PID** falls selbst gestartet (`Running (PID <pid>)`), sonst "Running (managed externally)" oder "Not running"
- **Sample Rate:** formatiert aus `self._config.sample_rate` (z.B. "48 kHz")
- **Active Outputs:** sortierte Geräteliste (>3 Geräte → gekürzt mit "…")
- **Expected latency:** `≤ 171 ms (ring buffer)` — berechnet aus `ARN_RING_CAPACITY=16384 / 2 / 48000 × 1000`
- **Log-Pfade:** Config (`CONFIG_FILE`), App-Log (`~/.audiorouter/logs/audiorouter.log`), Helper-Log (`~/Library/Logs/AudioRouterNow/`)

#### `_open_documentation()` — Dev-Mode-Fallback

Öffnet bevorzugt die **lokale** `DOKUMENTATION.md` (relativ zum Modul, `__file__.parent.parent`) — relevant im Dev-Mode. Existiert sie nicht (z.B. im gebündelten App-Bundle), fällt es auf `DOCUMENTATION_URL` (GitHub) zurück:

```python
local_doc = pathlib.Path(__file__).parent.parent / "DOKUMENTATION.md"
if local_doc.exists():
    subprocess.run(["open", str(local_doc)])
else:
    webbrowser.open(DOCUMENTATION_URL)
```

---

## 19. Bugfix-Welle v2.3 — Initialisierungsreihenfolge & Stabilität (30. Mai 2026)

Am 30. Mai 2026 wurde eine Reihe von Stabilitäts-Bugs behoben, die unter realen Nutzungsbedingungen auftraten. Anders als die Audit-Welle (Abschnitt 13) und der 5-Wave-Plan (Abschnitt 15) handelt es sich hier nicht um proaktiv gesuchte Code-Smells, sondern um vom Nutzer beobachtete Symptome, deren gemeinsame Wurzel die v2.2-Architekturänderung war.

**Beteiligte Commits:**

| Commit | Beschreibung |
|--------|-------------|
| `f82de17` | `fix(driver): add SHM watch thread to detect Helper restart` |
| `2426b67` | `fix(volume): intercept media keys + set system output for volume HUD` |
| `1bc5579` | `fix: auto-start symmetry, StartIO trigger, volume poll fallback` |
| `41ea1b7` | `fix(routing): SR-reinit decoupled from output changes, retry on failure` |

---

### 19.1 Root-Cause-Analyse (Kontext)

Die v2.2-Architekturänderung kehrte die SHM-Ownership um: **der Helper erstellt das SHM-Segment, der Driver verbindet sich nur** (Sandbox-Compliance, siehe Abschnitt 17). Diese Umkehr ist korrekt und notwendig — sie führte aber als Nebeneffekt eine ganze Klasse neuer **Initialisierungs-Reihenfolge-Probleme** ein, weil nun zwei unabhängig gestartete Prozesse (Driver via `_coreaudiod`, Helper via App/LaunchAgent) sich über ein gemeinsames Segment finden müssen, dessen Lifecycle nicht mehr beim Driver liegt.

Drei Bugkategorien wurden identifiziert:

1. **Property-Asymmetrie** — beim Auto-Start wurde nur ein Teil der CoreAudio-Default-Properties gesetzt (Bug A).
2. **Über-aggressiver Reinit** — jede Output-Änderung löste einen vollständigen SR-Reinit aller Outputs aus (Bug B).
3. **Fehlende IO-Aktivierung & SHM-Drift** — kein Audio-Client → kein `StartIO` (Bug C); Helper-Neustart → Driver schreibt in veraltetes Segment (Bug D).

---

### 19.2 Bug A: Volume-Tasten inaktiv nach App-Start

**Symptom:** Nach dem App-Start zeigen die Keyboard-Volume-Tasten eine leere HUD-Bahn (kein gefüllter Lautstärke-Balken) und reagieren nicht auf Tastendruck. Erst manuelles Umschalten des Ausgabegeräts in den Systemeinstellungen "reparierte" das Verhalten.

**Root Cause:**

- `_auto_start_if_configured()` setzte nur `kAudioHardwarePropertyDefaultOutputDevice` (`'dOut'`, `0x644F7574`), **nicht** `kAudioHardwarePropertyDefaultSystemOutputDevice` (`'sOut'`, `0x734F7574`).
- macOS-Keyboard-Volume-Tasten folgen dem **System Output** (`'sOut'`), nicht dem Default Output (`'dOut'`).
- `'sOut'` blieb dadurch beim physischen Interface (z.B. Komplete Audio 6), das keine Software-Lautstärke unterstützt → die HUD-Bahn bleibt leer und Tastendrücke verpuffen.

**Warum der Workaround funktionierte:** Manuelles Umschalten in den Systemeinstellungen lässt macOS selbst **beide** Properties setzen (`'dOut'` + `'sOut'`). Danach zeigte `'sOut'` auf "Audio Router", und die Volume-Tasten wirkten.

**Fixes (4 Ebenen):**

**1. `_auto_start_if_configured()` — Symmetrie `dOut` + `sOut`** (`menu_bar_app.py`):

```python
set_default_output_device(AUDIO_ROUTER_DEVICE_NAME)
# System Output ebenfalls auf Audio Router setzen — Keyboard-Volume-
# Tasten folgen dem System Output ('sOut'). Symmetrisch zu dOut.
set_default_system_output_device(AUDIO_ROUTER_DEVICE_NAME)
```

Dieselbe Symmetrie wurde in `_switch_system_audio()` (manueller Klick auf die Status-Zeile) und in `_save_and_apply()` (Auto-Switch beim ersten aktivierten Output) eingezogen — überall, wo zuvor nur `'dOut'` gesetzt wurde, wird jetzt auch `'sOut'` gesetzt.

**2. `set_default_system_output_device()` — neue Funktion** (`audio_device_control.py`):

Strukturell analog zu `set_default_output_device()`, aber sie schreibt in `kAudioHardwarePropertyDefaultSystemOutputDevice`:

```python
_kAudioHardwarePropertyDefaultSystemOutputDevice = 0x734F7574  # 'sOut'

def set_default_system_output_device(device_name: str) -> tuple[bool, str]:
    """
    Setzt das macOS Default System Output (kAudioHardwarePropertyDefaultSystemOutputDevice).
    Keyboard-Volume-Tasten folgen dem System Output — damit diese auf
    'Audio Router' wirken (und nicht auf das physische Interface), muss
    Audio Router auch als System Output gesetzt sein.
    """
    # Device-Liste durchsuchen → target_id ermitteln → SetPropertyData auf 'sOut'
```

**3. `_poll_volume_sync()` — Fallback-Poller im 0.5s-Timer** (`menu_bar_app.py`):

Ein im UI-Timer (alle 0.5s) aufgerufener Poller, der **externe** Volume-Änderungen erkennt (z.B. durch andere Apps oder Tasten, die den Driver nicht direkt erreichen) und sie via `osascript` re-applied. Das erneute Setzen triggert den `SetPropertyData`-Pfad des Drivers, der `volume_q16` im SHM aktualisiert — so bleibt `volume_q16` immer synchron mit dem System-Volume.

```python
def _poll_volume_sync(self):
    """Fallback: Wenn Keyboard-Volume-Keys den Driver nicht direkt erreichen,
    erkennt dieser Poll die Änderung und triggert volume_q16 via osascript."""
    try:
        r = subprocess.run(['osascript', '-e',
            'output volume of (get volume settings)'],
            capture_output=True, text=True, timeout=0.3)
        new_vol = int(r.stdout.strip())
        old_vol = getattr(self, '_last_polled_vol', new_vol)
        self._last_polled_vol = new_vol
        if new_vol != old_vol:
            subprocess.run(['osascript', '-e',
                f'set volume output volume {new_vol}'],
                capture_output=True, timeout=0.3)
    except Exception:
        pass
```

**Loop-Sicherheit:** Der Poller reagiert ausschließlich bei einem **Delta** (`new_vol != old_vol`). Der zuletzt gesehene Wert wird in `self._last_polled_vol` gecacht. Setzt der Poller selbst das Volume, ist `new_vol` beim nächsten Tick gleich `old_vol` → keine erneute Aktion, keine Endlosschleife.

**4. `_handle_media_key()` — NSEvent GlobalMonitor** (`menu_bar_app.py`):

Da Volume-Tasten virtuelle HAL-Devices nicht zuverlässig direkt erreichen, fängt ein globaler `NSEvent`-Monitor (`NSSystemDefinedMask`) die Media-Keys ab und verarbeitet sie manuell — ohne Accessibility-Permissions:

```python
self._media_key_monitor = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
    NSSystemDefinedMask, self._handle_media_key
)
```

Der Handler dekodiert das `data1`-Feld der `NSSystemDefined`-Events (Typ 14, Subtype 8): Bits 31–16 = Key-Code, Bits 15–8 = Key-State (`0xA` = Key-Down). Verarbeitete Key-Codes (`NX_KEYTYPE_*`):

| Key-Code | Konstante | Aktion |
|----------|-----------|--------|
| `3` | `NX_KEYTYPE_SOUND_UP` | Volume +7 (`min(100, …)`) |
| `2` | `NX_KEYTYPE_SOUND_DOWN` | Volume −7 (`max(0, …)`) |
| `7` | `NX_KEYTYPE_MUTE` | Toggle: `0` wenn > 0, sonst `50` |

Der neue Wert wird via `set volume output volume X` (osascript) gesetzt — was wiederum den `SetPropertyData`-Pfad des Drivers korrekt triggert und `volume_q16` aktualisiert. `STEP = 7` ergibt ~15 Stufen über den Bereich 0–100.

---

### 19.3 Bug B: Output stoppt bei Multi-Device-Änderung

**Symptom:** Komplete Audio 6 + MacBook-Lautsprecher sind beide aktiv. Wird der MacBook-Lautsprecher abgewählt, stoppt **auch** die KA6 — obwohl an ihr nichts geändert wurde.

**Root Cause:**

- `_save_and_apply()` rief `_apply_best_sample_rate()` bei **jeder** Output-Änderung auf.
- Dieser Aufruf führte (über `set_sample_rate`) zu `sr_change_gen++` im SHM. Der `volume_poll_thread` des Helpers erkannte die Änderung und rief `sr_reinit_all_outputs()` auf.
- Die alte `sr_reinit_all_outputs()` stoppte **alle** Outputs atomisch (Stop/Destroy/Create/Start) — unabhängig davon, ob sich die Sample-Rate des jeweiligen Geräts überhaupt geändert hatte.
- Ein einzelner fehlschlagender `AudioDeviceStart` ohne Retry → der betroffene Output blieb dauerhaft `active = false` und stumm.

Effektiv: Das Entfernen der MacBook-Speaker veränderte die optimale gemeinsame Sample-Rate faktisch nicht — trotzdem wurden alle Outputs durch den Reinit gerissen, und die KA6 erholte sich nicht.

**Fixes:**

**1. `_apply_best_sample_rate()` — Early-Return bei unveränderter SR** (`menu_bar_app.py`):

```python
# Fix 3c: Nur wenn sich die optimale SR wirklich von der aktuellen
# Config-SR unterscheidet wird der Helper benachrichtigt. Sonst loest
# set_sample_rate() unnoetig einen disruptiven SR-Reinit aller Outputs aus.
if best == self._config.sample_rate:
    logger.debug("Auto Sample-Rate: %d Hz unveraendert — kein Reinit", best)
    return
```

Damit unterbleibt der `set_sample_rate`-Call (und das nachfolgende `sr_change_gen++`) vollständig, wenn die berechnete optimale Rate der aktuellen Config-Rate entspricht.

**2. `sr_reinit_all_outputs()` — Selektiver Reinit pro Output** (`helper/AudioRouterNowHelper.c`):

Statt blind alle Outputs zu stoppen, wird pro Output `kAudioDevicePropertyNominalSampleRate` des Geräts gegen die Ring-SR verglichen. Stimmen sie überein, wird **nur** die Leseposition neu gesetzt — der Output läuft ununterbrochen weiter:

```c
/* Aktuelle Device-SR lesen */
Float64 device_sr = (Float64)new_sr;
UInt32  sz = sizeof(Float64);
AudioObjectGetPropertyData(dev->dev_id, &sr_prop, 0, NULL, &sz, &device_sr);

/* Fix 3b: SR stimmt bereits ueberein — kein disruptiver Stop/Start. */
if ((uint32_t)device_sr == new_sr) {
    dev->base_ratio = 1.0;
    uint32_t q20 = (uint32_t)(dev->base_ratio * (double)(1u << 20));
    atomic_store_explicit(&dev->src_ratio_q20, q20, memory_order_relaxed);
    atomic_store_explicit(&dev->local_ridx, w, memory_order_release);
    dev->src_frac_ridx = (double)w / 2.0;
    /* active/proc_id bleiben unveraendert — Output laeuft weiter. */
    continue;
}
```

Nur Outputs mit tatsächlich abweichender Geräte-SR durchlaufen den vollen Stop → Destroy → Create → Start-Zyklus.

**3. `sr_reinit_all_outputs()` — Retry-Logik für `AudioDeviceStart`** (`helper/AudioRouterNowHelper.c`):

Für Outputs, die neu gestartet werden müssen, wird `AudioDeviceStart` bis zu 3× mit 100ms Pause versucht. Erst nach dem dritten Fehlschlag wird der Output explizit auf `active = false` gesetzt und das Scheitern protokolliert — statt eines stillen Fails:

```c
/* Fix 3a: AudioDeviceStart mit Retry — bis zu 3 Versuche, 100ms Pause.
 * Verhindert dass ein einmaliger transienter Fehler den Output dauerhaft
 * im stillen active=false-Zustand stehen laesst. */
for (int retry = 0; retry < 3; retry++) {
    err = AudioDeviceStart(dev->dev_id, dev->proc_id);
    if (err == noErr) break;
    if (retry < 2) usleep(100000);  /* 100ms */
}
if (err != noErr) {
    fprintf(stderr, "Helper: AudioDeviceStart fehlgeschlagen nach 3 Versuchen "
                    "(OSStatus %d) fuer %s — Output bleibt inaktiv\n",
            (int)err, dev->name);
    AudioDeviceDestroyIOProcID(dev->dev_id, dev->proc_id);
    dev->proc_id = NULL;
    dev->active  = false;
} else {
    dev->active = true;
}
```

**Resultat:** Das Ab-/Anwählen einzelner Geräte beeinflusst die übrigen Outputs nicht mehr, solange sich deren effektive Sample-Rate nicht ändert. Transiente `AudioDeviceStart`-Fehler werden überbrückt statt zu dauerhafter Stille zu führen.

---

### 19.4 Bug C: Kein Audio nach Neuinstallation

**Symptom:** Nach einer frischen DMG-Installation fließt kein Audio. Im Helper-Status bleibt `write_idx` (bzw. `ring_frames`) bei `0`.

**Root Cause:**

- Der HAL-Driver schreibt nur dann Samples in den Ring, wenn `gDeviceIsRunning > 0` — dieses Flag wird durch den `StartIO`-Callback gesetzt.
- `StartIO` wird von `coreaudiod` erst dann ausgelöst, wenn ein Audio-Client das Device aktiv öffnet.
- Nach einer Neuinstallation sind **keine Outputs** in der Config gespeichert → `_auto_start_if_configured()` kehrt sofort zurück (kein gespeichertes Device) → kein Client öffnet "Audio Router" → kein `StartIO` → `write_idx` bleibt `0`.

Der IO-Stack wird also nie "scharf geschaltet", weil zwischen erster Geräteauswahl und tatsächlichem Audio-Client eine Lazy-Init-Lücke klafft.

**Fix: `_trigger_start_io` — verzögerter IO-Stack-Aufbau** (`menu_bar_app.py`):

Beim ersten Output-Setup (`_save_and_apply()`, Zweig "erster aktivierter Output") wird ein Background-Thread gestartet, der 1.5s wartet (genug Zeit für coreaudiod, `StartIO` regulär auszulösen), dann den Helper-Status prüft. Ist der Ring danach immer noch leer, wird der Helper kurz heruntergefahren und neu verbunden — dieser Reconnect zwingt `coreaudiod`, den IO-Stack neu aufzubauen und `StartIO` auszulösen:

```python
def _trigger_start_io():
    import time
    time.sleep(1.5)  # coreaudiod braucht ~1s um StartIO auszulösen
    status = self._helper.get_status(timeout=1.0)
    if status and status.get("ring_frames", 0) == 0:
        # Ring noch leer — Helper neu verbinden triggert coreaudiod
        logger.info("StartIO-Trigger: Ring leer nach Device-Aktivierung, reconnect...")
        self._helper.shutdown()
        import time as _t; _t.sleep(0.5)
        self._helper.ensure_running()
threading.Thread(target=_trigger_start_io, daemon=True, name="start-io-trigger").start()
```

**Resultat:** Auch beim allerersten Geräte-Setup direkt nach der Installation wird der IO-Stack zuverlässig aktiviert — Audio fließt ohne manuellen Eingriff.

---

### 19.5 Bug D: Driver schreibt in veraltetes SHM nach Helper-Neustart

**Symptom:** Nach einem Helper-Neustart (z.B. App-Neustart oder manueller Helper-Restart über die Status-Zeile) herrscht Stille: Der Driver schreibt weiterhin in das **alte**, bereits unlinkte SHM-Segment, während der frisch gestartete Helper vom **neuen** Segment liest.

**Root Cause:**

Beim Helper-Startup ruft dieser `shm_unlink()` + `shm_open(O_CREAT)` auf — das entfernt das alte Segment aus dem Namespace und erstellt ein **neues** unter demselben Namen. Der Driver hatte aber noch das alte Segment gemappt (`gSHMRing != NULL`). Da der Retry-Thread (`arn_shm_retry_thread`) nur läuft, **solange** `gSHMRing == NULL` ist, lief er hier nicht — der Driver schrieb für immer in das veraltete Segment.

Die alte v2.1-Logik konnte einen Helper-**Neustart** also nicht erkennen, nur einen Helper-**Erststart**.

**Fix: `arn_shm_watch_thread`** (`driver/src/AudioRouterNowDriver.c`):

Ein neuer permanenter Watch-Thread (gestartet in `ARN_Initialize`, parallel zum Retry-Thread) erkennt das neue Segment über einen **Inode-Vergleich**:

- Alle 2s `shm_open(ARN_SHM_NAME)` + `fstat()`. Zeigt der Name auf eine **andere Inode** als unser aktuelles `gSHMFD`, existiert ein neues Segment (der Helper hat neu erstellt).
- Bei Erkennung: neues Segment mappen + validieren (`magic` / `version`), dann **atomarer Swap** von `gSHMRing` auf das neue Segment, `write_idx = read_idx` (Ring leeren) und `sr_change_gen++` zur Helper-Resync.

```c
/* Inode-Vergleich: zeigt der Name auf ein anderes Segment als unseres? */
struct stat cur_st, chk_st;
bool is_new_segment = false;
if (gSHMFD >= 0 &&
    fstat(gSHMFD, &cur_st) == 0 &&
    fstat(check_fd, &chk_st) == 0) {
    is_new_segment = (cur_st.st_ino != chk_st.st_ino);
}
...
/* Ring leeren (write_idx = read_idx) und Helper zur Resync triggern. */
uint32_t ridx = atomic_load_explicit(&new_ring->read_idx, memory_order_acquire);
atomic_store_explicit(&new_ring->write_idx, ridx, memory_order_release);
atomic_fetch_add_explicit(&new_ring->sr_change_gen, 1u, memory_order_release);

/* Atomarer Swap: ab jetzt sieht der IOProc das neue Segment. */
gSHMFD = check_fd;
atomic_store_explicit(&gSHMRing, new_ring, memory_order_release);
```

**RT-Sicherheit (verzögerte Bereinigung):** `gSHMRing` ist jetzt als `_Atomic(ARNSharedRing *)` deklariert; der IOProc lädt den Pointer **einmal** pro Aufruf atomar in eine lokale Variable. Das alte Mapping wird **nicht sofort** unmappt, sondern erst im **nächsten** Watch-Zyklus (2s später) freigegeben (`pending_old_ring` / `pending_old_fd`). Bis dahin sind alle in-flight IOProc-Aufrufe (Dauer ≪ 1ms) auf dem alten Pointer garantiert beendet — der RT-Thread kann nie auf ein gerade unmapptes Segment zugreifen (kein SIGBUS).

```c
/* Alten Swap-Rest jetzt sicher freigeben (in-flight IOProcs sind durch). */
if (pending_old_ring != NULL) {
    munmap(pending_old_ring, ARN_SHM_SIZE);
    pending_old_ring = NULL;
}
if (pending_old_fd >= 0) {
    close(pending_old_fd);
    pending_old_fd = -1;
}
```

`arn_shm_cleanup()` setzt `gSHMWatchRunning = 0` und joined den Watch-Thread beim Entladen des Treibers — analog zum Retry-Thread.

**Resultat:** Ein Helper-Neustart wird innerhalb von ≤2s erkannt; der Driver biegt automatisch auf das neue Segment um. Driver und Helper arbeiten danach wieder auf demselben Ring — kein dauerhaftes Verstummen mehr nach Helper-Neustart.

---

### Thread-Modell-Ergänzung (v2.3)

Der Driver besitzt jetzt zwei SHM-bezogene Hintergrund-Threads:

| Thread | Erstellt von | Aufgabe |
|--------|-------------|---------|
| `arn_shm_retry_thread` | HAL-Treiber | Wartet (alle 500ms) bis Helper SHM **erstmals** anlegt (v2.1) |
| `arn_shm_watch_thread` | HAL-Treiber | Erkennt Helper-**Neustart** (alle 2s, Inode-Vergleich) und swappt `gSHMRing` (v2.3) |

In der Engine ergänzen `_poll_volume_sync()` (im 0.5s-UI-Timer) und der `NSEvent`-Media-Key-Monitor (`_handle_media_key`) die Volume-Synchronisation; der `start-io-trigger`-Thread aktiviert einmalig den IO-Stack beim ersten Output-Setup.

---

*Dokumentation zuletzt aktualisiert am 30. Mai 2026 — AudioRouterNow v2.3.0*
