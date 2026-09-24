# 03: Approaches that were discarded

[Back to the index](README.md) · Previous: [02-decisions.md](02-decisions.md) · Next: [04-verification.md](04-verification.md)

---

This document exists so that nobody, including the author in a year, tries any
of these again without knowing what happened the first time.

Two of the three were written, compiled and tested. They are in the git history
as commit `dc59f98`, which commit `db1ecb4` deletes. The third was rejected at
the design stage on arithmetic grounds.

---

## The shape of the problem

`MenuBarExtra(.window)` does not tear down its view tree when the panel closes.
Anything self-ticking inside that tree keeps ticking until the process exits.
The obvious response is: find out whether the panel is open, and pause when it
is not.

Both discarded approaches are variants of that response. Both failed, and they
failed in the same direction, which is the worst possible direction: the
waveform froze **while the panel was open and visible**, with the level meters
and the callback counter still updating next to it. That is not a degraded
version of the bug, it is a worse bug, because a stalled waveform in a visible
panel looks like the app has hung.

---

## A1: pause on the panel window's key status

**What was built.** A `PanelVisibility` object, a `@MainActor ObservableObject`
with a `@Published private(set) var isVisible`. A `PanelWindowProbe`, an
`NSViewRepresentable` with no drawing and no intrinsic size, sat in the
`.background` of `MenuBarView` and reported the real `NSWindow` up through
`viewDidMoveToWindow()`. Both directions were then observed, filtered to that
one window object:

| Direction | Signal |
|-----------|--------|
| Up | `NSWindow.didBecomeKeyNotification`, `object: panelWindow` |
| Down | `NSWindow.didResignKeyNotification`, `object: panelWindow` |
| Initial sync | `window.isKeyWindow` at attach time |

`TimelineView(.animation)` became
`TimelineView(.animation(minimumInterval:paused:))`, with

```swift
private var isPaused: Bool {
    !panelVisibility.isVisible || controlActiveState == .inactive
}
```

The construction was careful. It used no private API, it filtered the
notification by window object so that an `NSAlert` taking key status could not
latch it off permanently, and it paired every down signal with an up signal. An
earlier draft of it had neither of those properties and was corrected in audit
before it ever ran.

**Why it failed anyway.** The careful construction answered the wrong question.

**Key status is not visibility.** A window can be visible without being key. For
an `LSUIElement` app that is the normal case, not an edge case: clicking the
menu bar item shows the panel, but it does not necessarily activate the app, and
an unactivated app does not own the key window. The panel was open, on screen,
in front of the user, and not key.

The `@Environment(\.controlActiveState)` term in the pause condition doubled the
same mistake rather than compensating for it. `controlActiveState` reports
whether the *app* is active, and an `LSUIElement` app showing a menu bar panel
frequently is not.

**Symptom.** With music playing and the panel open, the waveform sat frozen
while the level meters beside it moved and the callback counter incremented.

**How it was caught, and why that matters.** The behaviour was not caught by a
test or by reasoning about the API. It was caught because the waveform would
briefly come alive at an odd moment: whenever a screenshot was taken. Taking a
screenshot momentarily pulls activation away and hands it back, and that handoff
produced the key-status transition the code was waiting for. A bug that only
animates when you try to photograph it is a bug that will not be reproduced by
staring at it, and it is worth noting that the diagnosis came from paying
attention to an incidental observation.

---

## A2: pause on `occlusionState`

**What was tried.** The same structure as A1, with `NSWindow.occlusionState` and
`NSWindow.didChangeOcclusionStateNotification` in place of key status.

**Why it looked right.** `occlusionState` asks the question that was actually
meant: is any part of this window visible to the user? It is backed by a
notification rather than requiring KVO on a property with no documented
observability guarantee. Semantically it is the correct choice, and if any
window-state approach were going to work, it would have been this one.

**Why it failed.** It proved unreliable for this particular panel in practice.
The waveform flickered briefly and then stood still again. The `.visible` flag
did not track the panel's ordering in and out in a way that could be depended
on.

No deeper root cause was established, and this document deliberately does not
invent one. What is established is the observed behaviour, twice, on the
development machine.

---

## The conclusion that survived

> The window state of a `MenuBarExtra` panel is not a dependable source, and the
> fix must not need it.

That sentence is why the shipped solution has no visibility detection in it at
all. `PanelVisibility`, `PanelWindowProbe` and the `paused:` parameter were all
deleted. The canvas is driven by a tick that the audio poll advances, and that
poll's lifetime is tied to routing rather than to any window
([D1](02-decisions.md#d1-remove-the-timeline-instead-of-pausing-it)).

The device poll gate went out with them, for the same reason
([D8](02-decisions.md#d8-leave-the-device-poll-ungated)).

There is a second lesson underneath the first, and it is more general:

> A diagnosis that declares the SwiftUI lifecycle unreliable cannot then use the
> SwiftUI lifecycle as its signal source.

The first draft of A1 did exactly that. It argued at length that the view tree
is never torn down, and then took its up signal from `onAppear`, which fires
only once for precisely that reason. The diagnosis refuted its own fix. That was
caught in audit and corrected to the window-bound form described above, which
then failed for the independent reason that key status is not visibility.

---

## A3: push more pairs per callback

**What it was.** Raise the time resolution of the waveform by having the IOProc
push several `(min, max)` pairs per CoreAudio callback instead of one, splitting
each callback's frames into sub-blocks.

**Why it was proposed.** It looks like the direct fix for the stutter of
[defect 3](01-crash-analysis.md#6-defect-3-the-waveform-could-not-scroll-smoothly-by-arithmetic):
more data points, finer granularity, smoother motion.

**Why it is wrong.** It makes the problem worse, and the arithmetic says so
before any code is written. Each pair occupies one 2 pt column. Doubling the
pairs per callback doubles the number of columns arriving per second, which
doubles the scroll speed:

| Pairs per callback | Columns/s at 44.1 kHz, 512 frames | Scroll speed | Required advance at 60 fps |
|--------------------|-----------------------------------|--------------|----------------------------|
| 1 | 86.1 | 172.2 pt/s | 2.87 pt |
| 2 | 172.2 | 344.4 pt/s | 5.74 pt |
| 4 | 344.4 | 688.8 pt/s | 11.48 pt |

The required advance per frame rises in proportion, and it is no more likely to
land on a multiple of the column width than before. More columns per frame means
**more** jumps per frame, not fewer. The only thing that changes is that a
waveform showing about 1.9 seconds of audio now shows about 0.95, and then 0.48.

It would also have meant new work inside the IOProc, which the rest of this
release went out of its way to avoid
([D5](02-decisions.md#d5-one-call-in-the-audio-path-and-why-it-is-allowed)).

**What actually fixes it.** Expressing the fractional remainder as a drawing
offset rather than trying to make it disappear
([D4](02-decisions.md#d4-sub-pixel-scrolling-from-a-self-measured-interval)).

---

## Also tried and abandoned: raising the frame rate

Worth stating explicitly because it is the first thing anyone tries. The
redraw rate was raised from 20 fps to 60 fps to see whether the stutter would
smooth out. It did not, and it cannot: no frame rate makes 172.2 pt/s divide
evenly into 2 pt columns. The 60 fps rate was kept for other reasons
([D3](02-decisions.md#d3-poll-at-60-fps-meter-at-20-hz)), not because it helped
here.

---

Next: [04-verification.md](04-verification.md)
