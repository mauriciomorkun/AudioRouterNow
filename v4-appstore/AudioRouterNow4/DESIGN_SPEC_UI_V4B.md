# DESIGN_SPEC_UI_V4B — MenuBar UI Redesign (Konzept 4B "Fusion Prominent Wave + Accordion Expand")

**Projekt:** AudioRouterNow v4 (App Store Edition, SwiftUI Menu-Bar-App)
**Erstellt:** 2026-07-09 · **Modell:** Opus (gem. Projektregel) · **Status:** Implementierungsreif
**Scope:** `MenuBarView.swift` (Rewrite) + `EngineController.swift` (Erweiterung) + `FanOutEngine.swift` (Peak-Metering) + 4 neue SwiftUI-Dateien

Diese Spec basiert auf der vollständigen Analyse der realen Codebase (Stand 2026-07-09). Alle Swift-Snippets sind syntaktisch vollständig und an die vorhandenen Typen/Signaturen angepasst.

---

## 0. Verifizierte Basis-Fakten (aus Code gelesen)

| Fakt | Quelle | Konsequenz für Design |
|------|--------|-----------------------|
| App ist `MenuBarExtra(...).menuBarExtraStyle(.window)`, LSUIElement | `AudioRouterNowApp.swift:29-34` | `TimelineView(.animation)` + `Canvas` animieren korrekt im Popover |
| `EngineController` ist `@MainActor final class ObservableObject`, per `@EnvironmentObject` injiziert | `EngineController.swift:17`, `MenuBarView.swift:15` | Neue `@Published` Properties genügen für UI-Reaktivität |
| `RouterStatus`: `.idle` / `.routing` / `.error(RouterError)`; hat `.isRouting`, `.isError` | `AudioRouterKit.swift:73-93` | UI-State wird aus `status` + neuem `isStarting` abgeleitet |
| `OutputConfig`: `uid: String`, `channelOffset: Int`, `channelCount: Int` (=2, im IOProc ungenutzt) | `OutputConfig.swift:17-35` | Chips aus `channelOffset..<channelOffset+channelCount` |
| Slots werden aus `resolvableOutputs` gebaut; `slots[i]` ↔ `resolvableOutputs[i]` in Reihenfolge | `FanOutEngine.swift:451-455`, `computeSlotLayouts:645-677` | slotIndex → Config-Key deterministisch abbildbar |
| Alle Slots teilen **dieselbe** Tap-Quelle L/R; `channelOffset` = Output-Kanal, nicht Quell-Selektion | `makeDirectIOBlock:745-907` | Ein Source-Peak/Callback ist für alle Slots akkurat |
| `deviceIDForUID(_:)` ist `private nonisolated static` | `FanOutEngine.swift:1158` | Muss public exponiert werden (Latenz-Abfrage im Controller) |
| `readDeviceLatency(deviceID:) -> DeviceLatencyInfo` ist bereits public (freie Funktion) | `DeviceLatency.swift:55` | Direkt aus Controller nutzbar |
| RT-Lock-Muster: `os_unfair_lock_s()` (< 100 ns Hold) | `VolumeTracker.swift:23-32` | Vorlage für `PeakMeters` |
| Mehrere Configs können dieselbe UID mit anderem `channelOffset` haben | `MenuBarView.swift:201-206` (KA6 Ch1-2/Ch3-4) | Peak-Dict-Key = `"uid:channelOffset"`, NICHT pure UID |
| `maxFramesPerCallback = 4096` | `FanOutEngine.swift:90` | Peak-Scan-Obergrenze |
| Warm-Restart-Pfade: `updateOutputs`, `restartRouting`, `warmRestartForSampleRateChange` | `EngineController.swift:151-318` | Latenz/Buffer-Refresh muss dort nachgezogen werden |

> **Design-Entscheidung (Confidence ~85%, dokumentiert):** Die vom Auftrag vorgegebene Signatur `peakLevels: [String: (l, r)]` wird beibehalten, aber der **Key ist der Composite `"\(uid):\(channelOffset)"`**, nicht die reine UID. Grund: Zwei Configs desselben Geräts (KA6 Ch1-2 + Ch3-4) würden bei UID-Key kollidieren und einen der beiden Meter unterdrücken. Der View liest über den Helper `controller.peak(for: config)`, sodass die Key-Konvention gekapselt bleibt.

---

## 1. Änderungsübersicht

| # | Datei | Art | Beschreibung | Risiko |
|---|-------|-----|--------------|--------|
| A1 | `AudioRouterKit/Sources/AudioRouterKit/FanOutEngine.swift` | Erweiterung | Neuer RT-sicherer `PeakMeters`-Typ; Capture im IOProc-Block; `slotDeviceKeys`, `ioBufferFrames`; public `deviceID(forUID:)`; `peakLevel(slotIndex:)`; Reset in Teardown | **M** (IOProc-Pfad) |
| A2 | `AudioRouterKit/Sources/AudioRouterKit/PeakMeters.swift` | **Neu** | Eigenständiger RT-sicherer Peak-Box-Typ (16 Slots, `os_unfair_lock`) | **L** |
| B1 | `AudioRouterNow4/EngineController.swift` | Erweiterung | 4 neue `@Published`; `performStart()`-Split für STARTING-State; `captureDeviceLatencies()`; `peak(for:)`; Reset/Refresh in stop + Warm-Restarts | **M** |
| C1 | `AudioRouterNow4/MenuBarView.swift` | **Rewrite** | Neuer Container: WaveHeader + Accordion-Device-List + State-Button + Footer | **M** |
| C2 | `AudioRouterNow4/UI/Theme.swift` | **Neu** | Color-Tokens, `ARNUIState`-Enum, dBFS-Helper | **L** |
| C3 | `AudioRouterNow4/UI/WaveHeaderView.swift` | **Neu** | `TimelineView`+`Canvas` 3-Layer-Sinuswelle, State-abhängiger Gradient | **L** |
| C4 | `AudioRouterNow4/UI/DeviceCardView.swift` | **Neu** | Glass-Card, Accordion, Chips, SignalMeter, StatsGrid, AddDeviceRow | **L** |
| C5 | `AudioRouterNow4/UI/RoutingControls.swift` | **Neu** | State-Button (Start/Verbinde/Stop) + FooterRow + PulsingDot + Spinner | **L** |

Keine destruktiven Operationen. Keine Secrets. Alle Änderungen abwärtskompatibel (bestehende Properties bleiben, neue sind additiv).

---

## 2. FanOutEngine — Peak-Metering Spec

### 2.1 Neuer Typ `PeakMeters` (neue Datei `PeakMeters.swift`)

RT-Muster identisch zu `VolumeTracker` (roher `os_unfair_lock_s`, single lock < 100 ns). Fixe Kapazität (kein RT-Alloc), vorab-allozierter Storage (wie die Scratch-Buffer in `DirectOutputSlot`).

```swift
//
//  PeakMeters.swift
//  AudioRouterKit
//
//  RT-sichere Peak-Level-Brücke: der Direct-IOProc schreibt pro Callback den
//  Source-Peak (post-Volume), der MainActor pollt ihn alle 500 ms.
//
//  Copyright 2026 Mauricio Moraïs da Cunha. Apache License 2.0.
//

import Foundation
import os

/// Peak-Pegel-Box (L/R pro Output-Slot). Single-Writer (IOProc-Thread),
/// Single-Reader (MainActor-Polling). RT-safe: eine `os_unfair_lock`-Sektion
/// pro Zugriff (< 100 ns), keine Allokation im Audio-Pfad.
///
/// - `@unchecked Sendable`: geteilter Zustand ausschliesslich über `_lock`
///   serialisiert; `storage` wird EINMAL bei `init` alloziert und erst im
///   `deinit` (nach `AudioDeviceStop`, RT-Pfad ruht) freigegeben.
final class PeakMeters: @unchecked Sendable {

    /// Harte Obergrenze der Output-Slots (= FanOutEngine-Fan-out-Limit).
    static let maxSlots = 16

    private var _lock = os_unfair_lock_s()
    /// Interleaved [l0, r0, l1, r1, …] mit `maxSlots * 2` Float32.
    private let storage: UnsafeMutableBufferPointer<Float32>

    init() {
        storage = UnsafeMutableBufferPointer<Float32>.allocate(capacity: Self.maxSlots * 2)
        storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    /// RT-Pfad: schreibt denselben (l, r)-Peak auf `slotCount` Slots und nullt
    /// den Rest. Aufruf NUR aus dem IOProc-Callback. `slotCount` wird gegen
    /// `maxSlots` geklemmt (RT-sicher, kein Overrun).
    func record(l: Float32, r: Float32, slotCount: Int) {
        let n = max(0, min(slotCount, Self.maxSlots))
        os_unfair_lock_lock(&_lock)
        for i in 0..<n {
            storage[i * 2]     = l
            storage[i * 2 + 1] = r
        }
        for i in n..<Self.maxSlots {
            storage[i * 2]     = 0
            storage[i * 2 + 1] = 0
        }
        os_unfair_lock_unlock(&_lock)
    }

    /// MainActor-Pfad: liest den Peak eines Slots. Out-of-range → (0, 0).
    func level(slotIndex: Int) -> (l: Float32, r: Float32) {
        guard slotIndex >= 0, slotIndex < Self.maxSlots else { return (0, 0) }
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return (storage[slotIndex * 2], storage[slotIndex * 2 + 1])
    }

    /// Setzt alle Pegel auf 0 (Silence-Callback ohne Delay, Stop, Teardown).
    func reset() {
        os_unfair_lock_lock(&_lock)
        storage.update(repeating: 0)
        os_unfair_lock_unlock(&_lock)
    }
}
```

### 2.2 FanOutEngine — neue Stored Properties & public API

Einfügen im `// MARK: State`-Block (nach `metrics`, `FanOutEngine.swift:129`):

```swift
    /// Realtime-sichere Peak-Pegel-Brücke (siehe ``PeakMeters``).
    private let peaks = PeakMeters()

    /// Slot-Identität pro Peak-Index: `slotDeviceKeys[i]` gehört zu `slots[i]`.
    /// Key-Format `"<uid>:<channelOffset>"` (Composite — mehrere Configs teilen
    /// evtl. dieselbe UID). Wird in ``buildAndStartAggregate`` gesetzt und in
    /// ``teardownAggregate`` geleert. Vom MainActor gelesen (Wert-Kopie).
    public private(set) var slotDeviceKeys: [String] = []

    /// IO-Buffer-Grösse (Frames pro Callback) des aktiven Aggregates.
    /// Wird nach erfolgreichem Start gesetzt (Fallback 512, falls unlesbar).
    public private(set) var ioBufferFrames: Int = 512
```

Public Lese-API (einfügen im `// MARK: Device-Discovery`-Bereich, z. B. nach `availableOutputDevices`, `FanOutEngine.swift:946`):

```swift
    /// Peak-Pegel eines Output-Slots [0.0 … 1.0 linear]. Polling-sicher.
    /// Index korrespondiert 1:1 mit ``slotDeviceKeys``.
    public func peakLevel(slotIndex: Int) -> (l: Float32, r: Float32) {
        peaks.level(slotIndex: slotIndex)
    }

    /// Public UID→AudioObjectID Auflösung für den Kontroll-Layer
    /// (Latenz-Abfrage). Flüchtig (AudioObjectID) — nur zum sofortigen Lesen.
    public nonisolated static func deviceID(forUID uid: String) -> AudioObjectID? {
        deviceIDForUID(uid)
    }
```

### 2.3 IOProc-Integration

**Signatur-Erweiterung** von `makeDirectIOBlock` (`FanOutEngine.swift:698-702`) — Parameter `peaks` ergänzen:

```swift
    private nonisolated static func makeDirectIOBlock(
        metrics: TapIOMetrics,
        slots: [DirectOutputSlot],
        volumeTracker: VolumeTracker?,
        peaks: PeakMeters
    ) -> AudioDeviceIOBlock {
```

**Aufruf** in `buildAndStartAggregate` (`FanOutEngine.swift:477`) anpassen:

```swift
        let directBlock = Self.makeDirectIOBlock(
            metrics: metrics, slots: slots, volumeTracker: volumeTracker, peaks: peaks
        )
```

**Slot-Keys + Buffer-Frames** setzen — in `buildAndStartAggregate` NACH `directOutputSlots = slots` (`FanOutEngine.swift:455`) und vor Schritt 4b:

```swift
        // Peak-Slot-Identität: 1:1 mit `slots` (computeSlotLayouts erhält die
        // Reihenfolge von resolvableOutputs). Für das UI-Peak-Mapping.
        slotDeviceKeys = resolvableOutputs.map { "\($0.uid):\($0.channelOffset)" }
```

Und am Ende von `buildAndStartAggregate`, unmittelbar vor `status = .routing` (`FanOutEngine.swift:492`):

```swift
        // IO-Buffer-Grösse für die UI-Statistik lesen (Fallback bleibt 512).
        ioBufferFrames = Self.bufferFrameSize(for: aggregateDeviceID) ?? ioBufferFrames
```

**Silence-Reset** im IOProc — die bestehende Early-Return-Guard (`FanOutEngine.swift:740-741`) erhält den Peak-Reset:

```swift
            // F2: Nur früh raus, wenn KEINE DelayLine zu leeren ist.
            guard (!isSilent || anySlotHasDelay), !slots.isEmpty, inputList.count >= 1
            else {
                if isSilent { peaks.reset() }   // UI-Meter auf 0 bei Stille
                return
            }
```

**Peak-Berechnung** — EINE O(n)-Passage. Einfügen NACH der Volume-Zeile `let vol: Float32 = ...` (`FanOutEngine.swift:786`) und VOR der `for slot in slots`-Schleife (`:789`). Begründung für die Position: `frameCount`, `vol` und das Tap-Format stehen hier fest; die Slot-Schleife bleibt unangetastet (kein Risiko für den Audio-Write-Pfad).

```swift
            // ── Peak-Metering (RT-safe, einzelne O(n)-Passage) ───────────
            // Alle Slots teilen dieselbe Tap-Quelle (channelOffset selektiert
            // nur den Output-Kanal) → ein Source-Peak ist für alle Slots gültig.
            var pkL: Float32 = 0
            var pkR: Float32 = 0
            if let intPtr = tapInterleavedPtr {
                let stride = tapInterleavedStride
                let rIdx = min(1, stride - 1)
                for i in 0..<frameCount {
                    let l = abs(intPtr[i * stride])
                    let r = abs(intPtr[i * stride + rIdx])
                    if l > pkL { pkL = l }
                    if r > pkR { pkR = r }
                }
            } else if let L = tapLeft {
                for i in 0..<frameCount {
                    let l = abs(L[i]); if l > pkL { pkL = l }
                }
                if let R = tapRight {
                    for i in 0..<frameCount { let r = abs(R[i]); if r > pkR { pkR = r } }
                } else {
                    pkR = pkL   // Mono → R spiegelt L
                }
            }
            peaks.record(l: pkL * vol, r: pkR * vol, slotCount: slots.count)
```

> `abs(_:)` auf `Float32` ist `Swift.abs` (kein Import nötig, keine Allokation, kein Branch-Overhead relevant).

### 2.4 Teardown / Reset

In `teardownAggregate` (`FanOutEngine.swift:511-534`) — nach `directOutputSlots = []` (`:527`) ergänzen:

```swift
        // Peak-Meter + Slot-Keys zurücksetzen (RT-Pfad ruht nach AudioDeviceStop).
        peaks.reset()
        slotDeviceKeys = []
        ioBufferFrames = 512
```

`teardownAggregate` wird von `teardownPartial` (stop) UND vom Warm-Restart aufgerufen — der Reset ist damit an beiden Pfaden abgedeckt. Beim Warm-Restart baut `buildAndStartAggregate` `slotDeviceKeys`/`ioBufferFrames` unmittelbar neu.

### 2.5 Buffer-Frame-Reader (neuer nonisolated static Helper)

Einfügen bei den Device-Property-Helpers (nach `nominalSampleRate`, `FanOutEngine.swift:1224`):

```swift
    /// Liest `kAudioDevicePropertyBufferFrameSize` (Output-Scope) des Aggregates.
    /// Nicht RT-safe — nur im Start-/Rebuild-Pfad aufrufen.
    private nonisolated static func bufferFrameSize(for deviceID: AudioObjectID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              value > 0 else { return nil }
        return Int(value)
    }
```

### 2.6 RT-Safety-Begründung

| Aspekt | Nachweis |
|--------|----------|
| Keine Allokation im IOProc | `peaks.record` schreibt in vorab-allozierten `storage`; kein Array-Literal, kein `malloc` |
| Kein `throw` | `record` ist non-throwing |
| Lock-Hold-Zeit | Ein `os_unfair_lock`-Zyklus über ≤ 32 Float-Stores (< 100 ns), identisch zum bereits akzeptierten `VolumeTracker`-Muster |
| Kein `self`-Capture | Der Block captured `peaks` per Wert (Referenz auf `@unchecked Sendable`-Box) — dieselbe Regel wie `metrics`/`volumeTracker`; die `nonisolated static` Factory bleibt erhalten (Crash-Regel `FanOutEngine.swift:683-693`) |
| Zusätzliche CPU | Genau EINE O(frameCount)-Passage (max 4096) pro Callback zusätzlich zum bestehenden O(frameCount·slots)-Write → vernachlässigbar |
| Priority Inversion | Single-Writer/Single-Reader; MainActor-Reader hält den Lock nur µs-kurz; `os_unfair_lock` ist für diese Asymmetrie geeignet (kein Park) |

### 2.7 Test-Kriterien (FanOutEngine)

1. **Unit (`PeakMeters`)**: `record(l:0.5,r:0.25,slotCount:3)` → `level(0)==(0.5,0.25)`, `level(2)==(0.5,0.25)`, `level(3)==(0,0)`, `level(15)==(0,0)`, `level(16)==(0,0)`.
2. **Unit**: `record(...,slotCount: 20)` klemmt auf 16, kein Crash/Overrun.
3. **Unit**: nach `reset()` sind alle Level `(0,0)`.
4. **Integration**: `slotDeviceKeys.count == directOutputSlots.count` nach `start` (nutze eine `#if DEBUG`-Testhilfe oder internes `@testable`-Zugriff).
5. **Manuell**: Audio abspielen → `peakLevel(0)` > 0; Pause → nach ≤ 1 Callback (bei Nicht-Delay-Slots) 0.
6. **Manuell (Regression)**: Kein Audio-Artefakt/Glitch nach Einbau (der Write-Pfad ist unverändert); Latenz-Kompensation (Delay-Pfad) unverändert.
7. **Thread-Sanitizer**: Kein Data-Race zwischen IOProc-`record` und MainActor-`level` (Lock deckt beide).

---

## 3. EngineController — Neue Properties Spec

### 3.1 Neue Published Properties

Einfügen nach `isMuted` (`EngineController.swift:32`):

```swift
    /// Output-Latenzen pro UID (befüllt bei Start / Warm-Restart).
    @Published private(set) var deviceLatencies: [String: DeviceLatencyInfo] = [:]

    /// IO-Buffer-Grösse (Frames) des aktiven Aggregates.
    @Published private(set) var bufferFrames: Int = 512

    /// Peak-Pegel pro Output-Slot. Key = `"<uid>:<channelOffset>"` (Composite —
    /// mehrere Configs desselben Geräts kollidieren sonst). Über ``peak(for:)``
    /// lesen, statt den Key manuell zu bilden.
    @Published private(set) var peakLevels: [String: (l: Float32, r: Float32)] = [:]

    /// `true` zwischen `startRouting()`-Aufruf und Engine-Bestätigung
    /// (UI-State „Verbinde Geräte…").
    @Published private(set) var isStarting: Bool = false
```

> `DeviceLatencyInfo` ist `public Sendable` (aus `AudioRouterKit`) — als Dictionary-Value nutzbar. `import AudioRouterKit` ist bereits vorhanden (`EngineController.swift:12`).

### 3.2 STARTING-State: `startRouting()`-Split

Der bestehende `startRouting()` (`EngineController.swift:101-120`) ruft `engine.start()` **synchron** auf dem MainActor. Damit SwiftUI zuerst den STARTING-Frame rendert, wird der Aufruf um einen Runloop-Tick verzögert. Ersetze `startRouting()` durch:

```swift
    func startRouting() {
        guard status != .routing, !isStarting else { return }
        isStarting = true
        // Nächster MainActor-Tick: SwiftUI rendert erst den STARTING-Frame,
        // dann folgt der (blockierende) CoreAudio-Start.
        Task { @MainActor [weak self] in
            guard let self, self.isStarting else { return }
            self.performStart()
        }
    }

    private func performStart() {
        defer { isStarting = false }
        do {
            try engine.start(outputs: outputConfigs)
            status = engine.status
            if status == .routing {
                bufferFrames = engine.ioBufferFrames          // neu
                captureDeviceLatencies()                       // neu
                startPolling()      // F10
                startLifecycle()    // F4
                UserDefaults.standard.set(true, forKey: Self.wasRoutingKey)
            }
        } catch let e as RouterError {
            logger.error("startRouting: RouterError: \(e.localizedDescription, privacy: .public)")
            status = .error(e)
        } catch {
            logger.error("startRouting: unerwarteter Fehler: \(String(describing: error), privacy: .public)")
            status = .error(.tapFailed(status: -1))
        }
    }
```

> **Hinweis:** Der blockierende `AudioDeviceStart` (TCC-Prompt, Aggregate-Build) läuft weiterhin auf dem MainActor — das ist unverändert zur Ist-Situation und akzeptiert (Popover ist ohnehin modal). Der einzige Zweck des `Task`-Ticks ist, dass der `isStarting=true`-Frame gerendert wird, bevor der blockierende Aufruf startet.

### 3.3 UID→AudioObjectID Mapping (`captureDeviceLatencies`)

Neue private Methode (einfügen nach `performStart`):

```swift
    /// Liest Output-Latenzen für alle konfigurierten Geräte (dedupliziert per UID).
    /// Nutzt die public UID→AudioObjectID-Auflösung der Engine + `readDeviceLatency`.
    private func captureDeviceLatencies() {
        var result: [String: DeviceLatencyInfo] = [:]
        for config in outputConfigs {
            guard result[config.uid] == nil,
                  let deviceID = FanOutEngine.deviceID(forUID: config.uid)
            else { continue }   // Gerät nicht (mehr) verbunden → überspringen
            result[config.uid] = readDeviceLatency(deviceID: deviceID)
        }
        deviceLatencies = result
    }
```

**Fehlerfall UID nicht auflösbar:** `deviceID(forUID:)` → `nil` → Eintrag fehlt im Dict → View zeigt für dieses Gerät „–" statt Latenz (siehe §4.7). Kein Crash, kein Force-Unwrap.

### 3.4 Peak-Polling (`poll()`-Erweiterung)

Erweitere `poll()` (`EngineController.swift:170-178`) — am Ende ergänzen:

```swift
        // Peak-Level pro Slot lesen + UI-seitige Release-Glättung (Attack sofort,
        // Release ~40 %/Tick), damit der Meter bei 500 ms-Polling nicht flackert.
        var newPeaks: [String: (l: Float32, r: Float32)] = [:]
        for (i, key) in engine.slotDeviceKeys.enumerated() {
            let raw = engine.peakLevel(slotIndex: i)
            let prev = peakLevels[key] ?? (l: 0, r: 0)
            newPeaks[key] = (
                l: max(raw.l, prev.l * 0.6),
                r: max(raw.r, prev.r * 0.6)
            )
        }
        peakLevels = newPeaks
```

### 3.5 Peak-Lookup-Helper (public)

Kapselt die Composite-Key-Konvention. Einfügen im public-Methoden-Bereich (z. B. nach `refreshAvailableDevices`, `EngineController.swift:187`):

```swift
    /// Peak-Pegel für eine Output-Config [0.0 … 1.0 linear]. `nil`, wenn das
    /// Gerät gerade nicht aktiv geroutet wird (kein Slot vorhanden).
    func peak(for config: OutputConfig) -> (l: Float32, r: Float32)? {
        peakLevels["\(config.uid):\(config.channelOffset)"]
    }

    /// Latenz-Info für eine Output-Config (oder `nil`, wenn nicht verfügbar).
    func latency(for config: OutputConfig) -> DeviceLatencyInfo? {
        deviceLatencies[config.uid]
    }
```

### 3.6 Reset bei Stop

In `stopRouting()` (`EngineController.swift:122-134`) — nach `isMuted = false` (`:131`) ergänzen:

```swift
        deviceLatencies = [:]
        peakLevels = [:]
        bufferFrames = 512
        isStarting = false
```

### 3.7 Refresh bei Warm-Restart

Nach erfolgreichem `updateOutputs` in **`applyOutputsIfRouting`** (`EngineController.swift:229-234`, im `do`-Block nach `self.startLifecycle()`) ergänzen:

```swift
                self.bufferFrames = self.engine.ioBufferFrames
                self.captureDeviceLatencies()
```

Analog in **`warmRestartForSampleRateChange`** (`EngineController.swift:310-312`, nach `self.status = self.engine.status`):

```swift
                self.bufferFrames = self.engine.ioBufferFrames
                self.captureDeviceLatencies()
```

Und in **`restartRouting`** (`EngineController.swift:158-159`, nach `status = engine.status` im `do`-Block):

```swift
            bufferFrames = engine.ioBufferFrames
            captureDeviceLatencies()
```

### 3.8 Backward-Compatibility Checks

| Prüfung | Erwartung |
|---------|-----------|
| Bestehende Properties (`status`, `outputConfigs`, `currentVolume`, …) unverändert | ✅ additiv |
| `startRouting()` Verhalten bei Fehler | Identisch — `performStart` übernimmt denselben catch-Baum |
| Auto-Start (`autoStartIfNeeded` → `startRouting`) | Funktioniert weiter; `isStarting`-Gate verhindert Doppelstart |
| `poll()` bei `status != .routing` | Früher `return` unverändert (`:171`) → keine Peak-Reads im Idle |
| Kein `weak`/Retain-Cycle | `Task { @MainActor [weak self] }` im Start-Tick |

---

## 4. MenuBarView — Vollständige View-Hierarchie Spec

### 4.0 Struktur & globale Parameter

```
MenuBarView (Container, width 320)
├── WaveHeaderView(state:)                       ← C3
├── StatusBar(state:, deviceCount:)              ← inline in MenuBarView
├── [TCC-Warnung]  (unverändert übernommen)      ← inline
├── [Fehler]       (unverändert übernommen)      ← inline
├── VolumeRow (nur ACTIVE)                        ← inline (aus altem volumeSection)
├── DeviceListSection                             ← C4
│   ├── ForEach(outputConfigs) → DeviceCardView(state:, config:)
│   │   └── (ACTIVE & expanded) ExpandedDeviceDetail
│   │        ├── ChannelChipsRow
│   │        ├── SignalMeter (L) + SignalMeter (R)
│   │        └── StatsGrid (Latenz · Puffer · Rate)
│   └── AddDeviceRow (Menu)
├── RoutingButton(state:)                         ← C5
└── FooterRow (LaunchAtLogin · Quit)              ← C5
```

- **Gesamtbreite:** `320` (statt 300 — die Accordion-Detailzeilen brauchen mehr Raum).
- **UI-State-Ableitung** (Single Source of Truth, in `Theme.swift`):

```swift
enum ARNUIState: Equatable {
    case idle, starting, active, error(RouterError)

    init(status: RouterStatus, isStarting: Bool) {
        if isStarting { self = .starting; return }
        switch status {
        case .idle:            self = .idle
        case .routing:         self = .active
        case .error(let e):    self = .error(e)
        }
    }

    var isActive: Bool   { self == .active }
    var isStarting: Bool { self == .starting }
    /// Wellen-/Header-Intensität: 0 = gedimmt (idle/error), 1 = voll (starting/active).
    var waveIntensity: Double {
        switch self { case .active, .starting: return 1.0; default: return 0.0 }
    }
}
```

Im View: `let ui = ARNUIState(status: controller.status, isStarting: controller.isStarting)`.

### 4.1 Color-Tokens (`Theme.swift`)

```swift
import SwiftUI

enum ARNColor {
    /// --accent  #40DCA5
    static let accent      = Color(red: 0.251, green: 0.863, blue: 0.647)
    /// Gedimmter, kühler Dunkelgrün-Tint für den IDLE-Header.
    static let accentDim   = Color(red: 0.157, green: 0.310, blue: 0.267)

    /// Header-Gradient VOLL (starting/active).
    static let headerTop   = Color(red: 0.055, green: 0.157, blue: 0.133)
    static let headerBottom = Color(red: 0.020, green: 0.078, blue: 0.067)
    /// Header-Gradient GEDIMMT (idle/error).
    static let headerTopDim    = Color(red: 0.086, green: 0.098, blue: 0.098)
    static let headerBottomDim = Color(red: 0.043, green: 0.051, blue: 0.051)

    /// Glass-Card-Fill (über .ultraThinMaterial gelegt).
    static let cardStroke   = Color.white.opacity(0.08)
    static let cardStrokeActive = accent.opacity(0.35)

    static let statusDotIdle = Color(white: 0.55)
    static let meterTrack    = Color.white.opacity(0.10)
}
```

### 4.2 dBFS-Helper (`Theme.swift`)

```swift
import Foundation

enum ARNAudioMath {
    /// Linearer Peak [0…1] → dBFS, geklemmt auf [floorDB … 0].
    static func dbfs(_ linear: Float32, floorDB: Double = -60) -> Double {
        let v = Double(linear)
        guard v > 1e-7 else { return floorDB }
        return max(floorDB, min(0, 20 * log10(v)))
    }

    /// dBFS → Meter-Füllgrad [0…1] relativ zum floorDB.
    static func meterFraction(_ linear: Float32, floorDB: Double = -60) -> Double {
        let db = dbfs(linear, floorDB: floorDB)
        return (db - floorDB) / (0 - floorDB)   // floorDB→0, 0dB→1
    }
}
```

### 4.3 WaveHeaderView (`WaveHeaderView.swift`)

- **Technologie:** `TimelineView(.animation)` liefert `context.date`; `Canvas` zeichnet 3 Sinus-Layer. Phase-Offset aus `date.timeIntervalSinceReferenceDate`.
- **Parameter:** Amplitude 10 pt (Layer 1), Wellenlänge ~200 pt, Speed ~0.3 rad/s (Layer 1); Layer 2/3 kürzer/schneller/transparenter.
- **State-Kopplung:** `intensity` (0…1) skaliert Amplitude + Farbdeckkraft; `pulsing` steuert den Status-Dot (in StatusBar, nicht hier).

```swift
//  WaveHeaderView.swift — AudioRouterNow4
import SwiftUI

struct WaveHeaderView: View {
    let state: ARNUIState

    private var intensity: Double { state.waveIntensity }

    // (Amplitude pt, Wellenlänge pt, Speed rad/s, Deckkraft)
    private let layers: [(amp: Double, len: Double, speed: Double, opacity: Double)] = [
        (10, 200, 0.30, 0.90),
        (7,  150, 0.45, 0.50),
        (5,  110, 0.65, 0.30),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let midY = size.height * 0.62
                for layer in layers {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: midY))
                    var x: CGFloat = 0
                    let step: CGFloat = 2
                    while x <= size.width {
                        let phase = (Double(x) / layer.len) * 2 * .pi + t * layer.speed
                        let y = midY + sin(phase) * layer.amp * max(0.08, intensity)
                        path.addLine(to: CGPoint(x: x, y: y))
                        x += step
                    }
                    let tint = (intensity > 0.5 ? ARNColor.accent : ARNColor.accentDim)
                        .opacity(layer.opacity * (0.35 + 0.65 * intensity))
                    ctx.stroke(path, with: .color(tint), lineWidth: 1.5)
                }
            }
            .drawingGroup()   // Metal-Compositing für ruckelfreie Kurve
        }
        .frame(height: 112)
        .background(headerGradient)
        .overlay(alignment: .topLeading) { titleOverlay }
        .animation(.easeInOut(duration: 0.4), value: intensity)
    }

    private var headerGradient: LinearGradient {
        let hot = intensity > 0.5
        return LinearGradient(
            colors: [hot ? ARNColor.headerTop : ARNColor.headerTopDim,
                     hot ? ARNColor.headerBottom : ARNColor.headerBottomDim],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var titleOverlay: some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .foregroundStyle(intensity > 0.5 ? ARNColor.accent : Color.secondary)
            Text("AudioRouterNow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }
}
```

> **Performance-Hinweis:** `.drawingGroup()` rendert das `Canvas` via Metal, sodass die 60-Hz-`TimelineView(.animation)` auf dem kleinen Popover CPU-schonend bleibt. Bei IDLE (intensity 0.08) bleibt die Welle nahezu flach → visuell „ruhend", die TimelineView läuft weiter (akzeptabel; alternativ §8 M2).

### 4.4 StatusBar (inline in MenuBarView)

```swift
private func statusBar(_ ui: ARNUIState) -> some View {
    HStack(spacing: 7) {
        PulsingDot(color: dotColor(ui), pulsing: ui == .active || ui == .starting)
        Text(statusText(ui))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        Spacer()
        if ui == .active {
            Text("CBs \(controller.totalCallbacks)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
}

private func dotColor(_ ui: ARNUIState) -> Color {
    switch ui {
    case .idle:     return ARNColor.statusDotIdle
    case .starting: return ARNColor.accent
    case .active:   return controller.hasReceivedAudio ? ARNColor.accent : .yellow
    case .error:    return .red
    }
}

private func statusText(_ ui: ARNUIState) -> String {
    switch ui {
    case .idle:     return "Kein Routing aktiv"
    case .starting: return "Verbinde Geräte…"
    case .active:
        let n = controller.outputConfigs.count
        return controller.hasReceivedAudio
            ? "Routing → \(n) Gerät\(n == 1 ? "" : "e")"
            : "Warte auf Audio…"
    case .error:    return "Fehler"
    }
}
```

### 4.5 PulsingDot & Spinner (`RoutingControls.swift`)

```swift
struct PulsingDot: View {
    let color: Color
    var pulsing: Bool
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(pulsing && animate ? 1.35 : 1.0)
            .opacity(pulsing && animate ? 0.55 : 1.0)
            .animation(pulsing
                ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                : .default, value: animate)
            .onAppear { animate = true }
            .onChange(of: pulsing) { _, newValue in animate = newValue }
    }
}

/// Kleiner mint-getönter Spinner für die STARTING-Geräteliste.
struct MintSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(ARNColor.accent)
            .scaleEffect(0.7)
            .frame(width: 12, height: 12)
    }
}
```

### 4.6 DeviceCardView + Accordion (`DeviceCardView.swift`)

- **State:** lokales `@State private var expanded` (nur ACTIVE relevant). Karte ist nur im ACTIVE-State klickbar.
- **IDLE:** Checkbox links (`checked` = Gerät ist in `outputConfigs`), Slider pre-settable (globaler Volume-Slider; per-Gerät-Volume ist Phase 5 — hier Platzhalter/entfällt, siehe Hinweis).
- **STARTING:** Karte `opacity 0.55`, `MintSpinner` statt Dot, nicht klickbar.
- **ACTIVE:** Dot (mint bei Signal) + Chevron; Klick toggelt `expanded` mit Spring.

> **Präzisierung zum IDLE-Slider:** Der Auftrag nennt „Slider pre-settable" pro Gerät. Da `OutputConfig` KEIN per-Gerät-Volume trägt und der IOProc nur einen globalen `vol` kennt (`FanOutEngine.swift:786`), gibt es aktuell keine per-Gerät-Lautstärke. **Entscheidung:** Im IDLE-State zeigt die Karte KEINEN per-Gerät-Slider (das wäre toter State). Der globale Volume-Slider erscheint wie bisher nur im ACTIVE-State (`VolumeRow`). Ein per-Gerät-Slider ist als Phase-5-Erweiterung (F16, N-Kanal-Umbau) markiert — hier NICHT implementiert, um keinen nicht-funktionalen Regler zu zeigen.

```swift
struct DeviceCardView: View {
    @EnvironmentObject var controller: EngineController
    let state: ARNUIState
    let config: OutputConfig
    @State private var expanded = false

    private var deviceName: String {
        controller.availableDevices.first { $0.uid == config.uid }?.name
            ?? String(config.uid.prefix(24))
    }
    private var isAvailable: Bool {
        controller.availableDevices.contains { $0.uid == config.uid }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if state.isActive, expanded {
                ExpandedDeviceDetail(config: config)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity))
            }
        }
        .padding(10)
        .background(cardBackground)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(strokeColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .opacity(state.isStarting ? 0.55 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard state.isActive else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                expanded.toggle()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            leadingIndicator
            Text(deviceName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isAvailable ? .primary : .tertiary)
            if config.channelOffset > 0 {
                Text("Ch\(config.channelOffset + 1)-\(config.channelOffset + 2)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            if state.isActive {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            removeButton
        }
    }

    @ViewBuilder private var leadingIndicator: some View {
        switch state {
        case .idle, .error:
            Image(systemName: "checkmark.square.fill")   // in outputConfigs = checked
                .foregroundStyle(ARNColor.accent)
                .font(.system(size: 13))
        case .starting:
            MintSpinner()
        case .active:
            Circle()
                .fill(signalColor)
                .frame(width: 8, height: 8)
        }
    }

    private var signalColor: Color {
        guard isAvailable, let p = controller.peak(for: config) else {
            return Color.secondary.opacity(0.35)
        }
        return (p.l + p.r) > 0.001 ? ARNColor.accent : Color.secondary.opacity(0.5)
    }

    private var removeButton: some View {
        Button { controller.removeOutputConfig(config) } label: {
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var strokeColor: Color {
        state.isActive && expanded ? ARNColor.cardStrokeActive : ARNColor.cardStroke
    }
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial)
    }
}
```

### 4.7 ExpandedDeviceDetail — Chips + Meter + Stats (`DeviceCardView.swift`)

```swift
struct ExpandedDeviceDetail: View {
    @EnvironmentObject var controller: EngineController
    let config: OutputConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.top, 8)
            ChannelChipsRow(config: config)
            signalMeters
            StatsGrid(config: config)
        }
        .padding(.top, 2)
    }

    private var peak: (l: Float32, r: Float32) { controller.peak(for: config) ?? (0, 0) }

    private var signalMeters: some View {
        VStack(spacing: 5) {
            SignalMeter(label: "L", linear: peak.l)
            SignalMeter(label: "R", linear: peak.r)
        }
    }
}

/// Kanalpaar-Chips aus channelOffset + channelCount.
struct ChannelChipsRow: View {
    let config: OutputConfig
    /// Standard-Kanalnamen (WAVE-Reihenfolge): L, R, C, LFE, Ls, Rs, …
    private static let names = ["L", "R", "C", "LFE", "Ls", "Rs", "Lb", "Rb"]

    private var labels: [String] {
        let start = config.channelOffset
        let count = max(1, config.channelCount)
        return (start..<start + count).map { i in
            i < Self.names.count ? Self.names[i] : "Ch\(i + 1)"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels, id: \.self) { name in
                Text(name)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(ARNColor.accent.opacity(0.18)))
                    .foregroundStyle(ARNColor.accent)
            }
            Spacer()
        }
    }
}

/// Ein Signal-Balken (L oder R) mit dBFS-Wert.
struct SignalMeter: View {
    let label: String
    let linear: Float32

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 12)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ARNColor.meterTrack)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [ARNColor.accent.opacity(0.7), ARNColor.accent],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * ARNAudioMath.meterFraction(linear))
                        .animation(.linear(duration: 0.12), value: linear)
                }
            }
            .frame(height: 6)
            Text(dbLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary).frame(width: 42, alignment: .trailing)
        }
    }

    private var dbLabel: String {
        let db = ARNAudioMath.dbfs(linear)
        return db <= -60 ? "−∞" : String(format: "%.0f dB", db)
    }
}

/// Latenz · Puffer · Rate.
struct StatsGrid: View {
    @EnvironmentObject var controller: EngineController
    let config: OutputConfig

    private var latency: DeviceLatencyInfo? { controller.latency(for: config) }

    var body: some View {
        HStack(spacing: 0) {
            stat("Latenz", latency.map { String(format: "%.1f ms", $0.totalMilliseconds) } ?? "–")
            divider
            stat("Puffer", "\(controller.bufferFrames)")
            divider
            stat("Rate", latency.map { String(format: "%.1f kHz", $0.sampleRate / 1000) } ?? "–")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 11, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 20)
    }
}
```

### 4.8 AddDeviceRow (`DeviceCardView.swift`)

Übernimmt die bestehende Add-Menu-Logik (`MenuBarView.swift:192-215`) 1:1, nur visuell als volle Zeile:

```swift
struct AddDeviceRow: View {
    @EnvironmentObject var controller: EngineController

    var body: some View {
        Menu {
            ForEach(controller.availableDevices, id: \.uid) { device in
                let pairCount = max(1, device.channelCount / 2)
                if pairCount == 1 {
                    Button(device.name) {
                        controller.addOutputConfig(OutputConfig(uid: device.uid, channelOffset: 0))
                    }
                } else {
                    ForEach(0..<pairCount, id: \.self) { pair in
                        let offset = pair * 2
                        Button("\(device.name) (Ch\(offset + 1)-\(offset + 2))") {
                            controller.addOutputConfig(OutputConfig(uid: device.uid, channelOffset: offset))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(ARNColor.accent)
                Text("Gerät hinzufügen").font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.white.opacity(0.12)))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }
}
```

### 4.9 RoutingButton (`RoutingControls.swift`)

Drei visuelle Zustände; `disabled`-Logik erhält die bestehende Regel (`outputConfigs.isEmpty && !routing`).

```swift
struct RoutingButton: View {
    @EnvironmentObject var controller: EngineController
    let state: ARNUIState

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func action() {
        switch state {
        case .active:               controller.stopRouting()
        case .idle, .error:         controller.startRouting()
        case .starting:             break
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .idle, .error: Image(systemName: "play.fill")
        case .starting:     MintSpinner()
        case .active:       Image(systemName: "stop.fill")
        }
    }
    private var title: String {
        switch state {
        case .idle, .error: return "Routing starten"
        case .starting:     return "Verbinde…"
        case .active:       return "Stop Routing"
        }
    }
    private var disabled: Bool {
        state == .starting || (controller.outputConfigs.isEmpty && !state.isActive)
    }
    private var background: AnyShapeStyle {
        switch state {
        case .idle, .error: return AnyShapeStyle(ARNColor.accent)
        case .starting:     return AnyShapeStyle(.ultraThinMaterial)
        case .active:       return AnyShapeStyle(Color(white: 0.12))
        }
    }
    private var foreground: Color { state == .idle || state == .error ? .black : ARNColor.accent }
    private var borderColor: Color { state == .active ? ARNColor.accent.opacity(0.6) : .clear }
}
```

### 4.10 FooterRow (`RoutingControls.swift`)

```swift
struct FooterRow: View {
    @EnvironmentObject var controller: EngineController
    var body: some View {
        HStack {
            Toggle("Bei Anmeldung starten", isOn: $controller.launchAtLogin)
                .toggleStyle(.checkbox).font(.system(size: 11))
            Spacer()
            Button("Beenden") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
```

### 4.11 MenuBarView Container (Rewrite-Body, `MenuBarView.swift`)

```swift
var body: some View {
    let ui = ARNUIState(status: controller.status, isStarting: controller.isStarting)
    VStack(alignment: .leading, spacing: 0) {
        WaveHeaderView(state: ui)
        statusBar(ui)
        if controller.isSuspectedTCCDenied { tccWarningSection.padding(.horizontal, 14).padding(.bottom, 8) }
        if case .error(let e) = controller.status { errorSection(e).padding(.horizontal, 14).padding(.bottom, 8) }
        if ui == .active { VolumeRow().padding(.horizontal, 14).padding(.vertical, 6); Divider() }
        ScrollView {
            VStack(spacing: 8) {
                ForEach(controller.outputConfigs, id: \.self) { cfg in
                    DeviceCardView(state: ui, config: cfg)
                }
                AddDeviceRow()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(maxHeight: 320)
        Divider()
        VStack(spacing: 10) {
            RoutingButton(state: ui)
            FooterRow()
        }
        .padding(14)
    }
    .frame(width: 320)
    .onAppear { controller.refreshLaunchAtLoginStatus() }
    .task {   // unverändert aus Ist-Stand übernommen
        controller.refreshAvailableDevices()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            controller.refreshAvailableDevices()
        }
    }
}
```

- `tccWarningSection`, `errorSection(_:)` werden **unverändert** aus dem Ist-Stand (`MenuBarView.swift:122-156`) übernommen.
- `VolumeRow` = der bestehende `volumeSection` (`MenuBarView.swift:160-180`), in eine eigene kleine `View` extrahiert (nutzt `controller.currentVolume`/`isMuted`/`setSystemVolume`).
- **ScrollView** kappt die Höhe (`maxHeight 320`), damit das Popover bei vielen Geräten nicht überläuft (Accordion kann die Höhe stark ändern).

### 4.12 Animation-Specs (Übersicht)

| Element | Technologie | Parameter |
|---------|-------------|-----------|
| Welle | `TimelineView(.animation)` + `Canvas` + `.drawingGroup()` | 3 Layer, amp 10/7/5 pt, len 200/150/110 pt, speed 0.30/0.45/0.65 rad/s; `intensity`-Übergang `.easeInOut 0.4 s` |
| Status-Dot Puls | `.scaleEffect`+`.opacity` mit `.repeatForever(autoreverses:)` | 0.8 s, scale 1.0↔1.35, opacity 1.0↔0.55 |
| Accordion Expand | `withAnimation(.spring(...))` auf `expanded` + `.transition` | `response 0.32, damping 0.82`; insertion `opacity + move(.top)`, removal `opacity` |
| Chevron | `.rotationEffect` gekoppelt an `expanded` | 0°↔90° (folgt Spring) |
| Signal-Meter | `.animation(.linear, value: linear)` auf Balkenbreite | 0.12 s (folgt 500 ms-Polling geglättet) |
| Spinner | `ProgressView().controlSize(.small)` mint | statisch rotierend |
| Card-Dim (STARTING) | `.opacity(0.55)` | folgt State-Wechsel (implizit) |

---

## 5. Neue Swift-Dateien

| Datei | Target | Zweck |
|-------|--------|-------|
| `AudioRouterKit/Sources/AudioRouterKit/PeakMeters.swift` | AudioRouterKit | RT-sichere Peak-Box (16 Slots, `os_unfair_lock`) |
| `AudioRouterNow4/UI/Theme.swift` | App | `ARNColor`, `ARNUIState`, `ARNAudioMath` |
| `AudioRouterNow4/UI/WaveHeaderView.swift` | App | Animierter Wellen-Header |
| `AudioRouterNow4/UI/DeviceCardView.swift` | App | `DeviceCardView`, `ExpandedDeviceDetail`, `ChannelChipsRow`, `SignalMeter`, `StatsGrid`, `AddDeviceRow` |
| `AudioRouterNow4/UI/RoutingControls.swift` | App | `RoutingButton`, `FooterRow`, `PulsingDot`, `MintSpinner`, `VolumeRow` |

**Alternativen-Abwägung:**

- **Alles in `MenuBarView.swift`** (monolithisch): schneller zu schreiben, aber die Datei würde ~600 Zeilen umfassen, SwiftUI-Previews wären unübersichtlich, und `PeakMeters` (Kit-Layer) muss ohnehin separat sein. → **verworfen.**
- **Aufgesplittet (empfohlen):** Ein UI-Ordner (`AudioRouterNow4/UI/`), Kit-Typ im Kit. Klare Layer-Grenze (RT-Box im Kit, View-Tokens in der App). Jede View einzeln in Xcode-Preview testbar. → **gewählt.**
- `PeakMeters` **muss** im Kit liegen (der IOProc-Block ist Kit-intern, `nonisolated static`); ein App-Layer-Typ wäre dort nicht captured-fähig ohne public-Leak.

---

## 6. Implementierungs-Reihenfolge (Bottom-Up)

**Phase 1 — Kit / RT-Layer (keine UI-Abhängigkeit):**
1. `PeakMeters.swift` anlegen (§2.1). → Kompiliert eigenständig.
2. `FanOutEngine`: `peaks`-Property, `slotDeviceKeys`, `ioBufferFrames`, `peakLevel(slotIndex:)`, `deviceID(forUID:)`, `bufferFrameSize(for:)` (§2.2, §2.5).
3. `FanOutEngine`: `makeDirectIOBlock`-Signatur + Aufruf + Peak-Passage + Silence-Reset + Teardown-Reset (§2.3, §2.4).
4. **Checkpoint:** `swift build` (Kit) + Unit-Tests (§2.7 Punkte 1–4). Manueller Audio-Test: `peakLevel` reagiert.

**Phase 2 — Controller (hängt an Phase 1):**
5. `EngineController`: 4 `@Published` (§3.1).
6. `startRouting`-Split → `performStart` + `captureDeviceLatencies` (§3.2, §3.3).
7. `poll()`-Peak-Block, `peak(for:)`/`latency(for:)`, stop-Reset, Warm-Restart-Refresh (§3.4–§3.7).
8. **Checkpoint:** App baut, altes UI läuft weiter (neue Properties nur additiv), `isStarting` togglet korrekt.

**Phase 3 — UI (hängt an Phase 2):**
9. `Theme.swift` (Tokens, State-Enum, Math) — keine Abhängigkeit ausser SwiftUI.
10. `RoutingControls.swift` (`PulsingDot`, `MintSpinner`, `RoutingButton`, `FooterRow`, `VolumeRow`).
11. `WaveHeaderView.swift`.
12. `DeviceCardView.swift` (Card → Detail → Chips/Meter/Stats → AddRow).
13. `MenuBarView.swift` Rewrite (Container, §4.11) — verdrahtet alles.
14. **Checkpoint:** Previews aller Views (§7), manueller Durchlauf aller 3 States.

**Phase 4 — Audit + Commit:**
15. Validator-Agent (§7-Checkliste) über den kompletten Diff.
16. Auto-Commit-Regel (Projekt-CLAUDE.md): `LAUNCH_EXECUTION.md` updaten + Conventional-Commit.

---

## 7. Audit-Kriterien

### 7.1 Pro-Schritt-Checkliste

**FanOutEngine / PeakMeters:**
- [ ] `PeakMeters.record` enthält keinen `throw`, kein `malloc`, kein Array-Literal.
- [ ] `storage` wird nur in `init` alloziert, in `deinit` freigegeben.
- [ ] `makeDirectIOBlock` bleibt `nonisolated static`; Block captured `peaks` per Wert (kein `self`).
- [ ] Peak-Passage steht NACH `let vol` und VOR der Slot-Schleife; Slot-Write-Pfad unverändert.
- [ ] Silence-Early-Return ruft `peaks.reset()`.
- [ ] `slotDeviceKeys.count == directOutputSlots.count` nach Start.
- [ ] `teardownAggregate` resettet `peaks`, `slotDeviceKeys`, `ioBufferFrames`.
- [ ] `deviceID(forUID:)` ist `public`, delegiert an `deviceIDForUID`.

**EngineController:**
- [ ] `startRouting` verzögert `performStart` um einen MainActor-Tick; `isStarting`-Gate gegen Doppelstart.
- [ ] `performStart` reproduziert den bestehenden catch-Baum exakt.
- [ ] `captureDeviceLatencies` behandelt `deviceID(forUID:) == nil` (kein Force-Unwrap).
- [ ] `poll()`-Peak-Block nur bei `status == .routing` (steht nach der bestehenden Guard).
- [ ] `stopRouting` resettet alle 4 neuen Properties.
- [ ] Alle 3 Warm-Restart-Pfade refreshen `bufferFrames` + `deviceLatencies`.

**UI:**
- [ ] `ARNColor.accent == Color(red: 0.251, green: 0.863, blue: 0.647)` (#40DCA5) exakt.
- [ ] `ARNUIState` deckt alle 4 Fälle; STARTING hat Vorrang vor `status`.
- [ ] Card ist nur bei `.active` klickbar (`onTapGesture` guard).
- [ ] IDLE zeigt keinen toten per-Gerät-Slider (Entscheidung §4.6).
- [ ] Peak-Lookup über `controller.peak(for:)` (nie manueller Key-Bau im View).

### 7.2 RT-Safety-Checks
- [ ] Thread-Sanitizer-Lauf: kein Race IOProc↔MainActor auf `PeakMeters`.
- [ ] Instruments (Time Profiler) auf dem IOThread: Peak-Passage < 5 % Callback-Budget.
- [ ] Kein Audio-Glitch/Dropout im A/B-Test (mit vs. ohne Peak-Einbau).
- [ ] Delay-Kompensation (Phase 4) unverändert hörbar synchron (Regression).

### 7.3 SwiftUI-Preview-Checks
Jede neue View braucht ein `#Preview` mit einem `EngineController`-Stub (oder Mock via `@Published`-Injektion). Prüfen:
- [ ] `WaveHeaderView(state: .idle)` gedimmt vs. `.active` voll-mint.
- [ ] `DeviceCardView` in allen 4 States (idle/starting/active-collapsed/active-expanded).
- [ ] `SignalMeter(linear: 0)` → „−∞"; `linear: 1` → „0 dB", voller Balken.
- [ ] `StatsGrid` mit/ohne Latenz-Info (Fallback „–").
- [ ] `RoutingButton` in allen 3 sichtbaren States + disabled bei leeren Outputs.

### 7.4 Regressions-Checks (bestehende Funktionen)
- [ ] Add/Remove Device während Routing (Warm-Restart M1) funktioniert weiter.
- [ ] Volume-Slider schreibt System-Volume (`setSystemVolume`).
- [ ] TCC-Warnung + Fehler-Section erscheinen wie zuvor.
- [ ] Launch-at-Login-Toggle (M2) + Auto-Start (S4) unverändert.
- [ ] „unavailable"-Gerät (nicht in `availableDevices`) wird in der Card gedimmt gezeigt, `peak(for:)==nil`.

---

## 8. Risiken und Mitigationen

| # | Risiko | Wahrsch. | Impact | Mitigation |
|---|--------|----------|--------|-----------|
| R1 | **IOProc-Änderung** verursacht Audio-Glitch/Crash | niedrig | hoch | Peak-Passage ist read-only auf der Tap-Quelle, ändert den Write-Pfad NICHT; `nonisolated static`-Regel eingehalten; A/B-Regressionstest (§7.2); Rollback = Passage + `record`-Aufruf entfernen |
| R2 | **`PeakMeters` Data-Race** IOProc↔MainActor | niedrig | mittel | Ein `os_unfair_lock` deckt Writer+Reader (bewährtes `VolumeTracker`-Muster); TSan im Audit |
| R3 | **`TimelineView(.animation)`** treibt CPU im geschlossenen/idle Popover | mittel | niedrig | `.drawingGroup()` (Metal); im geschlossenen Popover pausiert SwiftUI die TimelineView automatisch. Optional M2: bei `.idle` auf statisches `Canvas` (ohne TimelineView) umschalten, wenn Time-Profiler > 3 % zeigt |
| R4 | **UID→AudioObjectID** nicht auflösbar (Gerät weg zwischen Start und Latenz-Read) | mittel | niedrig | `captureDeviceLatencies` überspringt `nil`; `StatsGrid` zeigt „–"; kein Crash |
| R5 | **Composite-Key-Kollision** wäre bei purem UID-Key aufgetreten | — | — | Key `"uid:channelOffset"` gewählt; gekapselt in `peak(for:)`/`slotDeviceKeys` |
| R6 | **`bufferFrames`** ist Aggregate-global, nicht per-Device | sicher | kosmetisch | UI zeigt es als globale Session-Statistik in jeder Card (dokumentiert); per-Device-Buffer gibt es im Aggregate-Modell nicht |
| R7 | **Peak flackert** bei 500 ms-Polling | mittel | niedrig | UI-seitige Release-Glättung in `poll()` (§3.4) + `.animation(.linear 0.12)` am Balken |
| R8 | **Accordion-Höhensprung** überläuft Popover | mittel | niedrig | `ScrollView` mit `maxHeight 320` (§4.11) |
| R9 | **STARTING-Frame** wird bei sehr schnellem Start nicht sichtbar | niedrig | kosmetisch | Akzeptiert — der Tick-Split garantiert mind. einen Render; kein funktionaler Effekt |

---

## 9. Zusammenfassung für den Validator

**Was prüfen (Prio-Reihenfolge):**
1. **RT-Safety** der IOProc-Peak-Passage + `PeakMeters` (R1, R2) — kritischster Punkt, da Audio-Pfad.
2. **`slotDeviceKeys` ↔ `slots` 1:1-Korrespondenz** (Peak-Zuordnung hängt daran).
3. **Backward-Compat** des `startRouting`-Splits (catch-Baum, Auto-Start, Doppelstart-Gate).
4. **Reset-Vollständigkeit** der 4 neuen Properties in stop + allen 3 Warm-Restart-Pfaden.
5. **Composite-Key**-Konsistenz zwischen Engine (`slotDeviceKeys`) und Controller (`peak(for:)`).
6. **UI-State-Ableitung** (STARTING-Vorrang) + `#40DCA5`-Token-Exaktheit.

**Geänderte Dateien:** `FanOutEngine.swift` (Erweiterung), `EngineController.swift` (Erweiterung), `MenuBarView.swift` (Rewrite).
**Neue Dateien:** `PeakMeters.swift`, `Theme.swift`, `WaveHeaderView.swift`, `DeviceCardView.swift`, `RoutingControls.swift`.
**Architektur-Grenze:** RT-Box im Kit, UI-Tokens/Views in der App, Controller als einzige MainActor-Brücke — bestehende Layering-Disziplin bleibt intakt.
</content>
</invoke>
