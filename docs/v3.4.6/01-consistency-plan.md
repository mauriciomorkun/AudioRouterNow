# v3.4.6 follow up plan, three consistency fixes

Written after the main fix (`e49d243`) was committed and audited. Nothing has
been built and nothing has been pushed at this point.

## What the audit found

Three items that do not block a build but leave the project saying things that
are not true, or saying them in more than one place.

## Corrected premise

The first draft of this plan assumed the minimum macOS version lived in two
places. It lives in six, and only three of them do any work:

| File and line | Value | Effect |
|---|---|---|
| `legacy-v3/installer/build.sh:48` | `MACOS_MIN_VERSION` | threshold the gate compares against |
| `legacy-v3/installer/AudioRouterNow.spec:112` | `LSMinimumSystemVersion` | what macOS reads at launch |
| `legacy-v3/driver/Makefile:49` | `-mmacosx-version-min` | **produces** the driver `minos` |
| `legacy-v3/driver/Makefile:67` | `-mmacosx-version-min` | **produces** the helper `minos` |
| `legacy-v3/helper/Makefile:23` | `-mmacosx-version-min` | **produces** it on a standalone build |
| `legacy-v3/driver/resources/Info.plist:38` | `LSMinimumSystemVersion` | driver bundle |

Unifying only the first two would have produced a label, not a source of truth.

---

## Step 1, one source for the minimum

1. **`legacy-v3/engine/version.py`**: add `MACOS_MIN_VERSION = "11.0"` next to
   `APP_VERSION`, with a comment naming every consumer and naming
   `driver/resources/Info.plist` as the deliberate exception.
2. **`AudioRouterNow.spec`**: read it from the already populated `_version_ns`
   right after `APP_VERSION`, use it at line 112. A missing constant raises
   `KeyError` and PyInstaller aborts before producing anything, same failure
   mode as `APP_VERSION`, so no extra guard. Remove the em dash in the comment
   block at line 17 while editing it.
3. **`build.sh:48`**: derive instead of define. Read with `awk` from
   `$ENGINE_DIR/version.py`, not through `$PYTHON`, because `ENGINE_DIR` exists
   at line 32 while `PYTHON` is only set at line 111. The gate needs the value
   at line 363, so the ordering holds.

   Two guards, both `fail`:
   - empty read, meaning missing file or missing line
   - format check `^[0-9]+(\.[0-9]+)*$`

   The second guard is not optional. `vgt()` in the gate computes with `+ 0`, so
   a non numeric value becomes 0, no version would ever count as greater, and
   **the gate would silently pass everything**. That is precisely the class of
   defect it exists to catch.
4. **The three real sources**: both Makefiles derive `ARN_MACOS_MIN` from
   `version.py` in the same regex style already used for `ARN_VERSION`, with
   `$(error ...)` on an empty result. The `ARN_VERSION` block has to move above
   the `CFLAGS` block, which currently comes first.

   Deliberately left alone: `driver/resources/Info.plist:38`. The Makefile
   copies that file verbatim; deriving it would need a `sed` step in the copy
   target, which is out of proportion for follow up work. `version.py` names it
   instead.

## Step 2, prove the gate still works, before building

Extract `check_minos_gate()` from `build.sh` with stub helpers and run it
against three targets:

| Target | Expected |
|---|---|
| `legacy-v3/installer/dist/AudioRouterNow.app` | 73 Mach-O, **fails with 57 violations** |
| `.../Versions/3.13/lib/python3.13/lib-dynload` | 78 Mach-O, passes |
| `.../Versions/3.13/bin` | 2 Mach-O, passes, one x86_64 only warning |

Do **not** use `Versions/3.13` as a whole. It carries locally installed scipy at
`minos 14.0` and reports 207 violations that would never reach a bundle.

This runs before the build, because deleting `dist/` removes the only negative
reference available.

## Step 3, the Intel contradiction

Say what is true today. Intel is not supported, by the prebuilt binary or by a
local build.

- `README.md:10-11`: drop Intel from the v3 redirect, add "Apple Silicon only"
- `README.md:88`: remove the self contradicting sentence about rebuilding from
  source
- `legacy-v3/README.md:6`: drop Intel
- `README.md:208` and `legacy-v3/installer/README.md:19`: "Python 3.10+" has
  been wrong since `e49d243`, name the python.org 3.13 framework build

## Step 4, record the Intel finding without promising it

`BACKLOG.md` is gitignored. Add an entry in the existing house style, status
idea, target version unknown, containing only measured facts:

- driver and helper are built universal, `x86_64 arm64`
- the shipped 3.4.5 bundle has them thinned to arm64, 68 of 73 files arm64 only
- cause is one line, `AudioRouterNow.spec:82`, `target_arch=None`
- python.org 3.13 is universal2, PyObjC wheels are `macosx_10_13_universal2`

And the other side with the same weight: unverified, no promise, no Intel
machine to test on, `target_arch="universal2"` requires every bundled binary to
be universal2, and the HAL driver has never run on Intel. `target_arch` is not
changed.

## Step 5, DOKUMENTATION.md

Last, so that what is documented is what was done.

- header to 3.4.6 and the current date
- line 11: drop Intel, same reason as step 3
- chapter 5: the pinned interpreter in the prerequisites, a new gate step
  between PyInstaller and signing, and the spec row noting it now reads
  `MACOS_MIN_VERSION` as well
- two new subsections before "Warum die App vor dem DMG gestapelt wird", in the
  same shape as that one: why the interpreter is pinned, and why the bundle is
  measured against the minimum. Include both `vtool` forms, why the second
  `version` line inside an `LC_BUILD_VERSION` block must not be read, why the
  gate sits before signing, and the measured 57 of 73
- chapter 9: "Python 3.10+" replaced, noting that Homebrew Python now aborts the
  build on purpose
- chapter 11: a new "Behoben in 3.4.6" section above the 3.4.5 one, in that
  section's style, including the honesty paragraph that the gate proves a
  necessary condition only, and the process sentence linking it to the stapling
  defect: what the project promises publicly, the build has to measure before
  shipping

## Step 6, close out

`git diff --stat` against `e49d243`. Expected: `version.py`,
`AudioRouterNow.spec`, `build.sh`, both Makefiles, `installer/README.md`,
`README.md`, `legacy-v3/README.md`, `DOKUMENTATION.md`. Nothing under `v4/`,
and neither `BACKLOG.md` nor `feedback/`.

Only then delete `.venv`, `dist/` and `build_output/` and build.

---

# Round two, findings from the audit

The audit cleared the work with no blockers. It found two "important" items and
three cosmetic ones, all of them statements that survived in corners the first
pass did not reach.

## The principle for this round

`DOKUMENTATION.md` chapter 43 is a dated chronicle entry from 4 June 2026. The
file separates current chapters from chronicle at chapter 13. A false statement
inside a chronicle gets **annotated, not overwritten**. Rewriting it would make
the record say something it never said, which is the opposite of what this
release is about.

Recommendations meant for present use are a different matter. Those get
corrected.

## Items

1. **`DOKUMENTATION.md:5720` and `:5724`.** The table row "App-Bundle
   (PyInstaller) | Rosetta 2" and the sentence "Der PyInstaller-Bundle ist
   arm64-only und laeuft via Rosetta 2". Rosetta 2 translates x86_64 to arm64,
   not the reverse, so an arm64 only bundle does not run on Intel at all. Add a
   dated correction note directly below. Do not edit the original lines.
2. **`DOKUMENTATION.md:5732`, section 43.3.** "Intel Macs: build from source" is
   a recommended requirements text for present use and promises an unverified
   path. Correct it to match `README.md:89`, and mark it as corrected with the
   date.
3. **`DOKUMENTATION.md` section 43.4.** It demanded the Python 3.13 downgrade as
   a P0 measure before launch. That measure was carried out on 25 September 2026
   in v3.4.6, for a different reason than the one given there. Add a dated note
   closing the loop, including the fact that the action was correct and was not
   taken, and that this is why the build now has a gate rather than a note.
4. **`legacy-v3/engine/README.md:12`**, "Python 3.10 oder neuer". Superseded by
   the pinned interpreter.
5. **`.github/ISSUE_TEMPLATE/bug_report.md:28`** offers Intel as a chip option
   and **`.github/PULL_REQUEST_TEMPLATE.md:18`** has "Tested on Intel Mac". Both
   imply Intel is a target platform. Bring them in line with `README.md:89`.

## Verification for this round

The three gate references must still produce 73 with 57 violations, 78 passing
and 2 passing. Nothing in `build.sh`, the spec, the Makefiles or `version.py` is
touched in this round, so any change there would be a mistake.
