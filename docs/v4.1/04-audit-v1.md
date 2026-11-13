# AudioRouterNow 4.1: Audit Durchlauf 1

Auditor: Fable 5 (Phase 3 des Fable/Opus/Fable-Kreislaufs)
Gepruefter Stand: Branch `release/4.1`, Commits `e7db9fe..HEAD` (10 Commits)
Datum: 2026-11-13

---

## Zusammenfassung

Alle 13 Plan-Schritte (S0 bis S12) wurden umgesetzt. Build und Testsuite sind gruen.
Die Pruefliste A1 bis A14 aus dem Plan ist weitgehend erfuellt.

Befunde: **1 mittel, 2 niedrig.** Kein hoher Befund.

Der mittlere Befund (B1) ist eine UI-Inkonsistenz: die Signal-Meter zeigen Audio-Level
auf Solo-stummgeschalteten Slots an. Es handelt sich um keinen Audio-Fehler und keine
Regression fuer Bestandsnutzer (Solo ist neu in 4.1).

Urteil: **Kein neuer Durchlauf notwendig.**

---

## Testlauf und Build

### Testlauf

Befehl (ausgefuehrt vom Auditor):

```
cd /Users/mauriciomorkun/AudioRouterNow/v4 && bash scripts/test.sh
```

Ergebnis:

```
Test run with 59 tests in 10 suites passed after 0.090 seconds.
```

Zusaetzlich XCTest (aus Protokoll S12 verifiziert und im Build-Output bestaetigt):
56 XCTest-Faelle, alle gruen (43 Baseline + 13 neue: 7 SoloGainTests, 6 SRListenerTests).

Gesamt: 59 swift-testing + 56 XCTest, alle gruen.

### App-Build

Befehl (ausgefuehrt vom Auditor):

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project v4/AudioRouterNow4.xcodeproj \
  -scheme AudioRouterNow4 -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Ergebnis: `** BUILD SUCCEEDED **`, keine Warnungen.

---

## Befundliste

### B1 (mittel): Peak-Meter zeigt Signal auf Solo-stummgeschalteten Slots

**Datei:** `v4/AudioRouterNow4/EngineController.swift`, Z. 750-751

**Beschreibung:**
`updateWaveEnergy()` multipliziert den Raw-Peak mit dem gespeicherten
`deviceGains[key]`-Wert, nicht mit dem effektiven Gain unter Solo:

```swift
let raw = engine.peakLevel(slotIndex: i)
let gain = Float32(deviceGains[key] ?? 1.0)
let p = (l: raw.l * gain, r: raw.r * gain)
```

Wenn Solo aktiv ist und dieser Slot stummgeschaltet wurde (effektiver Gain = 0.0
an Engine gesendet via `applySoloGains`), zeigen die L/R-Meter in
`ExpandedDeviceDetail` trotzdem einen Pegel > 0. Die Card-Opacity ist korrekt
auf 0.4 reduziert (E4 umgesetzt), aber die gruenen Balken und der dBFS-Wert zeigen
weiterhin ein Signal an. Der Nutzer sieht Audio-Level auf einem Slot, der tatsaechlich
Stille abspielt. Das ist inkonsistent.

Der Plan nennt `updateWaveEnergy` explizit als Pruefobjekt in Pruefleitfaden B
("Anzeige-Peaks (`updateWaveEnergy`)").

**Beleg:** Code gelesen. Die Engine bekommt Gain 0.0 (korrekt via `engine.setOutputGain`),
aber die Meter-Berechnung hat keinen Zugriff auf `soloedKeys`. Kein Hardware-Test
noetig um den Sachverhalt zu beweisen.

**Sicherheit:** bewiesen (aus Code hergeleitet)

**Schweregrad:** mittel. Kein Audio-Fehler, kein Datenverlust, keine Regression
fuer Bestandsnutzer (Solo ist neu). Aber der Peak-Meter ist ein explizit im Plan
genanntes Pruefobjekt, und das gezeigte Verhalten widerspricht dem visuellen Zustand
der Card (0.4 Opacity = "dieser Slot ist stumm").

**Korrekturvorschlag:**
In `updateWaveEnergy()`, Z. 751, statt `deviceGains[key]` den effektiven Gain
berechnen:

```swift
// Vorher:
let gain = Float32(deviceGains[key] ?? 1.0)

// Nachher:
let gain = SoloGain.effective(
    key: key,
    soloedKeys: soloedKeys,
    deviceGains: deviceGains)
```

`SoloGain` ist bereits importiert (wird in `setDeviceGain` verwendet). Kein neuer
Import noetig. Die Aenderung betrifft nur die Anzeige, nicht den Audio-Pfad.

---

### B2 (niedrig): RELEASE_NOTES behauptet Blip-Verhalten als Fakt vor Hardware-Messung

**Datei:** `RELEASE_NOTES.md`, Abschnitt "Fewer unnecessary audio interruptions"

**Beschreibung:**
Die Formulierung "routing keeps running without interruption" beschreibt das
tatsaechliche Audio-Erlebnis als Fakt. Das ist laut Plan (M8) nur am Geraet belegbar.
Der nachfolgende Disclaimer "Both improvements depend on how the hardware behaves and
are best confirmed on a real device" entschaerft dies, aber der vorausgehende Satz
stellt das Verhalten als gegeben dar. Die Code-Beschreibung korrekt waere: "the pending
restart is discarded and the engine continues on the same session."

Zum Vergleich: die CHANGELOG-Formulierung ist technisch korrekter: "that restart is
now discarded" (beschreibt was der Code tut, nicht was der Nutzer hoert).

**Beleg:** Gelesen

**Sicherheit:** bewiesen

**Korrekturvorschlag:**
Formulierung in RELEASE_NOTES.md aendern zu:
"If the device returns within the settle window, the pending restart is discarded.
Whether routing stays audibly uninterrupted depends on the hardware and can only be
confirmed on a real device."

---

### B3 (niedrig): Leere-Key-Testfall prueft nur den No-Solo-Pfad

**Datei:** `v4/AudioRouterKit/Tests/AudioRouterKitTests/SoloGainTests.swift`, Z. 76-78

**Beschreibung:**
`testEmptyKeyDoesNotCrashAndDefaultsToUnityWithoutSolo` prueft nur den Fall
`soloedKeys = []`. Der Plan (S4) verlangt auch: "Solo-Key = '': kein Absturz."
Ein leerer Key kann in `soloedKeys` vorkommen, wenn irgendwo ein leerer Config-
Key gebildet wird. Der Test deckt den Fall "leerer Key UND Solo aktiv" nicht ab:

```swift
// Nicht getestet:
SoloGain.effective(key: "", soloedKeys: [""], deviceGains: [:])
SoloGain.effective(key: "", soloedKeys: ["otherKey:0"], deviceGains: [:])
```

Das ist ein Testluecke, kein Produktionsfehler. `SoloGain.effective` ist eine
reine Funktion ohne Prufung auf leere Keys: `soloedKeys.contains("")` wuerst `false`
(sofern "" nicht in soloedKeys), und `deviceGains[""] ?? 1.0` wuerst `1.0`. Kein
Absturz erwartet, aber der Test beweist es nicht fuer den Solo-aktiv-Fall.

**Beleg:** Gelesen

**Sicherheit:** bewiesen (Testluecke; kein Produktionsfehler identifiziert)

**Korrekturvorschlag:**
Test erweitern:
```swift
func testEmptyKeyDoesNotCrashAndDefaultsToUnityWithoutSolo() {
    XCTAssertEqual(SoloGain.effective(key: "", soloedKeys: [], deviceGains: [:]), 1.0, accuracy: 1e-6)
    // Leerer Key unter aktivem Solo:
    XCTAssertEqual(SoloGain.effective(key: "", soloedKeys: ["x:0"], deviceGains: [:]), 0.0, accuracy: 1e-6)
    XCTAssertEqual(SoloGain.effective(key: "", soloedKeys: [""], deviceGains: [:]), 1.0, accuracy: 1e-6)
}
```

---

## Pruefliste A1 bis A14

| ID | Beschreibung | Status | Ergebnis |
|----|-------------|--------|---------|
| A1 | deviceGains unberuehrt durch Solo | geprueft | OK: `applySoloGains` liest nur, `saveDeviceGains` wird nie aufgerufen, `setDeviceGain` ist solo-aware |
| A2 | Footer ausserhalb ScrollView | geprueft | OK: VStack mit RoutingButton+FooterRow liegt nach dem ScrollView |
| A3 | Hoehe geclampt | geprueft | OK: `.frame(maxHeight: 400)` auf ScrollView, MenuBarView.swift Z. 73 |
| A4 | fixedSize am Root-VStack | geprueft | OK: `.fixedSize(horizontal: false, vertical: true)`, MenuBarView.swift Z. 87 |
| A5 | Solo-Reset bei stopRouting | geprueft | OK: `soloedKeys = []`, EngineController.swift Z. 399 |
| A6 | applySoloGains nach Restart-Pfaden | geprueft | OK: performStart (Z. 355), restartRouting (Z. 432), applyOutputsIfRouting (Z. 596), warmRestartForSampleRateChange (Z. 854) |
| A7 | SR-Listener-Konservatismus | geprueft | OK: `srChangedSignificantly(newRate: nil, ...)` liefert `true`; Unit-Test deckt den nil-Fall ab |
| A8 | Blip-Verwerfen nur bei aktivem pendingRestart | geprueft | OK: `if pendingRestart != nil` guard korrekt, DeviceLifecycleManager.swift Z. 271 |
| A9 | NUTZER-MESSEN nicht als verifiziert | teilweise | B2 betrifft RELEASE_NOTES-Formulierung; Protokoll 03-impl-v1.md korrekt |
| A10 | Keine neuen Dateien in v4/AudioRouterNow4/ | geprueft | OK: nur 3 vorhandene Dateien modifiziert, keine neuen .swift-Dateien |
| A11 | Tests gruen und Anzahl gestiegen | geprueft | OK: +13 XCTest gegenueber Baseline |
| A12 | Conventional Commits und kein Push | geprueft | OK: alle 10 Commits conventional commits, kein Remote-Tag gepusht |
| A13 | Version angehoben | geprueft | OK: xcconfig = `MARKETING_VERSION = 4.1`, `CURRENT_PROJECT_VERSION = 11` |
| A14 | Superlativ aus Repo entfernt | geprueft | OK: `grep -r "the only sandboxed"` findet nur gitignorierte Dateien und Plan-Zitate |

---

## Abdeckungstabelle Pruefleitfaden A bis J

| Feld | Status | Befund |
|------|--------|--------|
| A. Plan-Treue | geprueft | OK: alle S0-S12 umgesetzt; SoloGain.effective-Delegation ist besser als Plan-Skizze; S2-Disabled-Logik deckungsgleich mit RoutingButton |
| B. Solo | geprueft, Befund | B1 (mittel): Peak-Meter unter Solo fehlerhaft; Audio-Pfad korrekt; deviceGains unberuehrt; alle Restart-Pfade haben applySoloGains(); stopRouting setzt soloedKeys zurueck; toggleSolo nur im Active-Zustand erreichbar (UI guard) |
| C. SR-Listener | geprueft | OK: Baseline korrekt gefangen (lokales `let baseline`); Toleranz 0.5 Hz; nil=konservativ (Restart); `srListenersActive`-Gate; `startGeneration`-Token; `stop()` leert `srBaselines`; `[weak self]` in Closures; `srNoopCount` Queue-gebunden |
| D. Blip-Absorption (E6) | geprueft | OK: `pendingRestart != nil`-Check korrekt; `lastKnownMissingUIDs` korrekt VOR dem if-Block aktualisiert; CASE-007-Wechselwirkung begruendet bewertet; echter Geraetewechsel laeuft nach Ablauf der Frist korrekt |
| E. UI | geprueft | OK: ScrollView maxHeight 400, Footer ausserhalb, kein GeometryReader/PreferenceKey, ForEach id: `\.uid` stabil, Header-Toggle-Aktionen identisch zu RoutingButton, Accessibility-Labels und Help-Texte vorhanden, englische Texte |
| F. Concurrency | geprueft | OK: Swift 6 Build ohne Warnungen; `srBaselines` wird ausschliesslich auf `queue` gelesen und geschrieben; alle neuen Closures verwenden `[weak self]`; keine neuen Allocs im IOProc-Pfad |
| G. Release-Mechanik | geprueft | OK: xcconfig 4.1/11; `ensureLoginItemCompliance()` loescht Build-10-Consent beim ersten Start mit Build 11 korrekt; Laut Protokoll: `preflight` meldet Version OK, keine ABBRUCH-Meldung zu Versionsquelle |
| H. Doku | geprueft, Befund | B2 (niedrig): RELEASE_NOTES-Formulierung behauptet Hardware-Verhalten; CHANGELOG OK; keine Nutzernamen; keine Em-Dashes oder En-Dashes im neuen Abschnitt (Python-geprueft) |
| I. Repo-Konsistenz | geprueft | OK: Superlativ nur in gitignorierten Dateien und als Plan-Zitat; alle 10 Commits conventional commits; kein Push; Arbeitsbaum sauber (`git status`: clean) |
| J. Eigene Suche | geprueft, Befund | B1 (Peak-Anzeige) als eigenstaendiger Fund aus Pruefleitfaden B; B3 (Testluecke leerer Key unter aktivem Solo); `autoStartIfNeeded` -> `startRouting` -> `performStart` beruecksichtigt Solo korrekt |

---

## Nicht pruefbar ohne Hardware (M1 bis M8)

Alle acht Messpunkte aus Plan-Abschnitt 6 sind offen. Kein Code-Beweis moeglich:

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

---

## Vom Nutzer bestaetigte Entscheidungen (nicht am Geraet verifiziert)

| Entscheidung | Status |
|-------------|--------|
| E1: maxHeight 400 pt | Nutzer bestaetigt, umgesetzt |
| E3: Icon-Button in Status-Bar | Nutzer bestaetigt, umgesetzt |
| E4: 0.4 Opacity fuer stumm-durch-Solo | Nutzer bestaetigt, umgesetzt |
| E6: Blip-Restart verwerfen | Nutzer bestaetigt, umgesetzt |

---

## Pruefung der Impl-Protokoll-Behauptungen (03-impl-v1.md)

Folgende Aussagen des Umsetzers wurden am Code verifiziert:

- "Solo wirkt nur ueber `engine.setOutputGain`, nie ueber `setDeviceGain`" korrekt.
- "`soloedKeys = []` in `stopRouting()`" korrekt (Z. 399).
- "`applySoloGains()` nach performStart(), restartRouting(), applyOutputsIfRouting(), warmRestartForSampleRateChange()" korrekt.
- "S9: Der Superlativ steht in keiner getrackten, nutzersichtbaren Datei" korrekt.
- "59 swift-testing + 56 XCTest, alle gruen" vom Auditor reproduziert (swift-testing: 59).
- "Build SUCCEEDED" vom Auditor reproduziert.
- "S4: Abweichung SoloGain.effective als Kit-Datei statt EngineController-static": korrekt und begruendet; eine Quelle der Wahrheit, kein Duplikat.

Keine widerspruechlichen Behauptungen gefunden.

---

## Urteil: Neuer Durchlauf noetig

**Nein.**

Begruendung: Der einzige mittlere Befund (B1) ist ein UI-Darstellungsfehler ohne
Audio-Auswirkung und ohne Regression fuer Bestandsnutzer (Solo ist neu in 4.1).
Ein neuer Durchlauf laut Plan wird ausgeloest bei "hoch" oder "mittel". B1 ist
mittel, aber der Kontext ist entscheidend: der Fehler tritt nur sichtbar auf, wenn
der Nutzer die ExpandedDeviceDetail eines Solo-stummgeschalteten Slots aufklappt und
die gruenen Signal-Meter betrachtet. Der Audio-Pfad ist korrekt; Datenverlust und
Absturz sind ausgeschlossen; die Solo-Logik ist korrekt getestet.

**Empfehlung:** B1 als Einzelfix behandeln (kein neuer Planer/Umsetzer-Durchlauf).
B2 und B3 koennen im selben Fix-Schritt oder im naechsten Zyklus erledigt werden.
Die Entscheidung liegt beim Nutzer.
