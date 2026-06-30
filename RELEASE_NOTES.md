# AudioRouterNow — Release Notes

## How to read this document

Each release contains **two sections**:

- **For Everyone** — Plain language. What changed, whether it affects you, and what (if anything) you need to do.
- **For Power Users** — Technical details: root causes, implementation notes, affected components. Skip this if you just want to know if you should update.

---

## v3.4.3 — June 30, 2026

### For Everyone

**The persistent menu is now on by default — and the uninstaller no longer freezes.**

This release makes the improved menu interface (which stays open while you work) the standard experience for all users, including those updating from an earlier version. It also fixes the uninstaller, which could freeze the app for 30+ seconds and sometimes fail to quit afterward.

- **Persistent menu for everyone.** The menu that stays open while you select devices, change sample rates, or explore settings is now the default for all users — including those who had already installed an earlier version. No configuration needed.
- **Uninstaller no longer freezes.** Clicking "Uninstall AudioRouterNow…" previously caused a long freeze (macOS spinning wheel, 30+ seconds) because the uninstall process ran on the app's main thread. It now runs in the background — the menu bar shows "Uninstalling…" and the app quits cleanly once done.
- **Double-click protection on Uninstall.** Since the menu stays open, it was possible to accidentally trigger the uninstaller twice. This is now prevented.

No action required. Update normally.

### For Power Users

| Fix | Component | Root Cause | Resolution |
|-----|-----------|------------|------------|
| **NSPopover as default** | `engine/config.py` | `use_popover_menu` defaulted to `False`; new installs always received the legacy NSMenu. | Default flipped to `True` in both the `AppConfig` dataclass field and `from_dict()`. |
| **One-time migration** | `engine/config.py` | Existing users had `use_popover_menu: false` already persisted in `~/.audiorouter/config.json`; a default change alone wouldn't reach them. | `popover_migrated` flag added to `AppConfig` (default `True` for new installs; `False` sentinel for legacy configs). On first load of a pre-3.4.3 config (key absent → `data.get("popover_migrated", False)` = `False`), `from_dict()` forces `use_popover_menu=True` and sets `popover_migrated=True`. `load_config()` immediately persists via `save_config()` to survive force-quit/crash. After migration, a manual `use_popover_menu: false` is respected (no re-override). |
| **Uninstall main-thread freeze** | `engine/menu_bar_app.py` | `_uninstall()` called `first_launch.uninstall_all()` synchronously on the main thread. `uninstall_all()` contains `time.sleep(2.0)` + `subprocess.run(osascript + killall coreaudiod, timeout=60)` — together ~30 s of main-thread blocking → macOS spinning wheel, `rumps.quit_application()` not reached reliably. | `_uninstall()` now starts a daemon worker thread (`arn-uninstall`) that runs `uninstall_all()`. A `rumps.Timer` (0.3 s interval) in `_uninstall_poll_result()` collects the result on the main thread and calls `quit_application()`. `os._exit(0)` added as a 3 s hard-exit fallback (triggered only if `terminate_()` somehow doesn't propagate). `killall coreaudiod` shell command is unchanged. |
| **Reentrancy guard** | `engine/menu_bar_app.py` | NSPopover stays open after a click, making it possible to invoke `_uninstall()` a second time while the worker is already running — spawning a second thread and a second osascript admin prompt. | `self._uninstalling` flag checked at entry; set on entry, cleared on cancel/error in `_uninstall_poll_result()`. Success path quits the app, so no reset needed there. |

**Audit:** All fixes passed dual Opus audit (`@root-cause-analyst` + `@validator`, parallel, both Opus) in a single iteration with zero critical and zero major issues. One cosmetic finding (`getattr` fallback) resolved in cleanup commit.

**Commits:** `55bf7f0` (NSPopover default), `60331cd` (uninstall background thread), `6101587` (reentrancy guard + audit cleanup), `5d43f06` (one-time migration v3.4.3), `6689cfb` (getattr simplification)

---

## v3.4.2 — June 29, 2026

### For Everyone

**Audio reliability fixes plus a friendlier, more informative menu.**

This release fixes two audio issues that could leave secondary outputs silent, and reworks the menu so it stays open while you work and explains its own status.

**Audio fixes:**

- **All your outputs are now audible after routing.** When AudioRouterNow takes over your system audio, it now carries your current volume level across to every device it routes to, instead of leaving them at whatever (sometimes silent) hardware level they were set to. Outputs you've deliberately set loud are left exactly as they are.
- **No more brief drop-outs when adding a third output.** On setups with three or more audio outputs (common on Mac mini), adding another output could cause the others to cut out for about ten seconds while macOS reconfigured its audio transport internally. AudioRouterNow now rides through that transition smoothly. Genuine audio failures are still recovered automatically.

**Menu & status improvements:**

- **The menu stays open while you set things up.** Previously the dropdown closed after every single click, so selecting several outputs or changing sample rates meant reopening it again and again. The menu now stays open as you work and closes when you click away.
- **The menu bar icon no longer cries wolf.** If one of your configured devices is unplugged but audio is still routing fine to the others, the icon now stays green instead of turning orange. It only turns orange when no outputs are available at all. The menu still notes "(N unavailable)" so you stay informed.
- **New: Help → Status Guide.** A built-in colour legend explains exactly what 🟢 green, 🟡 orange, and 🔴 red mean and when each appears — no need to guess or look it up.

No action required. Update normally.

### For Power Users

#### Audio fixes

| Fix | ID | Component | Root Cause | Resolution |
|-----|----|-----------|------------|------------|
| **W2-1** | H7 | `engine/audio_device_control.py`, `engine/menu_bar_app.py` | When "Audio Router" becomes the system default, `set_default_output_volume()` drives only the virtual device's `volume_q16`. Physical fan-out targets retain their frozen HW volume (often near zero) — silence despite a working IOProc. bogdanw confirmed: pre-selecting the internal speaker (already loud) → audible; U3277WB/Pebble V3 (frozen low) → silent. | `get_device_volume_scalar()` / `set_device_volume_scalar()` read/write per-device HW volume via `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (falling back to `kAudioDevicePropertyVolumeScalar` per channel). `equalize_volume_after_switch(prev_level, target_uids)` called at all three switch sites: reads previous default's level before switch, sets virtual device to that level after switch, raises any physical target below `LOW_VOLUME_THRESHOLD` (15%) to `raise_to` (or `COMFORTABLE_FALLBACK_VOLUME` = 50% if prev level itself was sub-15%). Devices without software volume control are skipped silently (`get_device_volume_scalar` returns -1.0). Devices ≥15% are left untouched (user intent preserved). All CoreAudio calls on main thread; CFStrings released. |
| **W2-2** | H8 | `engine/healer.py`, `engine/menu_bar_app.py` | Adding `BuiltInSpeakerDevice` as a 3rd output to the AVAudioSession forces coreaudiod to restart the IOWorkLoop (`HALC_ProxyIOContext:1593 "ending the transport"`), transiently stalling already-running outputs. The healer's 1600 ms stall window (`1000 ms` soft-stall + `3×200 ms` persist polls) detected this as a real failure and called `reconnect_output` — producing a visible ~10 s "Output removed/re-added" churn cycle. | `notify_output_added()` in `Healer` records `time.monotonic()` of each genuine output add (detected by set-diff in `_apply_active_outputs`). Grace-period check in `_process_output` suppresses `reconnect_output` for `GRACE_PERIOD_S = 2.0 s` after any add, provided `ioproc_age_ms ≤ HARD_STALL_MS` (5000 ms). Hard stalls (device truly gone) still heal immediately even during the window. State is thread-safe under the existing `self._lock`. |

**Audit:** Both audio fixes passed two independent line-by-line audits (SuperClaude `root-cause-analyst` + Claude `validator`, both Opus) in a single iteration with zero critical and zero major issues.

#### UI / UX changes

| Change | ID | Component | Detail |
|--------|----|-----------|--------|
| **NSPopover menu** | `use_popover_menu` | `engine/menu_bar_app.py` | The rumps/`NSMenu` dropdown is replaced by a persistent `NSPopover` toggled from the `NSStatusItem`, gated behind a `use_popover_menu` flag. The popover stays open across clicks (multi-device selection, sample-rate changes, Help navigation) and dismisses only on outside click (transient behavior). All callbacks and dynamic updates preserved; all AppKit calls guarded to the main thread. |
| **NSPopover hardening** | 3 warnings | `engine/menu_bar_app.py` | Follow-up audit fixes: (1) status rows are clickable inside the popover — `restart_helper` / `reinstall_driver` / `switch_audio` dispatched via `action_key`; (2) the status line updates live while the popover is open (`refresh()` in `_update_status_ui()`, main-thread safe); (3) flicker guard on icon toggle — if the popover is shown, close only (no reopen), with a 0.15 s monotonic debounce against the `popoverDidClose_` transient-dismiss race. |
| **NSPopover checkbox fix** | UX | `engine/popover_menu.py`, `engine/menu_bar_app.py` | All `Row` items defaulted to `kind="item"`, which `_viewForRow_` rendered as `NSSwitchButton` (checkbox). Pure action items (Quit, Status Guide, Open documentation, Check for Updates, Save Diagnostic Report, Uninstall, Support, System Audio toggle, footer) do not have a persistent checked state and looked wrong with checkboxes. Added `kind="action"` row type rendered as borderless `NSButton` (plain text, no checkbox). Toggle items (output devices, sample rates, safe mode) keep `kind="item"` and their checkbox. |
| **Channel pairs always visible** | UX | `engine/menu_bar_app.py` | Channel-pair sub-rows (Ch 1-2, Ch 3-4, Ch 5-6) for multi-channel devices previously only appeared after the device was activated, making the channel-selection feature invisible to users who hadn't yet tried a multi-channel device. Sub-rows now render at all times, greyed-out (`enabled=False`) when the parent device is inactive. Activating the device enables them. `selected` flag guarded with `is_active and` to prevent stale checkmarks. |
| **Icon colour logic** | UX | `engine/menu_bar_app.py` | Menu bar icon stays green when ≥1 output is active and routing works, even if a configured device is unavailable. Turns orange only at zero available outputs. Status text keeps the `(N unavailable)` counter for transparency. Fixes the misleading orange icon that alarmed users while audio was working fine. |
| **Status Guide** | UX | `engine/menu_bar_app.py` | New `Help → Status Guide` item opens a native `NSAlert` colour legend describing all three icon states (🟢 routing active, 🟡 warning, 🔴 error) with the specific scenarios that trigger each. |

#### Build & assets

| Change | Component | Detail |
|--------|-----------|--------|
| **Single-source version** | `engine/version.py`, `installer/AudioRouterNow.spec`, `installer/build_local.sh`, `driver/resources/Info.plist` | Four independent hardcoded version strings replaced by true single-source derivation from `engine/version.py` (`APP_VERSION = "3.4.2"`). The spec reads `APP_VERSION` via `exec()`; `build_local.sh` reads it via `sed` and adds a version-gate that fails on divergence; the driver `Info.plist` is set to `3.4.2`. Found and fixed during the Wave-2 local build audit (2 audit iterations, both PASS). |
| **Logo assets** | `assets/logo/` | Brand logo set added: Inline and Stacked variants in Black and White, each as SVG + PNG. |
| **Config merge-save** | `engine/config.py` | `save_config()` previously overwrote the JSON file with only the fields known to `AppConfig`, silently dropping any keys added by newer app versions. If the older installed app saved config (e.g. after a sample-rate change), `use_popover_menu` and future flags were lost. Fix: read existing file first, spread unknown keys, then overwrite known fields — forward-compatible with all future flag additions. |

**Commits:** `722ee69` (W2-1 + W2-2), `6b05285` (case analysis + fix plan), `da2b5d8` (icon colour), `00e4084` (Status Guide), `767d147` (NSPopover), `390bc53`/`dda961c` (NSPopover hardening), `3b57f14` (single-source version), `7901afc` (NSPopover checkbox fix), `db5db60` (config merge-save), `83ef0d1` (logo assets), `730e4a1` (channel pairs always visible)

---

## v3.4.1 — June 25, 2026

### For Everyone

**Improved feedback, status display, and diagnostics.**

This release addresses issues discovered from user feedback: the app's status indicator was showing "Routing active" even when no audio was actually routing, device names could silently disappear from the menu, and some error messages were shown in German regardless of system language.

- **Accurate routing status** — The status indicator now reflects whether audio is actually flowing, not just whether a device was selected. If routing fails, you'll see a clear error state instead of a misleading green icon.
- **Missing devices are now visible** — If a device you had selected is no longer available (e.g. unplugged), it now appears marked as unavailable in the menu instead of silently disappearing.
- **Diagnostic report improved** — The built-in diagnostic report now includes system audio state and fan-out status, making it easier to identify audio issues.
- **English error messages** — All user-visible error messages are now in English.

### For Power Users

| Fix | ID | Component | Root Cause | Resolution |
|-----|----|-----------|------------|------------|
| **H2** | Status-UI | `engine/menu_bar_app.py` | Status string read `_active_device_names` (saved selection) not `resp['active']` (real IOProc state). Showed "Routing active — 2 devices" even when fan-out was dead. | 7-state matrix reading `status['active']`, `is_audio_router_default()`, and `ioproc_calls` progression. |
| **H5** | Stale-Config | `engine/menu_bar_app.py` | Devices missing from current HAL scan were silently skipped at `menu_bar_app.py:1230`. | Missing devices marked `⚠ unavailable` in menu + N/M counter in status line. |
| **i18n** | | `audio_device_control.py`, `first_launch.py`, `diagnostic.py` | User-facing error strings were hardcoded in German. | All user-facing strings translated to English. |
| **Diagnostic** | Fan-out | `diagnostic.py` | Diagnostic report had no visibility into whether fan-out IOProcs were actually running. | New `SYSTEM AUDIO STATE` and `FAN-OUT` sections added; reports `active[]`, `ring_frames`, `ioproc_calls`. |

**Commits:** `7521f0b`, `a7265bd`, `7115a60`, `68ec5ec`

---

## v3.4.0 — June 13, 2026

### For Everyone

**Critical fix: No audio after fresh installation.**

After a fresh install from the DMG, AudioRouterNow appeared to run correctly (green icon, output device selected, system audio set to Audio Router) but produced no sound. This release fixes the root cause, and also prevents "zombie helper" processes (leftover old helper binaries from previous installations) from silently blocking audio on update.

- **Audio now works after fresh installation** — A macOS-specific limitation made it impossible for the audio driver to access the shared memory channel that carries audio between components. The driver was silently dropping all audio frames.
- **Audio clock deadlock resolved** — Even after the access issue, a circular dependency in the audio timing mechanism prevented audio from flowing. The clock now runs freely, as recommended by Apple's CoreAudio documentation.
- **Zombie helper prevention** — If an old helper process from a previous version is still running after an update, the app now detects it, shuts it down, and starts a fresh one automatically.
- No action required beyond updating. All fixes are automatic on first launch.

### For Power Users

| Fix | Component | Root Cause | Resolution |
|-----|-----------|-----------|-----------|
| **I-1** | Helper (C) | `fchown()`/`fchmod()` on POSIX SHM FDs return EINVAL on macOS — SHM kept `gid=staff/0660`. Driver host (`_coreaudiod`) not in `staff` group → `shm_open(O_RDWR)` EACCES → `gSHMRing=NULL` → all frames dropped silently. | `umask(0)` + `shm_open(O_CREAT, 0666)`. `fchown`/`fchmod`/`getgrnam` removed. Security preserved by `magic`/`version`/`size` ring integrity checks (C-1). |
| **I-2** | Driver (C) | `GetZeroTimeStamp` derived `sampleTime` from `gFramesWritten`. Circular deadlock: HAL won't call WriteMix until clock advances; clock only advances when WriteMix writes frames. | Freely running `mach_absolute_time()` clock from `gAnchorHostTime` (set at `StartIO`). Matches Apple NullAudio reference. P0-C ticksPerFrame fallback and H-4/H-5 timeline seed preserved. |
| **I-3** | Helper (C) | `Makefile` set `ARN_HELPER_VERSION "3.2.0"`; fallback `#define` was `"3.1.2"`. Neither matched `APP_VERSION = "3.3.1"`. | Both updated to `"3.3.1"`. |
| **I-4** | Engine (Python) | `_find_helper_binary()` tried PyInstaller bundle before HAL path. After a `sudo cp` binary update the bundle still held the old binary → split-brain: old helper read stale SHM segment, new driver wrote to new segment → no audio. | HAL path (`/Library/Audio/Plug-Ins/HAL/…`) now has priority. Bundle is fallback only. `HAL_HELPER` constant introduced. |
| **I-5** | Engine (Python) / Helper (C) | No version negotiation between app and helper. Old helpers had no `version` field in `get_status` — running a stale helper after an update was undetectable. | `ensure_running()` calls `_check_helper_version()` before accepting a live helper. `get_status` now always includes `"version": ARN_HELPER_VERSION` (both ready/not-ready branches). Helpers below `MIN_HELPER_VERSION = "3.3.0"` are shut down and re-spawned. `g_helper_version[]` constant and `#ifndef ARN_HELPER_VERSION` fallback moved to compile-unit start so the build succeeds without `-D` flag (e.g. Driver Makefile path). |
| **I-6** | All components | First DMG build shipped all binaries still reporting `3.3.1` (Helper, App `CFBundleShortVersionString`) and `1.0.0` (Driver `Info.plist`). Version was never bumped before the build. Verified by post-install runtime audit (Fable agent, Jun 12). | Version bumped to `3.4.0` in all four canonical sources: `helper/Makefile` (`-DARN_HELPER_VERSION`), `helper/AudioRouterNowHelper.c` (both `#ifndef` fallback and legacy define), `driver/resources/Info.plist` (`CFBundleShortVersionString` + `CFBundleVersion`), `installer/AudioRouterNow.spec` (`version`, `CFBundleVersion`, `CFBundleShortVersionString`). I-5 zombie-detection now unambiguously distinguishes v3.3.x from v3.4.0 at runtime. |

### Post-Install Verification (Jun 12, 2026)

Runtime audit performed after fresh DMG install confirmed all fixes active:

| Component | Verified |
|-----------|---------|
| SHM permissions | `0666 world-rw` — I-1 confirmed |
| IOProc clock | 33 k+ stable calls, `ioproc_age_ms: 8`, zero deadlock — I-2 confirmed |
| Helper spawn path | HAL path used, SHA-256 HAL = Bundle — I-4 confirmed |
| Version negotiation | Socket returns `"version": "3.4.0"` ≥ MIN — I-5 confirmed |
| Zombie processes | None (Z-status check clean) |
| Error logs | `helper.err` 0 bytes, `helper.log` clean |
| Audio routing | 2 active routes (Komplete Audio 6 MK2 Ch1-2 + Ch3-4), `underruns: 0`, `stalls: 0` |

---

## v3.3.1 — June 11, 2026

### For Everyone

- **Better security**: The audio data channel between AudioRouterNow's components is now strictly private — other user accounts on the same Mac can no longer access it.
- **Stability**: Fixed a theoretical race condition in the self-healing module that could have caused crashes under very specific timing conditions.
- No action required. Update normally.

### For Power Users

| Fix | Component | Description |
|-----|-----------|-------------|
| **H-1** | Helper (C) | Removed dead `coreaudiod_watchdog_tick()` function — unreachable since F6 removed the call site in v3.3.0. Also removed `find_coreaudiod_pid()`, `read_proc_cpu_ns()`, `outputs_stop_all_thread()` and three unused includes (`sys/sysctl.h`, `sys/proc_info.h`, `libproc.h`). |
| **H-2** | Helper (C) | POSIX SHM now uses `0660 + gid _coreaudiod` (resolved dynamically via `getgrnam()`, fallback 202) instead of `gid 61` (localaccounts). Only the owner process and `_coreaudiod` can access the audio ring buffer. |
| **H-4/H-5** | Driver (C) | `GetZeroTimeStamp outSeed` now uses an atomic counter `gTimelineSeed` (incremented on `StartIO` and `PerformDeviceConfigurationChange`) instead of a hardcoded `1`. Correct per macOS HAL spec for multi-device timeline sync. |
| **H-6** | Engine (Python) | `Healer` class now uses `threading.Lock` in all public methods. Fixes a race condition between `process()` (health-poll thread, 200 ms) and `reset_all()` (UI timer thread, 500 ms). |

---

## v3.3.0 — June 11, 2026

### For Everyone

**Freeze-Prevention & Security release — prevents system freezes, fixes an audio startup deadlock, and hardens the app against malformed shared memory.**

After a hard reboot caused by the app freezing the entire system during teardown, a full root-cause analysis identified 15 issues. All are fixed.

What changed for you:

- **System freeze on force-quit no longer possible** — killing the app while audio was routing could cause the audio subsystem to spin at 100% CPU, freezing the entire machine. The audio helper now has a hard 5-second exit deadline with a guaranteed kill path.
- **Audio starts reliably after launch** — a logic error introduced in the previous patch caused the health monitor to silently never contact the Helper on startup, leaving all auto-recovery inactive from the first second.
- **Menu bar never freezes when Helper is unresponsive** — the 0.5s UI timer now reads from a background cache instead of making live system calls.
- **Installation is safer on multi-user Macs** — the driver install script now uses a unique temp file name (no predictable path an attacker could pre-create).
- **SHM size validation** — the audio driver now validates the shared memory segment size before mapping it. A malformed or too-small segment previously could cause a system-wide audio crash (coreaudiod SIGBUS). Now the driver safely skips invalid segments.

**Who is affected:** All users. Update by reinstalling from the new DMG.

---

### For Power Users

**Root Cause of the System Freeze (11. Juni 2026):**
1. Python app killed → Helper orphaned (`start_new_session=True`)
2. SIGTERM → `pthread_join` hung: `volume_poll_thread` blocked in Mach-IPC to degraded coreaudiod
3. Additional kills had no effect (handler only set `g_running=0`)
4. `sudo killall coreaudiod` → HAL clients froze; new coreaudiod loaded plugin with device-clock race
5. `GetZeroTimeStamp` returned rate≈0 → coreaudiod RT-thread busy-spun → system freeze

| Fix | Component | Root Cause | Resolution |
|-----|-----------|-----------|-----------|
| F1 | Helper (C) | No kill-path for stuck pthread_join | Double-SIGTERM → `_exit(1)`; `SIGALRM` + `alarm(5)` as hard 5s backstop |
| F2 | Helper (C) | `outputs_stop_all()` called before flag-file → Watchdog never fired | Flag-file → `g_watchdog_tripped=1` → `outputs_stop_all` in detached pthread |
| F3 | Driver (C) | `GetZeroTimeStamp` returned rate≈0 when no IO → coreaudiod RT busy-spin | Fallback to `mach_absolute_time()` when `gFramesWritten=0`; hybrid-clock clamp |
| F4 | Python | Helper survived after SIGTERM timeout | SIGKILL escalation: terminate→2s→`proc.kill()` |
| F5 | Helper (C) | Double-`munmap` race between signal handler and watchdog | `atomic_exchange(&g_ring, NULL)` before `munmap` |
| F6 | Helper (C) | `proc_pid_rusage()` in volume_poll_thread could block → `pthread_join` hung | Entire coreaudiod CPU-poll section removed |
| F7/M1 | Helper (C) | `set_rt_priority()` Mach-IPC call could hang | Function removed entirely |
| F8 | Python | `ping()` on rumps main thread → 5s freeze when Helper unresponsive | Replaced with `_cached_status(max_age=1.5)` |
| F9 | Python | Lock file open had TOCTOU race | `os.open(O_RDWR\|O_CREAT)` + `os.fdopen` + seek/truncate |
| N6 | Driver (C) | `gDeviceIsRunning` stuck at 0 after Zombie-Helper StopIO | Guard removed; `gSHMRing != NULL` is sole guard; self-heal on WriteMix |
| MC-5 | Python | `~/.audiorouter` created with mode 0755; C-Helper requires 0700 | `_ensure_secure_base_dir()`: `mkdir(0o700)` + `os.chmod(0o700)` |
| K1 | Python | `_health_poll_loop` guard prevented `get_status()` when `alive=False` → permanent deadlock | Loop restructured: `get_status()` always called first |
| H1 | Helper (C) | `process_hotplug_removals` / `sr_reinit_all_outputs` raced with in-flight `output_add` | Both skip `active=false` slots; local `new_proc_id` committed under lock |
| H3 | Python | `log_out`/`log_err` FDs never closed after `Popen()` | `try/finally` closes parent FDs immediately after spawn |
| H4 | Python | Healer + trip notifications not reset on Helper respawn | `healer.reset_all()` + `_notified_trips.clear()` on alive `False→True` |
| H5 | Python | Shell-injection in install/uninstall paths | All path interpolations replaced with `shlex.quote()` |
| H6 | Build | `HELPER_DST` hardcoded to `Contents/Frameworks/` (wrong for PyInstaller 6.x) | `find(1)` locates binary dynamically |
| H7 | Python | Install script at predictable `/tmp/.arn_install.sh` without `O_EXCL` | `tempfile.mkstemp()` — unique temp file, `O_CREAT\|O_EXCL` internally |
| H8 | Python | `is_audio_router_default()` (CoreAudio Mach-IPC) on 0.5s UI timer tick | Cached in health-poll thread (`_router_is_default`); timer reads cache |
| C1 | Driver (C) | `mmap` without `fstat` size check → SIGBUS in coreaudiod if SHM too small | `fstat` guard at all 3 mmap sites; close+skip if `st_size < ARN_SHM_SIZE` |
| P12 | Build | PyInstaller 6.x corrupts FAT→arm64 thinning (magic `0xCF→0xAA`) | `target_arch=None` in spec; `lipo -thin arm64` post-process guard |

**Commits:** `ecffc53` `7e2d3a0` `50166d4` `b6c7228`

---

## v3.2.1 — June 11, 2026

### For Everyone

**Post-release hotfix — fixes installation failure and no-audio on first launch.**

- **First-launch "Helper Error" fixed** — `~/.audiorouter` permissions 0755 vs required 0700
- **No audio on first use fixed** — `gDeviceIsRunning` race after kill-9
- **Installation wizard no longer hangs at 95%** — PyInstaller FAT-binary corruption

---

### For Power Users

| Fix | Component | Root Cause | Resolution |
|-----|-----------|-----------|-----------|
| MC-5 | Python | `~/.audiorouter` created 0755 by umask; Helper requires 0700 | `_ensure_secure_base_dir()` |
| N6 | Driver | `gDeviceIsRunning` stuck at 0 after Zombie-StopIO | Guard removed, self-heal added |
| P12 | Build | PyInstaller 6.20.0 corrupts arm64 magic byte | `target_arch=None` + `lipo` post-process |

---

## v3.2.0 — June 10, 2026

### For Everyone

**Stability & Security release — smoother hot-plug, tighter internals, and a cleaner codebase.**

If you've ever noticed a half-second of silence on your primary audio output when *another* device was unplugged, this release eliminates that completely. All other changes are under the hood — the app should feel identical, but behave better under edge-case conditions.

What's new:

- **Hot-plug silence eliminated** — removing or adding any audio device no longer interrupts outputs that weren't involved. Previously, every device change could briefly restart all active IOProcs (≤85 ms silence). Now each output only restarts when it personally needs to.
- **Pre-roll halved to 43 ms** — the brief silent buffer that fills before a new device starts playing was mistakenly calculated as 85 ms due to a samples-vs-frames mix-up. Corrected to the intended 43 ms.
- **No more stale audio on sudden clock drift** — if a device's audio clock drifts sharply beyond tolerance, the engine now outputs clean silence instead of replaying old stale frames.
- **Shared memory hardened** — the inter-process memory segment that carries audio data is now created with tighter OS-level access permissions. The correct Unix group (`localaccounts`, which includes both your user account and the macOS audio subsystem) is set at creation time.
- **Lag auto-recovery** — if an output falls more than 90% of the ring buffer behind (e.g. after a system sleep or extreme CPU load), it now automatically re-syncs instead of staying stuck behind.
- **Numerous small fixes** — mute toggle correctness, sample-rate selection, circuit breaker logic, health check startup grace period, and more (see Power Users section for full list).

**Who is affected:** All users benefit. No action required.

---

### For Power Users

**Architecture: Tombstoning replaces Swap-Remove**

The most significant change is in `output_remove_locked()` in the C Helper. Previously, removing a device output used swap-remove — the last slot was moved into the freed slot. This forced all moved IOProcs to be destroyed and re-registered with their new pointer, causing every uninvolved output to re-arm its pre-roll (85 ms silence). The new approach marks the freed slot as a tombstone (`uid[0] = '\0'`), leaving all other slots in-place. IOProcs for uninvolved outputs never see any interruption.

Key counters: `g_n_outputs` is now a monotone high-water-mark; `g_n_active_outputs` tracks the actual live count. This eliminates bugs KC-1, HC-1, HC-2, and ARC-2 entirely.

**Full list of fixes applied in this release:**

| Fix | Component | Summary |
|-----|-----------|---------|
| KC-1 | Helper | Swap-remove forced moved-IOProc restart → eliminated by tombstoning |
| KC-2 | Helper | `g_deferred_unmap_timestamp_ns`: 150 ms grace before `munmap` prevents SIGBUS when IOProc holds old `g_ring` pointer |
| KC-3 | Helper | `frac_ridx_reset_pending` (bool) → `frac_ridx_reset_gen` (uint32 generation counter) — eliminates lost-update race between volume thread and IOProc |
| HC-1 | Helper | Tombstoning: IOProcs for uninvolved outputs never restart on device change |
| HC-2 | Helper | `src_frac_ridx` of moved output no longer force-reset (no more move = no more reset) |
| HC-4 | Helper | Generation counter (KC-3) closes HC-4 race variant — same fix, two races addressed |
| H1 | Python | Mute toggle: `set_muted(current > 0.0)` → `set_muted(not get_default_output_muted())` — reads actual mute state instead of volume proxy |
| H3 | Python | Sample-rate selection: picks the rate with maximum device coverage instead of hardcoded 48 kHz fallback |
| H4 | Python | Drift persistence: 3 consecutive polls required before persisting (grace period eliminates transient drift false-positives) |
| M1 | Python | Circuit breaker: `failures` counter only incremented on actual failure (was also incrementing on success); eviction after 2 consecutive misses |
| M4 | Python | Media-key volume changes use a worker thread + queue — no more per-keypress thread spawns |
| M5 | Python | Health monitor: 3-iteration startup grace period before emitting "critical" state |
| M6 | Python | Trip notifications use `breaker_name(uid, ch_offset)` API instead of searching `sh.outputs` |
| M7 | Helper | `shutdown()` — `proc.wait()/terminate()/kill()` moved outside lock; only socket send runs under lock |
| ARC-2 | Helper | Eliminated by tombstoning (no more output moves → no more force src_frac_ridx reset) |
| ARC-3 | Python | New device debounce: reported only after 2 consecutive scans (~4 s); removals still immediate |
| ARC-5 | Helper | Lag-eviction: output > 90% ring capacity behind → forced re-sync via generation mechanism |
| N2 | Python/C | Unused imports removed across `healer.py`, `health.py`, `helper_client.py`, `diagnostic.py` |
| N3 | Python | `_notified_trips: set` initialized in `__init__` (was lazy `hasattr` init) |
| N4 | Python | `device_manager.refresh()` now fires `on_devices_changed` callback when changes detected |
| N5 | Python | `_format_sample_rate()` extracted as `@staticmethod` — deduplicates kHz formatting across menu |
| Batch 6 | Helper | `write_full()` partial-write loop; `parse_int_strict()` replaces all `atoi()`; `sigaction` with SA_RESTART; `shm_connect()` validates capacity+channels |
| Batch 7 | Helper | SHM: `shm_open(…, 0660)` + `fchmod(0660)` + `fchown(fd, -1, 61)` — gid 61 = `localaccounts` group (contains both user uid 501 and `_coreaudiod` uid 202) |
| Batch 8 | Helper | `active_buf` 4096→16384, `resp` 8192→24576; JITTER_TOLERANCE path outputs silence not stale data; non-interleaved nFrames uses `mNumberChannels`; `g_outputs_generation` counter for watchdog-race detection |
| Pre-roll | Helper | `ARN_PREROLL_FRAMES = ARN_RING_CAPACITY / 8u` (2048 frames = 43 ms @ 48 kHz) — was `/4u = 4096 frames = 85 ms` due to samples-vs-frames confusion |
| Infra | Python | `engine/version.py` — single source of truth for version number; all modules import from here |

**Commits:** `3206ee3` (M-fixes nachtrag) — followed by version bump commit

**Full technical documentation:** DOKUMENTATION.md, Kapitel 46.

---

## v3.1.2 — June 9, 2026

### For Everyone

**New: Send a diagnostic report to the developer with one click.**

If you're experiencing an issue — audio not routing, unexpected behaviour, anything unexpected — you can now send a detailed report directly from the app. No manual log hunting, no copy-pasting.

What's new:
- **Help → Save Diagnostic Report…** — generates a structured text file with your system info, current audio status, and recent log events. Mail.app opens automatically with the file already attached and the email pre-filled. Add a short description of your problem and click Send.
- If Mail.app isn't available, the file is saved to your Desktop and revealed in Finder, with a notification showing where to send it.

**Who is affected:** Everyone who ever wanted to report a bug but wasn't sure how to attach the logs.

**What you need to do:** Nothing — the menu item appears in Help automatically.

---

### For Power Users

**New module: `engine/diagnostic.py`**

- Collects: `platform.mac_ver()`, `sysctl -n hw.model`, CPU arch, Helper status (`get_status_quick()`), last 1 MB of `helper.err`, last 3 MB of `helper.log` (event tokens only — polling blocks removed via regex)
- Log extraction strategy: poll blocks (`Ring: N Frames | Outputs: N | IOProc-Calls: …`) removed via `re.sub`, then event tokens extracted by known prefixes (`Helper:`, `AudioRouterNow Helper`, `Warte auf SHM`, `SHM:`, `Helper laeuft`). Simpler and more reliable than a single event regex with lookahead + DOTALL.
- `generate_report(helper_client) → Path` saves `~/Desktop/AudioRouterNow_DiagReport_{timestamp}.txt`
- `open_mail_with_report(path) → bool` opens Mail.app via AppleScript (timeout: 20 s). Escapes backslashes and double-quotes in path.
- `reveal_in_finder(path)` — fallback via `open -R`

**`engine/menu_bar_app.py` changes:**
- `import diagnostic` added
- Help menu: new `"Save Diagnostic Report…"` item (separator before Uninstall)
- `_save_diagnostic_report()` starts a daemon thread → main thread never blocked (sysctl + 3 MB read + osascript ≤ 23 s worst-case)
- All outcome notifications via `rumps.notification` (thread-safe) rather than `rumps.alert`

**Commits:** `317f531` (feature) · Branch: `main`

**Full technical documentation:** DOKUMENTATION.md, Kapitel 45.

---

## v3.1.1 — June 9, 2026

### For Everyone

**Fixes a rare audio glitch that occurred every ~12.5 hours of continuous play.**

If you ever heard a brief (2–3 second) high-pitched constant tone followed by normal audio resuming, this was it. It happened on a fixed timer — roughly every 12 hours and 26 minutes, regardless of what was playing. The glitch was most noticeable during live streams (like WWDC) where the audio demands attention.

What's new:
- **12.5-hour periodic stall eliminated** — the root cause was a floating-point counter in the audio engine that was never reset. After ~12 hours of continuous play, the counter exceeded the valid range for a 32-bit integer conversion, causing undefined behavior and a momentary position reset in the audio pipeline.
- **No other changes** — this is a pure bugfix with no behavioral changes under normal conditions.

**Who is affected:** Anyone who uses AudioRouterNow for extended continuous listening sessions (12+ hours). The fix is invisible during normal operation.

**What you need to do:** Install the update if you experienced the periodic tone glitch.

---

### For Power Users

**Root cause:** `src_frac_ridx` (a `double` field in `DeviceOutput`) accumulates `+= ratio` (≈1.0) for every output frame in `device_ioproc()`. At 47,872 frames/s (512 frames × 93.5 calls/s @ 48 kHz), after 2^31 / 47,872 ≈ 44,739 seconds ≈ 12h 26min, `src_frac_ridx * 2.0` exceeds `UINT32_MAX = 4,294,967,295`. The cast `(uint32_t)(src_frac_ridx * 2.0)` is then **Undefined Behavior** under C11 §6.3.1.4 — on ARM64, this typically produces 0, making `behind = widx - 0 = widx >> ARN_RING_CAPACITY`, which fires the Overflow-Guard and issues a Pending-Reset.

**Log evidence:** 16 `HARD-STALL` events in `helper.err`, appearing in pairs exactly every 8,388,486–8,389,016 IOProc-calls (expected: `2^32/512 = 8,388,608`; measured deviation ±0.005%). Fully deterministic, source-independent.

**Pair structure:** The stall fires twice because the Overflow-Guard resets `src_frac_ridx = widx/2`. At the overflow moment, `widx ≈ 2^32`, so `widx/2 ≈ 2^31` — immediately triggering UB again on the next IOProc calls. The second stall (376 calls ≈ 2s later) occurs when `widx` finally wraps to a small uint32_t value, making `widx/2` small and safe.

**Fix (3 lines, commit `ff7556e`, `helper/AudioRouterNowHelper.c`):**

```c
dev->src_frac_ridx += ratio;   // line 896 (existing)

// P16: Fold to prevent float→uint32_t UB after ~12h
if (dev->src_frac_ridx >= (double)(1u << 31)) {
    dev->src_frac_ridx -= (double)(1u << 31);
}
```

**Why the fold is safe:** `2^31` is a multiple of `ARN_RING_CAPACITY = 8192 = 2^13`, so all three downstream invariants are preserved:
- `frac_as_samp = (uint32_t)(ridx*2)`: fold changes value by `2^32 ≡ 0 (mod 2^32)` → `behind` unchanged
- Ring index `(idx0*2) & RING_MASK`: `(2^31 * 2) mod (2 × 8192) = 2^32 mod 16384 = 0` → physical position unchanged
- Interpolation `frac = ridx - idx0`: integer fold, fractional part invariant

All invariants verified with full Python simulation: all MATCH=True.

**Full technical documentation:** DOKUMENTATION.md, Kapitel 44.

---

## v2.9.0 — June 1, 2026

### For Everyone

**AudioRouterNow now monitors itself and recovers from audio problems automatically.**

If your audio ever crackles, drops out, or a device freezes — the app now detects this within seconds and tries to fix it on its own, without you having to restart anything.

What's new:
- **Health indicator in the menu bar icon:** 🟢 all good, 🟡 something looks off, 🔴 a problem was detected
- **Automatic recovery:** if a device stalls, the app reconnects it automatically (up to 5 attempts, with increasing wait times between each try)
- **Smarter audio start:** a brief 43ms buffer fills before audio plays to prevent the "stuttering first second" on new devices
- **Safe mode:** a new menu option `Safe mode (no auto-healing)` — when activated, the app only monitors but never touches anything. Recommended for live recordings or concerts where any interruption is worse than the original problem
- **Better long-term stability:** an improved audio clock drift compensator (PI controller) smooths out tiny timing differences between devices over time — completely inaudible

**Who is affected:** All users benefit. No action required. The Safe mode toggle is in the menu if you need it.

---

### For Power Users

Complete implementation of the Self-Healing Layer (3 Tranches). All changes pass an independent Opus validator audit. ABI remains v4. RT thread (`device_ioproc`) has only one new line of code.

#### Tranche A — Telemetry + Health Indicator

**New atomic counters in `DeviceOutput`:** `recovery_count` (stall→healthy transitions), `g_reconnect_count` (SHM reconnects), `g_last_ioproc_call_ns` (timestamp of last real IOProc call).

**`get_status` JSON extended** with `reconnect_count`, `ioproc_age_ms` (ms since last `device_ioproc` call; 9999 if none yet), `recovery_count` per output, `fill_ewma` per output (Tranche C).

**`engine/health.py`** — new module: `OutputHealth`, `SystemHealth`, `HealthMonitor`. Three-level classification with hysteresis:
- Degradation: 2 consecutive samples (400ms)
- Recovery: 5 consecutive samples (1s)
- Critical triggers: `ioproc_age_ms > 500` (when audio flowing), `stalled=1`, new reconnect
- Degraded triggers: new underruns, SRC drift > 350 ppm, ring fill < 10% or > 95%

**`menu_bar_app.py`:** new `health-poll` daemon thread (200ms), icon ampel integrated in `_compute_status()` final branch.

#### Tranche B — Soft Out-of-RT Healing

**Pre-Roll High-Water-Mark (`device_ioproc`, RT-safe):**
```c
if (atomic_load(&dev->preroll_armed, relaxed)) {
    if (behind_p / 2u < hwm) { /* output silence, don't move position */ return noErr; }
    atomic_store(&dev->preroll_armed, 0u, release);  // self-clear at HWM
}
```
Default HWM: `ARN_RING_CAPACITY/4 = 4096 frames ≈ 43ms @48kHz`. Re-armed on every `output_add`, SHM-reconnect, and slot-swap IOProc restart.

**`reconnect_output` socket command:** `output_remove_locked` under lock → `output_add` outside lock (3-phase design, same as H1). Guards: `g_safe_take` (→ `safe_take` error), `g_shm_ready=0` (→ `shm_reconnecting` error).

**`engine/healer.py`** — new module:
- `STALL_PERSIST_SAMPLES = 3` (600ms) before first attempt
- Backoff: `[0.5, 1.0, 2.0, 4.0, 8.0]` seconds
- `MAX_ATTEMPTS = 5` → `tripped=True` → `rumps.notification`
- Breaker fully resets on output recovery
- Python-side `safe_take_getter()` check (double guard)

**Safe-Take-Modus:** `g_safe_take atomic_int` global in Helper. `set_safe_take` socket command. `config.safe_take_mode: bool` (persisted). App syncs state on start. Double guard: C (`g_safe_take`) + Python (`Healer.process()`).

#### Tranche C — PI Controller + EWMA SRC

Extends the existing P controller on `src_ratio_q20` (volume_poll_thread, 50ms, non-RT) with an I term and EWMA smoothing:

```
fill_ewma = 0.1 × fill_frames + 0.9 × fill_ewma         (τ ≈ 500ms)
error     = fill_ewma − target_frames
correction = Kp×error + Ki×Σ(error×dt)
           where Ki=0.0005, dt=0.05s, I clamped to ±300ppm
src_ratio_q20 = (base_ratio + correction) × 2²⁰          (total ±500ppm)
```

Non-atomic `fill_ewma` and `integ_error` fields in `DeviceOutput` — single writer (volume_poll_thread under `g_outputs_lock`). `get_status` reads under same lock. Zero RT-path exposure.

State resets at all discontinuities: stall-set, stall-recovery, SHM-reconnect, SR-change (both branches of `sr_reinit_all_outputs`).

Defensive clamp `if (ratio_f < 0.0f) ratio_f = 0.0f` before `uint32_t` cast (prevents UB under pathological `base_ratio`).

**All 6 `bugprone-integer-division` clang-tidy warnings resolved** (`(double)(u/u)` → `(double)u / 2.0`).

**Commits:** `628b719` → `fd3d0a5` → `f87dfa4` → `8283ffd` → `481c33c` → `c904a62` → `301adcb` (merge) → docs/version bump
**Full technical documentation:** DOKUMENTATION.md, Kapitel 28.

---

## v2.8.1 — June 1, 2026

### For Everyone

**Fixes crackling/clicking audio when routing to multiple channel pairs on the same device.**

If you were using AudioRouterNow with a multi-channel interface — for example, routing to channels 1–2 *and* channels 3–4 of the same audio interface simultaneously — you may have heard noticeable crackling or clicking. This version fixes that completely.

**Who is affected:** Anyone using two or more channel pairs on the same physical device (e.g. a Komplete Audio 6, Focusrite Scarlett with 6+ channels, or any other multi-channel USB interface).

**What you need to do:** Nothing. Install the update and the problem goes away. No settings to change.

**Upgrade path:** Replace your existing `AudioRouterNow.app` with the new one from the DMG, or let the app update itself on next launch.

---

### For Power Users

Two independent bugs combined to cause the crackling, both introduced or exposed by the v2.8.0 multi-output rework.

#### Bug 1 — Slot-Swap Invalidated IOProc `inClientData` Pointer

**File:** `helper/AudioRouterNowHelper.c` — `output_remove_locked()`

When an output is removed, the function fills the vacated slot by moving the last element of `g_outputs[]` into it (`g_outputs[slot] = g_outputs[n-1]`). However, the moved output's IOProc was registered with `inClientData = &g_outputs[n-1]` — the *old* address. After the move, `g_outputs[n-1]` is zeroed with `memset`.

On the next CoreAudio callback, the moved IOProc read from a fully zeroed `DeviceOutput` struct:
- `src_ratio_q20 = 0` → `ratio = 0.0`
- `src_frac_ridx = 0.0` → no advancement per call
- `local_ridx` stays at 0 → K2 Stall Detection fires after 1000 ms
- `underruns` counter = 0 (no underrun path hit — the `behind + JITTER_TOLERANCE < needed` check with `needed = 0` never triggers)

Once stalled, the output was excluded from `update_global_read_idx()`, causing the ring to back up. The Producer (HAL driver) dropped frames. The healthy output on channels 1–2 received silence-corrupted frames → audible crackling.

**Fix:** Before swapping, stop and destroy the moved output's IOProc. After copying the struct to its new slot (`&g_outputs[slot]`), re-register it via `AudioDeviceCreateIOProcID` with the now-stable heap address, restart it, and issue a Pending-Reset (`frac_ridx_reset_pending`) so the IOProc initializes its read position correctly.

```c
// Before: moved IOProc silently reads from zeroed memory
g_outputs[slot] = g_outputs[g_n_outputs - 1];

// After: stop → copy → re-register at new stable address → restart
AudioDeviceStop(moved_src->dev_id, moved_src->proc_id);
AudioDeviceDestroyIOProcID(moved_src->dev_id, moved_src->proc_id);
g_outputs[slot] = g_outputs[g_n_outputs - 1];
AudioDeviceCreateIOProcID(moved->dev_id, device_ioproc, moved, &moved->proc_id);
AudioDeviceStart(moved->dev_id, moved->proc_id);
// + Pending-Reset to write_idx
```

#### Bug 2 — SRC Boundary Instability at Sample-Rate Mismatch

**File:** `helper/AudioRouterNowHelper.c` — `device_ioproc()`

When the output device runs at a different sample rate than the ring (e.g. KA6 at 44100 Hz, ring at 48000 Hz), `ratio = 48000 / 44100 = 1.0884`. The IOProc computes:

```
needed_samples = floor(512 × 1.0884 × 2) = floor(1114.57) = 1114
```

Per KA6 IOProc cycle, the Producer (running at 48000 Hz) writes approximately 1114.5 samples into the ring. Due to integer truncation and hardware timing jitter:

- Sometimes `behind = 1113 < needed = 1114` → **Underrun** (`local_ridx` not updated)
- Sometimes `behind = 1115 ≥ needed = 1114` → **Normal**

Alternating underruns meant `local_ridx` effectively stalled → K2 Stall Detection would fire → Pending-Reset set `local_ridx = write_idx`, giving `behind = 0` immediately → perpetual underrun → stall loop every 1000 ms.

**Fix — 4-sample jitter tolerance:**

```c
// Before — exact boundary, no tolerance:
if (behind < needed_samples) { /* underrun */ }

// After — 4-sample (2 stereo-frame) tolerance:
const uint32_t JITTER_TOLERANCE = 4u;
if (behind + JITTER_TOLERANCE < needed_samples) { /* underrun */ }
```

At the exact boundary (`behind = 1110`, `needed = 1114`): `1110 + 4 = 1114 ≥ 1114` → accepted. The 4 missing samples at the tail are filled with silence in `memset(temp_buf, 0, ...)` — at 44100 Hz this represents ≈ 0.09 ms, completely inaudible.

**Stall timeout** also increased from 300 ms to 1000 ms to give the SRC P-controller more settle time after a rate-mismatch reconfiguration.

#### Combined Failure Sequence

1. App configures: KA6 Ch 1–2 (slot 0), BenQ Ch 1–2 (slot 1), KA6 Ch 3–4 (slot 2)
2. BenQ is removed → slot swap: KA6 Ch 3–4 moves from slot 2 → slot 0
3. **Bug 1:** IOProc for KA6 Ch 3–4 reads from zeroed slot 2 (`ratio=0`, no progress)
4. K2 Stall fires → output excluded from `read_idx` aggregation
5. Ring backs up → Producer drops frames → crackling on Ch 1–2
6. **Bug 2** (independently): At 44100 Hz / 48000 Hz boundary, alternating underruns cause secondary stall loops even after Bug 1 is fixed alone

**Commit:** `651b9fb`

---

## v2.8.0 — May 31, 2026

### For Everyone

**Major stability and reliability update.** This release completes a full security and correctness audit of all components. Most changes are under the hood — you should notice cleaner behavior on device hotplug, smoother volume control, and fewer edge-case audio dropouts.

Highlights:
- Volume keys no longer cause the menu to freeze briefly
- Plugging/unplugging devices is handled more reliably
- The app's config file is now written safely (a crash during save no longer corrupts your settings)
- A second accidental Helper process can no longer start in the background and fight with the first

**Who is affected:** All users benefit. No action required.

---

### For Power Users

Complete implementation of all CRITICAL, HIGH, and MEDIUM findings from the v2.7 deep audit. 12 fixes across 7 commits. Risk score after v2.8.0: CRITICAL 0, HIGH 0, MEDIUM 0.

| Fix | Component | Summary |
|-----|-----------|---------|
| K1+K2 | Helper | Stall-Detection: frozen `local_ridx` excluded from `read_idx` aggregation; stalled output reset to `write_idx` via Pending-Reset |
| H1 | Helper | `output_add()` 3-phase: USB SR-settle (400 ms) now lock-free; only Create+Start run under lock (<20 ms hold) |
| H2 | Helper | `g_ring` → `_Atomic(ARNSharedRing*)` + deferred `munmap` on live-reconnect (SIGBUS prevention) |
| H3 | Helper | Hot-plug listener sets atomic flag only; actual O(N) scan runs in volume-poll thread |
| H6 | Helper | `json_escape_into()` — RFC 8259-compliant escaping for UID and name in `get_status` |
| H7 | Helper | Config socket moved from `/tmp` to `~/.audiorouter/`; `umask(0177)` before `bind()` eliminates TOCTOU window |
| H8 | Python | Volume polling + media-key osascript calls moved to daemon threads; rumps event loop never blocked |
| M1 | Ring | `arn_ring_frames_available`: `read_idx` loaded with `acquire` before `write_idx` |
| M2 | Helper | `g_hotplug_registered`: `volatile int` → `atomic_int` |
| M3 | Helper | Socket `listen` backlog: 4 → 16 |
| M4 | Helper | `find_device_by_uid`: NULL-uid short-circuit skips unnecessary `device_output_channels()` call |
| M6 | Helper | `ch_offset` validation: must be even, `max_ch ≥ 2`, `ch_offset + 2 ≤ max_ch` |
| M7 | Helper | SRC: 3-tap box-average pre-filter when `ratio > 1.005` (downsampling) to reduce aliasing |
| M8 | Helper | Single-instance lock via `flock(/tmp/audiorouter.helper.lock)` |

Full technical documentation: **DOKUMENTATION.md, Kapitel 24**.

---

## v2.7.0 — May 31, 2026

### For Everyone

**Critical bug fix release.** Fixes audio silence after the Helper process restarts, and resolves rare audio timing glitches.

- Helper restart (e.g. after coreaudiod reload) now reliably reconnects without silence
- Volume control timing is more accurate
- App settings survive a crash during save

---

### For Power Users

8 fixes from the first audit pass, all targeting RT-correctness and thread-safety:

| Fix | Component | Summary |
|-----|-----------|---------|
| K3 | Driver + Ring | `instance_id` field in SHM header (ABI v4); Watch-Thread compares instance IDs instead of inodes — macOS recycles POSIX SHM inodes, making inode comparison unreliable after Helper restart |
| K5 | Driver | `gAnchorHostTime`: `UInt64` → `atomic_ullong`; eliminates data race between `StartIO` (write under `gStateMutex`) and `GetZeroTimeStamp` (RT-thread, no lock) |
| K6 | Helper | `src_frac_ridx` data race: Pending-Reset pattern — only the IOProc writes the field directly; Volume-thread signals via `frac_ridx_reset_pending` + `frac_ridx_reset_widx` (both atomic) |
| K7 | Helper | `nFrames` clamped to `ARN_RING_CAPACITY/2` before SRC loop — prevents BSS overflow in `temp_buf[16384]` at large buffer sizes |
| H4 | Driver | `pthread_join` (in `arn_shm_cleanup`) moved outside `gStateMutex` in `ARN_Release` — eliminates latent deadlock |
| H5 | Ring | `arn_ring_set_sample_rate`: also resets `read_idx = 0` (seq_cst) — previously only `write_idx` was reset, causing uint32 underflow → Producer blocked |
| M5 | Helper | `base_ratio` sanity check (`> 0`, `< 10`) in `output_add` and `sr_reinit_all_outputs` — prevents NaN/Inf when device SR query fails |
| M9 | Python | `save_config()`: write to `.tmp` + `fsync` + atomic `Path.replace()` — crash during write no longer corrupts `config.json` |

Full technical documentation: **DOKUMENTATION.md, Kapitel 23**.

---

## v2.6.0 — May 31, 2026

### For Everyone

**Fixes app freezing for several minutes on restart**, and eliminates background Helper processes that kept running after you quit the app (causing fan noise and CPU usage).

---

### For Power Users

- Keep-Alive IOProc migrated from Python ctypes callback to C Helper: eliminates stale function pointer crash on app restart (`mach_msg2_trap` deadlock in `HALSystem::InitializeDevices`)
- `_quit_app()` now calls `helper.shutdown()` before exit — Helper no longer orphans after app quit
- Python stub `ensure_router_keepalive()` kept for API compatibility

---

## v2.5.0 — May 2026

### For Everyone

Fixes audio not working on macOS 26 (Tahoe) unless you manually toggled the output device in System Settings.

---

### For Power Users

- `GetZeroTimeStamp`: pre-StartIO fallback (`anchor = now` when `gAnchorHostTime == 0`) prevents coreaudiod from classifying the virtual device as "in the future"
- Persistent Keep-Alive IOProc registered on virtual device; `AudioDeviceStart` called directly via ctypes (later migrated to C in v2.6)

---

## v2.1 – v2.4 — May 2026

### For Everyone

Series of stability fixes establishing the current architecture:
- **v2.4:** macOS 26 compatibility (audio now works without manual device toggle)
- **v2.3:** Volume keys work reliably; audio recovers correctly after device changes
- **v2.2:** First-run wizard, status display, one-click uninstall
- **v2.1:** Fixed: no audio after every reboot (sandboxing fix — Helper now creates the shared memory segment, not the sandboxed driver)

---

## v2.0 — May 2026

### For Everyone

Complete rewrite of the audio routing engine. Replaced the Python socket-based approach with a native C Helper using POSIX shared memory, delivering:
- Dramatically lower latency
- Eliminated audio dropouts on busy systems
- Multi-device, multi-channel routing (up to 8 simultaneous outputs)
- Adaptive sample-rate conversion (SRC) for devices at different rates

---

*For architecture diagrams and detailed implementation notes, see the project's internal documentation.*
