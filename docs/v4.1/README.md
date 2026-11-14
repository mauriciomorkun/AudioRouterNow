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
| [05-decisions.md](05-decisions.md) | Entscheidungen Zyklus 2. D1: Launch-at-Login-Reset beim Build-Sprung 10 auf 11, begruendet, Rueckfall dokumentiert. Status: erstellt. |
| [06-appstore-texts.md](06-appstore-texts.md) | App Store Connect Textvorlagen: What's New (oeffentlich), Review-Notiz (nicht oeffentlich), Store-Description-Ersetzungsanleitung Schritt fuer Schritt. Status: erstellt. |
| [07-impl-v2.md](07-impl-v2.md) | Umsetzungsprotokoll v2 (Umsetzer: Opus, Durchlauf 2). Pro Schritt N0-N7 Status, Commit-Hash, Test- und Build-Ergebnis, Abweichungen. Preflight-Ergebnis, offene Messpunkte, Restrisiken. Status: fertig. |
| [08-audit-v2.md](08-audit-v2.md) | Audit Durchlauf 2 (Auditor: Fable 5). Tests 59 swift-testing + 56 XCTest gruen, Build SUCCEEDED, Preflight "4.1 (11)" erkannt. B1-B5 behoben. 1 neuer Befund niedrig (C1: Naming-Kollision D1 in Doku). Kein neuer Durchlauf noetig. Status: fertig. |
| [09-final-report.md](09-final-report.md) | Abschlussbericht (Phase 4): Umfang, Ergebnis je Punkt, Ablauf der zwei Durchlaeuf, Befunde B1 bis B5 und C1, Entscheidungen, Restrisiken, die offenen Messungen M1 bis M9 und die Nutzeraufgaben bis zur Einreichung. Wird in Durchlauf 3 erweitert. Status: fertig (Durchlauf 3 erweiternd). |
| [10-plan-v3.md](10-plan-v3.md) | Nachbesserungsplan v3 (Planer: Fable 5). Scope: F1 (CHANGELOG Blip-Formulierung), F2 (Kommentar-D1-Praezision), F3 (Known-Limitation maxSlots in CHANGELOG und RELEASE_NOTES), F4 (vier Korrekturen im Abschlussbericht). 5 Schritte P3-S0 bis P3-S4 plus README-Update P3-S5, 3 Entscheidungen P3-D1 bis P3-D3. Status: bereit zur Ausfuehrung durch Opus-Agent. |
| [11-impl-v3.md](11-impl-v3.md) | Umsetzungsprotokoll v3 (Umsetzer: Opus, Durchlauf 3). Pro Schritt P3-S0 bis P3-S5 Status, Commit-Hash, grep- bzw. Testergebnis, Abweichungen. Teststand nachher: 59 swift-testing plus 56 XCTest, App-Build SUCCEEDED. Status: fertig. |
| [12-audit-v3.md](12-audit-v3.md) | Audit Durchlauf 3 (Auditor: Fable 5). Tests 59 swift-testing + 56 XCTest gruen, Build SUCCEEDED, Preflight unveraendert. F1 bis F4 behoben. 1 neuer Befund niedrig (E1: Schrittanzahl in Abschlussbericht), 1 Beobachtung (E2: fehlender Hash in Impl-Protokoll). Kreislauf abgeschlossen. Status: fertig. |
| [13-doc-inventory.md](13-doc-inventory.md) | Doku-Inventur zur Pflege aller Projektdokumentation auf Stand 14.11.2026 (Doku-Agent: Sonnet). Geprüfte Fakten gegen Git, `gh release list` und `gh issue view 1`, Liste veralteter oder widersprüchlicher Aussagen vor der Änderung (Datei, Stelle, alt, neu, Beleg) und das Ergebnis der Pflege. Status: fertig. |

| [14-plan-nachtrag.md](14-plan-nachtrag.md) | Nachtragsplan (Planer: Fable 5, 2026-11-14). Scope: W1 (Lautstaerke, Solo, Pegel und Welle fuer alle Ausgaben, maxSlots 16 auf 32) und W2 (Welle unter Solo bleibt unveraendert hoch). 8 Schritte NT-S0 bis NT-S7 plus NT-S8, 6 Entscheidungen NT-D1 bis NT-D6. Zwei ENTSCHEIDUNG NUTZER BESTAETIGEN-Punkte (NT-D1 Kapazitaet, NT-D4 Wellen-Auslegung). Status: Final, bereit zur Ausfuehrung durch Fable-Agent. |

## Hinweis zur Quellenlage

Jedes Dokument in diesem Ordner trennt strikt zwischen:

- **belegt:** mit einer zitierbaren Quelle.
- **gemessen:** mit einem konkreten Befehl und einem konkreten Ergebnis auf echter Hardware.
- **ungeprüft:** von der Recherche genannt, aber hier nicht nachvollzogen.
- **Annahme:** Hypothese, die erst noch zu prüfen ist.

Diese Einordnung steht in den Tabellen jedes Dokuments. Eine Aussage ohne
diese Markierung gilt als nicht gesichert.
