# AudioRouterNow 4.1: Mini-Plan Nachtrag, Durchlauf 3

Planer: Fable 5. Datum: 2026-11-15.
Basis: Audit `docs/v4.1/19-audit-nachtrag-v2.md` (Commit `77f0d1f`), Befunde H1 bis H3.
Vorgaenger: `17-plan-nachtrag-v2.md`, `18-impl-nachtrag-v2.md`.

---

## 1. Scope

Drei Befunde, alle aus Audit `19-audit-nachtrag-v2.md`:

| ID | Schwere | Datei | Massnahme |
|----|---------|-------|-----------|
| H1 | mittel | `v4/AudioRouterNow4/EngineController.swift`, Z. 767-769 | Kommentar korrigieren: "5120 Allokationen/s" ist falsch (richtig: 20 Allokationen/s) |
| H2 | niedrig | `v4/AudioRouterKit/Tests/AudioRouterKitTests/WaveEnergyMathTests.swift`, Z. 29 | Doppelten Bindestrich " -- " entfernen |
| H3 | niedrig | `v4/AudioRouterNow4/EngineController.swift`, Z. 879-883 | Entscheidung pruefen, kein Code |

Ausserdem: neue Kommentare per `git diff 5dc55f5..HEAD -- v4/ | grep "^+" | grep "//"` auf weitere
Zahlenfehler pruefen.

Kein Verhalten wird geaendert. Keine neuen Dateien im App-Target.

---

## 2. Entscheidungen

### NT3-D1: H1 Kommentartext

Der Audit schlaegt vor:

```swift
// NT2-D5: slotPeaks wird je Tick einmal angelegt (MainActor, 20 Hz, kein IOProc).
// 1 Heap-Allokation/Tick (256 Elemente, ~2 KiB, kurzlebig), auf einem Mac vernachlaessigbar.
// Falls NM-4 einen messbaren Overhead zeigt: Instance-Variable + removeAll(keepingCapacity: true).
```

Dieser Text ist korrekt und im Projektstil. Er wird unveraendert uebernommen.
Begruendung: `reserveCapacity(slots)` belegt Speicher einmalig fuer den Tick;
die 256 `append`-Aufrufe belegen keinen neuen Heap-Speicher. 20 Hz x 1 Allokation = 20/s, nicht 5120/s.

### NT3-D2: H2 Ersatz fuer " -- "

Ersatz: Komma. Ergebnis: "identisch, die Regressionsgarantie liegt..."
Kein Gedankenstrich, kein Semikolon (wuerde den Satz staerker trennen als noetig).

### NT3-D3: H3 akzeptiert ohne Code

`warmRestartForSampleRateChange` loescht `outputLimitNotice` nicht. Die Meldung
lautet "Remove an output to add another." Nach einem SR-Warmrestart hat der Nutzer
weiterhin 255 Ausgaben konfiguriert; die Meldung ist also sachlich korrekt.
Sie ist nicht falsch und nicht irrefuehrend: Der Nutzer kann immer noch keine weitere
Ausgabe hinzufuegen, ohne eine zu entfernen. Der SR-Warmrestart aendert die Zahl der
konfigurierten Ausgaben nicht.

NT2-D2 gilt auch fuer diesen Pfad: `addOutputConfig` sperrt das Hinzufuegen waehrend
aktiven Routings, daher kann die Meldung nach einem Warm-Restart nicht erneut gesetzt
werden. Die Meldung laeuft weiter, was unschoen ist, aber den Nutzer nicht in die
Irre fuehrt. Kein Code-Fix. Entscheidung: als akzeptierter Rest dokumentieren
(NT3-D3), Verweis in `21-impl-nachtrag-v3.md` und `09-final-report.md`.

---

## 3. Schritte

| Nr. | Schritt | Datei | Commit-Typ |
|-----|---------|-------|-----------|
| N3-S0 | Diesen Plan schreiben, README ergaenzen | docs | `docs(v4.1)` |
| N3-S1 | H1 beheben: Kommentar korrigieren | EngineController.swift | `docs(EngineController)` |
| N3-S2 | H2 beheben: " -- " durch Komma ersetzen | WaveEnergyMathTests.swift | `docs(WaveEnergyMathTests)` |
| N3-S3 | H3: kein Code, Entscheidung in Impl-Protokoll dokumentieren | docs | Teil von N3-S4 |
| N3-S4 | Doku nachziehen: 21-impl-nachtrag-v3.md, 09-final-report.md Nachtrag-Abschnitt, README | docs | `docs(v4.1)` |

Nach N3-S1 und N3-S2 je: Build und `v4/scripts/test.sh` (erwartet 60 + 96 gruen).

---

## 4. Verbotsliste

- Echtzeitpfad (IOProc), Entitlements, Signierung, Consent, Settle-Freeze
- Neue Dateien im App-Target
- Wellenformel, Solo-Logik
- Bestehende Kommentare ausser den genannten aendern
- Historische Plan- und Audit-Dokumente 02 bis 19
- Push, Tag, Einreichung
- Namen oder E-Mails Dritter
- Gedankenstrich (Em-Dash, En-Dash) und " -- " in neuen Texten

---

## 5. Akzeptanzkriterien

Nach Abschluss muss jeder der folgenden Tests gruen sein:

```bash
# H1: Alte Zahl nicht mehr vorhanden
grep -n "5120 Allokationen" /Users/mauriciomorkun/AudioRouterNow/v4/AudioRouterNow4/EngineController.swift
# erwartet: kein Treffer

# H1: Neue Aussage vorhanden
grep -n "20 Hz" /Users/mauriciomorkun/AudioRouterNow/v4/AudioRouterNow4/EngineController.swift
# erwartet: Treffer in Zeile ~767-769

# H2: Doppelter Bindestrich nicht mehr vorhanden
grep -n " -- " /Users/mauriciomorkun/AudioRouterNow/v4/AudioRouterKit/Tests/AudioRouterKitTests/WaveEnergyMathTests.swift
# erwartet: kein Treffer

# Tests gruen
bash /Users/mauriciomorkun/AudioRouterNow/v4/scripts/test.sh
# erwartet: 60 swift-testing + 96 XCTest, alle gruen

# Build gruen
cd /Users/mauriciomorkun/AudioRouterNow/v4 && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AudioRouterNow4.xcodeproj -scheme AudioRouterNow4 \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
# erwartet: BUILD SUCCEEDED
```

---

## 6. Audit-Leitfaden fuer den letzten Auditor

Dieser Leitfaden richtet sich an den unabhaengigen Fable-Auditor nach Durchlauf 3.

**Pflicht:**
1. `git log --oneline -5` auf `release/4.1` lesen, Hashes pruefen.
2. `git diff 07bdfef..HEAD -- v4/` lesen: genau 2 Produktivdateien plus Doku, kein Code-Delta.
3. `EngineController.swift` Z. ~767-769: "5120 Allokationen" darf nicht vorkommen, "20 Hz" muss vorkommen.
4. `WaveEnergyMathTests.swift` Z. ~29: " -- " darf nicht vorkommen.
5. Build und `v4/scripts/test.sh` selbst ausfuehren: 60 + 96 gruen.
6. `warmRestartForSampleRateChange` Z. ~879-883: kein `outputLimitNotice = nil` im Erfolgsblock (NT3-D3 akzeptiert).
7. Neue Kommentare `git diff 5dc55f5..HEAD -- v4/ | grep "^+" | grep "//"` auf weitere Zahlenfehler pruefen.
8. Keine neuen Dateien im App-Target (`git diff 07bdfef..HEAD --name-only -- v4/AudioRouterNow4/`).
9. Kein Em-Dash, kein En-Dash, kein " -- " in neuen Zeilen.
10. Kein Push, kein Tag, kein Arch-Verzeichnis geaendert.

**Urteil erwartet:** Nachtrags-Zyklus abgeschlossen: ja oder nein (bei neuem Befund mittel oder hoch: nein).
