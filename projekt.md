# AudioRouterNow — Projektdokumentation

> Stand: 21.05.2026  
> Ziel: Eigenständiger, lizenzfreier Audio-Router für macOS — universell für alle Audio-Interfaces

---

## 1. Ausgangslage & Problem

**Hardware:** Native Instruments Komplete Audio 6 MK2  
**Problem:** macOS routet System-Audio standardmäßig nur zu Out 1/2. Die Outputs Out 3/4 bleiben stumm.  
**Ziel:** System-Audio gleichzeitig auf alle gewünschten Outputs routen — auf jedem Mac, ohne technische Vorkenntnisse.

---

## 2. Was bereits existiert (v1 — `~/audio-router/`)

Ein funktionierendes Python-Projekt, das dieses Problem löst — aber noch mit Abhängigkeit zu BlackHole.

### Dateien
| Datei | Inhalt |
|---|---|
| `audio_engine.py` | Core-Engine: routet BlackHole 2ch → Komplete Audio 6 Out 1/2 + Out 3/4 |
| `menu_bar_app.py` | macOS Menubar-Widget (rumps): Start/Stop, Channel-Toggle |
| `cli.py` | Terminal-Interface: `--list-devices`, `--no-12`, `--no-34` |
| `requirements.txt` | sounddevice, numpy, rumps, pyobjc |
| `.venv/` | Python 3.14 Virtual Environment |

### Desktop Launcher
- `~/Desktop/Audio Router.app` — Doppelklick startet das Menubar-Widget
- LSUIElement=true (kein Dock-Icon), Icon vom macOS Music.app

### Audio-Flow v1
```
macOS System Audio → BlackHole 2ch → AudioEngine (Python) → Komplete Audio 6
                                                              ├── Out 1/2 ✓
                                                              └── Out 3/4 ✓
```

### Abhängigkeiten v1
- **BlackHole 2ch** (ExistentialAudio) — GPL-3.0 Lizenz
- **SwitchAudioSource** — CLI Tool für macOS Audio-Umschaltung
- **Python 3.14** + Virtual Environment

---

## 3. Warum eine neue Version? (v2 — AudioRouterNow)

### Lizenzproblem
BlackHole ist **GPL-3.0** lizenziert:
- Private Nutzung: erlaubt
- Kommerzielle / closed-source Nutzung: **nicht erlaubt ohne Lizenz**
- Lösung: Eigenen virtuellen Audio-Treiber bauen → kein Fremdcode, keine Lizenzeinschränkungen

### UX-Problem (Installationsaufwand)
BlackHole ist eine Kernel Extension (kext):
- Manuelle Security-Genehmigung in macOS Systemeinstellungen nötig
- System-Neustart erforderlich
- Schlechte User Experience für einen Installer

---

## 4. Architektur v2 — AudioRouterNow

### Kernidee: Apple AudioServerPlugin statt Kernel Extension

Apple bietet seit macOS 10.14 (Mojave) eine offizielle User-Space-Alternative zu kexts:  
**AudioServerPlugin** — ein HAL (Hardware Abstraction Layer) Plugin.

| | BlackHole (kext) | AudioRouterNow (AudioServerPlugin) |
|---|---|---|
| Kernel Extension | Ja | **Nein** |
| Security-Genehmigung | Ja (manuell) | **Nein** |
| System-Neustart | Ja | **Nein** |
| Lizenz | GPL-3.0 | **100% eigen** |
| Alle Interfaces | Fix (nur Loopback) | **Konfigurierbar** |

### Komponenten

```
┌─────────────────────────────────────────────┐
│        AudioRouter.driver                   │
│   (Apple AudioServerPlugin — C/Swift)       │  ← Kein kext, kein Neustart
│   Installiert in /Library/Audio/Plug-Ins/HAL│
│   Erstellt "Audio Router" als virtuelle     │
│   Input/Output Device in Core Audio         │
└──────────────────┬──────────────────────────┘
                   │ IPC / Unix Socket
┌──────────────────▼──────────────────────────┐
│          Python Routing Engine              │
│   • Device Discovery (alle Interfaces)      │
│   • Channel Routing (konfigurierbar)        │
│   • Hot-plug Detection (Echtzeit)           │
│   • Sample Rate Matching                    │
└──────────────────┬──────────────────────────┘
                   │ Core Audio
        ┌──────────┴──────────────────┐
        ▼                             ▼
  Komplete Audio 6            Beliebige Andere
  (Out 1/2 + Out 3/4)         (USB, BT, HDMI, intern)
```

### Audio-Flow v2
```
macOS System Audio → AudioRouter Virtual Device → Python Engine → Jedes Interface
                     (unser eigener Treiber)                      (vom User wählbar)
```

---

## 5. Features v2

### Automatische Device-Erkennung
- Beim Start werden **alle** angeschlossenen Audio-Interfaces erkannt
- Kanalzahl (Inputs + Outputs) wird automatisch ausgelesen
- **Hot-plug**: USB-Interface einstecken → sofort in der Liste

### Universelle Interface-Unterstützung
Funktioniert mit allen Core Audio Devices:
- USB-Interfaces (Komplete Audio 6, Focusrite, SSL, etc.)
- Thunderbolt-Interfaces
- HDMI / DisplayPort Audio
- Bluetooth (AirPods, etc.)
- Internes MacBook Audio
- Virtuelle Devices (andere Driver)

### Menu Bar Widget (erweitert)
```
🎛️ Audio Router
──────────────────────────
INPUT (Quelle)
  ● Audio Router Virtual   ← System-Audio
  ○ Komplete Audio 6 In 1/2
  ○ MacBook Pro Mikrofon

OUTPUT (Ziele — mehrfach wählbar)
  ☑ Komplete Audio 6 — Out 1/2
  ☑ Komplete Audio 6 — Out 3/4
  ☐ MacBook Pro Lautsprecher
  ☐ AirPods Pro

Sample Rate: [48000 Hz ▼]
Buffer:      [512 ▼]
[▶ Routing starten]
```

### Installer / Verteilung
- Kein Terminal nötig
- Kein Neustart nötig
- Kein Security-Approval nötig
- **Ziel:** Doppelklick auf DMG → Fertig

---

## 6. Technologie-Stack

| Komponente | Technologie | Aufwand |
|---|---|---|
| HAL Plugin (Treiber) | C oder Swift | ~2 Tage |
| Routing Engine | Python (bestehend) | bereits fertig |
| Menu Bar Widget | Python + rumps (erweitert) | ~1 Tag |
| Device Discovery | Python + sounddevice | bereits fertig |
| Installer / DMG | PyInstaller + Shell | ~halber Tag |

---

## 7. Entscheidungen (festgelegt 21.05.2026)

| Entscheidung | Wahl | Begründung |
|---|---|---|
| **App-Name** | AudioRouterNow | Final, bleibt so |
| **Zielgruppe** | Professionell gebaut, zunächst privat | Kommerzialisierung offen gehalten |
| **macOS Mindest-Version** | macOS 11 (Big Sur) | Apple Silicon Support, AudioServerPlugin stabil, Python 3.10+ |
| **HAL Plugin Sprache** | Swift + C-Bridge | Moderner, Apple-native, besser wartbar |
| **IPC-Methode** | Unix Domain Socket | Zuverlässig, low-latency, gut für Swift↔Python |
| **Lizenzstrategie** | Proprietär (kein GPL-Code) | Kommerzialisierung jederzeit möglich |

### Implikationen der Entscheidungen

**macOS 11 (Big Sur) als Minimum:**
- Unterstützt Intel + Apple Silicon (Universal Binary nötig!)
- AudioServerPlugin voll unterstützt
- Python 3.10+ läuft problemlos
- Deckt ~95% aller aktiven Macs ab (Stand 2026)

**Professioneller Aufbau von Anfang an:**
- Code-Signierung (Apple Developer ID) — nötig für Gatekeeper-Kompatibilität
- Notarisierung durch Apple — damit Macs ohne "Unbekannter Entwickler"-Warnung
- Universal Binary (arm64 + x86_64) — läuft nativ auf Intel und Apple Silicon
- Semantic Versioning (v1.0.0, v1.1.0, …)
- Automatischer Update-Check (Sparkle Framework oder manuell)

> ⚠️ Apple Developer Program ($99/Jahr) nötig für Code-Signierung & Notarisierung.  
> **Entscheidung 21.05.2026:** Wird vorerst ignoriert. App läuft im Development-Modus auf eigenem Mac.  
> Code-Signierung & Notarisierung werden nachgeholt, wenn Vermarktung konkret wird.

---

## 8. Nächste Schritte (Roadmap)

### Phase 1 — Fundament (Treiber)
1. [x] HAL Plugin (AudioServerPlugin) in C implementieren — 1686 Zeilen ✅
2. [x] Unix Socket IPC zwischen Treiber und Python Engine ✅
3. [ ] Treiber in `/Library/Audio/Plug-Ins/HAL/` installieren & testen
4. [x] Universal Binary (arm64 + x86_64) kompiliert ✅

### Phase 2 — Engine & UI
5. [x] Python Routing Engine (socket_receiver.py + routing_engine.py) ✅
6. [x] Menu Bar Widget mit Device-Picker (menu_bar_app.py) ✅
7. [x] Hot-plug Detection — polling alle 2s (device_manager.py) ✅
8. [x] Channel-Mapping für N-Kanal Devices ✅
9. [x] Persistente Config (config.py → ~/.audiorouter/config.json) ✅
10. [x] CLI Interface (cli.py) ✅
11. [x] Natives System-Audio-Umschalten via osascript — kein SwitchAudioSource nötig ✅
12. [x] Donation-System (Buy Me a Coffee, einmaliger Hint) ✅

### Phase 3 — Distribution
13. [x] PyInstaller Spec (AudioRouterNow.spec) ✅
14. [x] build.sh — vollautomatischer Build → DMG ✅
15. [x] first_launch.py — Erststart-Installer ohne Terminal ✅
16. [x] GitHub README mit SEO-Texten ✅
17. [ ] Code-Signierung (Apple Developer ID) — später
18. [ ] Notarisierung (Apple Notarization) — später

### Phase 4 — Qualität (offen)
14. [ ] End-to-End Test: Treiber installieren + App starten
15. [ ] Testen auf macOS 11, 12, 13, 14, 15
16. [ ] Testen auf Intel Mac + Apple Silicon Mac
17. [ ] Testen mit verschiedenen Audio-Interfaces

---

## 9. Referenzen

- [Apple AudioServerPlugin Dokumentation](https://developer.apple.com/documentation/coreaudio)
- [BlackHole GitHub (Referenz-Implementierung)](https://github.com/ExistentialAudio/BlackHole)
- [sounddevice Python Library](https://python-sounddevice.readthedocs.io/)
- [rumps — macOS Menu Bar Framework](https://github.com/jaredks/rumps)
- Bestehendes Projekt: `~/audio-router/`
