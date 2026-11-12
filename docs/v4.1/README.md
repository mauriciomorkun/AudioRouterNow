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
| [03-impl-v1.md](03-impl-v1.md) | Umsetzungsprotokoll v1 (Umsetzer: Opus). Pro Schritt Status, Commit-Hash, Test- und Build-Ergebnis, Abweichungen. Gesamtstand, offene Messpunkte (M1-M8), bestätigte Entscheidungen (E1, E3, E4, E6), Restrisiken. Teststand nachher: 59 swift-testing plus 56 XCTest, App-Build SUCCEEDED. Status: fertig, Audit durch zweiten Fable-Agenten ausstehend. |

## Hinweis zur Quellenlage

Jedes Dokument in diesem Ordner trennt strikt zwischen:

- **belegt:** mit einer zitierbaren Quelle.
- **gemessen:** mit einem konkreten Befehl und einem konkreten Ergebnis auf echter Hardware.
- **ungeprüft:** von der Recherche genannt, aber hier nicht nachvollzogen.
- **Annahme:** Hypothese, die erst noch zu prüfen ist.

Diese Einordnung steht in den Tabellen jedes Dokuments. Eine Aussage ohne
diese Markierung gilt als nicht gesichert.
