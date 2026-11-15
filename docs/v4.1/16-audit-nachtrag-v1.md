# AudioRouterNow 4.1: Audit Nachtrag, Durchlauf 1

Auditor: Fable 5, unabhaengig. Datum: 2026-11-15.
Plan: `docs/v4.1/14-plan-nachtrag.md` (Fassung 2, Commit `5dc55f5`).
Umsetzung: Commits `49f1a2c` bis `634d922` (12 Commits).
Protokoll: `docs/v4.1/15-impl-nachtrag.md`.

Stand: abgeschlossen.

---

## 1. Zusammenfassung

Testlauf, Build und Preflight erfolgreich (Details Abschnitt 2). W1 (Slots ueber 16 ohne Nachteil) ist im Code und in den Tests vollstaendig umgesetzt. W2 (Welle unter Solo nicht kleiner) ist im Code korrekt implementiert; der Leittest `testSoloDoesNotLowerTheWave` ist planmaessig strukturell tautologisch, sein Wert liegt in der Signatur. Verbotsliste nicht verletzt. Kein Befund hoch. Zwei Befunde mittel (G1, G2). Drei Befunde niedrig (G3, G4, G5).

---

## 2. Testlauf, Build und Preflight

Alle Befehle auf Branch `release/4.1`, Commit `634d922`.

### test.sh

```
bash /Users/mauriciomorkun/AudioRouterNow/v4/scripts/test.sh
```

Ergebnis: 60 swift-testing in 10 Suiten, 95 XCTest -- alle gruen, 0 Fehler.
Zuwachs gegenueber Baseline (59/56): +1 swift-testing, +39 XCTest. Erwartet.

### App-Build

```
cd /Users/mauriciomorkun/AudioRouterNow/v4 && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AudioRouterNow4.xcodeproj -scheme AudioRouterNow4 \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Ergebnis: BUILD SUCCEEDED. Keine Swift-Warnungen (selbst geprueft).

### preflight.sh

```
bash /Users/mauriciomorkun/AudioRouterNow/v4/scripts/preflight.sh
```

Ergebnis: 1 ABBRUCH (letztes Archiv ist 4.0.1 (10), erwartet 4.1 (11)), 2 Warnungen
(v4-appstore/ vorhanden, Commits nicht gepusht). Entspricht der Planerwartung.

---

## 3. Status W1 und W2

### W1: Nutzer mit mehr als 16 Ausgaben haben keinen Nachteil

**Erfuellt (am Code geprueft, Hardware-Verifikation offen).**

Belege:
- `OutputLimits.maxSlots = 256`, `maxConfiguredOutputs = 255`. `SlotGains.maxSlots`
  und `PeakMeters.maxSlots` verweisen auf dieselbe Quelle.
- Der Zweig `if idx >= SlotGains.maxSlots { ... return }` in `setOutputGain` und der
  Warn-Block in `buildAndStartAggregate` (beide `FanOutEngine.swift`) sind entfernt.
  `grep -n "SlotGains.maxSlots" FanOutEngine.swift`: kein Treffer (selbst geprueft).
- `updateWaveEnergy` iteriert ueber alle Slots ohne `where`-Schranke.
- `start` und `buildAndStartAggregate` prufen mit `OutputLimits.validateOutputCount`
  vor dem ersten CoreAudio-Aufruf.
- `addOutputConfig` blockiert bei >= 255 konfigurierten Ausgaben und setzt
  `outputLimitNotice`.
- `removeOutputConfig` setzt `outputLimitNotice = nil`.
- Tests decken Indices 15, 16, 17, 31, 32, 33, 100, 255 und die Grenze 256 ab.
- Hardware-Messung (NM-1 bis NM-4) steht aus.

### W2: Die Welle wird unter Solo nie kleiner

**Erfuellt (am Code geprueft, Hardware-Verifikation offen).**

Belege:
- `WaveEnergyMath.soloNeutralLinear` hat keinen `soloedKeys`-Parameter.
  Rechenprobe (Lektuer): 3 Slots, Peak 0.5, kein Gain. Summe = 3 x 0.5 = 1.5,
  geteilt durch 3 = 0.5. Unter Solo: exakt dieselbe Eingabe, exakt dasselbe Ergebnis.
  Solo-Geraet mit Gain 0.2, andere 1.0: (0.2 + 1.0 + 1.0) x 0.5 / 3 = 0.367, identisch
  mit und ohne Solo (da Solo `deviceGains` nie schreibt).
- `updateWaveEnergy` uebergibt `deviceGains`, nicht `soloedKeys`.
- Meter-Pfad (`newPeaks`) behaelt `SoloGain.effective` (B1 erhalten).
- `testQuieterSoloDeviceDoesNotChangeTheWave` prueft den Erwartungswert
  `0.8 * (1.0 + 0.2 + 1.0) / 3` und ist nicht tautologisch (selbst geprueft).
- `testSoloDoesNotLowerTheWave` ist planmaessig strukturell tautologisch (zwei
  identische Aufrufe) -- Schwaeche dokumentiert (G4).
- Hardware-Messung (NM-3) steht aus.

---

## 4. Befunde nach Schweregrad

### Hoch

Keine.

### Mittel

#### G1: `testSoloDoesNotLowerTheWave` -- kein echter Regressionsschutz fuer W2 (mittel)

**Datei:** `v4/AudioRouterKit/Tests/AudioRouterKitTests/WaveEnergyMathTests.swift`, Z. 20-31.

**Beschreibung:** Der Test ruft `soloNeutralLinear` zweimal mit identischen Eingaben auf und
behauptet `withoutSolo == withSolo`. Er wuerde bestehen, auch wenn die Funktion konstant 0
oder konstant 1 zurueckgaebe. Der einzige Regressionsschutz fuer W2 (Solo aendert die
Welle nicht) liegt in der Signatur der Funktion (kein `soloedKeys`-Parameter), nicht in
einem Testwert. Wenn jemand spaaeter einen `soloedKeys`-Parameter einfuehrt und die Funktion
konserviert, schlaegt kein Test an.

**Beleg:** Zitat aus dem Test (Z. 27-30):
```swift
let withoutSolo = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: gains)
let withSolo    = WaveEnergyMath.soloNeutralLinear(slotPeaks: peaks, keys: keys, deviceGains: gains)
XCTAssertEqual(withoutSolo, withSolo, accuracy: 0.0001)
```

**Sicherheit:** bewiesen (Lektuer + Testlauf).

**Schweregrad-Begruendung:** Der Plan beschreibt den Test ausdruecklich als strukturell tautologisch
(14-plan-nachtrag.md, NT-S5) und das Protokoll bestaetigt (15-impl-nachtrag.md, Abweichung 2).
Die Schwaeche liegt also im bewusst akzeptierten Zustand. Sie ist mittel, weil kein anderer Test
direkt prueft: "wenn `soloedKeys` uebergeben wuerde, waere das Ergebnis anders". Das vorhandene
`testMaskedSumWouldHaveShrunkTheWave` prueft, dass die ALTE Formel schlechter war, nicht dass die
neue Solo-Neutralitaet in Zukunft erhalten bleibt. Es waere ein Regressionsschutz gegen das
Wiedereinfuehren der alten Formel, aber nicht gegen das stille Einfuehren von `soloedKeys`.

**Korrekturvorschlag:** Einen zusaetzlichen Test schreiben, der `soloNeutralLinear` mit zwei
verschiedenen Eingaben prueft: einmal mit `deviceGains` enthaltend alle Keys mit Gain 1.0
("kein Solo"), einmal mit einem Key mit Gain 0.0 (Simulation des Effekts, wenn `soloedKeys`
in die Funktion sickerte). Der Test sollte zeigen, dass das Ergebnis mit Gain 0.0 kleiner ist
als mit Gain 1.0 -- das wuerde rot, wenn `soloedKeys` in die Funktion gebaut und Solo dann doch
den Divisor beeinflussen wuerde. Alternativ genuegt ein Kommentar, der diesen Sachverhalt
explizit als "nur Signatur-Garantie, kein Wert-Test" kennzeichnet. Der Plan nennt diesen
Sachverhalt bereits; der Test selbst hat keinen erlaeuternden Kommentar ausserhalb von Z. 20-23.

---

#### G2: `outputLimitNotice` nicht synchronisiert mit Start-Fehlerpfad und erfolgreichem Start (mittel)

**Datei:** `v4/AudioRouterNow4/EngineController.swift`, Z. 345-368 (`performStart`),
Z. 422-443 (`restartRouting`).

**Beschreibung:** Zwei Luecken:

1. Wenn `startRouting()` fehlschlaegt, weil eine aus der Persistenz geladene Liste mehr als
   255 Ausgaben enthaelt, setzt `performStart` den Status auf `.error(RouterError.tooManyOutputs(...))`
   (Z. 362-363). `MenuBarView` zeigt den Fehlertext in `errorSection` an (rotes Symbol).
   `outputLimitNotice` wird NICHT gesetzt. Inkonsistenz: bei einer interaktiven Ablehnung via
   `addOutputConfig` erscheint die orangefarbene Meldung; beim Neustart mit denselben Daten
   erscheint nur ein roter Fehler ohne erklaerende Meldung in der Meldungszeile.

2. `performStart` loescht `outputLimitNotice` bei Erfolg nicht (Z. 349-359). Wenn ein Nutzer
   die Warn-Meldung sieht (addOutputConfig abgelehnt), dann ohne Entfernen Start drueckt (bei
   <= 255 Ausgaben erfolgreich), bleibt die orangefarbene Meldung nach dem erfolgreichen Start
   sichtbar, obwohl das Routing laeuft.

**Beleg:** `outputLimitNotice` wird nur in `addOutputConfig` gesetzt (Z. 551) und in
`removeOutputConfig`/`addOutputConfig(.allowed)` geloescht (Z. 554, 564). `performStart` und
`restartRouting` beruehren `outputLimitNotice` nicht (Lektuer geprueft).

**Sicherheit:** bewiesen (Lektuer).

**Schweregrad-Begruendung:** Luecke 1: fuer einen Start mit persistierten Daten ist der Fehlertext
in `errorSection` korrekt und vollstaendig; das Routing startet nicht. Luecke 2: eine veraltete
Meldung bleibt nach erfolgreichem Start sichtbar, was den Nutzenden verwirrt. Beide Luecken sind
im Plan nicht beschrieben und sind daher nicht bewusst entschieden.

**Korrekturvorschlag (Luecke 1):** Im `catch let e as RouterError`-Block von `performStart`:
```swift
if case .tooManyOutputs(_, let max) = e {
    outputLimitNotice = OutputLimits.limitMessage(max: max)
}
```
**Korrekturvorschlag (Luecke 2):** In `performStart` nach erfolgreichem Start (nach `startPolling`):
```swift
outputLimitNotice = nil
```

---

### Niedrig

#### G3: `testSoloDoesNotLowerTheWave` -- fehlender erklaerder Kommentar im Testkoerper (niedrig)

**Datei:** `WaveEnergyMathTests.swift`, Z. 20-31.

**Beschreibung:** Der Kommentar im Testkopf erklaert das Muster. Im Testkoerper (Z. 27-30) fehlt
jedoch ein Hinweis, dass die zwei identischen Aufrufe kein Versehen sind. Ein Leser ohne
Kontext koennte annehmen, dass hier ein Copy-Paste-Fehler vorliegt. Das ist eine Wartbarkeits-
und Lesbarkeitsluecke, kein funktionaler Fehler.

**Sicherheit:** bewiesen.

**Korrekturvorschlag:** Einen Kommentar direkt vor `let withSolo = ...` einfuegen:
```swift
// Absicht: die Funktion hat kein soloedKeys-Argument. Beide Aufrufe sind
// identisch -- die Aussage liegt in der Signatur, nicht im Vergleichswert.
```

---

#### G4: `docs/v4.1/09-final-report.md` -- Verweis auf `16-audit-nachtrag.md` statt `16-audit-nachtrag-v1.md` (niedrig)

**Datei:** `docs/v4.1/09-final-report.md`, Z. 378 (vor der Korrektur durch diesen Audit).

**Beschreibung:** Der Abschlussbericht verwies auf `16-audit-nachtrag.md`. Der Plan und die
Aufgabenstellung nennen `16-audit-nachtrag-v1.md` (mit Versionssuffix). Der README-Eintrag
(durch die Umsetzung ebenfalls auf den falschen Namen) wurde im Zuge dieses Audits auf
`16-audit-nachtrag-v1.md` korrigiert. Der Abschlussbericht und die README wurden in diesem
Lauf aktualisiert (nicht Teil des Produktivcode-Nachtrags, nur Doku-Konsistenz).

**Sicherheit:** bewiesen (Lektuer, korrigiert im Rahmen dieses Audits).

**Status:** behoben (Korrekturen in `docs/v4.1/09-final-report.md` und `docs/v4.1/README.md` im selben Commit wie dieser Bericht).

---

#### G5: `updateWaveEnergy` -- je Tick eine Array-Allokation auf dem MainActor (niedrig, kein RT-Pfad)

**Datei:** `v4/AudioRouterNow4/EngineController.swift`, Z. 761-762.

**Beschreibung:** `slotPeaks` wird je Tick (20 Hz) mit `reserveCapacity(slots)` neu angelegt.
Das ist kein Echtzeit-Pfad (MainActor-Poll), aber bei 256 Slots und 20 Hz entstehen 5120
Allokationen pro Sekunde. Bei kleiner Slotzahl ist der Unterschied vernachlaessigbar. Das
Protokoll erwaehnt diesen Sachverhalt (Restrisiken, NT-S6). Der Plan (NT-D6) begruendet die
index-gleichen Arrays damit, dass "der 20-fps-Poll keine zusaetzliche Dictionary-Allokation
je Tick bekommt". Eine Array-Allokation pro Tick ist verbleibendes Rauschen und kein Fehler.

**Sicherheit:** bewiesen (Lektuer).

**Korrekturvorschlag:** Optional: `slotPeaks` als instance-Variable in `EngineController` halten
und bei jedem Tick nur `removeAll(keepingCapacity: true)` aufrufen. Ist kein dringender Fix.

---

## 5. Abdeckungstabelle

| Feld | Status | Anmerkung |
|------|--------|-----------|
| A. Plan-Treue | OK | 11 Schritte nachvollzogen. Abweichungen 1-11 im Protokoll begruendet und nicht planwidrig. Verbotsliste: keine Verletzung festgestellt. |
| B. W1 vollstaendig | OK | Keine weitere feste 16er-Grenze im Produktivcode. Pfade fuer Index >= 16: Lautstaerke, Solo, Pegel und Wellen-Schleife korrekt. lastSV dynamisch (slots.count). Keine festen Arrays/Tupel ueber Slots. |
| C. Grenze 255/256 | OK | addDecision sperrt bei >= 255. validateOutputCount wirft bei > 255. orderedSlotConfigs haengt hoechstens einen Default-Slot an. slots.count <= configs + 1 <= 256. Guards in SlotGains.set/gain und PeakMeters.level/record verhindern Out-of-bounds. |
| D. Sichtbares Verhalten | Teilergebnis | Meldung korrekt bei addOutputConfig (G2: beim Start-Fehler fehlt Synchronisation). errorSection zeigt tooManyOutputs. Text korrekt. removeOutputConfig loescht Meldung. |
| E. W2 korrekt | OK | Formel prueft Lektuer (Rechenprobe in Abschnitt 3). Kein soloedKeys-Pfad. Meter behalten SoloGain.effective. G1 (Test-Schwaeche). |
| F. Echtzeit/Nebenl. | OK | makeDirectIOBlock unveraendert (git diff geprueft). Keine neuen Alloks/Locks/Logging im IOProc. os_unfair_lock bleibt einzig. OutputLimits und WaveEnergyMath ohne globalen Zustand, Sendable. 14,1 ns/Lock-Schätzung nachvollziehbar (synthetisch, als solche gekennzeichnet). |
| G. Regression | OK | CASE-004/007-Symbole unveraendert (git diff). SoloGainTests gruen. VolumeScalingTests gruen. B1-B5 und F1-F4 per Lektuer und Diff geprueft. |
| H. Doku | Teilergebnis | CHANGELOG und RELEASE_NOTES: Known-limitation entfernt, Fixed-Eintraege korrekt und belegt. Keine Em/En-Dashes in neuen Zeilen. ARCHITECTURE.md korrekt (512 Werte, OutputLimits-Quelle). 09-final-report.md Nachtrag-Abschnitt angehaengt (als ## 11, nicht ## 9: begruendete Abweichung). 05-decisions.md D2 korrekt ergaenzt, Namenskollision explizit behandelt. README.md: Dateiname-Diskrepanz (G4). Zahlen und Hashes stimmen mit git log ueberein. |
| I. Zweig-Konsistenz | OK | Conventional Commits. kein --no-verify. Arbeitsbaum sauber. kein Push, kein Tag v4.1. Version nur in xcconfig. |
| J. Eigene Suche | Siehe G2, G5 | Meldungs-Synchronisation beim Start-Fehler (G2). Array-Allokation im Poll (G5). Kein weiterer Befund. |

---

## 6. Nicht pruefbar ohne Hardware (NM-1 bis NM-7)

Alle sieben offenen Messpunkte koennen nur am Geraet durchgefuehrt werden:

| ID | Thema |
|----|-------|
| NM-1 | Hoerpruefung: Lautstaerke, Solo und Pegel fuer Ausgaben ab Index 16 |
| NM-2 | Pegelanzeige ab der 17. Ausgabe |
| NM-3 | Welle unter Solo gleich hoch wie ohne Solo |
| NM-4 | CPU-Last bei 16 und 45+ Slots (Lock-Messschatzung ist synthetisch) |
| NM-5 | Panel-Bedienbarkeit bei sehr vielen Zeilen (R5, non-lazy VStack) |
| NM-6 | Meldung bei Ausgabenlimit (fixedSize-Layout sauber) |
| NM-7 | Speicher bei 45+ aktiven Slots |

---

## 7. Urteil

**Neuer Durchlauf noetig: ja.**

Grund: Befund G1 (mittel) und G2 (mittel) sind offen. G2 ist ein Verhaltensfehler:
bei Neustart mit einer zu langen persistierten Liste erscheint kein `outputLimitNotice`,
waehrend dieselbe Situation via `addOutputConfig` orangefarbene Meldung haette. Der Fehler
hat Nutzerwirkung (inkonsistentes Feedback, Nutzer kann Zustand nicht korrigieren ohne
roten Fehlertext zu verstehen). G1 ist eine Testluecke, kein Produktivcode-Fehler.

---

## 8. Anhang: RT-Pruefpunkte (RT1-RT6)

| ID | Ergebnis |
|----|----------|
| RT1 | makeDirectIOBlock unveraendert: git diff 5dc55f5..HEAD -- v4/AudioRouterKit/Sources/AudioRouterKit/FanOutEngine.swift zeigt 5 Hunks, alle vor Z. 700; makeDirectIOBlock beginnt Z. 891. Bewiesen. |
| RT2 | Keine neuen Allocs/Logger/Locks im IOProc. grep ohne Treffer. Bewiesen. |
| RT3 | storage wird in init einmal alloziert, kein Zeigerauswechsel. Bewiesen. |
| RT4 | lastSV hat slots.count Groesse, vor AudioDeviceStart angelegt. Bewiesen. |
| RT5 | updateWaveEnergy laeuft im MainActor-Poll (wavePollTask). Bewiesen. |
| RT6 | 14,1 ns/Lock, 117 us bei 256 Slots: synthetisch, so gekennzeichnet. Plausibel. |
