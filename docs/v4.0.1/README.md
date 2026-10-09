# AudioRouterNow 4.0.1: the full record

This folder documents the first update after the App Store launch of
AudioRouterNow 4. It exists because the interesting part of 4.0.1 is not what
shipped, it is *why* that shipped and what was written, tested and thrown away
first.

The changelog tells you what changed. The release notes tell you what it means
for you. This folder tells you how the decisions were reached, which assumptions
turned out to be wrong, and which claims are still unproven.

## Contents

| Document | What is in it |
|----------|---------------|
| [01-crash-analysis.md](01-crash-analysis.md) | The crash report, what it contained and what it did not. The three defects, derived from the code, with the arithmetic behind each one |
| [02-decisions.md](02-decisions.md) | Every decision that shaped the fix, with its reasoning and its accepted cost |
| [03-discarded-approaches.md](03-discarded-approaches.md) | Three approaches that were written or considered and rejected, and the reason each one failed. Read this before reintroducing any of them |
| [04-verification.md](04-verification.md) | How the fix was checked, and the list of things that remain unchecked |
| [05-volume-plan.md](05-volume-plan.md) | The second defect, added later: the system volume was applied twice on the default device. Written before the code changed, including an objection to the plan that turned out to be wrong |
| [06-volume-report.md](06-volume-report.md) | The closing report on that defect. What the fix exposed, what two reviews got wrong, and the one finding that could not be fixed because no unit test can reach it |
| [07-submission-plan.md](07-submission-plan.md) | The step by step plan for submitting to App Review, in German because it is a working checklist rather than a report. Includes the guideline 2.4.5(iii) risk from an earlier rejection. Carries the progress markers for each phase |
| [08-submission-log.md](08-submission-log.md) | What actually happened while submitting. The archive built from the wrong project tree, the dSYM forensics that proved it, why validation and upload would both have passed it, and the preflight script written in response. Also the one finding from checking the store text against the code |
| [09-investigation-case007-008.md](09-investigation-case007-008.md) | The two-model parallel investigation of CASE-007 (volume jump on headphone connect) and CASE-008 (speakers always play). Root causes, hypothesis rankings, comparison of model results |

## Release at a glance

| Field | Value |
|-------|-------|
| Version | 4.0.1, build 10 (`MARKETING_VERSION` 4.0.1, `CURRENT_PROJECT_VERSION` 10) |
| Status | **Submitted to App Review on 09.10.2026. Waiting for Review.** Build 10 was archived on 08.10.2026, validated and uploaded. Build 9 was uploaded on 1 October 2026 but never submitted and is superseded. Tags `v4.0.0` (on `6e32199`) and `v4.0.1` are set and pushed. |
| Work completed | 23 September 2026 for the crash (CASE-003), 27 September 2026 for the volume defect (CASE-004), 6 October 2026 for CASE-007 and CASE-008 |
| Platform | Mac App Store, macOS 14.4 or later, Apple Silicon |
| Trigger | Five crash reports in App Store Connect (22 September 2026), a volume report in the MacRumors thread (24 September 2026), and two self-found defects (5 October 2026) |
| Commits | `f6d0bb9`, `dc59f98`, `27bc3ce`, `9f0a871`, `db1ecb4`, `c34fd7b`, `4a0f6c1`, `c9e097d`, `a76a1e2`, `0bbad31`, `1a8257a`, `41246bc`, `b1dcf8e`, `9bbd131`, `e3ac13b`, `3dc3cfa`, `70d9ab7` (docs: submission plan), `b5652be` (docs: submission status in changelog and release notes) |
| Internal case IDs | CASE-003 (crash), CASE-004 (volume), CASE-007 (volume jump on hotplug), CASE-008 (speakers play despite exclusive selection) |

**Uploaded is not submitted.** The distinction is kept exact throughout this
folder, and for most of the folder's life it marked the open question: the build
sat on Apple's servers and App Review had not seen it. That is now history. The
irreversible step, phase 6 of [07-submission-plan.md](07-submission-plan.md), was
taken on 09.10.2026. Build 10 is with App Review, waiting. The documents below
that were written before submission still describe the uploaded-but-not-submitted
state on purpose: they are the record of how the decision was reached, not a
current status.

The last four commits in the list came out of the submission run itself rather
than the defects: `a76a1e2` and `0bbad31` record what went wrong,
`1a8257a` moves the signing settings into the project file, and `41246bc` adds
`v4/scripts/preflight.sh`, the gate that exists so the same mistake cannot repeat
quietly. See [08-submission-log.md](08-submission-log.md).

The commit range is worth reading in full, the messages carry most of the
reasoning that later became these documents:

```sh
git log f6d0bb9^..41246bc
```

Note that `dc59f98` implements an approach that `db1ecb4` deletes again. That is
not a mistake in the history, it is the history. See
[03-discarded-approaches.md](03-discarded-approaches.md).

## Read this part before the rest

The raw `.ips` crash log was never available. Everything in
[01-crash-analysis.md](01-crash-analysis.md) is derived from reading the source
against the crash grouping that App Store Connect showed, not proven from a
symbolicated trace. The crash was never reproduced on a development machine.

Each of the three defects described here is a genuine defect, and each fix is
justified on its own merits regardless of the crash report. Whether they fix
*the reported crash* is open, and only the crash statistics of the coming weeks
can answer it. [04-verification.md](04-verification.md) lists exactly what is
proven and what is not.

CASE-007 and CASE-008, added in build 10, do not depend on the crash report. Both were self-found in the running app and are independently verifiable.

## Source files this release touched

| File | Role |
|------|------|
| [`v4/AudioRouterNow4/UI/WaveHeaderView.swift`](../../v4/AudioRouterNow4/UI/WaveHeaderView.swift) | The canvas. Timeline removed, sanitising and sub-pixel offset added |
| [`v4/AudioRouterNow4/UI/WaveClock.swift`](../../v4/AudioRouterNow4/UI/WaveClock.swift) | New. The redraw tick and the smoothed normalisation reference |
| [`v4/AudioRouterKit/Sources/AudioRouterKit/WaveformBridge.swift`](../../v4/AudioRouterKit/Sources/AudioRouterKit/WaveformBridge.swift) | Ring buffer, now also measures its own push interval and reports a phase |
| [`v4/AudioRouterKit/Sources/AudioRouterKit/WaveformGeometry.swift`](../../v4/AudioRouterKit/Sources/AudioRouterKit/WaveformGeometry.swift) | New. Non-finite hardening, testable without a UI |
| [`v4/AudioRouterNow4/EngineController.swift`](../../v4/AudioRouterNow4/EngineController.swift) | Owns the clock, drives the poll, adds `openBugReport()` |
| [`v4/AudioRouterNow4/MenuBarView.swift`](../../v4/AudioRouterNow4/MenuBarView.swift) | Device poll left ungated on purpose, see decision D8 |
| [`v4/AudioRouterKit/Sources/AudioRouterKit/FanOutEngine.swift`](../../v4/AudioRouterKit/Sources/AudioRouterKit/FanOutEngine.swift) | `waveformSnapshot(count:)` became `waveformFrame(count:)`. The IOProc was unchanged by the crash fix, but **is** changed by the volume fix, see 05 |
| [`v4/AudioRouterKit/Sources/AudioRouterKit/VolumeTracker.swift`](../../v4/AudioRouterKit/Sources/AudioRouterKit/VolumeTracker.swift) | Settle-freeze added for CASE-007: `freezeActive` flag, `shouldAdoptVolume` pure function, 4-second deadline |
| [`v4/AudioRouterNow4/MenuBarView.swift`](../../v4/AudioRouterNow4/MenuBarView.swift) | Exclusive routing toggle added to footer for CASE-008 |

## Related documents

- [`CHANGELOG.md`](../../CHANGELOG.md), section `## [4.0.1 (10)]` for CASE-007 and
  CASE-008, `## [4.0.1 (9)]` for the volume defect, and `## [4.0.1 (8)]` for the
  crash fix. Builds 8 and 9 were never submitted; build 10 carries all of their
  fixes plus the two added on 6 October
- [`RELEASE_NOTES.md`](../../RELEASE_NOTES.md), section "AudioRouterNow 4.0.1 (Build 10)"
  for the current build, and "AudioRouterNow 4.0.1 (Build 9)" for the superseded one
- [`BACKLOG.md`](../../BACKLOG.md), for the three items deliberately kept out of
  4.0.1: the sample rate listener, the universal binary versus the "Apple Silicon
  only" documentation, and the v4 tagging work
- [`v4/scripts/preflight.sh`](../../v4/scripts/preflight.sh), the submission gate
- [`v4/ARCHITECTURE.md`](../../v4/ARCHITECTURE.md), the surrounding v4 architecture
