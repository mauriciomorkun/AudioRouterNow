# AudioRouterNow — HAL Driver (Phase 1)

Virtuelles macOS-Audio-Device **"Audio Router"** als Apple AudioServerPlugin
(HAL Plugin). Ersatz fuer BlackHole — ohne Kernel Extension, ohne
Security-Approval, ohne Neustart.

## Was es macht

1. Registriert ein Stereo-**Output**-Device "Audio Router" in Core Audio.
2. Schreibt macOS Audio auf dieses Device, werden die PCM-Samples
   (Float32, interleaved) im IO-Callback abgegriffen.
3. Die Samples werden **non-blocking** ueber einen Unix Domain Socket
   (`/tmp/audiorouter.sock`) an die Python Routing Engine (Phase 2)
   weitergeleitet.
4. Lauscht noch kein Python-Prozess, werden die Frames verworfen — der
   Treiber laeuft trotzdem stabil weiter.

**Audio-Format:** Float32 · 48000 Hz (auch 44100/96000) · 512 Frames · Stereo

## Dateien

| Datei | Zweck |
|---|---|
| `src/AudioRouterNowDriver.c` | Vollstaendiges AudioServerPlugin (C) |
| `resources/Info.plist`       | Bundle-Metadaten + CFPlugIn-Factory-Registrierung |
| `Makefile`                   | Build / Install / Uninstall / Reload |

## Voraussetzungen

- macOS 11 (Big Sur) oder neuer
- Xcode Command Line Tools (`xcode-select --install`)

## Build

```bash
cd driver
make
```

Erzeugt `build/AudioRouterNow.driver` als **Universal Binary**
(arm64 + x86_64), ad-hoc signiert (noetig, damit `coreaudiod` das Plugin
auf Apple Silicon laedt).

## Installation

```bash
sudo make install     # kopiert nach /Library/Audio/Plug-Ins/HAL/
sudo make reload      # startet coreaudiod neu -> Treiber wird geladen
```

> `make reload` fuehrt `killall coreaudiod` aus. macOS startet den Dienst
> sofort automatisch neu; laufende Audio-Wiedergabe stoppt dabei kurz.

Nach dem Reload erscheint **"Audio Router"** in
*Systemeinstellungen → Ton → Ausgabe*.

## Test

Pruefen, ob das Device registriert wurde:

```bash
python3 -c "import sounddevice; print([d for d in sounddevice.query_devices() if 'Audio Router' in d['name']])"
```

Erwartete Ausgabe: ein Geraet mit Namen `Audio Router`, 2 Output-Kanaelen.

Alternativ ohne Python:

```bash
system_profiler SPAudioDataType | grep -A4 "Audio Router"
```

IPC-Verbindung pruefen — minimaler Python-Listener (Phase-2-Platzhalter):

```python
import socket, os
p = "/tmp/audiorouter.sock"
if os.path.exists(p): os.remove(p)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(p); s.listen(1)
print("warte auf coreaudiod ...")
conn, _ = s.accept()
print("verbunden — empfange Audio")
while True:
    data = conn.recv(4096)
    if not data: break
    print(f"{len(data)} bytes")
```

Wird in macOS Audio auf "Audio Router" wiedergegeben, erscheinen
laufend Byte-Pakete (512 Frames x 8 Byte = 4096 Byte pro Block).

## Logs

Der Treiber laeuft in `coreaudiod` (keine Konsole). Logs via:

```bash
log stream --predicate 'subsystem == "com.audiorouter.now.driver"' --info
```

## Deinstallation

```bash
sudo make uninstall
sudo make reload
```

## Makefile-Targets

| Target | Wirkung |
|---|---|
| `make` / `make all` | Baut das `.driver` Bundle |
| `make install`      | Kopiert nach `/Library/Audio/Plug-Ins/HAL/` (root) |
| `make uninstall`    | Entfernt das installierte Bundle (root) |
| `make reload`       | `killall coreaudiod` — laedt Treiber neu (root) |
| `make clean`        | Loescht `build/` |

## Technische Hinweise

- **Statisches Objektmodell:** PlugIn(1) → Box(2) → Device(3) →
  Output-Stream(4) + Volume(5) + Mute(6). `CreateDevice`/`DestroyDevice`
  werden nicht unterstuetzt (das Device existiert dauerhaft).
- **RT-Sicherheit:** `DoIOOperation` laeuft auf einem Realtime-Thread —
  kein `malloc`, kein blockierendes IO. Der Socket-Send nutzt
  `MSG_DONTWAIT`; das (blockierende) `connect` erledigt ein separater
  Hintergrund-Thread, der die Verbindung alle 500 ms neu aufbaut.
- **Sample-Rate-Wechsel** laufen ueber
  `RequestDeviceConfigurationChange` → `PerformDeviceConfigurationChange`.
- **Code-Signierung:** Aktuell ad-hoc (Development). Apple Developer ID
  + Notarisierung folgen in Phase 3 (siehe `projekt.md`).

## Naechster Schritt (Phase 2)

Die Python Routing Engine muss den Unix Socket `/tmp/audiorouter.sock`
oeffnen (`bind` + `listen`), die Float32-Stereo-Frames lesen und auf die
gewuenschten physischen Audio-Interfaces verteilen.
