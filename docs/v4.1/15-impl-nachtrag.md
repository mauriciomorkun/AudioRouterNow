# AudioRouterNow 4.1: Umsetzungsprotokoll Nachtrag (Slots und Welle)

Umsetzer: Fable 5, Durchlauf 1 von höchstens 3 des Nachtrags-Zyklus.
Plan: `docs/v4.1/14-plan-nachtrag.md` (Fassung 2, Commit `5dc55f5`). Branch `release/4.1`.
Der Lauf wurde einmal durch das Sitzungslimit unterbrochen und anhand des Repostands
fortgesetzt: NT-S1 bis NT-S8 waren committet, NT-S9 lag uncommittet im Arbeitsbaum und wurde
dabei gegen den Plan geprüft und korrigiert (siehe Abweichungen 1, 4 und 7).

Alles, was hier als geprüft steht, wurde in diesem Lauf ausgeführt. Alles unter "Offene
Messpunkte" wurde NICHT ausgeführt und ist NICHT verifiziert.

---

## Schritte

Testspalte: swift-testing / XCTest nach dem Schritt, jeweils alle grün. Der App-Build (Debug,
`CODE_SIGNING_ALLOWED=NO`) war nach jedem Code-Schritt BUILD SUCCEEDED.

| Schritt | Commit | swift-testing / XCTest | Neue Tests |
|---------|--------|------------------------|------------|
| NT-S0 Baseline | keiner | 59 / 56 | 0 |
| NT-S1 `RouterError.tooManyOutputs` | `49f1a2c` | 59 / 56 | 0 (Test in NT-S2) |
| NT-S2 `OutputLimits` | `d9533c3` | 59 / 64 | 8 XCTest |
| NT-S3 Kapazität der Brücken | `f4ce7ea` | 59 / 77 | 7 XCTest (`SlotGainsTests`), 6 XCTest (`PeakMetersTests`) |
| NT-S4 `FanOutEngine` | `86f8244` | 60 / 77 | 1 swift-testing (`startRejectsTooManyOutputs`) |
| NT-S5 `WaveEnergyMath` | `8e69e43` | 60 / 88 | 11 XCTest |
| NT-S6 `EngineController` | `d66d1c7` | 60 / 88 | 0 (Verdrahtung im App-Target) |
| NT-S7 Meldungszeile `MenuBarView` | `82dd4fd` | 60 / 88 | 0 (UI) |
| NT-S8 `SoloSlotRangeTests` | `b5a76cf` | 60 / 95 | 7 XCTest |
| NT-S9 Doku | `b4bf696` | 60 / 95 | 0 |
| Nacharbeit (Kommentare, ein Test) | `3a6d203` | 60 / 95 | 0 neu, 1 Test ersetzt |
| NT-S10 Abschluss, dieses Protokoll | `821e968` (und ein Nachtrag zum Preflight-Lauf 2) | 60 / 95 | 0 |

Alle Schritte haben den Status "erledigt". Der Inhalt entspricht dem Plan, Abweichungen stehen
im nächsten Abschnitt. Die Akzeptanzprüfungen des Plans, in diesem Lauf ausgeführt:

- **NT-S1:** Suche nach `case .tccDenied`, `.deviceNotFound`, `.aggregateLayoutMismatch` im
  App-Target ohne Treffer. Im Kit gibt es genau einen erschöpfenden `switch`
  (`errorDescription`, erweitert) und `if case` in Tests. Kein weiterer erschöpfender `switch`.
- **NT-S4:** `grep -n "SlotGains.maxSlots" FanOutEngine.swift` ohne Treffer. `grep -n
  "Unity-Gain\|ignoriert"` findet nur einen Kommentar zur Feedback-Schleife (Z. 357) und zwei
  Kommentare zum Teardown, keinen Warn-Text des alten stillen Verhaltens.
- **NT-S6:** `grep -n "SlotGains.maxSlots" EngineController.swift` ohne Treffer. `grep -rn
  "maxSlots" v4/AudioRouterNow4 v4/AudioRouterKit/Sources` liefert 15 Treffer, alle in
  `OutputLimits.swift`, `SlotGains.swift` und `PeakMeters.swift`, keiner im App-Target. Kein
  `where i < `, kein `idx >= ...maxSlots`, kein `maxSlots = 16` mehr in den Quellen.
- **NT-S7:** `MenuBarView` bekommt die bedingte Zeile und `limitNoticeSection`. Keine neue
  Datei, kein `GeometryReader`, kein `PreferenceKey`.
- **NT-S9:** `grep -n "Known limitation" CHANGELOG.md RELEASE_NOTES.md` ohne Treffer. Die
  neuen Texte enthalten keinen Gedankenstrich, Em-Dash oder En-Dash (per `grep -P` auf U+2013
  und U+2014 sowie dem Gedankenstrich mit Leerzeichen in den eigenen Diffs geprüft). Keine Namen.

---

## Abweichungen und Lücken

1. **ABWEICHUNG, Nummer des Nachtrag-Abschnitts im Abschlussbericht.** Der Plan nennt
   `## 9. Nachtrag: ...`. In `09-final-report.md` sind 9 und 10 belegt. Der Abschnitt heißt
   deshalb `## 11. Nachtrag: Slots und Welle (Stand 2026-11-14)` und ist am Ende angehängt.
   Das Dokumentenverzeichnis (Abschnitt 10) blieb unverändert, damit der bestehende Text nicht
   umgeschrieben wird. Die Dokumente 14 und 15 sind im neuen Abschnitt und in der `README.md`
   genannt. Eine erste, uncommittete Fassung hatte den Abschnitt als `## 9` eingefügt und die
   bestehende Verzeichnistabelle mit transliterierten Umlauten neu geschrieben. Beides wurde vor
   dem Commit verworfen, der Bericht kam aus HEAD zurück, der Abschnitt wurde sauber angehängt.
2. **ABWEICHUNG, Test `testQuieterSoloDeviceDoesNotChangeTheWave`.** Die erste Fassung enthielt
   eine Tautologie (`XCTAssertEqual(result, result)`). Ersetzt (`3a6d203`) durch den Vergleich
   mit dem Erwartungswert `0,8 * (1,0 + 0,2 + 1,0) / 3` und den Vergleich gegen den Wert der
   verworfenen Option 2 (`0,8 * 0,2 = 0,16`). Der Plantest `testSoloDoesNotLowerTheWave` ist
   strukturell tautologisch (die Funktion kennt Solo nicht), wie im Plan beschrieben und im
   Test dokumentiert. Seine Aussage liegt in der Signatur ohne `soloedKeys`, nicht im Wert.
3. **ABWEICHUNG, Plantest `testSetAllWithMoreThanCapacityIgnoresExcess`.** Der Plan nennt
   "Slot 255 trägt Wert 255". Der Test setzt Werte `i / 256` (Gains sind auf 0 bis 1 geklemmt)
   und prüft Slot 255 gegen `255 / 256`. Gleiche Absicht, anderer Zahlenwert.
4. **ABWEICHUNG, Kommentare.** In NT-S3, NT-S4 und NT-S6 hatte ich Kommentare ohne Umlaute
   geschrieben und dabei Originalkommentare in `EngineController` und `FanOutEngine` verändert.
   In `3a6d203` zurückgenommen: bestehende Kommentare stehen im Originalwortlaut, neue
   Kommentare haben korrekte Umlaute. Der Kommentar "W2: Anzeige-Pegel = IOProc-Peak ..." in
   `updateWaveEnergy` blieb erhalten, weil er für den Meter-Pfad weiter gilt (der Plan lässt
   nur den D1-Kommentar entfallen). Beim Nacharbeiten wurden versehentlich vier bestehende
   Testdateien per `sed` verändert und sofort per `git checkout` auf HEAD zurückgesetzt, sie
   sind nicht im Commit.
5. **LÜCKE, Zeilenangabe im Plan.** Der Plan nennt "Z. 752 bis 753" für den D1-Kommentar in
   `updateWaveEnergy`. Am Code stand er an anderer Stelle (Z. 768 bis 769 vor der Änderung).
   Entfernt wurde das Symbol, nicht die Zeile.
6. **LÜCKE, Namenskollision D2.** Der Plan verlangt in `05-decisions.md` den Eintrag "D2".
   `05-plan-v2.md` hat bereits ein D2 (Solo-Test). Der Eintrag trägt den Inhalt des Plans, einen
   Satz zur Abgrenzung beider Nummerierungen und den geforderten Vermerk "Interpretation to be
   confirmed by the user".
7. **ABWEICHUNG, README.** Die Tabelle in `docs/v4.1/README.md` war vor dem Eintrag zu 14 durch
   eine Leerzeile unterbrochen. Die Leerzeile ist entfernt, Eintrag 14 aktualisiert, Einträge 15
   und 16 ergänzt (16 mit Status "ausstehend").
8. **NICHT AUSGEFÜHRT, Plan NT-S9 g.** Die lokalen gitignorierten Dateien `BACKLOG.md` und
   `docs/support/` habe ich nicht nachgezogen (`docs/support/` ist leer). Die Hinweise des
   Plans (W1 erst nach bestandener Hörprüfung als erledigt führen, Folgepunkte
   Snapshot-Struktur bei auffälligem NM-4 und `LazyVStack` bei auffälligem NM-5) bleiben dem
   Hauptagenten.
9. **Test `startRejectsTooManyOutputs`.** Die Syntax `#expect(throws: RouterError...)` mit
   einem `Equatable`-Fehlerwert lief in der installierten swift-testing-Version ohne
   Anpassung. Der Test greift vor `createTap` und berührt kein CoreAudio.
10. **Kein Test auf `EngineController`.** Wie im Plan erwartet gibt es kein Test-Target für das
    App-Target. `addOutputConfig`, `removeOutputConfig`, `updateWaveEnergy` und
    `limitNoticeSection` sind nur per Lektüre und Build geprüft.
11. **`SoloSlotRangeTests` sind eine Nachbildung.** Der Dateikopf sagt ausdrücklich, dass nur das
    Zusammenspiel von `SoloGain.effective` und `SlotGains` geprüft wird, nicht
    `EngineController` oder `FanOutEngine`.

Keine Änderung an Entitlements, Signierung, `project.yml`, `.pbxproj`, Version und Build,
Consent-Mechanik, `VolumeTracker.swift`, `SoloGain.swift`, historischen Dokumenten 02 bis 13
(in `09-final-report.md` und `05-decisions.md` nur angehängt) und Marketing-Dateien. Keine neuen
Dateien in `v4/AudioRouterNow4/`. Kein Push, kein Tag, keine Einreichung.

### Echtzeitpfad

- `git diff 5dc55f5 HEAD` auf `FanOutEngine.swift` zeigt fünf Hunks, alle vor Zeile 700
  (`setOutputGain`, Kopf von `start`, Kopf von `buildAndStartAggregate`, ehemaliger Warn-Block,
  ein Kommentar). `makeDirectIOBlock` beginnt bei Zeile 891 und enthält keine Änderung. Rampe
  (`svStep`, `lastSV`), `slotAppliesVol`, `computeSlotAppliesVol`, `effectiveVolume`,
  `slotTargetSV` und `VolumeTracker.swift` sind unverändert.
- `grep -n "pthread_mutex\|NSLock\|DispatchSemaphore"` in `SlotGains.swift` und
  `PeakMeters.swift`: kein Treffer. `os_unfair_lock` bleibt das einzige Primitiv.
- `SlotGains.storage` und `PeakMeters.storage` werden weiter einmal in `init` alloziert. Nur die
  Kapazitätskonstante ist größer (256 mal 4 Byte und 256 mal 8 Byte).

---

## Gesamt-Teststand

| | swift-testing | XCTest | App-Build |
|--|---------------|--------|-----------|
| Vorher (NT-S0) | 59 in 10 Suiten | 56 | BUILD SUCCEEDED |
| Nachher (NT-S10) | 60 in 10 Suiten | 95 | BUILD SUCCEEDED |

Zuwachs: 1 swift-testing und 39 XCTest (8 `OutputLimitsTests`, 7 neue `SlotGainsTests`, 6
`PeakMetersTests`, 11 `WaveEnergyMathTests`, 7 `SoloSlotRangeTests`). Alle grün, 0 Fehler. Die
Zahlen stammen aus `v4/scripts/test.sh` ("Test run with 60 tests in 10 suites passed",
"Executed 95 tests, with 0 failures"). Neue Swift-Warnungen traten im App-Build nicht auf (der
gefilterte Build-Log zeigte keine `.swift`-Warnung). Die neuen Testdateien laufen nur über
`test.sh` (SPM), nicht über das Xcode-Test-Target, weil die `.pbxproj` nur drei Testdateien
führt (Bestand seit 4.1, nicht angefasst).

---

## Preflight (selbst ausgeführt, `bash v4/scripts/preflight.sh`)

Lauf 1, vor dem Commit dieses Protokolls: 1 ABBRUCH, 3 Warnungen.

- ABBRUCH: letztes Archiv ist 4.0.1 (10), erwartet war 4.1 (11). Unverändert gegenüber dem
  Stand vor dem Nachtrag, laut Plan erwartet.
- Warnung: `v4-appstore/` existiert noch (bekannt).
- Warnung: nicht committete Änderungen (zu diesem Zeitpunkt nur dieses noch untracked Protokoll).
- Warnung: Commits sind noch nicht gepusht (bekannt, Push nicht erlaubt).
- OK: xcconfig 4.1 (11), Tag `v4.1` existiert nicht, App Sandbox und Audio Input vorhanden.

Lauf 2, nach dem Commit `821e968` (Arbeitsbaum sauber): 1 ABBRUCH, 2 Warnungen. Der ABBRUCH
(Archiv 4.0.1 (10), erwartet 4.1 (11)) und die Warnungen zu `v4-appstore/` und zu nicht
gepushten Commits sind unverändert gegenüber dem Plan. Die Warnung zu uncommitteten Änderungen
ist verschwunden. Es gibt keine Abweichung vom erwarteten Ergebnis.

---

## Offene Messpunkte (alle OFFEN, NICHT VERIFIZIERT)

Kein Agent kann diese Messungen ausführen. Die Spalte "Ergebnis" bleibt leer.

| ID | Thema | Prüfanleitung | Erwartung | Ergebnis |
|----|-------|---------------|-----------|----------|
| NM-1 | Hörprüfung über 16 und 32 Ausgaben | Virtuelles Gerät mit 64 Kanälen (32 Paare) plus Interface (z. B. 10 Paare) plus Standardgerät, mindestens 45 Zeilen, Routing aktiv. Lautstärke einer Ausgabe ab der 17. und einer jenseits der 32. verstellen. Solo auf der 1. Ausgabe, dann auf der 17., dann auf einer jenseits der 32. | Jede Ausgabe reagiert auf Lautstärke, Solo schaltet alle anderen stumm, nach Aufheben gelten die gespeicherten Pegel | offen |
| NM-2 | Pegelanzeige ab der 17. Ausgabe | Wie NM-1, Karte der 17. und einer späteren Ausgabe aufklappen | Signal-Balken zeigen Pegel, unter fremdem Solo 0 | offen |
| NM-3 | Welle unter Solo | Mindestens drei Ausgaben, gleiches Material, Wellenhöhe ohne Solo ansehen, Solo setzen, wechseln, aufheben | Wellenhöhe bleibt gleich, nur die Karten-Meter ändern sich | offen |
| NM-4 | CPU-Last | Activity Monitor, CPU-Anteil von AudioRouterNow bei 16 und bei 45 oder mehr Slots über einige Minuten, wenn möglich bei kleinem IO-Buffer | Anstieg gering. Die Hochrechnung des Plans (etwa 1 Prozent des Callback-Budgets bei 256 Slots) ist synthetisch. Aussetzer oder Knacken melden | offen |
| NM-5 | Bedienung bei sehr vielen Zeilen | Panel öffnen, scrollen, Regler ziehen, Karten aufklappen bei 45 oder mehr Zeilen, falls möglich bei einem Gerät mit 128 oder 256 Kanälen | Panel bleibt bedienbar, kein Absturz (CASE-003 beachten) | offen |
| NM-6 | Meldung am Limit | Lokal `OutputLimits.maxSlots` temporär auf 20 senken (nicht committen), bauen, 19 Ausgaben wählen, eine weitere versuchen | Meldung erscheint, Ausgabe wird nicht hinzugefügt, Layout bleibt heil. Danach Konstante zurücksetzen | offen |
| NM-7 | Speicher | Activity Monitor, Speicher bei 45 oder mehr Slots | Zuwachs im Bereich einiger MiB (Rechnung: etwa 65 KiB je Slot) | offen |

Besonders ungeprüft: ob CoreAudio bei 128 bis 256 Kanalpaaren eines Geräts ein Aggregate stabil
aufbaut und taktet (NM-1, NM-5). Die CPU-Messwerte des Plans (14,1 ns je Lock, 117 µs je
Callback bei 256 Slots) hat der Planer synthetisch erhoben, ich habe sie nicht wiederholt.

---

## Restrisiken

Schritte mit Restrisiko:

- **NT-S3 (Echtzeit-nah):** `setAll` und `record` halten den Lock bei 256 statt 16 Einträgen
  länger (geschätzt 0,1 bis 0,3 µs, ungemessen). Der IOProc-Leser wartet im ungünstigsten Fall
  so lange. Der Poll im MainActor liest je Tick bis zu 256 Pegel mit je einem Lock, die
  Konkurrenz mit dem IOProc ist nicht gemessen (NM-4).
- **NT-S4:** `buildAndStartAggregate` prüft nach dem Teardown in `updateOutputs`. Bei einer zu
  langen gespeicherten Liste stoppt die Engine dort (Status `.idle`), der Controller zeigt den
  Fehler. Das ist im Plan so entschieden (keine Zustandsdivergenz). Die Sperre in
  `addOutputConfig` fängt den Fall in der Praxis vorher ab.
- **NT-S6:** Die Verdrahtung in `EngineController` ist nicht unit-testbar. Die Schleife in
  `updateWaveEnergy` legt je Tick ein Array mit `reserveCapacity(slots)` an (MainActor, 20 Hz,
  nicht im IOProc).
- **NT-S7:** Eine bedingte Zeile im `fixedSize(vertical:)`-Baum ändert die Panelhöhe, am Gerät
  ungeprüft (NM-6).
- **Gesamt:** `MenuBarView` und `DeviceCardView` bauen die Liste ohne Lazy-Container. Bei sehr
  vielen Zeilen ist die Bedienbarkeit ungemessen (NM-5, R5 des Plans). Die Auslegung von W2
  (NT-D4) und die Entscheidungen NT-D1, NT-D5, NT-D7 sind vom Nutzer noch zu bestätigen.

Hinweise für den Auditor zur Grenze 255 zu 256: `maxConfiguredOutputs = 255`, `maxSlots = 256`,
ein Slot bleibt für den synthetischen Default-Slot reserviert. `addDecision` lehnt ab dem
Zählerstand 255 ab (Duplikate zuerst). `validateOutputCount` wirft ab 256. Die Tests prüfen 255
und 256 sowie Index 255 (gültig) und 256 (ungültig) in `SlotGains` und `PeakMeters`. Per Lektüre
zu prüfen bleibt, dass `slots.count <= Konfigurationen + 1` auch im Exklusiv-Modus und bei der
Deduplizierung über `addedConfigKeys` gilt (Plan, Abschnitt 2.2).

---

## Nachtrag Durchlauf 2 (NT2-S0 bis NT2-S4)

Umsetzer: Fable 5, Durchlauf 2 von hoechstens 3 des Nachtrags-Zyklus.
Plan: `docs/v4.1/17-plan-nachtrag-v2.md` (Commit `23be274`). Ausgefuehrt: 2026-11-15.
Vollstaendiges Protokoll in `docs/v4.1/18-impl-nachtrag-v2.md`.

### Schritte

| Schritt | Commit | swift-testing / XCTest | App-Build | Neue Tests |
|---------|--------|------------------------|-----------|------------|
| NT2-S0 Baseline | keiner | 60 / 95 | BUILD SUCCEEDED | 0 |
| NT2-S1 G1+G3 Signaturtest+Kommentar | `5835733` | 60 / 96 | BUILD SUCCEEDED | 1 XCTest |
| NT2-S2 G2 outputLimitNotice bei Erfolg | `dc32d9b` | 60 / 96 | BUILD SUCCEEDED | 0 |
| NT2-S3 G5 Kommentar slotPeaks-Allokation | `2ff74a5` | 60 / 96 | BUILD SUCCEEDED | 0 |
| NT2-S4 Doku-Update | `97f687c` | 60 / 96 | n/a | 0 |

### Entscheidungen

- NT2-D1: G2 Luecke 1 kein Fix (akzeptierter Zustand, `errorSection` mit erklaerndem Text genuegt).
- NT2-D2: G2 Luecke 2 Fix: `outputLimitNotice = nil` in `performStart` und `restartRouting` Erfolgsblock.
- NT2-D3: G1 Regressionsschutz durch Signatur-Test (Compiler-Pruefung) und Kommentar.
- NT2-D4: G4 bereits geloest, kein Eingriff.
- NT2-D5: G5 nur Kommentar, kein Produktivcode-Fix.

### Abweichungen

Keine. Alle Schritte plankonform ausgefuehrt.

### Gesamt-Teststand nach Durchlauf 2

| | swift-testing | XCTest | App-Build |
|--|---------------|--------|-----------|
| Eingang (NT2-S0 = NT-S10) | 60 in 10 Suiten | 95 | BUILD SUCCEEDED |
| Nachher (NT2-S3) | 60 in 10 Suiten | 96 | BUILD SUCCEEDED |

Zuwachs: 1 XCTest (`testSoloNeutralLinearSignatureHasNoSoloedKeys` in `WaveEnergyMathTests`).
Alle gruen, 0 Fehler.

### Offene Messpunkte

Unveraendert NM-1 bis NM-7 (s.o.), alle OFFEN, NICHT VERIFIZIERT.
NT2-D2 eroeffnet neuen Messpunkt NM-6 (Meldung nach erfolgreichem Start verschwindet),
bereits in der NM-6-Zeile oben eingetragen.
