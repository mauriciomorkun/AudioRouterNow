# AudioRouterNow 4.1: Audit Durchlauf 3

Auditor: Fable 5 (Durchlauf 3 des Fable/Opus/Fable-Kreislaufs, letzter Durchlauf)
Gepruefter Stand: Branch `release/4.1`, Commits `545f05e..HEAD`
(5 Commits: `4192a76`, `87fe856`, `36d50b1`, `6d681fc`, `70df541`)
Datum: 2026-11-13

---

## Zusammenfassung

Alle vier Nachbesserungspunkte F1 bis F4 sind korrekt umgesetzt. Tests (59 + 56),
Build und Preflight verhalten sich wie erwartet. Kein neuer mittlerer oder hoher
Befund. Ein niedriger Befund (E1) in der Dokumentation des Abschlussberichts
(Schrittanzahl ungenau); ein Beobachtungsvermerk (E2) zum fehlenden Commit-Hash
im Implementierungsprotokoll.

Urteil: **Kreislauf abgeschlossen: ja.**

---

## Testlauf und Build

### Testlauf

Befehl (selbst ausgefuehrt):

```
cd ~/AudioRouterNow/v4 && bash scripts/test.sh
```

Ergebnis:

```
Test run with 59 tests in 10 suites passed after 0.155 seconds.
Executed 56 tests, with 0 failures (0 unexpected) in 0.019 seconds
```

Gesamt: 59 swift-testing + 56 XCTest, alle gruen. Unveraendert gegenueber
Durchlauf 2.

### App-Build

Befehl (selbst ausgefuehrt):

```
cd ~/AudioRouterNow/v4 && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AudioRouterNow4.xcodeproj \
  -scheme AudioRouterNow4 -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Ergebnis: `** BUILD SUCCEEDED **`, keine neuen Warnungen.

### Preflight

Befehl (selbst ausgefuehrt):

```
bash ~/AudioRouterNow/v4/scripts/preflight.sh
```

Ergebnis:

```
1. Projektbaum
  WARNUNG v4-appstore/ existiert noch.

2. Version
  OK      xcconfig sagt 4.1 (11)
  OK      Keine zweite Versionsquelle im Projekt

3. Build-Nummer gegen vorhandene Tags
  OK      Tag v4.1 existiert noch nicht

4. Arbeitsbaum
  OK      Sauber
  WARNUNG Commits sind noch nicht gepusht

5. Berechtigungen (Release)
  OK      App Sandbox aktiv
  OK      Audio Input vorhanden

6. Letztes Archiv (falls vorhanden)
  Archiv: AudioRouterNow4 07-10-2026, 17.55.xcarchive
  ABBRUCH Archiv ist 4.0.1 (10), erwartet war 4.1 (11)

ERGEBNIS: 1 Abbruchgrund, 2 Warnung(en).
```

ERGEBNIS: 1 ABBRUCH (altes 4.0.1-(10)-Archiv), 2 Warnungen. Keine neuen Abbrueche
gegenueber Durchlauf 2. Arbeitsbaum sauber (erwartet: Entwurf dieser Datei
transient, nach Commit verschwindet die entsprechende Warnung).

---

## Status F1 bis F4

### F1: CHANGELOG Blip-Formulierung

**Status: behoben.**

Commit `4192a76` ersetzt "keeps running uninterrupted" durch
"keeps running on the same session" in `CHANGELOG.md` Z. 106.

Geprueft:

- `grep -n "keeps running uninterrupted" CHANGELOG.md`: kein Treffer im 4.1-Block.
- `grep -n "keeps running on the same session" CHANGELOG.md`: Treffer Z. 106.
- `grep -n "uninterrupted\|without interruption\|seamless\|no interruption\|no gap\|guaranteed" CHANGELOG.md RELEASE_NOTES.md docs/v4.1/06-appstore-texts.md`: keine Treffer
  im 4.1-Block von CHANGELOG oder in `06-appstore-texts.md`. RELEASE_NOTES Z. 193
  enthaelt "uninterrupted" als Teil des Hardware-Vorbehalts: "Whether audio stays
  audibly uninterrupted depends on the hardware and can only be confirmed on a real
  device." Das ist kein Versprechen, sondern eine explizit bedingte Aussage und
  entspricht der genehmigten Formulierung aus Commit `fd502c7` (Plan P3-D1).

Historische Eintraege (CHANGELOG Z. 355, RELEASE_NOTES Z. 464, Z. 745) enthalten
"uninterrupted" in den Abschnitten 4.0.0 und 4.0.1; diese sind unveraendert.

Code-Beleg (am Code geprueft, nicht nur gelesen): `DeviceLifecycleManager.swift`
Z. 271 bis 278. Bei `pendingRestart != nil` und Geraet-Rueckkehr innerhalb der
Settle-Frist wird `pendingRestart?.cancel()` und `pendingRestart = nil` aufgerufen;
die Engine laeuft ohne Neustart weiter. Das deckt die Aussage
"the engine keeps running on the same session" exakt ab.

Aeltere Versionseintraege unveraendert: `git diff 545f05e..HEAD -- CHANGELOG.md`
zeigt ausschliesslich Z. 106 und die neuen Known-limitation-Zeilen im 4.1-Block.

### F2: Kommentar-Praezisierung D1-Kollision

**Status: behoben.**

Commit `87fe856` aendert in `v4/AudioRouterNow4/EngineController.swift` Z. 752
genau eine Zeile: "Entscheidung D1 (Planer, 2026-11-13)" ersetzte durch
"Plan-v2-Entscheidung D1 (docs/v4.1/05-plan-v2.md)".

Geprueft:

- `git diff 545f05e..HEAD -- v4/` zeigt exakt eine Kommentarzeile geaendert,
  keine Logik, keine neue Zeile, kein neuer Import. Produktivcode unveraendert.
- Build nach diesem Commit: `** BUILD SUCCEEDED **` (im Protokoll P3-S2 und im
  abschliessenden Lauf bestaetigt, letzteres selbst ausgefuehrt).
- Mehrdeutigkeit aufgeloest: Der Verweis auf `docs/v4.1/05-plan-v2.md` macht
  den Bezug eindeutig; ein Leser, der im Repo nach "D1" sucht, sieht jetzt
  das richtige Dokument. `05-decisions.md` D1 (Launch-at-Login) und
  `05-plan-v2.md` D1 (Wellenenergie-Divisor) sind dadurch klar unterscheidbar.

### F3: Known-limitation-Absatz maxSlots

**Status: behoben.**

Commit `36d50b1` fuegt je einen Known-limitation-Block in CHANGELOG und
RELEASE_NOTES ein.

Geprueft:

Inhalt am Code verifiziert (selbst ausgefuehrt):

- `SlotGains.swift` Z. 17: `public static let maxSlots = 16` - bestaetigt.
- `PeakMeters.swift` Z. 24: `static let maxSlots = 16` - bestaetigt.
- `FanOutEngine.swift` Z. 196 bis 199: `setOutputGain` verwirft den Aufruf mit
  einer Log-Warnung, wenn `idx >= SlotGains.maxSlots`. Slots ab Index 16
  behalten ihren gespeicherten Gain (nicht 1.0 fix, sondern `outputGains[key]`
  aus dem `outputGains`-Dictionary, das bei Start mit 1.0 belegt wird). Da
  `setOutputGain` den `slotGains`-Schreibzugriff ueberspringt, bleibt der Slot
  auf dem letzten Wert, der in `slotGains` steht (Initialisierung 1.0 via
  `reseedSlotGains`). In der Praxis: Unity-Gain (1.0), weil kein anderer Pfad
  `slotGains.set` fuer diesen Index aufruft. Die Formulierung "play at a fixed
  gain of 1.0" ist sachlich korrekt.
- `FanOutEngine.swift` Z. 598 bis 599: `buildDirectOutputSlots` loggt eine Warnung
  bei `slotDeviceKeys.count > SlotGains.maxSlots`. Bestaetigt.
- Solo-Pfad: `EngineController.applySoloGains()` (Z. 503 bis 509) ruft fuer jeden
  Key in `slotDeviceKeys` `engine.setOutputGain(effective, forKey: key)` auf.
  `setOutputGain` verwirft den Aufruf fuer Slots ab Index 16. Damit wirkt Solo
  fuer die Ausgaben ab Index 16 nicht: sie spielen weiter mit Unity-Gain, unabhaengig
  davon, ob Solo aktiv ist. Die Aussage in CHANGELOG und RELEASE_NOTES ist korrekt.

Grenze seit 4.0 (geprueft): `git log -S "maxSlots" -- v4/AudioRouterKit/Sources/
AudioRouterKit/SlotGains.swift` liefert Commit `671f202`, der ein Vorfahre von
`v4.0.0` (6e32199) ist. Per-Device-Lautstaerke-Grenze existiert also seit v4.0.0.
Die Aussage "The per-device volume limit has been present since 4.0" ist korrekt.

Wortlaut: sachlich, kein Marketing, kein Superlativ, kein Gedankenstrich.

### F4: Korrekturen am Abschlussbericht

**Status: behoben (F4a bis F4e), ein niedrig-eingestufter Rest-Befund E1).**

Commit `6d681fc` korrigiert `docs/v4.1/09-final-report.md` in fuenf Punkten.

Geprueft:

- F4a (M5, 17 Ausgaben): M5-Tabelle nennt jetzt "17 konfigurierte Ausgaben" und
  Slot 17 (Index 16). Der Inkonsistenz-Hinweissatz entfernt. Korrekt.
- F4b (B4/B5-Zuordnung): Formulierung praezisiert ("das ist eine Vereinfachung fuer
  die Planungs-Perspektive..."). Korrekt.
- F4c (C2-Korrektur): Rechenbeispiel mit Verweis auf Audit 2 Abschnitt B1; der
  Widerspruchssatz entfernt. `08-audit-v2.md` Abschnitt B1 enthaelt das Beispiel
  "1 von 4 Slots, linear = 0.25". Korrekt.
- F4d (Zeilenfundstellen): Beide Fundstellen FanOutEngine.swift Z. 196-199 und
  Z. 598-599 genannt, "was ich nicht geprueft habe" entfernt. Am Code bestaetigt.
- F4e (Durchlauf-3-Ergaenzung): Sechste Aussage, Durchlaeufe-Tabelle Zeile 3,
  Befundliste F1 bis F4. Korrekt.

Befund E1 (niedrig, siehe Abschnitt "Befunde"):
Durchlaeufe-Tabelle Zeile 3, Spalte "Plan", beschreibt den Plan v3 als
"4 Schritte P3-S0 bis P3-S3 plus Bericht-Update P3-S4". Tatsaechlich hat der
Plan 6 Schritte (P3-S0 Baseline, P3-S1 bis P3-S4 Nachbesserung, P3-S5 README).
Die Angabe "4 Schritte... bis P3-S3" stimmt nicht; richtig waere
"6 Schritte P3-S0 bis P3-S5". P3-S5 (README-Update) fehlt in der Beschreibung.

---

## Befunde nach Schweregrad

### Hoch

Keine.

### Mittel

Keine.

### Niedrig

**E1 (niedrig): Schrittanzahl in Durchlaeufe-Tabelle ungenau**

- Datei: `docs/v4.1/09-final-report.md` Z. 134
- Beschreibung: Durchlaeufe-Tabelle Zeile 3 beschreibt Plan v3 mit
  "4 Schritte P3-S0 bis P3-S3 plus Bericht-Update P3-S4". Der Plan hat
  tatsaechlich 6 Schritte (P3-S0 bis P3-S5). P3-S5 (README-Update)
  fehlt. Die Zahl "4" ist falsch; die Schritte P3-S0 bis P3-S3 werden
  aufgezaehlt, aber P3-S4 als Sonderfall und P3-S5 fehlt komplett.
- Beleg: `10-plan-v3.md` grep nach `Schritt P3-S` liefert
  P3-S0, P3-S1, P3-S2, P3-S3, P3-S4, P3-S5 (6 Eintraege).
- Sicherheit: bewiesen.
- Korrekturvorschlag: "6 Schritte P3-S0 bis P3-S5" oder
  "P3-S0 bis P3-S5" ersetzen; alternativ die Stufung so wie bisher
  beibehalten aber korrekt zaehlen.
- Da dies der letzte Durchlauf ist: geht an den Nutzer (Empfehlung:
  jetzt in einem Folgecommit beheben oder bewusst akzeptieren; kein
  Einfluss auf Code, Build, Einreichung oder Nutzerwirkung).

### Beobachtungsvermerk

**E2 (Beobachtung, kein Befund): PLATZHALTER in `11-impl-v3.md`**

- Datei: `docs/v4.1/11-impl-v3.md` Z. 155
- Beschreibung: Zeile "Hash: PLATZHALTER-S5" wurde nicht durch den
  tatsaechlichen Commit-Hash `70df541` ersetzt. Der Commit existiert
  und enthaelt beide Aenderungen (README + dieses Protokoll).
- Sicherheit: bewiesen (selbst geprueft).
- Schweregrad: ausserhalb der Befundkategorien; rein dokumentarisch.
  Kein Einfluss auf Code, Tests oder Einreichung.
- Empfehlung: Hash `70df541` eintragen. Da letzter Durchlauf: geht
  an den Nutzer.

---

## Abdeckungstabelle

| Pruefeld | Geprueft | Ergebnis |
|----------|----------|---------|
| 1. F1 CHANGELOG/RELEASE_NOTES/06-appstore-texts.md | ja | kein Versprechen im 4.1-Block; Hardware-Vorbehalt-Formulierung korrekt; Code-Beleg bestaetigt |
| 2. F2 Kommentar-Praezisierung | ja | genau eine Kommentarzeile geaendert; Logik unveraendert; Build gruen |
| 3. F3 Known-Limitation maxSlots | ja | alle Code-Stellen am HEAD verifiziert; Aussagen in CHANGELOG und RELEASE_NOTES korrekt |
| 4. F4 Abschlussbericht | ja | F4a bis F4e korrekt; Rest-Befund E1 niedrig |
| 5a. Gedankenstriche/Dashes neu | ja | keine Em/En-Dashes in neuen Textteilen |
| 5b. Namen/E-Mails Dritter | ja | keine Drittparteien in neuen Inhalten gefunden |
| 5c. README 01 bis 12 | ja | alle Dateien aufgelistet; Beschreibungen korrekt |
| 5d. Consent-Funktionen/Echtzeitpfad | ja | unveraendert in `git diff` |
| 5e. Conventional Commits, kein Push, kein Tag | ja | alle Commits konform; kein v4.1-Tag; Arbeitsbaum sauber |
| 5f. Version 4.1/Build 11 nur in xcconfig | ja | bestaetigt |
| 5g. Abschnitte 4.1-Release-Texte konsistent | ja | Solo, ScrollView, SR-Listener, Blip, Launch-at-Login, Known limitation alle korrekt |
| 6. Eigensuche | ja | keine zusaetzlichen Befunde gefunden |

---

## Nicht pruefbar ohne Hardware (unveraendert M1 bis M9)

| ID | Thema |
|----|-------|
| M1 | ScrollView maxHeight 400 pt visuell korrekt |
| M2 | Header-Toggle steuert Routing korrekt |
| M3 | Solo ohne Knacksen oder Lautstaerkesprung |
| M4 | Solo bei abgestecktem Geraet |
| M5 | 17 Ausgaben konfiguriert; Slot 17 (Index 16) nicht stummschaltbar |
| M6 | Noop-Rate des SR-Listeners niedrig |
| M7 | Warm-Restart bei echtem Rate-Wechsel |
| M8 | Blip-Absorption: Audio kuerzer oder nicht unterbrochen |
| M9 | Wellenform unter Solo: Pegelanzeige der stummen Slots auf 0 |

---

## Restbefunde fuer den Nutzer

Die folgenden Punkte koennen nicht im Kreislauf behoben werden (letzter
Durchlauf erreicht) und gehen an den Nutzer:

1. **E1 (niedrig, bewiesen):** `09-final-report.md` Z. 134, Schrittanzahl
   fuer Plan v3 auf "4" beziffert statt korrekt auf "6"; P3-S5 fehlt in
   der Beschreibung. Empfehlung: in einem Folgecommit korrigieren.
   Kein Einfluss auf Build oder Einreichung.

2. **E2 (Beobachtung):** `11-impl-v3.md` Z. 155, Hash "PLATZHALTER-S5"
   nicht durch `70df541` ersetzt. Empfehlung: in einem Folgecommit
   ersetzen. Kein Einfluss auf Build oder Einreichung.

3. **M1 bis M9 (Messungen):** Alle neun Messpunkte stehen offen und
   koennen nur am Geraet verifiziert werden. Besonders relevant vor
   der Einreichung: M8 (Blip-Absorption), M3/M9 (Solo ohne Knacksen,
   Wellenform), M5 (maxSlots-Grenze mit 17 Ausgaben). M8 ist
   Rueckfall-Trigger: schlaegt es negativ aus, ist Commit `5798a63`
   umzukehren.

---

## Urteil

**Kreislauf abgeschlossen: ja.**

Alle vier Nachbesserungspunkte F1 bis F4 aus Plan v3 sind korrekt umgesetzt
und am Code belegt. Tests (59 swift-testing + 56 XCTest) und App-Build
(Debug, `CODE_SIGNING_ALLOWED=NO`) sind gruen. Preflight meldet 1 ABBRUCH
wegen des fehlenden neuen Archivs (unvermeidbar bis zur Einreichung) und
2 Warnungen (unveraendert). Kein Produktivcode, kein Echtzeitpfad, keine
Consent-Mechanik wurde beruehrt. Kein Push, kein Tag, kein Merge.

Verbleibende Befunde sind niedrig (E1: Dokumentationsfehler) oder eine
Beobachtung (E2: fehlender Hash). Beide ohne Einfluss auf Code, Build oder
Einreichung. Die offenen M1 bis M9 sind Nutzeraufgaben und waren in allen
Durchlaeufen als nicht maschinell pruefbar klassifiziert.

Die naechsten Schritte bis zur Einreichung liegen beim Nutzer:

1. Optional: E1 und E2 in einem Folgecommit korrigieren.
2. Neues Archiv (Build 11) in Xcode erstellen, signieren und notarisieren.
3. Messpunkte M1 bis M9 am Geraet verifizieren (mindestens M8, M3, M9 vor Einreichung).
4. App Store Connect: "What's New" aus `06-appstore-texts.md` eintragen,
   Store-Description-Superlativ ersetzen (Abschnitt 3).
5. Tag `v4.1` setzen, Branch mergen, pushen.
