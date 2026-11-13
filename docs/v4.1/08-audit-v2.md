# AudioRouterNow 4.1: Audit Durchlauf 2

Auditor: Fable 5 (Durchlauf 2 des Fable/Opus/Fable-Kreislaufs)
Gepruefter Stand: Branch `release/4.1`, Commits `41d4673..HEAD`
(6 Produktivcommits: `cba4489`, `fd502c7`, `f2f7deb`, `c079c27`, `68c8d71`, `8eae52b`; plus README-Update `70fcfe0`)
Datum: 2026-11-13

---

## Zusammenfassung

Alle fuenf Befunde B1 bis B5 aus den vorherigen Runden sind behoben oder
dokumentiert. Kein Produktivcode wurde verbotenerweise veraendert. Build, Tests
und Preflight verhalten sich wie erwartet. Zwei neue Befunde, beide niedrig:

- **C1 (niedrig):** Naming-Kollision der Entscheidungs-ID "D1" in zwei
  Dokumenten mit unterschiedlichem Bezugspunkt. Navigatorisch leicht
  irreleading, kein Code-Fehler.
- **C2 (niedrig):** Wellenenergie (`sum / Float32(slots)`) teilt durch die
  Gesamtzahl aller Slots, nicht nur durch die aktiven Solo-Slots. Das war
  eine bewusste Planer-Entscheidung (Entscheidung D1 in `05-plan-v2.md`).
  Als Pruefliste-Element explizit aufgegriffen; kein Befund, sondern eine
  bestaetigt-dokumentierte Entwurfswahl. Siehe Abschnitt B1 unten.

Urteil: **Kein neuer Durchlauf noetig.**

---

## Testlauf und Build

### Testlauf

Befehl (selbst ausgefuehrt):

```
cd /Users/mauriciomorkun/AudioRouterNow/v4 && bash scripts/test.sh
```

Ergebnis:

```
Test run with 59 tests in 10 suites passed after 0.088 seconds.
```

XCTest (im selben Lauf, Framework AudioRouterKitTests):

```
Executed 56 tests, with 0 failures (0 unexpected) in 0.019 seconds
```

Gesamt: 59 swift-testing + 56 XCTest, alle gruen. Unveraendert gegenueber
Durchlauf 1.

Suiten im Detail (XCTest): ExclusiveRoutingTests (11), SRListenerTests (6),
SlotGainsTests (8), SoloGainTests (7), VolumeFreezeTests (9),
VolumeScalingTests (15).

### App-Build

Befehl (selbst ausgefuehrt):

```
cd /Users/mauriciomorkun/AudioRouterNow/v4 && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AudioRouterNow4.xcodeproj \
  -scheme AudioRouterNow4 -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Ergebnis: `** BUILD SUCCEEDED **`, keine Swift-6-Warnungen, keine neuen
Compiler-Meldungen (Umgebungsmeldungen DVTCoreDeviceCore/CoreSimulator sind
Xcode-Installations-Hinweise, keine Build-Fehler).

### Preflight

Befehl (selbst ausgefuehrt):

```
bash /Users/mauriciomorkun/AudioRouterNow/v4/scripts/preflight.sh
```

Ergebnis (waehrend Audit-Lauf; der untracked Entwurf dieser Datei erzeugt
eine dritte Warnung, die nach dem Commit verschwindet):

```
1. Projektbaum
  WARNUNG v4-appstore/ existiert noch.

2. Version
  OK      xcconfig sagt 4.1 (11)
  OK      Keine zweite Versionsquelle im Projekt

3. Build-Nummer gegen vorhandene Tags
  OK      Tag v4.1 existiert noch nicht

4. Arbeitsbaum
  WARNUNG Nicht committete Aenderungen (Audit-Entwurf dieser Datei, transient).
  WARNUNG Commits sind noch nicht gepusht

5. Berechtigungen (Release)
  OK      App Sandbox aktiv
  OK      Audio Input vorhanden

6. Letztes Archiv (falls vorhanden)
  Archiv: AudioRouterNow4 07-10-2026, 17.55.xcarchive
  ABBRUCH Archiv ist 4.0.1 (10), erwartet war 4.1 (11)
  OK      Archiv stammt aus v4/ (110 Pfadverweise)
```

ERGEBNIS: 1 ABBRUCH (altes 4.0.1-(10)-Archiv), 2 Warnungen nach Commit.
Kein neuer ABBRUCH gegenueber dem Planer-Lauf. Version-Pruefung:
"4.1 (11)" erkannt (B5 erfuellt).

---

## Status B1 bis B5

### B1: `updateWaveEnergy()` nutzt `SoloGain.effective(...)` fuer Meter UND `sum`

**Status: behoben.**

Beleg (selbst am Code geprueft):

- `EngineController.swift` Z. 754 (Commit `cba4489`):
  ```swift
  let gain = SoloGain.effective(key: key, soloedKeys: soloedKeys, deviceGains: deviceGains)
  ```
  Die alte Zeile `let gain = Float32(deviceGains[key] ?? 1.0)` existiert in
  `updateWaveEnergy()` nicht mehr. Grep-Treffer fuer `deviceGains[key]` in der
  Funktion: null (einziger Treffer liegt in `setDeviceGain` Z. 478, der
  Persistenz-Schreibpfad, korrekt).
- `SoloGain.effective` ist ueber `AudioRouterKit` importiert (Z. 12,
  unveraendert); kein neuer Import noetig.
- `sum` wird pro Slot mit `p = raw * gain` (Z. 755, 762) berechnet; stumme
  Slots (gain = 0.0) tragen 0 bei. Konsistenz zwischen Meter und Welle ist
  hergestellt.

**Zur `sum / Float32(slots)`-Frage:** Der Divisor ist `engine.slotDeviceKeys.count`
(alle konfigurierten Slots, inkl. durch Solo stumm geschalteter). Damit sinkt
die berechnete Wellenenergie unter Solo proportional zur Anzahl der stummen
Slots. Beispiel: 1 von 4 Slots solo'd, solo-Slot bei Vollpegel -> `linear = 0.25`
statt `1.0` ohne Solo. Das ist die dokumentierte Entwurfswahl D1 aus
`docs/v4.1/05-plan-v2.md` Abschnitt 2: "Stumme Slots zaehlen nicht.
Konsistenz zwischen Welle und Metern: beide zeigen die effektiv ausgegebene
Energie." Das Verhalten ist beabsichtigt und dokumentiert; kein Befund.

### B2: RELEASE_NOTES-Blip-Formulierung hardware-neutral

**Status: behoben.**

Beleg (selbst am Code geprueft):

- `grep "keeps running without interruption" RELEASE_NOTES.md` liefert nur
  Z. 453 (altes Bluetooth-Feature einer frueheren Version), keinen Treffer
  im 4.1-Abschnitt.
- `grep "pending restart is discarded" RELEASE_NOTES.md` liefert Z. 192
  (im 4.1-Abschnitt, Satz "pending restart is discarded and the engine keeps
  running on the same session").
- Der nachfolgende Satz: "Whether audio stays audibly uninterrupted depends
  on the hardware and can only be confirmed on a real device." (verifiziert)
- Kein Gedankenstrich, kein Superlativ, kein Nutzername im neuen Block.

### B3: Testfall prueft leeren Key unter aktivem Solo

**Status: behoben. Aussagekraft ausreichend, kein Tautologie-Risiko.**

Beleg (selbst am Code geprueft):

`SoloGainTests.swift` Z. 47-54 (Commit `f2f7deb`):
```swift
func testEmptyKeyDoesNotCrashAndDefaultsToUnityWithoutSolo() {
    XCTAssertEqual(SoloGain.effective(key: "", soloedKeys: [], deviceGains: [:]), 1.0, accuracy: 1e-6)
    XCTAssertEqual(SoloGain.effective(key: "", soloedKeys: ["x:0"], deviceGains: [:]), 0.0, accuracy: 1e-6)
    XCTAssertEqual(SoloGain.effective(key: "", soloedKeys: [""], deviceGains: [:]), 1.0, accuracy: 1e-6)
}
```

Tautologie-Pruefung (selbst durchgefuehrt): Wenn man die Bedingung in
`SoloGain.swift` Z. 44 invertiert (`!soloedKeys.contains(key) ? base : 0.0`),
liefert die zweite Assertion 1.0 statt 0.0. Der Test wuerde rot. Kein
Tautologie-Risiko.

Anzahl `XCTAssertEqual` in der Datei: 14 (war 12 laut Impl-Protokoll, Plan
verlangte mindestens 10).

### B4: `05-decisions.md`, CHANGELOG, RELEASE_NOTES, `06-appstore-texts.md`

**Status: behoben.**

Einzelpunkte:

1. **05-decisions.md (B4a):** Datei existiert (Commit `c079c27`). Enthaelt
   D1 "Accept that build 10 to 11 resets Launch at Login" mit den vier
   Feldern Decision, Why not a regression, Effect on user, Why no code fix
   plus Fallback. Kein Nutzername, kein Gedankenstrich, kein Marketing-
   Versprechen. Kein Em-/En-Dash (Python-geprueft).

2. **CHANGELOG und RELEASE_NOTES (B4b, Commit `68c8d71`):**
   - CHANGELOG.md Z. 111: "Launch at Login is reset after the update" als
     neuer Eintrag in der `### Changed`-Rubrik des 4.1-Abschnitts. Verweis
     auf `docs/v4.1/05-decisions.md, D1` korrekt.
   - RELEASE_NOTES.md: neuer Abschnitt "Launch at Login is reset after the
     update" vor "Wording". Erklaert die Ursache, gibt Schritt-fuer-Schritt-
     Anweisung (Footer-Checkbox). Kein Em-/En-Dash, kein Nutzername.
   - Behauptung "Footer-Schalter" am Code verifiziert:
     `RoutingControls.swift` Z. 173 zeigt `Toggle("Launch at Login", ...)`
     mit `.toggleStyle(.checkbox)` in der Footer-Zeile. Korrekt.
   - Behauptung "Auto-Start nach Login" (`wasRouting`/`autoStartIfNeeded`):
     `wasRouting` ist NICHT an die Build-Nummer gebunden, persistiert also
     ueber Updates. Auto-Start beim naechsten App-Launch bleibt erhalten.
     Das ist vorhandenes Verhalten und wird in der Doku nicht erwaehnt
     (korrekt: es ist keine Aenderung durch dieses Update).

3. **06-appstore-texts.md (B4c, Commit `8eae52b`):** Datei existiert. Drei
   Abschnitte: What's New, Review-Notiz, Store-Description-Ersetzung.
   - What's New: 1103 Zeichen (Limit 4000, eingehalten).
   - Store-Description-Ersatztext: "AudioRouterNow runs fully sandboxed. No
     kernel extension. No virtual driver. No reboot." (87 Zeichen). Sachlich,
     ohne Superlativ, ohne Marketing.
   - Schritt-fuer-Schritt-Anleitung fuer App Store Connect korrekt und
     vollstaendig (URL, Reiter, Feldbeschreibung, Speicher-Hinweis).
   - Einzige E-Mail: `dev@mauriciomorkun.com` (laut Plan ausdruecklich
     erlaubt; kein privater Name).
   - Kein Em-/En-Dash, kein Nutzername (Python-geprueft).

4. **Weitere build-nummernabhaengige Zustaende:** Alle Vorkommen von
   `currentBuildNumber` und `CFBundleVersion` in `EngineController.swift`
   wurden geprueft (8 Vorkommen). Neben dem Launch-at-Login-Consent gibt es
   keine weiteren build-nummernabhaengigen Zustaende mit Nutzerwirkung.
   `openBugReport()` liest die Build-Nummer nur zur Anzeige; kein
   persistierter Zustand ist davon abhaengig.

### B5: Preflight-Ergebnis unabhaengig bestaetigt

**Status: bestaetigt.**

Selbst ausgefuehrt (siehe Abschnitt "Testlauf und Build"). Ergebnis:
1 ABBRUCH (altes 4.0.1-(10)-Archiv), 2 Warnungen nach Commit. Version
"4.1 (11)" erkannt. Das entspricht exakt der Plan-Erwartung: Der ABBRUCH
ist unvermeidlich bis ein neues 4.1-Archiv gebaut wird (Einreichungsschritt,
ausserhalb des Scopes). Der Umsetzer muss vor der Einreichung in Xcode
archivieren (Product > Archive) und danach `preflight.sh` erneut ausfuehren;
dann muss der ABBRUCH verschwunden sein.

---

## Neue Befunde

### C1 (niedrig): Naming-Kollision "D1" in zwei Dokumenten

**Datei/Stellen:**
- `docs/v4.1/05-plan-v2.md` Abschnitt 2: "D1: Entscheidung zur
  `sum`-Berechnung fuer die Wellenenergie"
- `docs/v4.1/05-decisions.md` Abschnitt "D1: Accept that build 10 to 11
  resets Launch at Login"
- `EngineController.swift` Z. 752: "Entscheidung D1 (Planer, 2026-11-13)"
  (meint die Wellenenergie-D1 aus plan-v2.md)
- `CHANGELOG.md` Z. 120: "See docs/v4.1/05-decisions.md, D1" (meint die
  Launch-at-Login-D1 aus decisions.md)

**Beschreibung:** Zwei verschiedene Entscheidungen in zwei verschiedenen
Dokumenten tragen denselben Bezeichner "D1". Ein kuenftiger Leser, der den
Code-Kommentar "Entscheidung D1 (Planer, 2026-11-13)" nachschlaegt, oeffnet
wahrscheinlich `05-decisions.md` zuerst und findet die Launch-at-Login-
Entscheidung statt der Wellenenergie-Entscheidung. `05-decisions.md` hat
einen Praeambel-Satz, der auf plan-v2.md verweist ("the display-consistency
decision D1 for the wave energy [...] are documented in `05-plan-v2.md`"),
womit die Ambiguitaet aufloesbar ist, aber nur wenn man diesen Satz liest.

**Beleg:** Gelesen (nicht ausgefuehrt).

**Sicherheit:** bewiesen (Naming-Kollision vorhanden).

**Schweregrad:** niedrig. Kein Code-Fehler, kein Datenverlust, keine
Audio-Auswirkung. Reine Dokumentations-Verwirrung.

**Korrekturvorschlag:** Den Wellenenergie-Eintrag in `05-plan-v2.md` und den
Code-Kommentar in `EngineController.swift` Z. 752 auf "D1-wave" (oder einen
anderen eindeutigen Bezeichner) umbenennen, sodass er nicht mit dem
Launch-at-Login-D1 in `05-decisions.md` kollidiert. Alternativ: im
Code-Kommentar explizit `05-plan-v2.md D1` statt nur "D1" schreiben.

---

## Pruefliste A1 bis A14 (unveraendert aus Audit v1, Regression)

Alle A-Positionen aus Audit v1 wurden stichprobenartig am aktuellen HEAD
re-verifiziert. Keine neuen Abweichungen.

| ID | Kurzbezeichnung | Status |
|----|----------------|--------|
| A1 | deviceGains unberuehrt durch Solo | OK |
| A2 | Footer ausserhalb ScrollView | OK: MenuBarView.swift Z. 77-80 |
| A3 | Hoehe geclampt | OK: `.frame(maxHeight: 400)` Z. 73 |
| A4 | fixedSize am Root-VStack | OK: Z. 87 |
| A5 | Solo-Reset bei stopRouting | OK: `soloedKeys = []` Z. 399 |
| A6 | applySoloGains nach Restart-Pfaden | OK: performStart Z. 355, restartRouting Z. 432, applyOutputsIfRouting Z. 596, warmRestartForSampleRateChange Z. 857 |
| A7 | SR-Listener-Konservatismus | OK |
| A8 | Blip-Verwerfen nur bei aktivem pendingRestart | OK |
| A9 | NUTZER-MESSEN nicht als verifiziert | OK: B2 behoben |
| A10 | Keine neuen Dateien in v4/AudioRouterNow4/ | OK: Commit `cba4489` aendert nur EngineController.swift |
| A11 | Tests gruen und Anzahl gestiegen | OK: 56 XCTest (14 XCTAssertEqual in SoloGainTests gegenueber 12) |
| A12 | Conventional Commits und kein Push | OK: alle 7 neuen Commits conventional, kein Tag, kein Push |
| A13 | Version angehoben | OK: xcconfig 4.1 (11) |
| A14 | Superlativ aus Repo entfernt | OK: 06-appstore-texts.md hat Ersatzformulierung ohne Superlativ |

---

## Abdeckungstabelle Pruefleitfaden 1 bis 9

| Feld | Status | Befund |
|------|--------|--------|
| 1. B1 (updateWaveEnergy) | geprueft | behoben; `sum/slots`-Verhalten dokumentiert (D1 plan-v2.md), kein Befund |
| 2. B2 (RELEASE_NOTES Blip) | geprueft | behoben; Formulierung korrekt hardware-neutral |
| 3. B3 (Testfall leerer Key) | geprueft | behoben; Tautologie-Pruefung bestanden |
| 4. B4 (decisions, CHANGELOG, texts) | geprueft | behoben; alle Behauptungen am Code verifiziert; Zeichenlimits eingehalten |
| 5. B5 (preflight) | selbst ausgefuehrt | bestaetigt; "4.1 (11)" erkannt, ABBRUCH nur wegen altem Archiv |
| 6. Regression Durchlauf 1 | geprueft | keine neuen Befunde; alle A1-A14 intakt |
| 7. Protokoll-Treue 07-impl-v2.md | geprueft | alle Behauptungen des Umsetzers am Code verifiziert; minimale Abweichungen (Zeilenumbruch N2, getrennte Commits N4/N5, README-Strategie N7) sind sachlich und korrekt erklaert |
| 8. Repo-Konsistenz | geprueft | keine Em-/En-Dashes, keine Nutzernamen in neuen Inhalten (Python-geprueft); alle 7 Commits conventional; kein Push; Arbeitsbaum sauber nach Commit |
| 9. Eigene Suche | geprueft | C1 (Naming-Kollision D1); sum/slots als Plan-entscheidung erkannt und bewertet; keine weiteren Befunde |

---

## Nicht pruefbar ohne Hardware (M1 bis M9)

| ID | Beschreibung |
|----|-------------|
| M1 | ScrollView mit 45+ Eintraegen, Footer immer sichtbar, MacBook 13" Panel passt auf Bildschirm |
| M2 | Header-Toggle startet/stoppt, im starting-Zustand deaktiviert, kein Doppelstart |
| M3 | Solo ohne Knacksen waehrend laufender Musik, gespeicherte Gains unveraendert nach Aufheben |
| M4 | Solo bei abgestecktem Geraet: alle anderen stumm; nach Aufheben alle verbliebenen hoerbar |
| M5 | maxSlots-Grenze (16): Slot 16+ spielt weiter unter Solo (bekannte Einschraenkung) |
| M6 | SR-Noop-Rate: nach 15+ min ohne SR-Wechsel Zaehler 0 oder sehr niedrig |
| M7 | SR-Restart bei echtem Wechsel (z.B. 48 kHz zu 44.1 kHz): Warm-Restart innerhalb 1-3 s |
| M8 | Blip-Absorption: USB-Aussetzer unter 2 s ohne hoerbare Luecke oder kuerzere Unterbrechung |
| M9 | Meter-Anzeige unter Solo: Signal-Meter solo-stumm geschalteter Slots zeigen 0, konsistent zu 0.4-Opacity |

---

## Protokoll-Treue von `07-impl-v2.md`

Alle Behauptungen des Umsetzers wurden am Code geprueft:

- "N1: `let gain = SoloGain.effective(...)` statt `deviceGains[key]`" korrekt
  (EngineController.swift Z. 754).
- "N1: `grep -n deviceGains[key]` findet nur noch setDeviceGain" korrekt.
- "N2: `grep keeps running without interruption` liefert im 4.1-Abschnitt
  keinen Treffer mehr" korrekt.
- "N2: `grep pending restart is discarded` liefert einen Treffer" korrekt
  (Z. 192).
- "N3: `grep -c XCTAssertEqual` = 14 (war 12)" korrekt (selbst ausgefuehrt:
  14; Plan sagte "mindestens 10", beides eingehalten).
- "N3: 7 Testmethoden unveraendert" korrekt.
- "N4: 05-decisions.md existiert mit D1 zu Launch-at-Login-Reset" korrekt.
- "N4: Footer-Schalter verifiziert (`RoutingControls.swift:173`)" korrekt.
- "N5: CHANGELOG und RELEASE_NOTES ergaenzt, kein vorhandener Text geloescht"
  korrekt.
- "N6: 06-appstore-texts.md existiert mit drei Abschnitten" korrekt.
- "N7: 59 swift-testing + 56 XCTest gruen, Build SUCCEEDED" korrekt
  (selbst ausgefuehrt).
- Alle genannten Commits (`cba4489`, `fd502c7`, `f2f7deb`, `c079c27`,
  `68c8d71`, `8eae52b`, `70fcfe0`) existieren auf `release/4.1`.
- Verbotsliste: Consent-Mechanik unberuehrt (grep auf `ensureLoginItemCompliance`,
  `hasValidLaunchAtLoginConsent`, `launchAtLoginConsentBuild` ueber den
  `e7db9fe..HEAD`-Diff liefert keine Treffer mit `+`-Praefix).
- Kein Push, keine Einreichung, kein `reset --hard`, kein `--no-verify`.

Keine widerspruechlichen Behauptungen gefunden.

---

## Urteil: Neuer Durchlauf noetig

**Nein.**

Begruendung: B1 bis B5 sind sauber behoben oder dokumentiert. Die zwei
neuen Befunde sind beide niedrig: C1 ist eine reine Doku-Namenskollision
ohne Code-Auswirkung. Die `sum/slots`-Frage ist eine dokumentierte
Entwurfswahl, kein Befund. Build und Tests sind gruen. Preflight erkennt
"4.1 (11)" korrekt; der einzige ABBRUCH betrifft das alte Archiv und ist
aufloesbarer Nutzerschritt vor der Einreichung.

**Empfehlung fuer C1:** Im naechsten Commit oder bei Gelegenheit den
Code-Kommentar in `EngineController.swift` Z. 752 von "D1" auf "D1-wave"
oder "D1 (05-plan-v2.md)" praezisieren. Kein eigener Zyklus noetig.
