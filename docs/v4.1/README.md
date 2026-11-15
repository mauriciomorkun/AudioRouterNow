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
| [14-plan-nachtrag.md](14-plan-nachtrag.md) | Nachtragsplan Fassung 2 (Planer: Fable 5, 2026-11-14). Scope: W1 (Lautstärke, Solo, Pegel und Welle für alle Ausgaben: Kapazität 256 aus einer Konstante, gemessene Kosten, Liste aller festen Größen, sichtbare Sperre und Startfehler oberhalb der Grenze) und W2 (Welle unter Solo bleibt gleich hoch, reine Kit-Funktion). 11 Schritte NT-S0 bis NT-S10, 7 Entscheidungen NT-D1 bis NT-D7. Zu bestätigen: NT-D1, NT-D4, NT-D5, NT-D7. Ersetzt Fassung 1 (Commit `4c7dbfe`, Grenze 32 mit stillem Degradieren darüber). Status: umgesetzt, siehe 15. |
| [15-impl-nachtrag.md](15-impl-nachtrag.md) | Umsetzungsprotokoll des Nachtrags (Umsetzer: Fable 5, Durchlauf 1 von höchstens 3). Pro Schritt NT-S0 bis NT-S10 Status, Commit-Hash, Test- und Build-Ergebnis, Abweichungen. Gesamtteststand, offene Messpunkte NM-1 bis NM-7, Restrisiken, Preflight-Ergebnis. Status: fertig. |
| [16-audit-nachtrag-v1.md](16-audit-nachtrag-v1.md) | Audit Nachtrag Durchlauf 1 (Auditor: Fable 5, 2026-11-15). 60 swift-testing + 95 XCTest gruen, Build SUCCEEDED, Preflight unveraendert (1 ABBRUCH, 2 Warnungen). W1 und W2 erfuellt. 2 Befunde mittel (G1: Testluecke Solo-Neutralitaet W2, G2: outputLimitNotice nicht synchronisiert mit Start-Fehlerpfad), 3 Befunde niedrig. Neuer Durchlauf noetig. Status: fertig. |
| [17-plan-nachtrag-v2.md](17-plan-nachtrag-v2.md) | Nachtragsplan Durchlauf 2 (Planer: Fable 5, 2026-11-15). Scope: G1 (Signaturtest W2), G2-Luecke-2 (outputLimitNotice bei Erfolg loeschen), G3 (Kommentar), G4 (bereits geloest), G5 (Kommentar). 4 Schritte NT2-S0 bis NT2-S4, 5 Entscheidungen NT2-D1 bis NT2-D5. Status: umgesetzt, siehe 15 und 18. |
| [18-impl-nachtrag-v2.md](18-impl-nachtrag-v2.md) | Umsetzungsprotokoll Durchlauf 2 (Umsetzer: Fable 5, 2026-11-15). Pro Schritt NT2-S0 bis NT2-S4 Status, Commit-Hash, Test- und Build-Ergebnis, Abweichungen. Gesamt: 60/96 gruen, BUILD SUCCEEDED. Status: fertig. |
| [19-audit-nachtrag-v2.md](19-audit-nachtrag-v2.md) | Audit Nachtrag Durchlauf 2 (Auditor: Fable 5, 2026-11-15). 60 swift-testing + 96 XCTest gruen, Build SUCCEEDED, Preflight unveraendert (1 ABBRUCH, 2 Warnungen). G1 bis G4 behoben. G5: Kommentar eingefuegt, aber 1 Befund mittel (H1: Zahlenwert falsch, 5120 statt 20 Allokationen/s). 2 Befunde niedrig. Neuer Durchlauf noetig. Status: fertig. |
| [20-plan-nachtrag-v3.md](20-plan-nachtrag-v3.md) | Mini-Plan Nachtrag Durchlauf 3 (Planer: Fable 5, 2026-11-15). Scope: H1 (Kommentar-Zahlenfehler, mittel), H2 (Doppelbindestrich, niedrig), H3 (warmRestartForSampleRateChange, niedrig, akzeptiert ohne Code, NT3-D3). 4 Schritte N3-S0 bis N3-S4, 3 Entscheidungen NT3-D1 bis NT3-D3. Begruendung von NT3-D3 nachtraeglich am Code korrigiert (`2960723`). Status: umgesetzt, siehe 21. |
| [21-impl-nachtrag-v3.md](21-impl-nachtrag-v3.md) | Umsetzungsprotokoll Nachtrag Durchlauf 3 (Fable 5, 2026-11-15). H1 und H2 als reine Kommentarkorrekturen behoben, H3 als akzeptierter Rest ohne Code (NT3-D3). Suche nach weiteren Kommentarfehlern ohne Fund. 60 swift-testing + 96 XCTest gruen, Build SUCCEEDED, Preflight 1 ABBRUCH wie erwartet. Status: fertig. |
| [22-audit-nachtrag-v3.md](22-audit-nachtrag-v3.md) | Audit Nachtrag Durchlauf 3 (Auditor: Fable 5, 2026-11-15). 60 swift-testing + 96 XCTest gruen, Build SUCCEEDED, Preflight 1 ABBRUCH + 3 Warnungen (dritte Warnung: noch ungetrackte Auditdatei). H1 behoben (Zahlen geprueft: 20 Allokationen/s, 5120 Schreibzugriffe/s). H2 behoben (kein " -- " mehr). H3 akzeptierter Rest (NT3-D3, Begruendung am Code bestaetigt). Keine neuen Befunde. Nachtrags-Zyklus abgeschlossen. Status: fertig. |

## Hinweis zur Quellenlage

Jedes Dokument in diesem Ordner trennt strikt zwischen:

- **belegt:** mit einer zitierbaren Quelle.
- **gemessen:** mit einem konkreten Befehl und einem konkreten Ergebnis auf echter Hardware.
- **ungeprüft:** von der Recherche genannt, aber hier nicht nachvollzogen.
- **Annahme:** Hypothese, die erst noch zu prüfen ist.

Diese Einordnung steht in den Tabellen jedes Dokuments. Eine Aussage ohne
diese Markierung gilt als nicht gesichert.
