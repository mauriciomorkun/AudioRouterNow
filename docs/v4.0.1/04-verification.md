# 04: What was verified, and what was not

[Back to the index](README.md) · Previous: [03-discarded-approaches.md](03-discarded-approaches.md)

---

The short version: the three defects are fixed and the fixes are tested. That
these fixes resolve *the five reported crashes* is not established, and cannot
be until the crash statistics come in.

---

## 1. Automated tests

**59 swift-testing cases across 10 suites, all green.**

| Suite | Cases | What it covers |
|-------|-------|----------------|
| `WaveformGeometry` | 13 | `+Inf` in `max`, `-Inf` in `min`, `NaN` in both, all-zero input, values above 1 (clamping), the empty array, and the combination of `sanitize` feeding `normalizationAmplitude` |
| `WaveformBridge Phase` | 14 | The sub-pixel phase logic |
| 8 pre-existing suites | 32 | `RouterError`, `RouterStatus`, `FanOutEngine` error paths, `FanOutEngine` slot layout, `DeviceLifecycleManager` settle delays, `DelayLine`, `OutputConfig` codable, `TapIOMetrics` |

The 27 new cases are in
[`WaveformGeometryTests.swift`](../../v4/AudioRouterKit/Tests/AudioRouterKitTests/WaveformGeometryTests.swift)
and
[`WaveformPhaseTests.swift`](../../v4/AudioRouterKit/Tests/AudioRouterKitTests/WaveformPhaseTests.swift).

> Count detail: 59 is the swift-testing (`@Test`) total. `SlotGainsTests` is an
> older XCTest class with 8 further cases and is not part of that number.

**What made the phase logic testable.** `WaveformBridge.init` takes an
injectable clock:

```swift
init(clock: @escaping @Sendable () -> Double = { CACurrentMediaTime() })
```

Production never passes it. The tests do, which means the interval smoothing,
the plausibility bounds and the phase calculation are all exercised without a
single real-time wait. A test suite that has to sleep in order to test timing is
a test suite that will be flaky on a loaded CI machine; this one is
deterministic.

**Why the hardening lives in the kit.** `WaveformGeometry` is in
`AudioRouterKit` rather than in the view precisely so that it can be tested
without bootstrapping a window or an app. That was a design constraint, not a
convenience.

---

## 2. Build

Full application build under `SWIFT_STRICT_CONCURRENCY: complete`. No errors, no
warnings.

That setting matters here because the fix moves a `@Published` write into a
`Task`-driven loop and introduces a new `@MainActor` observable object. Strict
concurrency checking is what confirms the actor isolation of `WaveClock`,
`WaveNormalizer` and the poll loop is sound rather than merely untested.

---

## 3. Manual verification

Carried out by the developer on a debug build.

| Check | Result |
|-------|--------|
| Panel opened and closed repeatedly with music playing | Waveform present every time |
| Level meters during the same test | Unchanged from 4.0.0 behaviour |
| Routing stopped | Animation settles, canvas stops redrawing |

The first of those is the one that both discarded approaches failed
([03-discarded-approaches.md](03-discarded-approaches.md)). It is the check that
distinguishes the shipped solution from them, and it is the reason it was
performed by hand rather than reasoned about.

---

## 4. Not verified, stated plainly

This is the part of the document that matters most in a year's time.

### The crash was never reproduced

It was not reproduced on any development machine, and no attempt succeeded.
The available facts point at a condition that is specific to one setup:

- one device out of 21 downloads,
- five reports over four days from that single device,
- macOS 26.6.2, ARM64,
- terminating frames inside AppKit's **per-window** display cycle.

The per-window framing is the suggestive part. Plausible triggers of that shape
include an external monitor, a refresh rate that differs from the built-in
display, display sleep and wake, and a resolution or scaling change. None of
these has been tested, and none is more than a guess. Without the raw `.ips`
there is no way to narrow it further.

### The raw `.ips` was never obtained

App Store Connect shows the crash grouping, not the full log. What is still
missing: the symbolicated trace with offsets, the exception subtype, the other
threads, the distribution across OS builds and hardware, and session counts
rather than report counts.

Every defect in [01-crash-analysis.md](01-crash-analysis.md) is derived from
reading the source. Each one is a genuine defect and each fix stands on its own.
Whether they are *the* defect behind those five reports is open.

### Whether the fix works can only be answered statistically

The honest test is the crash rate in App Store Connect over at least two weeks
after 4.0.1 reaches users. Nothing before that is evidence either way.

### `.drawingGroup()` is still in place

The keep-or-remove decision is deferred until a reproduction measurement exists
([D10](02-decisions.md#d10-keep-drawinggroup-for-now)). Removing it on
suspicion would degrade drawing quality with no evidence of benefit, and it
would make the post-release statistics ambiguous by changing two things at once.

### Residual timing jitter in the redraw

The poll uses `Task.sleep`, which guarantees only a **minimum** duration, and
the poll shares the MainActor with the entire user interface. Frame spacing
therefore varies by a few milliseconds. The sub-pixel phase corrects for the
*audio* side of the timing, not for this.

`CVDisplayLink` would fix it, and it is a different mechanism from the display
cycle observer that crashed. It was not used because it is marked deprecated on
recent macOS and because introducing a new display-timing mechanism into a patch
release whose entire purpose is to remove one would be poor judgement. It
remains available as a future option.

---

## 5. What would close this out

In order of value:

1. **Crash statistics.** Two weeks minimum after 4.0.1 is live, watching whether
   the signature recurs. This is the only real answer.
2. **The raw `.ips`**, if it can still be downloaded. It would turn a derived
   root cause into a proven one, or refute it.
3. **A reproduction measurement in Instruments**, comparing the canvas with and
   without `.drawingGroup()` under the display conditions suspected above. This
   would settle [D10](02-decisions.md#d10-keep-drawinggroup-for-now) on data
   rather than on instinct.
4. **Reports through the new bug report button**
   ([D9](02-decisions.md#d9-a-bug-report-button)). The original user had no way
   to describe what he was doing. The next one will.

---

[Back to the index](README.md)
