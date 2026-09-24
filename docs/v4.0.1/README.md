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

## Release at a glance

| Field | Value |
|-------|-------|
| Version | 4.0.1, build 8 (`MARKETING_VERSION` 4.0.1, `CURRENT_PROJECT_VERSION` 8) |
| Status | **Prepared, not submitted.** Code is on `main`, nothing is tagged and nothing has been sent to App Review |
| Work completed | 23 September 2026 |
| Platform | Mac App Store, macOS 14.4 or later, Apple Silicon |
| Trigger | Five crash reports aggregated in App Store Connect, received 22 September 2026 |
| Commits | `f6d0bb9`, `dc59f98`, `27bc3ce`, `9f0a871`, `db1ecb4`, `c34fd7b` |
| Internal case ID | CASE-003 |

The commit range is worth reading in full, the messages carry most of the
reasoning that later became these documents:

```sh
git log f6d0bb9^..c34fd7b
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

## Source files this release touched

| File | Role |
|------|------|
| [`v4/AudioRouterNow4/UI/WaveHeaderView.swift`](../../v4/AudioRouterNow4/UI/WaveHeaderView.swift) | The canvas. Timeline removed, sanitising and sub-pixel offset added |
| [`v4/AudioRouterNow4/UI/WaveClock.swift`](../../v4/AudioRouterNow4/UI/WaveClock.swift) | New. The redraw tick and the smoothed normalisation reference |
| [`v4/AudioRouterKit/Sources/AudioRouterKit/WaveformBridge.swift`](../../v4/AudioRouterKit/Sources/AudioRouterKit/WaveformBridge.swift) | Ring buffer, now also measures its own push interval and reports a phase |
| [`v4/AudioRouterKit/Sources/AudioRouterKit/WaveformGeometry.swift`](../../v4/AudioRouterKit/Sources/AudioRouterKit/WaveformGeometry.swift) | New. Non-finite hardening, testable without a UI |
| [`v4/AudioRouterNow4/EngineController.swift`](../../v4/AudioRouterNow4/EngineController.swift) | Owns the clock, drives the poll, adds `openBugReport()` |
| [`v4/AudioRouterNow4/MenuBarView.swift`](../../v4/AudioRouterNow4/MenuBarView.swift) | Device poll left ungated on purpose, see decision D8 |
| [`v4/AudioRouterKit/Sources/AudioRouterKit/FanOutEngine.swift`](../../v4/AudioRouterKit/Sources/AudioRouterKit/FanOutEngine.swift) | `waveformSnapshot(count:)` became `waveformFrame(count:)`. The IOProc itself is unchanged |

## Related documents

- [`CHANGELOG.md`](../../CHANGELOG.md), section `## [4.0.1 (8)]`
- [`RELEASE_NOTES.md`](../../RELEASE_NOTES.md), section "AudioRouterNow 4.0.1 (Build 8)"
- [`v4/ARCHITECTURE.md`](../../v4/ARCHITECTURE.md), the surrounding v4 architecture
