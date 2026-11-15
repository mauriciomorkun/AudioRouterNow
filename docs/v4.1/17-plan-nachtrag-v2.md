# AudioRouterNow 4.1: Nachtragsplan Durchlauf 2

Erstellt: 2026-11-15 (Planer: Fable 5, Nachtrags-Zyklus Durchlauf 2 von hoechstens 3).
Basis: Audit `docs/v4.1/16-audit-nachtrag-v1.md` (Commit `8dd0838`), Umsetzung
`docs/v4.1/15-impl-nachtrag.md`, Plan `docs/v4.1/14-plan-nachtrag.md`. Branch `release/4.1`.

---

## 1. Kopf

### 1.1 Ziel

Schliessen der offenen Befunde G1 (mittel) und G2 (mittel) sowie G3 bis G5 (niedrig)
aus dem Audit `16-audit-nachtrag-v1.md`.

### 1.2 Scope-Freeze (verbindlich)

Enthalten: nur die fuenf Befunde G1 bis G5. Kein weiterer Code ausser den unten genannten
Stellen. Keine neuen Dateien im App-Target.

### 1.3 Baseline

| Pruefung | Ergebnis (Audit-Stand `8dd0838`) |
|----------|----------------------------------|
| `bash v4/scripts/test.sh` | 60 swift-testing in 10 Suiten, 95 XCTest, alle gruen |
| App-Build | BUILD SUCCEEDED |

App-Build-Befehl:

```
cd /Users/mauriciomorkun/AudioRouterNow/v4 && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AudioRouterNow4.xcodeproj \
  -scheme AudioRouterNow4 -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Test-Befehl:

```
bash /Users/mauriciomorkun/AudioRouterNow/v4/scripts/test.sh
```

### 1.4 Leitplanken

Unveraendert aus `14-plan-nachtrag.md` Abschnitt 1.5. Zusaetzlich:
- Keine neuen Dateien in `v4/AudioRouterNow4/`.
- Keine Aenderung an `makeDirectIOBlock`, Rampe, `SoloGain.swift`, `VolumeTracker.swift`.
- Schreibstil: Umlaute korrekt, kein Gedankenstrich, kein Em-Dash, kein En-Dash,
  keine Namen oder E-Mails Dritter.
- Konventionelle Commit-Messages, Co-Author-Zeile, kein Push, kein `--no-verify`.

---

## 2. Entscheidungen

### NT2-D1: G2 Luecke 1 kein Fix (ENTSCHEIDUNG)

**Frage:** Soll bei einem Start-Fehler wegen `RouterError.tooManyOutputs` zusaetzlich
`outputLimitNotice` gesetzt werden?

**Wahl:** Kein Fix. Luecke 1 gilt als akzeptabler Zustand.

**Begruendung:** `RouterError.tooManyOutputs.errorDescription` lautet:
"Too many outputs are selected (N). AudioRouterNow can route to M at once. Remove some
outputs and press Start again."
Diese Meldung erscheint in `errorSection` (roter Text, `MenuBarView.swift` Z. 269-280) und
ist vollstaendig, erklaerend und handlungsanleitend. Der Nutzer sieht genau, was zu tun ist.
Die orangefarbene Meldung von `outputLimitNotice` liefert keinen zusaetzlichen Informationswert
und wuerde roten und orangefarbenen Text gleichzeitig zeigen, was die Hierarchie verwirrt.
Die Situation (persistierte Liste ist zu lang) unterscheidet sich semantisch von der
interaktiven Ablehnung in `addOutputConfig`: dort wird ein konkreter Wunsch abgelehnt,
hier liegt ein Fehlzustand vor. Verschiedene Signalfarben sind deshalb konsistent.
Am Code geprueft: `performStart` Z. 361-367 zeigt `status = .error(e)`, MenuBarView
Z. 48-53 zeigt `errorSection`. `outputLimitNotice` wird NICHT gesetzt, das ist richtig so.

**Rueckfall:** entfaellt (kein Eingriff).

---

### NT2-D2: G2 Luecke 2 Fix: Meldung loeschen bei Start/Restart-Erfolg (ENTSCHEIDUNG)

**Frage:** Wann soll `outputLimitNotice` geloescht werden, wenn ein erfolgreicher Start
oder Restart stattfindet?

**Situation am Code:** `outputLimitNotice` wird gesetzt in `addOutputConfig` (Z. 551)
wenn `.limitReached`. Sie wird geloescht in `removeOutputConfig` (Z. 564) und in
`addOutputConfig` beim `.allowed`-Fall (Z. 554).

**Problem:** Ein Nutzer sieht die orangefarbene Meldung (addOutputConfig abgelehnt), entfernt
danach eine andere Ausgabe per Klick (removeOutputConfig loescht die Meldung), fuegt die
gewuenschte Ausgabe hinzu und startet. Oder: Der Nutzer sieht die Meldung, drueckt Start ohne
zu aendern (bei einer Liste mit genau 255 oder weniger Ausgaben, also Start erfolgreich),
die Meldung bleibt sichtbar waehrend Routing laeuft.

**Wahl:** `outputLimitNotice = nil` in den Erfolgspfaden von `performStart` und
`restartRouting`. Nicht in `applyOutputsIfRouting`, weil dieser Pfad kein direktes Starten
durch den Nutzer ist und die Sperre in `addOutputConfig` ohnehin eingreift, bevor es zu
einem `applyOutputsIfRouting`-Aufruf kommen kann.

**Zusatzregel:** Die Meldung "Remove an output to add another" bleibt wahr, solange
`outputConfigs.count >= OutputLimits.maxConfiguredOutputs`. Deshalb wird sie NICHT beim
blossen Starten entfernt, wenn die Liste immer noch am Limit steht. Nein: das waere
zu komplex und einfacher ist klarer. Die Meldung zu loeschen bei Routing-Beginn ist das
konsistente Verhalten, weil ein Routingbeginn bedeutet, dass die Liste valide ist
(validateOutputCount war erfolgreich). Ist die Liste noch am Limit, kann man auch keine
weitere Ausgabe hinzufuegen, die Meldung erscheint wieder sofort beim naechsten Versuch.
Ein Re-Start mit exakt 255 Ausgaben ist valide (< 256), daher ist die Meldung ueberholt.

**Testmoeglichkeit:** `EngineController` und `MenuBarView` haben kein Test-Target. Eine
reine Hilfsfunktion in `OutputLimits` macht hier keinen Sinn, da es nur eine Null-Zuweisung
ist. Der Fix wird per Lektuer geprueft, Build und visuelle Verifikation durch NM-6.

**Rueckfall:** Zuweisung entfernen (eine Zeile je Funktion).

---

### NT2-D3: G1 Regressionsschutz W2 (ENTSCHEIDUNG)

**Frage:** Wie wird der Regressionsschutz gegen das spaetere Einfuehren eines
`soloedKeys`-Parameters in `soloNeutralLinear` sinnvoll gestaltet?

**Wahl:** Kombination aus Option (a) und Option (c).

(a) Ein Signatur-Test: Ein expliziter XCTest, der einen Funktionstyp-Wert gegen die aktuelle
Signatur von `soloNeutralLinear` kompiliert. Er schlaegt beim Kompilieren fehl, wenn jemand
die Signatur aendert (z.B. `soloedKeys` hinzufuegt). Kein neues Produktivcode-Verhalten noetig.

(c) Ein erklaerende Kommentar im Testkoerper von `testSoloDoesNotLowerTheWave` (bezieht G3
mit ein), der deutlich macht, dass die zwei identischen Aufrufe kein Copy-Paste-Fehler sind
und die Regressionsgarantie durch die Signatur gilt.

**Warum nicht Option (b):** "Zusammenspiel SoloGain.effective und WaveEnergyMath"
(Meter-Pfad aendert sich unter Solo, Wellen-Pfad nicht) ist bereits durch den vorhandenen
Test `testMaskedSumWouldHaveShrunkTheWave` abgedeckt: er zeigt, dass die alte Formel mit
`SoloGain.effective` kleiner ist. Ein weiterer Test in dieser Richtung wuerde sich
weitgehend wiederholen.

**Wirksamkeit des Signatur-Tests:** Wenn jemand `soloNeutralLinear` um `soloedKeys` ergaenzt,
aendert sich der Typ der Funktion. Der Signatur-Test weist einen Wert des alten Typs zu
und kompiliert nicht mehr. Der Test schlaegt also beim Kompilieren fehl, nicht erst zur
Laufzeit. Das ist der staerkste verfuegbare Schutz ohne Produktivcode zu verbiegen.

**Mutation-Probe (gedanklich):** Nach Einfuegen von `soloedKeys: Set<String> = []` als
neuen Parameter wuerde der Signatur-Test nicht kompilieren, weil der gespeicherte
Funktionswert `([...], [String], [String: Double]) -> Float32` den neuen Typ
`([...], [String], Set<String>, [String: Double]) -> Float32` nicht deckt.

**Rueckfall:** Nur Kommentar (Option c), kein Signatur-Test.

---

### NT2-D4: G4 Status-Pruefung (ENTSCHEIDUNG)

**Frage:** Ist die Dateiname-Diskrepanz in README/Abschlussbericht noch offen?

**Wahl:** Nichts zu tun. Bereits vollstaendig geloest.

**Begruendung:** Der Audit `16-audit-nachtrag-v1.md` Abschnitt 4 G4 sagt ausdruecklich:
"Status: behoben (Korrekturen in `docs/v4.1/09-final-report.md` und `docs/v4.1/README.md`
im selben Commit wie dieser Bericht)." Der HEAD-Stand der README.md (Z. 28) verweist
korrekt auf `16-audit-nachtrag-v1.md`. Kein weiterer Fix noetig.

---

### NT2-D5: G5 Array-Allokation im Poll (ENTSCHEIDUNG)

**Frage:** Soll `slotPeaks` in `updateWaveEnergy` als Instance-Variable gehalten werden
(einmal angelegt, je Tick `removeAll(keepingCapacity: true)` aufgerufen)?

**Wahl:** Kein Produktivcode-Fix. Stattdessen ein klaerenden Kommentar an der Stelle.

**Begruendung:** Die Allokation laeuft im MainActor-Poll (20 Hz), nicht im IOProc. Bei 256
Slots und 20 Hz entstehen 5120 Allokationen pro Sekunde. Das ist auf einem modernen Mac
kein messbares Problem: die Allokation ist klein (256 Tupel a 8 Byte = 2 KiB) und
kurzlebig (freigegeben nach dem Tick). Eine Instance-Variable wuerde den Zustand in
`EngineController` aufblaehen und die Lesbarkeit verschlechtern, ohne einen belegten
Laufzeitvorteil zu bringen. Das `reserveCapacity(slots)` im jetzigen Code ist bereits
eine Optimierung (reduziert Re-Allokationen innerhalb des Ticks). Das Verhalten wird
durch NM-4 am Geraet geprueft: wenn dort ein messbarer Overhead erscheint, ist der
Instance-Variable-Ansatz der natuerliche Nachzug.
Kein Verhalten, keine Tests, nur ein Kommentar.

---

## 3. Nummerierte Schritte

Nach jedem Schritt: `bash v4/scripts/test.sh` und App-Build; lokaler Commit.

---

### NT2-S0: Baseline bestaetigen

Datei: keine Aenderung.

Ausfuehren: `bash /Users/mauriciomorkun/AudioRouterNow/v4/scripts/test.sh` und App-Build.

Akzeptanz: 60 swift-testing und 95 XCTest gruen, BUILD SUCCEEDED.
Commit: keiner.

---

### NT2-S1: G1 + G3: Signatur-Test und Kommentar in `WaveEnergyMathTests.swift`

**Datei:** `v4/AudioRouterKit/Tests/AudioRouterKitTests/WaveEnergyMathTests.swift`

**Aenderung a: Kommentar in `testSoloDoesNotLowerTheWave` (G3)**

Aktuell Z. 28 (nach dem ersten `let withoutSolo`-Aufruf):
```swift
        // "Solo auf Slot 1": Funktion hat kein soloedKeys, beide Aufrufe identisch
        let withSolo = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: gains)
```

Ersetzen durch:
```swift
        // Absicht: soloNeutralLinear hat kein soloedKeys-Argument. Beide Aufrufe sind
        // identisch -- die Regressionsgarantie liegt in der Signatur der Funktion,
        // nicht im Vergleichswert. Kein Copy-Paste-Fehler.
        // Der Signatur-Test testSoloNeutralLinearSignatureHasNoSoloedKeys prueft,
        // dass die Signatur unveraendert bleibt.
        let withSolo = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: gains)
```

**Aenderung b: Neuer Test `testSoloNeutralLinearSignatureHasNoSoloedKeys` (G1)**

Am Ende der Klasse `WaveEnergyMathTests`, vor der schliessenden `}` einfuegen:

```swift
    func testSoloNeutralLinearSignatureHasNoSoloedKeys() {
        // Regressionsschutz fuer W2 (NT2-D3): Wenn jemand soloedKeys als
        // Parameter einfuehrt, kompiliert diese Zuweisung nicht mehr.
        // Der Typ muss exakt ([(l: Float32, r: Float32)], [String], [String: Double]) -> Float32 sein.
        // Kein Laufzeit-Assert noetig: der Compiler uebernimmt die Pruefung.
        let _: ([(l: Float32, r: Float32)], [String], [String: Double]) -> Float32
            = WaveEnergyMath.soloNeutralLinear
        // Platzhalter-Assertion damit der Compiler kein "never used"-Warn ausgibt.
        XCTAssertTrue(true)
    }
```

**Akzeptanz:** Kompiliert ohne Warnung. `bash v4/scripts/test.sh` zeigt 60 swift-testing
und 96 XCTest gruen (1 neuer Test). App-Build: BUILD SUCCEEDED.

Commit-Muster:
`test(AudioRouterKit): Signaturtest und Kommentar fuer W2-Regressionsschutz (G1, G3, NT2-D3)`

---

### NT2-S2: G2 Luecke 2: `outputLimitNotice` in `performStart` und `restartRouting` loeschen

**Datei:** `v4/AudioRouterNow4/EngineController.swift`

**Stelle 1: `performStart` (Z. 345-368 am aktuellen Code)**

Im Erfolgsblock nach `if status == .routing { ... }`, nach `startPolling()` und vor der
schliessenden `}` des `if status == .routing`-Blocks:

```swift
                // NT2-D2: Meldung loeschen, Routing ist erfolgreich gestartet.
                outputLimitNotice = nil
```

Konkret: nach Z. 358 (`if !soloedKeys.isEmpty { applySoloGains() }`), vor Z. 359
(`UserDefaults.standard.set(true, forKey: Self.wasRoutingKey)`):

```swift
                outputLimitNotice = nil
```

Der Kommentar kann direkt vor der Zuweisung stehen, eine Zeile genuegt.

**Stelle 2: `restartRouting` (Z. 422-443 am aktuellen Code)**

Im Erfolgsblock nach `captureDeviceLatencies()` und dem Solo-Pfad, vor der schliessenden
`}` des `do`-Blocks (also nach Z. 435, `if !soloedKeys.isEmpty { applySoloGains() }`):

```swift
                // NT2-D2: Meldung loeschen, Routing-Neustart erfolgreich.
                outputLimitNotice = nil
```

**Was nicht geaendert wird:** `applyOutputsIfRouting`, `removeOutputConfig`,
`addOutputConfig`. Diese Pfade sind bereits korrekt (removeOutputConfig loescht, addOutputConfig
loescht beim Zulassen). Stopp loescht `outputLimitNotice` nicht bewusst (kein Routing mehr,
Meldung ist dann irrelevant aber nicht stoerend; Nutzer wird sie sehen wenn er das Panel oeffnet,
kann aber durch Klick auf "Entfernen" die Situation beheben).

**Akzeptanz:** App baut. Lektuer bestaetigt: nach erfolgreichem Start und Restart ist
`outputLimitNotice == nil`. Testbar mit NM-6 am Geraet.

Commit-Muster:
`fix(EngineController): outputLimitNotice bei erfolgreichem Start und Restart loeschen (G2, NT2-D2)`

---

### NT2-S3: G5: Kommentar in `updateWaveEnergy` (EngineController)

**Datei:** `v4/AudioRouterNow4/EngineController.swift`

**Stelle:** Zeile mit `slotPeaks.reserveCapacity(slots)` (aktuell ca. Z. 762).

Direkt darunter oder als Kommentar davor einfuegen:

```swift
        // NT2-D5: slotPeaks wird je Tick neu angelegt (MainActor, 20 Hz, kein IOProc).
        // Bei 256 Slots sind das ~5120 Allokationen/s, auf einem Mac vernachlaessigbar.
        // Falls NM-4 einen messbaren Overhead zeigt: Instance-Variable + removeAll(keepingCapacity: true).
```

**Akzeptanz:** App baut. Keine Test-Aenderung.

Commit-Muster:
`style(EngineController): Kommentar zur slotPeaks-Allokation im Poll (G5, NT2-D5)`

---

### NT2-S4: Doku-Update

**Datei a:** `docs/v4.1/15-impl-nachtrag.md`
Abschnitt am Ende (nach "Restrisiken"): einen neuen Abschnitt "Nachtrag Durchlauf 2" anhaengen.

**Datei b:** `docs/v4.1/README.md`
Eintrag 17 (diesen Plan) und Eintrag 18 (Impl-Protokoll Durchlauf 2 oder Nachtrag in 15) ergaenzen.

Konkret fuer README.md, nach dem letzten Eintrag (16) eine neue Zeile:
```
| [17-plan-nachtrag-v2.md](17-plan-nachtrag-v2.md) | Nachtragsplan Durchlauf 2 (Planer: Fable 5, 2026-11-15). Scope: G1 (Signaturtest W2), G2-Luecke-2 (outputLimitNotice bei Erfolg loeschen), G3 (Kommentar), G4 (bereits geloest), G5 (Kommentar). 4 Schritte NT2-S0 bis NT2-S4, 5 Entscheidungen NT2-D1 bis NT2-D5. Status: umgesetzt, siehe 18. |
| [18-impl-nachtrag-v2.md](18-impl-nachtrag-v2.md) | Umsetzungsprotokoll Durchlauf 2 (Umsetzer: Fable 5). Pro Schritt NT2-S0 bis NT2-S4 Status, Commit-Hash, Test- und Build-Ergebnis, Abweichungen. Status: ausstehend. |
```

**Akzeptanz:** README-Tabelle konsistent. Impl-Protokoll (18) wird nach der Umsetzung angelegt.

Commit-Muster:
`docs(v4.1): Plan Nachtrag Durchlauf 2 und README-Update (NT2-S4)`

---

## 4. Verbotsliste

Unveraendert aus `14-plan-nachtrag.md` Abschnitt 4, zusaetzlich:
- Keine Aenderung an `applyOutputsIfRouting`, `addOutputConfig`, `removeOutputConfig`
  ausser den explizit genannten zwei Zeilen in NT2-S2.
- Keine Aenderung an `WaveEnergyMath.soloNeutralLinear` (Produktivcode unberuehrt).
- Historische Plan- und Audit-Dokumente 02 bis 16 nicht umschreiben.
- G4 nicht noch einmal "beheben" (bereits geloest, kein Eingriff).
- Push, Tag, Einreichung, Entitlements, Signierung.

---

## 5. Risiken

| Risiko | Einschaetzung | Massnahme |
|--------|---------------|-----------|
| Signatur-Test kompiliert nicht (Swift-Version) | niedrig; `let _: Typ = Funktion` ist Standard-Swift | Umsetzer prueft Syntax gegen bestehende Testdateien |
| `outputLimitNotice = nil` im falschen Block | niedrig; am Code konkret belegt | Umsetzer prueft Zeilennummern vor dem Edit |
| Kommentar-Einzug aendert Stil | keine Auswirkung auf Tests/Build | Bestehenden Stil im File beachten |
| Compiler-Warnung "never used" fuer `let _` | moeglich | `let _` oder explizit `_ = ...` verwenden |

---

## 6. NUTZER MUSS MESSEN (unveraendert)

| ID | Thema |
|----|-------|
| NM-1 | Hoerpruefung: Lautstaerke, Solo und Pegel fuer Ausgaben ab Index 16 |
| NM-2 | Pegelanzeige ab der 17. Ausgabe |
| NM-3 | Welle unter Solo gleich hoch wie ohne Solo |
| NM-4 | CPU-Last bei 16 und 45+ Slots |
| NM-5 | Panel-Bedienbarkeit bei sehr vielen Zeilen |
| NM-6 | Meldung bei Ausgabenlimit (fixedSize-Layout sauber); und: nach erfolgreichem Start verschwindet die Meldung |
| NM-7 | Speicher bei 45+ aktiven Slots |

---

## 7. Audit-Leitfaden fuer Durchlauf 2

Checkliste fuer den unabhaengigen Fable-Auditor.

### Pflichtschritte

1. `bash v4/scripts/test.sh` ausfuehren: 60 swift-testing und 96 XCTest gruen erwartet.
2. App-Build: BUILD SUCCEEDED erwartet, keine neuen Swift-Warnungen.
3. `git diff 8dd0838 HEAD` lesen: Diff enthaelt nur die unten genannten Stellen.

### Checkliste G1

- [ ] `WaveEnergyMathTests.swift`: Test `testSoloNeutralLinearSignatureHasNoSoloedKeys`
  existiert und hat den Typ `([(l: Float32, r: Float32)], [String], [String: Double]) -> Float32`.
- [ ] Der Test ist nicht tautologisch (prueft Signatur, nicht Laufzeitwert).
- [ ] Mutation-Check (Lektuer): Wenn `soloNeutralLinear` einen neuen Parameter `soloedKeys`
  bekommen wuerde, wuerde der Typ nicht mehr passen und der Test nicht kompilieren.

### Checkliste G2

- [ ] NT2-D1 bestaetig: Kein `outputLimitNotice`-Setzen im Fehlerpfad von `performStart`.
  `errorSection` zeigt `.tooManyOutputs`-Text (rot, erklaerend). Begruendung in NT2-D1.
- [ ] `performStart` Erfolgsblock: `outputLimitNotice = nil` ist vorhanden,
  nach `applySoloGains()` oder `startPolling()`, vor `UserDefaults.set(wasRoutingKey)`.
- [ ] `restartRouting` Erfolgsblock: `outputLimitNotice = nil` ist vorhanden,
  nach `applySoloGains()`.
- [ ] `applyOutputsIfRouting`: unveraendert (kein `outputLimitNotice`).
- [ ] Szenario-Probe (Lektuer): Nutzer sieht Meldung (limitReached), startet mit 254
  Ausgaben (< 255, also erfolgreich). Nach Start ist `outputLimitNotice == nil`. Korrekt.

### Checkliste G3

- [ ] `testSoloDoesNotLowerTheWave` enthaelt den erklaerenden Kommentar vor `let withSolo`.
- [ ] Kommentar nennt: Absicht, Signatur ohne soloedKeys, Verweis auf Signatur-Test.

### Checkliste G4

- [ ] `docs/v4.1/README.md` Z. 28: Verweis auf `16-audit-nachtrag-v1.md`. Kein weiterer Fix.
- [ ] `docs/v4.1/09-final-report.md`: Verweis auf `16-audit-nachtrag-v1.md` (im Audit behoben).

### Checkliste G5

- [ ] `EngineController.swift` nahe `slotPeaks.reserveCapacity`: Kommentar vorhanden.
- [ ] Kein Produktivcode-Fix (kein neues Instance-Feld, kein `removeAll`).

### Checkliste Regression

- [ ] `WaveEnergyMath.soloNeutralLinear`: Signatur und Implementierung unveraendert.
- [ ] `SoloGain.swift`: keine Aenderung.
- [ ] `makeDirectIOBlock`: keine Aenderung (`git diff 8dd0838 HEAD -- v4/AudioRouterKit/Sources/AudioRouterKit/FanOutEngine.swift`).
- [ ] `addOutputConfig`, `removeOutputConfig`: nur die explizit geplanten Zeilen geaendert.
- [ ] Keine neuen Dateien in `v4/AudioRouterNow4/`.
- [ ] Keine Em-Dashes, En-Dashes, Gedankenstriche in neuen Zeilen.
- [ ] Keine Namen oder E-Mails Dritter.
- [ ] Kein Push, kein Tag.

---

## 8. Abschlussschritte nach der Umsetzung

1. Umsetzungsprotokoll `docs/v4.1/18-impl-nachtrag-v2.md` anlegen (neue Datei, SPM-Pfad,
   kein App-Target, kein `.pbxproj`-Eingriff).
2. README-Eintrag 18 auf "fertig" setzen.
3. Wenn Audit Durchlauf 2 kein neues Mittel-Befund meldet: Nachtrags-Zyklus abgeschlossen.
   Dann gilt der Abschlussbericht `09-final-report.md` als abschliessend erweiterbar
   (Nachtrag-Abschnitt 11 schon vorhanden, ggf. Stand-Datum aktualisieren).
4. Offene Nutzeraufgaben (Messungen NM-1 bis NM-7, Store-Texte, Archiv, Einreichung)
   bleiben unveraendert (aus `09-final-report.md` und CLAUDE.md).
