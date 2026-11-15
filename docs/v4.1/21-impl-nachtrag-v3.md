# AudioRouterNow 4.1: Umsetzungsprotokoll Nachtrag, Durchlauf 3

Umsetzer: Fable 5 (Plan und Umsetzung in einem Agenten, Unabhaengigkeit durch den folgenden Audit). Datum: 2026-11-15.
Plan: `docs/v4.1/20-plan-nachtrag-v3.md` (Erstfassung `2ae52d9`, korrigiert in `2960723`).
Basis-Audit: `docs/v4.1/19-audit-nachtrag-v2.md` (Commit `77f0d1f`), HEAD bei Beginn: `77f0d1f`.

Stand: abgeschlossen, Audit Durchlauf 3 steht aus.

---

## 1. Schritte

| Schritt | Inhalt | Commit | Status |
|---------|--------|--------|--------|
| N3-S0 | Mini-Plan `20-plan-nachtrag-v3.md`, README | `2ae52d9` | erledigt |
| N3-S1 | H1: Kommentar in `updateWaveEnergy` korrigiert | `e2bcc93`, angeglichen in `63b4d04` | erledigt |
| N3-S2 | H2: " -- " im Testkommentar durch Komma ersetzt | `b9faad8` | erledigt |
| N3-S3 | H3: Entscheidung am Code geprueft, kein Code | Plan-Korrektur `2960723` | erledigt (akzeptiert) |
| N3-S4 | Protokoll 21, Abschlussbericht, README | siehe Abschnitt 5 | erledigt |

### N3-S1: H1

Befund: Der Kommentar in `v4/AudioRouterNow4/EngineController.swift` (`updateWaveEnergy`, bei
`slotPeaks`) nannte "~5120 Allokationen/s". `slotPeaks` wird je Tick einmal angelegt
(`reserveCapacity(slots)`), das sind 20 Allokationen pro Sekunde bei 20 Hz, unabhaengig von der
Slot-Zahl. 5120 ist 20 Hz x 256 Slots und zaehlt Element-Schreibzugriffe, keine Allokationen.

Aenderung: nur der Kommentar, kein Code. Der Kommentar nennt jetzt "20 Allokationen pro
Sekunde" und "5120 Element-Schreibzugriffe pro Sekunde (20 Hz x 256, keine Allokationen)".

Abweichung: In `e2bcc93` stand zunaechst der kuerzere Vorschlag des Audits ("1 Heap-Allokation/Tick
(256 Elemente, ~2 KiB ...)"). Er war nicht falsch (256 Elemente zu je 8 Byte sind 2 KiB), nannte aber
die 5120 Schreibzugriffe nicht und wich vom verbindlichen Wortlaut des Auftrags ab. Nach dem
Hinweis des Hauptagenten in `63b4d04` angeglichen. Build und Tests liefen nach beiden Commits.

### N3-S2: H2

Befund: `v4/AudioRouterKit/Tests/AudioRouterKitTests/WaveEnergyMathTests.swift` Z. 29, Kommentar
"identisch -- die Regressionsgarantie". Aenderung: " -- " durch ", " ersetzt, nur der Kommentar.

### N3-S3: H3, Entscheidung NT3-D3 (akzeptiert, kein Code)

Geprueft am Code (`EngineController.swift`):

- `warmRestartForSampleRateChange` setzt `outputLimitNotice` im Erfolgsblock nicht zurueck
  (`grep -n outputLimitNotice`: Zuweisungen nur in `performStart`, `restartRouting`,
  `addOutputConfig` und `removeOutputConfig`).
- Die Meldung (`OutputLimits.limitMessage`) lautet "Output limit reached: AudioRouterNow can route to
  255 outputs at once. Remove an output to add another." Sie ist nicht an den Routing-Zustand
  gebunden und bleibt auch ohne Warm-Restart stehen, bis der Nutzer eine Ausgabe hinzufuegt oder
  entfernt oder Routing startet bzw. neu startet.
- Ein SR-Warmrestart aendert `outputConfigs` nicht. Mit 255 konfigurierten Ausgaben stimmt die
  Aussage der Meldung danach unveraendert. Er erzeugt keinen neuen veralteten Zustand. Ein Fall, in
  dem sie falsch oder irrefuehrend wird, ist am Code nicht belegbar.

Entscheidung: als akzeptierter Rest dokumentieren, kein Code. Ein Fix (`outputLimitNotice = nil`
im Erfolgsblock) waere trivial, aendert aber Verhalten ohne belegten Nutzen.

Korrektur an der eigenen Arbeit: Die Erstfassung des Plans (`2ae52d9`) und ein erster Entwurf dieses
Protokolls begruendeten NT3-D3 mit einer Sperre in `addOutputConfig` waehrend aktiven Routings. Diese
Sperre gibt es nicht: `addOutputConfig` ruft im Fall `.allowed` `applyOutputsIfRouting()` auf, eine
Ablehnung gibt es nur beim Erreichen des Limits (`.limitReached`). Die Begruendung wurde in `2960723`
im Plan ersetzt. Die Entscheidung selbst bleibt, sie traegt ohne diese Annahme.

### Suche nach weiteren Fehlern in neuen Kommentaren

Ausgefuehrt: `git diff 5dc55f5..HEAD -- v4/ | grep "^+" | grep "//"`, gesamte Ausgabe gelesen.

Am Code oder per Rechnung geprueft, ohne Beanstandung:

- Konstanten: `OutputLimits.maxSlots = 256`, `maxConfiguredOutputs = maxSlots - 1` (255).
- Test `PeakMetersTests`: "Slots 3 bis 199 wurden genullt" passt zu `slotCount: 200` und dann `3`.
- Test `SoloSlotRangeTests`: Slots 0, 15, 16, 17, 119 und "Slots 60 bis 255 sind 1.0" passen zu den
  Schleifen im Test (Zeilen 44 bis 45, 121 bis 129).
- `WaveEnergyMathTests`: 0.6/3 = 0.2, (0.6+0+0.6)/3 = 0.4, (0.6+0.4)/2 = 0.5, 0.8 x 0.2 / 1 = 0.16,
  1.0/100 = 0.01.
- H1-Kommentar: 20 Hz x 256 = 5120, 256 x 8 Byte = 2 KiB.

Nicht einzeln nachgerechnet wurden Kommentare ohne Zahlen- oder Zustandsaussage (Kopfzeilen,
Strukturkommentare). Kein weiterer belegter Fehler, keine weitere Korrektur.

### Akzeptanzpruefungen (selbst ausgefuehrt)

- `grep -c "5120 Allokationen"` in `EngineController.swift`: 0 Treffer.
- "20 Allokationen pro Sekunde" und "5120 Element-Schreibzugriffe": Treffer in Z. 768.
- `grep -c " -- "` in `WaveEnergyMathTests.swift`: 0 Treffer.
- Em-Dash oder En-Dash in neuen Zeilen unter `v4/` seit `5dc55f5`: 0 Treffer.

---

## 2. Teststand und Build (selbst ausgefuehrt)

Nach dem letzten Code-Commit `63b4d04`:

| Pruefung | Ergebnis |
|----------|----------|
| `v4/scripts/test.sh` | 60 swift-testing in 10 Suiten, 96 XCTest, 0 Fehler |
| App-Build (Debug, `CODE_SIGNING_ALLOWED=NO`) | BUILD SUCCEEDED |

`EngineController` hat kein Test-Target. Die Aenderung dort ist ein Kommentar und per Lektuere und
Build geprueft.

## 3. Preflight (selbst ausgefuehrt)

`bash v4/scripts/preflight.sh`: 1 ABBRUCH (letztes Archiv ist 4.0.1 (10), erwartet 4.1 (11)),
Warnungen: `v4-appstore/` vorhanden, Commits nicht gepusht. Beim Lauf vor dem Commit dieses
Protokolls kam eine dritte Warnung (nicht committete Aenderungen) wegen dieser noch ungetrackten
Datei hinzu. Das entspricht der Planerwartung.

## 4. Offene Messpunkte

Unveraendert gegenueber Durchlauf 2. Keine Messung wurde von einem Agenten durchgefuehrt.

| ID | Thema |
|----|-------|
| NM-1 | Hoerpruefung: Lautstaerke, Solo und Pegel fuer Ausgaben ab Index 16 |
| NM-2 | Pegelanzeige ab der 17. Ausgabe |
| NM-3 | Welle unter Solo gleich hoch wie ohne Solo |
| NM-4 | CPU-Last bei 16 und 45+ Slots (hier auch die Schreib- und Allokationslast von `slotPeaks`) |
| NM-5 | Panel-Bedienbarkeit bei sehr vielen Zeilen |
| NM-6 | Meldung bei Ausgabenlimit (fixedSize-Layout sauber); nach erfolgreichem Start verschwindet die Meldung (NT2-D2) |
| NM-7 | Speicher bei 45+ aktiven Slots |

## 5. Commits dieses Durchlaufs

| Commit | Inhalt |
|--------|--------|
| `2ae52d9` | N3-S0: Mini-Plan und README |
| `e2bcc93` | N3-S1: H1, erste Fassung des Kommentars |
| `b9faad8` | N3-S2: H2 |
| `63b4d04` | N3-S1: H1, Kommentar auf verbindlichen Wortlaut angeglichen |
| `2960723` | Plan-Korrektur (NT3-D1 Wortlaut, NT3-D3 Begruendung) |
| siehe `git log` | N3-S4: Protokoll 21, Abschlussbericht, README (`docs(v4.1)`) |

## 6. Hinweise fuer den letzten Audit

- Der Hash des N3-S4-Commits steht bewusst nicht in diesem Dokument (er entsteht erst mit dem
  Commit), er ist per `git log -1` auffindbar.
- Pruefen, ob NT3-D3 (H3 akzeptiert) ueberzeugt: Begruendung in Abschnitt 1, N3-S3.
- Die Korrektur der Plan-Begruendung ist Teil der Historie (`2ae52d9` gegen `2960723`).
