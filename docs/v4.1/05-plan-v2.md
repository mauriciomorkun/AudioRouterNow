# AudioRouterNow 4.1: Nachbesserungsplan v2

Erstellt: 2026-11-13 (Planer: Fable 5, Phase 1 Durchlauf 2 des Fable/Opus/Fable-Kreislaufs)
Basis: Audit `docs/v4.1/04-audit-v1.md` (Commit `338855e`)

---

## 1. Kopf

### 1.1 Ziel

Die drei Befunde B1 bis B3 aus Audit v1 sowie die zwei zusaetzlichen Luecken B4 und B5
beheben, die der Planer beim Lesen des Codes identifiziert hat. Kein neues Feature,
keine Aenderung am Audio-Pfad, keine neuen Entitlements.

### 1.2 Scope-Freeze (verbindlich)

**Enthalten:** B1, B2, B3, B4 (nur Doku), B5 (nur Befundaufnahme und Nutzerhinweis).

**Ausdruecklich ausgeschlossen:** AirPlay-Integration, Per-App-Routing, Bluetooth-
Latenzkompensation, Intel-Support, Marketing-Inhalte, `v4-appstore/` aufraeumen,
Einreichung bei App Store Connect, kein Push. Die Mechanik von
`ensureLoginItemCompliance`/`hasValidLaunchAtLoginConsent` wird NICHT angefasst
(review-geprueft, korrekt, Leitplanke).

### 1.3 Branch

`release/4.1` (sauber, Commit `338855e` als Startpunkt).

### 1.4 Baseline

Verifiziert vom Planer:

| Pruefung | Ergebnis |
|----------|----------|
| `bash v4/scripts/test.sh` | 59 swift-testing in 10 Suiten, alle gruen |
| XCTest (aus Protokoll S12) | 56 Faelle, alle gruen (43 Baseline + 13 neue) |
| App-Build (Debug, `CODE_SIGNING_ALLOWED=NO`) | BUILD SUCCEEDED |

App-Build-Befehl (unveraendert aus Plan v1 und Audit):
```
cd ~/AudioRouterNow/v4 && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AudioRouterNow4.xcodeproj \
  -scheme AudioRouterNow4 -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Versionsdaten (unveraendert aus S1): `MARKETING_VERSION = 4.1`,
`CURRENT_PROJECT_VERSION = 11` in `v4/Configs/AudioRouterNow4.xcconfig`.

Preflight-Ergebnis (Planer hat `v4/scripts/preflight.sh` selbst ausgefuehrt):

```
1. Projektbaum
  WARNUNG v4-appstore/ existiert noch.

2. Version
  OK      xcconfig sagt 4.1 (11)
  OK      Keine zweite Versionsquelle im Projekt

3. Build-Nummer gegen vorhandene Tags
  OK      Tag v4.1 existiert noch nicht

4. Arbeitsbaum
  OK      Sauber
  WARNUNG Commits sind noch nicht gepusht

5. Berechtigungen (Release)
  OK      App Sandbox aktiv
  OK      Audio Input vorhanden

6. Letztes Archiv (falls vorhanden)
  Archiv: AudioRouterNow4 07-10-2026, 17.55.xcarchive
  ABBRUCH Archiv ist 4.0.1 (10), erwartet war 4.1 (11)
  OK      Archiv stammt aus v4/ (110 Pfadverweise)

ERGEBNIS: 1 Abbruchgrund, 2 Warnungen.
```

Das Ergebnis stimmt mit der Aussage im Impl-Protokoll (S12) ueberein. Der
ABBRUCH betrifft das alte Archiv von 07.10.2026 (4.0.1 Build 10), nicht die
Versionsquelle. Er ist unvermeidlich bis ein neues 4.1-Archiv gebaut wird
(Einreichungsschritt, ausserhalb dieses Scopes). Der Umsetzer muss vor der
Einreichung ein neues Archiv bauen und danach `preflight.sh` erneut ausfuehren;
dann muss der ABBRUCH verschwunden sein und nur die zwei Warnungen bleiben.

Die WARNUNG zu `v4-appstore/` ist bekannt und erwartet (Leitplanke: nicht
anfassen).

### 1.5 Leitplanken

Unveraendert aus Plan v1, zuzueglich:
- `ensureLoginItemCompliance()` und die gesamte Consent-Mechanik werden NICHT
  veraendert. Jede Zeile, die `launchAtLoginConsentBuildKey` oder
  `launchAtLoginOptedInKey` liest oder schreibt, bleibt unberuehrt.
- `SoloGain.effective(key:soloedKeys:deviceGains:)` ist die einzige Quelle
  der Wahrheit fuer Solo-Gain-Entscheidungen. Kein Duplikat dieser Logik.
- Keine neuen Swift-Dateien in `v4/AudioRouterNow4/` (Signierungsverlust).
- Neue Swift-Dateien im SPM-Package `AudioRouterKit` sind unproblematisch.
- Kein Alloc im IOProc. Die Aenderung an `updateWaveEnergy` laeuft auf dem
  MainActor (20-fps-Poll), nicht im IOProc.
- Kein Lock ausser `os_unfair_lock` im Echtzeitpfad.
- Keine Marketing-Texte, keine Nutzernamen in Commits oder Docs.
- Konventionelle Commit-Messages, Scope in Klammern.

---

## 2. Entscheidungen

### D1: Entscheidung zur `sum`-Berechnung fuer die Wellenenergie (B1)

**Frage:** Sollen Solo-stumm-geschaltete Slots in `sum` (Wellenenergie-Header)
mitzaehlen?

**Kontext am Code (verifiziert, Z. 744-759 in `EngineController.swift`):**
```swift
var sum: Float32 = 0
for (i, key) in engine.slotDeviceKeys.enumerated() where i < SlotGains.maxSlots {
    let raw = engine.peakLevel(slotIndex: i)
    let gain = Float32(deviceGains[key] ?? 1.0)
    let p = (l: raw.l * gain, r: raw.r * gain)
    // ...
    sum += (p.l + p.r) / 2
}
```

Fuer die Wellenform-Energie gilt: der Header visualisiert "was die App an die
Outputs sendet". Ein Solo-stumm-geschalteter Slot sendet Gain 0.0. Zaehlt er
trotzdem in `sum`, zeigt die Welle mehr Energie als tatsaechlich abgespielt
wird. Beim Extremfall (alle Slots ausser einem sind stumm, das Solo-Geraet ist
leise) bleibt die Welle hoch, obwohl fast nichts gehoert wird.

Dasselbe `SoloGain.effective(...)` das fuer die Peak-Meter-Korrektur verwendet
wird, liefert 0.0 fuer stumme Slots. Damit faellt ihr Beitrag zu `sum` ebenfalls
auf 0, was der tatsaechlichen Ausgangsenergie entspricht.

**Wahl: `SoloGain.effective(...)` auch fuer `sum` verwenden.** Stumme Slots
zaehlen nicht. Konsistenz zwischen Welle und Metern: beide zeigen die effektiv
ausgegebene Energie.

**Risikoabschaetzung:** Der Extremfall (Solo-Geraet allein, sehr leise) laesst
die Welle klein werden. Das ist korrekt: wenn fast kein Audio ausgegeben wird,
soll die Welle das widerspiegeln. Kein Audio-Pfad ist betroffen.

**Rueckfall:** Wenn der Nutzer am Geraet feststellt, dass die Welle unter Solo
zu klein ist und stattdessen die ungefilterte `sum` bevorzugt, kann er das durch
Wiederherstellung der alten Zeile `let gain = Float32(deviceGains[key] ?? 1.0)`
in einem separaten Commit umkehren. Die Mechanik ist lokal begrenzt.

### D2: Verhalten von `SoloGain.effective` bei leerem Key unter aktivem Solo (B3)

**Frage:** Was soll `SoloGain.effective(key: "", soloedKeys: ["x:0"], ...)` zurueckgeben?

**Code-Analyse (verifiziert, `SoloGain.swift:38-45`):**
```swift
public static func effective(
    key: String,
    soloedKeys: Set<String>,
    deviceGains: [String: Double]
) -> Float32 {
    let base = Float32(deviceGains[key] ?? 1.0)
    if soloedKeys.isEmpty { return base }
    return soloedKeys.contains(key) ? base : 0.0
}
```

Wenn `soloedKeys` nicht leer ist und `""` nicht in `soloedKeys` enthalten ist,
gibt die Funktion `0.0` zurueck. Das ist konsistentes Verhalten: ein leerer Key
ist kein solo'eter Key. `soloedKeys.contains("")` = `true` wuerde zurueckgeben,
wenn explizit der leere Key solo'et wurde.

**Wahl: dieses Verhalten wird als korrekt anerkannt und getestet.** Der neue
Testfall prueft:
- Leerer Key ohne Solo: liefert 1.0 (Unity, aus `deviceGains[""] ?? 1.0`).
- Leerer Key unter aktivem Solo (kein leerer Key in `soloedKeys`): liefert 0.0.
- Leerer Key solo'et (leerer Key IN `soloedKeys`): liefert 1.0 (Unity-Default,
  da `deviceGains[""]` nicht besetzt ist).

**Rueckfall:** Der Test kann entfernt werden, falls ein kuenftiger Planer das
Verhalten aendern will; die Funktion selbst bleibt unberuehrt.

---

## 3. Schritte

### Schritt N0: Baseline-Verifikation

**ID:** N0
**Datei:** keine Produktivdatei

Vorgehen:
1. `git status` prueft, dass `release/4.1` sauber ist (Commit `338855e`).
2. `cd ~/AudioRouterNow/v4 && bash scripts/test.sh` ausfuehren.
   Erwartet: 59 swift-testing, alle gruen.
3. App-Build ausfuehren (Befehl aus Abschnitt 1.4). Erwartet: BUILD SUCCEEDED.

Akzeptanzkriterium: Tests gruen, Build gruen.

Commit: keiner in N0.

---

### Schritt N1: Peak-Meter und Wellenenergie unter Solo korrigieren (B1)

**ID:** N1
**Datei:** `v4/AudioRouterNow4/EngineController.swift`
**Symbole/Zeilen:** `updateWaveEnergy()`, Z. 750-759 (verifiziert)

**Ist-Stand (Z. 750-759):**
```swift
let raw = engine.peakLevel(slotIndex: i)
let gain = Float32(deviceGains[key] ?? 1.0)
let p = (l: raw.l * gain, r: raw.r * gain)
let prev = peakLevels[key] ?? (l: 0, r: 0)
newPeaks[key] = (
    l: max(p.l, prev.l * 0.80),
    r: max(p.r, prev.r * 0.80)
)
sum += (p.l + p.r) / 2
```

**Soll-Stand:**
```swift
let raw = engine.peakLevel(slotIndex: i)
// Effektiven Gain verwenden: unter aktivem Solo erhalten stumme Slots 0.0.
// Entscheidung D1 (Planer, 2026-11-13): SoloGain.effective auch fuer `sum`,
// damit Wellenform und Meter konsistent die tatsaechlich ausgegebene Energie zeigen.
let gain = SoloGain.effective(key: key, soloedKeys: soloedKeys, deviceGains: deviceGains)
let p = (l: raw.l * gain, r: raw.r * gain)
let prev = peakLevels[key] ?? (l: 0, r: 0)
newPeaks[key] = (
    l: max(p.l, prev.l * 0.80),
    r: max(p.r, prev.r * 0.80)
)
sum += (p.l + p.r) / 2
```

**Import:** `SoloGain` ist im selben Modul (ueber `AudioRouterKit`) bereits
importiert. Kein neuer Import noetig. Belegt: `SoloGain.effective` wird bereits
in `applySoloGains()` verwendet (EngineController importiert AudioRouterKit).

**Begründung:** Audit-Befund B1. Die Card-Opacity ist auf 0.4 gedimmt (E4,
umgesetzt), aber die gruenen Balken der Signal-Meter und der dBFS-Wert zeigen
weiterhin Pegel > 0. Der Nutzer sieht Audio-Level auf einem Slot, der
tatsaechlich Stille abspielt. Inkonsistent. Der Audio-Pfad ist korrekt; nur die
Anzeige ist falsch.

**Zusaetzliche Pruefung nach der Aenderung:** `soloedKeys` ist eine
`@Published private(set)` Property auf `EngineController`, und
`updateWaveEnergy()` ist `private func` auf `@MainActor`. `SoloGain.effective`
ist eine `nonisolated static func`. Kein Concurrency-Problem. `updateWaveEnergy`
liest `soloedKeys` nur, schreibt nie. Leitplanke "deviceGains wird durch Solo
nie beschrieben" bleibt erfuellt: diese Aenderung liest nur.

**Akzeptanzkriterium:**
- Build gruen.
- `grep -n "deviceGains\[key\]" v4/AudioRouterNow4/EngineController.swift` findet
  in `updateWaveEnergy()` keinen direkten `deviceGains[key]`-Zugriff mehr fuer
  `gain`.
- Tests gruen (59 swift-testing + 56 XCTest unveraendert; keine neuen Tests fuer
  `updateWaveEnergy` noetig, da sie eine MainActor-Methode ist und nicht aus
  SPM-Tests testbar).

Commit: `fix(engine): use effective solo gain in updateWaveEnergy for meters and wave`

---

### Schritt N2: RELEASE_NOTES.md Formulierung hardware-neutral fassen (B2)

**ID:** N2
**Datei:** `RELEASE_NOTES.md`
**Symbol/Zeile:** Abschnitt "Fewer unnecessary audio interruptions", der Satz
"routing keeps running without interruption" (verifiziert, Z. 192).

**Ist-Stand (Z. 192):**
```
If it comes back quickly, routing keeps running without interruption.
```

**Soll-Stand:**
```
If it comes back within the settle window, the pending restart is discarded
and the engine keeps running on the same session. Whether audio stays
audibly uninterrupted depends on the hardware and can only be confirmed on
a real device.
```

**Begründung:** Der bestehende Satz beschreibt das Ergebnis aus Nutzerperspektive
("routing keeps running without interruption") als Tatsache. Das ist eine
Hardware-Eigenschaft (M8 im Plan), die nur am Geraet gemessen werden kann. Was
der Code tut, ist: er verwirft den Restart und setzt die Session fort. Der
Nachfolge-Disclaimer ("Both improvements depend on how the hardware behaves and
are best confirmed on a real device") daempft das, aber der vorausgehende Satz
stellt das Ergebnis als gegeben dar. Die neue Formulierung beschreibt ausschliesslich
den Code-Pfad.

**Vergleich mit CHANGELOG.md:** Die CHANGELOG-Formulierung "that restart is now
discarded" (verifiziert, Z. 107) ist bereits korrekt und wird nicht geaendert.

**Akzeptanzkriterium:**
- `grep "keeps running without interruption" RELEASE_NOTES.md` findet keinen
  Treffer mehr.
- `grep "pending restart is discarded" RELEASE_NOTES.md` findet einen Treffer.
- Kein Marketing-Inhalt, kein Nutzername.

Commit: `docs(release-notes): describe blip fix as code behaviour, not hardware outcome`

---

### Schritt N3: Testluecke in SoloGainTests behoben (B3)

**ID:** N3
**Datei:** `v4/AudioRouterKit/Tests/AudioRouterKitTests/SoloGainTests.swift`
**Symbol/Zeile:** `testEmptyKeyDoesNotCrashAndDefaultsToUnityWithoutSolo`, Z. 47-49
(verifiziert).

**Ist-Stand (Z. 47-49):**
```swift
func testEmptyKeyDoesNotCrashAndDefaultsToUnityWithoutSolo() {
    XCTAssertEqual(SoloGain.effective(key: "", soloedKeys: [], deviceGains: [:]), 1.0, accuracy: 1e-6)
}
```

**Soll-Stand:** Testmethode unveraendert lassen und die zwei fehlenden Faelle
als Assert-Zeilen INNERHALB derselben Methode ergaenzen. Begruendung: die Methode
heisst bereits "DoesNotCrash" (Absturztest); die neuen Assertionen prufen das
Verhalten unter aktivem Solo, das ebenfalls absturz- und inhaltlich korrekt sein
soll (Entscheidung D2).

```swift
func testEmptyKeyDoesNotCrashAndDefaultsToUnityWithoutSolo() {
    // Kein Solo: leerer Key liefert Unity (Fallback-Default aus deviceGains[""]).
    XCTAssertEqual(SoloGain.effective(key: "", soloedKeys: [], deviceGains: [:]), 1.0, accuracy: 1e-6)
    // Solo aktiv, leerer Key NICHT in soloedKeys: stumm (kein Absturz erwartet).
    XCTAssertEqual(SoloGain.effective(key: "", soloedKeys: ["x:0"], deviceGains: [:]), 0.0, accuracy: 1e-6)
    // Leerer Key solo'et: Unity-Default (nicht in deviceGains, daher 1.0).
    XCTAssertEqual(SoloGain.effective(key: "", soloedKeys: [""], deviceGains: [:]), 1.0, accuracy: 1e-6)
}
```

**Begründung:** Audit-Befund B3. `SoloGain.effective` ist eine reine Funktion;
die ersten zwei neuen Assert-Zeilen sind direkt aus der Funktion herleitbar (D2).
Die Testmethode deckt jetzt drei Faelle statt einem ab.

**Akzeptanzkriterium:**
- Alle swift-testing und XCTest gruen. Anzahl XCTest steigt um 0 (neue Assertionen
  in bestehender Methode, keine neue Testmethode).
- `grep -c "XCTAssertEqual" v4/AudioRouterKit/Tests/AudioRouterKitTests/SoloGainTests.swift`
  liefert mindestens 10 (war 7, plus 3 neue Zeilen; 7 bestehende + 3 = 10 Assert-
  Zeilen gesamt; Methodenzahl unveraendert).

Commit: `test(kit): cover empty key under active solo in SoloGainTests`

---

### Schritt N4: Entscheidungsdokument `docs/v4.1/05-decisions.md` erstellen (B4a)

**ID:** N4
**Datei:** `docs/v4.1/05-decisions.md` (NEU)

Stil: `docs/v4.0.1/02-decisions.md` (englisch, faktisch, kein Marketing,
kein Em-Dash, kein Gedankenstrich " - " als solcher ohne Funktion).

Inhalt: Entscheidung D1 fuer diesen Zyklus, analog zu D11 aus 4.0.1
(dort: "accept that build 7-to-8 resets Launch at Login"). Hier: Build 10-zu-11.

**Schreibvorlage (Umsetzer verwendet diese Felder genau so):**

```
# AudioRouterNow 4.1: Decisions

[...]

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
```

**Akzeptanzkriterium:** Datei existiert. Kein Nutzername, kein Em-Dash, kein
Marketing. Der Satz "Launch at Login checkbox" ist aktuell und am Code
verifiziert: `RoutingControls.swift:173` zeigt einen `Toggle("Launch at Login")`
als Checkbox (`.toggleStyle(.checkbox)`) in der Footer-Zeile.

Commit: `docs(v4.1): decisions for cycle 2, D1 Launch at Login build reset`

---

### Schritt N5: CHANGELOG und RELEASE_NOTES um B4-Hinweis ergaenzen (B4b)

**ID:** N5
**Dateien:** `CHANGELOG.md` (Z. 70, Abschnitt `[4.1 (11)]`), `RELEASE_NOTES.md`
(Abschnitt "AudioRouterNow 4.1")

Beide Dateien haben bereits einen `[4.1 (11)]`-Abschnitt (verifiziert). Es gibt
dort KEINEN Hinweis zum Launch-at-Login-Reset. Dieser Absatz wird ERGAENZT
(kein vorhandener Text geloescht).

**CHANGELOG.md:** Im Abschnitt `[4.1 (11)]` unter einer neuen Unterrubrik
`### Changed` (falls noch nicht vorhanden; die aktuelle Rubrik heisst nur
"Changed" mit dem Superlativ-Eintrag, also dort ergaenzen):

Vorlage (Umsetzer prueft, ob "Changed" bereits existiert; wenn ja: Zeile
anhaengen, wenn nein: neue Rubrik anlegen):

```
- **"Launch at Login" is reset after the update.** The consent for the launch
  item is tied to the exact build number it was granted for. Updating from
  build 10 to build 11 invalidates the stored consent: the app will not
  launch at login after the update, even if it did before. To re-enable it,
  open the app, expand the footer, and check "Launch at Login".
  This is intended behaviour under Guideline 2.4.5(iii) and was established
  in 4.0.1. See docs/v4.1/05-decisions.md, D1.
```

**RELEASE_NOTES.md:** Im Abschnitt "For Everyone" von AudioRouterNow 4.1,
als neuen Absatz vor "Wording" (oder nach "Fewer unnecessary audio
interruptions", bevor der Abschnitt endet):

```
#### Launch at Login is reset after the update

If you had "Launch at Login" turned on in AudioRouterNow 4.0.1, the update
will turn it off. This is intentional. The app links its consent to run at
login to the exact build number it was granted for, so that an update can
never keep launching without fresh confirmation.

To turn it back on: open AudioRouterNow from the menu bar icon and check
"Launch at Login" in the footer. A short confirmation prompt will appear.
Nothing else changes; your routing settings and volume levels are kept.
```

**Akzeptanzkriterium:** Kein Nutzername, kein Em-Dash, kein Marketing. Der
genaue Ort des Schalters ("Launch at Login" in der Footer-Checkbox) ist
verifiziert am Code (`RoutingControls.swift:173`).

Commit: (zusammen mit N4 oder separat) `docs(changelog): note launch-at-login
reset in 4.1, refer to 05-decisions.md D1`

Hinweis: Schritt N4 und N5 koennen in einem einzigen Commit zusammengefasst
werden, wenn der Umsetzer die Reihenfolge bevorzugt. Wichtig ist, dass beide
erledigt sind bevor der naechste Schritt beginnt.

---

### Schritt N6: App-Store-Connect-Textvorlage erstellen (B4c)

**ID:** N6
**Datei:** `docs/v4.1/06-appstore-texts.md` (NEU)

Diese Datei haelt alle Texte, die der Nutzer in App Store Connect eintraegt.
Sie ist nicht gitignored (kein Marketing-Inhalt, keine Nutzernamen, keine
vertraulichen Daten, rein technische und sachliche Texte). Format wie
`docs/v4.0.1/07-submission-plan.md` Abschnitt "Vorlage fuer die Review-Notiz",
jedoch mit klar beschrifteten Abschnitten pro Feld.

**Inhalt (Umsetzer uebernimmt diese Vorlage, passt Datum-/Statusfelder an):**

---

```markdown
# AudioRouterNow 4.1: App Store Connect Texte

## 1. "What's New" (Versionshinweise im Store, max. 4000 Zeichen)

Vorlage (englisch, kein Superlativ, kein Marketing):

---

This update adds a solo button, fixes two causes of unnecessary audio
interruptions, and makes the device list scrollable when many devices
are configured.

Scrollable device list. The panel no longer grows past the screen when you
have many outputs configured. The start/stop button in the footer stays
visible. A second start/stop button has been added to the status bar at the top.

Solo per output. While routing is active, each output has a solo button (the
"S" icon). Tap it to hear only that output. Tap it again to release. Solo is
session-only and resets when you stop routing. It does not change your stored
volume settings.

Fewer unnecessary restarts. The sample rate listener no longer restarts the
engine when macOS fires a notification but the rate did not actually change.
A device that briefly disconnects and reconnects within the settle window
no longer forces a restart.

Note: "Launch at Login" is reset by this update. The consent is tied to the
exact build number it was granted for. If you had it turned on, open the app
and check "Launch at Login" in the footer to re-enable it.

---

## 2. Review-Notizen (nicht oeffentlich sichtbar, fuer den Reviewer)

Vorlage:

---

This update adds three features and fixes two defects.

1. Scrollable device list: the panel now has a ScrollView capped at 400 pt.
   The footer with the routing button stays outside the scroll view. An
   additional start/stop icon button was added to the status bar.

2. Solo per output: a session-only solo button on each device card. Tap to
   play only that output. Solo uses engine.setOutputGain exclusively and never
   writes to the stored per-device gains (UserDefaults). Full test coverage in
   SoloGainTests.swift.

3. Sample rate listener: the listener reads a baseline at registration and
   compares before triggering a restart. A read failure is treated as a change
   (conservative). Test coverage in SRListenerTests.swift.

4. Device blip absorption: a device reconnecting within the settle window
   discards the pending restart instead of scheduling a new one.

5. Store description: unverifiable superlative removed.

To test routing you need to allow audio recording when macOS asks. The app
uses the Process Tap API to read system audio. Nothing is recorded or stored;
the audio is passed straight to the selected output devices.

Steps to test:
1. Open the app from the menu bar icon.
2. Allow audio recording when prompted.
3. Select one or more output devices.
4. Play any audio. It should come out of all selected devices.
5. Tap the "S" button on one device card. Only that device should play.

Note on "Launch at Login": this update deliberately resets that setting. The
consent is tied to the exact build number it was granted for, so that an app
update can never silently keep launching the app. This is the same mechanism
reviewed and accepted in build 10 (4.0.1). Working as intended under
Guideline 2.4.5(iii).

Contact: dev@mauriciomorkun.com

---

## 3. Store Description: Textbaustein ersetzen (Nutzeraufgabe)

Der Satz "AudioRouterNow is the only sandboxed multi-output solution on the
Mac App Store" (oder aehnlich) muss in App Store Connect durch folgenden
Satz ersetzt werden:

  "AudioRouterNow runs fully sandboxed. No kernel extension. No virtual
  driver. No reboot."

Wo in App Store Connect:
1. App Store Connect oeffnen: https://appstoreconnect.apple.com
2. AudioRouterNow App aufrufen.
3. Version 4.1 anlegen (falls noch nicht vorhanden, nach dem Hochladen des
   Archivs).
4. Im Reiter "App Information" (linke Spalte) ODER direkt in der
   Versionsvorbereitung: Feld "Description" aufrufen.
5. Den Satz suchen und durch den neuen ersetzen.
6. Speichern. Die Aenderung wird erst mit dem naechsten Review sichtbar.

Hinweis: die Superlativ-Stelle liegt nur in App Store Connect, NICHT im
Repository (verifiziert im Impl-Protokoll S9).
```

**Akzeptanzkriterium:** Datei existiert. Kein Nutzername, kein Em-Dash, kein
Marketing-Versprechen. Alle technischen Angaben sind am Code verifiziert (Solo-
Mechanik, SR-Listener, Blip-Absorption, Launch-at-Login-Mechanik).

Commit: `docs(v4.1): app store connect text templates for 4.1 submission`

---

### Schritt N7: Abschluss-Testlauf und README-Ergaenzung

**ID:** N7
**Dateien:** `docs/v4.1/README.md`

Vorgehen:
1. `cd ~/AudioRouterNow/v4 && bash scripts/test.sh`
   Alle Tests gruen. Zaehlstand notieren. Erwartet: 59 swift-testing (unveraendert),
   XCTest: 56 (unveraendert, da N3 nur Assertionen ergaenzt, keine neue Methode).
2. App-Build ausfuehren (Befehl aus Abschnitt 1.4). Erwartet: BUILD SUCCEEDED.
3. `v4/scripts/preflight.sh` ausfuehren. Erwartet: ABBRUCH wegen altem Archiv
   bleibt (kein neues Archiv in diesem Zyklus gebaut), 2 Warnungen bleiben.
   Version und Tag: wie bisher. Kein neuer Fehler.
4. `docs/v4.1/README.md` um die neuen Dokumente ergaenzen:

```
| [05-plan-v2.md](05-plan-v2.md) | Nachbesserungsplan v2 (Planer: Fable 5). Scope: B1 (Peak-Meter unter Solo), B2 (RELEASE_NOTES-Formulierung), B3 (Testluecke leerer Key), B4 (Launch-at-Login-Reset-Doku), B5 (Preflight-Befund). 7 Schritte (N0-N7). Status: zur Ausfuehrung bereit. |
| [05-decisions.md](05-decisions.md) | Entscheidungen Zyklus 2. D1: Launch-at-Login-Reset beim Build-Sprung 10 auf 11. |
| [06-appstore-texts.md](06-appstore-texts.md) | App Store Connect Textvorlagen: What's New, Review-Notiz, Store-Description-Ersetzung (Schritt-fuer-Schritt). |
```

Commit: `docs(v4.1): update README for cycle 2 documents`

---

## 4. Verbotsliste

Der Umsetzer darf NICHT:
- Den FanOutEngine-Echtzeitpfad (IOProc-Block, `makeDirectIOBlock`) aendern.
- `deviceGains` (UserDefaults) durch Solo-Operationen beschreiben.
- Entitlements aendern (`AudioRouterNow4.entitlements`,
  `AudioRouterNow4-Debug.entitlements`).
- `ensureLoginItemCompliance()` oder `hasValidLaunchAtLoginConsent()` aendern.
- Die Keys `launchAtLoginOptedInKey` oder `launchAtLoginConsentBuildKey`
  in ihrer Semantik veraendern.
- `v4-appstore/` oder `legacy-v3/` anfassen.
- Auf den Remote pushen (`git push`).
- Bei App Store Connect einreichen.
- Neue Swift-Dateien in `v4/AudioRouterNow4/` erstellen, ohne dass dieser
  Plan einen expliziten Schritt dafuer enthaelt.
- Marketing-Texte in Commits oder Dokumentation schreiben.
- Nutzernamen oder E-Mail-Adressen in irgendeiner Datei erwaehnen.
  Ausnahme: `docs/v4.1/06-appstore-texts.md` darf `dev@mauriciomorkun.com`
  enthalten (steht bereits in der 4.0.1-Vorlage, kein privater Name).
- `--no-verify` beim Commit verwenden.
- SlotGains.maxSlots veraendern.
- Den W1-Ramp-Mechanismus im IOProc veraendern.
- Em-Dashes (" - " als Gedankenstrich) in irgendeiner neuen oder geaenderten
  Datei verwenden.
- `SoloGain.effective` duplizieren oder eine zweite Implementierung derselben
  Logik anlegen.

---

## 5. Risiken

### R1: Import von `SoloGain` in `EngineController.updateWaveEnergy` (N1)

`SoloGain` ist eine `public enum` in `AudioRouterKit`. `EngineController` liegt
im App-Target und importiert `AudioRouterKit` bereits (verifiziert: `import
AudioRouterKit` steht in `EngineController.swift`). Kein neuer Import noetig.

Gegenmassnahme: Build nach N1 ausfuehren; Compiler prueft den Import.

### R2: `soloedKeys`-Zugriff in `updateWaveEnergy` (N1)

`soloedKeys` ist `@Published private(set) var` auf `EngineController`.
`updateWaveEnergy` ist `private func` auf demselben `@MainActor`-Typ. Kein
Concurrency-Problem. Der Zugriff ist read-only.

Gegenmassnahme: Swift-6-Build ohne Warnungen ist das Akzeptanzkriterium.

### R3: Neue Assertionen in `testEmptyKeyDoesNotCrashAndDefaultsToUnityWithoutSolo` (N3)

Die neue dritte Assertion (`soloedKeys: [""]`) prueft den Pfad "leerer Key solo'et".
`SoloGain.effective(key: "", soloedKeys: [""], ...)` fuehrt zu
`soloedKeys.contains("") = true`, also `return base = Float32(deviceGains[""] ?? 1.0) = 1.0`.
Das ist korrekt und absturzsicher (D2).

Gegenmassnahme: Testlauf nach N3.

---

## 6. Messpunkte "NUTZER MUSS MESSEN"

Unveraendert aus Plan v1, Abschnitt 6 (M1 bis M8). Kein Punkt wird durch diese
Nachbesserungsschritte erledigt oder veraendert.

**Zusaetzlicher Messpunkt fuer B1:**

### M9: Peak-Meter unter Solo (B1-Fix, Geraet erforderlich)

**Vorbedingung:** Mindestens zwei Outputs konfiguriert, Routing aktiv.

**Vorgehen:** Solo-Button eines Outputs druecken. Eine andere Card aufklappen
(ExpandedDeviceDetail oeffnen). Die gruenen Signal-Meter-Balken der stumm-durch-
Solo-Card beobachten.

**Erwartetes Ergebnis nach N1:** Die Meter zeigen 0 (Stille), konsistent mit der
0.4-Opacity der Card. Vor N1 zeigten sie Pegel.

---

## 7. Audit-Leitfaden fuer Durchlauf 2

Der Auditor prueft zuerst die Befunde B1 bis B5, dann die Regressionscheck-
felder aus Durchlauf 1.

### Checkliste B1: Peak-Meter-Fix (N1)

- Pruefen: `updateWaveEnergy()` in `EngineController.swift`, Z. ca. 751.
  `SoloGain.effective(key:soloedKeys:deviceGains:)` wird fuer `gain` verwendet.
  Kein direkter `deviceGains[key]`-Zugriff fuer `gain` in dieser Methode mehr.
- Pruefen: `soloedKeys` und `deviceGains` werden nur gelesen, nie geschrieben.
- Pruefen: `sum` verwendet ebenfalls den effektiven Gain (D1-Entscheidung).
- Pruefen: Build gruen, kein Swift-6-Concurrency-Fehler.

### Checkliste B2: RELEASE_NOTES-Formulierung (N2)

- Pruefen: `grep "keeps running without interruption" RELEASE_NOTES.md`
  liefert keine Treffer.
- Pruefen: `grep "pending restart is discarded" RELEASE_NOTES.md` liefert
  mindestens einen Treffer.
- Pruefen: der neue Text beschreibt den Code-Pfad, nicht das Nutzererlebnis.

### Checkliste B3: Testluecke leerer Key (N3)

- Pruefen: `testEmptyKeyDoesNotCrashAndDefaultsToUnityWithoutSolo` enthaelt
  jetzt mindestens drei `XCTAssertEqual`-Zeilen.
- Pruefen: die neue Assertion mit `soloedKeys: ["x:0"]` prueft den Wert `0.0`.
- Pruefen: die neue Assertion mit `soloedKeys: [""]` prueft den Wert `1.0`.
- Pruefen: alle Tests gruen, Methoden-Anzahl unveraendert (7 Methoden in
  `SoloGainTests`).

### Checkliste B4: Launch-at-Login-Doku (N4, N5, N6)

- Pruefen: `docs/v4.1/05-decisions.md` existiert und enthaelt D1 mit den vier
  Feldern: Decision, Why not a regression, Effect on the user, Why no code fix.
- Pruefen: `CHANGELOG.md` im Abschnitt `[4.1 (11)]` enthaelt einen Absatz zum
  Launch-at-Login-Reset.
- Pruefen: `RELEASE_NOTES.md` im Abschnitt "AudioRouterNow 4.1" enthaelt einen
  Absatz "Launch at Login is reset after the update".
- Pruefen: `docs/v4.1/06-appstore-texts.md` existiert und enthaelt alle drei
  Abschnitte (What's New, Review-Notiz, Store-Description-Ersetzung).
- Pruefen: kein Nutzername, kein Em-Dash in einem der neuen Dokumente.
- Pruefen: der genannte Ort des Schalters ("Launch at Login" Checkbox im Footer)
  ist korrekt (am Code verifiziert: `RoutingControls.swift:173`).

### Checkliste B5: Preflight-Ergebnis (N7)

- Pruefen: `v4/scripts/preflight.sh` wird vom Umsetzer ausgefuehrt und das
  vollstaendige Ergebnis im Impl-Protokoll v2 dokumentiert.
- Erwartetes Ergebnis: ABBRUCH wegen altem Archiv bleibt, 2 Warnungen bleiben.
  Kein neuer ABBRUCH.
- Pruefen: die Version-Pruefung zeigt weiterhin "xcconfig sagt 4.1 (11)".
- Nutzerhinweis fuer Einreichung: neues Archiv bauen, dann `preflight.sh` erneut
  ausfuehren; ABBRUCH muss dann weg sein.

### Regressionscheck Durchlauf-1-Felder (unveraendert aus Audit A1 bis A14)

| ID | Pruefen |
|----|---------|
| A1 | `deviceGains` unberuehrt durch Solo: `applySoloGains` und `updateWaveEnergy` schreiben nicht in `deviceGains`. |
| A2 | Footer liegt nach dem `ScrollView` im `body` von `MenuBarView`. |
| A3 | `ScrollView` hat `.frame(maxHeight: 400)`. |
| A4 | `.fixedSize(horizontal: false, vertical: true)` am Root-VStack unveraendert. |
| A5 | `soloedKeys = []` in `stopRouting()` vorhanden. |
| A6 | `applySoloGains()` nach `performStart()`, `restartRouting()`, `applyOutputsIfRouting()`, `warmRestartForSampleRateChange()`. |
| A7 | `srChangedSignificantly(newRate: nil, ...)` liefert `true`. |
| A8 | Blip-Verwerfen nur bei `pendingRestart != nil`. |
| A9 | Keine NUTZER-BESTAETIGTE Entscheidung als verifiziert gemeldet. |
| A10 | Keine neuen Swift-Dateien in `v4/AudioRouterNow4/` ausser was dieser Plan enthaelt. |
| A11 | Tests gruen, Anzahl nicht kleiner als 59 swift-testing + 56 XCTest. |
| A12 | Conventional Commits und kein Push. |
| A13 | xcconfig: `MARKETING_VERSION = 4.1`, `CURRENT_PROJECT_VERSION = 11`. |
| A14 | `grep -r "the only sandboxed"` findet keine Treffer in getracken Dateien. |

---

## 8. Abschlussschritte

Nach N7:

1. Testlauf-Ergebnis in Impl-Protokoll v2 (`docs/v4.1/07-impl-v2.md`) eintragen.
   Format analog zu `docs/v4.1/03-impl-v1.md`.

2. `git log --oneline release/4.1` prueft, dass alle Commits seit `338855e`
   conventional commits sind und kein Push stattgefunden hat.

3. NUTZER-MUSS-MESSEN-Punkte (M1-M9) bleiben offen bis zur Hardware-Messung.

4. Einreichungsvorbereitungen (reine Nutzeraufgaben, kein Agent):
   a. Neues 4.1-Archiv in Xcode erstellen (Product > Archive).
   b. `v4/scripts/preflight.sh` erneut ausfuehren; ABBRUCH muss verschwunden sein.
   c. App Store Connect: `docs/v4.1/06-appstore-texts.md` als Quelle verwenden.

---

## 9. Zusatzauftrag: Weitere Funde aus den Audit-v1-OK-Feldern

Der Planer hat beim Lesen der als "OK" markierten Felder (SR-Listener-Baseline,
Blip-Absorption, ScrollView) ergaenzend geprueft:

**SR-Listener-Baseline (Feld C):** `srBaselines` wird in `stop()` geleert
(`srBaselines = [:]`, verifiziert im Impl-Protokoll S6). `srNoopCount` wird
NICHT zurueckgesetzt (Session-akumulierend, dokumentiert im Plan v1 als Absicht).
`srListenerBlocks` wird in `stop()` durch `unregisterSRListeners()` geleert.
Kein neuer Befund.

**Blip-Absorption `pendingRestart != nil` (Feld D):** Der Guard
`if pendingRestart != nil` wurde am Code verifiziert (Impl-Protokoll S8, Commit
`5798a63`). `lastKnownMissingUIDs` wird VOR dem `if`-Block aktualisiert
(korrekt, wie im Audit bestaetigt). Kein neuer Befund.

**ScrollView (Feld E):** `ForEach id: \.uid` ist stabil. `.frame(maxHeight: 400)`
ist gesetzt. Footer liegt ausserhalb. `GeometryReader`/`PreferenceKey` fehlen
(korrekt). Kein neuer Befund.

**Ergebnis: keine weiteren Funde B6 ff.**

---

## Anhang: Abweichungen am Code versus Vorbeschreibung

**B1:** Der Auditor schlug `SoloGain.effective(key:soloedKeys:deviceGains:)` vor
und verifizierte die Signatur am Code. Der Plan folgt dieser Signatur exakt. Die
tatsaechliche Signatur (verifiziert, `SoloGain.swift:37-45`) lautet:
```swift
public static func effective(
    key: String,
    soloedKeys: Set<String>,
    deviceGains: [String: Double]
) -> Float32
```
Kein Abweichung.

**B4:** Die Aufgabenbeschreibung nannte "D1 in einem neuen Dokument
`docs/v4.1/05-decisions.md`". Der Planer hat diesen Namen beibehalten. Die Datei
`docs/v4.1/05-plan-v2.md` (dieser Plan) traegt dieselbe Nummer im Dateinamen,
was am Ende zu zwei Dateien mit dem Praefix "05-" fuehrt. Das ist unvermeidbar,
weil Schritt N4 von der Aufgabe so verlangt wird. Der Umsetzer soll es nicht
umbenennen.

**Preflight:** Das Ergebnis stimmt mit dem Impl-Protokoll S12 ueberein: ABBRUCH
wegen altem 4.0.1 (10)-Archiv, WARNUNG `v4-appstore/`, WARNUNG Commits nicht
gepusht. Die Version-Pruefung zeigt korrekt 4.1 (11). Das ist unveraendert, da
kein neues Archiv erstellt wird.
