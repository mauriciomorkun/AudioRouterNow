# AudioRouterNow 4.1: Audit Nachtrag, Durchlauf 3

Auditor: Fable 5, unabhaengig. Datum: 2026-11-15.
Plan: `docs/v4.1/20-plan-nachtrag-v3.md` (Erstfassung `2ae52d9`, korrigiert in `2960723`).
Umsetzung: `docs/v4.1/21-impl-nachtrag-v3.md` (Commits `e2bcc93` bis `42081ff`).
Basis-Audit: `docs/v4.1/19-audit-nachtrag-v2.md` (Commit `77f0d1f`).
HEAD bei Auditbeginn: `42081ff`.

Stand: abgeschlossen.

---

## 1. Zusammenfassung

Testlauf, Build und Preflight erfolgreich (60 swift-testing + 96 XCTest gruen, BUILD SUCCEEDED,
1 ABBRUCH + 3 Warnungen, dritte Warnung ist der noch ungetrackte Entwurf dieses Dokuments).
Diff 77f0d1f..HEAD deckt genau 2 Produktivdateien plus Doku, kein Code-Delta ausserhalb der
geplanten Kommentarkorrekturen. H1 ist sauber behoben (Kommentar am HEAD korrekt, keine
Rechenfehler). H2 ist behoben (kein " -- " mehr im Testkommentar). H3 ist als akzeptierter Rest
dokumentiert (NT3-D3), die Begruendung traegt am Code. Suche nach weiteren Kommentarfehlern
in den seit dem Nachtrag-Beginn neuen Zeilen (`git diff 5dc55f5..HEAD -- v4/ | grep "^+"
| grep "//"`) ergibt keinen neuen Befund. Plan-Korrektur `2960723` ist konsistent. Kein Befund
hoch oder mittel.

---

## 2. Testlauf, Build und Preflight

Alle Befehle auf Branch `release/4.1`, HEAD-Commit `42081ff`.

### test.sh

```
bash ~/AudioRouterNow/v4/scripts/test.sh
```

Ergebnis: 60 swift-testing in 10 Suiten, 96 XCTest (`Executed 96 tests, with 0 failures (0
unexpected)`), alle gruen, 0 Fehler.
Plan-Erwartung: 60 swift-testing und 96 XCTest. Erfuellt.

### App-Build

```
cd ~/AudioRouterNow/v4 && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AudioRouterNow4.xcodeproj -scheme AudioRouterNow4 \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Ergebnis: BUILD SUCCEEDED.

### preflight.sh

```
bash ~/AudioRouterNow/v4/scripts/preflight.sh
```

Ergebnis: 1 ABBRUCH (letztes Archiv ist 4.0.1 (10), erwartet 4.1 (11)), 3 Warnungen
(v4-appstore/ vorhanden, Commits nicht gepusht, nicht committete Aenderungen). Die dritte
Warnung betrifft den noch ungetrackten Entwurf dieses Dokuments und war in Durchlauf 2 analog
beim Impl-Protokoll aufgetreten (`21-impl-nachtrag-v3.md` Abschnitt 3). Nach dem Commit dieses
Dokuments sind es wieder 2 Warnungen. Entspricht der Planerwartung.

---

## 3. Status H1 bis H3

### H1: Kommentarfehler "5120 Allokationen/s" (mittel, aus Audit v2)

**Geprueft am HEAD (`EngineController.swift` Z. 767-770):**

```swift
// NT2-D5: slotPeaks wird je Tick (MainActor, 20 Hz, kein IOProc) einmal angelegt:
// 20 Allokationen pro Sekunde, bei 256 Slots 5120 Element-Schreibzugriffe pro Sekunde
// (20 Hz x 256, keine Allokationen). Auf einem Mac vernachlaessigbar. Falls NM-4 einen
// messbaren Overhead zeigt: Instanzvariable plus removeAll(keepingCapacity: true).
```

Akkzeptanzpruefungen:

- `grep -n "5120 Allokationen"` in `EngineController.swift`: 0 Treffer. Bewiesen.
- `grep -n "20 Allokationen pro Sekunde"` in `EngineController.swift`: Treffer in Z. 768. Bewiesen.
- `grep -n "5120 Element-Schreibzugriffe"` in `EngineController.swift`: Treffer in Z. 768. Bewiesen.

Zahlencheck am Endfassung:

- 20 Allokationen/Sekunde: `var slotPeaks = []` erzeugt pro Tick eine Heap-Allokation;
  bei 20 Hz sind das 20/s. Korrekt.
- 5120 Element-Schreibzugriffe/Sekunde: 20 Hz x 256 Slots = 5120. Korrekt.
- "(20 Hz x 256, keine Allokationen)": `reserveCapacity(slots)` belegt Speicher einmalig
  fuer den Tick, die 256 `append`-Aufrufe erfordern keine neue Heap-Allokation. Korrekt.
- "kein IOProc": `updateWaveEnergy` ist eine `@MainActor`-Methode (Klasse ist `@MainActor`).
  Korrekt.

Nur der Kommentar wurde geaendert, kein Code-Delta. Bestaetig durch `git diff 77f0d1f..HEAD -- v4/`.

**Status: behoben, bewiesen.**

---

### H2: Doppelter Bindestrich " -- " im Testkommentar (niedrig, aus Audit v2)

**Geprueft am HEAD (`WaveEnergyMathTests.swift` Z. 29):**

```swift
// identisch, die Regressionsgarantie liegt in der Signatur der Funktion,
```

`grep -n " -- "` in `WaveEnergyMathTests.swift`: 0 Treffer. Bewiesen.
Test selbst (Z. 24-35): unveraendert, kein Code-Delta. Bestaetigt durch Diff.

**Status: behoben, bewiesen.**

---

### H3: `warmRestartForSampleRateChange` loescht `outputLimitNotice` nicht (niedrig, aus Audit v2)

**Entscheidung NT3-D3: akzeptiert ohne Code. Geprueft am Code:**

`warmRestartForSampleRateChange` (Z. 848-890): Erfolgsblock Z. 879-884 enthaelt kein
`outputLimitNotice = nil`. Bestaetigt.

Zuweisungen auf `outputLimitNotice` per `grep -n outputLimitNotice`:

| Zeile | Art |
|-------|-----|
| 100 | Deklaration `@Published` |
| 555 | `= OutputLimits.limitMessage(max:)` in `addOutputConfig` (`.limitReached`) |
| 558 | `= nil` in `addOutputConfig` (`.allowed`) |
| 568 | `= nil` in `removeOutputConfig` |
| 360 | `= nil` in `performStart` (Erfolgsblock) |
| 439 | `= nil` in `restartRouting` (Erfolgsblock) |

`warmRestartForSampleRateChange` taucht in dieser Liste nicht auf. Korrekt gemaess NT3-D3.

Tragfaehigkeit der Begruendung: `warmRestartForSampleRateChange` ruft `updateOutputs` mit
den unveraenderten `outputConfigs` auf (Z. 876). Es werden keine Ausgaben hinzugefuegt oder
entfernt. Mit 255 konfigurierten Ausgaben gilt die Meldung "Remove an output to add another"
danach unveraendert, ein neuer veralteter Zustand entsteht nicht. `addOutputConfig` sperrt
bei aktivem Routing nichts, es ruft `applyOutputsIfRouting()` auf; die Begruendung traegt
auch ohne eine solche Sperre, weil die Meldung zustandsunabhaengig korrekt bleibt
(Plan-Korrektur `2960723` geprueft, kein Widerspruch zwischen Entscheidung und Schritten).

**Status: akzeptierter Rest (NT3-D3), Begruendung traegt am Code, bewiesen.**

---

## 4. Befunde nach Schweregrad

### Hoch

Keine.

### Mittel

Keine.

### Niedrig

Keine neuen Befunde.

---

## 5. Abdeckungstabelle

| Feld | Status | Anmerkung |
|------|--------|-----------|
| 1. H1: Kommentar am HEAD korrekt | OK | Zahlen und Behauptungen geprueft: 20/s, 5120 Schreibzugriffe, kein IOProc. Nur Kommentar veraendert. Bewiesen. |
| 2. H2: kein " -- " im Testkommentar | OK | grep-Treffer 0. Test unveraendert. Bewiesen. |
| 3. H3: NT3-D3 traegt am Code | OK | warmRestartForSampleRateChange aendert outputConfigs nicht. Meldung zustandsunabhaengig korrekt. Plan-Korrektur `2960723` konsistent. Bewiesen. |
| 4. Weitere Kommentarfehler in neuen Zeilen | OK | `git diff 5dc55f5..HEAD -- v4/ | grep "^+" | grep "//"` vollstaendig gelesen. Zahlen und Aussagen geprueft. "RT-sicher" in SlotGains.gain korrekt (os_unfair_lock, kein Alloc, kein ARC im IOProc-Pfad). Kein neuer Befund. |
| 5. Regression und Hygiene | OK | Tests gruen (60/96). Diff 77f0d1f..HEAD deckt genau 2 Produktivdateien. FanOutEngine (makeDirectIOBlock) unveraendert (Diff 77f0d1f..HEAD leer). Wellenformel und Solo-Logik unveraendert. Keine neuen Dateien im App-Target (`git diff 77f0d1f..HEAD --name-only -- v4/AudioRouterNow4/` zeigt nur `EngineController.swift`). Kein Em-Dash, En-Dash oder " -- " in neuen `v4/`-Zeilen. Keine Namen oder E-Mails Dritter. Conventional Commits. Kein Push, kein Tag `v4.1`. grep "maxSlots" in Quelldateien: kein fester Wert 16. Arbeitsbaum: nur diese Datei ungetrackt. |
| 6. Doku-Endstand | OK | `09-final-report.md` Nachtrag-Abschnitt: Hashes stimmen mit `git log --oneline 5dc55f5..HEAD` ueberein, Befunde G1 bis H3 mit korrektem Status. Testzahlen 60 + 96 korrekt. Protokoll `21-impl-nachtrag-v3.md` konsistent (Hashes, Zahlen). `15-impl-nachtrag.md` Nachtrag-Abschnitt vorhanden. README listet 01 bis 21 (22 wird mit diesem Commit ergaenzt). CHANGELOG Z. 112-115 und RELEASE_NOTES Z. 218-220: Limit-Satz korrekt (255 konfigurierte Ausgaben, keine Uebertreibung). |
| 7. Gesamturteil Nachtrag | OK | W1 erfuellt (Kapazitaet 256, Limit sichtbar, Tests). W2 erfuellt (Wellenformel Solo-neutral, Signaturtest). Alle Befunde hoch oder mittel behoben oder nie vorhanden. Drei Durchlaeufe ausgeschoepft. |

---

## 6. Nicht pruefbar ohne Hardware (NM-1 bis NM-7)

Unveraendert gegenueber Audit v2. Keine Messung wurde von einem Agenten durchgefuehrt.

| ID | Thema |
|----|-------|
| NM-1 | Hoerpruefung: Lautstaerke, Solo und Pegel fuer Ausgaben ab Index 16 |
| NM-2 | Pegelanzeige ab der 17. Ausgabe |
| NM-3 | Welle unter Solo gleich hoch wie ohne Solo |
| NM-4 | CPU-Last bei 16 und 45+ Slots (auch slotPeaks-Schreib- und Allokationslast) |
| NM-5 | Panel-Bedienbarkeit bei sehr vielen Zeilen |
| NM-6 | Meldung bei Ausgabenlimit (fixedSize-Layout sauber); nach erfolgreichem Start verschwindet die Meldung (NT2-D2) |
| NM-7 | Speicher bei 45+ aktiven Slots |

---

## 7. Urteil

**Nachtrags-Zyklus abgeschlossen: ja.**

Begruendung: Alle Befunde mit Schwere mittel oder hoch sind behoben (G1, G2, H1). Alle
niedrigen Befunde sind behoben (G3, G4, H2) oder als akzeptierter Rest dokumentiert (H3
per NT3-D3). Die Verbotsliste wurde nicht verletzt. W1 und W2 sind erfuellt. Drei Durchlaeufe
wurden ausgefuehrt; das Limit ist ausgeschoepft.

### Restpunkte fuer den Nutzer (Empfehlung)

Die folgenden Punkte sind offen und benoetigen eine Entscheidung oder eine Aktion am Geraet.
Sie waren bereits vor dem Nachtrag bekannt und sind unveraendert.

| Punkt | Kategorie | Empfehlung |
|-------|-----------|------------|
| NM-1 bis NM-7: Messungen am Geraet | Hardware erforderlich | Vor der Einreichung durchfuehren; Ergebnisse in `09-final-report.md` Abschnitt 7 eintragen. Falls M8 (negativ) eintritt, Commit `5798a63` umkehren. |
| `EngineController` und `MenuBarView` ohne Test-Target | Bewusste Luecke | Jetzt akzeptieren. Fuer 4.2 erwaegen. |
| NT3-D3: `warmRestartForSampleRateChange` loescht `outputLimitNotice` nicht | Akzeptierter Rest | Jetzt bewusst akzeptieren (Meldung bleibt sachlich korrekt). Wenn unerwuenscht: `outputLimitNotice = nil` im Erfolgsblock von `warmRestartForSampleRateChange` (kein weiterer Audit-Durchlauf noetig, da reiner Verhaltenswunsch). |
| NT2-D1: Startfehlerpfad behaelt `outputLimitNotice` | Akzeptierter Rest | Jetzt bewusst akzeptieren. `errorSection` zeigt den Fehlertext, die Limit-Meldung ist nicht irrefuehrend. |
| `17-plan-nachtrag-v2.md` NT2-D5 enthaelt noch die falsche Zahl "5120 Allokationen/s" | Historisches Dokument | Bleibt unveraendert (historische Plan-Dokumente sind verboten zu aendern). Kein Handlungsbedarf. |
| Einreichungs-Nutzeraufgaben (Messungen, App Store Connect, Archiv, CHANGELOG-Datum, Tag, Merge, Push, Einreichung) | Nutzeraktion | Vollstaendige Liste in `09-final-report.md` Abschnitt 8 und in CLAUDE.md. |

---

## 8. Anhang: Einzelpruefung nach Plan-Checkliste (20-plan-nachtrag-v3.md, Abschnitt 6)

- [x] `git log --oneline -5` gelesen: Hashes 42081ff, 2960723, 63b4d04, b9faad8, e2bcc93.
- [x] `git diff 07bdfef..HEAD -- v4/`: genau 2 Produktivdateien, kein Code-Delta. Bewiesen.
- [x] "5120 Allokationen" in `EngineController.swift`: 0 Treffer. Bewiesen.
- [x] "20 Allokationen pro Sekunde" und "5120 Element-Schreibzugriffe": Treffer Z. 768. Bewiesen.
- [x] " -- " in `WaveEnergyMathTests.swift`: 0 Treffer. Bewiesen.
- [x] Build und test.sh selbst ausgefuehrt: 60 + 96 gruen. Bewiesen.
- [x] `warmRestartForSampleRateChange` Z. 879-884: kein `outputLimitNotice = nil` (NT3-D3 akzeptiert). Bewiesen.
- [x] Neue Kommentare geprueft: kein Zahlenfehler, keine unbelegte Behauptung. "RT-sicher" in SlotGains korrekt. Bewiesen.
- [x] Keine neuen Dateien im App-Target. Bestaetigt.
- [x] Kein Em-Dash, En-Dash, " -- " in neuen `v4/`-Zeilen. Bewiesen.
- [x] Kein Push, kein Tag. Bestaetigt.
