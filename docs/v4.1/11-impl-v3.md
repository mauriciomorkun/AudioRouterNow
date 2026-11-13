# AudioRouterNow 4.1: Umsetzungsprotokoll v3

Umsetzer: Opus (Durchlauf 3 des Fable/Opus/Fable-Kreislaufs, letzter Durchlauf)
Plan: `docs/v4.1/10-plan-v3.md` (Commit `545f05e`)
Branch: `release/4.1`
Datum: 2026-11-13

---

## Baseline (P3-S0)

- Arbeitsbaum sauber, HEAD `545f05e` (der Plan-Commit; der Plan nennt als
  Startpunkt `14a6417`, der Plan-Commit `545f05e` liegt eine Position darueber
  und beruehrt nur das Plandokument, deshalb keine Abweichung fuer den Scope).
- `bash v4/scripts/test.sh`: 59 swift-testing in 10 Suiten, alle gruen.
- XCTest im selben Lauf: 11 + 6 + 8 + 7 + 9 + 15 = 56 Faelle, 0 Fehler.
- App-Build (Debug, `CODE_SIGNING_ALLOWED=NO`): `** BUILD SUCCEEDED **`.

Ergebnis: Baseline bestaetigt, kein Commit (reine Verifikation).

---

## P3-S1: CHANGELOG Blip-Formulierung (F1)

**Status:** erledigt.

Datei `CHANGELOG.md` Z. 106, nur diese eine Zeile geaendert:
"keeps running uninterrupted" ersetzt durch "keeps running on the same session".
Der Hardware-Vorbehalt bleibt laut Plan P3-D1 nur in RELEASE_NOTES.md.

grep-Akzeptanztest:
- `grep "keeps running uninterrupted" CHANGELOG.md`: kein Treffer.
- `grep "keeps running on the same session" CHANGELOG.md`: Treffer Z. 106.

Build/Tests: nicht noetig (kein Swift-Code beruehrt).

Commit: `docs(changelog): describe blip session behaviour without hardware claim (F1)`
Hash: 4192a76

Abweichungen/Luecken: keine.

---

## P3-S2: Code-Kommentar D1 praezisieren (F2, C1)

**Status:** erledigt.

Datei `v4/AudioRouterNow4/EngineController.swift` Z. 752, nur diese Zeile:
"Entscheidung D1 (Planer, 2026-11-13)" ersetzt durch
"Plan-v2-Entscheidung D1 (docs/v4.1/05-plan-v2.md)". Z. 751 und 753 bis 755
unveraendert (am Code geprueft). Kein Logikwechsel, kein neuer Import.

grep-Akzeptanztest:
- `grep -n "Plan-v2-Entscheidung D1" EngineController.swift`: Treffer Z. 752.
- `grep -n "Entscheidung D1 (Planer" EngineController.swift`: kein Treffer.

Build/Tests: App-Build `** BUILD SUCCEEDED **`; `test.sh` 59 swift-testing +
56 XCTest, alle gruen (unveraendert zur Baseline).

Commit: `docs(engine): qualify D1 comment to reference 05-plan-v2.md (F2, C1)`
Hash: 87fe856

Abweichungen/Luecken: keine.

---

## P3-S3: Known-Limitation-Absatz (F3)

**Status:** erledigt.

- `CHANGELOG.md`: Neuer `### Known limitation` Block nach dem `### Changed`-Block
  des 4.1-Abschnitts, vor der `---`-Linie. Wortlaut exakt wie im Plan.
- `RELEASE_NOTES.md`: Neuer `#### Known limitation: more than 16 outputs` Block
  nach dem `#### Wording`-Block, vor der `---`-Linie. Wortlaut exakt wie im Plan.

Kein Em-Dash, kein Superlativ, kein privater Name. Inhalt am Code belegt
(SlotGains.maxSlots = 16, nullbasierter Index 16, Grenze seit 4.0 fuer Lautstaerke,
seit 4.1 auch fuer Solo).

grep-Akzeptanztest:
- `grep -n "Known limitation" CHANGELOG.md`: Treffer im 4.1-Abschnitt.
- `grep -n "Known limitation" RELEASE_NOTES.md`: Treffer im 4.1-Abschnitt.
- `grep -n "uninterrupted\|without interruption" CHANGELOG.md`: nur historischer
  Treffer (Z. 355 Stable Output Mode), kein Treffer im 4.1-Block.
- `grep -n "seamless\|no interruption" CHANGELOG.md RELEASE_NOTES.md docs/v4.1/06-appstore-texts.md`:
  kein Treffer.

Build/Tests: nicht noetig (kein Swift-Code beruehrt).

Commit: `docs(changelog): document maxSlots limitation for volume and Solo (F3)`
Hash: 36d50b1

Abweichungen/Luecken: keine.

---

## P3-S4: Abschlussbericht aktualisieren (F4a bis F4e)

**Status:** erledigt. Datei `docs/v4.1/09-final-report.md`.

- F4a: M5-Prüfleitfaden (Tabelle Abschnitt 7) auf 17 Ausgaben korrigiert, Prüfziel
  Slot 17 (Index 16); der Inkonsistenz-Hinweissatz entfernt. Wortlaut wie Plan.
- F4b: Abschnitt 4.3, Zuschreibung B4/B5 klarer formuliert, Wortlaut wie Plan.
- F4c: Abschnitt 6a, Rechenbeispiel "1 von 4 Slots, linear = 0,25" mit Verweis auf
  Audit 2 Abschnitt B1; der alte Widerspruchssatz entfernt.
- F4d: Abschnitt 6c, beide Fundstellen (FanOutEngine.swift Z. 196 bis 199 und
  Z. 598 bis 599) genannt; "was ich nicht geprüft habe" entfernt. Beide Zeilen
  am Code am HEAD verifiziert (setOutputGain Zweig idx >= maxSlots; Count-Warnung).
- F4e: Abschnitt 1 um eine sechste Aussage zu Durchlauf 3 und um
  "Audit 3 ist noch ausstehend (12-audit-v3.md)" ergänzt; Durchläufe-Tabelle
  (4.1) um die dritte Zeile; Befundliste (4.2) um F1 bis F4.

grep-Akzeptanztest:
- `grep -c "Durchlauf 3\|10-plan-v3\|12-audit-v3" 09-final-report.md`: 4 (>=3).
- `grep -n "17 konfigurierte\|Index 16"`: M5-Zeile getroffen.
- `grep -n "0,25.*Audit 2\|Audit 2.*0,25"`: Abschnitt 6a getroffen.
- `grep -n "Z. 196\|Z. 598"`: Abschnitt 6c getroffen.

Em-/En-Dash-Prüfung (Python) über die berührten Dateien: kein Dash in neuen
Textteilen (nur historische Zeilen enthalten En-Dashes, unberührt).

Build/Tests: nicht nötig (nur Markdown).

Commit: `docs(v4.1): update final report for cycle 3 findings (F4a-F4e)`
Hash: 6d681fc

**ABWEICHUNG:** Der Status von C1 in der Befundliste (4.2) stand auf "**Offen**".
Da P3-S2 (Commit-Message "F2, C1") genau diesen Befund behebt, wurde der C1-Status
auf "Behoben in P3-S2-Commit" aktualisiert, damit der Bericht in sich konsistent
bleibt. Der Plan nennt diese Zeile nicht ausdrücklich; die Änderung ist eine
minimale Konsistenz-Korrektur im Rahmen von F4e.

---

## P3-S5: README aktualisieren

**Status:** erledigt. Datei `docs/v4.1/README.md`.

**ABWEICHUNG/LÜCKE:** Die drei Zeilen für `10-plan-v3.md`, `11-impl-v3.md` und
`12-audit-v3.md` waren bereits im Plan-Commit `545f05e` in die Inhaltstabelle
eingetragen (mit leicht anderem Wortlaut als im Plan-Block P3-S5). Das
Akzeptanzkriterium `grep -c "10-plan-v3\|11-impl-v3\|12-audit-v3" README.md` = 3
ist damit bereits erfüllt. Statt die Zeilen zu duplizieren (was den Plan verletzt
hätte), wurde nur die Zeile zu `11-impl-v3.md` von "Status: ausstehend" auf den
tatsächlichen Stand "Status: fertig" aktualisiert. Die Zeilen zu `10-plan-v3.md`
und `12-audit-v3.md` blieben unverändert (Plan bzw. Audit-Status korrekt).

grep-Akzeptanztest:
- `grep -c "10-plan-v3\|11-impl-v3\|12-audit-v3" README.md`: 3.

Build/Tests: nicht nötig.

Commit: `docs(v4.1): update README for cycle 3 documents` (gemeinsam mit dem
Protokoll).
Hash: PLATZHALTER-S5

---

## Gesamtstand

**Teststand vorher (Baseline, HEAD 545f05e):** 59 swift-testing + 56 XCTest grün,
App-Build `** BUILD SUCCEEDED **`.

**Teststand nachher:** 59 swift-testing + 56 XCTest grün, App-Build
`** BUILD SUCCEEDED **` (nach P3-S2, dem einzigen Code-berührenden Schritt, und
im abschliessenden Lauf nach allen Schritten unverändert).

**Commits (Durchlauf 3, release/4.1):**
- P3-S1 `4192a76` docs(changelog): describe blip session behaviour without hardware claim (F1)
- P3-S2 `87fe856` docs(engine): qualify D1 comment to reference 05-plan-v2.md (F2, C1)
- P3-S3 `36d50b1` docs(changelog): document maxSlots limitation for volume and Solo (F3)
- P3-S4 `6d681fc` docs(v4.1): update final report for cycle 3 findings (F4a-F4e)
- P3-S5 (README + dieses Protokoll): Hash siehe Commit-Log

Kein Push, kein Tag, kein Merge, kein `--no-verify`, kein `reset --hard`.

**Offene Messpunkte (NUTZER MUSS MESSEN, nicht verifizierbar):** M1 bis M9,
unverändert offen. Keiner wurde von einem Agenten gemessen.

**Abweichungen:**
1. Startpunkt-Commit: Branch stand bei `545f05e` (Plan-Commit) statt `14a6417`;
   `545f05e` berührt nur das Plandokument, kein Scope-Konflikt.
2. P3-S4: C1-Status in der Befundliste von "Offen" auf "Behoben in P3-S2-Commit"
   gesetzt (Konsistenz zu F2, siehe P3-S4-Eintrag).
3. P3-S5: README-Zeilen bereits im Plan-Commit vorhanden; nur die 11-impl-v3-Zeile
   auf "fertig" aktualisiert (siehe P3-S5-Eintrag).

**Restrisiken:** Keine Code-Logik berührt (nur ein Kommentar in
EngineController.swift). Alle inhaltlichen Aussagen in CHANGELOG, RELEASE_NOTES
und Bericht sind am Code belegt. Die Formulierungen sind nicht von Apple App
Review geprüft (ausserhalb des Scopes). M1 bis M9 bleiben offen.
