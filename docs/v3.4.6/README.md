# AudioRouterNow 3.4.6: the full record

This folder documents the release that fixed two defects which had been present
in every public v3 build since the GitHub launch on 14 June 2026, and which were
both invisible from the outside.

The changelog says what changed. The release notes say what it means for you.
This folder says how the decisions were reached, which of them were wrong, and
what is still unproven.

## Contents

| Document | What is in it |
|----------|---------------|
| [00-plan.md](00-plan.md) | The execution plan, written before any code was touched, including two of its own premises that did not survive verification |
| [01-consistency-plan.md](01-consistency-plan.md) | The follow up after the first audit, and the discovery that the minimum macOS version lived in six places rather than two |
| [02-report.md](02-report.md) | The closing report, plus a dated addendum. It was written before the updater defect was found, and says so |
| [03-sparkle-plan.md](03-sparkle-plan.md) | The updater fix, including the abort condition agreed before starting |

## The two defects

**The app did not start below macOS 26.** Every release carried a Python runtime
compiled for macOS 26, so the dynamic linker refused to load it before any
application code ran. No icon, no window, no error. Reported by a user on macOS
12.7.6 on 24 September.

**The updater had never started.** Sparkle was embedded from 3.4.0 onward and
failed on every single launch, caught and logged. Found while testing the first
fix. Nobody reported it, and nobody could have: an updater that finds nothing and
an updater that never runs look identical from the outside.

## The one thing worth carrying forward

Chapter 43.4 of `DOKUMENTATION.md`, written on 4 June 2026, ten days before the
launch, demanded the move to Python 3.13 as a P0 measure before release, with a
complete set of instructions. The reason given there was different, the action
would have been the same. It was never carried out.

So the first defect was not missed for lack of insight. The insight existed, in
writing, correctly, and marked critical. What was missing was something that
stops the build when a recognised measure has not been taken.

**A note in a document is not a gate.** Both gates in `build.sh` exist because of
that sentence.

## Release at a glance

| Field | Value |
|-------|-------|
| Version | 3.4.6 |
| Released | 26 September 2026 |
| Platform | Direct download and Homebrew, macOS 11 or later, Apple Silicon |
| SHA-256 | `c97b1bfb6b9ec6238f642821922f20bb549b99b05f588168e810a836d883a3c4` |
| Commits | `e49d243`, `3096979`, `ccf9c20`, `44762e7`, `0bdc36c`, `55a2432`, `75dd975` |
| Internal case IDs | CASE-005, CASE-006 |

## Read this part before the rest

The deployment target of every file in the bundle is measured and correct, which
is **necessary** for the app to launch on macOS 11. It is not **sufficient**: a
correct target says nothing about a library calling an API that only exists in a
later macOS.

Confirmation on a real system below macOS 26 is still outstanding. It can only
come from outside, and it is not presented as done anywhere in this repository.

The updater fix carries no such caveat. It was demonstrated end to end on an
installed build before anything was claimed.

## Related documents

- [`CHANGELOG.md`](../../CHANGELOG.md), section `## [3.4.6]`
- [`RELEASE_NOTES.md`](../../RELEASE_NOTES.md), section "v3.4.6"
- [`DOKUMENTATION.md`](../../DOKUMENTATION.md), chapter 5 for the build gates and
  chapter 11 for both fixes
- [`docs/v4.0.1/`](../v4.0.1/), the same kind of record for the App Store app
