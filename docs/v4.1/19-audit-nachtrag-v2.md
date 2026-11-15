# AudioRouterNow 4.1: Audit Nachtrag, Durchlauf 2

Auditor: Fable 5, unabhaengig. Datum: 2026-11-15.
Plan: `docs/v4.1/17-plan-nachtrag-v2.md` (Commit `23be274`).
Umsetzung: `docs/v4.1/18-impl-nachtrag-v2.md` (Commits `5835733` bis `07bdfef`).
Basis-Audit: `docs/v4.1/16-audit-nachtrag-v1.md` (Commit `8dd0838`).

Stand: abgeschlossen.

---

## 1. Zusammenfassung

Testlauf, Build und Preflight erfolgreich (60 swift-testing + 96 XCTest gruen, BUILD SUCCEEDED,
1 ABBRUCH + 2 Warnungen wie erwartet). Diff deckt genau 5 Dateien plus Doku, keine unerlaubten
Stellen geaendert, keine neuen Dateien im App-Target. G1 (Signaturtest), G2 Luecke 2
(outputLimitNotice bei Erfolg loeschen), G3 (erklaereder Kommentar) und G4 (unveraendert
geloest) sind sauber behoben; NT2-D1 (G2 Luecke 1 kein Fix) ist am Code bestaetigt. G5
(Array-Allokation, Kommentar ergaenzt) hat einen Nachtrag-Befund: der Kommentar enthaelt eine
falsche Zahl (H1, mittel). Mutationstest Variante a (kein Default): Kompilierungsfehler, Test
schlaegt an. Variante b (mit Default): ebenfalls Kompilierungsfehler, Test schlaegt an. Kein
Befund hoch.

---

## 2. Testlauf, Build und Preflight

Alle Befehle auf Branch `release/4.1`, HEAD-Commit `07bdfef`.

### test.sh

```
bash /Users/mauriciomorkun/AudioRouterNow/v4/scripts/test.sh
```

Ergebnis: 60 swift-testing in 10 Suiten, 96 XCTest, alle gruen, 0 Fehler.
Zuwachs gegenueber Eingang (60/95): +1 XCTest (`testSoloNeutralLinearSignatureHasNoSoloedKeys`).
Plan-Erwartung: 60 swift-testing und 96 XCTest. Erfuellt.

### App-Build

```
cd /Users/mauriciomorkun/AudioRouterNow/v4 && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AudioRouterNow4.xcodeproj -scheme AudioRouterNow4 \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Ergebnis: BUILD SUCCEEDED. Keine neuen Swift-Warnungen (selbst geprueft).

### preflight.sh

```
bash /Users/mauriciomorkun/AudioRouterNow/v4/scripts/preflight.sh
```

Ergebnis: 1 ABBRUCH (letztes Archiv ist 4.0.1 (10), erwartet 4.1 (11)), 2 Warnungen
(v4-appstore/ vorhanden, Commits nicht gepusht). Entspricht der Planerwartung.

### Mutationstest G1

**Variante a: `soloedKeys: Set<String>` OHNE Default-Wert einfuegen**

Kopie des Pakets in /tmp-Verzeichnis. `WaveEnergyMath.soloNeutralLinear` um Parameter
`soloedKeys: Set<String>` (ohne Default) ergaenzt.

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Ergebnis: Compilerfehler in `WaveEnergyMathTests.swift`:
"missing argument for parameter 'soloedKeys' in call" (11 Stellen).
Der Signatur-Test `testSoloNeutralLinearSignatureHasNoSoloedKeys` ist NICHT die Ursache der
Compilerfehler, denn alle anderen Tests (Z. 16, 27, 33, 47, 71, 84, 90, 98, 105, 112 ff.) rufen
die Funktion ebenfalls auf und liefern denselben Fehler. Das Ergebnis ist trotzdem korrekt:
die Testsuite kompiliert nicht, also schlaegt sie fehl. Der Signatur-Test traegt dazu bei
(Z. 144-145, Typ-Inkompatibilitaet). Bewiesen.

**Variante b: `soloedKeys: Set<String> = []` MIT Default-Wert einfuegen**

Kopie des Pakets in /tmp-Verzeichnis. `soloedKeys: Set<String> = []` als dritter Parameter.

Ergebnis: Compilerfehler in `WaveEnergyMathTests.swift` Z. 144-145:
"cannot convert value of type '@Sendable ([(l: Float32, r: Float32)], [String], Set<String>,
[String: Double]) -> Float32' to specified type '([(l: Float32, r: Float32)], [String],
[String: Double]) -> Float32'"

Erklaerung: In Swift hat eine Funktion mit einem Default-Parameter dennoch einen anderen Typ
als eine ohne. Eine Funktionsreferenz (`WaveEnergyMath.soloNeutralLinear`) hat den vollen
4-Argumente-Typ. Die Zuweisung an die 3-Argumente-Typ-Variable schlaegt fehl. Der
Signatur-Test ist also sowohl fuer Variante a (ohne Default) als auch fuer Variante b
(mit Default) wirksam. Die anderen Testkallstellen kompilieren dagegen weiterhin, weil
Swift den Default-Wert automatisch einsetzt. Bewiesen: der Signatur-Test deckt den
Default-Parameter-Fall ab, die sonstigen Tests nicht.

---

## 3. Status G1 bis G5

| ID | Beschreibung | Status |
|----|--------------|--------|
| G1 | Fehlender Regressionsschutz fuer W2-Signatur | behoben |
| G2 | outputLimitNotice nicht synchronisiert | Luecke 1: NT2-D1 (kein Fix, bestaetigt); Luecke 2: behoben |
| G3 | Fehlender erklaereder Kommentar im Testkoerper | behoben |
| G4 | Dateiname-Diskrepanz README/Abschlussbericht | bereits in Durchlauf 1 geloest, unveraendert korrekt |
| G5 | Array-Allokation je Tick ohne Kommentar | Kommentar eingefuegt; neuer Befund H1 (falsche Zahl im Kommentar) |

---

## 4. Befunde nach Schweregrad

### Hoch

Keine.

### Mittel

#### H1: Falscher Zahlenwert im G5-Kommentar (mittel)

**Datei:** `v4/AudioRouterNow4/EngineController.swift`, Z. 767-769.

**Beschreibung:** Der eingefuegte Kommentar lautet:
"Bei 256 Slots sind das ~5120 Allokationen/s, auf einem Mac vernachlaessigbar."

Das ist numerisch falsch. `slotPeaks` wird einmal je Tick als Array angelegt:
1 Heap-Allokation pro Tick, 20 Ticks/s = 20 Allokationen/s, unabhaengig von der Slot-Zahl.
Die Zahl 5120 ist das Produkt 256 Slots x 20 Hz und entspricht der Anzahl der Elemente, die
pro Sekunde in das Array geschrieben werden (je ein `append` pro Slot pro Tick), nicht der
Anzahl der Heap-Allokationen. `reserveCapacity(slots)` belegt den Speicher einmalig fuer
den Tick; die 256 `append`-Aufrufe belegen keinen neuen Heap-Speicher.

Der Fehler liegt bereits im Plan (17-plan-nachtrag-v2.md, Abschnitt NT2-D5: "5120 Allokationen
pro Sekunde"), wurde von dort in das Umsetzungsprotokoll (18-impl-nachtrag-v2.md, NT2-S3) und
in den Produktivcode-Kommentar kopiert.

**Beleg:** Code Z. 765-775: `var slotPeaks: [(l: Float32, r: Float32)] = []` (eine Allokation),
`slotPeaks.reserveCapacity(slots)` (pre-alloziert den Puffer), dann 256 mal
`slotPeaks.append(raw)` (kein neuer Heap, da reserviert). Array wird nach dem Tick
freigegeben.

**Sicherheit:** bewiesen (Lektuer + Swift-Allokationsmodell).

**Schweregrad-Begruendung:** Falsche Behauptung in einem Code-Kommentar. Die Aussage "20
Allokationen/s" vs. "5120 Allokationen/s" aendert die Schlussfolgerung nicht (beide sind
vernachlaessigbar), aber ein kuenftiger Leser, der die Zahl bei einer Performance-Analyse
verwendet, wuerde Fehlentscheidungen treffen. Definition "mittel": falsche Behauptung in
Code-Kommentar.

**Korrekturvorschlag:** Z. 767-769 ersetzen durch:
```swift
// NT2-D5: slotPeaks wird je Tick einmal angelegt (MainActor, 20 Hz, kein IOProc).
// 1 Heap-Allokation/Tick (256 Elemente, ~2 KiB, kurzlebig), auf einem Mac vernachlaessigbar.
// Falls NM-4 einen messbaren Overhead zeigt: Instance-Variable + removeAll(keepingCapacity: true).
```

---

### Niedrig

#### H2: Doppelter Bindestrich " -- " im Testkommentar (niedrig, Stil)

**Datei:** `v4/AudioRouterKit/Tests/AudioRouterKitTests/WaveEnergyMathTests.swift`, Z. 29.

**Beschreibung:** Der eingefuegte Kommentar lautet:
"identisch -- die Regressionsgarantie liegt..."
Das " -- " ist kein Em-Dash oder En-Dash (verboten), sondern zwei ASCII-Bindestriche.
Es verstosst nicht gegen die explizite Schreibregel (kein Gedankenstrich, kein Em-Dash,
kein En-Dash). Es ist ein Stilpunkt ohne Auswirkung auf Funktion oder Verstaendnis.

**Sicherheit:** bewiesen (Diff-Lektuer).

**Schweregrad:** niedrig (Stil).

**Korrekturvorschlag:** "identisch, die Regressionsgarantie liegt..." oder Satz aufteilen.

---

#### H3: `warmRestartForSampleRateChange` loescht `outputLimitNotice` nicht (niedrig)

**Datei:** `v4/AudioRouterNow4/EngineController.swift`, Z. 859-887.

**Beschreibung:** `warmRestartForSampleRateChange` ist ein dritter Erfolgs-Routing-Pfad
(neben `performStart` und `restartRouting`). Er loescht `outputLimitNotice` nicht, obwohl
er beim Erfolg das Routing fortsetzt. Der Plan hat diesen Pfad bewusst ausgelassen:
NT2-D2 nennt nur `performStart` und `restartRouting` und begruendet, dass die
`addOutputConfig`-Sperre verhindert, dass die Meldung in einem aktiven Routing-Zustand
erneut gesetzt wird. Dennoch ist folgendes Szenario moeglich: Nutzer hat 255 Outputs,
versucht einen 256. hinzuzufuegen (Meldung erscheint, wird abgelehnt), danach aendert
sich die Sample-Rate eines Geraets und `warmRestartForSampleRateChange` laeuft erfolgreich.
Die Meldung bleibt sichtbar, obwohl Routing laeuft.

**Beleg:** `warmRestartForSampleRateChange` Z. 879-883: Erfolgsblock ohne
`outputLimitNotice = nil`.

**Sicherheit:** bewiesen (Lektuer).

**Schweregrad:** niedrig. Das Szenario ist eng (255 Outputs konfiguriert, SR-Wechsel), die
Meldung ist nicht falsch (es sind noch 255 Outputs konfiguriert), und NT2-D2 hat diesen
Pfad bewusst ausgenommen. Auswirkung: Meldung laeuft nach SR-Neustart weiter, was
unschoen ist, aber den Nutzer nicht in die Irre fuehrt.

**Korrekturvorschlag:** `outputLimitNotice = nil` nach Z. 883 im Erfolgsblock von
`warmRestartForSampleRateChange` einfuegen. Oder NT2-D2 explizit auf diesen Pfad
ausweiten.

---

## 5. Abdeckungstabelle

| Feld | Status | Anmerkung |
|------|--------|-----------|
| 1. G1 Signaturtest wirksam | OK | Mutationstest a und b beide bewiesen: Compilerfehler. Kommentar erklaerend. Produktivcode unveraendert. |
| 2. G2 outputLimitNotice | OK | Luecke 2 geloest: im Erfolgsblock von performStart (Z. 360) und restartRouting (Z. 439). Luecke 1: NT2-D1 bestaetigt (kein Fix, errorSection genuegt). Start-Fehler behaelt Meldung nicht (kein Setzen im Fehlerpfad geprueft). Rand: 254 Outputs, Start erfolgreich, Meldung geloescht (korrekt). |
| 3. G3 bis G5 | Teilergebnis | G3: Kommentar vorhanden, inhaltlich korrekt. G4: Dateiname-Link in README Z. 28 und 09-final-report.md Z. 378 korrekt. G5: Kommentar eingefuegt, aber H1 (falsche Zahl). |
| 4. Regression | OK | Tests gruen (60/96). Diff nur 5 Dateien + Doku. Keine neuen Dateien im App-Target. soloNeutralLinear Signatur und Implementierung unveraendert. FanOutEngine.swift ab makeDirectIOBlock unveraendert (Diff 23be274..HEAD leer). W1 und W2 erfuellt (kein grep-Treffer "maxSlots" als feste 16). |
| 5. Doku | OK | 18-impl-nachtrag-v2.md Hashes stimmen mit git log ueberein. 15-impl-nachtrag.md Nachtrag-Abschnitt ergaenzt. README-Eintraege 17 und 18 korrekt. 09-final-report.md Nachtrag-Abschnitt: noch nicht um Durchlauf-2-Stand erweitert (geplant erst nach Abschluss dieses Audits). Keine Em/En-Dashes in neuen Zeilen. Keine Namen oder E-Mails Dritter. |
| 6. Eigene Suche | Teilergebnis | H1 (Zahlenfehler im Kommentar, mittel). H2 (Doppelbindestrich, niedrig). H3 (warmRestartForSampleRateChange, niedrig). |

---

## 6. Nicht pruefbar ohne Hardware (NM-1 bis NM-7)

| ID | Thema |
|----|-------|
| NM-1 | Hoerpruefung: Lautstaerke, Solo und Pegel fuer Ausgaben ab Index 16 |
| NM-2 | Pegelanzeige ab der 17. Ausgabe |
| NM-3 | Welle unter Solo gleich hoch wie ohne Solo |
| NM-4 | CPU-Last bei 16 und 45+ Slots |
| NM-5 | Panel-Bedienbarkeit bei sehr vielen Zeilen |
| NM-6 | Meldung bei Ausgabenlimit (fixedSize-Layout sauber); und: nach erfolgreichem Start verschwindet die Meldung (NT2-D2) |
| NM-7 | Speicher bei 45+ aktiven Slots |

---

## 7. Urteil

**Nachtrags-Zyklus abgeschlossen: nein.**

Grund: Befund H1 (mittel) ist offen. Der Kommentar in
`EngineController.swift` Z. 768 behauptet "~5120 Allokationen/s"; korrekt sind 20
Allokationen/s (256 Elemente pro Tick). Ein dritter und letzter Durchlauf ist erforderlich.

Scope des dritten Durchlaufs: ausschliesslich H1 (1-Zeilen-Fix im Kommentar). H2 und H3
koennen im dritten Durchlauf mit behandelt werden, sind aber kein Pflichtbestandteil.

---

## 8. Anhang: Einzelpruefung nach Plan-Checkliste

### Checkliste G1 (aus 17-plan-nachtrag-v2.md, Abschnitt 7)

- [x] `testSoloNeutralLinearSignatureHasNoSoloedKeys` existiert (Z. 139-148).
- [x] Typ: `([(l: Float32, r: Float32)], [String], [String: Double]) -> Float32`. Bewiesen.
- [x] Test nicht tautologisch: prueft Signatur, nicht Laufzeitwert. `XCTAssertTrue(true)`
      ist Platzhalter (noetig wegen "never used"-Warnungsvermeidung), nicht die eigentliche
      Pruefung. Bewertung: Das `XCTAssertTrue(true)` ist schwach, aber sein Zweck ist
      klar kommentiert und es beeinflusst die Wirksamkeit des Tests nicht (der Typ-Check
      findet vor der Ausfuehrung statt). Kein Befund.
- [x] Mutation a (kein Default): kompiliert nicht. Bewiesen.
- [x] Mutation b (mit Default): kompiliert nicht. Bewiesen. Erklaerung: Swift-Funktionsreferenzen
      haben den vollen Typ einschliesslich aller Parameter, auch der mit Default-Werten.

### Checkliste G2 (aus 17-plan-nachtrag-v2.md, Abschnitt 7)

- [x] NT2-D1 bestaetigt: kein `outputLimitNotice`-Setzen im Fehlerpfad von `performStart`
      (Z. 363-365). `errorSection` zeigt `.tooManyOutputs`-Text. Geprueft.
- [x] `performStart` Erfolgsblock Z. 360: `outputLimitNotice = nil` vorhanden,
      nach `applySoloGains()`, vor `UserDefaults.set(wasRoutingKey)`.
- [x] `restartRouting` Erfolgsblock Z. 439: `outputLimitNotice = nil` vorhanden,
      nach `applySoloGains()`, vor `catch let e`.
- [x] `applyOutputsIfRouting`: unveraendert, kein `outputLimitNotice`. Bestaetigt (Diff leer).
- [x] Szenario 254 Outputs, Meldung sichtbar, Start erfolgreich: Meldung wird geloescht. Korrekt.
- [x] Szenario 255 Outputs, Start erfolgreich: Meldung wird geloescht. Korrekt per NT2-D2:
      Meldung zeigt "Remove an output to add another", nach Start mit valider Liste (255 < 256)
      ist Meldung ueberholt. Wenn Nutzer dann nochmals hinzufuegen will, erscheint sie wieder.
- [x] Start-Fehler: Meldung bleibt, falls sie vorher gesetzt war. `performStart` Fehlerpfad
      beruehrt `outputLimitNotice` nicht. Korrekt per NT2-D1.

### Checkliste G3

- [x] `testSoloDoesNotLowerTheWave` Z. 28-32: erklaereder Kommentar vorhanden.
- [x] Kommentar nennt: Absicht (kein soloedKeys-Argument), Regressionsgarantie liegt in
      der Signatur, Verweis auf `testSoloNeutralLinearSignatureHasNoSoloedKeys`. Vollstaendig.

### Checkliste G4

- [x] `docs/v4.1/README.md` Z. 28: Verweis auf `16-audit-nachtrag-v1.md`. Korrekt.
- [x] `docs/v4.1/09-final-report.md` Z. 378: Verweis auf `16-audit-nachtrag-v1.md`. Korrekt.

### Checkliste G5

- [x] Kommentar vorhanden: Z. 767-769 in `EngineController.swift`.
- [x] Kein Produktivcode-Fix. Bestaetigt.
- [!] Zahlenwert falsch: "5120 Allokationen/s" vs. korrekte "20 Allokationen/s". Befund H1.

### Checkliste Regression

- [x] `WaveEnergyMath.soloNeutralLinear`: Signatur und Implementierung unveraendert (Diff leer).
- [x] `SoloGain.swift`: keine Aenderung (Diff 23be274..HEAD leer).
- [x] `makeDirectIOBlock`: keine Aenderung (Diff 23be274..HEAD -- FanOutEngine.swift leer).
- [x] `addOutputConfig`, `removeOutputConfig`: unveraendert (Diff leer).
- [x] Keine neuen Dateien in `v4/AudioRouterNow4/`. Bestaetigt (Diff --name-only: 5 Dateien).
- [x] Keine Em-Dashes, En-Dashes, Gedankenstriche in neuen Zeilen. Bewiesen.
- [x] Keine Namen oder E-Mails Dritter. Bewiesen.
- [x] Kein Push, kein Tag. Branch-Stand unveraendert.
