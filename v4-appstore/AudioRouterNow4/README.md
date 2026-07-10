# AudioRouterNow v4

macOS Menu Bar App that routes system audio to multiple output devices
simultaneously using the CoreAudio HAL. A single Process Tap captures the system
mix; a private Aggregate Device fans it out to N output slots with per-device
latency compensation — no third-party drivers, no kernel extensions.

> App Store Edition (Swift rewrite of the v3 HAL-plugin architecture). Ships as
> an `LSUIElement` (menu-bar only, no Dock icon).

## Requirements

- macOS 13.0+ (Ventura) — Process Taps (`AudioHardwareCreateProcessTap`) are 14.2+
  for some APIs; the app targets modern CoreAudio Tap support
- Xcode 15+
- Swift 5.9+
- System Audio Recording permission (TCC) granted by the user on first routing

## Architecture

### Overview

The project is split into a pure audio engine (SPM package) and a thin SwiftUI
app shell. The engine owns the real-time path and knows nothing about the UI;
the app polls the engine on the main actor and renders.

```
┌──────────────────────────── AudioRouterNow4 (App) ─────────────────────────┐
│                                                                            │
│  AudioRouterNowApp ──@StateObject──> EngineController (@MainActor)          │
│   (MenuBarExtra)                        │  owns                             │
│        │ injects env                    ▼                                   │
│   MenuBarView ── WaveHeaderView ── DeviceCardView                           │
│   (polls controller: waveEnergy 20fps, waveformSnapshot 60fps)             │
│                                          │                                  │
└──────────────────────────────────────────┼─────────────────────────────────┘
                                            │ start / updateOutputs / poll
┌──────────────────────────── AudioRouterKit (SPM) ─┼─────────────────────────┐
│                                                    ▼                         │
│  FanOutEngine (@MainActor control path)                                     │
│   ├── createTap()          → CATapDescription + AudioHardwareCreateProcessTap│
│   ├── buildAndStartAggregate → private Aggregate (Tap + all output devices) │
│   └── makeDirectIOBlock()  → ONE nonisolated Direct-IOProc (RT thread)      │
│                                   │ writes RT-safe                          │
│         ┌─────────────────────────┼──────────────────────────┐             │
│         ▼                         ▼                          ▼              │
│   WaveformBridge            PeakMeters (AudioMetrics)   TapIOMetrics        │
│   (256-slot ring)           (os_unfair_lock)           (silence heuristic)  │
│                                                                             │
│  DeviceLifecycleManager — property listeners → debounced (warm) restart     │
│  OutputConfig — value type, Codable (UserDefaults persistence)              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Audio Pipeline

```
System Default Device (all app audio, post-mix)
        │
        ▼
  CATap (stereoGlobalTap, own process excluded, muteBehavior = .mutedWhenTapped)
        │  inInputData (last input buffer of the aggregate)
        ▼
  Direct IOProc  ──────────────────────────────────────────────► ioOutputData
        │  (peak metering, waveform min/max, volume scale, delay compensation)
        │
        ├─ slot[0] Default Output   (buffer offset 0)
        ├─ slot[1] Fan-out target 1 (channel offset, optional DelayLine)
        ├─ slot[2] Fan-out target 2
        └─ slot[N] …
```

Key points:

- **Single source of truth.** With `.mutedWhenTapped`, CoreAudio mutes the source
  at the tap, so the default output receives no signal on the native path. The
  Direct-IOProc is therefore the *only* signal producer and drives **all** slots,
  including the default output (`allOutputs[0]`, buffer offset 0).
- **Zero inter-thread latency.** No ring buffer between capture and playback: the
  IOProc copies `inInputData → ioOutputData` in place. The private Aggregate
  Device synchronizes the clocks of all sub-devices
  (`kAudioSubTapDriftCompensationKey`). End-to-end latency ≈ 5 ms (tap capture
  delay only).
- **Feedback-loop prevention.** The app's own process is excluded from the tap
  (`kAudioHardwarePropertyTranslatePIDToProcessObject`). Otherwise the fan-out
  output would be re-captured by the global tap and accumulate exponentially.
- **Output-latency compensation (Phase 4).** Devices differ wildly in hardware
  latency (USB ≈ 5–40 ms, Bluetooth ≈ 100–300 ms, AirPlay ≈ 200–2000 ms). Lower-
  latency slots are delayed by a `DelayLine` up to `maxLatency` so every slot
  plays in sync. Latencies are sample-rate-normalized (seconds) for comparison;
  `delayFrames` is expressed in the aggregate's nominal sample rate.

### Real-Time Safety

The Direct-IOProc runs on `com.apple.audio.IOThread.client`, not the main queue.
It obeys strict RT constraints:

- **No allocation.** Scratch buffers and `DelayLine` storage are pre-allocated at
  build time (capacity = `maxFramesPerCallback`, 4096). The IOProc never touches
  the heap.
- **No throwing / no blocking.** The block returns `Void`; all error handling
  lives on the control path.
- **Lock discipline.** Cross-thread state (`WaveformBridge`, `PeakMeters`) is
  guarded by `os_unfair_lock` / `OSAllocatedUnfairLock` — bounded O(1) sections
  (< 100 ns) with priority inheritance, so the low-priority UI reader cannot
  cause priority inversion against the RT writer.
- **No inherited MainActor isolation.** The IOProc block is built by a
  `nonisolated static` factory (`makeDirectIOBlock`). A closure defined inline in
  a `@MainActor` method inherits MainActor isolation, which injects a
  `dispatch_assert_queue(mainQueue)` check that fails on the CoreAudio RT thread
  (`EXC_BREAKPOINT`). **Rule: all RT/CoreAudio callbacks must be built in a
  `nonisolated` context.**
- **Clamping over trust.** Frame counts are clamped against the real output
  buffer size *and* the pre-allocated capacity (no overrun). The `DelayLine` path
  is used only when `n <= delayFrames` to avoid ring read/write overlap.

### Threading Model

Four cooperating rates, from real-time down to render:

| Tier | Runs on | Rate | Purpose |
|------|---------|------|---------|
| Direct-IOProc | CoreAudio RT thread | ~86 Hz (48k/512) | capture → fan-out, peak/waveform capture |
| `wavePollTask` | MainActor | 20 fps (50 ms) | peak levels + perceptual `waveEnergy` |
| `pollingTask`  | MainActor | 2 fps (500 ms) | callbacks, TCC suspicion, volume/mute |
| `TimelineView(.animation)` | Main / render | up to 60 fps | oscilloscope Canvas reads `waveformSnapshot` |

The engine writes RT-safe; the controller only ever *reads* those boxes from the
main actor. Device-lifecycle callbacks arrive on a serial CoreAudio queue and hop
back to the main actor via `Task { @MainActor }`.

### Components

| Component | File | Responsibility |
|-----------|------|----------------|
| `FanOutEngine` | `AudioRouterKit/…/FanOutEngine.swift` | Tap + Aggregate + Direct-IOProc; master election; slot mapping; latency compensation |
| `WaveformBridge` | `AudioRouterKit/…/WaveformBridge.swift` | RT-safe 256-slot (min,max) ring for the oscilloscope |
| `PeakMeters` / `TapIOMetrics` | `AudioRouterKit/…/AudioMetrics.swift` | RT-safe peak levels + silence/callback counters |
| `OutputConfig` | `AudioRouterKit/…/OutputConfig.swift` | Value type: device UID + channel offset (Codable) |
| `DeviceLifecycleManager` | `AudioRouterKit/…/DeviceLifecycleManager.swift` | Property listeners → debounced full/warm restart |
| `RouterError` / `RouterStatus` | `AudioRouterKit/…/AudioRouterKit.swift` | Public error/status surface + OSStatus mapper |
| `AudioRouterNowApp` | `AudioRouterNow4/AudioRouterNowApp.swift` | MenuBarExtra entry point + onboarding |
| `EngineController` | `AudioRouterNow4/EngineController.swift` | `@MainActor ObservableObject` bridge; polling; persistence |
| `AppDelegate` | `AudioRouterNow4/AppDelegate.swift` | `applicationDidFinishLaunching` hook |
| `MenuBarView` | `AudioRouterNow4/MenuBarView.swift` | Root UI: header, status, device list, controls |
| `WaveHeaderView` | `AudioRouterNow4/UI/WaveHeaderView.swift` | Normalized oscilloscope header (Canvas + Metal) |
| `DeviceCardView` | `AudioRouterNow4/UI/DeviceCardView.swift` | Device cards, signal meters, stats grid |

## Project Structure

```
AudioRouterNow4/
├── AudioRouterKit/                 SPM package — the audio engine (UI-free)
│   └── Sources/AudioRouterKit/
│       ├── FanOutEngine.swift          Tap + Aggregate + Direct-IOProc (RT)
│       ├── WaveformBridge.swift        RT-safe oscilloscope ring buffer
│       ├── AudioMetrics.swift          PeakMeters + TapIOMetrics (RT-safe)
│       ├── OutputConfig.swift          Codable output-target value type
│       ├── DeviceLifecycleManager.swift  Hot-plug / SR-change reconciliation
│       └── AudioRouterKit.swift        Public API: RouterError/RouterStatus
├── AudioRouterNow4/                SwiftUI app shell (LSUIElement)
│   ├── AudioRouterNowApp.swift         MenuBarExtra entry point + onboarding
│   ├── EngineController.swift          ObservableObject bridge (MainActor)
│   ├── AppDelegate.swift               NSApplicationDelegate
│   ├── MenuBarView.swift               Root UI view
│   └── UI/
│       ├── WaveHeaderView.swift        Oscilloscope header (TimelineView+Canvas)
│       └── DeviceCardView.swift        Device cards, meters, stats
├── Configs/                        Build configs / entitlements
├── AudioRouterNow4.xcodeproj       Generated project (see project.yml)
├── project.yml                     XcodeGen spec
└── README.md                       This file
```

## Building

Open in Xcode:

```sh
open AudioRouterNow4.xcodeproj
# Select the AudioRouterNow4 scheme → Run (⌘R)
```

The `AudioRouterKit` package resolves automatically as a local SPM dependency.

To build the engine package in isolation (fast, hardware-free unit tests for the
pure slot-planning logic — `computeSlotLayouts`, `electMasterUID`):

```sh
cd AudioRouterKit
swift build
swift test
```

Notes:

- The app is an `LSUIElement`; there is no window — look for the waveform icon in
  the menu bar after launch.
- On first routing, macOS prompts for **System Audio Recording** permission. A
  denied permission surfaces as `noErr` + continuous silence, detected
  heuristically (`FanOutEngine.isSuspectedTCCDenied`) and shown as a UI hint —
  there is no public preflight API (App Store Guideline 2.5.1).

## Key Design Decisions

- **Single Direct-IOProc, not one per output.** All outputs are sub-devices of
  one private Aggregate Device. A single IOProc writes every slot from the shared
  tap source, so the sub-device clocks are drift-compensated by CoreAudio and no
  cross-IOProc synchronization is needed.
- **Master election is deterministic.** The clock master is chosen by transport
  type (USB/TB/PCI > built-in > HDMI > virtual > *never* Bluetooth/AirPlay), with
  a lexicographic UID tie-break — reproducible regardless of add order. Adaptive-
  buffer transports (BT/AirPlay) are never master.
- **Warm restart preserves the TCC session.** Adding/removing outputs or handling
  a sample-rate change tears down only the Aggregate + IOProc and rebuilds
  (`updateOutputs`). The tap survives, so no new permission prompt fires. Full
  restart is reserved for default-device change / device loss / coreaudiod
  restart.
- **UID-based device identity.** Configs persist the stable
  `kAudioDevicePropertyDeviceUID`, never the volatile `AudioObjectID`, so hot-plug
  reconciliation stays correct across reconnects.
- **Pure planning logic is isolated for testing.** `computeSlotLayouts` and
  `electMasterUID` are `nonisolated static` and CoreAudio-free, making the tricky
  buffer-offset / delay-frame math unit-testable without hardware.
- **Perceptual, not linear, UI energy.** The header waveform maps peak → dBFS →
  normalized [0,1] and smooths with an asymmetric EMA (fast attack, slow release)
  for a VU-meter feel; the oscilloscope normalizes per snapshot so quiet audio
  stays visible while silence collapses to a thin line.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
Copyright 2026 Mauricio Moraïs da Cunha.
