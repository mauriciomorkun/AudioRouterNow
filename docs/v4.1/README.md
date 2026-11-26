# AudioRouterNow 4.1: Arbeitsaufzeichnung

Dieser Ordner sammelt die Vorarbeiten und Recherchen für das Update 4.1. Er
folgt demselben Zweck wie `docs/v4.0.1/`: nicht was am Ende ausgeliefert wird,
sondern wie die Entscheidungen zustande kamen, welche Annahmen sich als falsch
erwiesen, und welche Behauptungen noch unbewiesen sind.

## Entscheidung: Bedienoberflaeche (C3 mit V2, getroffen am 17.11.2026)

**Der Nutzer hat am 17.11.2026 C3 mit V2 gewaehlt** (im Stand der Test-App
"AudioRouterNow 4.1 TEST C3b"). Diese Bedienoberflaeche bleibt in der finalen 4.1.
Die Varianten C und C2 sind damit verworfen und nur noch als Patches unter
`.claude/variants/` archiviert.

**Begruendung des Nutzers (soweit bekannt):** C3 gefaellt ihm am Geraet. Die
V2-Kennzeichnung (bereits hinzugefuegte Ausgaenge mit Haken, ausgegraut, nicht
waehlbar) hat er in der Test-App "AudioRouterNow 4.1 TEST C3b" am Geraet gesehen,
markiert und verdunkelt. Die Scrollbarkeit des "Add device"-Menues hat er mit der
Pruefhilfe "AudioRouterNow 4.1 TEST C3 LISTE" (120 kuenstliche Eintraege) am Geraet
bestaetigt. Weitere Begruendungen sind nicht festgehalten.

**Was dadurch festgelegt ist:** ein grosser Start/Stop-Knopf oben (unter der
Statuszeile, ausserhalb der Scroll-Ansicht) als einziger Start/Stop-Knopf, keine
Start/Stop-Pille in der Statuszeile und keine Pille im Footer, Support als Mint-Pille
mit Herz und Wort "Support", Hover-Erklaerungen fuer die Footer-Symbole, Footer in
einer Reihe, dazu V2 im "Add device"-Menue (bereits hinzugefuegte Paare mit Haken und
ausgegraut, bei allen hinzugefuegt der deaktivierte Hinweis "All outputs are
added.").

### Verworfene Varianten und ihre Sicherungsorte

| Variante | Kurzbeschreibung | Sicherung (archiviert) |
|----------|------------------|------------------------|
| **C** | Mint-Pille "Start" in der Statuszeile, grosser Knopf im Footer | `.claude/variants/C1-obere-pille/` (`C1.patch`) |
| **C2** | grosser Knopf oben plus Pille im Footer, Footer in zwei Reihen | `.claude/variants/C2-grosser-knopf-oben/` (`C2.patch`) |

Der gewaehlte Stand C3 mit V2 (C3b) ist als `.claude/variants/C3b-aktuell/`
(`C3b.patch` plus `untracked/`) gesichert und entspricht dem Arbeitsbaum von
`release/4.1`.

### Vergleichstabelle (historischer Verlauf vor der Entscheidung)

Die folgende Tabelle hielt die drei Varianten vor der Entscheidung gegenueber. Sie
bleibt als Verlauf stehen; gewaehlt ist C3 mit V2.

| Variante | Layout (Skizze) | Staerken | Schwaechen / Risiken | Test-App (Desktop) | Sicherung / Rueckweg | Pruefstand |
|----------|-----------------|----------|----------------------|--------------------|----------------------|------------|
| **C** | Statuszeile traegt rechts eine Mint-Pille "Start" (Leerlauf) bzw. runder Stop-Knopf (aktiv); grosser Start-Knopf bleibt unten im Footer. `[• status  (Start)]` ... `[ Start Routing ]`(Footer) | Vertraute Footer-Position des grossen Knopfs; Pille oben zusaetzlich sichtbar | Bei langer Liste ist der grosse Footer-Knopf wieder ausser Sicht (der Ausgangsfall); zwei Start-Elemente | "AudioRouterNow 4.1 TEST (neu).app" | `.claude/variants/C1-obere-pille/` (`C1.patch`); Rueckweg: Arbeitsbaum zuruecksetzen, Patch anwenden | ImageRenderer-Nachbau, nicht am Geraet |
| **C2** | grosser Start/Stop-Knopf OBEN (unter der Statuszeile, ausserhalb der Scroll-Ansicht); kompakte Pille unten im Footer neben Quit; Footer in zwei Reihen. `[ Start Routing ]`(oben) ... `[(Start) ... Quit]` / `[Launch ♥🔒🔇🐞]` | Grosser Knopf immer sichtbar (loest den Ausgangsfall); Footer aufgeraeumt | Footer-Pille neben dem immer sichtbaren oberen Knopf wirkt redundant; zwei Reihen = mehr Hoehe (volle Liste 621 pt im Nachbau) | "AudioRouterNow 4.1 TEST C2.app" | `.claude/variants/C2-grosser-knopf-oben/` (`C2.patch`); Rueckweg wie C | ImageRenderer-Nachbau, Start-Smoke-Test crashfrei, nicht am Geraet |
| **C3** (Arbeitsbaum) | grosser Knopf OBEN als einziger Start/Stop-Knopf; Footer-Pille entfernt; Support als Mint-Pille mit Herz und Wort "Support"; Hover-Sprechblasen fuer die Footer-Symbole; Footer in einer Reihe. `[ Start Routing ]`(oben) ... `[Launch (♥ Support) 🔒🔇🐞   Quit]` | Nur ein Start/Stop-Knopf, kein Dublettenrisiko; Support klarer; eine Reihe spart Hoehe (volle Liste 589 pt im Nachbau) | Hover-Bubble und VoiceOver nur am Geraet voll belegbar; "Launch at Login"-Umbruch bei grosser Dynamic Type nur abgesichert, nicht am Geraet bestaetigt | "AudioRouterNow 4.1 TEST C3.app" (C3b = C3 plus V2: "AudioRouterNow 4.1 TEST C3b.app") | aktueller Arbeitsbaum, gesichert als `.claude/variants/C3b-aktuell/` (`C3b.patch` plus `untracked/`); Rueckweg wie C | ImageRenderer-Nachbau, unabhaengiger Audit `24-audit-ui-c3.md` (Freigabe mit Auflagen, danach nachgebessert), nicht am Geraet |

NICHT zur Auswahl standen (zur Klarstellung ausdruecklich genannt):

- **Urzustand 4.1 (P1):** kleines Start/Stop-Icon (Dreieck/Quadrat) rechts in der
  Statuszeile, grosser Start-Knopf im Footer. Verworfen, weil das Icon nicht als
  Knopf erkannt wurde. Test-App "AudioRouterNow 4.1 TEST.app".
- **Pruefhilfe (C3 LISTE):** "AudioRouterNow 4.1 TEST C3 LISTE.app" mit 120
  kuenstlichen Eintraegen im "Add device"-Menue, die kein Routing ausloesen. Reine
  Pruefhilfe fuer die Scrollbarkeit (`25-add-device-liste.md`), keine Variante.

**V2 (Add-device-Menue, Duplikate gekennzeichnet)** ist Teil des gewaehlten Stands
C3b. V2 betrifft nur das native "Add device"-Menue (bereits hinzugefuegte Paare mit
Haken und ausgegraut, Hinweis "All outputs are added."). Umgesetzt und auditiert
(`25-add-device-liste.md`, Abschnitt "Audit V2": Freigabe). Die Logik liegt
ausschliesslich in `AddDeviceRow` (`DeviceCardView.swift`) plus der reinen Kit-Logik
`AddDeviceMenuModel`.

### Nach der Entscheidung noch zu tun

1. Den Stand C3 mit V2 (bereits im Arbeitsbaum) committen; die Varianten C und C2
   bleiben als Patches unter `.claude/variants/` archiviert.
2. RELEASE_NOTES auf den Endstand C3 mit V2 bringen (der CHANGELOG beschreibt bereits
   C3 mit V2; RELEASE_NOTES beschrieb noch den aelteren Statuszeilen-Stand, siehe
   `13-doc-inventory.md`).
3. `v4/scripts/preflight.sh`, Datum im CHANGELOG, Tag `v4.1`, neues Archiv, Merge,
   Push, Einreichung (verbindliche Reihenfolge in `09-final-report.md`, Abschnitt 8).
   Nur auf Anweisung des Nutzers.

### Pruefpunkte am Geraet

Am Geraet bereits gesehen: Scrollbarkeit des "Add device"-Menues (Pruefhilfe
"TEST C3 LISTE") und die V2-Kennzeichnung (markiert, verdunkelt, nicht waehlbar, in
"TEST C3b"). Weiterhin offen: M1 (ScrollView und Sichtbarkeit des oberen Knopfs bei
langer Liste), M2 (Start/Stop ueber den oberen Knopf), M2b (Knopfoptik oben und
Footer), M2c (Hover-Erklaerungen im echten Panel, VoiceOver). Anleitungen in
`09-final-report.md`, Abschnitt 7.

Zur Einordnung: C3 loest nur das aktuelle Darstellungsproblem. Ein breiterer Wunsch
"Geraete im Menue ausblenden" liegt als v4.2-Idee im BACKLOG ("Device Visibility
Filter"), nicht Teil dieser Entscheidung. V1 (Untermenue je Mehrkanalgeraet) und V3
(Suchfeld-Popover) im "Add device"-Menue bleiben offene Ideen ohne Termin.

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
| [23-ui-start-button-oben.md](23-ui-start-button-oben.md) | UI-Nachtrag (2026-11-16). Drei Teile. Teil C (Verlauf): der obere Start/Stop-Knopf in der Statuszeile war ein nacktes Symbol und wurde nicht als Knopf erkannt (zwei Screenshots des Nutzers); Variantenvergleich A/B/C, gewaehlte Loesung C (Pille oben, grosser Knopf unten). Teil C2 (Verlauf): die Positionen getauscht, der grosse Knopf nach oben, die Pille in den Footer, Footer in zwei Reihen. Teil C3 (aktueller Stand): der grosse Knopf bleibt oben und ist der einzige Start/Stop-Knopf, die Footer-Pille ist entfernt (samt der nur fuer sie gebauten `HeaderToggle`-Logik und ihren Tests), der Support-Knopf ist als Mint-Pille mit Wort "Support" aufgewertet (Bewertung von vier Varianten), die Footer-Symbole bekommen eine eigene SwiftUI-Hover-Bubble im Fenster (von NSToolTip unabhaengig, am Rand geclampt; `.help` an diesen Elementen entfernt), der Footer ist eine Reihe. Enthaelt Support-Bewertungstabelle, Hover-Verfahren mit technischer Begruendung, Tooltip-Texte je Symbol, Layout-Skizze, Hoehenrechnung, Barrierefreiheit, Tests (60 swift-testing plus 110 XCTest), visuelle Pruefung per ImageRenderer, Sicherungen von C und C2 unter `.claude/variants/`, was nicht geprueft ist. Tooltip-Texte testbar in `AudioRouterKit.FooterTips` (neu). Enthaelt auch die Audit-Nachbesserung (Abschnitt 6b) nach `24-audit-ui-c3.md`: Doku-Nachzug im Abschlussbericht 3.1, Umbruchschutz fuer Launch at Login, Support und Quit (`lineLimit(1)` plus `fixedSize`), `accessibilityHint` aus derselben Quelle wie die Hover-Bubble, `clearHover()` auch in Lock und Exclusive. Tests danach 60 swift-testing plus 112 XCTest. Status: umgesetzt; C3 am 17.11.2026 vom Nutzer gewaehlt (C3 mit V2), nicht am Geraet verifiziert. |
| [25-add-device-liste.md](25-add-device-liste.md) | Frage (2026-11-17): Ist die "Add device"-Liste scrollbar bei sehr vielen Ausgaengen (BlackHole 64ch = 32 Paare, ueber 100 Eintraege)? Antwort JA, belegt: das `Menu` in `AddDeviceRow` ist ein natives macOS-NSMenu, das bei Ueberlaenge scrollt (Scroll-Pfeil, Scrollrad, Tastatur). Direkt gemessen an einem NSMenu mit 300 Eintraegen: das Menue-Fenster wurde auf 1090 pt (Bildschirm 1440 pt) begrenzt statt 5700 pt, mit Scroll-Pfeil (Screenshot `/tmp`). Das echte SwiftUI-Menue per Klick nicht automatisierbar (Accessibility-Rechte fehlten, kein Dialog ausgeloest). Entscheidung Fall A: keine Code-Aenderung, kein CHANGELOG-Eintrag, nur Doku. Drei Verbesserungsvorschlaege mit Aufwand/Risiko (V1 Untermenue je Multi-Channel-Geraet, V2 bereits hinzugefuegte Paare mit Haken/ausblenden, V3 Suchfeld-Popover). V2 ist nun umgesetzt (2026-11-17, Abschnitt "V2 umgesetzt"): bereits hinzugefuegte Paare (uid plus channelOffset) erscheinen mit Haken und ausgegraut (deaktivierter `Toggle` im Menue, systemkonformer NSMenu-Haken laut Apple), bei "alle hinzugefuegt" ein Hinweis "All outputs are added."; Logik testbar im Kit (`AddDeviceMenuModel`, 17 Tests), Testversion "AudioRouterNow 4.1 TEST C3b.app". V1 und V3 weiter nicht umgesetzt. Pruefhilfe-App "AudioRouterNow 4.1 TEST C3 LISTE.app" auf dem Desktop (120 kuenstliche Eintraege, die kein Routing ausloesen). Status: Scrollbarkeit fertig (Fall A, am Geraet bestaetigt), V2 Teil der finalen 4.1 (Entscheidung 17.11.2026). |
| [24-audit-ui-c3.md](24-audit-ui-c3.md) | Unabhaengiger Audit der Variante C3 (Opus, 2026-11-16). Urteil "Freigabe mit Auflagen", keine Blocker. Prueft Tooltip-Texte am Code, Hover-Bubble-Robustheit und Clamping (nachgerechnet), restlose Entfernung der `HeaderToggle`-Logik, Footer-Layout und Umbruchrisiko bei grosser Dynamic Type, App-Review-Regeln, Tests und Stil, Signierung der Test-App, Regressionen. Zwei "sollte behoben" (Doku-Nachzug 3.1, Launch-at-Login-Umbruch) und drei kosmetische Punkte (accessibilityHint, Nicht-C3-Diff an `.gitignore`, `clearHover` bei Lock/Exclusive); alle ausser dem `.gitignore`-Punkt in Abschnitt 6b von Dok 23 behoben. Status: fertig. |
| [26-release-plan.md](26-release-plan.md) | Release-Plan: der Weg von `release/4.1` bis zur Einreichung bei App Review (Ist-Stand, Commit-Plan, Voraussetzungen vor dem Archiv, Release-Ablauf, Risiken, Nutzerentscheidungen). Status: fertig (17.11.2026), Architekturaussage am selben Tag korrigiert (v4 ist belegt universal). |
| [27-messprotokoll.md](27-messprotokoll.md) | Messprotokoll der Sitzung am Gerät (21. bis 23.11.2026). 23 Zeilen mit Anleitung, Ergebnis und Notiz je Messpunkt (M1 bis M9, M2b/M2c/M2d, NM-1 bis NM-7, vier Zusatzzeilen): 23 ok, 0 offen, keine negativ. Mit Zeitstempeln aus dem System-Log, Screenshots, CPU- und Speicherwerten bei 3, 18 und 48 Zeilen und der Dokumentation der vorübergehenden BlackHole-Messumgebung. Einordnung: `09-final-report.md` Abschnitt 12. |
| [28-release-runbook.md](28-release-runbook.md) | Release-Runbook (24.11.2026): Ist-Stand, vier Tore (Upload, Einreichung, Release, Öffentlichkeit), 19 Schritte vom Archiv bis zur Nachsorge mit Ablehnungszweig, Smoke-Test des Store-Builds, Risikoregister, Ergebnis des Vor-Push-Audits (keine Zugangsdaten, Team-Kennung schon öffentlich), Liste überholter Dokumentstellen und Entscheidungen D1 bis D7. Abschnitt 8 (Übergabe, 24.11.2026): Upload erledigt, Version 4.1 im Portal angelegt, Stand der Portal-Schritte P1 bis P9 mit dem nächsten Schritt (Screenshots ersetzen). Nur App-Ablauf, kein Marketing. Erarbeitet aus fünf Fachprüfungen und zwei Gegenprüfungen. |
| [screenshots/](screenshots/README.md) | Sechs Screenshots der Test-Version (Endstand C3 mit V2), aufgenommen am Gerät am 18.11.2026: Leerlauf, Hover-Hinweis am Bug-Symbol, Routing mit 3 Ausgängen, Solo, aufgeklappter Ausgang, Add-device-Menü mit Haken. Arbeitsbilder (Fensterausschnitte), keine fertigen App-Store-Screenshots. |

## Stand vor dem Archiv (18.11.2026)

Checkliste der Vorbereitungen bis zum 4.1-Archiv. Belege und Details in
`26-release-plan.md` (Hauptteil und Nachtrag 18.11.2026).

**Erledigt:**

- [x] Bedienoberflaeche entschieden: C3 mit V2 (17.11.2026).
- [x] E2 (Architektur) entschieden: Option A, universal belassen, kein ARCHS
      (18.11.2026); v4-Aussagen ehrlich formuliert, v3 unveraendert.
- [x] C3/V2-Arbeitsbaum lokal in Commits gesichert (`1a5a959`, `730b8cf`,
      `30c4d5e`, `01125b5`, `27dcd0e`, `4942a34`). Nicht gepusht, kein Tag.
- [x] Signierung in `v4/project.yml` vorbereitet (`CODE_SIGN_STYLE: Automatic`;
      Team ID bleibt in der gitignorierten `Signing.local.xcconfig`). In einer
      /tmp-Kopie belegt, dass `xcodegen generate` damit die heutige Signierung
      reproduziert. Nicht committet.
- [x] `v4-appstore/` umkehrbar umbenannt nach `v4-appstore.STALE-2026-10-01`;
      Preflight-Warnung dazu entfaellt.
- [x] Screenshot-Vorlage vorhanden (Endstand C3 mit V2, `screenshots/`).

**Offen (beim Nutzer):**

- [x] Messpunkte am Geraet (M1 bis M9, M2b/M2c/M2d, NM-1 bis NM-7): durchgefuehrt 21. bis 23.11.2026, keiner negativ (siehe unten, `27-messprotokoll.md`). Zusatzzeilen offen.
- [x] Lokale `Signing.local.xcconfig` ist angelegt (18.11.2026, Team ID aus `project.pbxproj`, gitignoriert, belegt am 23.11.2026: Datei vorhanden, `DEVELOPMENT_TEAM` gesetzt). Vor dem Archiv in Xcode prüfen, dass das Team angezeigt wird.
- [ ] Neues 4.1-Archiv bauen und signieren (behebt den Preflight-ABBRUCH).
- [ ] Preflight erneut, App-Store-Connect-Texte, Datum, Tag, Merge, Push,
      Einreichung. Nur auf ausdrueckliche Anweisung.

## Stand nach der Messsitzung (23.11.2026)

Die Messsitzung am Gerät ist durchgeführt. Belege je Messpunkt in `27-messprotokoll.md`,
Einordnung in `09-final-report.md` (Abschnitt 12).

**Ergebnis:** 23 von 23 Zeilen ok, keine offen (Stand 24.11.2026), keine negativ. Der feste Rückfall bei M8
(Commit `5798a63` umkehren) wurde nicht ausgelöst. M8 war zunächst falsch als ok
eingetragen, nach der Log-Auswertung zurückgenommen und nach einer Wiederholung mit
schnellem Wiedereinstecken (dreimal "L1: Blip erkannt", kein Engine-Neustart) bestätigt.

**Gemessen mit vorübergehender Zusatzhardware:** Mit BlackHole 16ch und 64ch (Homebrew,
nur für die Messung, danach entfernt) lief der Mac mit 48 Zeilen. Dabei: Liste scrollt,
Oberfläche bedienbar (M1, NM-5), Lautstärke und Solo auf Platz 17 und 33 wirken (M5,
NM-1), CPU unabhängig von der Zeilenzahl (NM-4), etwa 70 KiB Speicher je Zeile (NM-7).
Die Limit-Meldung (NM-6) wurde mit einer Testkopie mit `maxSlots = 4` in `/tmp` geprüft,
das Repo blieb unverändert.

**Offen nach der Sitzung:**

- [x] Zusatzzeilen VoiceOver-Hinweis, Tab-Fokus-Reihenfolge, Umbruch bei großer Schrift: am 24.11.2026
      auf Nutzerangabe ok.
- [x] CPU-Vergleich mit der Store-Version 4.0.1 (erledigt 23.11.2026): 38,7 Prozent (4.0.1)
      gegenüber 41,5 Prozent (4.1) bei 3 Zeilen, kein Unterschied im Rahmen der Streuung.
      Die Basislast von etwa 40 % eines Kerns hat schon 4.0.1.
- [x] Launch-at-Login-Reset (6d) angenommen, Gerätename "NI Audio 4 DJ" in den Screenshots bleibt (beides 23.11.2026, `09-final-report.md` Abschnitt 12.5). E1, E4, E6, 6a nicht ausdrücklich bestätigt, die Messungen widersprechen nicht.
- [x] Neues 4.1-Archiv gebaut und geprüft (23.11.2026, 17:23 Uhr, aus HEAD `429b865`), Preflight ohne
      Abbruchgrund (siehe `09-final-report.md` Abschnitt 12.4).
- [x] Hochladen, App-Store-Connect-Texte, Einreichung erledigt (25.11.2026).
      CHANGELOG und RELEASE_NOTES auf "submitted 2026-11-24" gesetzt (Commit `3122566`).
      Tag, Merge und Push erst nach dem Release (Tor D), nur auf ausdrückliche Anweisung.

## Stand nach der Einreichung (25.11.2026)

4.1 (Build 11) wurde am 25.11.2026 bei Apple eingereicht. Status: "Waiting for Review".

Portal vollständig ausgefüllt: 5 Screenshots (C3-Motive 2880x1800, 01 bis 05), What's New (Langfassung
mit 255-Limit), Review-Notiz (6 Punkte), Superlativ ersetzt, Promotional Text Variante A,
Subtitle/Keywords angepasst, Privacy gecheckt, Altersfreigabe-Bereich nicht geöffnet.

CHANGELOG und RELEASE_NOTES auf Einreichungsdatum gesetzt (Commit `3122566`). Kein Push, kein Tag,
kein Merge, keine öffentlichen Aktionen bis zur Genehmigung und ausdrücklichen Freigabe durch den Nutzer.

Noch offen: S06 TestFlight-Smoke-Test (empfohlen, gatet Tor C/Release), Apple-Prüfung (1 bis 3 Tage).

## Stand nach dem Release (26.11.2026)

4.1 (Build 11) ist seit **26.11.2026** im Mac App Store live. Apple-Genehmigung kam am selben Tag
wie die Einreichung (Thanksgiving US, 1 Tag Review). Release manuell ausgelöst um ca. 14:00 CET
durch den Nutzer ("Release this version" im Portal). Phased Release deaktiviert (volle Auslieferung
an alle Nutzer sofort).

Landing Page (audiorouternow.mauriciomorkun.com) bereits vor dem Release-Klick aktualisiert:
3 neue Feature-Karten (Scroll, Solo, 255 Outputs), 5 neue Screenshots (ss41-01 bis ss41-05, 2880x1800).
Buffer-Kampagne: 11 Posts eingereiht (P01-P10 geplant, P11 als Draft), P01 um 15:00 CET.

Tor D abgeschlossen: FF-Merge nach `main`, Tag `v4.1`, Push, GitHub Release erstellt.

## Hinweis zur Quellenlage

Jedes Dokument in diesem Ordner trennt strikt zwischen:

- **belegt:** mit einer zitierbaren Quelle.
- **gemessen:** mit einem konkreten Befehl und einem konkreten Ergebnis auf echter Hardware.
- **ungeprüft:** von der Recherche genannt, aber hier nicht nachvollzogen.
- **Annahme:** Hypothese, die erst noch zu prüfen ist.

Diese Einordnung steht in den Tabellen jedes Dokuments. Eine Aussage ohne
diese Markierung gilt als nicht gesichert.
