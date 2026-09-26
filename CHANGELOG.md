# Changelog

## [3.4.6], 2026-09-25 · _Legacy (macOS 11+, direct download)_

### Fixed
- **The app did not start at all on macOS versions older than the machine it was
  built on.** `installer/build.sh` resolved its interpreter with
  `PYTHON=$(command -v python3)`, which picked up Homebrew's Python. Homebrew
  compiles its interpreter against the running system, so the Python runtime that
  PyInstaller copied into the bundle carried the build machine's minimum OS version
  instead of the documented one. Measured on the shipped 3.4.5 bundle,
  `Contents/Frameworks/Python` reports a minimum of macOS 26.0, and 57 Mach-O files
  in that bundle require it.

  Below that version the dynamic linker refuses to load the runtime before a single
  line of application code runs. There is no window, no icon and no error message.
  Seen from the build machine the result looks correct, which is how this survived
  three months and several releases. Reported by a user on macOS 12.7.6.

  The build now uses the python.org framework build of Python 3.13 at a fixed
  absolute path, whose deployment target is macOS 11.0. The README has promised
  macOS 11 or later since launch, and this is the first release in which that
  has been measured to hold. Measured, not yet observed running: see the note
  below on what this release proves and what it does not.

### Added
- **Deployment target gate in the build script.** After the PyInstaller step and
  before signing, every Mach-O file in the bundle is checked with `vtool -show-build`
  against a single declared minimum. Both `LC_BUILD_VERSION` and
  `LC_VERSION_MIN_MACOSX` are read, once per architecture slice, since a universal
  binary can carry a different target in each. All violations are listed before the
  build aborts, rather than only the first. Files built for x86_64 alone are reported
  as a warning.
- **The build refuses a virtual environment created by a different interpreter.** A
  venv records its origin in `pyvenv.cfg` and keeps using that interpreter's standard
  library, so a leftover venv would have silently defeated the fix above. Mismatches
  are now discarded and rebuilt.

> **What this release proves and what it does not.** The gate establishes that no
> file in the bundle demands a system newer than macOS 11.0, which is a necessary
> condition for the app to launch. It is not a sufficient one: a correct deployment
> target says nothing about a code path calling an API that only exists in a later
> macOS. Confirmation on a real pre-26 system is separate from the measurement.

---

## [4.0.1 (8)], 2026-09-23 · _prepared, not yet submitted to App Review_

> **Full record:** [`docs/v4.0.1/`](docs/v4.0.1/) documents the decisions behind
> this release, including the three approaches that were written or considered
> and discarded, and the list of things that remain unverified.

> **Label note:** this is `MARKETING_VERSION 4.0.1`, build 8. It is a different
> thing from the older `## [4.0.1], 2026-08-05` entry further down, which tracked
> App Store re-submit Build 3 under the old labelling scheme. Entries in the
> `X.Y.Z (build)` form use the current scheme.

### Fixed
- **Crash in the SwiftUI display cycle** (CASE-003). The reported crash sits in
  `__NSWindowGetDisplayCycleObserver`, AppKit's per-window display cycle. The wave
  header drove its canvas from a `TimelineView(.animation)`, which registers an
  observer there, and a `MenuBarExtra(.window)` panel does not tear down its view
  tree when it closes, so that timeline kept running indefinitely with the panel
  shut.

  The timeline is gone rather than paused. The canvas is now driven by the wave
  poll that already existed in `EngineController`, which only runs while routing
  is active and is cancelled in `stopRouting()`. No display cycle observer is
  registered at all, and the animation stops on its own when routing stops.

  Two earlier attempts to keep the timeline and pause it on panel visibility were
  written and discarded, both froze the waveform while the panel was open and
  visible. Key window status is the wrong question (a window can be visible
  without being key, which is the normal case for an `LSUIElement` app), and
  `occlusionState` proved unreliable for this panel. The approach that survived
  needs no window state at all.
- **Non-finite sample values could reach CoreGraphics** (CASE-003). A single
  `Infinity` sample made the waveform normalisation divisor `Infinity`, and
  `Inf / Inf` is `NaN`, so every derived y-coordinate became `NaN`. The existing
  minimum-height guard was written as `if yMin - yMax < 1`, which is always false
  for `NaN`, so it was skipped exactly when it was needed. Sample values are now
  sanitised before any coordinate is computed (`WaveformGeometry` in
  AudioRouterKit, covered by 13 unit tests), and the guard is stated positively so
  the safe branch is the default.

### Added
- **Bug report button** in the footer (`ladybug` icon with tooltip). Opens a
  pre-filled email containing app version, build, macOS version, hardware model,
  number of configured outputs and routing state. Device *names* are deliberately
  omitted, they frequently contain real names. `ProcessInfo.systemUptime` is
  deliberately omitted, it is a required-reason API and would force a
  `PrivacyInfo.xcprivacy` entry. Falls back to GitHub Issues if no mail client is
  configured.

### Changed
- **Wave header redraw is now driven by audio, not by the display**: 60 fps while
  routing, nothing at all when idle. Previously it ran unbounded via
  `TimelineView(.animation)` regardless of whether anyone was looking.
- **Waveform scrolls smoothly instead of stepping**. The IOProc pushes one column
  per CoreAudio callback, about 86 per second at 44.1 kHz with 512 frames, which
  is 172 pt/s across 2 pt columns. Redrawing at 60 fps means 2.87 pt per frame,
  not a multiple of the 2 pt column width, so the picture advanced by one column
  on some frames and two on others. Raising the frame rate cannot fix that, it is
  arithmetic. `WaveformBridge` now measures its own push interval and reports a
  phase, and the canvas offsets the drawing by a fraction of a column.
- **Waveform amplitude no longer jumps** as loud transients enter and leave the
  visible window. The normalisation reference is smoothed across frames with a
  fast attack and a slow release, the same shape as the level meters.

### Note for existing users
- Build number moves from 7 to 8. `hasValidLaunchAtLoginConsent()` validates the
  stored consent against the build number, so **"Launch at Login" has to be
  enabled once more after updating**. This is intended behaviour under Guideline
  2.4.5(iii): the build-number binding is what prevents a Login Item from
  surviving an app update without fresh consent.

---

## [4.0.0 (7)], 2026-08-13

### Fixed
- Guideline 2.4.5(iii): Replaced implicit UserDefaults-based consent check with
  explicit per-build NSAlert consent dialog for Launch at Login. Consent is now
  tied to the current build number, preventing stale UserDefaults from previous
  test sessions from silently re-enabling auto-launch after app updates.
  `ensureLoginItemCompliance()` now clears outdated consent keys and always
  unregisters unless consent was explicitly granted for the current build.

All notable changes to AudioRouterNow are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Full technical details for each release: [RELEASE_NOTES.md](RELEASE_NOTES.md)

---

## [v4] AudioRouterNow 4, Mac App Store

> **Versioning note:** v4 follows Apple's App Store versioning (`Version 1.0`, Build `4.0.0`).
> v3 continues as the legacy open-source release and uses its own semver track.

---

## [4.0.4], 2026-08-11 · _Mac App Store (macOS 14.4+)_, Re-Submit Build 6

### Fixed
- **App Store screenshot headline**, the replacement screenshot introduced in Build 5 still contained the words "free" and "Free forever" in the headline text ("A free & easy to use alternative to paid routing apps. Free forever. Open source."). Apple's Guideline 2.3.7 explicitly states that "references to free or discounted services are considered a price reference and are not appropriate for app metadata." Headline replaced with "Route your Mac's audio to multiple outputs simultaneously." and subtitle "Open source · No drivers · No setup required", no pricing language of any kind.
- **Build archive stale-cache issue**, Build 5 was archived without running "Product > Clean Build Folder" in Xcode beforehand. Xcode reused cached compiled objects from Derived Data, causing the binary to include the old OnboardingView UI (with the Launch at Login checkbox) despite the source code being correct. For Build 6, Derived Data was fully deleted (`~/Library/Developer/Xcode/DerivedData/`) before archiving, and the app was verified locally (no checkbox visible in onboarding) prior to submission.

---

## [4.0.3], 2026-08-09 · _Mac App Store (macOS 14.4+)_, Re-Submit Build 5

### Fixed
- **Launch at Login removed from onboarding**, the "Launch at Login" checkbox has been removed from the first-launch onboarding screen entirely. Showing any auto-launch control at startup, even unchecked, was interpreted by Apple Review as the app presenting auto-launch capability at first launch (Guideline 2.4.5(iii)). Launch at Login is now exclusively controlled via the dedicated menu toggle, which requires an explicit deliberate user action and is always off by default. The `ensureLoginItemCompliance()` gate (introduced in Build 4) remains active on every app launch, ensuring no Login Item can exist without explicit user consent.
- **Removed unreachable `SMAppService.register()` branch from onboarding callback**, after the checkbox removal, the `onContinue` callback in `AudioRouterNowApp` still contained an `if launchAtLogin { register() }` branch that could never execute (OnboardingView always passes `false`). Removed to eliminate any static-analysis ambiguity: `register()` is now called exclusively from the explicit menu-toggle `didSet`. The onboarding callback now unconditionally sets the opt-in key to `false` and calls `unregister()` (no-op if nothing is registered) to clear any residual registration from older builds.

### Changed
- **App Store screenshot**, replaced screenshot that showed the Support Tip Jar with visible pricing ($1.99 / $4.99). App Store screenshots may not include price references per Guideline 2.3.7. The new screenshot shows the app in its standard routing state.
- **App Review Notes**, added screen recording demonstrating the complete user flow and a successful sandbox in-app purchase (Guideline 2.1(b) requirement).

---

## [4.0.2], 2026-08-07 · _Mac App Store (macOS 14.4+)_, Re-Submit Build 4

### Fixed
- **Login Item is now unregistered unless explicitly opted in**, a Login Item registered by an earlier build (before the opt-in default) survived app updates because macOS binds `SMAppService` registrations to the bundle ID, not the binary. On every launch the app now enforces a compliance gate: unless the user has explicitly enabled "Launch at Login", any existing registration is removed. This fully resolves the recurring Apple Review rejection (Guideline 2.4.5(iii)), the previous build only changed the default for *new* installs and could not clear a pre-existing registration. Explicit opt-in is tracked via a dedicated `launchAtLoginExplicitlyOptedIn` flag set only by a deliberate user action (onboarding checkbox or menu toggle).

### Changed
- **Support page**, added a dedicated support page at `audiorouternow.mauriciomorkun.com/support/` with a getting-started guide, troubleshooting, FAQ, and direct contact (email + GitHub Issues). Resolves Apple Review note (Guideline 1.5) that the previous Support URL (GitHub Issues) did not present usable support information.

---

## [4.0.1], 2026-08-05 · _Mac App Store (macOS 14.4+)_, Re-Submit Build 3

### Fixed
- **Launch at Login defaults to off**, the onboarding toggle was previously checked by default, causing the app to register as a Login Item without explicit user consent. The toggle now defaults to unchecked; users must actively opt in. Fixes Apple Review rejection (Guideline 2.4.5(iii)).

---

## [4.0.0], 2026-07-24 · _Mac App Store (macOS 14.4+)_

### Added, Complete Swift Rewrite
- **Process Tap architecture**, replaces the HAL plugin + C helper + Python stack entirely. Audio is captured via `CATapDescription` (Apple's sandboxed, public Process Tap API) and fanned out through a `CoreAudio` IOProc on an in-process Aggregate Device. No driver installation, no helper process, no admin password required.
- **Stable Output Mode**, a 🔒 lock toggle (default ON) in the footer prevents macOS from switching the system output when a Bluetooth device auto-connects. Audio routing continues uninterrupted; volume keys remain bound to the locked device. Persisted via UserDefaults.
- **Bluetooth volume fix**, volume keys now correctly follow Bluetooth devices. `VolumeTracker` probes `kAudioObjectPropertyElementMain` first, then falls back to channel elements 1 and 2 for devices (e.g. AirPods, Sony WH-1000XM series) that only expose per-channel volume scalars. Software-volume mode handles devices with no hardware volume property.
- **Tip Jar (StoreKit 2)**, optional, non-blocking in-app purchases: Coffee ☕ ($1.99) and Beer 🍺 ($4.99). App is fully functional without purchase.
- **Live waveform**, animated peak meter in the menu bar header (per-channel RMS + peak hold, 60 fps via `CADisplayLink`).
- **Animated device cards**, DeviceCard with live volume ring, status indicator, routing latency display.
- **Accordion routing panel**, progressive disclosure; channel pair selection per device.
- **macOS 14.4+ only**, required by the Process Tap API (`kAudioHardwarePropertyProcessTapList`).
- **Apache 2.0 license**, replaces GPL-3.0 for the v4 codebase; App Store compatible.
- **Sandboxed**, full App Store sandbox. No helper process, no driver, no kernel extension.

### Architecture
- `AudioRouterKit`, standalone Swift Package (FanOutEngine, VolumeTracker, DeviceLifecycleManager, ProcessTapCapture)
- `AudioRouterNow4`, SwiftUI + MenuBarExtra app target (EngineController, MenuBarView, WaveHeaderView, DeviceCardView, RoutingControls, TipJarView)
- Thread model: CoreAudio IOProc on realtime thread; UI on `@MainActor`; lifecycle on dedicated serial queue

---

## [3.4.5], 2026-09-18 · _Legacy (macOS 11+, direct download)_

### Fixed
- **Driver installation failed on first launch when `/Library/Audio/Plug-Ins/HAL/` did
  not exist** ([#1](https://github.com/mauriciomorkun/AudioRouterNow/issues/1)). `cp`
  does not create parent directories, so the copy aborted with ENOENT on systems where
  no HAL plug-in had ever been installed. The installer now runs `mkdir -p` on the
  target directory first, in both the script and the fallback path.
- The post-install verification dialog no longer shows the self-contradictory message
  *"The driver was installed but is missing at the expected path"*. It now states that
  the installation failed, prints the exact commands to diagnose (`ls -la`) and work
  around (`sudo mkdir -p`) the problem, and points to the log file. The actual state of
  both paths is written to the log.

> **Note on 3.4.0–3.4.4:** the installer script ended with `echo`, so its exit code was
> always 0 regardless of whether `cp` succeeded. A failed copy was reported as success.
> The error check (`cp -Rf … || exit 1`) was committed in `7f951d4` but never shipped in
> a release, 3.4.5 is the first release to contain it.

---

## [3.4.4], 2026-06-30 · _Legacy (macOS 11+, direct download)_

### Fixed
- Devices with non-ASCII characters in their CoreAudio UID (e.g. CJK characters from serial numbers) are now correctly routed, previously the helper received `\uXXXX` escape sequences instead of actual UTF-8 bytes, causing `find_device_by_uid()` to fail with "not found" despite the device being present and functional

---

## [3.4.3], 2026-06-30

### Fixed
- NSPopover is now the default menu for all users, including fresh installs, `use_popover_menu` default changed from `False` to `True`
- Existing users who had the old NSMenu persisted in their config now automatically receive the NSPopover after updating, one-time migration via `popover_migrated` flag in `AppConfig`; fires once on first launch, immediately persisted to survive force-quit/crash; a manual revert to `use_popover_menu: false` is respected afterwards
- Uninstaller no longer freezes the app for 30+ seconds, `uninstall_all()` now runs in a background thread with a polling timer; the UI stays responsive throughout
- Reentrancy guard on the Uninstall menu item prevents double-trigger when the menu stays open (NSPopover)
- App now reliably quits after a successful uninstall, `rumps.quit_application()` called from the main thread after the background worker completes

---

## [3.4.2], 2026-06-29

### Added
- Help → Status Guide, native `NSAlert` colour legend explaining all three menu bar icon states (🟢 routing active, 🟡 warning, 🔴 error) and the scenarios that trigger each
- Persistent `NSPopover` menu (behind `use_popover_menu` flag), the menu now stays open after each click so you can select multiple outputs and change settings without reopening it; closes on outside click
- Brand logo asset set in `assets/logo/`, Inline and Stacked variants, Black and White, each as SVG + PNG

### Fixed
- Audio now audible on all fan-out outputs after routing switch, HW volume of physical targets was frozen at previous (often near-zero) level; now carried across from the previous system default on every switch
- No more ~10 s audio drop-out on other outputs when a 3rd device is added, healer grace period (2 s) prevents unnecessary reconnect during coreaudiod transport restart
- Devices without software volume control (hardware-pot interfaces) correctly skipped during volume propagation
- Menu bar icon stays green when audio routes fine despite an unavailable configured device, turns orange only when zero outputs are available (status text keeps the `(N unavailable)` counter)
- Three NSPopover follow-up warnings resolved, status rows clickable inside the popover, status line updates live while the popover is open, and a 0.15 s flicker guard on icon toggle
- Action items in NSPopover (Quit, Status Guide, docs, etc.) no longer render with spurious checkboxes, only toggle items (output devices, sample rate, safe mode) use checkbox style
- Channel pairs for multi-channel devices are now always visible in the NSPopover, even when the device is inactive, sub-rows (Ch 1-2, Ch 3-4, …) appear greyed-out so users can discover channel selection before activating the device

### Changed
- Version number is now single-sourced from `engine/version.py`
- Config save now merges with existing file instead of overwriting, unknown fields (e.g. feature flags from newer versions) survive round-trips through older installed app versions (`APP_VERSION = "3.4.2"`), `installer/AudioRouterNow.spec`, `installer/build_local.sh`, and `driver/resources/Info.plist` all derive from it; build fails on divergence (4 previously hardcoded strings eliminated)

---

## [3.4.1], 2026-06-25

### Fixed
- Routing status now reflects actual IOProc state, not saved device selection
- Missing/unplugged devices shown as `⚠ unavailable` instead of silently disappearing
- All user-facing error messages translated to English
- Diagnostic report now includes SYSTEM AUDIO STATE and FAN-OUT sections

---

## [3.4.0], 2026-06-13

### Fixed
- Audio no longer silent after fresh installation (SHM permissions: `umask(0)` + `0666` world-readable)
- Audio clock deadlock resolved, `GetZeroTimeStamp` now uses a freely-running `mach_absolute_time()` clock
- Zombie helper prevention, stale helper processes from previous versions are automatically detected and replaced on launch
- Version negotiation between app and helper prevents split-brain after updates

### Changed
- Helper binary search path: HAL path (`/Library/Audio/Plug-Ins/HAL/…`) now has priority over PyInstaller bundle path
- Helper version field added to all `get_status` responses; helpers below `MIN_HELPER_VERSION` (3.3.0) are auto-replaced

---

## [3.3.1], 2026-06-11

### Fixed
- Version string inconsistency: helper, driver, and app now all report `3.3.1`

---

## [3.3.0], 2026-06-11

### Added
- Automated health monitoring with self-healing (Healer module)
- Zombie helper detection

### Fixed
- Single-instance enforcement
- Several stability improvements under concurrent audio device changes

---

## [3.2.0], 2026-06-10

### Added
- First stable release with full audio routing
- Menu bar UI with device selection
- HAL audio driver + C helper + Python engine architecture
- One-click system audio switch

---

## Earlier versions (v2.x)

v2.9.0, v2.8.x, v2.7.0, Pre-release development iterations.  
Not publicly documented; architecture was significantly revised for v3.x.
