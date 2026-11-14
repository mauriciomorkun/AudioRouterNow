# AudioRouterNow 4.1: Nachtragsplan (Slots und Welle)

Erstellt: 2026-11-14 (Planer: Fable 5, Nachtrags-Zyklus nach Abschluss des
3-Durchlauf-Kreislaufs). Basis: `docs/v4.1/09-final-report.md` (Commit `b237cf0`),
vollstaendige Lektuere von `SlotGains.swift`, `PeakMeters.swift`, `SoloGain.swift`,
`FanOutEngine.swift`, `EngineController.swift`, `SlotGainsTests.swift`,
`SoloGainTests.swift`, `VolumeScalingTests.swift`, `05-plan-v2.md` (D1) und
den CASE-004/007 Feedback-Dateien. Status: Final (Planer-Lauf abgeschlossen, Baseline 59 swift-testing + 56 XCTest verifiziert).

---

## 1. Kopf

### 1.1 Ziel

Zwei Nutzerwuensche erfuellen:

**W1.** Lautstaerke, Solo, Pegelanzeige und Wellen-Energie sollen fuer ALLE
konfigurierten Ausgaben gleich funktionieren. Slots ab Index 16 werden heute
mit festem Unity-Gain gespielt, nicht stummgeschaltet, zeigen keinen Pegel und
fehlen in der Wellenenergie-Schleife. Das soll aufgehoert werden: entweder
echter Fix bis zur belegten Engine-Obergrenze, oder ehrliche, sichtbare
Begrenzung bei der Auswahl (kein stilles Degradieren).

**W2.** Die Welle im Header soll visuell nie durch Solo kleiner werden. Die
aktuelle Implementierung (Commit `cba4489`, Plan-v2-Entscheidung D1 Welle)
wendet `SoloGain.effective` auf `sum` an, sodass stumme Slots 0 beitragen
aber weiter im Divisor `Float32(slots)` stehen. Bei 1 von 3 Slots auf Solo
faellt `linear` auf ca. 0,33. Die Korrektur: `sum` und Division sollen
Solo-neutral werden (Quelle: Nutzerwunsch nach Abschlussbericht 2026-11-14).

### 1.2 Scope-Freeze (verbindlich)

**Enthalten:**
- W1: `SlotGains.swift`, `PeakMeters.swift`, `FanOutEngine.swift` (Stellen
  `setOutputGain`, `reseedSlotGains`, `buildAndStartAggregate` Warn-Block,
  Schleife `updateWaveEnergy` Z. 746), `EngineController.swift` (Schleife
  Z. 746 und Kommentare), Testdateien `SlotGainsTests.swift`, neue
  Kit-Testdatei fuer die Wellenformel, Doku (CHANGELOG, RELEASE_NOTES,
  `09-final-report.md`).
- W2: `EngineController.swift` (Schleife `updateWaveEnergy`), neue reine
  Funktion `WaveEnergyFormula` oder aehnlich in `AudioRouterKit` (neue
  Swift-Datei im Kit ist erlaubt, nicht im App-Target).

**Ausdruecklich ausgeschlossen:**
- Entitlements, Signing, `project.yml`, neues Archiv, Einreichung.
- Neue Dateien in `v4/AudioRouterNow4/` (Signierungsverlust durch XcodeGen).
- Consent-Mechanik (`ensureLoginItemCompliance`, `hasValidLaunchAtLoginConsent`).
- Jede Aenderung am IOProc-Timing, an `slotAppliesVol`, an der Settle-Freeze-
  Logik (CASE-004/007) und an der Rampe W1 (Zipper-Noise-Schutz).
- Historische Plan- und Audit-Dokumente `02-plan-v1.md` bis `13-doc-inventory.md`
  (kein Umschreiben der Vergangenheit).
- Push, Tag, Merge.
- Marketing-Inhalte.

### 1.3 Branch

`release/4.1`, Startpunkt Commit `b237cf0`.

### 1.4 Baseline

Verifiziert durch Audit v3 (Commit `5bf8d4f`) und bestaetigt durch diesen Planer
(Lektuere der Protokolle; keine eigenstaendige Testausfuehrung zum Zeitpunkt
der Planerstellung):

| Pruefung | Ergebnis |
|----------|----------|
| `bash v4/scripts/test.sh` | 59 swift-testing in 10 Suiten, alle gruen |
| XCTest (Framework AudioRouterKitTests) | 56 Faelle, alle gruen |
| App-Build (Debug, `CODE_SIGNING_ALLOWED=NO`) | BUILD SUCCEEDED |

App-Build-Befehl (unveraendert):

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

### 1.5 Leitplanken

Unveraendert aus Plan v2 (Abschnitt 1.5), zuzueglich:

- Der IOProc-Pfad wird fuer W1 veraendert (erster Echtzeiteingriff dieses
  Nachtragszyklus). Der Umsetzer prueft JEDEN Eingriff am RT-Pfad nach den
  Regeln in Abschnitt 2 (Entscheidungen NT-D2 und NT-D3).
- Kein Alloc im IOProc. Keine Swift-Container-Operationen, die allozieren.
  Kein ARC-Traffic. Kein Logging im heissen Pfad.
- `os_unfair_lock` bleibt das einzige Synchronisationsmittel fuer
  `SlotGains` und `PeakMeters`.
- CASE-004/007-Invariante: effektiver Faktor = `globalVol x slotGain`.
  `setDeviceGain` persistiert immer den Nutzerwert. Die Settle-Freeze-Logik
  in `VolumeTracker.swift` wird nicht beruehrt.
- Konventionelle Commit-Messages, Scope in Klammern.
- Kein Em-Dash, kein En-Dash, keine privaten Namen, keine E-Mails Dritter
  in neuen Inhalten.
- Keine Gedankenstriche im Sinne der Schreibstil-Konvention des Nutzers.
- Neue Swift-Dateien NUR im SPM-Package `AudioRouterKit`, nie in
  `v4/AudioRouterNow4/`.

---

## 2. Entscheidungen

### NT-D1: Echte Obergrenze der Engine (Beleg fuer W1)

**Frage:** Bis zu welcher Slot-Anzahl kann die Engine tatsaechlich arbeiten?

**Analyse am Code (verifiziert durch diesen Planer):**

Die einzige harte Grenze unterhalb von theoretisch-unendlich ist die
Speicherallokation von `lastSV` in `makeDirectIOBlock`:

```swift
var lastSV = [Float32](repeating: -1, count: slots.count)
```

Dieser Array wird auf dem Control-Thread vor `AudioDeviceStart` aufgebaut
(nicht im IOProc) und danach via Closure-Capture als uniquely-referenced
Heap-Box gebunden. Subscript-Mutation auf einem uniquely-referenced Array
alloziert nicht. Er waechst mit `slots.count`, das heisst: fuer beliebig
viele Slots wird korrekt genug Speicher vorab reserviert, SOLANGE der
Aufbau VOR `AudioDeviceStart` stattfindet (das ist der Fall, s. Zeile 648
bis 651: `makeDirectIOBlock` wird vor `AudioDeviceCreateIOProcIDWithBlock`
und `AudioDeviceStart` aufgerufen). Keine eigene Kapazitaetsgrenze.

`PeakMeters`: hat eigene `maxSlots = 16` und alloziert nur diesen Bereich.
`SlotGains`: hat eigene `maxSlots = 16` und alloziert nur diesen Bereich.
Beide werden vom IOProc gelesen/geschrieben. Sie sind die einzigen
kuenstlichen Grenzen.

CoreAudio Aggregate Devices: Apple dokumentiert keine harte numerische Grenze
fuer Sub-Devices. Die praktische Grenze liegt an USB-Bus-Bandbreite und
Sample-Rate-Matching, nicht an einer API-Konstante. BlackHole 64ch liefert
32 Stereo-Paare (64 Kanaele), was 32 Slots ergibt wenn alle Paare einzeln
konfiguriert werden, zueglich einem Interface-Slot = 33+. Eine KI-Schranke
bei dieser Anzahl ist nicht dokumentiert. Die Aussage "bis 32 Slots fuer
reale Konfigurationen plausibel" ist eine Annahme des Planers, unbewiesen.

**Feststellung:** Die echte Engine-Obergrenze fuer den IOProc-Pfad
(`slots.count`) ist NICHT 16. Sie ist durch `buildDirectOutputSlots` dynamisch
und durch den verfuegbaren RAM und die CoreAudio-Sub-Device-Grenze (undokumentiert,
in der Praxis >> 32) nach oben begrenzt. Die 16-Grenze stammt ausschliesslich
aus `SlotGains.maxSlots` und `PeakMeters.maxSlots`, also aus einer kuenstlichen
Softwareschranke.

**Belegter Stand:** `SlotGains.maxSlots = 16`, `PeakMeters.maxSlots = 16`
sind harte Schranken in vorab-alloziertem Speicher. Die IOProc-Schleife
ueber `slots` ist dagegen bereits uneingeschraenkt (laeuft ueber alle Slots,
unabhaengig von `maxSlots`). `lastSV` waechst mit `slots.count`. Daher ist
die Grenze kein fundamentales Limit des IOProc, sondern ein Artefakt der
festen Speichergroesse dieser zwei Klassen.

**Wahl:** `maxSlots` wird in beiden Klassen von 16 auf 32 angehoben. Begruendung:

1. 32 deckt alle in der Praxis belegten Konfigurationen ab (BlackHole 64ch
   = 32 Stereo-Paare, ein Interface darueber = 33; bei 33 waere die naechste
   Frage, ob CoreAudio ein Aggregate mit so vielen Sub-Devices aufbaut).
2. Speicher: `SlotGains` alloziert `maxSlots * 4` Byte = 128 Byte (vorher
   64). `PeakMeters` alloziert `maxSlots * 2 * 4` Byte = 256 Byte (vorher
   128). Triviale Erhoehung.
3. Jenseits von 32 ist kein reales Setup bekannt. Wenn der Nutzer dennoch
   mehr als 32 Ausgaben konfiguriert, zeigt die App ein LogWarning (wie
   bisher bei > 16). Statt stiller Unity-Gain-Degradierung soll ab
   Version NT-D1 jenseits von 32 ein NUTZER-SICHTBARER Hinweis in der UI
   erscheinen (Messpunkt NM-1 verifiziert das Verhalten).
4. Keine Aenderung am IOProc-Speicher-Modell: `lastSV` alloziert bereits
   exakt so viele Eintraege wie Slots, das bleibt unveraendert.

**ENTSCHEIDUNG NUTZER BESTÄTIGEN:** Soll die Obergrenze auf 32 gesetzt werden?
Falls der Nutzer mehr als 32 Slots benoetigt (kein bekanntes reales Szenario,
aber vorstellbar bei BlackHole 64ch + grossem Multi-Channel-Interface mit je
einem Kanal-Paar als Slot), ist NT-D1 vor der Umsetzung anzupassen.

**Rueckfall:** `maxSlots` auf 16 zuruecksetzen, Commit umkehren.

---

### NT-D2: Lock-Verhalten im IOProc nach NT-D1

**Frage:** Entstehen bei 32 Slots Lock-Kontentionen die einen Snapshot erfordern?

**Analyse:**

`SlotGains.gain(slotIndex:)` nimmt EINEN Lock pro Aufruf. Im IOProc wird
es fuer jeden Slot einmal aufgerufen: 32 Slots x 2 Lock-Ops (lock + unlock)
= 64 `os_unfair_lock`-Ops pro Callback. Bei 44,1 kHz und 512 Frames sind
das ca. 86 Callbacks/s, also ca. 5500 Lock-Ops/s. `os_unfair_lock` ist auf
Apple Silicon typisch < 20 ns (ungepruefte Schatzung des Planers), was
ca. 110 µs/s Summe ergibt (< 0,02 % CPU). Das ist eine Schatzung, nicht
gemessen. Fuer 32 Slots ist kein Snapshot noetig; der bestehende Lock
bleibt unveraendert. Bei einer deutlichen Erhohung ueber 32 waere ein
Snapshot lohnenswert, aber das liegt ausserhalb des Scope dieses Plans.

**Wahl:** Bestehender `os_unfair_lock`-Mechanismus bleibt unveraendert. Kein
Snapshot, kein neues Synchronisationsmuster. Begruendung: die erwiesene Null-
Allokations- und Null-ARC-Eigenschaft des bestehenden Musters ist wichtiger
als eine theoretische Optimierung.

**Rueckfall:** n/a (kein Eingriff).

---

### NT-D3: Speicher-Uebergabe bei Groessenaenderung von SlotGains/PeakMeters

**Frage:** Muss bei einer Groessenaenderung der vorab-allozierte Speicher
sicher an einen laufenden IOProc uebergeben werden?

**Analyse:**

`SlotGains` und `PeakMeters` werden beim Start der Engine einmalig als `let`-
Konstanten erstellt und via Closure-Capture an den IOProc-Block uebergeben.
Wenn `maxSlots` nur eine Konstante ist (nicht die Kapazitaet einer lebenden
Instanz), dann aendert sich das Speicher-Layout ausschliesslich beim Init,
also beim naechsten `buildAndStartAggregate`. Der IOProc-Block wird VORHER
durch `AudioDeviceStop` beendet, danach `AudioDeviceDestroyIOProcID`
aufgerufen, bevor neue Instanzen gebaut werden. Kein lebender IOProc zeigt
auf den alten Speicher. Eine dynamische Uebergabe ist nicht noetig.

**Wahl:** Statische Konstante `maxSlots` wird erhoht, keine dynamische
Allokation, keine Pointer-Uebergabe waehrend laufendem IOProc. Sicher.

---

### NT-D4: W2 - Auslegung des Nutzerwunsches (ENTSCHEIDUNG NUTZER BESTÄTIGEN)

**Frage:** Was genau bedeutet "die Welle soll visuell nie kleiner werden"?

**Auslegung des Hauptagenten (zu bestaetigen):** Solo darf die Wellenhoehe
gegenueber dem Zustand ohne Solo bei gleichem Audiomaterial nicht verringern.
Konkret: wenn bei N gleichlaut spielenden Slots ohne Solo die Welle auf Hoehe H
steht, dann darf H unter Solo eines beliebigen Slots nicht unter H fallen.

**Konsequenz dieser Auslegung:** Die Welle soll Solo-neutral sein. Die
einfachste Loesung ist, den gespeicherten Gain (`deviceGains[key]`) statt
`SoloGain.effective` fuer `sum` zu verwenden und den Divisor auf die
Gesamtzahl aller Slots zu belassen. Genau das ist der Zustand VOR Commit
`cba4489` (Plan v2 D1 Welle).

**Pruefung der Garantie "Solo aendert die Wellenhoehe nicht":**

Sei `sum_device = sum_i (raw_i * deviceGains[i] + raw_i * deviceGains[i]) / 2`
(also mit gespeichertem Gain, ohne Solo-Maskierung).

Faelle:
1. Solo-Geraet mit denselben Pegel wie alle anderen: `sum_device` ist identisch
   mit oder ohne Solo. Garantie erfullt.
2. Solo-Geraet ist LEISER als der Durchschnitt (Nutzerwert = 0,2):
   - Ohne Solo: `sum` schliesst alle Slots ein, Welle hoch.
   - Mit Solo: `sum` schliesst alle Slots ein (unveraendert), Welle hoch.
   - Garantie erfullt (Welle bleibt hoch, auch wenn das Solo-Geraet leise ist).
   - Fuer die METER-Anzeige der stummen Cards gilt: die Meter bleiben auf 0
     (B1-Korrektur aus `cba4489` bleibt erhalten, weil `peakLevels` weiterhin
     `SoloGain.effective` verwendet).
3. Solo-Geraet abgesteckt: `raw_i = (0, 0)` fuer diesen Key. `sum_device`
   sinkt, weil der Beitrag dieses Slots auf Null faellt. Die Welle sinkt.
   Das ist korrekt: es kommt weniger Audio an.
4. Alle Slots ausser einem auf Solo (d.h. einem Solo-Geraet folgen alle):
   `sum_device` ist identisch, Welle unveraendert. Garantie erfullt.

Problempotenzial bei "Division durch Anzahl hoerbarer Slots" (Alternative):
Wenn der Divisor auf die Anzahl aktiver (nicht-stummer) Slots reduziert wird,
ergibt sich: 1 Solo-Slot mit Pegel 0,5 bei sonst 3 Slots mit Pegel 0,8.
Ohne Solo: `(0,8+0,8+0,8+0,5)/4 = 0,725`. Mit Solo und Divisor nur Solo-
Slots: `0,5/1 = 0,5`. Welle SINKT. Garantie nicht erfullt. Dieser Ansatz
scheidet aus.

**Wahl:** `sum` mit `deviceGains[key]` berechnen (unveraendert von `SoloGain.
effective` zurueck auf den Nutzerwert), Divisor bleibt `Float32(slots)`. Die
Meter (B1-Korrektur) bleiben unveraendert (verwenden weiter `SoloGain.effective`).

**Ruckfall (wenn der Nutzer am Geraet feststellt, dass die Welle unter Solo zu
hoch wirkt):** Zeile in `updateWaveEnergy` auf `SoloGain.effective` zuruecksetzen,
in einem eigenen Commit (wie im Rueckfall von D1-Welle in Plan v2 beschrieben).

**Konsistenz mit W1:** Wenn `maxSlots` auf 32 angehoben wird, iteriert die
Schleife in `updateWaveEnergy` ueber Slots bis 32 statt 16. Die W2-Formel
(Summe aus `deviceGains`) ist davon unabhaengig korrekt.

---

### NT-D5: Neue Datei fuer die reine Wellenformel

**Frage:** Soll die Wellenformel als testbare Funktion in eine neue Kit-Datei
extrahiert werden?

**Kontext:** Plan v2 Leitplanke: neue Dateien im Kit sind unproblematisch, im
App-Target nicht (Signierungsverlust durch XcodeGen). Die Auslegung von W2
(D4) ergibt eine einfache Formel, die in `updateWaveEnergy` inline bleibt
(5 Zeilen). Eine Extraktion ist moeglich aber nicht zwingend fuer die
Korrektheit.

**Wahl:** Eine neue Datei `WaveEnergyMath.swift` im Kit mit einer reinen
Funktion `WaveEnergyMath.soloNeutralEnergy(peaks:deviceGains:keys:)` die den
linearen Mittelwert ohne Solo-Maskierung berechnet. Die Testdatei koennte
daneben `WaveEnergyMathTests.swift` heissen. `updateWaveEnergy` delegiert an
diese Funktion. Begruendung: die Erfahrung aus CASE-004 (zitiert im Kit-
Kommentar) zeigt, dass eine ungetestete Funktion im heissen Pfad Fehler
versteckt. Die Formel ist einfach genug, das Extrahieren dauert einen
Schritt; der Nutzen (Testbarkeit) ist hoch.

**Rueckfall:** Wenn der Umsetzer beim Extrahieren auf ein Typproblem stoesst
(z.B. Swift-Concurrency-Kompilierungsfehler), kann er die Formel inline in
`updateWaveEnergy` lassen und den Test direkt dort als Blackbox schreiben.
In diesem Fall kein neuer File im Kit.

---

### NT-D6: Behandlung von `applySoloGains` fuer Slots ab Index 16 nach NT-D1

**Frage:** Muss `applySoloGains` nach der NT-D1-Erhoehung angepasst werden?

**Analyse:** `applySoloGains` iteriert ueber `engine.slotDeviceKeys` (alle
Keys) und ruft `engine.setOutputGain` auf. `setOutputGain` prueft heute
`if idx >= SlotGains.maxSlots { return }` (Z. 196-199). Nach NT-D1 ist
`maxSlots = 32`, also werden Keys mit Slot-Index 16 bis 31 korrekt behandelt.
Die `reseedSlotGains`-Methode iteriert ueber `slotDeviceKeys` und ruft
`slotGains.setAll` auf, was bis `maxSlots` schreibt. Korrekt nach NT-D1.

**Wahl:** `applySoloGains` und `reseedSlotGains` benoetigen keine eigene
Aenderung, sie profitieren automatisch von der erhoehten `maxSlots`-Schranke.
Die Log-Warnung in `buildAndStartAggregate` Z. 598-599 wird auf `> 32`
angepasst (statt `> 16`).

---

## 3. Nummerierte Schritte

### NT-S0: Baseline verifizieren

**Datei:** keine Aenderung.

**Aktion:**

```bash
cd /Users/mauriciomorkun/AudioRouterNow
bash v4/scripts/test.sh
cd v4 && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AudioRouterNow4.xcodeproj \
  -scheme AudioRouterNow4 -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

**Akzeptanzkriterium:** 59 swift-testing + 56 XCTest gruen, Build SUCCEEDED.

**Test:** keine eigenen Tests, nur Baseline-Verifikation.

**Commit-Muster:** kein Commit fuer diesen Schritt.

---

### NT-S1: `SlotGains.maxSlots` von 16 auf 32 anheben (W1)

**Datei:** `v4/AudioRouterKit/Sources/AudioRouterKit/SlotGains.swift`

**Symbol/Zeile:** `public static let maxSlots = 16` (Z. 17 verifiziert).

**Aenderung:**

```swift
// vorher:
public static let maxSlots = 16

// nachher:
public static let maxSlots = 32
```

Keine weiteren Aenderungen in dieser Datei noetig: `storage` alloziert
`capacity: Self.maxSlots`, `setAll` iteriert `0..<Self.maxSlots`, `gain`
und `set` pruefen gegen `Self.maxSlots`. Alle Schranken passen sich
automatisch an.

**Begruendung:** Entscheidung NT-D1. Hebt die kuenstliche 16er-Grenze auf;
reale Konfigurationen bis 32 Ausgaben erhalten vollen Support.

**Speicherwirkung:** Vorab-Allokation steigt von 64 auf 128 Byte.

**Akzeptanzkriterium:** `SlotGains.maxSlots == 32` im Debugger lesbar.
Tests in `SlotGainsTests.swift` laufen gruen (sie benutzen `SlotGains.
maxSlots` als Schranke, passen sich automatisch an).

**Test:** Bestehende Tests passen sich automatisch an. Neue Tests in NT-S3.

**Commit-Muster:** `fix(SlotGains): maxSlots 16 -> 32 (NT-D1)`

---

### NT-S2: `PeakMeters.maxSlots` von 16 auf 32 anheben (W1)

**Datei:** `v4/AudioRouterKit/Sources/AudioRouterKit/PeakMeters.swift`

**Symbol/Zeile:** `static let maxSlots = 16` (Z. 24 verifiziert).

**Aenderung:**

```swift
// vorher:
static let maxSlots = 16

// nachher:
static let maxSlots = 32
```

Keine weiteren Aenderungen noetig: `storage` alloziert `maxSlots * 2`,
`record` klemmt `slotCount` gegen `maxSlots`, alle Bounds-Guards passen
sich an.

**Begruendung:** `PeakMeters.maxSlots` und `SlotGains.maxSlots` muessen
konsistent sein, da beide im IOProc benutzt werden und `peaks.record`
in `makeDirectIOBlock` Z. 1022 `slots.count` als `slotCount` uebergibt.
Nach NT-D1 ist `slots.count` potenziell > 16 und das `record` wuerde
die neuen Slots auf 0 klemmen, was die Pegelanzeige kaputt bricht.

**Speicherwirkung:** Vorab-Allokation steigt von 128 auf 256 Byte.

**Akzeptanzkriterium:** `PeakMeters.maxSlots == 32` lesbar. Build gruen.

**Test:** Neue Tests in NT-S3.

**Commit-Muster:** `fix(PeakMeters): maxSlots 16 -> 32 (NT-D1)`

---

### NT-S3: `EngineController.updateWaveEnergy`-Schleife auf neue maxSlots anpassen (W1)

**Datei:** `v4/AudioRouterNow4/EngineController.swift`

**Symbol/Zeile:** Schleife Z. 746 (verifiziert durch grep):
`for (i, key) in engine.slotDeviceKeys.enumerated() where i < SlotGains.maxSlots`

**Aenderung:** Die `where`-Bedingung entfernen. Der Vergleich ist nach NT-S1
entweder korrekt bis 32 oder eine unnotige Schranke. Wenn `slotDeviceKeys.count`
> 32 waere, wuerde die Engine bereits in `buildAndStartAggregate` eine Warnung
loggen; der Schleifenzugriff auf `peakLevel(slotIndex: i)` ist sicher, da
`PeakMeters.level(slotIndex:)` Out-of-range auf `(0, 0)` klemmt (Z. 58
in `PeakMeters.swift` verifiziert). Die `where`-Schranke war ein Workaround
fuer die 16er-Grenze; nach NT-D1 ist sie nicht mehr noetig.

```swift
// vorher (Z. 746):
for (i, key) in engine.slotDeviceKeys.enumerated() where i < SlotGains.maxSlots {

// nachher:
for (i, key) in engine.slotDeviceKeys.enumerated() {
```

**Begruendung:** Die Schleife laeuft nun ueber alle konfigurierten Slots.
Slots ab Index 32 (falls ueberhaupt vorhanden) erhalten sicher (0, 0) von
`peakLevel`, da `PeakMeters.level` clampt. Sie zaehlen damit mit Pegel 0
zur `sum` bei, was bei vielen Slots und echten Ausgaben vernachlaessigbar
ist. Kein Out-of-bounds.

**Akzeptanzkriterium:** Schleife laeuft ohne `where`. Build gruen.

**Test:** Neue Tests in NT-S4.

**Commit-Muster:** `fix(EngineController): remove maxSlots guard in updateWaveEnergy (W1)`

---

### NT-S4: Neue Datei `WaveEnergyMath.swift` und `WaveEnergyMathTests.swift` (W1 und W2)

**Datei (neu):** `v4/AudioRouterKit/Sources/AudioRouterKit/WaveEnergyMath.swift`

**Datei (neu, Test):**
`v4/AudioRouterKit/Tests/AudioRouterKitTests/WaveEnergyMathTests.swift`

**Warum eine neue Datei erlaubt:** Neue Swift-Dateien im SPM-Package
`AudioRouterKit` sind laut allen Plaenen (Plan v2 Abschnitt 1.5 und
Plan v1 Verbotsliste) ausdruecklich erlaubt. Die XcodeGen-Signierungsregel
gilt nur fuer `v4/AudioRouterNow4/`.

**Inhalt der neuen Funktion (vereinfachte Skizze, kein RT-Pfad):**

```swift
// WaveEnergyMath.swift
public enum WaveEnergyMath {

    /// Berechnet den linearen Mittel-Peak ueber alle Slots ohne Solo-Maskierung.
    /// Quelle: Nutzerwunsch W2 (Nachtrag 2026-11-14). Die reine Funktion liegt im
    /// Kit, damit sie aus dem Test-Target erreichbar ist (gleiches Muster wie
    /// SoloGain.effective, Begruendung in SoloGain.swift).
    ///
    /// - Parameters:
    ///   - peaks: IOProc-Peaks pro Key (l, r), einmal pro Poll-Tick gelesen.
    ///   - deviceGains: gespeicherte Per-Device-Gains [0...1].
    ///   - keys: Slot-Keys in Slot-Reihenfolge.
    /// - Returns: linearer Mittelwert [0...1], gegen 1.0 geklemmt.
    public static func soloNeutralLinear(
        peaks: [String: (l: Float32, r: Float32)],
        deviceGains: [String: Double],
        keys: [String]
    ) -> Float32 {
        guard !keys.isEmpty else { return 0 }
        var sum: Float32 = 0
        for key in keys {
            let p = peaks[key] ?? (l: 0, r: 0)
            let g = Float32(deviceGains[key] ?? 1.0)
            sum += (p.l * g + p.r * g) / 2
        }
        return min(1, sum / Float32(keys.count))
    }
}
```

**Aenderung in `EngineController.updateWaveEnergy`:** Die bestehende
Berechnung von `sum` und `linear` durch einen Aufruf von
`WaveEnergyMath.soloNeutralLinear` ersetzen. Der Meter-Pfad (B1-Korrektur
mit `SoloGain.effective` fuer `peakLevels`) bleibt unveraendert.

**Wichtig:** Die `newPeaks`-Befuellung (Z. 744 ff.) verwendet WEITERHIN
`SoloGain.effective` fuer die Meter-Korrektur. Nur die `sum`-Variable fuer
die Wellenenergie wird auf den gespeicherten Gain umgestellt.

**Konkrete Aenderung in `updateWaveEnergy` (Skizze):**

```swift
// Vorher (Z. 744-762, verifiziert):
var sum: Float32 = 0
for (i, key) in engine.slotDeviceKeys.enumerated() {   // nach NT-S3
    let raw = engine.peakLevel(slotIndex: i)
    let gain = SoloGain.effective(key: key, soloedKeys: soloedKeys, deviceGains: deviceGains)
    let p = (l: raw.l * gain, r: raw.r * gain)
    let prev = peakLevels[key] ?? (l: 0, r: 0)
    newPeaks[key] = (l: max(p.l, prev.l * 0.80), r: max(p.r, prev.r * 0.80))
    sum += (p.l + p.r) / 2
}
// ...
let linear = min(1, sum / Float32(slots))

// Nachher: Schritt 1 - Meter-Pfad bleibt (SoloGain.effective),
//          Schritt 2 - Wellenenergie-Pfad nutzt deviceGains direkt.
var rawPeaks: [String: (l: Float32, r: Float32)] = [:]
for (i, key) in engine.slotDeviceKeys.enumerated() {   // NT-S3: kein where
    let raw = engine.peakLevel(slotIndex: i)
    rawPeaks[key] = raw
    let gain = SoloGain.effective(key: key, soloedKeys: soloedKeys, deviceGains: deviceGains)
    let p = (l: raw.l * gain, r: raw.r * gain)
    let prev = peakLevels[key] ?? (l: 0, r: 0)
    newPeaks[key] = (l: max(p.l, prev.l * 0.80), r: max(p.r, prev.r * 0.80))
}
// W2 (NT-D4): Solo-neutrale Wellenenergie
let linear = WaveEnergyMath.soloNeutralLinear(
    peaks: rawPeaks, deviceGains: deviceGains, keys: engine.slotDeviceKeys)
```

**Kommentar im Code:** Der neue Kommentar soll explizit NT-D4 als Quelle
zitieren (analog zum D1-Welle-Kommentar, aber mit korrektem Verweis auf
diesen Plan):

```swift
// W2 (NT-D4, docs/v4.1/14-plan-nachtrag.md): Solo-neutrale Wellenenergie.
// SoloGain.effective gilt NICHT fuer sum: die Welle zeigt die Audio-Energie
// des Quellsignals nach Per-Device-Gain, unabhaengig vom Solo-Zustand.
// Meter (peakLevels) behalten SoloGain.effective (B1-Korrektur aus cba4489).
```

**Akzeptanzkriterium:** Funktion `WaveEnergyMath.soloNeutralLinear` existiert
und ist aus Tests erreichbar. `updateWaveEnergy` delegiert korrekt. Build gruen.

**Tests (neue Datei `WaveEnergyMathTests.swift`, XCTest):**

| Test | Was geprueft |
|------|--------------|
| `testNoSoloReturnsExpectedLinear` | 3 Slots, gleiche Peaks, kein Solo: Summe korrekt |
| `testSoloDoesNotChangeLinear` | 3 Slots, Solo auf Slot 1: Ergebnis identisch zum No-Solo-Fall |
| `testSoloedDeviceQuieterDoesNotChangeSumForOtherSlots` | Solo-Geraet hat Gain 0,2, Ausgleich ok |
| `testAbstractedDeviceZeroContrib` | Abgestecktes Geraet (peak 0,0): beitraegt korrekt 0 |
| `testEmptyKeysReturnsZero` | Leere Key-Liste: 0 |
| `testAllZeroGainsReturnZero` | Alle Gains 0: 0 |
| `testClampsAtOne` | Alle Slots auf Maximum: Ergebnis <= 1,0 |
| `testSlotAboveMaxSlotsIncludedInSum` | 33 Slots (Slot 32 als Index 32): Summe schliesst ihn ein |

**Commit-Muster:**
`feat(AudioRouterKit): WaveEnergyMath fuer Solo-neutrale Wellenenergie (W2, NT-D4)`,
`test(AudioRouterKit): WaveEnergyMathTests fuer soloNeutralLinear (W2)`

---

### NT-S5: `FanOutEngine.setOutputGain` Warnung und Log auf 32 anpassen

**Datei:** `v4/AudioRouterKit/Sources/AudioRouterKit/FanOutEngine.swift`

**Symbole/Zeilen (verifiziert durch grep):**

1. Z. 196-199: `setOutputGain` Warnung "ausserhalb SlotGains.maxSlots=16".
   Nach NT-S1 ist `SlotGains.maxSlots == 32`; die Warnung verwendet `\(SlotGains.
   maxSlots, privacy: .public)` dynamisch, passt sich also automatisch an.
   Kein Eingriff noetig.

2. Z. 598-599: `buildAndStartAggregate` Warn-Block
   `if slotDeviceKeys.count > SlotGains.maxSlots { logger.warning(...) }`.
   Diese Pruefschwelle passt sich automatisch an, da `SlotGains.maxSlots`
   dynamisch gelesen wird. Der Text "`Slots >= 16 spielen mit festem Unity-Gain`"
   ist nach NT-D1 veraltet. Der Log-Text wird auf "Slots ab Index N spielen mit
   Unity-Gain (NT-D1)" korrigiert, aber der Text ist nur in der Entwickler-
   Konsole sichtbar, kein User-facing String.

**Aenderung:** Nur den Log-String in Z. 599 aktualisieren. Keine Logik-Aenderung.

```swift
// vorher (Kern des Strings):
"Slots ≥ \(SlotGains.maxSlots, privacy: .public) spielen mit festem Unity-Gain (1.0)"

// nachher:
"Slots ab Index \(SlotGains.maxSlots, privacy: .public) ohne Per-Device-Gain (NT-D1)"
```

**Akzeptanzkriterium:** Log-String veraltet nicht mehr bei naechster maxSlots-
Erhoehung. Build gruen.

**Test:** kein eigener Test, Build-Verifikation reicht.

**Commit-Muster:** `fix(FanOutEngine): update warning log for new maxSlots (NT-D1)`

---

### NT-S6: Neue Kit-Testdatei fuer SlotGains und PeakMeters (W1-Tests)

**Datei:** Neue Assertionen in `SlotGainsTests.swift` und
`PeakMeters`-Tests (falls bereits eine Testdatei existiert; andernfalls Assertionen
in `SlotGainsTests.swift` ergaenzen, da keine eigene PeakMeters-Testdatei
gefunden wurde).

**Neue Tests fuer `SlotGains` (Erweiterung von `SlotGainsTests.swift`):**

| Test | Was geprueft |
|------|--------------|
| `testSlot16IsAccessibleAfterRaise` | Nach NT-S1: `sg.set(0.5, slotIndex: 16)` und `sg.gain(slotIndex: 16) == 0.5` |
| `testSlot31IsLastValid` | Slot 31 (neues Max - 1): setzen und lesen korrekt |
| `testSlot32IsOutOfRange` | Slot 32 (neues Max): `gain` liefert 1.0, `set` ist No-Op |
| `testSetAllWith20Elements` | `setAll` mit 20 Elementen: Slots 16-19 gesetzt, Rest Unity |

**Neue Assertionen fuer `PeakMeters` (neue Testklasse in
`SlotGainsTests.swift` oder eigene Datei nach Ermessen des Umsetzers):**

| Test | Was geprueft |
|------|--------------|
| `testSlot16RecordAndRead` | `record(l:0.5, r:0.3, slotCount:17)` und `level(slotIndex:16)` korrekt |
| `testSlot32IsOutOfRange` | `level(slotIndex:32)` liefert (0, 0) |

**Commit-Muster:**
`test(AudioRouterKit): SlotGains und PeakMeters Kapazitaetstests fuer maxSlots 32 (W1)`

---

### NT-S7: Doku anpassen (CHANGELOG, RELEASE_NOTES, Abschlussbericht-Nachtrag)

**Ziel:** Den Known-limitation-Absatz aus CHANGELOG und RELEASE_NOTES ueberarbeiten
(er nennt 16, das ist nach NT-D1 falsch) und im Abschlussbericht einen
Nachtrag-Abschnitt ergaenzen.

**Datei 1: `CHANGELOG.md`**

Den Absatz unter `### Known limitation` (Z. 122-132, verifiziert durch grep)
ersetzen durch:

```markdown
### Known limitation

- **Outputs beyond the first 32 do not respond to per-device volume or Solo.**
  The per-device volume controls and Solo both operate through a 32-slot gain
  bridge. Configured outputs beyond the 32nd (zero-based index 32 and above)
  play at a fixed gain of 1.0, regardless of the volume slider or Solo state.
  The engine logs a warning when more than 32 outputs are configured.
  Configurations reaching this limit require an unusually large number of
  simultaneously configured outputs; the most common large configuration
  (BlackHole 64ch combined with a multi-channel interface) stays well within
  the limit. The per-device volume limit was raised from 16 to 32 in this
  release (Build 11, Nachtrag).
```

**Datei 2: `RELEASE_NOTES.md`**

Den Absatz unter `#### Known limitation: more than 16 outputs` (Z. 215-224,
verifiziert) ersetzen durch:

```markdown
#### Known limitation: more than 32 outputs

The per-device volume controls and the Solo button both work through a fixed
32-slot gain bridge. If you have more than 32 outputs configured, the ones
beyond the 32nd (zero-based: index 32 and above) will not respond to the
volume slider or Solo; they play at full gain regardless. This limit was
raised from 16 to 32 in this update and covers all known real-world
configurations. The engine logs a warning to the system log when this limit
is exceeded.
```

**Datei 3: `docs/v4.1/09-final-report.md`**

Einen Nachtrag-Abschnitt am Ende ergaenzen (neuer Abschnitt "## 9. Nachtrag
Slots und Welle (2026-11-14)") mit:
- Verweis auf diesen Plan (`14-plan-nachtrag.md`).
- Zusammenfassung der Aenderungen (NT-D1 bis NT-D6).
- Aenderung Messpunkt M5 (Grenze war 16, ist jetzt 32).
- Messpunkt M9 (Welle unter Solo): bleibt sinnvoll, aber die Erwartung
  aendert sich: die Welle soll unter Solo NICHT kleiner werden.
- Hinweis auf offene ENTSCHEIDUNG NUTZER BESTÄTIGEN-Punkte (NT-D1, NT-D4).

**Commit-Muster:**
`docs(v4.1): Nachtrag Slots und Welle in CHANGELOG, RELEASE_NOTES, Abschlussbericht`

---

### NT-S8: README.md ergaenzen

**Datei:** `docs/v4.1/README.md`

Einen Eintrag fuer `14-plan-nachtrag.md` in der Inhaltstabell ergaenzen.

**Commit-Muster:** zusammen mit NT-S7 in einem einzigen Doku-Commit, oder
als eigenstaendiger Commit nach NT-S7.

---

## 4. Verbotsliste

Neben den Verboten aus Abschnitt 1.2 (Scope-Freeze) sind folgende Eingriffe
ausdruecklich verboten:

- Jede Aenderung an `ensureLoginItemCompliance`, `hasValidLaunchAtLoginConsent`,
  `launchAtLoginConsentBuildKey`, `launchAtLoginOptedInKey`.
- Jede Aenderung an `slotAppliesVol`, `computeSlotAppliesVol`, `effectiveVolume`
  oder `slotTargetSV` (CASE-004-Invariante).
- Jede Aenderung an der Rampe `svStep`, `lastSV`, W1-Zipper-Noise-Schutz.
- Jede Aenderung an `VolumeTracker.settleFreeze` oder verwandter Settle-Logik
  (CASE-007-Invariante).
- Neue Dateien in `v4/AudioRouterNow4/` (ausser der Kommentarkorrektur in
  `EngineController.swift`, die eine Aenderung in einer BESTEHENDEN Datei ist).
- Eingriffe in `project.yml`, `AudioRouterNow4.xcconfig` Versionsnummern,
  Entitlements, Signing-Zertifikate.
- Plan- und Audit-Dokumente `02-plan-v1.md` bis `13-doc-inventory.md` umschreiben.
- Marketing-Inhalte.
- Push, Tag, Merge.
- Allozierung im IOProc-Block.

---

## 5. Risiken

**R1 (Echtzeitpfad, mittel):** `SlotGains.gain` wird nun fuer bis zu 32 Slots
pro Callback aufgerufen. Das Lock-Verhalten wurde in NT-D2 bewertet und als
vertretbar eingestuft (Schatzung, nicht gemessen). Falls unter Last bei vielen
Slots Audio-Artefakte auftreten, Schritt NT-S1 evaluieren.

**R2 (Pegelanzeige, niedrig):** `PeakMeters.record` schreibt bis zu 32 Slots
(NT-S2). Slots ab Index 32, falls konfiguriert, werden auf 0 geklammert.
Das ist korrekt und war bei 16 genauso.

**R3 (Testdeckung, niedrig):** Slots > 16 koennen im Unit-Test nicht durch
echte CoreAudio-Callbacks getestet werden. Die Tests (NT-S3, NT-S6) pruefen
die Speicher-Logik, nicht die Audio-Ausgabe. Die Hoerrprobe am Geraet (NM-1)
ist der einzige Beleg fuer korrektes Audio.

**R4 (W2 Wellenenergie, niedrig):** Die Rueckkehr zu `deviceGains[key]` (vor
D1-Welle) wurde explizit als Rueckfallpfad in Plan v2 beschrieben. Die Welle
zeigt jetzt mehr Energie unter Solo als die tatsaechlich ausgegebene; ob das
den Nutzer verwirrt, ist ungepruefte Annahme.

**R5 (Seed-Pfad, niedrig):** `reseedSlotGains` und `applySoloGains` laufen
automatisch korrekt nach NT-D6. Wenn jedoch ein Warm-Restart zwischen NT-S1
(SlotGains aktualisiert) und NT-S2 (PeakMeters aktualisiert) stattfindet,
waere das Verhalten inkonsistent. Da beide Schritte in separaten Commits
stattfinden und es KEINEN Checkpoint zwischen ihnen gibt (der Umsetzer soll
beide in einer Sitzung ausfuehren), ist dieses Risiko vernachlaessigbar.
Sicherheitshalber: Schritt NT-S1 und NT-S2 in einem einzigen Commit
durchfuehren oder sehr schnell hintereinander committen.

---

## 6. Nutzer muss messen

Keine dieser Messungen kann von einem Agenten durchgefuehrt werden.

| ID | Thema | Pruefsanleitung | Erwartetes Ergebnis |
|----|-------|-----------------|---------------------|
| NM-1 | Lautstaerke und Solo fuer Slots 17+ | BlackHole 64ch + Interface, 17+ Paare konfiguriert. Slot 17 (Index 16) Lautstaerke verschieben, Solo setzen. Slot 1 (Index 0) solo setzen | Slot 17 reagiert auf Lautstaerke und Solo. Slot 1 auf Solo: Slot 17 verstummt |
| NM-2 | Pegelanzeige fuer Slots 17+ | Wie NM-1. Signal-Balken der Card von Slot 17 aufklappen | Pegelanzeige zeigt Pegel (nicht 0,0 wie bisher) |
| NM-3 | Welle unter Solo | Routing aktiv, 2+ Ausgaben. Solo eines Slots setzen | Welle bleibt genauso hoch wie ohne Solo (Nutzerwunsch W2 erfuellt) |
| NM-4 | CPU-Last bei 32 Slots | Wenn Hardware verfuegbar: 32 Ausgaben konfigurieren, Routing starten, Activity Monitor pruefen | Keine sichtbare CPU-Erhoehung gegenueber 16 Slots |

---

## 7. Audit-Leitfaden

Der unabhaengige Fable-Auditor prueft nach jedem Schritt Folgendes:

### 7.1 Build und Tests

```bash
bash /Users/mauriciomorkun/AudioRouterNow/v4/scripts/test.sh
```

Erwartetes Ergebnis: mindestens 59 swift-testing (Basistests unveraendert)
+ neue Tests = neue Gesamtzahl, alle gruen. XCTest-Anzahl steigt durch NT-S6
(mindestens 4 neue) und NT-S4 (mindestens 8 neue). App-Build SUCCEEDED.

### 7.2 Regressions-Checkliste

Jede der folgenden Eigenschaften muss unveraendert gelten:

| ID | Eigenschaft | Pruefmethode |
|----|-------------|--------------|
| B1 | Pegelanzeige unter Solo: stumme Slots zeigen 0 | `SoloGain.effective` weiterhin in `peakLevels`-Pfad vorhanden |
| B2 | RELEASE_NOTES-Formulierung korrekt | Grep auf "uninterrupted" in neuen Inhalten |
| B3 | Leerer Key unter aktivem Solo: 0.0 | `SoloGainTests` laufen gruen |
| B4 | Launch-at-Login-Reset dokumentiert | CHANGELOG und RELEASE_NOTES unveraendert |
| B5 | Preflight-Ergebnis unveraendert | Skript laufen lassen |
| F1 | CHANGELOG Blip-Eintrag ohne "uninterrupted" | Grep in CHANGELOG |
| F2 | Kommentar-D1-Praezision in EngineController | Grep auf "05-plan-v2.md" in EngineController |
| F3 | Known-limitation jetzt fuer 32 (nicht 16) | Grep auf "16" in Known-limitation-Abschnitt |
| F4 | Abschlussbericht Nachtrag-Abschnitt vorhanden | Datei lesen |

### 7.3 Echtzeit-Review

| Punkt | Was zu pruefen ist |
|-------|--------------------|
| NT-RT1 | Kein `alloc`, kein `malloc`, kein neues `UnsafeBuffer.allocate` im IOProc-Block | grep auf `allocate` in `makeDirectIOBlock` |
| NT-RT2 | `lastSV` wird vor `AudioDeviceStart` alloziert | Lektuere von `makeDirectIOBlock` und `buildAndStartAggregate` Reihenfolge |
| NT-RT3 | `SlotGains.gain` und `PeakMeters.level` verwenden `os_unfair_lock`, kein anderes Primitiv | grep auf `pthread_mutex\|DispatchSemaphore\|NSLock` in `SlotGains.swift` und `PeakMeters.swift` |
| NT-RT4 | Kein neues `Logger`-Aufruf im IOProc-Block (Logging alloziert) | Lektuere des modifizierten IOProc-Bereichs |
| NT-RT5 | `updateWaveEnergy` laeuft auf MainActor, nicht im IOProc | Annotation `@MainActor` in `EngineController` oder `wavePollTask` |

### 7.4 W2-Korrektheit

- `WaveEnergyMath.soloNeutralLinear` liest `deviceGains[key]`, nicht `SoloGain.effective`.
- `peakLevels`-Befuellung in `updateWaveEnergy` liest weiterhin `SoloGain.effective`.
- Kein Pfad verbindet `soloedKeys` mit `WaveEnergyMath.soloNeutralLinear`.

---

## 8. Abschlussschritte

Nach allen NT-S0 bis NT-S8 (in dieser Reihenfolge):

1. Vollstaendigen Testlauf (`bash v4/scripts/test.sh`) ausfuehren und Ergebnis
   im Implementierungsprotokoll (das der Umsetzer analog zu `11-impl-v3.md`
   erstellt) festhalten.
2. App-Build ausfuehren und Ergebnis festhalten.
3. Preflight ausfuehren:
   ```bash
   bash /Users/mauriciomorkun/AudioRouterNow/v4/scripts/preflight.sh
   ```
   Erwartetes Ergebnis: unveraendert (1 ABBRUCH wegen altem Archiv, 2 Warnungen).
4. `docs/v4.1/14-plan-nachtrag.md` als fertiggestellt markieren (Status-Zeile
   oben aendern).
5. `docs/v4.1/README.md` mit Eintrag fuer `14-plan-nachtrag.md` ergaenzen
   (NT-S8).
6. Doku-Commit laut NT-S7 und NT-S8.
7. Audit-Datei (neues Dokument `15-audit-nachtrag.md`) durch unabhaengigen
   Fable-Agenten erstellen lassen.
8. Bei Befunden ab Schwere mittel: Nachtrag-Zyklus wiederholen (maximal 2
   Wiederholungen, danach Nutzer informieren).
9. Kein Push, kein Tag, keine Einreichung ohne explizite Nutzeranweisung.

**BACKLOG und gitignored Doku:** `BACKLOG.md` und `docs/support/` sind
gitignored. Der Umsetzer soll dort die maxSlots-Erhoehung als erledigte
BACKLOG-Massnahme vermerken, aber nur als Information; die Hauptdoku
liegt in den committeten Dateien.

---

## 9. ENTSCHEIDUNGEN NUTZER BESTAETIGEN (zusammenfassend)

Vor der Umsetzung durch den Fable-Agenten soll der Nutzer folgende zwei
Entscheidungen bestaetigen:

**NT-D1:** `maxSlots` von 16 auf 32 anheben. Frage: Reicht 32 als Obergrenze?
(bekannte reale Maximal-Konfiguration: BlackHole 64ch (32 Paare) + Interface
= ca. 33 Slots; 32 wuerde einen Slot ausschneiden. Wenn alle 32 BlackHole-Paare
benoetigt werden: `maxSlots = 34` oder hoeher waehlen.)

**NT-D4:** Welle unter Solo bleibt unveraendert hoch (kein Absacken durch
stille Slots). Frage: Ist das der gewuenschte Effekt? (Konsequenz: die Welle
zeigt nicht mehr die effektiv ausgegebene Energie unter Solo, sondern die
Quelle nach Per-Device-Gain. Der Unterschied ist rein visuell.)
