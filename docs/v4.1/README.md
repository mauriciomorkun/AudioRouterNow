# AudioRouterNow 4.1: Arbeitsaufzeichnung

Dieser Ordner sammelt die Vorarbeiten und Recherchen für das Update 4.1. Er
folgt demselben Zweck wie `docs/v4.0.1/`: nicht was am Ende ausgeliefert wird,
sondern wie die Entscheidungen zustande kamen, welche Annahmen sich als falsch
erwiesen, und welche Behauptungen noch unbewiesen sind.

## Inhalt

| Dokument | Was darin steht |
|----------|-----------------|
| [01-airplay-research.md](01-airplay-research.md) | Recherche zur AirPlay-Unterstützung. Warum keine AirPlay-Geräte in der Ausgabeliste erscheinen, was gemessen wurde, was belegt ist, was nur Annahme bleibt, und ein konkreter Echttest-Plan mit dem Volumio-Gerät des Nutzers. Status: Entscheidung offen |
| [02-plan-v1.md](02-plan-v1.md) | Durchführungsplan v1 (Planer: Fable 5). Scope P1-P5: ScrollView plus Header-Toggle, Solo-Button, SR-Listener-Fix, Entprellen, Store-Description. 12 nummerierte Schritte (S0-S12), 8 Entscheidungen (E1-E8), 14 Audit-Punkte (A1-A14), 8 Messpunkte (M1-M8). Baseline-Tests konnten nicht laufen (Xcode-Lizenz). Status: bereit zur Ausführung durch Opus-Agent. |
| [03-impl-v1.md](03-impl-v1.md) | Umsetzungsprotokoll v1 (Umsetzer: Opus). Pro Schritt Status, Commit-Hash, Test- und Build-Ergebnis, Abweichungen. Gesamtstand, offene Messpunkte (M1-M8), bestätigte Entscheidungen (E1, E3, E4, E6), Restrisiken. Teststand nachher: 59 swift-testing plus 56 XCTest, App-Build SUCCEEDED. Status: fertig. |
| [04-audit-v1.md](04-audit-v1.md) | Audit Durchlauf 1 (Auditor: Fable 5). Build und Tests gruen. 3 Befunde: B1 mittel (Peak-Meter unter Solo zeigt falschen Pegel), B2 niedrig (RELEASE_NOTES-Formulierung), B3 niedrig (Testluecke leerer Key). Kein neuer Durchlauf notwendig. Status: fertig. |
| [05-plan-v2.md](05-plan-v2.md) | Nachbesserungsplan v2 (Planer: Fable 5). Scope: B1 (Peak-Meter unter Solo), B2 (RELEASE_NOTES-Formulierung hardware-neutral), B3 (Testluecke leerer Key unter aktivem Solo), B4 (Launch-at-Login-Reset-Doku: 05-decisions.md, CHANGELOG, RELEASE_NOTES, 06-appstore-texts.md), B5 (Preflight-Befund aufgenommen). 7 Schritte N0-N7. Keine weiteren Funde B6 ff. Status: bereit zur Ausfuehrung. |
| [05-decisions.md](05-decisions.md) | Entscheidungen Zyklus 2. D1: Launch-at-Login-Reset beim Build-Sprung 10 auf 11, begruendet, Rueckfall dokumentiert. Zu erstellen durch Umsetzer. |
| [06-appstore-texts.md](06-appstore-texts.md) | App Store Connect Textvorlagen: What's New (oeffentlich), Review-Notiz (nicht oeffentlich), Store-Description-Ersetzungsanleitung Schritt fuer Schritt. Zu erstellen durch Umsetzer. |

## Hinweis zur Quellenlage

Jedes Dokument in diesem Ordner trennt strikt zwischen:

- **belegt:** mit einer zitierbaren Quelle.
- **gemessen:** mit einem konkreten Befehl und einem konkreten Ergebnis auf echter Hardware.
- **ungeprüft:** von der Recherche genannt, aber hier nicht nachvollzogen.
- **Annahme:** Hypothese, die erst noch zu prüfen ist.

Diese Einordnung steht in den Tabellen jedes Dokuments. Eine Aussage ohne
diese Markierung gilt als nicht gesichert.
