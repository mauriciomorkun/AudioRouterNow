# Doku-Inventur 4.1 (Stand 14.11.2026)

Vor der Doku-Pflege angelegte Liste veralteter oder widersprüchlicher Aussagen,
geprüft gegen Git (`git log`, `git tag`, Arbeitsbaum), `gh release list`,
`gh issue view 1` und die Dokumente in `docs/v4.1/`. Belege in der letzten Spalte.

## Geprüfte Fakten (Grundlage)

| Fakt | Beleg |
|------|-------|
| Branch `release/4.1`, 30 Commits vor `main`, kein Tag `v4.1`, nicht gepusht | `git rev-list --count main..HEAD` = 30, `git tag` ohne `v4.1`, Arbeitsbaum sauber |
| Version in `v4/Configs/AudioRouterNow4.xcconfig`: 4.1 (11) | `MARKETING_VERSION = 4.1`, `CURRENT_PROJECT_VERSION = 11` |
| CHANGELOG und RELEASE_NOTES tragen die 4.1-Sektion mit Platzhalter-Datum `YYYY-MM-DD` | `CHANGELOG.md:70`, `RELEASE_NOTES.md:156` ("not yet submitted") |
| v3.4.5 veröffentlicht 18.09.2026, v3.4.6 (Latest) 26.09.2026 | `gh release list --limit 8` |
| GitHub Issue #1 ist OPEN, Melder-Antwort mit v3.4.5-Link vorhanden | `gh issue view 1 --json state,comments` (state OPEN, Kommentar 18.09.2026) |

## Veraltete oder widersprüchliche Aussagen (vor der Änderung)

| Datei | Stelle | Aussage (alt) | Stand heute | Beleg |
|-------|--------|---------------|-------------|-------|
| `project_audiorouternow_v345_pending.md` | Titel, ganze Datei | Dateiname "pending", Inhalt beschreibt v3.4.5 als anstehend bzw. gerade erschienen | v3.4.5 erschien 18.09., v3.4.6 am 26.09.; Release-Teil erledigt, nur Issue #1 bleibt offen | `gh release list`, `gh issue view 1` |
| `.claude/CLAUDE.md` | Z. 15 | "aktuell 4.0.1 (Build 10)" ohne Hinweis auf 4.1 | 4.1 (11) liegt fertig auf `release/4.1`, nicht released | `git`, xcconfig |
| `.claude/CLAUDE.md` | Z. 59 bis 62 | "Noch offen": 4.1-Punkte "in BACKLOG.md (AirPlay, Solo-Button, ...)" als offen | Diese Punkte sind auf `release/4.1` umgesetzt, nicht released | `docs/v4.1/09-final-report.md`, `git log` |
| `.claude/CLAUDE.md` | Z. 67 bis 83 | Sparkle/Homebrew "offener Release-Schritt" für v3.4.0 | v3.4.0 bis v3.4.6 sind released, Appcast und Cask gepflegt | `gh release list`, Memory v345 |
| `feedback/README.md` | Z. 17 (CASE-002) | "Release v3.4.5 + Antwort an Melder ausstehend" | v3.4.5 released 18.09., Melder am Issue beantwortet, Issue noch OPEN | `gh release list`, `gh issue view 1` |
| `BACKLOG.md` | Abschnitt "Nächste App-Store-Updates" und 4.1-Einträge | ScrollView/Start-Toggle/Solo/SR-Listener/Entprellen/Store-Description als Ideen bzw. "geplant für 4.1" | Alle auf `release/4.1` umgesetzt, nicht released, nicht am Gerät verifiziert | `docs/v4.1/09-final-report.md` |
| `TODO.md` | Z. 23, 35 bis 38 | "der eine wirklich offene Punkt": Build 9 nicht eingereicht | 4.0.1 (Build 10) ist seit 13.10. live; der offene Punkt ist jetzt 4.1 | `docs/v4.0.1/README.md`, `gh` |
| `project_audiorouternow_v401_workflow_pending.md` | ganze Datei | "Submission steht aus", Stand 15.10. | 4.0.1 live; 4.1 umgesetzt auf `release/4.1` | `git`, `docs/v4.1/` |
| `project_audiorouternow_v4_tags_pending.md` | ganze Datei | Stand 12.10., `v4-appstore/` offen | `v4-appstore/` weiter offen, Signierung in `project.yml` weiter offen; 4.1 neu | `docs/v4.1/09-final-report.md` Abschnitt 6e |
| Memory-Datei zum UI-Überlauf-Supportfall (Dateiname bewusst nicht genannt, enthält einen Nutzernamen) | "BACKLOG-Items ausgelöst" | ScrollView/Start-Toggle nur als Backlog-Idee | In 4.1 umgesetzt, nicht released | `docs/v4.1/09-final-report.md` 3.1 |

## Ergebnis

Pflege am 14.11.2026 durchgeführt. Geänderte Dateien:

| Datei | getrackt/lokal | Was geändert |
|-------|----------------|--------------|
| `docs/v4.1/README.md` | getrackt | Eintrag `13-doc-inventory.md` im Verzeichnis ergänzt |
| `docs/v4.1/13-doc-inventory.md` | getrackt | Diese Datei neu angelegt (Inventur und Ergebnis) |
| `BACKLOG.md` | lokal (gitignored) | 4.1-Absatz Stand 14.11.2026 ergänzt; Einträge ScrollView, Start-Toggle, Solo, SR-Listener, Entprellen, Store-Description auf tatsächlichen Stand (umgesetzt auf `release/4.1`, nicht released, M1 bis M9 offen); vier neue Einträge (maxSlots-Hinweis, Wellen-Energie-Teiler, Launch-at-Login-Consent, Signierung in `project.yml`); Fußdatum |
| `TODO.md` | lokal (gitignored) | Header-Datum; 4.0.1 live statt Build-9-offen; 4.1 als aktueller offener Punkt; v3.4.5-Datum |
| `LAUNCH_EXECUTION.md` | lokal (gitignored) | Sechs Einträge für den 4.1-Zyklus (AirPlay 11.11., Plan/Umsetzung 12.11., Audit und Durchläufe 13. bis 14.11.) mit Commit-Hashes |
| `.claude/CLAUDE.md` | lokal (gitignored) | Projektkontext (4.1 auf `release/4.1`); Update-Ablauf-Block mit 4.1-Lehren; 4.1-Status- und Nächste-Schritte-Block; Noch-offen-Liste; Sparkle und Homebrew als erledigt mit Beleg |
| `feedback/README.md` | lokal (gitignored) | CASE-002 auf "ausgeliefert in v3.4.5", Issue #1 noch OPEN; Hinweis auf den UI-Überlauf-Fall in `docs/support/`; Stand-Datum |
| `docs/support/INDEX.md`, `categories/ui-overflow.md`, `interactions/2026-11-05_*.md` | lokal (gitignored) | UI-Überlauf-Fall: Ursache bestätigt, Fix in 4.1 umgesetzt (nicht released), Rückmeldung an Nutzer nach Release |
| `MEMORY.md` und 5 Projekt-Memories | lokal (Memory) | Zwei neue Memories (`v41_status`, `airplay_research`); `v345_pending`, `v401_workflow_pending`, `v4_tags_pending` und die Memory-Datei zum UI-Überlauf-Supportfall auf Stand; Index aktualisiert |

Konsistenzprüfung: kein eigener Doku-Satz mehr mit "v3.4.5 ausstehend" (die
verbliebene Fundstelle in `MEMORY.md` ist ein wörtliches Zitat über Tims veralteten
DB-Stand, mit UPDATE-Klausel eingeordnet). Keine Em- oder En-Dashes in neu
geschriebenem Text. Keine Nutzer- oder Drittnamen in getrackten Dateien (getrackt
geändert wurden nur `docs/v4.1/README.md` und diese Datei). Getrackter Arbeitsbaum
nach den Commits sauber.

## Nachtrag 15.11.2026

Erneut gepflegt nach Abschluss des Nachtrag-Zyklus zu 4.1 (W1 und W2, Doku `14` bis `22`):

| Datei | getrackt/lokal | Was geändert |
|-------|----------------|--------------|
| `docs/v4.1/13-doc-inventory.md` | getrackt | Dieser Abschnitt angefügt |
| `BACKLOG.md` | lokal (gitignored) | 4.1-Absatz auf Stand 15.11.2026; `maxSlots`-Eintrag und Wellen-Energie-Teiler-Eintrag als erledigt (W1, W2); M5-Formulierung auf Nachtrag-Stand; neue akzeptierte Reste (NM-5/NM-7, NT3-D3, Test-Target-Lücke) |
| `TODO.md` | lokal (gitignored) | Stand-Datum und offener-Punkt-Text auf 15.11.2026 und 63 Commits |
| `LAUNCH_EXECUTION.md` | lokal (gitignored) | Drei neue Einträge für den Nachtrag-Zyklus (Durchlauf 1 bis 3, 14. bis 15.11.2026) |
| `.claude/CLAUDE.md` | lokal (gitignored) | 4.1-Stand-Block auf 15.11.2026 und 63 Commits; Nachtrag-Inhalt (W1, W2); Messpunkte NM-1 bis NM-7; Lehren aus dem Nachtrag als eigener Abschnitt |
| `project_audiorouternow_v41_status.md` | lokal (Memory) | Stand 15.11.2026, Nachtrag W1 und W2, Tests 60 plus 96, 63 Commits, NM-1 bis NM-7 |
| `feedback_agent_auftraege_doppelbindestrich.md` | lokal (Memory) | Neue Datei: " -- " in Agentenauftraegen verbieten |
| `MEMORY.md` | lokal (Memory) | Zeile `v41_status` auf Stand; neue Zeile `feedback_agent_auftraege_doppelbindestrich` |

Konsistenzprüfung Nachtrag: kein eigener Satz mehr mit "16er-Grenze offen" oder "maxSlots = 16".
Testzahlen 60 plus 96 konsistent. Commit-Zahl 63 konsistent. Keine Em-, En-Dashes oder
" -- " in neu geschriebenem Text. Keine Nutzer- oder Drittnamen in getrackten Dateien
(getrackt geändert wurde nur diese Datei).

## Konsistenzprüfung 15.11.2026 (zweiter Lauf)

Gepflegt nach dem Nachtrag-Zyklus und dem Festlegen des wichtigsten nächsten Schritts.
Grundlage: Git (`git rev-list --count main..HEAD` = 64 zum Zeitpunkt der Prüfung),
alle zitierten Commit-Hashes per `git cat-file -e`, Textabgleich in den Dokumenten.

### Abweichungstabelle

| Prüffeld | Befund | Aktion | Beleg |
|----------|--------|--------|-------|
| a) Commit-Zahlen | Lokale/gitignorierte Dateien (BACKLOG.md, TODO.md, .claude/CLAUDE.md, project_audiorouternow_v41_status.md) nannten "63 Commits" ohne Prüfbefehl. Die Zahl war 64 zum Zeitpunkt dieser Prüfung (jeder Doku-Commit erhöht sie). | In lokalen Dateien ersetzt durch "Stand 15.11.2026: 63 Commits vor `main`; aktuell: `git rev-list --count main..HEAD`". Getrackte Dateien unverändert (historische Momentaufnahmen mit Datum). | `git rev-list --count main..HEAD` = 64 |
| b) Commit-Hashes | Alle 36 geprüften Hashes (Hauptzyklus und Nachtrag) existieren und gehören zu den beschriebenen Schritten. Einzige Auffälligkeit: Befund G4 im Abschlussbericht (Zeile 424) zitiert den defekten Dateinamen `16-audit-nachtrag.md` als historische Beschreibung eines behobenen Fehlers, nicht als Live-Verweis. | Keine Aktion. Historische Beschreibung eines behobenen Befunds, kein toter Link. | `git cat-file -e <hash>^{commit}` fuer alle 36 Hashes |
| c) Teststand | "60 swift-testing plus 96 XCTest" steht einheitlich in allen Stellen, die den Endstand nach dem Nachtrag beschreiben. Historische Zustände (59 plus 56 in den Durchlauf-1-bis-3-Protokollen, 60 plus 95 in Audit-Nachtrag-v1) sind datiert und korrekt. Der Abschlussbericht Abschnitt 1 nennt "59 plus 56" als Stand vor dem Nachtrag; Abschnitt 11 korrigiert auf "60 plus 96". | Keine Aktion. Alle aktuell-Stand-Aussagen konsistent. | `grep` ueber BACKLOG.md, .claude/CLAUDE.md, project_audiorouternow_v41_status.md, 09-final-report.md Abschnitt 11 |
| d) README.md und Querverweise | Alle Dateien 01 bis 22 existieren. Alle Querverweise in 09-final-report.md auf benannte NN-Dateien zeigen auf existierende Dateien. Einzige Fundstelle `16-audit-nachtrag.md` (ohne -v1) ist historische Fehlerbeschreibung (Befund G4), kein Verweis. | Keine Aktion. | `ls docs/v4.1/`; Skript `test -f` |
| e) CHANGELOG und RELEASE_NOTES | Kein "Known limitation"-Absatz mehr. Die "Fixed"-Eintraege fuer die 16er-Grenze, Blip-Absorption, SR-Listener, ScrollView, Solo und Wellenenergie stimmen mit dem Code ueberein (belegt durch Commits und Audit-Protokolle). "keeps running uninterrupted" in CHANGELOG Blip-Eintrag als Rest-Formulierung bekannt und in `docs/v4.1/09-final-report.md` Abschnitt 6f dokumentiert. Launch-at-Login-Reset korrekt in beiden Dokumenten. | Keine Aktion. Der Rest Blip-Formulierung ist dokumentiert. | `grep` CHANGELOG.md, RELEASE_NOTES.md; 09-final-report.md Abschnitt 6f |
| f) feedback/README.md, docs/support, BACKLOG.md | Keine veraltete Aussage "Solo wirkt nicht ab Slot 17". Statussymbole einheitlich. UI-Ueberlauf-Hinweis am Ende von feedback/README.md korrekt (Fix in 4.1 umgesetzt, nicht released). | Keine Aktion. | Textabgleich |
| g) Memory | Alle 28 in MEMORY.md verlinkten Dateien existieren. Sechs Dateien im Memory-Ordner ohne Indexeintrag gefunden (siehe "Ungeprüft/offen"). Die Zeile zu `project_audiorouternow_v401_workflow_pending.md` ist lang, aber durch UPDATE-Klausel (14.11.2026) korrekt eingeordnet und nicht irreführend. | Keine Aktion an verifizierten Dateien. Unindexierte Dateien in Liste "Ungeprüft/offen". | `ls memory/*.md` gegen MEMORY.md |
| h) Zeilenangaben | Stichprobe 10 Angaben in 09-final-report.md. EngineController.swift: Bericht nennt "laut Audit 2 Zeile 752" fuer den D1-Kommentar; tatsaechliche Zeile nach dem Nachtrag ist 790 (Nachtrag fugte Zeilen ein). Der Bericht gibt dies korrekt als historisch-gespeicherte Aussage aus Audit 2 wieder; Abschnitt 11 stellt klar, dass Abschnitte 1 bis 10 den Stand vor dem Nachtrag beschreiben. FanOutEngine.swift Z. 196 bis 199 und Z. 598 bis 599 (Abschnitt 6c) sind durch den Nachtrag entfernt, aber Abschnitt 11 nennt 6c ausdruecklich als ueberholt. | Keine Aktion an der getrackten Datei. Zeilenangaben sind korrekt als historisch eingeordnet. | `grep -n` in EngineController.swift; Abschnitt 11 des Berichts |
| i) Stilregeln | Alle neuen Zeilen (getrackt, seit 5dc55f5) geprueft. Kein Em-Dash, kein En-Dash, kein " -- " als Gedankenstrich-Ersatz in neuen Texten. Vorhandene " -- " in `git diff`-Befehlen (Git-Separator) und in woertlichen Zitaten (Fehlerbeschreibung G4, H2) sind zulaessig. Kein Nutzername in getrackten Aenderungen. | Keine Aktion. | `git diff 5dc55f5..HEAD | grep "^+" | grep " -- \| -- "` |
| j) Format | Tabellen vollstaendig, Ueberschriften-Hierarchie konsistent, Datumsformat TT.MM.JJJJ im Text, Stand-Zeilen aktuell, keine doppelten Leerzeilen in neuen Abschnitten. | Keine Aktion. | Textabgleich |

### Neu festgelegter Prioritaetspunkt (15.11.2026)

Messpunkte M1 bis M9 und NM-1 bis NM-7 gemeinsam mit Claude durchgehen eingetragen in:

- `.claude/CLAUDE.md` (lokal): Abschnitt "4.1: Stand 15.11.2026 und nächste Schritte",
  hervorgehobener erster Punkt "Wichtigster nächster Schritt"
- `project_audiorouternow_v41_status.md` (Memory): Abschnitt "Nächster Schritt (Priorität)"
  ganz oben unter dem Kopf
- `MEMORY.md` (Memory): Zeile zu `project_audiorouternow_v41_status.md` ergänzt um
  "Nächster Schritt: Messpunkte M1 bis M9 und NM-1 bis NM-7 gemeinsam mit Claude durchgehen"
- `BACKLOG.md` (lokal): Prioritätssatz im 4.1-Absatz, Verweis auf `TODO.md`

`docs/v4.1/09-final-report.md` unverändert: Abschnitt 7 listet M1 bis M9 als offen,
Nachtrag-Abschnitt listet NM-1 bis NM-7 als offen. Kein Widerspruch zum neuen Punkt.

### Geänderte Dateien

| Datei | getrackt/lokal | Was geändert |
|-------|----------------|--------------|
| `docs/v4.1/13-doc-inventory.md` | getrackt | Dieser Abschnitt angefügt |
| `BACKLOG.md` | lokal | Commit-Zahl mit Verifikationsbefehl verankert; Prioritaetssatz zu Messpunkten ergänzt |
| `TODO.md` | lokal | Commit-Zahl mit Verifikationsbefehl verankert |
| `.claude/CLAUDE.md` | lokal | Prioritaetspunkt "Wichtigster nächster Schritt" eingefügt; Commit-Zahl mit Verifikationsbefehl verankert |
| `project_audiorouternow_v41_status.md` | Memory | Abschnitt "Nächster Schritt (Priorität)" eingefügt; Commit-Zahl mit Verifikationsbefehl verankert |
| `MEMORY.md` | Memory | Zeile zu `project_audiorouternow_v41_status.md` um Prioritaetshinweis ergänzt |

### Ungeprüft/offen

- **Memory-Dateien ohne Indexeintrag:** `audiorouter_backlog.md`, `project_audiorouter_now.md`,
  `project_tim_status.md`, `project_tim_research_feature.md` (AudioRouterNow-verwandt oder
  Tim-Projekt), `project_astroanalyzer_apple_developer.md`, `project_backup_strategy.md`,
  `_session-context.md`, `session_claude_setup_optimization_2026_09_10.md`. Inhalt nicht
  geprüft, kein Indexeintrag angelegt (Vorsicht: Inhalt unbekannt, versehentliche Einträge
  möglich). Nutzerseitige Entscheidung, ob und was zu indexieren ist.
- **Memories council, buffer, tracker** (`project_audiorouternow_council_pending.md`,
  `project_audiorouternow_buffer_pending.md`, `project_audiorouternow_tracker.md`): Inhalt
  historisch (Fälligkeitsdaten 2026-09), Aktualität nicht geprüft. Unverändert gelassen.
- **C1 offen** (Namenskollision D1): Im Abschlussbericht als dokumentiert geführt; der
  Kommentar in EngineController.swift verweist inzwischen auf `docs/v4.1/05-plan-v2.md`
  (laut Audit). Am Code nicht erneut verifiziert.

## Konsistenzpruefung 17.11.2026

Anlass: Es liegen DREI Bedienkonzepte (C, C2, C3) im Arbeitsbaum von `release/4.1`;
welche in 4.1 erscheint, ist noch nicht entschieden (C3b = C3 plus V2 ist der
aktuelle Arbeitsbaum). Diese Pruefung haelt fest, welche Doku die offene Entscheidung
nennt und welche Aussagen bei Wahl von C oder C2 neu zu formulieren sind.

### Was geaendert wurde (diese Pflege)

| Datei | getrackt/lokal | Was |
|-------|----------------|-----|
| `docs/v4.1/README.md` | getrackt | Abschnitt "Offene Entscheidung: Bedienoberflaeche (Variante C, C2 oder C3)" mit Varianten-Tabelle, Test-Apps, Sicherungen, V2-Einordnung (Annahme markiert), Schritten nach der Entscheidung, Pruefpunkten, Kalender-Hinweis |
| `docs/v4.1/09-final-report.md` | getrackt | Banner ganz oben: Entscheidung zwischen drei Varianten offen, Verweis auf 23 und README |
| `docs/v4.1/23-ui-start-button-oben.md` | getrackt (untracked im Git) | Abschnitt "Entscheidungsstand und Vergleich" mit Vergleichstabelle, Empfehlung (als Einschaetzung), "Entscheidung des Nutzers: OFFEN" mit Platz fuer Datum/Wahl |
| `docs/v4.1/25-add-device-liste.md` | getrackt (untracked im Git) | Abschnitt "Audit V2" (Teil A dieses Auftrags) |
| `docs/v4.1/13-doc-inventory.md` | getrackt | dieser Abschnitt plus Arbeitsstand-Notiz |

Lokale (gitignorierte) Dateien: TODO.md, BACKLOG.md, `.claude/CLAUDE.md`,
`docs/homepage-redesign/00-verlauf.md` sowie Memory (neue Datei plus Index) siehe
Punkt 5 bis 7 des Auftrags und die Arbeitsstand-Notiz unten.

### Von der offenen Entscheidung betroffene Dokumente

| Dokument | Beschreibt derzeit | Bei Wahl C oder C2 neu zu formulieren? |
|----------|--------------------|-----------------------------------------|
| `CHANGELOG.md` (4.1-Abschnitt) | bewusst den Stand **C3b** | Ja. Betroffen sind im Abschnitt "Changed": die Zeile "The start/stop button now sits at the top of the panel ... It is the only start/stop button in the panel. The footer is a single row ..." (bei C faellt der obere Knopf weg und der grosse Knopf bleibt im Footer; bei C2 traegt der Footer eine Pille und zwei Reihen), die Zeile "The support control is now a labelled button" (C/C2: Support ist ein Icon, kein beschrifteter Knopf) und die Zeile "Footer controls now show a short explanation on hover" (die Hover-Bubbles sind nur in C3). Die Zeile "The Add device menu marks outputs that are already added" (V2) bleibt unabhaengig von der Variante. **Nicht jetzt geaendert** (der CHANGELOG beschreibt bewusst C3b). |
| `RELEASE_NOTES.md` (4.1-Abschnitt) | beschreibt noch den **aelteren Statuszeilen-Stand** (P1/C): "A small start/stop button has also been added to the status bar at the top, so routing can be started or stopped from either end of the panel." Das passt zu C (Pille oben plus Footer-Knopf), NICHT zu C2/C3 (ein grosser Knopf oben, kein Statuszeilen-Toggle). Es fehlen die C3-Punkte (Support als Knopf, Hover-Erklaerungen, Footer eine Reihe) und die V2-Kennzeichnung ("Add device" markiert hinzugefuegte Paare). | Ja, in jedem Fall. Bei C3: den Statuszeilen-Satz durch "the start/stop button has moved to the top and is the only one" ersetzen, Support-Knopf, Hover-Erklaerungen und V2 ergaenzen. Bei C: Satz bleibt naeher am jetzigen Text. Bei C2: Pille-im-Footer-Formulierung. **Nicht jetzt geaendert** (Variante offen; Angleich gehoert in den Schritt nach der Entscheidung). |
| `docs/v4.1/06-appstore-texts.md` (App-Store-Texte) | What's New und Review-Notiz zu 4.1 | Pruefen bei der Einreichung. Soweit die Texte die UI-Anordnung (oberer Knopf, Footer, Support) nennen, an die gewaehlte Variante angleichen. Hier nicht geaendert. |
| Screenshots (App Store) | zeigen den UI-Stand der gewaehlten Variante | Nach der Entscheidung mit der gewaehlten Variante neu erstellen. Nicht Teil dieser Pflege. |

Ergebnis: Kein CHANGELOG-Eintrag wurde geaendert (er beschreibt bewusst C3b), nichts
Vorlaeufiges oben angefuegt. Die Zeilen, die bei Wahl von C oder C2 neu zu formulieren
waeren, sind oben benannt, damit der Angleich nach der Entscheidung vollstaendig
gelingt.

## Konsistenzpruefung 17.11.2026, Entscheidung C3

Anlass: Der Nutzer hat am 17.11.2026 C3 mit V2 gewaehlt. Diese Pflege stellt die
"offen"-Aussagen in der Doku auf den Endstand um.

### Dadurch angepasste Dateien

| Datei | getrackt/lokal | Was |
|-------|----------------|-----|
| `docs/v4.1/README.md` | getrackt | Abschnitt "Offene Entscheidung" in "Entscheidung: Bedienoberflaeche (C3 mit V2, getroffen am 17.11.2026)" umgewandelt; Tabelle der verworfenen Varianten; Vergleichstabelle als Verlauf behalten; Inhaltstabelle um 26-release-plan.md ergaenzt, Status in 23/25 angepasst |
| `docs/v4.1/09-final-report.md` | getrackt | Banner auf "Bedienoberflaeche entschieden: C3 mit V2"; M2/M2b/M2c/M2d auf den gewaehlten Stand, am Geraet Gesehenes und Offenes vermerkt |
| `docs/v4.1/23-ui-start-button-oben.md` | getrackt | "Entscheidung des Nutzers: OFFEN" durch "Entscheidung: C3 mit V2, 17.11.2026"; OFFEN-Satz im Vergleichsabschnitt umgestellt |
| `docs/v4.1/25-add-device-liste.md` | getrackt | V2 als Teil der finalen 4.1 vermerkt, Scrollbarkeit am Geraet bestaetigt, V1/V3 offen |
| `docs/v4.1/13-doc-inventory.md` | getrackt | dieser Abschnitt plus Arbeitsstand-Notiz |
| `RELEASE_NOTES.md` | getrackt | 4.1-UI-Beschreibung auf den Endstand C3 mit V2 (siehe verbleibende Punkte) |
| `docs/v4.1/06-appstore-texts.md` | getrackt | UI-Beschreibungsstellen zum zweiten Statuszeilen-Knopf auf C3 angepasst |
| `CHANGELOG.md` | getrackt | geprueft, beschreibt bereits C3 mit V2, nicht geaendert |

Lokale (gitignorierte) Dateien und Memory: siehe Punkte 8 und 9 des Auftrags und die
Arbeitsstand-Notiz unten.

### Verbleibende Punkte (RELEASE_NOTES.md, aelterer Statuszeilen-Stand)

Vor der Anpassung beschrieb `RELEASE_NOTES.md` im 4.1-Abschnitt den aelteren
Statuszeilen-Stand (C/P1). Die konkreten Stellen:

- Zeile 170 (ca.): "A small start/stop button has also been added to the status bar
  at the top, so routing can be started or stopped from either end of the panel."
  Das passt zu C (Statuszeilen-Toggle plus Footer-Knopf), NICHT zu C3 (ein grosser
  Knopf oben, kein Statuszeilen-Toggle). Auf den Endstand gebracht.
- Es fehlten die C3-Punkte (Start/Stop-Knopf oben als einziger, Support als Knopf,
  Hover-Erklaerungen, Footer eine Reihe) und die V2-Kennzeichnung. Ergaenzt.

Der CHANGELOG beschreibt im 4.1-Abschnitt bereits C3 mit V2 (Zeilen "The start/stop
button now sits at the top of the panel", "The support control is now a labelled
button", "Footer controls now show a short explanation on hover", "The Add device
menu marks outputs that are already added") und wurde nicht geaendert.

### Screenshots (App Store)

`docs/v4.1/06-appstore-texts.md` enthielt zwei UI-Beschreibungsstellen, die den
aelteren Statuszeilen-Knopf nannten ("A second start/stop button ... status bar",
"An additional start/stop icon button ... status bar"); beide sind auf den C3-Stand
gebracht (oberer Knopf als einziger, Support als beschrifteter Knopf, Hover-Hinweise,
V2 im "Add device"-Menue). Der Store-Description-Baustein in Abschnitt 3 (reiner
Nutzertext ohne UI-Anordnung) ist unveraendert. **Neue Screenshots noetig:** die fuer
App Store Connect geplanten Screenshots muessen den Endstand C3 mit V2 zeigen (oberer
Start/Stop-Knopf, einreihiger Footer mit beschriftetem Support, V2-Markierung im
"Add device"-Menue), nicht die aeltere Optik. Erstellung ist Nutzeraufgabe, nicht Teil
dieser Pflege.

## Arbeitsstand Doku 17.11.

Zwischenstand der Doku-Pflege zur offenen Bedienoberflaechen-Entscheidung (C/C2/C3)
und zu V2. Wird je Teilschritt fortgeschrieben, damit ein Sitzungslimit keinen
Fortschritt kostet.

- [x] Teil A: Audit V2 als Abschnitt "Audit V2" ans Ende von `docs/v4.1/25-add-device-liste.md`.
      Urteil Freigabe. Tests 60 swift-testing plus 129 XCTest selbst ausgefuehrt und gruen,
      `git status --short` davor und danach gleich.
- [x] C3b-Sicherung: `.claude/variants/C3b-aktuell/` (Patch `C3b.patch` plus Kopien der
      untracked Dateien unter `untracked/`). Patch per `git apply --check` gegen eine frische
      `git archive HEAD`-Kopie in /tmp geprueft: OK. /tmp-Kopie geloescht.
- [x] Punkt 1: `docs/v4.1/README.md` (Abschnitt "Offene Entscheidung").
- [x] Punkt 2: `docs/v4.1/09-final-report.md` (Banner).
- [x] Punkt 3: `docs/v4.1/23-ui-start-button-oben.md` (Abschnitt "Entscheidungsstand und Vergleich").
- [x] Punkt 4: Konsistenzpruefung 17.11.2026 (oben).
- [x] Punkt 5: lokale Dateien. BACKLOG.md (4.1-Block um Varianten C/C2/C3 und V1/V3 plus
      Verweis auf v4.2 "Device Visibility Filter" ergaenzt, nichts entfernt), TODO.md
      (WICHTIGSTER NAECHSTER SCHRITT um die offene Variantenwahl und Kalender-Hinweis),
      `.claude/CLAUDE.md` (Session-Start-Erinnerungsblock), `00-verlauf.md` (Eintrag 11).
- [x] Punkt 6: Memory. Neue Datei `project_audiorouternow_v41_variantenentscheidung_pending.md`
      (Frontmatter name/description/type: project), neue OFFEN-Zeile in MEMORY.md,
      `project_audiorouternow_v41_status.md` auf Stand 17.11.2026 (Teststand 60 plus 129,
      Verweis auf die neue Datei). Acht Memory-Dateien ohne Indexeintrag nicht angefasst.
- [x] Punkt 7: Kalender-Hinweis in README und TODO ("Zusatzerinnerung per Kalender nicht
      eingerichtet, Anmeldung abgelaufen"). Nichts installiert (kein launchd, kein cron).

## Arbeitsstand Entscheidung C3 (17.11.2026)

Der Nutzer hat am 17.11.2026 C3 mit V2 gewaehlt (Stand der Test-App "TEST C3b").
Diese Notiz wird je Teilschritt fortgeschrieben, damit ein Sitzungslimit keinen
Fortschritt kostet. Regeln: kein Commit, kein Push, kein Tag, keine Gedankenstriche,
keine Klarnamen in getrackten Dateien, nichts am Swift-Code, landing-page/, GitHub,
docs/support/. `docs/v4.1/26-release-plan.md` nicht angefasst (anderer Agent).

- [x] Punkt 1: `docs/v4.1/README.md`. Abschnitt "Offene Entscheidung" in "Entscheidung:
      Bedienoberflaeche (C3 mit V2, getroffen am 17.11.2026)" umgewandelt (Entscheidung,
      Begruendung des Nutzers, Tabelle der verworfenen Varianten mit Sicherungsorten,
      was festgelegt ist, Vergleichstabelle als historischer Verlauf behalten). Inhalts-
      tabelle: 26-release-plan.md ergaenzt (als "in Arbeit" markiert), Status in 23 und
      25 auf "entschieden C3 mit V2" angepasst.
- [x] Punkt 2: `docs/v4.1/09-final-report.md`. Banner auf "Bedienoberflaeche entschieden:
      C3 mit V2 (17.11.2026)" ersetzt. M2/M2b/M2c/M2d auf den gewaehlten Stand C3 mit V2
      umformuliert; bei M2d vermerkt, was der Nutzer am Geraet gesehen hat (Scrollbarkeit
      mit "TEST C3 LISTE", V2-Kennzeichnung in "TEST C3b"); offene Punkte uebernommen aus
      23 Abschnitt 7 (Hover im echten Panel, VoiceOver, Tab-Fokus, Umbruch bei grosser
      Schrift, Start ohne Absturz, Audiotest). Datierte C3-Protokolle (Teststand 110) nicht
      veraendert; der aktuelle Stand mit V2 (60 plus 129) steht in dieser Datei und im Memory.
- [x] Punkt 3: `docs/v4.1/23-ui-start-button-oben.md`. "Entscheidung des Nutzers: OFFEN"
      durch "Entscheidung: C3 mit V2, 17.11.2026" ersetzt (Datum, Wahl, Begruendung,
      Folgen). Der OFFEN-Satz im Abschnitt "Entscheidungsstand und Vergleich" auf die
      getroffene Wahl umgestellt; Vergleichstabelle und Empfehlung als Verlauf behalten;
      Kopf "Aktuell: Variante C3" beibehalten.
- [x] Punkt 4: `docs/v4.1/25-add-device-liste.md`. Vermerk im V2-Abschnitt: V2 ist Teil
      der finalen 4.1 (Entscheidung 17.11.2026, C3 mit V2), Scrollbarkeit am Geraet mit
      der Pruefhilfe bestaetigt, V1 und V3 bleiben offene Ideen ohne Termin.
- [x] Punkt 5: Abschnitt "Konsistenzpruefung 17.11.2026, Entscheidung C3" oben in dieser
      Datei (Liste der angepassten Dateien plus RELEASE_NOTES-Zeilenliste, konkrete Zeilen
      benannt).
- [x] Punkt 6: CHANGELOG geprueft (beschreibt bereits C3 mit V2, nicht geaendert).
      RELEASE_NOTES.md: 4.1-UI-Beschreibung auf den Endstand gebracht (oberer Knopf als
      einziger statt "small ... from either end", neuer Abschnitt "A clearer footer" mit
      Support-Knopf und Hover-Hinweisen, neuer Abschnitt zur V2-Kennzeichnung im
      "Add device"-Menue). Englisch, neutral, ohne Superlativ, ohne Gedankenstrich.
- [x] Punkt 7: `docs/v4.1/06-appstore-texts.md`. Zwei UI-Beschreibungsstellen
      (What's New, Review-Notiz) vom zweiten Statuszeilen-Knopf auf C3 gebracht; Store-
      Description-Baustein (Abschnitt 3) unberuehrt. Screenshot-Hinweis im Konsistenz-
      pruefungs-Abschnitt oben ergaenzt (neue Screenshots fuer den Endstand noetig).
- [x] Punkt 8: lokale Dateien. `.claude/CLAUDE.md` (Erinnerungsblock durch kurzen Vermerk
      "C3 mit V2 (17.11.2026)" ersetzt; Messpunkte-Block M1 bis M9 / NM-1 bis NM-7 bleibt
      als wichtigster naechster Schritt). TODO.md (Variantenwahl auf erledigt, naechste
      Schritte: Messpunkte mit TEST C3b, ARCHS, Signierung project.yml, v4-appstore/,
      Preflight, App-Store-Texte und Screenshots, Commit-Reihenfolge, Tag, Einreichung).
      BACKLOG.md (4.1-Block: Variante entschieden; V1/V3 offen; "Device Visibility Filter"
      nicht angefasst). 00-verlauf.md (Eintrag 12, keine Aenderung an landing-page/).
- [x] Punkt 9: Memory. `project_audiorouternow_v41_variantenentscheidung_pending.md` auf
      Status ENTSCHIEDEN umgeschrieben (Dateiname unveraendert; Wahl C3 mit V2, Folgen,
      Sicherungspfade, Test-Apps mit Aufraeumungsvorschlag TEST/TEST (neu)/TEST C2, nichts
      geloescht). MEMORY.md-Zeile von OFFEN auf "ERLEDIGT, entschieden" gesetzt.
      `project_audiorouternow_v41_status.md` aktualisiert (Entscheidung, Teststand 60 plus
      129, naechster Schritt Messpunkte mit TEST C3b). Acht Memory-Dateien ohne Indexeintrag
      nicht angefasst; docs/support/ nicht angefasst; keine Klarnamen in Memory.

