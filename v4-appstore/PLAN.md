# AudioRouterNow v4.0 — App Store Edition
## Vollständiger Implementierungsplan (Process Taps Architektur)

**Stand:** 10. Juni 2026
**Status:** Planung / Vorab-Phase
**Basis:** v3.2.0 (HAL-Plugin-Architektur, nicht App-Store-fähig)

---

### 1. Warum v4.0 und warum Process Taps?

- **Aktuelle v3.x Architektur: HAL-Plugin → nicht App-Store-fähig.** Sechs strukturelle Blocker:
  1. HAL-Plugin muss nach `/Library/Audio/Plug-Ins/HAL/` installiert werden — außerhalb der Sandbox
  2. Installation erfordert Admin-Passwort
  3. `coreaudiod`-Restart nötig (`launchctl kickstart`) — privilegierte Operation
  4. C-Helper-Daemon läuft als separater Prozess außerhalb des App-Bundles
  5. Shared Memory (`shm_open`) + Unix Socket IPC — in der Sandbox stark eingeschränkt
  6. Python/py2app-Bundle mit eingebettetem Interpreter — Review-Risiko, kein Hardened-Runtime-Idiom
- **Process Taps (macOS 14.2+):** System-Audio ohne Treiber, ohne Admin, ohne Installer. Apple-offizielle API (`AudioHardwareCreateProcessTap`), eingeführt genau für diesen Use Case.
- **App Store → maximale Distribution:** Gatekeeper-frei, automatische Updates via OS, kein DMG-/Notarization-Flow für den Endnutzer, Sichtbarkeit im Store.
- **Zielgruppe:** macOS 14.2+ User — ab 2025 schätzungsweise 70–80 % der aktiven Macs (alle Geräte ab ca. 2018 können Sonoma). v3.x bleibt für ältere Systeme verfügbar.

---

### 2. Neue Architektur — Übersicht

```
┌─────────────────┐     ┌────────────────────────┐     ┌──────────────────────────────┐
│  System Audio   │ ──► │  Process Tap           │ ──► │  Swift App (sandboxed)       │
│  (alle Apps)    │     │  (CoreAudio,           │     │  ┌────────────────────────┐  │
└─────────────────┘     │   CATapDescription)    │     │  │ Ring Buffer + SRC      │  │
                        └────────────────────────┘     │  │ PI-Regler (Drift)      │  │
                                                       │  └───────────┬────────────┘  │
                                                       │              │ Fan-out       │
                                                       │   ┌──────────┼──────────┐    │
                                                       │   ▼          ▼          ▼    │
                                                       │ IOProc     IOProc     IOProc │
                                                       └───┼──────────┼──────────┼────┘
                                                           ▼          ▼          ▼
                                                    ┌──────────┐ ┌──────────┐ ┌──────────┐
                                                    │ Output 1 │ │ Output 2 │ │ Output N │
                                                    │ (z.B.    │ │ (z.B.    │ │          │
                                                    │ KA6 Ch1-2│ │ KA6 Ch3-4│ │ AirPods) │
                                                    └──────────┘ └──────────┘ └──────────┘
```

**Schichten:**
- Kein HAL-Plugin, kein C-Helper-Daemon, kein Installer, kein Admin-Passwort
- Alles in einer sandboxten Swift-App (SwiftUI `MenuBarExtra` + AppKit wo nötig)
- IPC: keiner nötig — alles im selben Prozess (Tap-Callback und Output-IOProcs teilen sich den Adressraum)
- Persistenz: `UserDefaults` (ggf. App Group, falls später Widgets/Extensions dazukommen)

---

### 3. Technische Komponenten

#### 3.1 System Audio Capture via Process Tap
- **APIs:** `CATapDescription` + `AudioHardwareCreateProcessTap` (CoreAudio, macOS 14.2+)
- **Varianten:**
  - *Process Tap:* gezielt einzelne Prozesse (z. B. nur Spotify) — Liste via `kAudioHardwarePropertyProcessObjectList`
  - *System Tap:* gesamtes System-Audio via `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` — das ist unser v3.x-Äquivalent
  - v4.0 startet mit System Tap; Per-App-Routing ist ein mögliches v4.1-Feature (USP gegenüber v3.x!)
- **TCC-Permission:** `NSAudioCaptureUsageDescription` in Info.plist ("AudioRouterNow benötigt Zugriff auf Systemaudio, um es an mehrere Ausgabegeräte weiterzuleiten."). Einmaliger System-Prompt beim ersten Start.
- **Sample-Rate-Handling:** Der Tap liefert das Audio im Format des Aggregats/Default-Device (native SR). Wir lesen das Format via `kAudioTapPropertyFormat`, folgen SR-Wechseln über Property-Listener und konvertieren bei Bedarf (siehe 3.3). Kein `coreaudiod`-Restart, kein Plugin-Reload — SR-Wechsel sind in v4.0 ein reines In-Process-Event.
- **Machbarkeit:** Hoch. Apple-Sample-Code und insidegui/AudioCap belegen den kompletten Pfad inkl. Sandbox.

#### 3.2 Multi-Output Fan-out
- **Option A — `AVAudioEngine` mit mehreren Engines:** Eine Engine pro Output-Device (eine Engine hat genau einen Output-Node). Einfacher Code, aber: pro Engine eigener Render-Thread, weniger Kontrolle über Puffergrößen/Latenz, und das Verteilen eines Tap-Streams auf N Engines erfordert ohnehin einen eigenen Ring-Buffer.
- **Option B — Direkte CoreAudio IOProcs pro physischem Output:** `AudioDeviceCreateIOProcID` pro Gerät, jeder IOProc liest aus einem eigenen SPSC-Ring-Buffer — exakt das heutige C-Helper-Modell, nur in Swift und im selben Prozess wie der Tap.
- **Empfehlung: Option B (native IOProcs).** Begründung:
  1. Die gesamte in v3.x gehärtete Logik (Ring-Buffer, Pre-Roll, PI-Regler, Underrun-Recovery, Tombstone-Slots) ist ein 1:1-Port — das Verhalten ist bekannt und über Monate produktionserprobt
  2. Volle Kontrolle über Channel-Offsets (Komplete Audio 6: Ch1-2 vs. Ch3-4 desselben Geräts) — mit AVAudioEngine nur umständlich erreichbar
  3. Deterministische Latenz und direktes Drift-Management pro Device-Clock
  4. Swift kann RT-sicher geschrieben werden (keine Allocations/Locks im IOProc; `UnsafeMutablePointer`-Ring, Atomics via `Atomics`-Package oder C-Shims)

#### 3.3 Sample Rate Conversion
- **`AVAudioConverter`** (oder Low-Level `AudioConverterRef`) für SR-Matching zwischen Tap-Format und Device-Format — nur aktiv wenn SRs differieren
- **PI-Regler für Clock-Drift** (wie heute): Port des bestehenden C-Codes nach Swift
  - ±500 ppm Stellbereich, EWMA-geglätteter Fill-Level als Regelgröße
  - Fractional-Resampler mit linearer Interpolation (heutiger `src_frac_ridx`-Mechanismus inkl. P16-Overflow-Fix und `frac_ridx_reset_gen`-Generation-Counter)
  - Der Algorithmus ist sprachunabhängig — Portierungsrisiko gering, Testbarkeit via Unit-Tests sogar besser als heute

#### 3.4 Menu Bar UI
- **SwiftUI `MenuBarExtra`** (macOS 13+, wir sind ohnehin auf 14.2+) — kein NSStatusItem-Boilerplate nötig; AppKit-Fallback nur falls Custom-Verhalten es erfordert
- **Funktionen (UX-Parität mit v3.x):**
  - Geräte-Auswahl (Multi-Checkbox, inkl. Channel-Paare bei Mehrkanal-Interfaces)
  - Volume-Slider + Mute pro Output und global
  - Sample-Rate-Anzeige
  - Health-Status (Ampel: grün/gelb/rot) — direkt aus In-Process-Telemetrie, kein SHM-Polling mehr
- **Persistenz:** `UserDefaults` (Geräte-Set, Volumes, Autostart-Flag); `SMAppService.mainApp` für Login-Item (sandbox-konform)

#### 3.5 Hot-Plug Device Management
- **CoreAudio Notification:** `kAudioHardwarePropertyDevices` Property-Listener auf dem System-Objekt
- **Keine Debounce-Kaskade nötig:** In v3.x musste Hot-Plug das HAL-Plugin-Verhalten (coreaudiod-Restart bei SR-Wechsel, BenQ-Dropout etc.) abfedern — `_pending_new_devices`-Karenz, Tombstone-Slots, Deferred-Unmap. In v4.0 ist ein Device-Wechsel nur: IOProc stoppen → zerstören → ggf. neu anlegen. Eine kleine Settle-Karenz (~500 ms) für USB-Enumeration bleibt sinnvoll, mehr nicht.

---

### 4. Wegfall-Analyse (was brauchen wir NICHT mehr)

**Entfällt komplett:**

| v3.x-Komponente | Umfang | Grund |
|---|---|---|
| `AudioRouterNow.driver` (HAL-Plugin) | gesamtes Plugin | Process Tap ersetzt virtuelles Device ✂️ |
| `AudioRouterNowHelper.c` | ~3.000 Zeilen C-Daemon | Logik wandert in-process nach Swift ✂️ |
| Shared Memory IPC (`shm_open`, 0660/fchown-Härtung) | — | kein zweiter Prozess ✂️ |
| Unix Socket + Auth-Token | — | kein IPC ✂️ |
| `installer/` (kompletter Installer-Flow) | — | App Store installiert ✂️ |
| `healer.py`, `health.py` (separater Monitor) | — | Telemetrie in-process ✂️ |
| `first_launch.py` | — | kein Setup-Flow nötig ✂️ |
| py2app/Python-Runtime im Bundle | — | reine Swift-App ✂️ |

**Bleibt / wird portiert:**

- PI-Regler-Logik → Swift (1:1-Port, unit-testbar)
- Device-Manager-Logik → Swift (cleaner: Property-Listener statt Polling, keine Pending-Karenz-Komplexität)
- UI-Konzept (Menu Bar, Geräte-Checkboxen, Ampel) → SwiftUI
- Diagnostic Report → deutlich einfacher, da alle Daten in einem Prozess liegen (kein SHM-Read, kein Socket-Roundtrip)

---

### 5. Implementierungsplan — Phasen

#### Phase 0: Entitlement + Apple Developer Setup (Woche 1)
- Apple Developer Portal: DriverKit-Entitlement? **NEIN bei Process Taps — nicht nötig!** Kein Antragsverfahren, keine Wartezeit.
- Standard-Entitlements für MAS: `com.apple.security.app-sandbox`, `com.apple.security.device.audio-input` (für den Tap-TCC-Pfad)
- `NSAudioCaptureUsageDescription` in Info.plist
- Neues Xcode-Projekt anlegen (Swift, Mac App Store Target, Hardened Runtime)
- **Ergebnis:** leeres, signierbares, sandboxtes App-Skelett

#### Phase 1: CoreAudio Process Tap Proof of Concept (Woche 1–2)
- Minimale Swift-App, die System-Audio via `CATapDescription` capturt
- Audio auf Default-Output weiterleiten (Loopback-Smoke-Test)
- TCC-Prompt verifizieren (erscheint, wird persistiert, Ablehnung erkennbar)
- **Testpunkt:** Kein Admin-Passwort, keine Installation nötig — App starten, Prompt bestätigen, Audio fließt

#### Phase 2: Multi-Output Fan-out (Woche 3–4)
- IOProc-Architektur mit SPSC-Ring pro Output (Option B aus 3.2)
- SR-Konversion zwischen Tap und Output
- Channel-Offset-Support (Mehrkanal-Interfaces)
- **Testpunkt:** Gleichzeitig auf Komplete Audio 6 MK2 Ch1-2 UND Ch3-4

#### Phase 3: PI-Regler + Clock-Drift-Kompensation (Woche 5)
- Port des bestehenden PI-Reglers aus C nach Swift
- ±500 ppm Range, EWMA Fill-Level, Pre-Roll (2048 Frames ≈ 43 ms @48 kHz)
- **Testpunkt:** 24 h Dauerbetrieb ohne Underruns

#### Phase 4: Menu Bar UI (Woche 6–7)
- SwiftUI `MenuBarExtra`
- Geräte-Selektion (Multi-Checkbox), Volume/Mute
- Sample-Rate-Anzeige, Health-Status (Ampel)
- UserDefaults-Persistenz + Login-Item
- **Testpunkt:** UX-Parität mit v3.x

#### Phase 5: Robustheit + Edge Cases (Woche 8)
- Hot-Plug während Wiedergabe (Add/Remove, Default-Device-Wechsel)
- `coreaudiod`-Restart-Recovery (Tap + IOProcs neu aufbauen)
- TCC-Permission verweigert → graceful degradation mit Hinweis + Deep-Link in Systemeinstellungen
- Underrun → Recovery (Pre-Roll-Reset, wie v3.x)
- **Testpunkt:** Kein Crash, kein Silent-Failure in allen Edge Cases

#### Phase 6: App Store Submission Vorbereitung (Woche 9–10)
- Privacy Manifest (`PrivacyInfo.xcprivacy`): Audio Capture Usage
- App Store Screenshots (5 Stück)
- App Description DE/EN
- App-Review-Notes: Begründung des System-Audio-Zugriffs explizit dokumentieren (Review-Risiko minimieren)
- **Testpunkt:** `notarytool` + `spctl`-Verifizierung, TestFlight-Build läuft auf sauberem System

---

### 6. Risiken und Abhängigkeiten

| Risiko | Einschätzung | Mitigation |
|---|---|---|
| macOS 14.2 Minimum — ~20–30 % der User ausgeschlossen | Mittel | v3.x bleibt als Direct-Download verfügbar; klare Kommunikation auf der Website |
| Process Tap TCC-Prompt: User muss explizit zustimmen (UX-Unterschied zu v3.x, das keinen Prompt hatte) | Gering | Onboarding-Screen erklärt den Prompt VOR dem Auslösen; Deep-Link bei Ablehnung |
| AVAudioEngine vs. IOProc | Entschieden | IOProc (Option B): mehr Kontrolle, bewährte v3.x-Logik, kein C mehr — siehe 3.2 |
| App Review: wenig Precedent für Audio-Apps mit Process Taps | Mittel | Privacy Manifest sauber, Review-Notes ausführlich, Demo-Video beilegen; AudioCap-artige Apps sind bereits im Store |
| Swift-RT-Sicherheit im IOProc (Allocations/ARC im Hot Path) | Mittel | Unsafe-Pointer-Ring, keine Klassen im Render-Pfad, Audit mit Instruments (RealtimeWatchdog) |
| Tap-Format-Wechsel zur Laufzeit (Default-Device-Wechsel) | Gering | Property-Listener + Converter-Rebuild, in Phase 5 explizit getestet |

---

### 7. Zeitschätzung

| Phase | Wochen | Aufwand |
|-------|--------|---------|
| 0: Setup | 0.5 | Gering |
| 1: PoC | 1.5 | Mittel |
| 2: Fan-out | 2 | Hoch |
| 3: PI-Regler | 1 | Mittel |
| 4: UI | 2 | Mittel |
| 5: Robustheit | 1 | Hoch |
| 6: App Store | 1.5 | Mittel |
| **Gesamt** | **~10 Wochen** | |

Annahme: Teilzeit-Entwicklung neben v3.x-Maintenance. Bei Vollzeit realistisch 6–7 Wochen.

---

### 8. Entwicklungsumgebung Setup

- Xcode 16+
- Swift 6.0 (Strict Concurrency — hilft bei RT-Thread-Disziplin)
- Target: macOS 14.2+
- Dependencies: Möglichst keine — CoreAudio, AVFoundation, SwiftUI, alles Apple-native. Einzige Kandidatin: `swift-atomics` für lock-freie Ring-Indizes (oder C-Shim mit `stdatomic.h`)
- Projekt-Layout-Vorschlag:
  ```
  v4-appstore/
  ├── PLAN.md                  (dieses Dokument)
  ├── README.md
  └── AudioRouterNow4/         (Xcode-Projekt, ab Phase 0)
      ├── App/                 (MenuBarExtra, Settings)
      ├── Engine/              (Tap, RingBuffer, PIController, OutputIOProc)
      └── Tests/               (PI-Regler Unit-Tests, Ring-Buffer-Tests)
  ```

---

### 9. Referenzen

- Apple Developer: "Capturing system audio with Core Audio taps" (Dokumentation + WWDC-Session)
- Apple Sample Code: AudioTapProcessor
- insidegui/AudioCap — Open-Source-Referenz-Implementierung (Process Taps, Sandbox, TCC)
- AudioDriverKit Documentation (für den Architektur-Vergleich / warum wir NICHT DriverKit nutzen)
- v3.x DOKUMENTATION.md — Kapitel zu PI-Regler, Ring-Buffer, Pre-Roll (Portierungs-Grundlage)

---

### 10. Nächste Schritte

1. [ ] Xcode-Projekt erstellen
2. [ ] `CATapDescription` Proof of Concept (Phase 1)
3. [ ] Apple Developer Portal prüfen, ob spezielle Entitlements nötig (erwartet: nein)
4. [ ] v3.x parallel weiterentwickeln, bis v4.0 Feature-Parität erreicht
