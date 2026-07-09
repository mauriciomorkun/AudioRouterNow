# AudioRouterNow v4 — UI-Layer-Dokumentation

Konzept 4B „Fusion Prominent Wave + Accordion Expand" (Session 5).
Kompakte Referenz für den SwiftUI-Layer. Ergänzt `../ARCHITECTURE.md` und die
vollständige `DESIGN_SPEC_UI_V4B.md`.

## Datei-Übersicht

| Datei | Inhalt |
|-------|--------|
| `Theme.swift` | `ARNUIState` (State-Machine), `ARNColor` (Farb-Tokens), `ARNAudioMath` (dBFS-Helfer) |
| `WaveHeaderView.swift` | Animierter 3-Layer-Sinuswellen-Header (`TimelineView(.animation)` + `Canvas` + `.drawingGroup()`) |
| `RoutingControls.swift` | `PulsingDot`, `MintSpinner`, `VolumeRow`, `RoutingButton`, `FooterRow` |
| `DeviceCardView.swift` | `DeviceCardView` (Accordion), `ExpandedDeviceDetail`, `ChannelChipsRow`, `SignalMeter`, `StatsGrid`, `AddDeviceRow` |
| `../MenuBarView.swift` | Container-View: setzt alles zusammen, 320 pt, `ScrollView` (maxHeight 320) |

Alle Views beziehen den `EngineController` per `@EnvironmentObject`. Der
`ARNUIState` wird EINMAL in `MenuBarView.body` berechnet und an die Kinder
durchgereicht.

## ARNUIState — State-Machine

```swift
enum ARNUIState: Equatable { case idle, starting, active, error(RouterError) }
init(status: RouterStatus, isStarting: Bool)   // starting hat Vorrang
```

- Ableitung: `isStarting == true` → `.starting`, sonst Mapping aus `RouterStatus`.
- `isActive`, `isStarting`: Convenience-Flags.
- `waveIntensity`: `1.0` für `starting`/`active`, sonst `0.0` (steuert Header-
  Amplitude, Gradient und Akzentfarbe).

Zustands-Effekte in der UI:

| State | Header | Status-Dot | Geräte-Leading | Button |
|-------|--------|-----------|----------------|--------|
| idle | gedimmt, kleine Welle | grau, kein Puls | `checkmark.square.fill` (mint) | „Routing starten" (mint) |
| starting | voll, Welle | mint, Puls | `MintSpinner` | „Verbinde…" (deaktiviert, Spinner) |
| active | voll, Welle | mint/gelb, Puls | Signal-Dot (mint/grau) | „Stop Routing" (dunkel, mint-Rand) |
| error | gedimmt | rot, kein Puls | wie idle | „Routing starten" |

## Color-Tokens (ARNColor)

| Token | Wert | Verwendung |
|-------|------|-----------|
| `accent` | `#40DCA5` (mint) | Primäraktion, aktive Meter/Chips, Wellen voll |
| `accentDim` | dunkler Grün-Tint | Wellen im IDLE-Header |
| `headerTop` / `headerBottom` | dunkelgrün | Header-Gradient VOLL |
| `headerTopDim` / `headerBottomDim` | neutralgrau | Header-Gradient GEDIMMT |
| `cardStroke` | weiss 8 % | Glass-Card-Rand (default) |
| `cardStrokeActive` | accent 35 % | Card-Rand bei expandiert+active |
| `statusDotIdle` | grau 0.55 | Status-Dot im Idle |
| `meterTrack` | weiss 10 % | Signal-Meter-Hintergrundschiene |

## Signal-Meter-Mathematik (ARNAudioMath)

```swift
dbfs(_ linear: Float32, floorDB: Double = -60) -> Double        // linear[0…1] → dBFS, geklemmt
meterFraction(_ linear: Float32, floorDB: Double = -60) -> Double // dBFS → Füllgrad [0…1]
```

- `dbfs`: `20·log10(linear)`, unter `1e-7` → `floorDB`, geklemmt auf `[-60, 0]`.
- `meterFraction`: mappt `floorDB → 0` und `0 dB → 1` (lineare Balkenbreite).
- Anzeige: `SignalMeter.dbLabel` zeigt `−∞` bei `≤ -60 dB`, sonst `"%.0f dB"`.

Die Peak-Werte kommen bereits UI-geglättet aus `EngineController.poll()`
(Attack sofort, Release ~40 %/Tick), damit der Meter bei 500-ms-Polling nicht
flackert.

## WaveHeaderView — Animation

- `TimelineView(.animation)` liefert eine kontinuierliche Zeitbasis; `Canvas`
  zeichnet drei Sinus-Layer (Amplitude/Wellenlänge/Speed/Deckkraft je Layer).
- `.drawingGroup()` erzwingt Metal-Compositing → ruckelfreie Kurve.
- Amplitude skaliert mit `state.waveIntensity` (min. 0.08, damit im Idle eine
  Rest-Welle bleibt); Gradient und Akzentfarbe schalten bei `intensity > 0.5`.
- `.animation(.easeInOut(0.4), value: intensity)` blendet den State-Wechsel weich.
- Höhe 112 pt, Titel-Overlay oben links (`waveform`-Icon + „AudioRouterNow").

## DeviceCardView — Accordion

- Glass-Card (`.ultraThinMaterial`, Radius 10). Tap toggelt `expanded` NUR im
  `.active`-State (`spring(response: 0.32, dampingFraction: 0.82)`).
- Header: Leading-Indicator (state-abhängig) · Gerätename (tertiär, wenn Gerät
  nicht verfügbar) · optionale `Ch…`-Marke · Chevron (rotiert 90° bei expandiert)
  · Remove-Button.
- Expand (`ExpandedDeviceDetail`, nur active+expanded): Divider,
  `ChannelChipsRow`, L/R-`SignalMeter`, `StatsGrid`. Insertion per
  `opacity + move(.top)`, Removal per `opacity`.
- `strokeColor`: `cardStrokeActive` bei expandiert, sonst `cardStroke`.
- Im STARTING-State ist die Card auf `opacity 0.55` gedimmt.
- `ChannelChipsRow`: Kanalnamen aus `channelOffset`+`channelCount`
  (`L, R, C, LFE, Ls, Rs, Lb, Rb`, danach `Ch<n>`).
- `StatsGrid`: Latenz (`latency(for:)`) · Puffer (`bufferFrames`) · Rate
  (`sampleRate/1000`).
- `AddDeviceRow`: `Menu` aus `availableDevices`; bei Multi-Kanal-Geräten ein
  Eintrag pro Kanalpaar (`OutputConfig(uid:channelOffset:)`).

## RoutingButton — 3 States

| State | Icon | Titel | Hintergrund | Text | Rand |
|-------|------|-------|-------------|------|------|
| idle/error | `play.fill` | „Routing starten" | `accent` | schwarz | – |
| starting | `MintSpinner` | „Verbinde…" | `.ultraThinMaterial` | mint | – |
| active | `stop.fill` | „Stop Routing" | dunkel (white 0.12) | mint | mint 60 % |

- Aktion: active → `stopRouting()`, idle/error → `startRouting()`, starting → no-op.
- `disabled`, wenn `starting` ODER (`outputConfigs.isEmpty` und nicht active).

## Neue EngineController-Properties (für UI-Consumer)

Diese Session-5-Properties/-Methoden treiben die neue UI (Signaturen siehe
`../EngineController.swift`):

- `isStarting: Bool` — treibt `ARNUIState.starting` (STARTING-Frame).
- `peakLevels: [String:(l,r)]` + `peak(for: OutputConfig) -> (l,r)?` —
  Composite-Key `"<uid>:<channelOffset>"`, geglättet, für Signal-Meter/Dot.
- `bufferFrames: Int` — IO-Buffer-Grösse für `StatsGrid`.
- `deviceLatencies: [String:DeviceLatencyInfo]` + `latency(for:)` — Latenz/Rate
  für `StatsGrid`.
- `startRouting()` — split: setzt `isStarting`, `performStart()` im nächsten Tick.
</content>
