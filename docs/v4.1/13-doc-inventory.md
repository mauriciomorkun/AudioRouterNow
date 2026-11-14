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
| `project_audiorouternow_support_thomas.md` | "BACKLOG-Items ausgelöst" | ScrollView/Start-Toggle nur als Backlog-Idee | In 4.1 umgesetzt, nicht released | `docs/v4.1/09-final-report.md` 3.1 |

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
| `MEMORY.md` und 5 Projekt-Memories | lokal (Memory) | Zwei neue Memories (`v41_status`, `airplay_research`); `v345_pending`, `v401_workflow_pending`, `v4_tags_pending`, `support_thomas` auf Stand; Index aktualisiert |

Konsistenzprüfung: kein eigener Doku-Satz mehr mit "v3.4.5 ausstehend" (die
verbliebene Fundstelle in `MEMORY.md` ist ein wörtliches Zitat über Tims veralteten
DB-Stand, mit UPDATE-Klausel eingeordnet). Keine Em- oder En-Dashes in neu
geschriebenem Text. Keine Nutzer- oder Drittnamen in getrackten Dateien (getrackt
geändert wurden nur `docs/v4.1/README.md` und diese Datei). Getrackter Arbeitsbaum
nach den Commits sauber.

