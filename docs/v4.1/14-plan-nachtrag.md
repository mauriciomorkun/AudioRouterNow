# AudioRouterNow 4.1: Nachtragsplan (Slots und Welle), Fassung 2

Erstellt: 2026-11-14 (Planer: Fable 5, Nachtrags-Zyklus nach dem 3-Durchlauf-Kreislauf).
Fassung 2 ersetzt Fassung 1 (Commit `4c7dbfe`). Anlass: Fassung 1 hob `maxSlots` nur
von 16 auf 32 an und ließ darüber ein stilles Degradieren stehen (Log-Warnung, Unity-Gain).
Das widerspricht W1. Fassung 2 setzt die Kapazität so hoch, dass der reale Auslöser
(Geräteliste mit 45 und mehr Einträgen) klar darunter liegt, belegt die Kosten mit einer
Messung, listet alle festen Größen im Code auf und macht das Verhalten oberhalb der
Kapazität sichtbar statt still.

Basis: `docs/v4.1/09-final-report.md` (Commit `b237cf0`), vollständige Lektüre von
`SlotGains.swift`, `PeakMeters.swift`, `SoloGain.swift`, `FanOutEngine.swift` (Gain-,
Slot-, Seed-, Peak-Pfade, IOProc), `EngineController.swift`, `MenuBarView.swift`,
`DeviceCardView.swift`, `AudioRouterKit.swift` (`RouterError`), `SlotGainsTests.swift`,
`SoloGainTests.swift`, `VolumeScalingTests.swift`, `05-plan-v2.md` (D1), `10-plan-v3.md`,
`feedback/CASE-004_*.md` und `CASE-007_*.md`.

Status: Final, bereit zur Ausführung durch einen Fable-Agenten.

---

## 1. Kopf

### 1.1 Ziel

**W1 (Nutzerwunsch, verbindlich):** Nutzer, die mehr als 16 Slots nutzen, sollen keinen
Nachteil haben. Lautstärke pro Gerät, Solo, Pegelanzeige und Wellen-Energie sollen für
alle tatsächlich ansteuerbaren Ausgaben gleich funktionieren. Kein stilles Degradieren.
Heute gilt für Slot-Index 16 und höher: fester Unity-Gain (`FanOutEngine.setOutputGain`
ignoriert den Aufruf, `FanOutEngine.swift` Z. 196 bis 199), Solo kann den Slot nicht
stumm schalten, `PeakMeters.level` liefert (0, 0), die Schleife in
`EngineController.updateWaveEnergy` (Z. 746, `where i < SlotGains.maxSlots`) lässt den
Slot aus.

**W2 (Nutzerwunsch, verbindlich):** Die Welle soll visuell nie kleiner werden. Auslegung
siehe NT-D4 (zu bestätigen): Solo darf die Wellenhöhe gegenüber dem Zustand ohne Solo bei
gleichem Audiomaterial nicht verringern.

### 1.2 Scope-Freeze (verbindlich)

**Enthalten:** nur W1 und W2 plus die dazugehörige Doku.

Code:
- Neue Kit-Dateien `OutputLimits.swift` und `WaveEnergyMath.swift` (Sources) sowie
  `OutputLimitsTests.swift`, `PeakMetersTests.swift`, `WaveEnergyMathTests.swift`,
  `SoloSlotRangeTests.swift` (Tests). Neue Dateien im SPM-Package sind unkritisch.
- `AudioRouterKit.swift` (neuer Fall `RouterError.tooManyOutputs` plus Beschreibung).
- `SlotGains.swift`, `PeakMeters.swift` (Kapazität aus einer Quelle).
- `FanOutEngine.swift` (nur: Prüfung der Slotzahl in `start` und `buildAndStartAggregate`,
  Entfernen der beiden 16er-Zweige in `setOutputGain` und im Warn-Block).
- `EngineController.swift` (`addOutputConfig`, `removeOutputConfig`, neue
  `@Published`-Eigenschaft für die Meldung, Schleife und Berechnung in
  `updateWaveEnergy`).
- `MenuBarView.swift` (eine bedingte Meldungszeile, KEINE neue Datei).
- Bestehende Tests: `SlotGainsTests.swift` erweitern, `AudioRouterKitTests.swift`
  (swift-testing) um einen Fall erweitern.

Doku: `CHANGELOG.md`, `RELEASE_NOTES.md`, `v4/ARCHITECTURE.md` (zwei Stellen),
`docs/v4.1/09-final-report.md` (Nachtrag-Abschnitt), `docs/v4.1/05-decisions.md`
(neuer Eintrag), `docs/v4.1/README.md`.

**Ausdrücklich ausgeschlossen:** siehe Verbotsliste (Abschnitt 4).

### 1.3 Branch

`release/4.1`, Startpunkt der Umsetzung: Commit dieser Fassung 2 (davor `4c7dbfe`, `b237cf0`).

### 1.4 Baseline (vom Planer in diesem Lauf selbst ausgeführt)

| Prüfung | Ergebnis |
|---------|----------|
| `bash v4/scripts/test.sh` | 59 swift-testing in 10 Suiten und 56 XCTest, alle grün |
| App-Build (Debug, `CODE_SIGNING_ALLOWED=NO`) | BUILD SUCCEEDED |

App-Build-Befehl:

```
cd ~/AudioRouterNow/v4 && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AudioRouterNow4.xcodeproj \
  -scheme AudioRouterNow4 -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Test-Befehl (liefert beide Zähler, XCTest und swift-testing):

```
bash ~/AudioRouterNow/v4/scripts/test.sh
```

Hinweis zur Testlage (am Code geprüft): In `v4/AudioRouterNow4.xcodeproj/project.pbxproj`
sind nur drei Testdateien eingetragen (`AudioRouterKitTests.swift`, `SlotGainsTests.swift`,
`WaveformGeometryTests.swift`). Die übrigen Tests laufen über den SPM-Pfad
(`v4/scripts/test.sh`). Neue Testdateien laufen deshalb automatisch über `test.sh`, die
`.pbxproj` wird NICHT angefasst (XcodeGen-Signierungsverlust, siehe Verbotsliste).

### 1.5 Leitplanken

Unverändert aus Plan v2 (Abschnitt 1.5), zusätzlich:

- Der IOProc-Block `makeDirectIOBlock` bleibt Byte für Byte unverändert. W1 berührt den
  Echtzeitpfad nur über die Kapazitätskonstante der beiden Brücken (siehe NT-D2, NT-D3).
- Kein Alloc, kein ARC-Traffic, kein Logging, kein neuer Lock im IOProc.
  `os_unfair_lock` bleibt das einzige Synchronisationsmittel in `SlotGains` und
  `PeakMeters`.
- CASE-004/007: effektiver Faktor bleibt `globalVol x slotGain`. `slotAppliesVol`,
  `slotTargetSV`, `effectiveVolume`, die Rampe (`svStep`, `lastSV`) und das Settle-Freeze
  in `VolumeTracker.swift` werden nicht berührt.
- `SoloGain.effective(key:soloedKeys:deviceGains:)` bleibt die einzige Quelle der
  Wahrheit für Solo-Gain-Entscheidungen. `setDeviceGain` persistiert weiter den
  Nutzerwert.
- Keine neuen Dateien in `v4/AudioRouterNow4/`.
- Schreibstil: Umlaute korrekt, kein Gedankenstrich, kein Em-Dash, kein En-Dash,
  keine Namen oder E-Mails Dritter, keine Marketing-Inhalte.
- Konventionelle Commit-Messages mit Scope in Klammern, Co-Author-Zeile, kein Push,
  kein `--no-verify`.

---

## 2. Befunde am Code (Grundlage der Entscheidungen)

### 2.1 Feste Größen und Kapazitäten im Code, vollständige Liste

Gesucht wurde in allen Kit-Quellen und im App-Target nach `maxSlots`, `capacity`,
`reserveCapacity`, `repeating:`, den Zahlen 16, 32, 64, 128, 256, Tupeln und Arrays fester
Länge. Jede Fundstelle:

**Slotzahl-Obergrenzen (künstlich, müssen weg oder auf eine Quelle):**

| Stelle | Inhalt | Wirkung |
|--------|--------|---------|
| `SlotGains.swift` Z. 17, 23, 36, 47, 58 | `maxSlots = 16`: Allokation, Lesen (außerhalb liefert 1.0), Schreiben (No-Op), `setAll` | Gain-Brücke endet bei Index 15 |
| `PeakMeters.swift` Z. 24, 31, 43, 49, 58 | `maxSlots = 16`: Allokation `maxSlots * 2`, `record` klemmt `slotCount`, Nullfüllung, `level` außerhalb liefert (0, 0) | Pegel endet bei Index 15 |
| `FanOutEngine.swift` Z. 196 bis 199 | `setOutputGain`: `idx >= SlotGains.maxSlots` verwirft den Aufruf mit Log-Warnung | Lautstärke und Solo wirkungslos ab Index 16 |
| `FanOutEngine.swift` Z. 596 bis 600 | Warn-Block "Slots ab maxSlots spielen mit festem Unity-Gain" | stilles Degradieren (nur Log) |
| `EngineController.swift` Z. 746 | `where i < SlotGains.maxSlots` in `updateWaveEnergy` | Welle und Meter lassen Slots ab 16 aus, der Divisor `slots` enthält sie trotzdem |
| `SlotGainsTests.swift` Z. 8, 34, 40, 42, 54, 61, 63 | Tests benutzen `SlotGains.maxSlots` als Schranke | passen sich an die Konstante an |
| `v4/ARCHITECTURE.md` Z. 91 und 98 | "`maxSlots * 2 = 32` Werte" und "klemmt `slotCount` gegen `maxSlots`" | Zahl muss aktualisiert werden |

**Dynamisch dimensioniert, keine feste Größe (belegt):**

| Stelle | Inhalt |
|--------|--------|
| `FanOutEngine.swift` Z. 911 | `lastSV = [Float32](repeating: -1, count: slots.count)`, wird in `makeDirectIOBlock` auf dem Kontroll-Thread VOR `AudioDeviceStart` angelegt |
| `FanOutEngine.swift` Z. 801 bis 820 | `slots` per `reserveCapacity(layouts.count)`; pro Slot zwei Scratch-Buffer mit `maxFramesPerCallback` (4096) Float32 und optional eine `DelayLine` |
| `FanOutEngine.swift` Z. 581, 588, 1418 bis 1428 | `slotDeviceKeys` und `slotAppliesVol` sind `map` über die Ausgaben |
| `FanOutEngine.swift` Z. 537 bis 546, 769 bis 792 | Sub-Devices und Layout-Info je UID, nicht je Slot: viele Kanalpaare EINES Geräts (z.B. BlackHole) sind EIN Sub-Device |
| `FanOutEngine.swift` Z. 1022 | `peaks.record(..., slotCount: slots.count)` |
| `FanOutEngine.swift` Z. 1056 | IOProc iteriert `for (slotIdx, slot) in slots.enumerated()`, also über die tatsächliche Slotzahl, nicht über die Kapazität |
| `AudioRouterNow4/UI/DeviceCardView.swift` Z. 289 bis 294, 351 bis 360 | `pairCount = max(1, channelCount / 2)`, keine Obergrenze (ein Gerät mit 256 Kanälen ergäbe 128 Zeilen) |

**Konstanten ohne Bezug zur Slotzahl (zur Abgrenzung):** `maxFramesPerCallback = 4096`
(Frames, `FanOutEngine.swift` Z. 99), `WaveformBridge.capacity = 256` (Zeitverlauf der
Oszilloskop-Werte, `WaveformBridge.swift` Z. 64), `DelayLine.minimumDelayFrames = 64`,
`silenceHeuristicThreshold = 200`. Keine davon begrenzt Slots.

**Nicht gefunden:** keine Tupel oder Arrays fester Länge über Slots, kein `.prefix`, kein
weiteres `16` oder `32` im Slot-Kontext in Kit oder App.

**Nicht belegbar (ungeprüft):** ob CoreAudio ein Aggregate mit sehr vielen
Ausgabe-Buffern (ein Gerät mit 128 oder 256 Kanälen, nicht interleaved bis zu 256 Buffer)
auf diesem System fehlerfrei aufbaut und taktet. Im Code gibt es dafür keine Konstante;
die F5-Prüfung (`aggregateLayoutMismatch`, Z. 619 bis 624) fängt eine Abweichung der
Buffer-Anzahl sicher ab. Ob es eine Systemgrenze gibt, ist nur am Gerät feststellbar
(NM-1, NM-5).

### 2.2 Wie viele Slots entstehen aus wie vielen Konfigurationen

`orderedSlotConfigs` (Z. 1339 ff.) hängt höchstens EINEN synthetischen Default-Slot an
(Schlüssel-Deduplizierung über `addedConfigKeys`). Also gilt:
`Slots <= konfigurierte Ausgaben + 1`. Ein konfigurierter Slot pro Kanalpaar.

### 2.3 Kosten hängen an der genutzten Slotzahl, nicht an der Kapazität

Der IOProc iteriert über `slots` (Z. 1056), `lastSV` und die Scratch-Buffer sind pro
tatsächlichem Slot. Die Kapazität der Brücken kostet nur Speicher: `SlotGains` 4 Byte,
`PeakMeters` 8 Byte pro Kapazitätseintrag. Bei 256: 1 KiB und 2 KiB.

**Gemessen (Planer, dieser Lauf, Release-Build mit `swiftc -O`, die echte
`SlotGains.swift` einkompiliert, ruhiger Mac, kein Hardware-Audio):**

| Messung | Ergebnis |
|---------|----------|
| `SlotGains.gain(slotIndex:)` je Aufruf (Lock, Lesen, Unlock, ohne Konkurrenz) | 14,1 ns |
| Synthetische Slot-Schleife (Gain lesen, Ziel, Rampe, Stereo-Multiplikation, 512 Frames) | 16 Slots 8,4 µs; 64 Slots 29,8 µs; 128 Slots 58,8 µs; 256 Slots 117,4 µs; 512 Slots 234,5 µs je Callback |
| Budget eines Callbacks bei 512 Frames und 44,1 kHz | 11 610 µs |

Hochrechnung aus den Messwerten (Rechnung, nicht gemessen):
- 256 Slots: 117 µs von 11 610 µs, also etwa 1,0 Prozent des Callback-Budgets.
- Lockzugriffe: 256 Slots mal 86 Callbacks pro Sekunde (512 Frames, 44,1 kHz) sind 22 000
  Lock-Paare pro Sekunde, mal 14,1 ns sind 0,31 ms pro Sekunde, also 0,03 Prozent eines
  Kerns. Bei kleinem IO-Buffer (64 Frames, 48 kHz, 750 Callbacks pro Sekunde) sind es
  192 000 Lock-Paare pro Sekunde, 2,7 ms pro Sekunde, 0,27 Prozent eines Kerns.
- Auf die Schleife bezogen: 256 mal 14,1 ns sind 3,6 µs der 117 µs, also etwa 3 Prozent.

Grenzen der Messung (ehrlich): synthetisch, ohne `DelayLine`, ohne echte CoreAudio-Buffer,
ohne Konkurrenz durch den MainActor auf dem Lock, Ausgabe-Buffer nur 1 MiB in L2. Die
Messung belegt die Größenordnung, nicht das Verhalten am Gerät (NM-4).

Speicher pro aktivem Slot (am Code belegt): zwei Scratch-Buffer je 4096 Float32 sind
32 KiB, eine `DelayLine` (falls Delay mindestens 64 Frames) hat zwei Buffer mit
`delay + 4096` Float32, also mindestens 32 KiB. Etwa 65 KiB pro Slot, bei 256 Slots etwa
16,6 MiB. Allokation auf dem Kontroll-Thread beim Aufbau, nicht im IOProc.

---

## 3. Entscheidungen

### NT-D1: Kapazität 256, eine Konstante als einzige Quelle (ENTSCHEIDUNG NUTZER BESTÄTIGEN)

**Frage:** Auf welche Slotzahl wird die Kapazität gesetzt?

**Optionen:**
1. 32 (Fassung 1): deckt den realen Auslöser nicht (ein Gerät mit 64 Kanälen gleich 32 Paare,
   plus Interface mit 10 Paaren, plus Standardgerät, also mehr als 32). Verworfen.
2. 256 als feste Konstante.
3. 512 oder mehr.
4. Dynamische Kapazität, gekoppelt an die Slotzahl beim Aufbau.

**Wahl:** Option 2, `OutputLimits.maxSlots = 256`, definiert in einer neuen Kit-Datei.
`SlotGains.maxSlots` und `PeakMeters.maxSlots` werden zu Verweisen auf diese Konstante.

**Begründung:**
- Größte realistische Summe (Zahlen laut Auftrag des Nutzers, vom Planer nicht
  nachgeprüft): ein virtuelles Gerät mit 256 Kanälen sind 128 Kanalpaare, dazu ein Interface
  mit 10 Paaren und einige weitere Geräte (eingebaut, HDMI), zusammen etwa 143. Mit einem
  zweiten großen Interface (z.B. 64 Kanäle gleich 32 Paare) etwa 175. 256 lässt mehr als
  80 Slots Reserve.
- Kosten sind trivial und belegt: Speicher 3 KiB, Laufzeit der Brücken an der genutzten
  Slotzahl (Abschnitt 2.3), auf 256 Slots hochgerechnet etwa 1 Prozent des Callback-Budgets
  und 0,03 Prozent eines Kerns für die Locks.
- 512 oder mehr wäre für die Brücken ebenfalls billig, aber der echte Aufwand (Scratch,
  DelayLine, UI mit nicht-lazy gebauten Zeilen) wächst linear mit der genutzten Slotzahl
  und ist oberhalb von etwa 256 am Gerät völlig ungetestet. Eine hohe, aber prüfbare und
  ehrlich benannte Grenze ist besser als eine unbelegte.
- Eine einzige Konstante verhindert, dass `SlotGains`, `PeakMeters`, die Add-Sperre und
  der Startfehler auseinanderlaufen (die Ursache der alten Lücke: zwei getrennte `16`).

**Rückfall:** Konstante ändern (eine Zeile). Alle Tests hängen an der Konstante.

### NT-D2: Lock-Mechanik unverändert, kein Snapshot

**Frage:** Muss `SlotGains.gain` bei hoher Slotzahl auf eine Struktur mit weniger
Lockzugriffen umgebaut werden (ein Snapshot pro Callback, atomare Floats)?

**Wahl:** Nein, die bestehende, bewährte Mechanik bleibt (ein `os_unfair_lock`-Zugriff pro
Slot und Callback).

**Begründung:** Gemessen 14,1 ns pro Zugriff, hochgerechnet 0,03 bis 0,27 Prozent eines
Kerns bei 256 Slots (Abschnitt 2.3). Ein Snapshot bräuchte einen vorab allozierten Puffer
mit Lebensdauer im IOProc-Block, also eine neue Freigabe-Regel, und würde den Echtzeitpfad
ändern, ohne dass ein Messwert es verlangt. Leitplanke: nur ändern, wenn sich begründen und
testen lässt.

**Rückfall:** Zeigt NM-4 am Gerät Aussetzer oder auffällige CPU-Last bei hoher Slotzahl,
wird ein Snapshot-Schritt (`SlotGains.copy(into:count:)`, ein Lock pro Callback) in einem
eigenen Plan nachgezogen. Nicht Teil dieses Plans.

### NT-D3: Feste Konstante statt dynamischer Kapazität

**Frage:** Soll die Kapazität an die Slotzahl gekoppelt werden?

**Wahl:** Nein, feste Konstante 256.

**Begründung:** `SlotGains` und `PeakMeters` werden als `let` in `FanOutEngine` angelegt
(Z. 141 und 148) und per Capture in den IOProc-Block gegeben. Eine dynamische Kapazität
verlangte Zeigerwechsel unter dem Lock oder neue Instanzen pro Aufbau (die IOProc-Capture
müsste folgen). Das ist machbar, aber für 3 KiB Speicher unnötig riskant im ersten
Echtzeit-Eingriff des Zyklus. Mit der festen Konstante ändert sich zur Laufzeit kein
Zeiger, der Speicher wird einmal in `init` angelegt und nach `AudioDeviceStop` im `deinit`
freigegeben (Bestandsverhalten, unverändert).

**Rückfall:** entfällt (kein Eingriff).

### NT-D4: W2, Auslegung und Formel (ENTSCHEIDUNG NUTZER BESTÄTIGEN)

**Frage:** Was heißt "die Welle soll visuell nie kleiner werden", und welche Formel
garantiert es?

**Auslegung des Hauptagenten, vom Planer am Code geprüft:** Solo darf die Wellenhöhe
gegenüber dem Zustand ohne Solo bei gleichem Audiomaterial nicht verringern. Die
Meter der Karten behalten die B1-Korrektur (stumme Karten zeigen keinen Pegel), nur die
Welle wird Solo-neutral. Unbestätigt: ob der Nutzer damit auch gemeint hat, dass die Welle
beim Absenken eines Gerätereglers (nicht Solo) nicht schrumpfen soll. Das wäre ein anderer
Wunsch (Welle ganz ohne Gain) und wird hier NICHT umgesetzt. Bitte bestätigen oder
korrigieren.

**Optionen:**
1. `sum` aus `deviceGains[key]` statt `SoloGain.effective`, Divisor unverändert (alle Slots).
2. Division durch die Anzahl hörbarer Slots.
3. Welle ohne jeden Gain (reiner Quell-Peak).

**Prüfung am Code und rechnerisch:**
- Der IOProc schreibt in `peaks.record` für ALLE Slots denselben Wert (Quell-Peak mal
  globale Lautstärke, `FanOutEngine.swift` Z. 1022, gain-frei). Also gilt für jeden Slot
  `raw_i = raw`.
- Solo schreibt `deviceGains` nie (`SoloGain.swift` Kommentar, CASE-004/R3). Damit ist bei
  Option 1 `sum / N = raw * mittel(deviceGains)`. Weder Solo noch die Wahl des Solo-Geräts
  gehen in die Formel ein. Die Garantie "Solo ändert die Wellenhöhe nicht" gilt exakt
  und per Konstruktion, auch wenn das Solo-Gerät leiser ist als der Durchschnitt und
  auch bei beliebig vielen Solo-Geräten.
- Abgestecktes Solo-Gerät: die Slotzahl und `raw` ändern sich dann durch den Rebuild,
  also ändert sich die Welle durch das Entfernen eines Geräts (physische Änderung), nicht
  durch Solo. Das ist erwartet und kein Verstoß.
- Option 2 verletzt die Garantie: drei Slots mit Gain 1,0 und ein Solo-Slot mit Gain 0,3
  bei gleichem Quellpegel. Ohne Solo mittelt die Welle über alle: (3 mal 1,0 + 0,3) / 4 =
  0,825. Unter Solo mit Divisor 1: 0,3. Die Welle schrumpft. Verworfen.
- Option 3 ändert zusätzlich das Verhalten bei normalen Gerätereglern, das niemand
  gewünscht hat. Verworfen.

**Wahl:** Option 1. Die Berechnung wird eine reine, testbare Funktion im Kit
(`WaveEnergyMath.soloNeutralLinear`, siehe NT-D6). Der Meter-Pfad (`peakLevels`) behält
`SoloGain.effective`.

**Konsistenz mit W1:** Die Schleife läuft ohne `where`-Schranke über alle Slots bis zur
Kapazität, Zähler und Divisor sind dieselbe Menge (bisher fehlten Slots ab 16 in der
Summe, standen aber im Divisor `slots`, die Welle war also bei mehr als 16 Slots
systematisch zu klein).

**Das hebt Entscheidung D1 (Welle) aus `05-plan-v2.md` auf.** Die Historie bleibt, der
Eintrag in `05-decisions.md` (NT-S9) verweist auf beide.

**Rückfall:** In `updateWaveEnergy` die Berechnung wieder auf `SoloGain.effective`
umstellen (eigener Commit).

### NT-D5: Verhalten oberhalb der Kapazität: ehrlich und sichtbar (ENTSCHEIDUNG NUTZER BESTÄTIGEN)

**Frage:** Was passiert, wenn mehr Ausgaben gewählt werden, als die Kapazität erlaubt?

**Optionen:**
1. Weiter nur Log-Warnung und Unity-Gain (Zustand heute): verworfen, widerspricht W1.
2. Hinzufügen blockieren, Meldung in der Oberfläche; zusätzlich harter Startfehler für den
   Fall, dass gespeicherte Daten mehr enthalten.
3. Bei Überschreitung automatisch kürzen: verworfen (stilles Degradieren).

**Wahl:** Option 2.
- Auswahl: `EngineController.addOutputConfig` fragt eine reine Entscheidungsfunktion im Kit
  (`OutputLimits.addDecision`). Bei Überschreitung wird die Konfiguration NICHT hinzugefügt
  und eine Meldung (englisch, UI-Stil) in einer neuen `@Published`-Eigenschaft gesetzt,
  die `MenuBarView` über der Geräteliste anzeigt.
- Start und Rebuild: `FanOutEngine.start` und `buildAndStartAggregate` werfen
  `RouterError.tooManyOutputs(count:max:)`, falls die Anzahl der Konfigurationen die Grenze
  übersteigt (Fall: aus der Persistenz geladene Liste). Die bestehende Fehlerzeile in
  `MenuBarView` (`errorSection`) zeigt `localizedDescription` bereits an.
- Grenze für Konfigurationen: `maxConfiguredOutputs = maxSlots - 1 = 255`, weil ein Slot für
  den synthetischen Default-Slot reserviert bleibt (Abschnitt 2.2). So gilt immer
  `Slots <= 256`.

**Meldungstexte (englisch):**
- Auswahl: `Output limit reached: AudioRouterNow can route to 255 outputs at once. Remove an output to add another.`
- Startfehler: `Too many outputs are selected (300). AudioRouterNow can route to 255 at once. Remove some outputs and press Start again.`

(Zahlen kommen aus der Konstante, nicht hartkodiert.)

**Begründung:** Die Grenze ist damit nie still. Der Nutzer erfährt sie an der Stelle der
Handlung. Praktisch ist sie unterhalb des realen Auslösers nicht erreichbar.

**Rückfall:** Die Sperre in `addOutputConfig` entfernen (eigener Commit), der Startfehler
bleibt als Absicherung der Kapazität.

### NT-D6: Wellenformel als Kit-Funktion mit Index-Arrays

**Frage:** Wo liegt die Wellenformel und wie sind die Parameter geschnitten?

**Wahl:** Neue Datei `WaveEnergyMath.swift` im Kit. Parameter sind index-gleiche Arrays
(`slotPeaks` und `keys`) statt eines Dictionaries, damit der 20-fps-Poll keine zusätzliche
Dictionary-Allokation je Tick bekommt (bei 256 Slots relevant). Gleiches Muster wie
`SoloGain` (Begründung dort: aus dem Test-Target nicht erreichbar, wenn im App-Target).

**Rückfall:** Formel inline lassen, dann sind die Tests nicht möglich (nicht empfohlen).

### NT-D7: Doku, Known-limitation entfällt, ehrlicher Rest-Stand als Satz (ENTSCHEIDUNG NUTZER BESTÄTIGEN)

**Frage:** Was wird aus dem Known-limitation-Absatz zu `maxSlots` in CHANGELOG und
RELEASE_NOTES?

**Wahl:** Der Absatz "Known limitation" entfällt in beiden Dateien, weil die Einschränkung
(stilles Unity-Gain ab Slot 16) nicht mehr existiert. Ersetzt wird er durch einen Eintrag
unter "Fixed" (CHANGELOG) bzw. einen Abschnitt in RELEASE_NOTES, der den wahren Rest-Stand
nennt: bis zu 255 gleichzeitige Ausgaben, darüber wird das Hinzufügen mit einer Meldung
verhindert. Die Formulierung nennt nur Belegtes (Code und Unit-Tests), keine
Hörprüfung, solange NM-1 nicht erledigt ist.

**Rückfall:** Wenn der Nutzer die Grenze nicht erwähnen will: Satz streichen, der Rest
bleibt belegt.

---

## 4. Verbotsliste

- Entitlements, Signierung, `project.yml`, `.pbxproj`, `AudioRouterNow4.xcconfig` (Version,
  Build), Archiv, Einreichung, Tag, Merge, Push.
- Consent-Mechanik (`ensureLoginItemCompliance`, `hasValidLaunchAtLoginConsent`,
  `launchAtLoginConsentBuildKey`, `launchAtLoginOptedInKey`).
- Neue Dateien in `v4/AudioRouterNow4/`.
- Der IOProc-Block `makeDirectIOBlock` (keine Zeile ändern), Rampe `svStep`/`lastSV`,
  `slotAppliesVol`, `computeSlotAppliesVol`, `effectiveVolume`, `slotTargetSV`.
- `VolumeTracker.swift` und das Settle-Freeze (CASE-007).
- `SoloGain.swift` (keine Änderung, nur Tests darum herum).
- Layout und Struktur der Geräteliste in `MenuBarView.swift` und `DeviceCardView.swift`
  (kein `LazyVStack`, kein Umbau: CASE-003 trat im selben View-Baum auf). Erlaubt ist
  ausschließlich die eine Meldungszeile (NT-S7).
- Historische Plan- und Audit-Dokumente `02` bis `13` umschreiben. Fassung 1 dieses Plans
  bleibt im Git-Verlauf.
- Marketing-Inhalte, Namen oder E-Mails von Nutzern und Dritten.
- Logging im IOProc, Allokation im IOProc, neue Locks.

---

## 5. Nummerierte Schritte

Nach jedem Schritt: Kit-Tests (`bash v4/scripts/test.sh`), App-Build (Befehl aus 1.4) und
lokaler Commit. Alle Zeilenangaben am aktuellen Code geprüft (Stand Commit `4c7dbfe`);
weichen sie nach früheren Schritten ab, gilt das Symbol.

### NT-S0: Baseline bestätigen

Datei: keine Änderung. `bash v4/scripts/test.sh` und App-Build ausführen.

Akzeptanz: 59 swift-testing und 56 XCTest grün, BUILD SUCCEEDED.
Commit: keiner.

### NT-S1: `RouterError.tooManyOutputs` (W1, ehrliches Verhalten)

Datei: `v4/AudioRouterKit/Sources/AudioRouterKit/AudioRouterKit.swift`.
Symbole: `enum RouterError` (Z. 20), `extension RouterError: LocalizedError` (Z. 55).

Änderung: neuer Fall am Ende des Enums und ein Zweig in `errorDescription`.

```swift
/// Mehr Ausgaben gewählt, als die Engine gleichzeitig ansteuern kann (NT-D5).
case tooManyOutputs(count: Int, max: Int)
```

```swift
case .tooManyOutputs(let count, let max):
    return "Too many outputs are selected (\(count)). AudioRouterNow can route to \(max) at once. Remove some outputs and press Start again."
```

Prüfung: Es gibt keinen weiteren erschöpfenden `switch` über `RouterError` im Repo
(Suche nach `case .tccDenied`, `.deviceNotFound`, `.aggregateLayoutMismatch` in
`AudioRouterNow4` und Tests fand nur eine Test-Fundstelle mit `if case`). Der Umsetzer
wiederholt die Suche vor dem Commit.

Begründung: gibt dem Überschreitungsfall einen benannten, sichtbaren Fehler. Die
bestehende `errorSection` in `MenuBarView` (Z. 263 bis 273) zeigt ihn ohne Änderung.

Akzeptanz: Kit und App bauen, kein Compilerfehler durch den neuen Fall.
Test: in NT-S2 (`OutputLimitsTests`, Beschreibung enthält die Zahlen).
Commit: `feat(AudioRouterKit): RouterError.tooManyOutputs für Ausgabenlimit (W1, NT-D5)`

### NT-S2: `OutputLimits` als einzige Quelle plus Entscheidungsfunktion (W1)

Neue Datei: `v4/AudioRouterKit/Sources/AudioRouterKit/OutputLimits.swift`.
Neue Testdatei: `v4/AudioRouterKit/Tests/AudioRouterKitTests/OutputLimitsTests.swift`.

```swift
import Foundation

/// Einzige Quelle der Wahrheit für die Slot-Obergrenze der Engine (NT-D1).
/// Kapazität der Brücken `SlotGains` und `PeakMeters`; die Kosten hängen an der
/// tatsächlich genutzten Slotzahl, nicht an dieser Konstante.
public enum OutputLimits {

    /// Obergrenze gleichzeitiger Slots (Brückenkapazität).
    public static let maxSlots = 256

    /// Obergrenze konfigurierter Ausgaben. Ein Slot bleibt für den synthetischen
    /// Default-Slot reserviert (`orderedSlotConfigs` hängt höchstens einen an).
    public static let maxConfiguredOutputs = maxSlots - 1

    public enum AddDecision: Equatable, Sendable {
        case allowed
        case duplicate
        case limitReached(max: Int)
    }

    /// Entscheidung beim Hinzufügen einer Ausgabe. Duplikate bleiben stumme No-Ops
    /// (Bestandsverhalten von `addOutputConfig`), das Limit wird sichtbar gemeldet.
    public static func addDecision(currentCount: Int, alreadyConfigured: Bool) -> AddDecision {
        if alreadyConfigured { return .duplicate }
        if currentCount >= maxConfiguredOutputs { return .limitReached(max: maxConfiguredOutputs) }
        return .allowed
    }

    public static func limitMessage(max: Int) -> String {
        "Output limit reached: AudioRouterNow can route to \(max) outputs at once. Remove an output to add another."
    }

    /// Prüfung für Start und Rebuild (die Persistenz kann mehr Einträge enthalten).
    public static func validateOutputCount(_ count: Int) throws {
        if count > maxConfiguredOutputs {
            throw RouterError.tooManyOutputs(count: count, max: maxConfiguredOutputs)
        }
    }
}
```

Tests (XCTest, `@testable import AudioRouterKit`):

| Test | Prüft |
|------|-------|
| `testCapacityIs256AndConfiguredLimitIs255` | Konstanten, `maxConfiguredOutputs == maxSlots - 1` |
| `testAddAllowedBelowLimit` | Anzahl 0, 16, 17, 100, 254 gleich `.allowed` |
| `testAddAtLimitIsRejectedWithMax` | Anzahl 255 und 300 gleich `.limitReached(max: 255)` |
| `testDuplicateWinsOverLimit` | Duplikat bei Anzahl 255 gleich `.duplicate` (keine Meldung) |
| `testNegativeCountIsAllowed` | Anzahl -1 gleich `.allowed` (kein Absturz) |
| `testValidateOutputCountBoundary` | 0 und 255 werfen nicht, 256 wirft `.tooManyOutputs(count: 256, max: 255)` |
| `testLimitMessageContainsNumberAndNoDash` | Text enthält "255", keine Zeichen U+2014, U+2013 |
| `testTooManyOutputsDescription` | `RouterError.tooManyOutputs(count: 300, max: 255).errorDescription` enthält "300" und "255" |

Akzeptanz: alle Tests grün.
Commit: `feat(AudioRouterKit): OutputLimits mit Kapazität 256 und Add-Entscheidung (W1, NT-D1, NT-D5)`

### NT-S3: Kapazität der Brücken aus einer Quelle (W1)

Dateien:
- `v4/AudioRouterKit/Sources/AudioRouterKit/SlotGains.swift` Z. 17.
- `v4/AudioRouterKit/Sources/AudioRouterKit/PeakMeters.swift` Z. 24.

Änderung (nur diese zwei Zeilen und die Kommentare):

```swift
// SlotGains.swift
public static let maxSlots = OutputLimits.maxSlots

// PeakMeters.swift
static let maxSlots = OutputLimits.maxSlots
```

Kommentare anpassen: in `PeakMeters` "Harte Obergrenze der Output-Slots (= FanOutEngine-
Fan-out-Limit)" auf "Kapazität, gleich `OutputLimits.maxSlots`"; in `SlotGains.gain` den
Satz "Out-of-range gibt 1.0 (Unity)" ergänzen um "(reiner Schutz gegen falsche Indizes,
in Produktion durch `OutputLimits` nicht erreichbar)".

Keine weiteren Änderungen: `storage` (`allocate(capacity: maxSlots)` bzw.
`maxSlots * 2`), `gain`, `set`, `setAll`, `record`, `level` greifen auf die Konstante zu.

Speicher: 256 mal 4 Byte (SlotGains, vorher 64 Byte) und 256 mal 8 Byte (PeakMeters,
vorher 128 Byte). Die Sperrdauer von `setAll` und `record` wächst mit der Kapazität (bis zu
512 Stores unter dem Lock, Schätzung etwa 0,1 bis 0,3 µs, ungemessen); der Leser wartet im
schlimmsten Fall so lange. Begründung für unveränderte Mechanik: NT-D2.

Tests (bestehend `SlotGainsTests.swift` erweitern, neu `PeakMetersTests.swift`):

SlotGainsTests, neu:

| Test | Prüft |
|------|-------|
| `testSlotsBeyondFormerLimitAreWritableAndReadable` | `set(0.5, slotIndex:)` und `gain(slotIndex:)` für 15, 16, 17, 31, 32, 33, 100, 255 |
| `testLastValidSlotAndFirstInvalidSlot` | Index `maxSlots - 1` setzbar, Index `maxSlots` (256) liefert 1.0 und `set` ist No-Op, Nachbarslots unverändert |
| `testSetAllBeyondSixteenSeedsEverySlot` | `setAll` mit 100 verschiedenen Werten, Stichproben 0, 15, 16, 17, 99; Slot 100 und 255 gleich 1.0 |
| `testSetAllWithMoreThanCapacityIgnoresExcess` | `setAll` mit 300 Werten wirft nicht, Slot 255 trägt Wert 255, kein Zugriff über die Kapazität |
| `testSetAllClampsValuesAboveSixteen` | Werte -1 und 2 an Slot 40 werden auf 0 und 1 geklemmt |
| `testResetCoversWholeCapacity` | nach `setAll` mit 0.3 auf 256 Slots setzt `reset` alle auf 1.0 |
| `testBridgesShareTheSingleCapacitySource` | `SlotGains.maxSlots == OutputLimits.maxSlots` und `PeakMeters.maxSlots == OutputLimits.maxSlots` |

PeakMetersTests (neue XCTest-Datei, `PeakMeters` ist `internal`, `@testable` genügt):

| Test | Prüft |
|------|-------|
| `testRecordAndReadBeyondSixteen` | `record(l: 0.5, r: 0.25, slotCount: 100)`, `level(slotIndex:)` für 0, 16, 99 gleich (0.5, 0.25); Slot 100 gleich (0, 0) |
| `testRecordAtFullCapacity` | `slotCount: 256`, Slot 255 trägt den Wert |
| `testRecordClampsAboveCapacity` | `slotCount: 300` wirft nicht, `level(slotIndex: 256)` und 300 gleich (0, 0) |
| `testLevelOutOfRange` | `level(slotIndex: -1)` gleich (0, 0) |
| `testRecordZeroesSlotsAboveCount` | erst `record(slotCount: 200)`, dann `record(slotCount: 3)`: Slot 3 und 150 gleich (0, 0) |
| `testResetClearsAll` | `reset` nullt Slot 0 und 255 |

Akzeptanz: Kit-Tests grün, App baut.
Commit: `fix(AudioRouterKit): SlotGains und PeakMeters Kapazität aus OutputLimits (W1, NT-D1)`

### NT-S4: FanOutEngine, Zweige entfernen und Slotzahl prüfen (W1)

Datei: `v4/AudioRouterKit/Sources/AudioRouterKit/FanOutEngine.swift`.

Änderungen (alle auf dem Kontroll-Thread, nicht im IOProc):

1. `setOutputGain` (Z. 193 bis 202): den Zweig `if idx >= SlotGains.maxSlots { ... return }`
   (Z. 196 bis 199) entfernen, übrig bleibt `slotGains.set(gain, slotIndex: idx)`.
   Kommentar: Der Index liegt durch die Prüfung in `start`/`buildAndStartAggregate` immer
   unter der Kapazität; `SlotGains.set` bleibt ein Schutz gegen falsche Indizes.

2. Warn-Block Z. 596 bis 600 (`if slotDeviceKeys.count > SlotGains.maxSlots { ... }`)
   ersatzlos entfernen, durch einen Kommentar ersetzen: "Slotzahl durch
   `OutputLimits.validateOutputCount` begrenzt (NT-D5)".

3. `start(outputs:exclusive:)` (Z. 277): direkt nach `guard status != .routing else { return }`
   und VOR `try createTap()` einfügen:

   ```swift
   // NT-D5: zu viele Ausgaben ehrlich ablehnen, bevor Tap (TCC) und Aggregate entstehen.
   try OutputLimits.validateOutputCount(outputs.count)
   ```

4. `buildAndStartAggregate` (Z. 425): als erste Anweisung (vor `readDefaultOutputDeviceUID`)
   dieselbe Prüfung. Sie deckt `updateOutputs` ab. Der bestehende `catch` in
   `updateOutputs` (Z. 332 bis 337) räumt komplett auf und setzt `status = .idle`,
   `EngineController` zeigt den Fehler über `status = .error(e)`. Eine Prüfung VOR dem
   Teardown in `updateOutputs` wird bewusst NICHT eingebaut, weil der Controller bei einem
   Wurf `status = .error` setzt, während die Engine weiterliefe (Zustandsdivergenz). In
   der Praxis fängt die Sperre in `addOutputConfig` den Fall vorher ab.

Nicht anfassen: `makeDirectIOBlock` und alles darin.

Begründung: schafft die belegte Invariante `Slots <= 256` und entfernt das stille
Degradieren. Die Grenze wird vor dem ersten CoreAudio-Aufruf geprüft.

Akzeptanz: Build grün; `grep -n "SlotGains.maxSlots" FanOutEngine.swift` liefert keine
Treffer mehr; `grep -n "Unity-Gain" FanOutEngine.swift` liefert keinen Warn-Text mehr.

Test (swift-testing, `AudioRouterKitTests.swift`, Suite "FanOutEngine (CI-safe: Fehler-Pfade)",
Muster des Tests `startBehaviour`, `@MainActor`, weil `FanOutEngine` `@MainActor` ist):

```swift
@Test("start() lehnt mehr als die erlaubte Zahl Ausgaben ab, ohne CoreAudio")
@MainActor
func startRejectsTooManyOutputs() {
    let engine = FanOutEngine()
    let configs = (0..<(OutputLimits.maxConfiguredOutputs + 1))
        .map { OutputConfig(uid: "test-uid", channelOffset: $0 * 2) }
    #expect(throws: RouterError.tooManyOutputs(
        count: configs.count, max: OutputLimits.maxConfiguredOutputs)) {
        try engine.start(outputs: configs)
    }
    #expect(engine.status == .idle)
}
```

Der Umsetzer prüft die Initialisierer von `OutputConfig` (Parameter `uid`, `channelOffset`,
Standardwert für `channelCount`, siehe `OutputConfig.swift` und die Aufrufe in den
bestehenden Tests) und die Syntax von `#expect(throws:)` in der installierten
swift-testing-Version (ungeprüft). Der Test ist deterministisch, weil die Prüfung vor
`createTap` greift. Ein Gegenstück mit genau `maxConfiguredOutputs` Konfigurationen wird
NICHT als Engine-Test geschrieben (es würde CoreAudio berühren); die Grenze ist in
`OutputLimitsTests` abgedeckt.

Commit: `fix(FanOutEngine): Slotzahl prüfen statt still degradieren, 16er-Zweige entfernt (W1, NT-D5)`

### NT-S5: `WaveEnergyMath` mit Tests (W2)

Neue Dateien: `v4/AudioRouterKit/Sources/AudioRouterKit/WaveEnergyMath.swift`,
`v4/AudioRouterKit/Tests/AudioRouterKitTests/WaveEnergyMathTests.swift`.

```swift
import Foundation

/// W2 (NT-D4, docs/v4.1/14-plan-nachtrag.md): Solo-neutrale lineare Wellen-Energie.
/// Reine Arithmetik, kein CoreAudio. `soloedKeys` ist bewusst KEIN Parameter: Solo kann
/// die Wellenhöhe so nicht beeinflussen. Die Meter der Karten nutzen weiter
/// `SoloGain.effective`.
public enum WaveEnergyMath {

    /// - Parameters:
    ///   - slotPeaks: IOProc-Peaks (L, R) je Slot, Reihenfolge wie `keys`.
    ///   - keys: Slot-Schlüssel "<uid>:<channelOffset>" in Slot-Reihenfolge.
    ///   - deviceGains: gespeicherte Nutzer-Gains [0...1] (Solo schreibt sie nie).
    /// - Returns: Mittelwert über ALLE Slots, auf 1.0 geklemmt; 0 bei leerer Eingabe.
    public static func soloNeutralLinear(
        slotPeaks: [(l: Float32, r: Float32)],
        keys: [String],
        deviceGains: [String: Double]
    ) -> Float32 {
        let n = min(slotPeaks.count, keys.count)
        guard n > 0 else { return 0 }
        var sum: Float32 = 0
        for i in 0..<n {
            let g = Float32(deviceGains[keys[i]] ?? 1.0)
            sum += (slotPeaks[i].l + slotPeaks[i].r) * 0.5 * g
        }
        return min(1, sum / Float32(n))
    }
}
```

Tests (XCTest):

| Test | Prüft |
|------|-------|
| `testEqualPeaksNoGainsReturnsPeak` | 3 Slots, Peak (0.6, 0.6), keine Gains gleich 0.6 |
| `testSoloDoesNotLowerTheWave` | 3 Slots gleicher Peak, "Solo auf Slot 1": Ergebnis gleich dem Ergebnis ohne Solo (die Funktion kennt Solo nicht, der Test ruft sie zweimal mit identischen Eingaben auf und dokumentiert das) |
| `testMaskedSumWouldHaveShrunkTheWave` | Regressionsanker gegen D1 (Welle): dieselben Slots, Summe mit `SoloGain.effective` und Solo auf 1 von 3 gleich 1/3 des neutralen Werts; die neutrale Funktion liefert den ungekürzten Wert |
| `testQuieterSoloDeviceDoesNotChangeTheWave` | Solo-Gerät mit Gain 0.2, andere 1.0: gleicher Wert wie ohne Solo (Gegenbeispiel zu Option 2) |
| `testDisconnectedSoloDeviceChangesWaveOnlyThroughPeaks` | Slot mit Peak (0, 0) senkt den Mittelwert (dokumentierte physische Änderung) |
| `testEmptyInputReturnsZero` | leere Arrays gleich 0 |
| `testMismatchedArrayLengthsUseShorterLength` | 3 Peaks, 2 Keys: Divisor 2 |
| `testMissingGainDefaultsToUnity` | Key fehlt in `deviceGains`, Faktor 1.0 |
| `testClampsAtOne` | Peaks 1.0 bei Gains 1.0 gleich genau 1.0, Peaks 2.0 gleich 1.0 |
| `testManySlotsBeyondSixteenCountEqually` | 100 Slots, alle gleicher Peak: Ergebnis gleich Einzelpeak (Slots ab 16 zählen mit) |
| `testOneLoudSlotAtIndexNinetyNineOfHundred` | Peak nur an Index 99: Ergebnis gleich Peak geteilt durch 100 |

Akzeptanz: Kit-Tests grün, App baut (die Funktion ist noch nicht verdrahtet).
Commit: `feat(AudioRouterKit): WaveEnergyMath, Solo-neutrale Wellenenergie (W2, NT-D4, NT-D6)`

### NT-S6: EngineController, Hinzufügen begrenzen und Welle verdrahten (W1, W2)

Datei: `v4/AudioRouterNow4/EngineController.swift` (bestehende Datei).

**a) Neue Eigenschaft** neben `outputConfigs` (Z. 96):

```swift
/// NT-D5: Meldung, wenn das Hinzufügen einer Ausgabe wegen der Slot-Obergrenze abgelehnt wurde.
@Published private(set) var outputLimitNotice: String?
```

**b) `addOutputConfig`** (Z. 539 bis 544) ersetzen durch:

```swift
func addOutputConfig(_ config: OutputConfig) {
    switch OutputLimits.addDecision(
        currentCount: outputConfigs.count,
        alreadyConfigured: outputConfigs.contains(config)
    ) {
    case .duplicate:
        return
    case .limitReached(let max):
        outputLimitNotice = OutputLimits.limitMessage(max: max)
        return
    case .allowed:
        outputLimitNotice = nil
        outputConfigs.append(config)
        Self.saveOutputConfigs(outputConfigs)
        applyOutputsIfRouting()
    }
}
```

Verhalten unterhalb der Grenze und bei Duplikaten bleibt identisch zu heute.

**c) `removeOutputConfig`** (Z. 548 bis 552): als erste Zeile `outputLimitNotice = nil`.

**d) `updateWaveEnergy`** (Z. 738 bis 787): Schleife ohne `where`, Array statt Summe, Welle
über `WaveEnergyMath`. Der Meter-Pfad (`newPeaks` mit `SoloGain.effective`) bleibt.

```swift
var newPeaks: [String: (l: Float32, r: Float32)] = [:]
var slotPeaks: [(l: Float32, r: Float32)] = []
slotPeaks.reserveCapacity(slots)
for (i, key) in engine.slotDeviceKeys.enumerated() {
    let raw = engine.peakLevel(slotIndex: i)
    slotPeaks.append(raw)
    // Meter: effektiver Gain, stumme Karten zeigen keinen Pegel (B1, cba4489).
    let gain = SoloGain.effective(key: key, soloedKeys: soloedKeys, deviceGains: deviceGains)
    let p = (l: raw.l * gain, r: raw.r * gain)
    let prev = peakLevels[key] ?? (l: 0, r: 0)
    newPeaks[key] = (l: max(p.l, prev.l * 0.80), r: max(p.r, prev.r * 0.80))
}
if !newPeaks.isEmpty { peakLevels = newPeaks }

// W2 (NT-D4, docs/v4.1/14-plan-nachtrag.md): Welle Solo-neutral, ersetzt D1 (Welle)
// aus docs/v4.1/05-plan-v2.md. Solo darf die Wellenhöhe nicht verringern.
let linear = WaveEnergyMath.soloNeutralLinear(
    slotPeaks: slotPeaks, keys: engine.slotDeviceKeys, deviceGains: deviceGains)
```

Der Rest (dBFS-Abbildung, EMA) bleibt unverändert. Die Variable `sum` entfällt. Den
Kommentar "Plan-v2-Entscheidung D1 ... `SoloGain.effective` auch fuer `sum`" (Z. 752 bis
753) entfernen, er wäre falsch.

Prüfung Seed- und Restart-Pfade (am Code geprüft, KEINE Änderung nötig): `setOutputGains`
(Z. 345, 426, 582, 848) ruft `reseedSlotGains` mit `slotDeviceKeys.map`, `applySoloGains`
(Z. 355, 432, 596, 857) iteriert über `engine.slotDeviceKeys` und ruft `setOutputGain` mit
`SoloGain.effective`. Nach NT-S3 und NT-S4 gilt beides ohne Obergrenze 16 für alle Slots
bis 256. Der Umsetzer prüft per Lektüre, dass kein weiterer Aufrufer auf `maxSlots` wartet:
`grep -rn "maxSlots" v4/AudioRouterNow4 v4/AudioRouterKit/Sources`.

Akzeptanz: App baut; `grep -n "SlotGains.maxSlots" v4/AudioRouterNow4/EngineController.swift`
liefert keinen Treffer; Verhalten unter Solo: Welle unverändert (NM-3).
Test: Logik in NT-S2 und NT-S5 getestet (Entscheidungsfunktion und Formel). Die
Verdrahtung im App-Target ist nicht unit-testbar (kein Test-Target für `EngineController`),
sie wird vom Auditor per Lektüre und am Gerät (NM-1 bis NM-3) geprüft.
Commit: `fix(EngineController): Ausgabenlimit sichtbar, Welle Solo-neutral, Slotschleife ohne 16er-Grenze (W1, W2)`

### NT-S7: Meldungszeile in `MenuBarView` (W1)

Datei: `v4/AudioRouterNow4/MenuBarView.swift` (bestehende Datei, keine neue Datei).

Änderung: direkt nach dem Fehlerblock (Z. 48 bis 53) einfügen und eine kleine
private Funktion neben `errorSection` (Z. 263) ergänzen:

```swift
// ── Ausgabenlimit-Meldung (NT-D5) ────────────────────────────
if let notice = controller.outputLimitNotice {
    limitNoticeSection(notice)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
}
```

```swift
private func limitNoticeSection(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.caption)
        Text(text)
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(3)
    }
}
```

Begründung: genau das Muster von `errorSection` (gleiche Struktur, nur Farbe und Symbol).
Die Meldung steht außerhalb des ScrollViews, sichtbar im Leerlauf und beim Routing. Sie
verschwindet beim nächsten Entfernen oder erfolgreichen Hinzufügen einer Ausgabe.

Risiko: Das Root-`VStack` hat `.fixedSize(vertical: true)`, eine bedingte Zeile verändert
die Höhe. `errorSection` und der TCC-Block tun dasselbe; der Umsetzer fügt keine
`GeometryReader` und keine `PreferenceKey` hinzu (CASE-003). Am Gerät zu prüfen (NM-6).

Akzeptanz: App baut; ohne Meldung ändert sich das Layout nicht.
Test: keiner automatisiert (UI). Auditor liest den Code.
Commit: `feat(MenuBarView): Meldung bei Ausgabenlimit (W1, NT-D5)`

### NT-S8: Solo und Lautstärke über die Slotgrenze 16 hinaus, Kit-Test (W1)

Neue Testdatei: `v4/AudioRouterKit/Tests/AudioRouterKitTests/SoloSlotRangeTests.swift`.

Die Pipeline `applySoloGains` (Controller) mit `setOutputGain` (Engine) ist im Test-Target
nicht erreichbar (CoreAudio, App-Target). Der Test bildet sie aus den beiden Kit-Bausteinen
nach: `SoloGain.effective` je Schlüssel, Ergebnis per `SlotGains.set(_, slotIndex:)`, Lesen
per `gain(slotIndex:)`. Das prüft, dass die beiden Bausteine über Index 16 hinaus
zusammenpassen, nicht den Controller selbst (im Dateikopf ausdrücklich so dokumentieren).

| Test | Prüft |
|------|-------|
| `testSoloOnSlotBeyondSixteenSilencesTheOthers` | 120 Schlüssel, Solo auf Index 100: Gain an 0, 15, 16, 17, 119 gleich 0.0, an 100 gleich gespeichertem Gain |
| `testSoloOnSlotZeroSilencesSlotsAboveSixteen` | Solo auf Index 0: Gain an 16, 17, 100 gleich 0.0 |
| `testReleaseSoloRestoresStoredGainsAboveSixteen` | nach Aufheben von Solo gelten die gespeicherten Gains an 16, 17, 100 wieder |
| `testPerDeviceVolumeBeyondSixteen` | Gain 0.4 an Index 40 gesetzt und gelesen, Nachbarn unverändert |
| `testSlotExactlySixteenAndSeventeenBehaveLikeLowSlots` | Index 15, 16, 17 identisches Verhalten unter Solo und ohne Solo |
| `testMoreSlotsThanBeforeConfigured` | erst `setAll` mit 5 Werten, dann mit 60: Slots 5 bis 59 tragen die neuen Werte, 60 bis 255 sind 1.0 |
| `testEmptyKeyUnderSoloBeyondSixteen` | leerer Schlüssel unter Solo ergibt 0.0 (D2), Schreiben auf einen Index über 16 ist unproblematisch |

Akzeptanz: Tests grün.
Commit: `test(AudioRouterKit): Solo und Lautstärke für Slots über 16 hinaus (W1)`

### NT-S9: Doku

Alle Texte nur mit Belegtem. Die Hörprüfung am Gerät steht aus (NM-1), das darf nicht als
Tatsache erscheinen.

**a) `CHANGELOG.md`**, Abschnitt `[4.1 (11)]`:
- Den Block `### Known limitation` (Z. 122 bis 133) vollständig entfernen.
- Unter `### Fixed` (nach dem Blip-Eintrag, vor `### Changed`) hinzufügen:

```markdown
- **Per-device volume, Solo and the level meters now cover every configured output.**
  Previously these controls were backed by a 16-slot bridge: outputs from the 17th on
  played at a fixed gain, ignored Solo and showed no level. The bridges are now sized
  for 256 slots and the wave header counts every output. The engine can route to up to
  255 configured outputs at once (plus the default output). Adding more is refused with
  a message in the panel, and a stored list that is too long is rejected at start with an
  error instead of silently degrading. The slot bridges and the limit are covered by
  unit tests.

- **The header wave no longer shrinks when Solo is active.** The wave previously
  averaged over all outputs while silenced outputs contributed zero, so soloing one of
  three equally loud outputs cut the wave to a third. The wave now ignores Solo; the level
  meters on the cards still show silence for silenced outputs.
```

**b) `RELEASE_NOTES.md`**, Abschnitt "AudioRouterNow 4.1 (Build 11), not yet submitted":
- Den Abschnitt `#### Known limitation: more than 16 outputs` (Z. 215 bis 224) entfernen.
- Unter "For Everyone" ergänzen: `#### Many outputs work like few` (Lautstärke, Solo und
  Pegelanzeige für jede Ausgabe, bis 255, darüber eine Meldung statt stillem Verhalten)
  und `#### The wave stays put under Solo`. Keine Aussage über ein gehörtes Ergebnis, nur
  über das Verhalten der Bedienelemente.

**c) `v4/ARCHITECTURE.md`**: Z. 91 `maxSlots * 2 = 32` ändern in
`OutputLimits.maxSlots * 2 = 512 Werte`; Z. 98 ("klemmt `slotCount` gegen `maxSlots`")
bleibt wahr. Zusatz: ein Satz zu `OutputLimits` als einziger Quelle der Kapazität.

**d) `docs/v4.1/09-final-report.md`**: neuen Abschnitt `## 9. Nachtrag: Slots und Welle
(Stand 2026-11-14)` am Ende anfügen (bestehenden Text nicht umschreiben). Inhalt: Anlass,
Verweis auf `14-plan-nachtrag.md`, Ergebnis je W1 und W2, Auflistung NT-D1 bis NT-D7, der
Hinweis, dass 6a (Welle durch alle Slots geteilt) und 6c (`maxSlots = 16`) durch den
Nachtrag überholt sind, und die neu gefassten Messpunkte:
- **M5 (neu):** Mehr als 16 Ausgaben. Ein virtuelles Gerät mit 64 Kanälen (32 Paare) plus
  ein Interface, mindestens 45 Zeilen. Lautstärke der 17. Ausgabe und einer Ausgabe jenseits
  der 32. verstellen. Solo auf der 1. Ausgabe, dann Solo auf der 17. und auf einer
  Ausgabe jenseits der 32. Erwartung: alle Ausgaben verhalten sich gleich, Solo schaltet
  die anderen stumm, Lautstärke wirkt. Optionales lokales Experiment für die Grenze:
  Konstante `OutputLimits.maxSlots` temporär auf 20 senken (nicht committen), bauen,
  19 Ausgaben wählen, eine weitere versuchen: Meldung erscheint, die Ausgabe wird nicht
  hinzugefügt. Danach zurückändern.
- **M9 (neu):** Meter und Welle unter Solo. Wie bisher: Meter der durch fremdes Solo stummen
  Karte zeigen 0. Neu: die Welle im Header bleibt unter Solo gleich hoch wie ohne Solo
  (gleiches Material, mehrere Ausgaben, Solo setzen, wechseln und aufheben).
- NM-1 bis NM-7 aus Abschnitt 7 dieses Plans übernehmen.

**e) `docs/v4.1/05-decisions.md`**: neuen Eintrag am Ende anfügen (Sprache der Datei:
Englisch), "D2: The header wave ignores Solo (supersedes D1 (wave) in
`05-plan-v2.md`)" mit Frage, Wahl (Solo-neutral, Meter unverändert), Begründung (Solo
schreibt `deviceGains` nie, daher exakt Solo-invariant), Rückfall (`SoloGain.effective` für
die Summe wiederherstellen) und dem Vermerk "Interpretation to be confirmed by the user".
Den bestehenden Eintrag D1 (Launch at Login) nicht ändern.

**f) `docs/v4.1/README.md`**: Eintrag für `14-plan-nachtrag.md` auf Fassung 2 aktualisieren
(Schritte NT-S0 bis NT-S10, Entscheidungen NT-D1 bis NT-D7), sowie `15-impl-nachtrag.md`
und `16-audit-nachtrag.md` nach Entstehung.

**g) Nur Hinweis an den Umsetzer, nicht committen (gitignored):** `BACKLOG.md` und
`docs/support/` lokal nachziehen: W1 erledigt, sobald die Hörprüfung bestanden ist;
mögliche Folgepunkte (Snapshot-Struktur falls NM-4 auffällig, `LazyVStack` für sehr lange
Listen falls NM-5 auffällig).

Akzeptanz: `grep -n "Known limitation" CHANGELOG.md RELEASE_NOTES.md` zeigt keinen Treffer
für den `maxSlots`-Absatz mehr (andere Treffer außerhalb 4.1 bleiben); neue Texte ohne
Gedankenstrich; keine Namen.
Commit: `docs(v4.1): Nachtrag Slots und Welle in CHANGELOG, RELEASE_NOTES, Bericht und Entscheidungen`

### NT-S10: Abschluss

1. `bash v4/scripts/test.sh` und App-Build, Ergebnis im Protokoll
   `docs/v4.1/15-impl-nachtrag.md` (pro Schritt Hash, Test, Build, Abweichungen, Stand der
   offenen Messpunkte) festhalten und committen.
2. `bash v4/scripts/preflight.sh`: erwartet unverändert 1 ABBRUCH (altes Archiv 4.0.1 (10)) und
   die bekannten Warnungen. Abweichung melden.
3. Unabhängiges Audit durch einen weiteren Fable-Agenten (Leitfaden Abschnitt 8), Entwurf
   früh speichern (`16-audit-nachtrag.md`).
4. Kein Push, kein Tag, keine Einreichung.

---

## 6. Risiken

- **R1 Echtzeitpfad (niedrig):** Der IOProc-Code ist unverändert. Geändert werden nur die
  Kapazität zweier Puffer (vorab in `init` alloziert) und die Slotzahl-Prüfung auf dem
  Kontroll-Thread. Restrisiko: `setAll` und `record` halten den Lock bei 256 statt 16
  Einträgen länger (Größenordnung 0,1 bis 0,3 µs, Schätzung, ungemessen).
- **R2 Lock-Kontention (niedrig):** 22 000 bis 192 000 Lock-Paare pro Sekunde bei 256 Slots
  (Abschnitt 2.3), gemessen 14,1 ns je Zugriff ohne Konkurrenz. Die Konkurrenz mit dem
  MainActor (Poll mit 20 fps liest je Tick 256 Pegel, jeweils ein Lock) ist nicht gemessen.
- **R3 Speicherübergabe (kein Risiko im Plan):** feste Konstante, kein Zeigerwechsel (NT-D3).
- **R4 Restart und Seed-Pfade (niedrig):** `reseedSlotGains` und `applySoloGains` laufen an
  vier Stellen (Start, Neustart, Output-Update, SR-Neustart) und sind nach NT-S3/NT-S4
  ohne Änderung korrekt für alle Slots (Lektüre, kein Test am Controller möglich).
- **R5 UI-Skalierung (mittel, ungeprüft):** `MenuBarView` baut die Liste mit `VStack` und
  `ForEach` ohne Lazy-Container (Z. 122 bis 141), `DeviceCardView` und die Paarzeilen
  (`ForEach(0..<pairCount)`) ebenso. Bei 128 Paaren eines Geräts mit 256 Kanälen plus
  Karten werden sehr viele Views erzeugt, der Poll in `MenuBarView` läuft alle 3 s. Die
  Antwortzeit ist nicht gemessen. Außerhalb des Scopes (CASE-003, gleicher View-Baum),
  daher als Messpunkt NM-5 und als möglicher Folgeschritt geführt.
- **R6 CoreAudio mit sehr vielen Buffern (ungeprüft):** Ob ein Aggregate mit 128 oder 256
  Kanalpaaren eines Geräts stabil taktet, ist nicht belegt. Die F5-Prüfung und der neue
  Startfehler fangen Abweichungen ehrlich ab, aber eine Systemgrenze unterhalb von 255
  wäre nur am Gerät sichtbar.
- **R7 Neuer `RouterError`-Fall (niedrig):** öffentliches Enum, erschöpfende `switch` in
  Fremdcode würden brechen. Im Repo gibt es keinen (Suche in NT-S1).
- **R8 Speicher (niedrig, belegt):** etwa 65 KiB je aktivem Slot, bei 256 Slots etwa
  16,6 MiB, allokiert beim Aufbau.
- **R9 Meldungszeile im `fixedSize`-Baum (niedrig, ungeprüft am Gerät):** NT-S7.
- **R10 Doku-Aussagen (niedrig):** ohne Hörprüfung dürfen CHANGELOG und RELEASE_NOTES nur
  Code- und Testaussagen machen (NT-S9).
- **R11 Testlage (niedrig):** neue Testdateien laufen nur über `test.sh` (SPM), nicht über
  das Xcode-Test-Target (`.pbxproj` nennt nur drei Testdateien). Das ist Bestand seit 4.1.

---

## 7. NUTZER MUSS MESSEN

Keine dieser Messungen kann ein Agent durchführen. Die Spalte "Ergebnis" bleibt leer.

| ID | Thema | Anleitung | Erwartung | Ergebnis |
|----|-------|-----------|-----------|----------|
| NM-1 | Hörprüfung mit mehr als 16 und mehr als 32 Ausgaben | Virtuelles Gerät mit 64 Kanälen (32 Paare) plus Interface (z.B. 10 Paare) plus Standardgerät, mindestens 45 Zeilen, Routing aktiv. Lautstärke einer Ausgabe ab der 17. und einer jenseits der 32. verstellen. Solo auf der 1. Ausgabe, dann auf der 17., dann auf einer jenseits der 32. | Jede Ausgabe reagiert auf Lautstärke, Solo schaltet alle anderen stumm, nach Aufheben gelten die gespeicherten Pegel | |
| NM-2 | Pegelanzeige ab der 17. Ausgabe | Wie NM-1, Karte der 17. und einer späteren Ausgabe aufklappen | Signal-Balken zeigen Pegel, unter fremdem Solo 0 | |
| NM-3 | Welle unter Solo | Mindestens drei Ausgaben, gleiches Material, Wellenhöhe ohne Solo ansehen, Solo setzen, Solo wechseln, Solo aufheben | Wellenhöhe bleibt gleich, nur die Karten-Meter ändern sich | |
| NM-4 | CPU-Last | Activity Monitor, CPU-Anteil von AudioRouterNow bei 16 und bei 45 oder mehr Slots über einige Minuten, wenn möglich bei kleinem IO-Buffer | Anstieg gering (Hochrechnung: etwa 1 Prozent des Callback-Budgets bei 256 Slots, synthetisch). Auffälligkeit melden (Aussetzer, Knacken) | |
| NM-5 | Bedienung der Liste bei sehr vielen Zeilen | Panel öffnen, scrollen, Regler ziehen, Karten aufklappen bei 45 oder mehr Zeilen, falls möglich bei einem Gerät mit 128 oder 256 Kanälen | Panel bleibt bedienbar, kein Absturz (CASE-003 beachten) | |
| NM-6 | Meldung bei Ausgabenlimit | Lokales Experiment: `OutputLimits.maxSlots` temporär auf 20 senken (nicht committen), bauen, 19 Ausgaben wählen, eine weitere versuchen | Meldung erscheint, Ausgabe wird nicht hinzugefügt, Layout bleibt heil. Danach Konstante zurücksetzen | |
| NM-7 | Speicher | Activity Monitor, Speicher bei 45 oder mehr Slots | Zuwachs im Bereich einiger MiB (Rechnung: etwa 65 KiB je Slot) | |

---

## 8. Audit-Leitfaden

Der unabhängige Auditor arbeitet diese Checkliste ab und führt Build und Tests selbst aus.

### 8.1 Build und Tests

```
bash ~/AudioRouterNow/v4/scripts/test.sh
cd ~/AudioRouterNow/v4 && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AudioRouterNow4.xcodeproj -scheme AudioRouterNow4 -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Erwartung: Zähler steigen gegenüber 59 swift-testing und 56 XCTest (mindestens ein neuer
swift-testing-Fall und die neuen XCTest-Fälle aus NT-S2, NT-S3, NT-S5, NT-S8), alles grün,
BUILD SUCCEEDED. Der Auditor nennt die tatsächlichen Zahlen.

### 8.2 Vollständigkeit von W1

- `grep -rn "maxSlots" v4/` (ohne `.build` und `.xcodeproj`): jede Fundstelle gehört zu
  `OutputLimits`, zu den Verweisen in `SlotGains`/`PeakMeters`, zu Tests oder Doku. Keine
  `16`, kein `where i < SlotGains.maxSlots`, kein `idx >= SlotGains.maxSlots`.
- `grep -n "Unity-Gain\|ignoriert" v4/AudioRouterKit/Sources/AudioRouterKit/FanOutEngine.swift`:
  keine Warn-Texte des alten stillen Verhaltens mehr.
- Jede Stelle aus Tabelle 2.1 abgehakt, auch `ARCHITECTURE.md`.
- Verhalten oberhalb der Kapazität: `addOutputConfig` ruft `OutputLimits.addDecision`, die
  Meldung ist in `MenuBarView` verdrahtet, `start` und `buildAndStartAggregate` prüfen vor
  `createTap` bzw. vor dem ersten CoreAudio-Aufruf. Kein Pfad, der bei Überschreitung still
  weiterläuft.
- Tests prüfen Index 16, 17, 31, 32, 100, 255 und die Grenze 256 selbst, Duplikat gegen
  Limit, `setAll` mit mehr Werten als Kapazität, `record` mit `slotCount` über der Kapazität.
- Der Auditor prüft, dass `SoloSlotRangeTests` ehrlich als Nachbildung beschrieben ist
  (kein Anspruch, den Controller zu testen).

### 8.3 Vollständigkeit von W2

- `updateWaveEnergy` ruft `WaveEnergyMath.soloNeutralLinear` ohne `soloedKeys`. `peakLevels`
  nutzt weiter `SoloGain.effective`. Kein Pfad führt `soloedKeys` in die Welle.
- Rechenprobe des Auditors: 3 Slots, gleicher Peak, Solo auf 1: Welle gleich wie ohne Solo;
  Solo-Gerät mit Gain 0,2: ebenfalls gleich.
- Der Auditor prüft die Auslegung (NT-D4) und ob die Unsicherheit klar als "zu bestätigen"
  markiert ist.

### 8.4 Echtzeit-Review

| Punkt | Prüfung |
|-------|---------|
| RT1 | `git diff` zeigt KEINE Änderung innerhalb von `makeDirectIOBlock` |
| RT2 | Keine neue Allokation, kein `Logger`, kein neuer Lock im IOProc; `os_unfair_lock` bleibt das einzige Primitiv in `SlotGains.swift` und `PeakMeters.swift` (`grep -n "pthread_mutex\|NSLock\|DispatchSemaphore"` ohne Treffer) |
| RT3 | `SlotGains.storage` und `PeakMeters.storage` werden einmal in `init` alloziert und im `deinit` freigegeben, kein Zeigerwechsel zur Laufzeit |
| RT4 | `lastSV` bleibt `slots.count` groß und wird vor `AudioDeviceStart` angelegt |
| RT5 | `updateWaveEnergy` läuft weiter im MainActor-Poll (`wavePollTask`), nicht im IOProc |
| RT6 | Der Messbeleg (14,1 ns, 117 µs bei 256 Slots) ist nachvollziehbar und als synthetisch gekennzeichnet; der Auditor darf ihn wiederholen (Kopie der `SlotGains.swift` plus eine kleine `main.swift` unter `/tmp`) |

### 8.5 CASE-004 und CASE-007

`slotAppliesVol`, `slotTargetSV`, `effectiveVolume`, Rampe, `VolumeTracker.swift` unverändert
(`git diff` leer für diese Symbole). `VolumeScalingTests` und `VolumeFreezeTests` grün.

### 8.6 Regression B1 bis B5 und F1 bis F4

| ID | Prüfung |
|----|---------|
| B1 | Meter unter Solo zeigen für stumme Karten 0: `SoloGain.effective` im `newPeaks`-Pfad vorhanden |
| B2 | RELEASE_NOTES enthalten keine Zusage "uninterrupted" für Blips ohne Hardware-Vorbehalt |
| B3 | `SoloGainTests` inklusive Test für leeren Schlüssel unter Solo unverändert grün |
| B4 | Launch-at-Login-Hinweise in CHANGELOG, RELEASE_NOTES und `06-appstore-texts.md` unverändert |
| B5 | `preflight.sh` unverändert: 1 ABBRUCH wegen altem Archiv, bekannte Warnungen |
| F1 | CHANGELOG-Blip-Eintrag ohne "uninterrupted" |
| F2 | Kommentar zu D1 in `EngineController.swift`: der alte Kommentar ist entfernt, der neue verweist auf NT-D4 und `14-plan-nachtrag.md` |
| F3 | War "Known-limitation zu `maxSlots`"; ist durch NT-D7 bewusst ersetzt. Der Auditor prüft, dass kein veralteter 16er-Hinweis in CHANGELOG, RELEASE_NOTES, `ARCHITECTURE.md` übrig ist und dass der neue Satz nur Belegtes behauptet |
| F4 | Bericht `09-final-report.md`: bestehende Abschnitte unverändert, Nachtrag nur angehängt |

### 8.7 Schreibstil und Datenschutz

Neue Texte ohne Gedankenstrich, Em-Dash, En-Dash (`grep -nP "\x{2014}|\x{2013}"`),
keine Namen oder E-Mails Dritter, keine Marketing-Inhalte, Umlaute korrekt, englische
UI-Texte im UI-Stil.

### 8.8 Scope

Nur die in 1.2 genannten Dateien geändert (`git diff --stat`), keine Änderung an
Entitlements, `project.yml`, `.pbxproj`, Versionsnummern, historischen Dokumenten 02 bis 13.

---

## 9. Zusammenfassung der Entscheidungen (ENTSCHEIDUNG NUTZER BESTÄTIGEN)

| ID | Inhalt | Bestätigung |
|----|--------|-------------|
| NT-D1 | Kapazität 256 (255 konfigurierbare Ausgaben plus Default-Slot), eine Konstante | bitte bestätigen (oder eine andere Zahl nennen) |
| NT-D4 | W2: Welle ignoriert Solo vollständig, Meter behalten die B1-Korrektur; ausdrücklich NICHT: Welle ohne Geräte-Gain | bitte bestätigen |
| NT-D5 | Oberhalb der Kapazität: Hinzufügen gesperrt mit Meldung, Startfehler bei zu langer gespeicherter Liste, Textvorschläge | bitte Sperre und Texte bestätigen |
| NT-D7 | Known-limitation entfällt, ersetzt durch Fixed-Eintrag mit Limit-Satz, nur Code- und Testaussagen | bitte bestätigen |
| NT-D2, NT-D3, NT-D6 | Locks unverändert, feste Konstante, Kit-Funktion mit Index-Arrays | Planerentscheidung, Rückfall dokumentiert |
