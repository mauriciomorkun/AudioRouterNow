# AudioRouterNow 4.1: Decisions

Created: 2026-11-13 (cycle 2 of the Fable/Opus/Fable loop)

This file records the decisions made for the 4.1 cycle that need a written
rationale. The implementation decisions E1, E3, E4 and E6 are documented in
`02-plan-v1.md`; the display-consistency decision D1 for the wave energy and
the solo testing decision D2 are documented in `05-plan-v2.md`. The decision
below is the one with an effect on existing users after the update.

---

## D1: Accept that build 10 to 11 resets "Launch at Login"

**Decision.** `CURRENT_PROJECT_VERSION` moves from 10 to 11, which invalidates
every stored Launch at Login consent. Existing users who had "Launch at Login"
enabled will find it turned off after the update. They can turn it back on
from the footer of the menu (the "Launch at Login" checkbox).

**Why this is not a regression.** `hasValidLaunchAtLoginConsent()` validates the
stored consent against the current build number:

    return optedIn == true && consentBuild == currentBuildNumber

That binding is the mechanism, not an accident of the bump. It prevents a Login
Item registration from surviving an app update without fresh consent, which is
what Guideline 2.4.5(iii) requires. This was established for 4.0.1 as D11,
reviewed by Apple at that submission, and accepted.

**Effect on the user.** After updating from 4.0.1 to 4.1, the app will not
launch automatically at login, even if that setting was on before. The app
continues to work normally when opened by hand. To re-enable it: open
AudioRouterNow from the menu bar icon, expand the footer, and check
"Launch at Login". A confirmation prompt will appear on the first enable.

**Why no code fix.** The mechanism is intentional, documented in D11 for 4.0.1,
and was accepted by App Review in that submission. Circumventing it would
require either (a) persisting consent across builds, which breaks the guideline
requirement, or (b) carrying consent forward by special-casing build 10,
which would create a one-off exception that cannot be maintained across future
builds and would still need to be justified to the reviewer. Neither is
acceptable.

**Fallback.** If a future App Review rejects this behaviour: revert to persisting
the Launch at Login state across build numbers. This would require a legal
review of Guideline 2.4.5(iii) compliance at that time.

---

## D2: The header wave ignores Solo (supersedes D1 (wave) in `05-plan-v2.md`)

Added: 2026-11-14, addendum cycle (NT-D4 in `14-plan-nachtrag.md`). Not to be
confused with D2 (solo testing) in `05-plan-v2.md`: the numbering of this file is
independent of the numbering in that plan.

Interpretation to be confirmed by the user.

**Question.** What does "the wave must never shrink under Solo" mean, and which
formula guarantees it?

**Decision.** Solo is not a parameter of `WaveEnergyMath.soloNeutralLinear`.
The function takes `slotPeaks`, `keys` and `deviceGains`; `soloedKeys` is
deliberately absent. The result is the average over all slots of the raw peak times the
stored device gain. Solo cannot change this result, because Solo never writes
`deviceGains` (CASE-004/R3). The level meters on the cards continue to use
`SoloGain.effective` (B1 is preserved). This supersedes D1 (wave) from
`05-plan-v2.md`, which passed `SoloGain.effective` into the sum as well.

**Rationale.** The IOProc writes the same raw peak to every slot (`peaks.record`
is gain-free). Therefore for each slot `raw_i = raw`. With `deviceGains` as the
only factor, the sum is `raw * mean(deviceGains)`. Solo does not appear in the
expression, so the guarantee holds exactly and by construction, regardless of
which device is soloed and regardless of how many are.

**Scope clarification (to be confirmed by the user).** This applies to Solo only.
If the user also wants the wave to be independent of the per-device gain sliders
(a pure-source wave), that is a different request and is not implemented here.

**Fallback.** Restore `SoloGain.effective` for the sum in `updateWaveEnergy`
(one-commit revert).
