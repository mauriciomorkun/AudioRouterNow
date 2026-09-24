# 01: The crash, and what could be derived from it

[Back to the index](README.md) · Next: [02-decisions.md](02-decisions.md)

---

## 1. What arrived

App Store Connect aggregated five crash reports for AudioRouterNow 4.0.0
(build 7). They were received on 22 September 2026.

| Field | Value |
|-------|-------|
| Reports | 5, all with the same signature |
| Distinct devices | 1 |
| Dates | 13 to 16 September 2026 |
| OS | macOS 26.6.2 |
| Architecture | ARM64 |
| App version | 4.0.0, build 7 |
| Total downloads at that point | 21 |

One user out of twenty-one, crashing five times over four days, with no way to
tell anyone. That last detail is why 4.0.1 also contains a bug report button
(decision [D9](02-decisions.md#d9-a-bug-report-button)).

## 2. What did not arrive

**The raw `.ips` was never available.** That means the following were missing,
and still are:

- the symbolicated stack trace with concrete frames and offsets,
- the exception subtype and the faulting address,
- the state of the other threads,
- the distribution across macOS builds and hardware models,
- the number of affected sessions rather than reports.

This is the single most important qualification in this folder. Everything
below is **derived from reading the source against the crash grouping**, not
proven from the report. Each defect described is real and independently
justified. That they are *the* defect behind those five reports is a hypothesis.
See [04-verification.md](04-verification.md) for the full list of open items.

## 3. What the grouping did show

The crash grouping placed the terminating frames in AppKit:

```
__NSWindowGetDisplayCycleObserver
  -> NSDisplayCycleObserverInvoke
       -> NSDisplayCycleFlush
```

with an uncaught Objective-C exception as the termination reason.

Two facts follow from that, and they are what narrowed the search:

1. **The display cycle is per window.** `__NSWindowGetDisplayCycleObserver`
   retrieves the observer belonging to one specific `NSWindow`. Whatever went
   wrong went wrong while AppKit was flushing that window's display cycle.
2. **The audio path is not implicated.** Nothing in the `FanOutEngine` IOProc,
   `DelayLine`, `SlotGains` or `PeakMeters` runs inside a display cycle flush.
   The audio path was read, but not modified, in this release.

In 4.0.0 there was exactly one thing in the app that registered itself as a
display cycle observer: the `TimelineView(.animation)` driving the waveform
canvas in the menu bar panel.

```
TimelineView(.animation)          <- registers a display cycle observer on the window
  └── Canvas { ctx, size in ... } <- coordinates are computed here
        └── .drawingGroup()       <- Metal compositing, its own render pass
```

That is the whole search space, and all three defects below sit inside it.

---

## 4. Defect 1: an animation that outlived the thing it was animating

### The mechanism

`TimelineView(.animation)` asks AppKit to call it back once per display cycle of
the window it lives in. That is exactly the frame the crash report points at.

On its own that would be unremarkable: a view that animates while it is on
screen. The problem is the container.

**`MenuBarExtra(.window)` does not tear down its view tree when the panel
closes.** It calls `orderOut()` on the panel window. The SwiftUI view tree stays
alive, fully constructed, for the remaining lifetime of the process.

The evidence for this is in the app's own code rather than in documentation. The
device poll in `MenuBarView` is a `.task` loop, and SwiftUI binds `.task` to the
lifetime of the view. If the tree were torn down, that loop would be cancelled
on close and restarted on the next open. It was not: it ran continuously from
first open until quit. Since `.task` survived, so did everything else in that
tree.

So in 4.0.0:

| Consumer | Rate | Ran with the panel closed |
|----------|------|---------------------------|
| `TimelineView(.animation)` in `WaveHeaderView` | up to 60 fps, unbounded | yes, indefinitely |
| `.task` device poll in `MenuBarView` | every 3 s | yes, indefinitely |

### Why this matters for a crash rather than just for battery

An animation that keeps driving a window's display cycle while that window is
being ordered out, reconfigured, or moved between displays is running at exactly
the moments when window state is in flux. It does not itself prove a crash, but
it is what puts a defective drawing path (defect 2) into the display cycle over
and over, unattended, for hours.

It is also the reason the bug was so hard to catch by ordinary use: nothing
visible was happening. The panel was closed.

### Why there is no simple SwiftUI answer

`onDisappear` does not fire reliably for this panel, because nothing disappears
in SwiftUI's model. There is no SwiftUI signal equivalent to "the panel was
closed". Two attempts to obtain that signal from AppKit instead are documented
in [03-discarded-approaches.md](03-discarded-approaches.md); both failed, and
the shipped fix does not need the signal at all.

---

## 5. Defect 2: Infinity, not NaN

This is the subtlest part of the case, and the part most likely to be got wrong
by someone reading quickly.

The intuition "a `NaN` sample poisoned a `CGPoint`" is nearly right and
completely useless, because **a `NaN` sample can never reach the drawing code**.
An `Infinity` can, and it *produces* the `NaN` further downstream.

### Step 1: why no NaN enters the ring buffer

`FanOutEngine` reduces each CoreAudio callback to one `(min, max)` pair using
plain comparisons ([`FanOutEngine.swift`](../../v4/AudioRouterKit/Sources/AudioRouterKit/FanOutEngine.swift),
in the IOProc):

```swift
var wMin: Float32 = 0
var wMax: Float32 = 0
for i in 0..<frameCount {
    let mono = (L[i] + R[i]) * 0.5
    if mono < wMin { wMin = mono }
    if mono > wMax { wMax = mono }
}
```

Every comparison involving `NaN` is false. A `NaN` sample therefore loses `<`
*and* `>` and is never written into `wMin` or `wMax`. It is silently discarded
by the accumulator.

`+Infinity` wins every `>` comparison and `-Infinity` wins every `<`. They land
in the ring buffer cleanly.

### Step 2: how the Infinity becomes a NaN

The canvas normalised the visible snapshot against its loudest column, so that
quiet passages still use the available height:

```swift
let maxAmp = samples.reduce(Float32(0)) { acc, s in max(acc, abs(s.max), abs(s.min)) }
let nMax = CGFloat(sample.max / maxAmp)
```

One `Inf` anywhere in the snapshot makes `maxAmp` equal to `Inf`. And
`Inf / Inf` is `NaN`. From that division onwards, **every** derived
y-coordinate in the frame is `NaN`, not just the one from the bad sample.

A single bad sample poisons the entire visible waveform, and keeps poisoning it
for as long as that sample remains inside the ring buffer window, which at 256
columns and roughly 86 pushes per second is about three seconds of frames.

### Step 3: why the existing guard did not fire

There was a guard. It was meant for exactly this class of problem:

```swift
if yMin - yMax < 1 {          // false whenever either value is NaN
    yMax = midY - 0.5
    yMin = midY + 0.5
}
```

`NaN - NaN` is `NaN`, and `NaN < 1` is **false**. The corrective branch was
skipped precisely in the case it was written for, and the `NaN` went straight
into `CGPoint(x: x, y: yMax)`.

### The generalisable lesson

A negatively phrased floating-point guard, `if <bad> { correct it }`, is unsafe.
`NaN` makes every condition false and therefore always selects the unchecked
branch. State the condition positively so that the safe branch is the default:

```swift
guard yMax.isFinite, yMin.isFinite, yMin - yMax >= 1 else {
    // safe fallback: a 1pt tick on the zero line
    continue
}
```

That is the form shipped in 4.0.1. The hardening itself lives in
[`WaveformGeometry`](../../v4/AudioRouterKit/Sources/AudioRouterKit/WaveformGeometry.swift)
and uses `isFinite`, not `isNaN`, for the reason set out above.

### Where an Infinity could come from

This was not chased to a specific source, and the fix does not depend on
knowing. A tapped process emitting a denormal or a non-finite float, a tap
reconfiguration producing a partially initialised buffer, or arithmetic in a
source app are all candidates. The hardening is at the boundary where the value
becomes a coordinate, which is the right place regardless of origin.

---

## 6. Defect 3: the waveform could not scroll smoothly, by arithmetic

This defect was found by hand while verifying the fix for defect 1, not from the
crash report. It is not a crash, it is a visible stutter, and it is included
here because it is structural rather than a coding mistake.

The IOProc pushes **exactly one column per CoreAudio callback**. At 44100 Hz
with a 512 frame buffer:

| Quantity | Value |
|----------|-------|
| Callbacks per second | 44100 / 512 = 86.1 |
| Column width | 2 pt |
| Scroll speed | 86.1 x 2 = 172.2 pt/s |
| Required advance at 60 fps | 172.2 / 60 = 2.87 pt per frame |

2.87 is not a multiple of the 2 pt column width. With whole-column stepping the picture could only
advance by one column on some frames and two on others, in an irregular pattern.
That alternation is what was visible as stutter.

**Raising the frame rate does not help.** It was tried, from 20 fps to 60 fps,
with no improvement. Nothing about the ratio becomes integral at a higher rate;
the fractional remainder just changes size. The fraction has to go somewhere,
and the only place it can go is into the drawing offset. That is what the
sub-pixel phase in
[`WaveformBridge`](../../v4/AudioRouterKit/Sources/AudioRouterKit/WaveformBridge.swift)
does, see decision [D4](02-decisions.md#d4-sub-pixel-scrolling-from-a-self-measured-interval).

A third approach, pushing more pairs per callback to raise the time resolution,
was considered and rejected. It makes the problem worse, not better;
[03-discarded-approaches.md](03-discarded-approaches.md#a3-push-more-pairs-per-callback)
explains why.

---

## 7. `.drawingGroup()`: amplifier, not cause

`.drawingGroup()` renders the canvas through Metal into an offscreen buffer.

It is **not** the cause. A `NaN` in a `CGPoint` is defective with or without
Metal. It is plausibly an amplifier: the separate render pass runs independently
of the surrounding layout and widens the window in which a defective path is
actually rasterised.

It was deliberately **left in place**. Removing it without a reproduction
measurement would be guessing, and it would measurably degrade drawing quality.
The decision is deferred until a reproduction exists, see
[D10](02-decisions.md#d10-keep-drawinggroup-for-now) and
[04-verification.md](04-verification.md).

---

## 8. What was explicitly not changed

| Area | Reason |
|------|--------|
| The IOProc and the realtime path | The crash is in the display cycle. All hardening happens after the ring buffer, on the MainActor |
| Signing, entitlements, StoreKit, `Info.plist`, `PrivacyInfo.xcprivacy` | Out of scope. Any change there lengthens App Review |
| `ensureLoginItemCompliance()` and the consent keys | Guideline 2.4.5(iii). The mechanism is review-proven and was not touched |
| `.drawingGroup()` | See section 7 |

The one exception to "do not touch the audio path" is a single
`CACurrentMediaTime()` call inside an already existing lock section, which is
argued in detail in [D5](02-decisions.md#d5-one-call-in-the-audio-path-and-why-it-is-allowed).

---

Next: [02-decisions.md](02-decisions.md)
