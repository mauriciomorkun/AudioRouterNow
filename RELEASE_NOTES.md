# AudioRouterNow — Release Notes

## How to read this document

Each release contains **two sections**:

- **For Everyone** — Plain language. What changed, whether it affects you, and what (if anything) you need to do.
- **For Power Users** — Technical details: root causes, implementation notes, affected components. Skip this if you just want to know if you should update.

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

*For full technical documentation, architecture diagrams, and implementation details, see `DOKUMENTATION.md`.*
