# AudioRouterNow

**Route macOS system audio to multiple audio interfaces simultaneously.**

AudioRouterNow is a free, open-source macOS menu bar app that lets you send your system audio to any combination of output devices at the same time — no restarts, no Terminal, no external tools required.

> Built by [Mauricio Morkun](https://mauriciomorkun.com) · Free forever · [Support via ☕](https://www.buymeacoffee.com/mauriciomorkun)

---

## What it does

macOS only routes system audio to one output at a time. AudioRouterNow breaks that limitation:

- Send system audio to **Out 1/2 and Out 3/4 simultaneously** on a multi-output interface
- Route to **multiple interfaces at once** — e.g. a USB interface + AirPods at the same time
- Auto-detects all connected audio interfaces and their channel counts
- Hot-plug: plug in a new interface → it appears in the menu instantly
- Works with USB, Thunderbolt, Bluetooth, HDMI, and internal audio

---

## How it works

AudioRouterNow uses a **custom HAL audio driver** (Apple AudioServerPlugin) — no kernel extension, no security approval, no restart required.

```
macOS System Audio
      │
      ▼
  AudioRouterNow.driver    ← our own virtual audio device
  (Apple HAL Plugin)       ← no kext, no restart, no approval
      │  Unix Socket
      ▼
  Python Routing Engine
      │
      ├──► Komplete Audio 6 — Out 1/2 + Out 3/4
      ├──► AirPods Pro
      └──► MacBook Pro Speakers
```

---

## Features

- **Menu bar interface** — click `🎛️`, check the outputs you want, done
- **Multi-output routing** — any number of devices simultaneously
- **Cross-interface** — route to outputs across different devices at the same time
- **Channel pair selection** — for multi-channel interfaces, choose exactly which output pair to use (Out 1-2, Out 3-4, Out 5-6…) via submenu
- **Hot-plug detection** — devices appear and disappear in real time
- **Remembers your setup** — selected outputs and channel pairs are restored on next launch
- **One-click system audio switch** — switches macOS system output to Audio Router natively (CoreAudio, no AppleScript)
- **No external tools** — no Homebrew, no SwitchAudioSource, no Terminal

---

## Requirements

- macOS 11 (Big Sur) or later
- Apple Silicon (arm64) — Intel Macs are not supported by the prebuilt binary. The entire app must be rebuilt from source (Apple Silicon only).

---

## Installation

1. Download `AudioRouterNow.dmg` from [Releases](../../releases)
2. Open the DMG and drag the app to Applications
3. Launch the app — macOS will ask for your password once to install the audio driver
4. `🎛️` appears in your menu bar — you're done

No Terminal. No restart. No security approval.

---

## Usage

1. Click `🎛️` in the menu bar
2. Check the output devices you want to route to
3. Click **"System Audio → Audio Router"** to switch macOS system audio
4. Click **"Start Routing"**
5. Audio now plays through all selected outputs simultaneously

---

## Coming from BlackHole?

AudioRouterNow was built as a complete, license-free replacement:

| | BlackHole | AudioRouterNow |
|---|---|---|
| License | GPL-3.0 | MIT |
| Kernel Extension | Yes | **No** |
| Security approval | Yes, manual | **No** |
| System restart | Yes | **No** |
| External tools | Yes (SwitchAudioSource) | **No** |
| Multiple interfaces | No | **Yes** |
| N-channel routing | No | **Yes** |
| Hot-plug | No | **Yes** |

No kernel extension. No restart. No Homebrew dependencies. Just drag, drop, and route.

---

## Build from source

**Requirements:** Xcode Command Line Tools (`xcode-select --install`), Python 3.10+

```bash
# 1. Build and install the HAL driver
cd driver
make
sudo make install && sudo make reload

# 2. Run the Python engine directly
cd engine
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python menu_bar_app.py
```

Build a standalone `.app` + DMG installer:

```bash
cd installer && ./build.sh
# Output: ~/Desktop/AudioRouterNow.dmg
```

> The HAL driver must be built first — run `make` in the `driver/` directory before running `build.sh`.

---

## Project structure

```
AudioRouterNow/
├── driver/                     ← HAL audio driver (C, Universal Binary)
│   └── src/AudioRouterNowDriver.c
├── engine/                     ← Python app
│   ├── menu_bar_app.py         ← Menu bar widget (rumps)
│   ├── routing_engine.py       ← Multi-output audio routing
│   ├── socket_receiver.py      ← Unix socket → PCM receiver
│   ├── device_manager.py       ← Device discovery + hot-plug
│   ├── config.py               ← Persistent config
│   ├── first_launch.py         ← Auto-installer (no Terminal)
│   └── cli.py                  ← CLI for testing
└── installer/                  ← PyInstaller + DMG build
    ├── build.sh
    └── AudioRouterNow.spec
```

---

## Support

AudioRouterNow is free and will stay free.  
If it saves you time, you can [buy me a coffee ☕](https://www.buymeacoffee.com/mauriciomorkun) — entirely optional.

---

## License

MIT License — see [LICENSE](LICENSE)
