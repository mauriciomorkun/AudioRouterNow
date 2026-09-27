# CASE-004: applying the volume once instead of twice

This document was written before the code was changed, and it is not edited
afterwards to look smarter than it was. One argument in it was wrong, and the
record of how it was refuted is the most useful part.

## The defect

`FanOutEngine.swift` applies `vol`, the volume scalar of the **default output
device**, to every output slot:

```swift
let targetSV = vol * g
```

For a fan-out target that is a deliberate remote control. For the default device
itself it is a second application of a factor its own hardware applies a moment
later.

```
Output(D) = Tap x vol(default device) x hardware volume(D)
```

The default device is the one case where the second factor **is** `vol`, so the
result is `vol²`. That is why the defect hits exactly the device the volume keys
move, and only that one.

## Why it counts as proven rather than suspected

The error in dB is the distance between `vol` and `vol²`:

```
error(vol) = -20 x log10(vol)
```

| `vol` | Predicted | Measured by the reporter |
|------:|----------:|-------------------------:|
| 100 % | **0,00 dB** | no difference |
| 30 % | **10,46 dB** | **about 10,5 dB** |

The reporter set the value with `set volume output volume 30` rather than
pressing a key, so the input was exact. A deviation of 0,04 dB does not confirm
a direction, it confirms the **shape** of the function. A DSP or buffer fault
would not vanish at unity gain. This one does.

He also brought a control group in a single session: a USB speaker with its own
dial showed no gap, a monitor without a dial showed no gap, the internal speakers
showed the gap. The dividing line is not the operating system and not the device
class, it is "is this the default device".

## What the fix is not

Reducing the line to `let targetSV = g` would be a second defect, not a fix.

| Case | Without `vol` | Consequence |
|---|---|---|
| Fan-out target with no dial of its own (monitor, HDMI) | sits at full scale | routing plays there at **full blast** |
| Default device in software volume mode | no hardware factor exists | the system volume stops working entirely |

The decision has to be made per slot.

## The chosen approach

`VolumeTracker` already distinguishes what is needed. It carries
`hasHardwareVolume`, which separates devices with a hardware dial from those
where the app's own slider stands in. That knowledge just never reached slot
level.

1. `VolumeTracker` exposes `hasHardwareVolume` for build time, read through its
   own serial queue.
2. `buildAndStartAggregate` derives a `[Bool]` per slot: the slot that **is** the
   default device and has a hardware dial gets factor `1.0`, everything else gets
   `vol`.
3. The array is passed into the IO block by value.
4. The one line becomes `effectiveVol * g`.

Matching is done on `uid == defaultOutputUID && channelOffset == 0`, **not** on
the slot index. Slot 0 is not reliably the default device: when another device
wins the master role in the aggregate, its slots come first. The channel offset
matters because `kAudioDevicePropertyVolumeScalar` governs only the primary
stereo pair, so channels 3 and 4 of the same device still need `vol` as a proxy.

## The argument that was wrong

A review of the plan raised what looked like a serious objection. A change of
default device only triggers a rebuild after a debounce of 2 seconds
(`DeviceLifecycleManager`, `btSettleDelay = 2.0`), and a pending rebuild is
cancelled by the next change, so repeated switching holds the window open
indefinitely. During that window the slot list is stale. The objection was that
the former default device would jump **up** by 10,5 dB, and that the fix would
therefore introduce a regression louder than the bug it removes.

It does not, and the arithmetic is short:

```
post-fix, slot with appliesVol == false:   sw = 1.0 * g     (constant)
```

That slot carried factor `1.0` **before** the switch as well, because it was the
default device with a hardware dial. It carries `1.0` after. A constant factor
cannot produce a jump. The objection had compared the pre-fix world with the
post-fix world, which is a comparison between two versions, not between two
points in time.

It inverts, in fact. **Before** the fix that same slot carries `vol(t) * g` and
therefore follows the dial of the newly selected device. The jump exists there.
The fix removes a level jump that nobody had reported.

## What does remain

The asymmetry itself is real and had not been written down:
`VolumeTracker.onDefaultDeviceChanged()` has **no** debounce, so `vol` follows
the new device within milliseconds while the slot list lags by 2 seconds. The
result is not a jump but a state held too long.

Which raises a question worth recording, because it points somewhere else. In
that window the former default plays at `1.0 x its own hardware`, respecting its
own setting. After the rebuild it plays at `vol_new x its own hardware`, damped
by the dial of a device it has nothing to do with. **The window may well be more
correct than the state that follows it.**

That undermines a premise held elsewhere, namely that fan-out targets sit at full
scale. For a device that was the default one second earlier, it is false. This
belongs to the open question about whether `kAudioDevicePropertyVolumeScalar` may
be treated as a linear amplitude at all, and it is deliberately not addressed
here.

## The approach that was rejected

Deciding per callback at run time instead of once at build time. Rejected, and
not for economy of lines.

It reintroduces precisely the fault the objection was worried about. During the
window the new default device is not yet a sub-device of the aggregate, so no
slot matches, so every slot flips to `appliesVol = true`, and the former default
drops by 10,5 dB **mid-stream**, traversed in roughly 10,7 ms at 512 frames and
48 kHz. Not a click, but an audible dip. The build-time variant has no level
change at that moment at all, and the change that does occur is deferred into the
silence of the full restart, where nothing can be heard.

It would also have to compare `AudioObjectID` values, because strings are barred
from the IO thread, and that identifier is documented in this codebase as
volatile precisely because slot identity is UID based. After a disconnect and
reconnect an identifier can be handed to a different device, and a false match
sets `appliesVol = false` on the wrong slot. That is the loud failure direction.

| | Build time | Run time |
|---|---|---|
| Lines | **~17** | ~47 |
| Mid-stream level change in the window | **none** | 10,5 dB over ~10,7 ms |
| New invariants to uphold | **none** | identifier freshness, snapshot atomicity |

## Verification, fixed before the work started

Three unit tests, free of CoreAudio and therefore suitable for CI, because the
assignment is a pure array transformation: default device with a dial, default
device without one, and the same device UID at channel offset 2.

Everything else needs hardware. The cases below are the ones that decide whether
this shipped correctly, and the last one exists to keep the boundary clean.

| Case | Expected |
|---|---|
| Default device with a dial at 30 % | **0 dB** difference, was 10,5 dB |
| Default device with a dial at 10 % | 0 dB, was about 20 dB |
| Default device **without** a dial (HDMI) | the app slider still changes the level |
| Fan-out target without a dial | plays at the `vol` level, not at full blast |
| Fan-out target with its own dial | no regression |
| Change of default device at low volume | on the former default, **no upward jump at any moment**, level constant through the window |
| Switching repeatedly inside 2 seconds | no jump, no accumulation, correct level 2 seconds after the last change |
| Change onto a device without a dial | a jump on the fan-out target is possible and **pre-existing**, to be measured against the unpatched build in the same session so it is not attributed to this fix |
| Mute | silence on every slot |

## Abort conditions, agreed in advance

CASE-004 gets a version of its own rather than being forced into this one if any
of the following holds.

1. `buildAndStartAggregate` reads the hardware-volume flag before the tracker has
   established it and therefore always sees the default. Symptom: no effect on a
   device without a dial.
2. More than one slot matches the default UID at channel offset 0.
3. The rebuild produces an audible click rather than the expected silence gap.
4. **The measurement on the former default device does show an upward jump.** Then
   the reasoning above is wrong, a path exists that changes the assignment during
   the window, and the defect is not what it is described to be here.

## Still unproven

Whether macOS leaves the hardware volume of the internal speakers untouched when
headphones are plugged in. The reasoning treats that factor as constant across
the switch. Only measurable at the machine, which is the first hardware case in
the table above.
