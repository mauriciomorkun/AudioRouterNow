# Sparkle fix, execution plan

Written 26 September 2026, after v3.4.6 was built, verified and found to have a
dead auto updater. Nothing is published yet. Full analysis in
`feedback/CASE-006_selbstfund_sparkle-startupdater.md` (local, not in Git).

## The decision this plan rests on

The fix is folded into v3.4.6 rather than deferred to v3.4.7, with a stated
abort condition.

Every user has to update by hand once, because the Sparkle in their installed
copy has never worked. The only question is whether that is the **last** manual
update. Shipping the fix in 3.4.6 makes it so. Deferring it costs every user a
second manual round.

**Abort condition, agreed before starting:** if a second defect appears behind
the fixed unpacking and is not understood within about an hour, v3.4.6 ships
without the Sparkle fix and Sparkle becomes v3.4.7. The Monterey fix does not
wait on this.

The risk of that happening is low but not zero. Everything else in the chain was
checked individually first: feed reachable (HTTP 200), `SUPublicEDKey` identical
to `generate_keys -p`, signature verification returns 0 for a real signature and
1 for a forged one.

## Step 1, register the metadata

`legacy-v3/engine/updater.py`, inside the `if _loaded:` branch, **before**
`objc.lookUpClass` and before any `SPUUpdater` method is ever bound:

```python
objc.registerMetaDataForSelector(b"SPUUpdater", b"startUpdater:", {
    "arguments": {2: {"type": b"^@", "type_modifier": objc._C_OUT}}
})
```

Measured: the signature changes from `b'B@:^@'` to an argument of `o^@`, where
the leading `o` marks the out parameter. PyObjC then returns the pair the
existing code already expects, and the real `NSError` stays readable.

Wrap it so a failure to register does not prevent Sparkle from loading. The
call site in step 2 survives either shape anyway.

## Step 2, make the call site shape independent

`updater.py:122`. Take the result once, accept both shapes:

```python
res = updater.startUpdater_(None)
if isinstance(res, tuple):
    ok, err = res[0], (res[1] if len(res) > 1 else None)
else:
    ok, err = bool(res), None
```

This is deliberately belt and braces. Step 1 is what recovers the error detail;
step 2 is what guarantees this line can never again be the sole reason the
updater dies silently, whatever a future PyObjC decides to do with the
signature.

The comment above the call has to be rewritten. The current one states an
assumption that was never true, and that assumption is the whole defect.

## Step 3, a guard, not a note

CASE-005 section 10 records the lesson from this week: a correct insight written
into a document changes nothing. Two cheap checks in `build.sh`, after the venv
exists and before the app is built:

1. **Key agreement.** `SUPublicEDKey` in the built `Info.plist` against
   `generate_keys -p`. A mismatch means every signed update would be rejected by
   every installed client, silently.
2. **Selector shape.** Load the vendored Sparkle framework in the build venv,
   register the metadata, assert the argument is now `o^@`. This guards CASE-006
   itself against returning.

Risk to weigh: `generate_keys -p` reads the login keychain. It ran here without
a prompt, but on another machine or after a keychain reset it could block a
build. Mitigation: treat an unreadable keychain as a warning, treat a readable
keychain with a mismatching key as a failure. Absence of evidence is not
evidence of a mismatch.

## Step 4, rebuild and verify

Full chain, unchanged: `build.sh`, sign, notarise, staple, DMG, closing gate.
The minos gate and every existing gate must pass exactly as before.

Then install and check the four points from CASE-006 section 6:

| # | Proof |
|---|-------|
| 1 | log shows `Sparkle-Updater gestartet (automatische Checks aktiv)` and no longer `Sparkle nicht aktiv` |
| 2 | an actual feed fetch happens, visible as no newer version being offered |
| 3 | `SUPublicEDKey` still matches `generate_keys -p` |
| 4 | minos gate and all other gates unchanged |

Point 2 is the one that matters. Points 1 and 3 can pass while the feed is never
read.

## Step 5, the cask

`homebrew-tap/Casks/audiorouternow.rb`:

- `auto_updates` to `false` until point 2 is demonstrated. The current `true`
  tells Homebrew the app updates itself, so `brew upgrade` skips it. Combined
  with a dead updater that leaves Homebrew users with no path to any new
  version at all.
- Remove the em dash in the `desc` line. It is public and violates the project
  style rule.

Once point 2 is demonstrated, `auto_updates` can go back to `true`, in a
separate commit, so the claim and its evidence sit together in the history.

## Step 6, then publish

Only after step 4 passes. Version stays 3.4.6, since nothing has been published
yet: no tag pushed, no release, no appcast entry. The existing local tag has to
be moved to the new commit.

## What this plan does not do

It does not change `startingUpdater` to `True`. That would sidestep the
signature problem entirely, but it moves failures into a Sparkle owned dialog in
front of the user, while the existing code deliberately handles them itself.

It does not touch `checkForUpdates_`, which is a plain action method with no
error parameter and is correct as written.
