# CASE-004: the closing report

Written after the work, as the final step of the agreed procedure. The plan is in
[05-volume-plan.md](05-volume-plan.md) and was written before any code changed.
This document records what actually happened, including the parts where the plan
and the reviews were wrong.

## Result

The system volume is applied once instead of twice. On the default output device
the signal is no longer attenuated by a factor its own hardware applies anyway.

| | |
|---|---|
| Version | 4.0.1, build 9. **Not tagged, not submitted** |
| Commits | `4a0f6c1`, `c9e097d` |
| Source changes | `FanOutEngine.swift`, `VolumeTracker.swift` |
| Tests | 23 in the XCTest suite, 15 of them for this defect, plus 59 in the swift-testing suite |
| Rounds | Three, the maximum allowed |

## What was found on the way

The interesting part of this work was not the fix. It was three things the fix
exposed, each of which had been invisible.

### Mute hung on the same thread, in the opposite direction

`VolumeTracker` encodes mute as a volume of zero. It carries no separate mute
state. So the naive fix, giving the default slot a flat factor of one, would have
removed the software mute from exactly that device and left silence depending on
the hardware mute reaching through an aggregate sub-device, which is not
established anywhere.

This is the same mechanism as the defect itself, mirrored:

| | Volume | Mute |
|---|---|---|
| Applying it twice | **the defect** | **possibly the protection** |
| Removing the duplication | too quiet | **sound while the mute key is lit** |

So the duplication was removed only where it provably does harm. The guard is one
expression, `(appliesVol || vol <= 0) ? vol : 1.0`, and it deliberately compares
against zero rather than reading a dedicated mute flag. A flag would read false on
a device that has no mute control at all, where macOS mutes by writing a volume of
zero, and would miss that case entirely.

### The tests were green against the wrong things, twice

The first three tests all placed the default device at index zero. They therefore
passed under the exact implementation the plan forbids, matching on the slot index
instead of the device identifier. The central design decision was covered by
nothing.

This was not established by reading the tests. It was established by deliberately
building the faulty implementation and running the suite against it. That practice
was introduced in round two and kept:

| Fault introduced deliberately | Tests that fail |
|---|---|
| Matching on index instead of identifier | 3 |
| Mute branch removed | 1 |
| Out of range fallback flipped to the loud direction | 2 |
| **IO callback bypasses the computed factor** | **0** |

### The last row is the finding that did not get fixed

A review found that the original defect can be reintroduced by writing the old
expression in the IO callback again, bypassing the computed factor, without any
test noticing. Its recommendation was to extract a third pure function, which
would catch it.

That was implemented, then measured. **The recommendation was wrong.** The
mutation survives the extended suite too.

The reason is structural and worth carrying forward: a test that calls the
function bypasses the very wiring it is meant to check. It cannot tell whether the
IO callback uses that function. No unit test can, at any granularity, because
"does the caller call the callee" is not a question about a function.

What actually covers this case is the listening check at 30 percent. An ineffective
wiring would have left the full gap in place, plainly audible. This is the reason
the hardware check is not a formality that repeats what the tests already say. For
one class of fault it is the only check that exists.

## Two things the reviews got wrong

Recorded because both sounded convincing.

**An upward jump after a device change.** The objection was that the fix would
leave the former default device playing 10,5 dB louder for the two seconds before
the rebuild. It does not. After the fix that slot carries a constant factor before
and after the change, and a constant cannot produce a jump. The comparison was
between two versions of the program, not between two points in time. Before the
fix that slot follows the dial of a device it has nothing to do with, so the fix
**removes** a jump nobody had reported.

**Two verification steps that could not verify anything.** A level measurement was
demanded to establish "exactly 0 dB". But the factor can only take two values,
`vol` or one, so a small residual error is structurally impossible: either the fix
applies and the gap is exactly zero, or it does not and the gap is the full 10,5 dB.
The question is binary, and an ear settles a binary question at that margin. A test
on a device without a hardware dial was also demanded, until it was worked through:
in that branch the code is character for character what it was before the fix.
Neither check was dropped for convenience. Neither could produce information.

## What is proven, and by what

| Claim | Established by |
|---|---|
| The cause is a second application of the same factor | Arithmetic against the reporter's measurement, agreeing to within 0,04 dB, plus his three output control group in one session |
| At most one slot ever skips the factor | The deduplication key in the output list, proven by construction rather than by cases |
| The hardware flag is read after it is established | `tracker.start()` is synchronous and precedes the build |
| No allocation, no reference counting, no lock in the IO callback | The optimised machine code was read, not assumed |
| The gap is gone at 30 percent | Listening check on the development machine, against a build of the previous state |
| Mute still silences every output | Listening check |

## What is not proven

The listening checks ran on one machine with one default device. Nothing is known
about other hardware, and nothing needs to be: the branch for devices without a
hardware dial is unchanged code.

Whether the hardware mute would have reached through on its own is still open.
It does not matter for shipping, because the guard stays either way, and it covers
devices with no mute control at all, for which a hardware mute does not exist by
definition.

Whether `kAudioDevicePropertyVolumeScalar` may be treated as a linear amplitude at
all is untouched. Apple documents it as non linear. If it follows a curve, the
factor applied to fan-out targets is imprecise, which is a separate defect with a
separate fix, and it was kept out of this work on purpose.

## The reporter

The cause is known rather than suspected because a user in the MacRumors thread
measured instead of describing. He set exact volume levels with AppleScript rather
than pressing a key, and he assembled a control group of three outputs in a single
session, which is what ruled out the operating system and the device class as
explanations.

A report saying "routing sounds quieter" would have produced a search. His report
produced a number, and the number matched the arithmetic of a specific line of
code.
