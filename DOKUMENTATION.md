# AudioRouterNow — Vollständige Projekt-Dokumentation

**Stand:** 23. Mai 2026  
**Version:** 1.0.0  
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

---

## 1. Projektübersicht

AudioRouterNow ist eine **kostenlose, Open-Source macOS Menu-Bar-App**, die System-Audio gleichzeitig auf mehrere Audio-Interfaces leitet. Der Benutzer wählt beliebig viele Ausgabegeräte und Kanal-Paare — der Ton erscheint auf allen gleichzeitig, in Echtzeit.

### Kernprinzip

```
macOS System-Audio
       │
       ▼
[Audio Router] ← virtuelles Gerät (HAL-Treiber)
       │
       │  Unix Domain Socket (/tmp/audiorouter.sock)
       │  Float32 PCM, 48kHz, Stereo, 512 Frames/Block
       ▼
[Python Engine] ← SocketReceiver
       │
       ├──► Komplete Audio 6  Ch 1-2  (sounddevice OutputStream)
       ├──► Komplete Audio 6  Ch 3-4  (selber Stream, 2. Kanal-Paar)
       ├──► MacBook Lautsprecher      (sounddevice OutputStream)
       └──► Focusrite Scarlett        (sounddevice OutputStream)
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

Das Projekt besteht aus drei unabhängigen Schichten:

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: Installer (.dmg)                                   │
│  PyInstaller → .app │ build.sh │ DMG-Background │ ICNS Icons │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: Python Engine                                      │
│  menu_bar_app.py │ routing_engine.py │ socket_receiver.py   │
│  config.py │ device_manager.py │ audio_device_control.py    │
└─────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: C HAL-Treiber (AudioServerPlugin)                 │
│  AudioRouterNowDriver.c → AudioRouterNow.driver             │
│  Installiert in /Library/Audio/Plug-Ins/HAL/                │
└─────────────────────────────────────────────────────────────┘
```

### Datenfluss im Detail

1. **User spielt Audio ab** → macOS routet Audio an "Audio Router" (Standard-Ausgabe)
2. **HAL-Treiber `DoIOOperation`** empfängt `WriteMix`-Callback mit Float32-PCM
3. **Volume/Mute-Scaling** im Treiber (in-place, RT-sicher)
4. **`ipc_send_rt()`** sendet Bytes non-blocking über Unix Domain Socket
5. **`SocketReceiver`** (Python) empfängt, wandelt in `numpy (512, 2) float32`
6. **`RoutingEngine.on_frames()`** skaliert Volume (CoreAudio-Cache, 50ms)
7. **`sd.OutputStream` Callbacks** schreiben Audio in physische Devices

### Thread-Modell

| Thread | Erstellt von | Aufgabe |
|--------|-------------|---------|
| Main Thread (rumps RunLoop) | macOS | UI, Menu, Timer |
| `audiorouter-socket-receiver` | SocketReceiver | Unix Socket accept() + recv() |
| `com.audiorouter.now.connector` | HAL-Treiber | Socket connect/reconnect |
| RT Audio Thread (pro Device) | sounddevice | OutputStream Callback |
| coreaudiod IO Thread | macOS HAL | DoIOOperation Callback |
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

### IPC-Architektur (Unix Socket)

Der RT-IO-Callback darf **niemals blockieren**. Daher:

- **Connector-Thread** (`ipc_connector_main`): blockierendes `connect()`, 500ms Retry-Intervall
- **`ipc_send_rt()`**: nicht-blockierendes `send()` mit `MSG_DONTWAIT`; bei `EAGAIN` Frame verwerfen, bei `EPIPE` FD schliessen → Connector reconnectet automatisch
- **`atomic_int gSocketFD`**: einzige geteilte Variable zwischen RT-Thread und Connector-Thread, lock-free

```c
// Socket-Konfiguration nach connect():
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));  // kein SIGPIPE
int sndbuf = kRingBufferFrames * kBytesPerFrame * 8;           // 8 Frames Buffer
fcntl(fd, F_SETFL, flags | O_NONBLOCK);                        // Non-blocking
```

### Volume & Mute im Treiber

In `DoIOOperation` (RT-Callback, kein Lock — aligned reads sind auf arm64/x86_64 unkritisch):

```c
float vol  = gVolume;   // Float32, aligned read
bool  mute = gMute;     // bool, aligned read

if (mute || vol <= 0.0f) {
    memset(ioMainBuffer, 0, byteCount);      // Stille senden (Takt halten)
} else if (vol < 0.999f) {
    float *samples = (float *)ioMainBuffer;
    for (size_t i = 0; i < byteCount/4; i++) samples[i] *= vol;
}
ipc_send_rt(ioMainBuffer, byteCount);
```

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
| `routing_engine.py` | OutputStream-Verwaltung, Frame-Verteilung |
| `socket_receiver.py` | Unix Socket Server, PCM-Empfang |
| `audio_device_control.py` | CoreAudio ctypes: Device-Auswahl, Volume, Mute |
| `device_manager.py` | Hot-Plug-Erkennung, Device-Liste |
| `config.py` | JSON-Persistenz (`~/.audiorouter/config.json`) |
| `first_launch.py` | Treiber-Prüfung beim ersten Start |
| `cli.py` | CLI-Interface (Debug) |
| `requirements.txt` | Python-Abhängigkeiten |

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

Die Lautstärkesteuerung läuft auf **zwei Ebenen gleichzeitig**:

### Ebene 1: HAL-Treiber (C, RT-Thread)

Wenn der User die Tastatur-Lautstärketasten drückt:
1. macOS schreibt über `SetPropertyData` → `kAudioLevelControlPropertyScalarValue` in `gVolume`
2. Treiber ruft `gPlugInHost->PropertiesChanged()` → macOS zeigt Volume-HUD
3. In `DoIOOperation`: PCM-Samples werden in-place mit `gVolume` multipliziert (oder `memset(0)` bei Mute)
4. Skaliertes Signal geht über Socket zur Python-Engine

### Ebene 2: Python Engine (50ms Cache)

Die Python-Engine liest zusätzlich `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` des aktiven Standard-Output-Devices via CoreAudio ctypes und skaliert die Frames nochmals. Cache-Intervall 50ms — vermeidet CoreAudio-Syscall pro Audio-Frame (~93 Frames/Sek bei 48kHz/512 Buffer).

### Vollständiger Signalweg

```
Tastatur-Lautstärketaste
        │
        ▼
macOS → SetPropertyData → gVolume (Treiber)
        │                      │
        │                      ▼
        │               DoIOOperation (RT-Thread)
        │               PCM-Samples × gVolume (in-place)
        │               Bei Mute: memset(0)
        │                      │
        ▼                      ▼
PropertiesChanged()        Socket Send (non-blocking)
Volume-HUD erscheint            │
                                ▼
                         SocketReceiver
                         4096 Bytes → numpy (512,2) float32
                                │
                                ▼
                         RoutingEngine.on_frames()
                         CoreAudio VirtualMainVolume-Cache (50ms)
                         frames × cached_volume (numpy)
                                │
                         ┌──────┴──────┐
                         ▼             ▼
                    Device A       Device B
                sd.OutputStream  sd.OutputStream
                    (RT-CB)          (RT-CB)
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

*Dokumentation zuletzt aktualisiert am 23. Mai 2026 — AudioRouterNow v1.0.0*

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
