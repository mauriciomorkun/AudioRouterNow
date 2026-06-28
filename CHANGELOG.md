# Changelog

All notable changes to AudioRouterNow are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Full technical details for each release: [RELEASE_NOTES.md](RELEASE_NOTES.md)

---

## [3.4.2] — 2026-06-28

### Fixed
- Audio now audible on all fan-out outputs after routing switch — HW volume of physical targets was frozen at previous (often near-zero) level; now carried across from the previous system default on every switch
- No more ~10 s audio drop-out on other outputs when a 3rd device is added — healer grace period (2 s) prevents unnecessary reconnect during coreaudiod transport restart
- Devices without software volume control (hardware-pot interfaces) correctly skipped during volume propagation

---

## [3.4.1] — 2026-06-25

### Fixed
- Routing status now reflects actual IOProc state, not saved device selection
- Missing/unplugged devices shown as `⚠ unavailable` instead of silently disappearing
- All user-facing error messages translated to English
- Diagnostic report now includes SYSTEM AUDIO STATE and FAN-OUT sections

---

## [3.4.0] — 2026-06-13

### Fixed
- Audio no longer silent after fresh installation (SHM permissions: `umask(0)` + `0666` world-readable)
- Audio clock deadlock resolved — `GetZeroTimeStamp` now uses a freely-running `mach_absolute_time()` clock
- Zombie helper prevention — stale helper processes from previous versions are automatically detected and replaced on launch
- Version negotiation between app and helper prevents split-brain after updates

### Changed
- Helper binary search path: HAL path (`/Library/Audio/Plug-Ins/HAL/…`) now has priority over PyInstaller bundle path
- Helper version field added to all `get_status` responses; helpers below `MIN_HELPER_VERSION` (3.3.0) are auto-replaced

---

## [3.3.1] — 2026-06-11

### Fixed
- Version string inconsistency: helper, driver, and app now all report `3.3.1`

---

## [3.3.0] — 2026-06-11

### Added
- Automated health monitoring with self-healing (Healer module)
- Zombie helper detection

### Fixed
- Single-instance enforcement
- Several stability improvements under concurrent audio device changes

---

## [3.2.0] — 2026-06-10

### Added
- First stable release with full audio routing
- Menu bar UI with device selection
- HAL audio driver + C helper + Python engine architecture
- One-click system audio switch

---

## Earlier versions (v2.x)

v2.9.0, v2.8.x, v2.7.0 — Pre-release development iterations.  
Not publicly documented; architecture was significantly revised for v3.x.
