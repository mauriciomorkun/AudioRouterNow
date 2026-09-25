# v3.4.6 execution plan

Written 25 September 2026, before any code was changed. Kept as written so that
the audit afterwards has something to compare the result against.

## Why this release exists

Every published v3 build carries a Python runtime compiled for macOS 26. Below
that version the dynamic linker cannot load it, so the process dies before any
application code runs. No icon, no window, no error. The README has promised
macOS 11 or later since launch and that promise was never true.

Reported by a user on macOS 12.7.6, 24 September 2026. Full analysis in
`feedback/CASE-005_email_python-runtime-minos26.md` (local, not in Git).

Root cause, `legacy-v3/installer/build.sh` line 90:

```bash
PYTHON=$(command -v python3)
```

That resolves to Homebrew Python 3.14, which compiles against the host OS.

## Two premises that were checked and corrected

The first draft of this plan contained two claims that did not survive
verification. Both are recorded because a plan that quietly drops its own errors
teaches nothing.

| Claim | Reality |
|-------|---------|
| The Homebrew cask is stuck at 3.4.0 and `LAUNCH_EXECUTION.md` is wrong about the 3.4.5 bump | The remote tap has commit `b1fb01c audiorouternow 3.4.5`. Only the local working copy is stale. A `git pull` resolves it |
| The landing page exists twice, `index.html` and `index-postlaunch.html`, and the wrong one gets edited | Commit `7594db3` merged them. Only `index.html` remains and it is byte identical to the live site |

## Fix vehicle

`/Library/Frameworks/Python.framework/Versions/3.13/bin/python3`, already
installed. Measured at the binary, not read from config:

```
minos 11.0      (arm64 slice)
x86_64 arm64    (universal2)
```

That matches the documented minimum exactly.

---

## Phase 0, preflight

1. Verify the python.org interpreter with `vtool -show-build` and `lipo -archs`.
   Abort if the arm64 slice is not 11.0.
2. Verify signing identity, notarytool keychain profile and the Sparkle EdDSA
   key are present. Do not touch any of them.
3. `git -C ~/homebrew-tap pull origin main` so the local cask is current.
4. Record the existing venv origin from `pyvenv.cfg` for the log, then delete it
   in phase 4.

## Phase 1, build script changes

All in `legacy-v3/installer/build.sh`.

1. **Single source for the promise.** Add `MACOS_MIN_VERSION="11.0"` in the
   paths block. Every later check reads this and nothing else hardcodes a
   version.
2. **Pin the interpreter.** Replace line 90 with an absolute path to the
   python.org framework build, plus an executable check that fails with the
   download URL if it is missing. Never read `python3` from the environment
   again.
3. **Reject a foreign venv.** Add `venv_matches_interpreter()`, which reads
   `home` from `pyvenv.cfg` and compares it against `dirname "$PYTHON"`. Extend
   the existing venv block so a mismatch discards and rebuilds. The existing
   `venv_is_healthy()` stays untouched.
4. **The gate.** Add `check_minos_gate()` after the PyInstaller step and before
   signing, so a broken build fails in seconds instead of after a notarisation
   round trip. It walks every file in the bundle, reads every `minos` value via
   `vtool -show-build`, and fails listing each offender. It also reports any
   `x86_64`-only file as a warning, since the documented target is Apple
   Silicon.

   The `.app` check covers the DMG because the DMG contains that bundle
   unchanged and holds no other Mach-O files.

## Phase 2, compatibility

Before building, dry-run the dependency resolution against 3.13:

```sh
/Library/Frameworks/Python.framework/Versions/3.13/bin/python3 -m pip install --dry-run -r requirements.txt
```

`rumps`, `pyobjc` and `pyinstaller` all support 3.13. If a wheel is missing, pin
rather than downgrade Python, and measure the `minos` of any replacement
interpreter before adopting it.

## Phase 3, version bumps

| File | What |
|------|------|
| `legacy-v3/engine/version.py` | `APP_VERSION`. The driver Makefile derives its helper version from here |
| `legacy-v3/driver/resources/Info.plist` | Two strings, lines 24 and 27. Not derived |
| `README.md` | Version line, release line, download link, SHA256 label and value |
| `legacy-v3/README.md` | Version line |
| `RELEASE_NOTES.md` | The cross reference inside the v4 section |
| `landing-page/index.html` | Five occurrences |
| `~/homebrew-tap/Casks/audiorouternow.rb` | Version and SHA256 |

Not bumped: existing `CHANGELOG.md`, `RELEASE_NOTES.md` and `docs/appcast.xml`
entries are history and get a new entry in front instead.

## Phase 4, build

Delete `dist/`, `build_output/` and `.venv` first, so the new interpreter check
cannot be satisfied by a leftover. Then run `build.sh` and watch for three
lines: the 3.13 interpreter, a freshly created venv, and the gate passing.

Expect 12 to 18 minutes, most of it waiting on Apple.

## Phase 5, verification

1. Distribution of `minos` across the built bundle. Expect nothing above 11.0.
2. Architecture distribution. Expect `arm64` and some universal, no
   `x86_64`-only.
3. Mount the finished DMG, then `stapler validate`, `spctl --assess` and a
   version read from the embedded `Info.plist`.
4. SHA256 of the DMG, later compared against the uploaded asset.

## Phase 6, publish

1. Commit and tag. Commit message states the defect, the cause with file and
   line, and the fix.
2. GitHub release **as a draft** first, see phase 8.
3. Appcast: hand edit `docs/appcast.xml`, do not run `generate_appcast`, which
   would overwrite the handwritten CDATA of the existing entries. Sign with
   `sign_update` and set `sparkle:minimumSystemVersion` to 11.0, a value that
   becomes true with this release.
4. Homebrew cask bumped and pushed in the same sitting, not later.
5. Landing page: diff against the live site before deploying, back up the server
   copy, deploy, verify over HTTP.

## Phase 7, manual steps for the owner

- Write to the reporter with the download link and the SHA256, and ask whether
  it starts on his Monterey machine.
- Correct MacRumors post #23. It claims v3 is maintained for anyone below macOS
  14.4, which was not true when written. State the defect plainly, state that
  3.4.6 fixes it, repeat that Intel remains unsupported by the prebuilt binary.

## Phase 8, what can actually be proven

This is the part worth being careful about, because the defect survived three
months precisely by looking fine from the build machine.

The gate proves a **necessary** condition: no file in the bundle demands a
system newer than 11.0. If that failed, the app could not possibly start. It is
not **sufficient**: a correct `minos` says nothing about a library calling an
API that only exists in a later macOS.

So the measurement alone must not be reported as a fix confirmed. The order is:

1. Draft the release.
2. Send it to the reporter, who has the exact affected system and already
   reproduced the failure.
3. Publish once he confirms.
4. If he does not reply within about three days, publish anyway and say plainly
   in the notes that the fix is proven by measurement and that runtime
   confirmation on a pre-26 system is still outstanding.

A local VM on macOS 12 is the durable answer for future v3 builds. It is a half
day of work and should not block this release.

## Risks

| Risk | Likelihood | Response |
|------|-----------|----------|
| A dependency has no 3.13 wheel | Low | Pin the package. Do not switch interpreters without measuring the replacement |
| PyInstaller 3.13 changes bundle layout | Low | The symlink resolution block in `build.sh` may need path updates. Signing fails loudly, it does not ship |
| The gate fails on a PyObjC wheel | Very low | Pin that wheel to the last version with a correct target |
| Notarisation rejected | Low | Nothing in the signing path changes. Read the Apple log |
| python.org 3.13 later uninstalled | Certain eventually | The build fails with the download URL in the message. That is the intended behaviour and better than a silent wrong build |
