# 02: The decisions, and why they were made that way

[Back to the index](README.md) · Previous: [01-crash-analysis.md](01-crash-analysis.md) · Next: [03-discarded-approaches.md](03-discarded-approaches.md)

---

## Summary

| ID | Decision | One-line reason |
|----|----------|-----------------|
| [D1](#d1-remove-the-timeline-instead-of-pausing-it) | Remove `TimelineView` entirely | Deleting the frame the crash sits in beats guessing when to pause it |
| [D2](#d2-the-tick-lives-in-its-own-object) | Put the redraw tick in `WaveClock`, not on `EngineController` | A `@Published` on the controller re-evaluates the whole panel at 60 Hz |
| [D3](#d3-poll-at-60-fps-meter-at-20-hz) | Poll at 60 fps, call `updateWaveEnergy()` every third pass | The meter EMA constants are tuned for 20 Hz |
| [D4](#d4-sub-pixel-scrolling-from-a-self-measured-interval) | Measure the push interval in the ring buffer and offset by a fraction of a column | Fixes a stutter that no frame rate can fix |
| [D5](#d5-one-call-in-the-audio-path-and-why-it-is-allowed) | Allow one `CACurrentMediaTime()` in `WaveformBridge.push()` | Mach timebase read, no syscall, no allocation, inside the existing lock |
| [D6](#d6-harden-after-the-ring-buffer-with-isfinite) | Sanitise in `WaveformGeometry`, on the MainActor, using `isFinite` | The realtime path stays untouched, and `isNaN` would miss the actual problem |
| [D7](#d7-smooth-the-normalisation-reference-across-frames) | Smooth the normalisation reference across frames | A per-frame reference makes the whole curve jump |
| [D8](#d8-leave-the-device-poll-ungated) | Leave the device poll ungated | Its gate depended on the same unreliable signal, and a stuck gate freezes the device list |
| [D9](#d9-a-bug-report-button) | Add a bug report button | Five crashes reached the developer through a chart, two weeks late |
| [D10](#d10-keep-drawinggroup-for-now) | Keep `.drawingGroup()` | Removing it without a measurement would be guessing |
| [D11](#d11-accept-that-build-8-resets-launch-at-login) | Accept that build 7 to 8 resets "Launch at Login" | Intended behaviour under Guideline 2.4.5(iii) |

---

## D1: remove the timeline instead of pausing it

**Decision.** `TimelineView(.animation)` was deleted from `WaveHeaderView`. The
canvas now redraws when `WaveClock.tick` changes, and that tick is advanced by
`wavePollTask` in `EngineController`.

**Why.** Two separate arguments point the same way.

*The crash argument.* The reported crash sits in
`__NSWindowGetDisplayCycleObserver`. `TimelineView(.animation)` is what
registers that observer. Removing the timeline means the app no longer has a
display cycle observer at all, so the frame the report points at cannot be
reached from this code path any more. That is a stronger position than pausing
the observer at the right moments, because it does not depend on getting the
moments right.

*The lifetime argument.* The poll that now drives the tick already existed, and
it has exactly the lifetime the animation should have had all along:

```swift
// EngineController.performStart()
if status == .routing {
    startPolling()      // starts wavePollTask
}

// EngineController.stopRouting()
wavePollTask?.cancel(); wavePollTask = nil
```

It starts when routing starts and is cancelled when routing stops. No panel
visibility has to be detected, guessed or observed. Two attempts to detect it
had already failed at this point, see
[03-discarded-approaches.md](03-discarded-approaches.md).

**Accepted cost.** While routing is active the canvas redraws at 60 fps whether
or not the panel is open, because nothing in the app knows whether it is open.
That is more work than the theoretical minimum. It buys correctness that the
theoretical minimum did not achieve in two attempts.

**Second accepted cost.** The idle sine wave no longer drifts, it stands still.
When routing is off there is no tick at all. That is decoration with no signal
behind it, and a static decoration was judged an acceptable price for having no
timer running in the idle state.

Documented at the decision site in
[`WaveHeaderView.swift`](../../v4/AudioRouterNow4/UI/WaveHeaderView.swift) and
[`WaveClock.swift`](../../v4/AudioRouterNow4/UI/WaveClock.swift).

---

## D2: the tick lives in its own object

**Decision.** `WaveClock` is a separate `@MainActor ObservableObject` holding a
single `@Published private(set) var tick: UInt32`. It is not a property on
`EngineController`.

**Why.** A `@Published` on `EngineController` would have worked functionally and
cost one file less. But `EngineController` is observed by the entire panel:
device cards, level meters, the volume row, the footer. Any change to any
`@Published` on it invalidates all of them. At 60 Hz that is the whole panel
tree re-evaluated sixty times a second, when the only thing that needs to be
redrawn is one canvas.

`WaveClock` is observed by `WaveHeaderView` and by nothing else. It is passed in
explicitly rather than through the environment, which makes that scope visible
at the call site:

```swift
WaveHeaderView(state: ui, clock: controller.waveClock)
```

**Detail worth keeping.** `advance()` uses `&+=`, wrapping addition, on purpose.
At 60 Hz the overflow arrives after roughly two years of continuous routing, and
when it does the counter simply continues from zero. Only the change matters,
never the value. The canvas reads it as:

```swift
let _ = clock.tick   // establishes the dependency; the value is unused
```

---

## D3: poll at 60 fps, meter at 20 Hz

**Decision.** `wavePollTask` sleeps about 16.7 ms per pass, and calls
`updateWaveEnergy()` on every third pass.

```swift
var step: UInt8 = 0
while !Task.isCancelled {
    try? await Task.sleep(nanoseconds: 16_666_667)   // ~60 fps
    step = (step &+ 1) % 3
    if step == 0 { self?.updateWaveEnergy() }
    self?.waveClock.advance()
}
```

**Why not run everything at 60 Hz.** `updateWaveEnergy()` smooths the level
meters with an exponential moving average whose constants (attack 0.55, release
0.10) are tuned for a 20 Hz update. Running the same constants three times as
often makes the meters attack and release three times as fast. That is a
behaviour change to a part of the UI this release had no business changing, and
it would have been an unattributed regression in a stability update.

**Why not run everything at 20 Hz.** The waveform is a scrolling picture; at
20 Hz the sub-pixel offset of [D4](#d4-sub-pixel-scrolling-from-a-self-measured-interval)
is still correct but visibly coarse.

The `% 3` split keeps both at the rate they were designed for. The cost is one
counter variable.

---

## D4: sub-pixel scrolling from a self-measured interval

**Decision.** `WaveformBridge` measures the interval between its own `push()`
calls, smooths it, and reports a phase in `[0, 1]` alongside the samples. The
canvas requests one column more than it can show and translates the drawing left
by `phase * step`.

**Why a phase at all.** Because of the arithmetic in
[01-crash-analysis.md section 6](01-crash-analysis.md#6-defect-3-the-waveform-could-not-scroll-smoothly-by-arithmetic):
one column arrives per callback, 86.1 per second, 2.87 pt per frame at 60 fps,
and 2.87 is not a multiple of the 2 pt column width. No frame rate makes that
ratio integral. The fractional remainder has to be expressed as a drawing
offset or it shows up as a stutter.

**Why the ring buffer measures itself rather than being told the sample rate.**
Passing sample rate and buffer size down from the engine would have worked on
the day it was written. It would then have to be re-plumbed on every device
change, sample rate change and buffer size change, through three layers, and it
would be silently wrong whenever that plumbing was missed. Measuring the actual
arrival interval is correct by construction: whatever changes upstream, the
measurement follows within a fraction of a second.

**The smoothing constants, and why they are what they are.**

| Constant | Value | Reason |
|----------|-------|--------|
| EMA alpha | 0.1 | Time constant of about 10 callbacks, roughly 100 ms at 86 Hz. Short enough to absorb a rate or buffer change quickly, long enough that the scheduling jitter of one callback does not make the scroll speed visibly wobble, which is the entire point of the measurement |
| Lower plausibility bound | 0.5 ms | No real CoreAudio callback is that close together. 0.5 ms is 22 frames at 44.1 kHz or 96 frames at 192 kHz. Shorter intervals only occur on a warm restart or in test code |
| Upper plausibility bound | 250 ms | The largest common buffer, 4096 frames, takes 93 ms at 44.1 kHz. Anything above 250 ms is not a measurement, it is a gap: warm restart, paused playback, device change |

Implausible intervals are **discarded rather than smoothed**, because a single
outlier fed into an EMA with alpha 0.1 distorts the average for dozens of
callbacks afterwards, and the visible result would be a waveform that crawls for
a second or two after every pause. The timestamp is still updated even when the
interval is discarded, otherwise the next measurement would include the gap and
be implausible in its turn.

**Why samples and phase come from one call.** `frame(count:)` returns a
`WaveformFrame` containing both, read under the same `os_unfair_lock` section.
Two separate calls would save nothing and would allow a `push()` to land between
them, so the phase would already belong to the next column while the samples
still showed the previous one. The visible result would be the waveform jumping
back by a column.

**Why one extra column is requested.** The drawing is translated left by up to
one full column width. Without a spare column at the right edge, that translation
would open a gap of one column plus the offset. The spare column sits exactly at
the edge and moves in as the drawing shifts.

**Why the offset is applied to a copy of the context.**

```swift
var wave = ctx
wave.clip(to: Path(CGRect(origin: .zero, size: size)))
wave.translateBy(x: -shift, y: 0)
```

`GraphicsContext` is a value type, so the clip and the translation end with the
copy. The zero line is drawn beforehand on the original context and therefore
stays put, which is what makes the movement read as scrolling rather than as the
whole header sliding. The clip is applied **before** the translation, otherwise
the spare column would be drawn past the right edge.

**Defensive detail.** `lockedPhase()` returns 0 unless `elapsed > 0`. A `NaN`
fails that comparison and yields 0, which is exactly right: a non-finite phase
would become a non-finite translation and therefore a non-finite coordinate,
which is the class of problem this release exists to remove.

---

## D5: one call in the audio path, and why it is allowed

**Decision.** `CACurrentMediaTime()` is called inside `WaveformBridge.push()`,
which runs on the CoreAudio IOProc thread. This is the only change in this
release to code that executes in the realtime path.

**Why it is defensible.**

- `CACurrentMediaTime()` reads the Mach timebase, `mach_absolute_time()`
  underneath. It is not a syscall.
- It allocates nothing.
- It takes no lock of its own.
- It sits **inside the `os_unfair_lock` section that `push()` already held**. No
  second synchronisation point is introduced, and the section stays O(1) and
  allocation-free.

**Why it is recorded so prominently.** The project rule is that the audio path
is not touched, and a rule with an undocumented exception is a rule that erodes.
The exception is stated at the call site, in the commit message, and here, so
that a future reader can see it was a decision rather than an oversight.

**What would have happened otherwise.** Timestamping on the reader side, in the
canvas, measures when the MainActor got around to reading, not when the audio
arrived. That is precisely the jitter the measurement is meant to remove.

---

## D6: harden after the ring buffer, with `isFinite`

**Decision.** A new type,
[`WaveformGeometry`](../../v4/AudioRouterKit/Sources/AudioRouterKit/WaveformGeometry.swift),
sanitises sample values before any coordinate is computed. It runs on the
MainActor, after the ring buffer, never in the IOProc.

| Function | Guarantee |
|----------|-----------|
| `sanitize(_: Float32)` | Non-finite becomes 0, everything else is clamped to [-1, 1] |
| `sanitize(_: (min, max))` | Both components hardened |
| `normalizationAmplitude(_:)` | Always finite and >= 0, including for an empty array or for input that is entirely non-finite |

**Why `isFinite` and not `isNaN`.** Because `NaN` is not the problem.
`FanOutEngine` accumulates min and max with `<` and `>`, and a `NaN` loses both
comparisons, so it can never reach the ring buffer. An `Infinity` wins both and
enters cleanly, and `Inf / Inf` in the normalisation is what produces the `NaN`.
A guard against `NaN` at the input would have caught nothing at all. The full
derivation is in
[01-crash-analysis.md section 5](01-crash-analysis.md#5-defect-2-infinity-not-nan).

**Why clamping to [-1, 1] and not just rejecting non-finite values.** A sample
above 1.0 is possible when a source delivers beyond full scale. It is finite, so
it passes any finiteness check, and it draws the curve outside the header.

**Why in the kit rather than in the view.** It is pure arithmetic with no UI
dependency, so in `AudioRouterKit` it can be tested without bootstrapping a
window. 13 test cases cover it, see [04-verification.md](04-verification.md).

**Why after the ring buffer and not in the IOProc.** Two `isFinite` checks per
sample in the IOProc would be cheap but not free, and the realtime path is the
one place in this app where "cheap but not free" is an argument that has to be
won rather than assumed. On the MainActor the cost is irrelevant, and the
guarantee is identical because every path to a coordinate goes through here.

**The guard is stated positively.** This is the form that shipped:

```swift
guard yMax.isFinite, yMin.isFinite, yMin - yMax >= 1 else {
    path.move(to: CGPoint(x: x, y: midY - 0.5))
    path.addLine(to: CGPoint(x: x, y: midY + 0.5))
    continue
}
```

The safe branch is now the default. The real column is drawn only when both
coordinates are finite and the column is at least 1 pt tall. The 4.0.0 form,
`if yMin - yMax < 1 { correct }`, took the unchecked branch whenever a value was
`NaN`, which is exactly when it should not have.

---

## D7: smooth the normalisation reference across frames

**Decision.** `WaveNormalizer` (in
[`WaveClock.swift`](../../v4/AudioRouterNow4/UI/WaveClock.swift)) holds the
normalisation divisor across frames and smooths it: attack 0.5, release 0.04.

**Why.** The canvas normalises the curve against the loudest column in the
visible window so that quiet passages still use the height. Until 4.0.1 that
reference was recomputed from scratch on every frame. When a loud transient
scrolls into the visible window, or out of it at the right edge, the reference
jumps, and the height of the *entire* curve jumps with it. It reads as breathing
or twitching, and it is easily mistaken for the stutter of
[D4](#d4-sub-pixel-scrolling-from-a-self-measured-interval), which is a different
problem with a different cause.

**Why these constants.** Fast attack so that a sudden transient is not clipped
at the top. Slow release, 0.04, which is a time constant of roughly 0.4 s at
60 fps: long enough that one loud hit leaving the window is not noticeable,
short enough that a signal which genuinely gets quieter does not stay squashed
for minutes. It is the same shape as the level meters, deliberately, so that the
two parts of the header behave consistently.

**Three details that are easy to get wrong.**

- Below 0.001 the value is snapped to 0, otherwise a residual epsilon would
  linger and the canvas silence detection (`maxAmp < 0.01`) would never engage.
- `WaveNormalizer` is a reference type, because the `Canvas` draw closure cannot
  mutate a view struct, and writing to it deliberately does **not** invalidate
  the view. Invalidating from inside a draw pass would loop.
- It is reset when routing stops, so the next session does not start with the
  scale of the previous one and appear briefly too flat or too tall.

---

## D8: leave the device poll ungated

**Decision.** The 3 second device enumeration in `MenuBarView` is **not** gated
on panel visibility. It runs continuously, as it did in 4.0.0.

**Why, given that section 4 of the analysis names it as a cost.** A gate existed
in the discarded intermediate version and was removed along with it. It depended
on the same panel visibility signal that could not be determined reliably, and
the failure mode is asymmetric:

| Gate fails | Consequence |
|------------|-------------|
| Wrongly open | CoreAudio is enumerated every 3 s with nobody watching. This is 4.0.0 behaviour |
| Wrongly closed | The device list freezes. Plugging in an interface does nothing, and the user has no way to tell why |

A frozen device list in an audio routing app is a functional failure. Polling
without an audience is a waste. Given a signal that had already been shown to be
unreliable twice, the waste is the smaller harm.

The reasoning is left as a comment at the `.task` loop itself, so that the next
person to notice the ungated poll finds out it was considered rather than
missed.

`onAppear` calls `refreshAvailableDevices()` once explicitly, so the list is
current the moment the panel opens rather than up to three seconds stale.

---

## D9: a bug report button

**Decision.** A `ladybug` icon button in the footer opens a pre-filled `mailto`
draft through `NSWorkspace.open`, with a GitHub Issues fallback.

**Why it is in a crash fix release.** Five crashes reached the developer through
an aggregated chart, two weeks after the fact, from one user who had no way to
say what he had been doing. The app had no contact path at all: the footer held
Launch at Login, Support and Quit, and the Help menu that v3 had did not survive
the rewrite. The fix for that gap belongs in the same release as the crash it
made harder to diagnose.

**What the draft contains, and what it deliberately does not.**

| Included | Excluded | Reason for exclusion |
|----------|----------|----------------------|
| App version and build | **Device names** | Audio devices are routinely named after their owner. The count alone is enough for diagnosis |
| macOS version | **`ProcessInfo.systemUptime`** | A required-reason API. Including it would force a `PrivacyInfo.xcprivacy` entry, and the diagnostic value does not justify that |
| Hardware model via `sysctl hw.model` | | CoreAudio behaves differently on Apple Silicon than on Intel, and buffer sizes differ by model line |
| Number of configured outputs | | |
| Routing state (`idle`, `starting`, `routing`, `error`) | | |

**Why `mailto` and `NSWorkspace.open`.** It is the only mechanism that works
inside the App Sandbox without an additional entitlement, and it is the pattern
`openTCCSettings()` already used. Nothing is transmitted until the user presses
send in their own mail client.

**Why a fallback is not optional.** `NSWorkspace.open` returns `false` when no
mail client is configured. Without the fallback the click would simply do
nothing, which is worse than no button.

**Why an icon and not a labelled button.** The footer row has no horizontal
space left for text at the panel's 320 pt width.

---

## D10: keep `.drawingGroup()` for now

**Decision.** `.drawingGroup()` stays on the canvas.

**Why.** It is an amplifier, not a cause; a `NaN` in a `CGPoint` is defective
with or without Metal. Removing it would measurably degrade drawing quality, and
without a reproduction measurement there would be no evidence that it helped.
Changing two things at once in a release whose effect can only be judged
statistically would also make the statistics unreadable.

**What would settle it.** A reproduction in Instruments, comparing the canvas
with and without the Metal pass. That measurement does not exist yet and is
listed as open in [04-verification.md](04-verification.md).

---

## D11: accept that build 8 resets "Launch at Login"

**Decision.** `CURRENT_PROJECT_VERSION` moves from 7 to 8, which invalidates
every stored Launch at Login consent. Existing users have to enable the setting
once more after updating.

**Why this is not a regression.** `hasValidLaunchAtLoginConsent()` validates the
stored consent against the current build number:

```swift
return optedIn == true && consentBuild == currentBuildNumber
```

That binding is the mechanism, not an accident of the bump. It is what prevents
a Login Item registration from surviving an app update without fresh consent,
which is what Guideline 2.4.5(iii) requires and what 4.0.0 was reworked for.

**Why it is nonetheless called out everywhere.** A setting that silently turns
itself off looks exactly like a bug to the person it happens to. It is stated in
the changelog, in the release notes, and here.

---

Next: [03-discarded-approaches.md](03-discarded-approaches.md)
