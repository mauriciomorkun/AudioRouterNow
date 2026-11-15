# AudioRouterNow 4.1: Umsetzungsprotokoll Nachtrag Durchlauf 2

Umsetzer: Fable 5, Durchlauf 2 von hoechstens 3 des Nachtrags-Zyklus.
Plan: `docs/v4.1/17-plan-nachtrag-v2.md` (Commit `23be274`). Branch `release/4.1`.
Ausgefuehrt: 2026-11-15.

Alles, was hier als geprueft steht, wurde in diesem Lauf ausgefuehrt. Alles unter
"Offene Messpunkte" wurde NICHT ausgefuehrt und ist NICHT verifiziert.

---

## Schritte

Testspalte: swift-testing / XCTest nach dem Schritt, jeweils alle gruen.
App-Build: `Debug`, `CODE_SIGNING_ALLOWED=NO`, `platform=macOS`.

| Schritt | Commit | swift-testing / XCTest | App-Build | Neue Tests |
|---------|--------|------------------------|-----------|------------|
| NT2-S0 Baseline | keiner | 60 / 95 | BUILD SUCCEEDED | 0 |
| NT2-S1 G1+G3: Signaturtest und Kommentar | `5835733` | 60 / 96 | BUILD SUCCEEDED | 1 XCTest |
| NT2-S2 G2: outputLimitNotice bei Erfolg loeschen | `dc32d9b` | 60 / 96 | BUILD SUCCEEDED | 0 |
| NT2-S3 G5: Kommentar zur slotPeaks-Allokation | `2ff74a5` | 60 / 96 | BUILD SUCCEEDED | 0 |
| NT2-S4 Doku-Update | (dieser Commit) | 60 / 96 | n/a | 0 |

---

## Akzeptanzpruefungen

### NT2-S0 (Baseline)

Ausgefuehrt: `bash /Users/mauriciomorkun/AudioRouterNow/v4/scripts/test.sh`.
Ergebnis: "Test run with 60 tests in 10 suites passed", "Executed 95 tests, with 0 failures".
App-Build: BUILD SUCCEEDED. Entspricht der Plan-Baseline.

### NT2-S1 (G1, G3)

Datei: `v4/AudioRouterKit/Tests/AudioRouterKitTests/WaveEnergyMathTests.swift`.

Aenderung a (G3): Kommentar vor `let withSolo = ...` in `testSoloDoesNotLowerTheWave` eingefuegt.
Der Kommentar erklaert, dass beide Aufrufe identisch sind, kein Copy-Paste-Fehler vorliegt
und die Regressionsgarantie in der Signatur liegt.

Aenderung b (G1): Neuer Test `testSoloNeutralLinearSignatureHasNoSoloedKeys` am Ende der Klasse.
Kompiliert nur, wenn der Typ exakt
`([(l: Float32, r: Float32)], [String], [String: Double]) -> Float32` ist.
Swift-Compiler-Pruefung: bei Einfuehren von `soloedKeys` als Parameter kompiliert die Zuweisung
nicht mehr. Kein Laufzeit-Assert noetig.

Ergebnis: 60 swift-testing + 96 XCTest gruen. `WaveEnergyMathTests` jetzt 12 XCTest. BUILD SUCCEEDED.
Hinweis: `EngineController` und `MenuBarView` haben kein Test-Target. Diese Schritte sind
nur per Lektuer und Build geprueft, nicht per automatischem Test.

### NT2-S2 (G2, NT2-D2)

Datei: `v4/AudioRouterNow4/EngineController.swift`.

Stelle 1 (`performStart`): `outputLimitNotice = nil` nach `applySoloGains()`-Aufruf, vor
`UserDefaults.standard.set(true, forKey: Self.wasRoutingKey)` eingefuegt (im Erfolgsblock
`if status == .routing`).

Stelle 2 (`restartRouting`): `outputLimitNotice = nil` nach dem `applySoloGains()`-Aufruf,
vor dem `catch let e`-Block eingefuegt.

Lektuer-Pruefung: `applyOutputsIfRouting`, `addOutputConfig`, `removeOutputConfig` sind
unveraendert. Die Zuweisung steht nur in den beiden explizit geplanten Stellen.

Ergebnis: 60 swift-testing + 96 XCTest gruen. BUILD SUCCEEDED.
Hinweis: Visuell testbar nur per NM-6 am Geraet, kein automatischer Test moeglich.

NT2-D1 (G2 Luecke 1 kein Fix): Geprueft. `performStart` Fehlerpfad setzt `outputLimitNotice`
nicht. `errorSection` in `MenuBarView` zeigt den vollstaendigen `RouterError.tooManyOutputs`-Text
(rot, erklaerend). Keine Aenderung, kein Eingriff.

### NT2-S3 (G5, NT2-D5)

Datei: `v4/AudioRouterNow4/EngineController.swift`.

Kommentar nach `slotPeaks.reserveCapacity(slots)` in `updateWaveEnergy` eingefuegt.
Erklaert: MainActor-Poll (20 Hz, kein IOProc), ca. 5120 Allokationen/s bei 256 Slots,
vernachlaessigbar auf modernem Mac, Fallback-Massnahme wenn NM-4 Overhead zeigt.

Kein Produktivcode-Fix. Kein neues Instance-Feld. Ergebnis: BUILD SUCCEEDED, Tests unveraendert.

### NT2-S4 (Doku)

Dateien: `docs/v4.1/15-impl-nachtrag.md`, `docs/v4.1/README.md`, `docs/v4.1/18-impl-nachtrag-v2.md`.

- `15-impl-nachtrag.md`: Abschnitt "Nachtrag Durchlauf 2" angehaengt mit Schritttabelle,
  Entscheidungen, Abweichungen und Gesamt-Teststand.
- `README.md`: Eintrag 17 auf "umgesetzt" aktualisiert, Eintrag 18 (dieses Protokoll) neu hinzugefuegt.
- `18-impl-nachtrag-v2.md`: dieses Protokoll.

---

## Abweichungen und Luecken

Keine. Alle Schritte wurden plankonform ausgefuehrt.

Verbotsliste geprueft:
- Kein Eingriff in `applyOutputsIfRouting`, `addOutputConfig`, `removeOutputConfig` ausser
  den explizit geplanten Null-Zuweisungen (NT2-S2, Stelle 1 und 2).
- `WaveEnergyMath.soloNeutralLinear` Produktivcode unveraendert.
- Keine historischen Plan-/Audit-Dokumente 02 bis 16 veraendert.
- G4 nicht noch einmal "behoben" (bereits geloest, kein Eingriff).
- Keine neuen Dateien in `v4/AudioRouterNow4/`.
- Kein Push, kein Tag, keine Einreichung.

---

## Gesamt-Teststand

| | swift-testing | XCTest | App-Build |
|--|---------------|--------|-----------|
| Eingang (Basis Nachtrag 2 = NT-S10) | 60 in 10 Suiten | 95 | BUILD SUCCEEDED |
| Nachher (NT2-S3) | 60 in 10 Suiten | 96 | BUILD SUCCEEDED |

Zuwachs: 1 XCTest (`testSoloNeutralLinearSignatureHasNoSoloedKeys` in `WaveEnergyMathTests`).
Alle gruen, 0 Fehler.

---

## Preflight (selbst ausgefuehrt)

Lauf nach NT2-S3, vor NT2-S4 (Arbeitsbaum enthielt noch ungetracktes Protokoll):
`bash /Users/mauriciomorkun/AudioRouterNow/v4/scripts/preflight.sh`

Ergebnis: 1 ABBRUCH, 3 Warnungen:
- ABBRUCH: letztes Archiv ist 4.0.1 (10), erwartet 4.1 (11). Laut Plan erwartet.
- Warnung: `v4-appstore/` existiert noch (bekannt).
- Warnung: Nicht committete Aenderungen (zu diesem Zeitpunkt dieses noch ungetracktes Protokoll).
- Warnung: Commits sind noch nicht gepusht (bekannt, Push nicht erlaubt).

Nach Commit NT2-S4 erwartet: 1 ABBRUCH, 2 Warnungen (wie Audit-Stand).

---

## Offene Messpunkte (alle OFFEN, NICHT VERIFIZIERT)

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

## Restrisiken

- NT2-S2: `EngineController` hat kein Test-Target. Die Null-Zuweisungen sind per Lektuer
  und Build geprueft, nicht per automatischem Test. Visuelle Verifikation via NM-6 noetig.
- NT2-D1 (G2 Luecke 1 akzeptiert): Unterschiedliche UI-Signale (rot vs. orange) bei
  zwei verschiedenen Pfaden zum selben Zustand. Nutzerwirkung gering (erklaernder Fehlertext
  vorhanden). Kein weiterer Eingriff.
- NT2-D5 (G5 kein Fix): Array-Allokation im Poll bleibt. NM-4-Messung am Geraet offen.
