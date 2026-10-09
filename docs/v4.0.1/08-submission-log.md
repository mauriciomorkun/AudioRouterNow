# Submitting 4.0.1: what actually happened

[07-submission-plan.md](07-submission-plan.md) says what should happen. This
document says what did. It was written because one phase went wrong in a way that
no later step would have caught, and because the correction that came out of it is
worth more than the phase it fixed.

Scope: phases 0 to 3 of the plan, which ran on 1 October 2026, plus phase 5.1,
which ran on 1 and 2 October. Phases 4, 5.2, 6 and 7 had not been started when
this was written. See [What is still open](#what-is-still-open).

## The state in one line

**Build 9 is uploaded to App Store Connect. Nothing has been submitted to App
Review.**

Those are two different things and this document keeps them apart everywhere.
Uploading puts the build on Apple's servers and makes it selectable under
**Build** in App Store Connect. Submitting is a separate, deliberate action that
hands the version to App Review. Only the second one starts a clock, and only the
second one is hard to take back. Up to now App Review has never seen 4.0.1.

## Timeline

| When | What | Result |
|---|---|---|
| 1 Oct 2026 | Phase 0, securing the starting point | Clean tree, version confirmed as 4.0.1 (9), tests green, local release build clean |
| 1 Oct 2026 | Phase 1, first archive run | **Wrong.** Produced 4.0.0 (7) from the wrong project tree |
| 1 Oct 2026 | Phase 1, second archive run | Correct, 4.0.1 (9), provenance verified |
| 1 Oct 2026 | Phase 2, Validate App | "Validation successful", no warnings |
| 1 Oct 2026, 17:26 | Phase 3, upload to App Store Connect | Succeeded. Build 9 is at Apple |
| 1 to 2 Oct 2026 | Phase 5.1, checking the store text against the code | Six claims confirmed, one finding, corrected |

Version and build were read from the single source,
`v4/Configs/AudioRouterNow4.xcconfig`, which carries `MARKETING_VERSION = 4.0.1`
on line 6 and `CURRENT_PROJECT_VERSION = 9` on line 7. `project.yml` only refers
to that file, so there is no second place to keep in sync.

## The incident: an archive from the wrong project tree

### What happened

The first archive run produced an archive labelled **4.0.0 (7)** instead of
4.0.1 (9).

The cause is not a build system fault. Two Xcode projects in this repository carry
the identical name `AudioRouterNow4`:

| Path | What it is |
|---|---|
| `v4/AudioRouterNow4.xcodeproj` | the correct one, 4.0.1 (9) |
| `v4-appstore/AudioRouterNow4/AudioRouterNow4.xcodeproj` | dead legacy tree, 4.0.0 (7), untracked since `b42d692` |

In Xcode's recent projects list both appear as nothing more than
"AudioRouterNow4". The dead one was reachable in fewer clicks than the correct
one. The legacy tree has no `MARKETING_VERSION` at all, which is why it reports
the hardcoded 4.0.0 (7) rather than failing.

### The proof was forensic

The version shown in the Organizer said which version was built. It did not say
which directory it was built from, and that was the question. The answer came out
of the archive's debug symbols, which retain absolute source paths:

```sh
ARCH=$(ls -dt ~/Library/Developer/Xcode/Archives/*/*.xcarchive | head -1)
strings "$ARCH/dSYMs/"*.dSYM/Contents/Resources/DWARF/* \
  | grep -oE "/AudioRouterNow/(v4|v4-appstore)/" | sort | uniq -c
```

| Archive | Hits on `/v4/` | Hits on `/v4-appstore/` |
|---|---|---|
| First run, wrong | 0 | 114 |
| Second run, correct | 110 | 0 |

The split is total in both directions, which is what makes the measurement
conclusive rather than suggestive. A mixed result would have meant something
stranger and worse.

The figures for the second archive are still reproducible: that archive is on
disk, reports 4.0.1 and build 9 in its `Info.plist`, and yields 110 hits on
`/v4/` and none on `/v4-appstore/`. The figures for the first archive come from
the record of the session. That archive was discarded and cannot be re-measured.

### Why nothing downstream would have caught it

This is the part worth carrying forward. The wrong archive would have passed
**both** remaining checks:

- **Validate App** checks signing, entitlements and bundle structure. All of that
  was correct in the wrong archive. It was a properly built, properly signed
  application. It was simply the previous version.
- **Upload** checks the same class of things. Neither step asks which working
  directory the binary came from, because for every normal build that question has
  only one possible answer.

The failure would have surfaced at Apple, as a rejection stating that build 7
already exists. By then the visible symptom (a duplicate build number) sits a long
way from the cause (a project picked from a menu), and the obvious reading of that
message is that the version numbers were wrong, which they were not.

What actually caught it was step 1.6 of the plan: look at the Organizer and read
the version. A human glance, placed there because the duplicate-name hazard had
been written down in advance as a warning on step 1.1.

**So the warning worked.** It is the reason anyone looked instead of clicking
straight through to Distribute. That is the one encouraging fact in this section,
and it is also the limit of it: the warning worked because it happened to be read
by the person it was written for, on the day it mattered.

### The countermeasure is a script, not a note

`v4/scripts/preflight.sh`, added in commit `41246bc`.

The reasoning is stated in the script's own header and is the whole point of it:
**a note in a document is not a gate.** That lesson is older than this incident,
it comes from v3.4.6, and this incident is what made it concrete. A warning in a
checklist depends on being read. It has no effect on the run where someone is
tired, or in a hurry, or confident because the last four releases went fine.

The script checks, in one pass:

- whether a duplicate project tree exists
- whether the version comes from a single source
- whether the version is already tagged, and therefore already shipped
- whether the working tree is clean
- entitlements
- after archiving, the provenance of the archive itself, via the dSYM strings
  described above

It exits non-zero on any blocking finding, which is the difference that matters.
It is anchored as step 0.6 of the plan, to be run again after phase 1 so that
section 6 inspects the fresh archive.

Honest note on sequence: the script did not prevent this incident. It was written
after it, and could not have run before it existed. It ran after the second,
correct archive run and passed. Its value is for every release after this one.

### Side finding: signing lived outside the repository

Recorded as commit `1a8257a`, found while checking step 1.3.

Before that commit `project.pbxproj` contained no `DEVELOPMENT_TEAM`, no
`CODE_SIGN_STYLE` and no `CODE_SIGN_IDENTITY`. Xcode resolved signing at build
time from whichever developer account happened to be signed in. That works as long
as exactly one team is configured, and it is how 4.0.0 was built, but it means the
setting could not be verified from the repository at all.

Opening the correct project caused Xcode to write those values, and `1a8257a`
commits them. The project now carries its own signing settings.

**The caveat is not closed.** The values sit in `project.pbxproj`, not in
`v4/project.yml`. The project is generated from `project.yml` by
`scripts/xcodegen.sh`, so a single `xcodegen` run would discard all of it again.
The durable fix is to carry the settings in `project.yml`, which is recorded as a
backlog item rather than changed in the middle of a submission.

## Phase 5.1: checking the store text against the code

The purpose of this phase is narrow and worth stating precisely: not to improve
the text, but to find any sentence in it that the code does not support. A store
text is a claim about software, and it is checkable.

Six claims were traced to source and confirmed:

| Claim in the store text | Confirmed by |
|---|---|
| A ladybug icon in the footer opens the bug report | `RoutingControls.swift:214`, `Image(systemName: "ladybug")` inside the button that calls `controller.openBugReport()` |
| No device names in the email | `EngineController.swift:564` onward, the body carries `outputConfigs.count`, a number, and no device name anywhere |
| The waveform runs only while routing | `stopRouting()` at `EngineController.swift:357` cancels `wavePollTask` on line 359 |
| The volume is applied only once | `FanOutEngine.slotTargetSV`, `FanOutEngine.swift:1332`, called from the IO path at line 997 |
| Mute does not depend on the hardware | `FanOutEngine.effectiveVolume`, `FanOutEngine.swift:1313`, whose branch is `(appliesVol \|\| vol <= 0) ? vol : 1.0`, so a volume of zero is always honoured in software |
| Launch at Login is deliberately reset | `launchAtLoginConsentBuildKey`, `EngineController.swift:119`, keyed on the build number, enforced by `ensureLoginItemCompliance()` at line 240 |

### The one finding

The privacy sentence in the store text named **three** pieces of information as
being included in the bug report email. `openBugReport()` in
`EngineController.swift:564` assembles **five**:

1. app version and build
2. macOS version
3. Mac model
4. the number of configured outputs
5. the current routing state

Items 4 and 5 were missing from the sentence.

**Why this was corrected by adding rather than by trimming.** In a privacy
statement, a list reads as exhaustive. A reader who is told "it includes A, B and
C" has been told, by implication, that it does not include D and E. Shortening the
sentence to something vaguer would have removed the inaccuracy while also removing
the information, and the original sentence was precise in form, just wrong in
content. So the list was completed instead. The same edit added the statement that
nothing leaves the machine until the user presses send in their own mail client,
which is true of a `mailto:` URL by construction and is the fact a reader of that
paragraph actually wants.

Neither of the two added items is sensitive. A count of outputs and an on/off
state carry no identifying content, which is precisely why they were easy to
overlook when the sentence was written. The defect was in the claim, not in the
software.

The corrected text lives in `docs/marketing/appstore-whatsnew-4.0.1.md`, which is
untracked by design. It is **1747 characters** of the 4000 allowed, previously
stated as 1635 in step 4.2 of the plan. That step has been corrected.

## Build 9 superseded by build 10

### What happened

Build 9 was uploaded to App Store Connect on 1 October 2026. The upload succeeded
and the build passed validation. No version metadata was filled in, and the
submission itself did not happen.

On 5 October 2026 two additional defects were found in the running app:
CASE-007 (volume jump on headphone connect) and CASE-008 (built-in speakers play
regardless of routing selection). Both were investigated on 5 October with two
independent model analyses in parallel (Fable and Claude Opus). The root causes
were confirmed and design plans written.

On 6 October 2026 both defects were fixed and an audit round was completed:

| Commit | What |
|---|---|
| `9bbd131` | CASE-007: settle-freeze in `VolumeTracker.swift` |
| `e3ac13b` | CASE-008: exclusive routing mode, conditional default-slot attachment |
| `3dc3cfa` | Audit round 1: one finding addressed (rank-4 fallback master diagnostic) |

These commits landed after the upload. The build Apple holds is build 9 and does
not contain any of these fixes. `v4/Configs/AudioRouterNow4.xcconfig` now reads
`CURRENT_PROJECT_VERSION = 10`. Preflight confirms: the existing archive is 4.0.1
(9), and build 10 has not yet been archived.

### Consequence for the submission plan

Phases 0 to 3 of the plan must run again for build 10. The metadata work in phase
4 can begin in parallel (the fields that do not depend on the build number), but
the build selection in step 4.3 will show build 10 once the upload completes.

The What's New text in `docs/marketing/appstore-whatsnew-4.0.1.md` is already
updated for build 10 (CASE-007 and CASE-008 are included). The review note in the
plan is updated to list all four defects.

The two commits from the submission run that came after the build 9 upload
(`b1dcf8e` on 3 October) and the new fix commits (`9bbd131`, `e3ac13b`, `3dc3cfa`
on 6 October) are the reason build 10 contains more than build 9 did.

## What is still open

| Item | State |
|---|---|
| Phase 4, the App Store Connect metadata | **Open.** No 4.0.1 version record created, "What's New" not entered, build 10 not selected (build 9 upload is superseded), no review note, release mode not chosen |
| Phase 5.2, the user's own checklist | **Open.** Depends on phase 4 |
| Phase 6, Submit for Review | **Open.** Not done. This is the step that has not happened |
| Phase 7, everything after | **Open** |
| Tags for v4 | **None exist.** Only `v3.4.0` through `v3.4.6` are tagged. 4.0.0 is not tagged and neither is 4.0.1 |
| `v4-appstore/`, 594 MB | Still present, deliberately. It must not be removed before `v4.0.0` is tagged on `6e32199`, because until then it is the only concrete image of the shipped version |
| Phases 0-3, build 10 archive | **Open.** Build 9 archive is outdated. Build 10 must be archived, validated and uploaded |

The ordering in the last two rows is the substance of it, not a formality. The
folder caused this incident, and the reflex is to delete it. Deleting it before
tagging would remove the only thing standing in for a missing tag. It becomes
dispensable at the moment the tag takes over its job, and not before.

Full detail on the tagging work is in `BACKLOG.md` under the entry on v4 having no
tags.

## What this release still does not claim

Carried over from [04-verification.md](04-verification.md) and unchanged by
anything in this document: whether the crash fix fixes *the reported crash* is
open. The raw `.ips` was never available and the crash was never reproduced. Only
the crash statistics of the coming weeks can answer it, and those require the
version to actually ship.

## Build 10: the run that was submitted (08 to 09 October 2026)

Everything above describes the build 9 run, which was uploaded and then
superseded. This section records the run that went all the way through. Where the
build 9 run stopped at phase 3 with phases 4 to 7 left open, the build 10 run
completed all of them and ended with the version in App Review.

### Phases 0 to 3, rerun for build 10

Phases 0 to 3 were run again from a clean tree. The only difference from the plan
as written was the build number: CASE-007 and CASE-008 had moved
`CURRENT_PROJECT_VERSION` from 9 to 10 in
`v4/Configs/AudioRouterNow4.xcconfig`, so every archive, validation and upload in
this run carried 4.0.1 (10) rather than 4.0.1 (9). The archive was built on
08.10.2026, validated and uploaded. `preflight.sh` ran against the fresh archive
and passed, including the dSYM provenance check that would have caught another
archive from the dead `v4-appstore/` tree. The duplicate-project hazard from the
build 9 run did not recur.

### Phase 5.1, rerun: one finding, corrected

The store-text-against-code check was run again by an Opus agent against the build
10 What's New text. Of 11 claims, 10 were confirmed in source. One finding: the
text described the bug report as opened from a "speaker icon". The control is the
ladybug in the footer, not a speaker icon (`RoutingControls.swift`, the
`controller.openBugReport()` button). Corrected to "from the footer" to match the
code. The correction was to the claim, not to the software.

### Phase 4, in App Store Connect

The metadata that had been open for the build 9 run was completed: Promotional
Text, the What's New text, build 10 selected under **Build**, the review note
listing all four defects (CASE-003, CASE-004, CASE-007, CASE-008), and the release
mode set to manual release.

### Phase 6, the irreversible step

"Add for Review" followed by "Submit to App Review" on 09.10.2026. This is the
step that had never been taken for build 9. The version is now with App Review,
status **Waiting for Review**. Experience puts the wait at 1 to 3 days.

### Phase 7, tags and documentation

`v4.0.0` was tagged on `6e32199` and `v4.0.1` was tagged, both pushed. This clears
the "no v4 tags" condition that the open-items table below was written under. The
changelog, release notes, root `README.md`, this folder's `README.md` and
`LAUNCH_EXECUTION.md` were updated to the submitted state.

### What is still open after build 10

| Item | State |
|---|---|
| App Review decision | **Open.** Waiting for Review, 1 to 3 days expected |
| `v4-appstore/`, 594 MB | Kept until approval, then remove. Its job as the only concrete image of the shipped version ends once 4.0.0 is tagged, which it now is, but it stays until the new version is live as a safety margin |
| Notify the reporter | **Open.** Tell the MacRumors reporter once 4.0.1 is approved and live |

Note that the open-items table in the build 9 section above is now historical. The
tags exist, the metadata is filled, and phase 6 is done. That table records the
state at the time the build 9 run stopped, not the current state.
