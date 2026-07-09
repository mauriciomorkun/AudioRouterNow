# AudioRouterNow v4 — Architektur-Dokumentation

Stand: 2026-07-09 · Konzept 4B (MenuBar UI Redesign, Session 5)

## Übersicht

AudioRouterNow v4 ist der Swift/SwiftUI-Rewrite der macOS-Audio-Routing-App für
den App Store. Die App nimmt das System-Audio (Core Audio Process Tap) ab und
verteilt (Fan-out) es simultan auf mehrere Ausgabegeräte. v4 ersetzt die frühere
HAL-Plugin/C-Helper/Python-Architektur durch einen reinen Swift-Stack mit einem
Direct-IOProc auf einem Aggregate-Device.

Der Prozess läuft als `LSUIElement`-MenuBar-App (kein Dock-Icon). Die gesamte
Bedienung erfolgt über das Popover-Menü (`MenuBarExtra`/`MenuBarView`, 320 pt
Breite).

## Layer-Architektur (3 Layers)

```
┌─────────────────────────────────────────────────────────────┐
│  UI-Layer  (SwiftUI, @MainActor)                             │
│  MenuBarView · WaveHeaderView · DeviceCardView ·             │
│  RoutingControls · Theme (ARNUIState / ARNColor / ARNMath)   │
└───────────────▲─────────────────────────────────────────────┘
                │  @Published (Status, Peaks, Latenz, Volume)
┌───────────────┴─────────────────────────────────────────────┐
│  Controller-Layer  (EngineController, ObservableObject)      │
│  @MainActor-Wrapper · Polling (0,5 s) · Config-Persistenz ·  │
│  Warm-Restart-Orchestrierung · Login-Item · Auto-Start       │
└───────────────▲─────────────────────────────────────────────┘
                │  synchrone / async-Aufrufe (start/stop/updateOutputs)
┌───────────────┴─────────────────────────────────────────────┐
│  AudioRouterKit  (Swift Package, RT-Domäne + Core Audio)     │
│  FanOutEngine · PeakMeters · VolumeTracker ·                 │
│  DeviceLifecycleManager · DeviceLatency · OutputConfig       │
└─────────────────────────────────────────────────────────────┘
```

Strikte Abhängigkeitsrichtung: UI → Controller → Kit. Das Kit kennt weder
SwiftUI noch den Controller. Die App-Target-Schicht importiert `AudioRouterKit`.

## AudioRouterKit (Package)

Reine Audio- und Core-Audio-Domäne, plattformfrei von SwiftUI. Der Package-Code
enthält die einzige echtzeitkritische (RT) Codepassage der App: den IOProc.

### FanOutEngine

Zentrale Engine. Baut ein Aggregate-Device aus Sub-Devices, installiert einen
Process Tap als Input und schreibt in einem Direct-IOProc-Callback das
Tap-Signal in alle Output-Slots.

Wichtige Properties (public, aus `FanOutEngine.swift`):

| Property | Typ | Zweck |
|----------|-----|-------|
| `status` | `RouterStatus` | `.idle` / `.routing` / `.error(RouterError)` |
| `isSuspectedTCCDenied` | `Bool` | Heuristik: viele Callbacks, nur Stille → TCC/DRM |
| `totalCallbacks` | `Int` | IOProc-Callback-Zähler (Metrik) |
| `hasReceivedAudio` | `Bool` | Non-Silence seit Start empfangen |
| `currentVolumeScale` | `Float32` | Aktueller System-Volume-Multiplikator |
| `ioBufferFrames` | `Int` | IO-Buffer-Grösse des aktiven Aggregates |
| `slotDeviceKeys` | `[String]` | Slot-Identität `"<uid>:<channelOffset>"`, 1:1 mit Peak-Index |

Wichtige Methoden (public):

| Methode | Zweck |
|---------|-------|
| `start(outputs:) throws` | Aggregate + Tap + IOProc aufbauen, `AudioDeviceStart` |
| `updateOutputs(_:) async throws` | Warm-Restart: Slots neu, Tap bleibt (kein neuer TCC-Prompt) |
| `stop()` | IOProc stoppen, Tap + Aggregate abbauen, Peaks/Keys zurücksetzen |
| `setSystemVolume(_:)` | Lautstärke auf Default-Output schreiben |
| `peakLevel(slotIndex:) -> (l,r)` | Peak-Pegel eines Slots (Polling-sicher) |
| `availableOutputDevices()` | `static` — verfügbare Ausgabegeräte (uid/name/channelCount) |
| `deviceID(forUID:)` | `static` — UID → `AudioObjectID` |
| `currentDefaultOutputUID()` | `static` — aktuelles Default-Output-Gerät |

RT-relevante Details des IOProc (`ioProcImpl`, ab ca. Zeile 729):
- Tap-Quelle wird interleaved oder non-interleaved erkannt (Stereo/Mono).
- Ein einziger Source-Peak (post-Volume) wird pro Callback berechnet — eine
  O(n)-Passage über die Frames — und via `peaks.record(...)` publiziert.
- Anschliessend schreibt der Callback pro Slot direkt in `ioOutputData`.
- Keine Allokation, kein Lock ausser der `os_unfair_lock`-Sektion in `PeakMeters`.

### PeakMeters — RT-Safety-Pattern

`PeakMeters` (siehe `PeakMeters.swift`) ist die RT-sichere Brücke zwischen dem
IOProc-Thread (Single-Writer) und dem MainActor-Polling (Single-Reader).

RT-Safety-Vertrag:
- `storage` (`UnsafeMutableBufferPointer<Float32>`, `maxSlots * 2 = 32` Werte)
  wird EINMAL im `init` alloziert und erst im `deinit` — nach `AudioDeviceStop`,
  wenn der RT-Pfad ruht — freigegeben. Keine Allokation im Audio-Pfad.
- Jeder Zugriff (`record` / `level` / `reset`) ist genau eine
  `os_unfair_lock`-Sektion (< 100 ns), keine Blockierung, kein `malloc`.
- `@unchecked Sendable`: der geteilte Zustand ist ausschliesslich über `_lock`
  serialisiert.
- `record(l:r:slotCount:)` klemmt `slotCount` gegen `maxSlots` → kein Overrun.
- `level(slotIndex:)` liefert bei Out-of-range `(0, 0)`.
- `reset()` nullt alle Pegel (Silence-Callback ohne Delay, Stop, Teardown).

### DeviceLatency

`DeviceLatencyInfo` (struct, `Sendable`) bündelt `deviceFrames`, `safetyFrames`,
`streamFrames` und `sampleRate`; abgeleitet: `totalFrames`, `totalMilliseconds`,
`totalSeconds`, `fanOutLatencySeconds`. Die freie Funktion
`readDeviceLatency(deviceID:)` liest die Werte per Core-Audio-Property-Queries.
Der Controller befüllt daraus `deviceLatencies[uid]` bei Start und Warm-Restart.

### VolumeTracker

Beobachtet das Default-Output-Gerät und dessen Lautstärke-/Mute-Property
(`@unchecked Sendable`, os_unfair_lock-geschützter Volume-Scale). Der IOProc liest
`volumeScale` RT-sicher (< 100 ns) und multipliziert das Tap-Signal, damit der
Systemlautstärke-Regler weiter greift, obwohl das Signal über einen Tap läuft.
`setSystemVolume(_:)` schreibt zurück auf das Gerät.

### DeviceLifecycleManager

Überwacht Geräte-Ereignisse (Verschwinden/Erscheinen gerouteter Geräte, Wechsel
des Default-Outputs, coreaudiod-Neustart, Sample-Rate-Wechsel) über Core-Audio-
Listener auf einer seriellen Queue. Meldet über zwei Callbacks an den Controller:
`onNeedsRestart` (Full-Restart, debounced) und `onSampleRateChanged` (Warm-
Restart). Settle-Delays: HDMI 3 s, Bluetooth 2 s.

## App Target (AudioRouterNow4)

### EngineController

`@MainActor final class EngineController: ObservableObject` — der einzige
Berührungspunkt der UI mit der Engine. Spiegelt Engine-Status in `@Published`-
Properties, pollt Metriken/Peaks alle 0,5 s, persistiert die Output-Config und
orchestriert Warm-Restarts.

`@Published`-Properties (UI-Consumer):

| Property | Typ | Bedeutung |
|----------|-----|-----------|
| `status` | `RouterStatus` | Gespiegelter Engine-Status |
| `isStarting` | `Bool` | true zwischen `startRouting()` und Engine-Bestätigung → UI-STARTING |
| `isSuspectedTCCDenied` | `Bool` | TCC/DRM-Warnung anzeigen |
| `totalCallbacks` | `Int` | Callback-Zähler (Status-Bar) |
| `hasReceivedAudio` | `Bool` | Audio empfangen (Dot-Farbe/Text) |
| `currentVolume` | `Double` | Slider-Wert [0…1] |
| `isMuted` | `Bool` | Mute-Zustand (Icon/Label) |
| `deviceLatencies` | `[String: DeviceLatencyInfo]` | Latenz pro UID (Stats-Grid) |
| `bufferFrames` | `Int` | IO-Buffer-Grösse (Stats-Grid) |
| `peakLevels` | `[String: (l,r)]` | Peak pro Slot, Composite-Key (Signal-Meter) |
| `outputConfigs` | `[OutputConfig]` | Konfigurierte Ausgänge (Geräteliste) |
| `availableDevices` | `[(uid,name,channelCount)]` | Verfügbare Geräte (Add-Menü) |
| `launchAtLogin` | `Bool` | Login-Item-Toggle (SMAppService) |

Public Methoden (UI-Consumer):

| Methode | Zweck |
|---------|-------|
| `startRouting()` | STARTING-Frame setzen, dann `performStart()` im nächsten Tick |
| `stopRouting()` | Engine stoppen, alle Metriken/Peaks zurücksetzen |
| `addOutputConfig(_:)` / `removeOutputConfig(_:)` | Config ändern + Warm-Restart falls routing |
| `setSystemVolume(_:)` | Slider → System-Default-Output |
| `refreshAvailableDevices()` | Geräteliste neu einlesen (3-s-Task in der View) |
| `refreshLaunchAtLoginStatus()` | SMAppService-Status spiegeln ohne didSet-Seiteneffekt |
| `peak(for:) -> (l,r)?` | Peak einer Config (nil, wenn nicht geroutet) |
| `latency(for:) -> DeviceLatencyInfo?` | Latenz einer Config |
| `openTCCSettings()` | Systemeinstellungen (Audio-Recording) öffnen |

### UI-Layer — Datei-Übersicht

| Datei | Zweck |
|-------|-------|
| `UI/Theme.swift` | `ARNUIState` (State-Machine), `ARNColor` (Tokens), `ARNAudioMath` (dBFS) |
| `UI/WaveHeaderView.swift` | Animierter 3-Layer-Sinuswellen-Header (TimelineView + Canvas) |
| `UI/RoutingControls.swift` | `PulsingDot`, `MintSpinner`, `VolumeRow`, `RoutingButton`, `FooterRow` |
| `UI/DeviceCardView.swift` | Glass-Card mit Accordion, Kanal-Chips, `SignalMeter`, `StatsGrid`, `AddDeviceRow` |
| `MenuBarView.swift` | Container: Header · Status-Bar · TCC/Error · Volume · ScrollView-Geräteliste · Button · Footer |

Details siehe `UI/README.md`.

## UI-State-Machine (ARNUIState)

`ARNUIState` ist die Single Source of Truth des UI-Zustands, abgeleitet aus
`RouterStatus` + `isStarting`:

```
        startRouting()            engine.status == .routing
  idle ───────────────► starting ──────────────────────────► active
   ▲                       │                                    │
   │  stopRouting()        │ RouterError                        │ stopRouting()
   └───────────────────────┴───────────◄────────────────────── error ◄─┘
```

- STARTING hat Vorrang vor dem gespiegelten `status` (deshalb der `startRouting()`-
  Split, siehe unten).
- `waveIntensity`: 1.0 für `starting`/`active` (voller Wellen-Header), sonst 0.0
  (gedimmt) — koppelt Amplitude und Header-Gradient.
- `error(RouterError)` trägt Associated Value; Vergleiche wie `ui == .active`
  nutzen die synthetisierte `Equatable`-Konformanz (`RouterError` ist bereits
  `Equatable`).

## Datenfluss: IOProc → PeakMeters → poll() → SwiftUI

```
CoreAudio IOProc-Thread          MainActor                 SwiftUI
──────────────────────           ─────────                 ───────
Tap-Signal abtasten
  │ ein Source-Peak/Callback
  │ (post-Volume, O(n))
  ▼
peaks.record(l,r,slotCount) ──►  os_unfair_lock  ◄── EngineController.poll()  (alle 0,5 s)
                                                     │  engine.peakLevel(slotIndex:)
                                                     │  + UI-Release-Glättung (max(raw, prev*0.6))
                                                     ▼
                                              peakLevels[key]  (@Published)
                                                     │
                                                     ▼
                                        MenuBarView / DeviceCardView / SignalMeter
```

Die UI-seitige Release-Glättung (`max(raw, prev * 0.6)`) im `poll()` verhindert,
dass der Meter beim 500-ms-Polling flackert: Attack sofort, Release ~40 %/Tick.

## Wichtige Design-Entscheidungen

### Composite-Key für Peak-Dict
Der Peak-Key ist `"<uid>:<channelOffset>"`, nicht nur die UID. Mehrere
Output-Configs desselben Geräts (verschiedene Kanalpaare, z. B. Ch1-2 und Ch3-4)
würden sonst kollidieren. `slotDeviceKeys` in der Engine bildet denselben Key
1:1 zum Slot-Index. Zugriff nur über `EngineController.peak(for:)`.

### Ein Source-Peak (kein per-Slot-Peak)
Alle Slots teilen dieselbe Tap-Quelle — `channelOffset` selektiert nur den
Output-Kanal, verändert aber nicht das Quellsignal. Darum berechnet der IOProc
genau EINEN Source-Peak pro Callback und schreibt ihn (identisch) auf alle
`slotCount` Slots. Das hält die RT-Passage bei O(n) statt O(n·slots).

### startRouting()-Split für den STARTING-Frame
`startRouting()` setzt nur `isStarting = true` und plant `performStart()` im
nächsten MainActor-Tick. So rendert SwiftUI zuerst den STARTING-Frame (Spinner,
„Verbinde…"), bevor der blockierende, synchrone CoreAudio-Start läuft. Ohne den
Split bliebe die UI während des Aggregate-/Tap-Aufbaus im IDLE-Frame hängen.

### Kein per-Gerät-Slider (Phase 5 / F16)
Der Volume-Slider ist global (System-Default-Output). Eine per-Gerät-Lautstärke
erfordert einen N-Kanal-Umbau des IOProc (individuelle Gain-Stufen pro Slot) und
ist auf Phase 5 (F16) verschoben.

## Laufzeit-Tests vor Release

Der Peak-Metering-Einbau berührt den RT-Pfad — vor jedem Release-Build sind
folgende manuelle Prüfungen Pflicht (keine automatisierbaren Tests):

1. **RT-Safety / Audio-Glitch** — Routing starten, Musik abspielen: kein
   Knackser/Dropout nach dem Peak-Einbau. `record()` darf den IOProc nicht
   spürbar verlängern.
2. **Thread-Sanitizer (TSan)** — Product → Scheme → Diagnostics → Thread
   Sanitizer aktivieren, Routing starten/stoppen, Geräte an-/abstecken: keine
   Data-Race-Reports rund um `PeakMeters`/`VolumeTracker`.
3. **UI-States** — IDLE → Start → STARTING → ACTIVE → Expand → Stop vollständig
   durchklicken; Signal-Meter reagieren beim Abspielen.
4. **Xcode-Previews** — alle neuen Views (`WaveHeaderView` Idle/Active,
   `DeviceCardView`, `SignalMeter`, `RoutingButton`) im Canvas rendern.
</content>
