# AudioRouterNow 4.1: Abschlussbericht

Phase 4 des Kreislaufs (Planung durch Fable, Umsetzung durch Opus, Audit durch
Fable, 3 Durchläufe). Geschrieben nach der Arbeit, ausschließlich aus den
Dokumenten in `docs/v4.1/`, dem Commit-Verlauf `e7db9fe^..HEAD` auf `release/4.1`
und den Angaben im Auftrag. Wo etwas in diesen Quellen nicht steht, steht hier
"ungeprüft". Dieser Bericht enthält keinen neuen Code und keine neue Messung. (Stand der Abschnitte 1 bis 11. Die Messsitzung am Gerät vom 21. bis 23.11.2026 steht in Abschnitt 12.)

> **Bedienoberflaeche entschieden: C3 mit V2 (17.11.2026).** Der Nutzer hat am
> 17.11.2026 C3 mit V2 gewaehlt (Stand der Test-App "AudioRouterNow 4.1 TEST C3b"):
> ein grosser Start/Stop-Knopf oben als einziger, Support als beschrifteter Knopf,
> Hover-Erklaerungen im Footer, Footer in einer Reihe, dazu V2 im "Add device"-Menue
> (hinzugefuegte Paare mit Haken und ausgegraut, Hinweis "All outputs are added.").
> Die Varianten C und C2 sind verworfen und nur noch als Patches unter
> `.claude/variants/` archiviert. Details, Begruendung und Sicherungsorte:
> `docs/v4.1/README.md`, Abschnitt "Entscheidung: Bedienoberflaeche". Die
> Nachtrag-Abschnitte unten (C, C2) bleiben als historischer Verlauf stehen; die
> Messpunkte M2/M2b/M2c/M2d beschreiben den gewaehlten Stand C3 mit V2.

## 1. Ergebnis in 5 Sätzen

1. Der Code von 4.1 (Version 4.1, Build 11) enthält eine scrollbare Geräteliste
   mit zusätzlichem Start/Stop-Schalter in der Statuszeile, einen Solo-Button pro
   Ausgabe, einen Sample-Rate-Listener mit Änderungserkennung und die Absorption
   kurzer Geräteaussetzer (Blips) beim Entfernen von Geräten, dazu die
   Release-Dokumentation und die Textvorlagen für App Store Connect.
2. Teststand zuletzt: 59 swift-testing in 10 Suiten und 56 XCTest, alle grün,
   App-Build (Debug, `CODE_SIGNING_ALLOWED=NO`) erfolgreich; beides haben die
   Audits 2 und 3 selbst ausgeführt.
3. Audit 1 fand 0 hohe, 1 mittleren und 2 niedrige Befunde, Audit 2 fand 0 hohe,
   0 mittlere und 1 niedrigen Befund (C1, Namenskollision einer Entscheidungs-ID in
   der Dokumentation), Audit 3 fand 0 hohe, 0 mittlere und einen niedrigen Befund
   (E1, falsche Schrittanzahl in diesem Bericht) sowie eine Beobachtung (E2,
   Platzhalter im Protokoll `11-impl-v3.md`); beides ist nach dem Audit direkt
   korrigiert worden. Alle Befunde B1 bis B5, C1 und F1 bis F4 sind behoben oder
   dokumentiert (`12-audit-v3.md`, Commit `5bf8d4f`).
4. Es fehlen alle Messungen am Gerät (M1 bis M9, keine ist erledigt) und die
   Einreichung (neues Archiv, App Store Connect, Tag, Merge, Push).
   *Nachtrag 23.11.2026: Die Messungen sind durchgeführt, keine fiel negativ aus
   (Abschnitt 12). Offen bleiben die Zusatzzeilen (VoiceOver-Hinweise, Tab-Fokus,
   große Schrift) und die Einreichung. Der CPU-Vergleich mit 4.0.1 ist am
   23.11.2026 gemacht, kein Unterschied (Abschnitt 12.1).*
5. Kein Agent hat gepusht, getaggt oder eingereicht; `preflight.sh` meldet bis zum
   Bau eines neuen Archivs einen ABBRUCH wegen des alten Archivs 4.0.1 (10).
6. Durchlauf 3 behebt F1 (CHANGELOG-Formulierung), F2 (Kommentar-Präzisierung),
   F3 (Known-Limitation-Absatz) und F4 (Berichts-Korrekturen). Das Audit dazu
   steht in `12-audit-v3.md`.

## 2. Umfang und Ausschlüsse

Zu 4.1 gehören laut Plan v1 (Scope-Freeze, Abschnitt 1.2) fünf Punkte:

| Punkt | Inhalt |
|-------|--------|
| P1 | ScrollView für die Geräteliste und Start/Stop-Schalter im Header |
| P2 | Solo-Button pro Ausgabe |
| P3 | Sample-Rate-Listener prüft die tatsächliche Änderung, dazu Entprellen beim Entfernen von Geräten (Blip-Absorption) |
| P4 | Store-Description ohne Superlativ |
| P5 | Versions- und Release-Mechanik |

Der Durchlauf 2 (Plan v2) hat keinen neuen Funktionsumfang, nur Nachbesserungen
zu B1 bis B5.

Ausdrücklich nicht Teil von 4.1 (Plan v1 und Plan v2, jeweils Abschnitt 1.2):

- AirPlay-Integration. Die Recherche liegt in `01-airplay-research.md`, die
  Entscheidung dort ist offen, ein Echttest mit verbundenem Gerät ist nicht gelaufen.
- Per-App-Routing.
- Bluetooth-Latenzkompensation und Intel-Support.
- Marketing-Inhalte (per Projektregel nicht im Repo).
- Aufräumen von `v4-appstore/`.
- Einreichung bei App Store Connect und Push.
- Die Consent-Mechanik von Launch at Login (`ensureLoginItemCompliance`,
  `hasValidLaunchAtLoginConsent`) wurde nicht angefasst.

## 3. Die Punkte im Einzelnen

Alle Zeilenangaben stammen aus den Audit-Dokumenten, nicht aus einer eigenen
Nachprüfung am Code.

### 3.1 ScrollView plus Header-Toggle (P1)

> **Nachtrag C3 (2026-11-16):** Der hier beschriebene Icon-Button in der
> Statuszeile (E3) ist im UI-Nachtrag C3 entfernt. Endstand: der grosse
> `RoutingButton` oben unter der Statuszeile ist der einzige Start/Stop-Knopf im
> Fenster; die Statuszeilen-Pille (C1) und die Footer-Pille (C2) sind beide
> entfernt, die zugehoerige `HeaderToggle`-Logik geloescht. Die ScrollView
> (`maxHeight: 400`) und der Footer ausserhalb der ScrollView bleiben unveraendert.
> Siehe `docs/v4.1/23-ui-start-button-oben.md`, Abschnitt "Variante C3", und den
> C3-Nachtrag am Ende dieses Berichts. Die folgende Tabelle beschreibt den Stand
> von P1 vor dem UI-Nachtrag.

| Feld | Inhalt |
|------|--------|
| Commit | `7700c3f` |
| Datei | `v4/AudioRouterNow4/MenuBarView.swift` |
| Änderung | Geräteliste in `ScrollView(.vertical)` mit `.frame(maxHeight: 400)` (Entscheidung E1). Footer mit Routing-Button bleibt außerhalb, `.fixedSize(vertical: true)` am Root bleibt. Ein Icon-Button (SF Symbol `play.fill`, `stop.fill` oder `ellipsis`) rechts in der Statuszeile (E3) |
| Abweichung vom Plan | Die Disabled-Bedingung des Toggles ist `ui == .starting \|\| (outputConfigs.isEmpty && !ui.isActive)`, deckungsgleich mit `RoutingButton.disabled`, nicht die Skizze des Plans (weicht nur im error-Zustand ab) |
| Automatisch getestet | Nichts. UI ist nicht in der Testsuite. Der Audit hat am Code geprüft: Footer außerhalb (A2), Höhe geklammert (A3), `fixedSize` am Root (A4), kein `GeometryReader` und kein `PreferenceKey`, stabile `ForEach`-ID `\.uid`, Aktionen des Toggles gleich denen des `RoutingButton` |
| Nur am Gerät messbar | M1 und M2. Dazu das Risiko R1 (CASE-003, früherer Absturz im selben View-Baum): Absturzfreiheit ist nur am Gerät belegbar |

### 3.2 Solo (P2)

| Feld | Inhalt |
|------|--------|
| Commits | `aabe549` (Zustand in `EngineController`), `6e71278` (reine Funktion `SoloGain.effective` in neuer Kit-Datei plus 7 XCTest), `146fbbb` (Solo-Button in `DeviceCardView`), `cba4489` (Anzeige-Korrektur, Durchlauf 2), `f2f7deb` (Testlücke, Durchlauf 2) |
| Dateien | `v4/AudioRouterNow4/EngineController.swift`, `v4/AudioRouterNow4/UI/DeviceCardView.swift`, `v4/AudioRouterKit/Sources/AudioRouterKit/SoloGain.swift` (neu), `v4/AudioRouterKit/Tests/AudioRouterKitTests/SoloGainTests.swift` (neu) |
| Änderung | `soloedKeys` (`@Published`, nur Sitzung, nicht gespeichert), `toggleSolo(for:)`, `applySoloGains()`. Solo wirkt ausschließlich über `engine.setOutputGain`. `setDeviceGain` persistiert immer den Nutzerwert und gibt der Engine 0, wenn der Slot durch fremdes Solo stumm ist. `soloedKeys` wird in `stopRouting()` geleert. `applySoloGains()` läuft nach `performStart()`, `restartRouting()`, `applyOutputsIfRouting()` und `warmRestartForSampleRateChange()`. Card-Opacity 0,4 bei Stummschaltung durch fremdes Solo (E4) |
| Abweichung vom Plan | `effectiveSoloGain` sollte statisch auf `EngineController` liegen. Das ist aus dem SPM-Test-Target nicht erreichbar, deshalb als `SoloGain.effective` in den Kit verschoben, `EngineController` delegiert. Eine Quelle der Wahrheit, kein Duplikat |
| Automatisch getestet | 7 XCTest in `SoloGainTests`. Nach Durchlauf 2 prüft der Test für den leeren Key auch den Fall unter aktivem Solo; die Assertion-Zahl stieg von 12 auf 14. Der Audit 2 hat die Bedingung probeweise invertiert und festgestellt, dass der Test dann rot würde (kein Tautologie-Risiko) |
| Nur am Gerät messbar | M3 (kein Knacksen, kein Pegelsprung), M4 (Solo-Gerät wird abgesteckt), M5 (Grenze `maxSlots`), M9 (Meter unter Solo). Dass die vorhandene Gain-Rampe (W1) im IOProc ein Knacksen verhindert, ist eine Annahme des Plans (E5), nicht gemessen |

### 3.3 Sample-Rate-Listener (P3, erster Teil)

| Feld | Inhalt |
|------|--------|
| Commits | `695e617` (Listener), `d5b08e5` (Tests) |
| Dateien | `v4/AudioRouterKit/Sources/AudioRouterKit/DeviceLifecycleManager.swift`, `v4/AudioRouterKit/Tests/AudioRouterKitTests/SRListenerTests.swift` (neu) |
| Änderung | `registerSRListeners` liest je Gerät eine Baseline der Nominal-Sample-Rate. Der Listener-Block vergleicht und löst `scheduleSRRestart` nur bei einer echten Änderung aus (Toleranz 0,5 Hz). Ein Lesefehler (`nil`) gilt konservativ als Änderung. Ein Aufruf ohne Änderung wird mit "M4-Noop" gezählt und geloggt (ohne Gerätenamen). `stop()` leert die Baselines, der Zähler bleibt |
| Automatisch getestet | 6 XCTest in `SRListenerTests`: gleiche Rate, kleine Änderung, echter Wechsel, `nil` konservativ, Grenze 0,5 Hz exakt, knapp darüber |
| Nur am Gerät messbar | M6 (Häufigkeit der Noop-Aufrufe über 15 Minuten) und M7 (Warm-Restart bei echtem Wechsel). Die reale Noop-Rate ist unbekannt |

### 3.4 Blip-Absorption (P3, zweiter Teil)

| Feld | Inhalt |
|------|--------|
| Commit | `5798a63` |
| Datei | `v4/AudioRouterKit/Sources/AudioRouterKit/DeviceLifecycleManager.swift` |
| Änderung | Im Pfad für ein zurückkehrendes Gerät wird ein noch ausstehender Restart verworfen, wenn `pendingRestart != nil` (Gerät kam innerhalb der Settle-Frist zurück), statt ihn durch einen neuen 2-Sekunden-Restart zu ersetzen. Kehrt das Gerät nach der Frist zurück, gilt unverändert der bisherige Pfad |
| Automatisch getestet | Kein eigener Test. Im Umsetzungsprotokoll steht für S8 nur der grüne Gesamtlauf. Der Audit hat die Logik am Code geprüft (Guard auf `pendingRestart`, `lastKnownMissingUIDs` wird vor dem `if` aktualisiert) |
| Nur am Gerät messbar | M8. Ob Aggregate und Tap einen Blip unbeschadet überstehen, ist laut Plan (E6, Kernrisiko) nicht aus dem Code belegbar. Reißt das Audio dauerhaft ab, ist der Schritt umzukehren |

### 3.5 Version und Release-Mechanik (P5)

| Feld | Inhalt |
|------|--------|
| Commits | `04a0589` (Version), `8f0496e` (CHANGELOG, RELEASE_NOTES), `fd502c7` (RELEASE_NOTES hardware-neutral), `68c8d71` (Hinweis zum Launch-at-Login-Reset) |
| Dateien | `v4/Configs/AudioRouterNow4.xcconfig` (4.0.1 / 10 auf 4.1 / 11), `CHANGELOG.md`, `RELEASE_NOTES.md` |
| Änderung | `MARKETING_VERSION = 4.1`, `CURRENT_PROJECT_VERSION = 11`. Der Abschnitt `[4.1 (11)]` trägt noch den Platzhalter `YYYY-MM-DD` für das Einreichungsdatum |
| Automatisch geprüft | `preflight.sh`: "xcconfig sagt 4.1 (11)", "Keine zweite Versionsquelle", "Tag v4.1 existiert noch nicht" jeweils OK. Der Audit 1 hat geprüft, dass `ensureLoginItemCompliance()` den Consent von Build 10 beim ersten Start mit Build 11 löscht |
| Nur am Gerät oder bei der Einreichung messbar | Das Verhalten nach dem Update bei Bestandsnutzern (Launch at Login aus, siehe 6d) ist nicht am Gerät beobachtet. Das neue Archiv und das Ergebnis von `preflight.sh` darauf (Abschnitt 6e) stehen aus |

### 3.6 Store-Description (P4)

| Feld | Inhalt |
|------|--------|
| Commit | `8eae52b` (Textvorlagen). Für den Schritt im Repo (S9) gab es keinen Commit |
| Datei | `docs/v4.1/06-appstore-texts.md` |
| Befund im Repo | Der Satz "the only sandboxed" steht in keiner getrackten, nutzersichtbaren Datei. Er steht nur in drei gitignorierten Dateien und im Plan als Zitat. Zu ersetzen ist er nur in App Store Connect |
| Vorlage | Ersatz: "AudioRouterNow runs fully sandboxed. No kernel extension. No virtual driver. No reboot." Dazu What's New (1103 Zeichen laut Audit 2, Limit 4000) und eine Review-Notiz |
| Automatisch geprüft | Zeichenlimits, kein Gedankenstrich, kein Nutzername (Audit 2) |
| Nur durch den Nutzer | Eintragen in App Store Connect (Abschnitt 8) |

## 4. Ablauf des Kreislaufs

### 4.1 Durchläufe

| Durchlauf | Plan | Umsetzung | Audit | Befunde | Behebung |
|-----------|------|-----------|-------|---------|----------|
| 1 | `02-plan-v1.md`, Commit `e7db9fe` (Fable, 12 Schritte S0 bis S12, 8 Entscheidungen E1 bis E8, 14 Audit-Punkte A1 bis A14, 8 Messpunkte M1 bis M8) | `04a0589` bis `8f0496e` (Version, Scroll-View, Solo, SR-Listener, Blip, Changelog), Protokoll `03-impl-v1.md` im Commit `c33f63b` (Opus) | `04-audit-v1.md`, Commit `338855e` (Fable): Build und 59 + 56 Tests grün | B1 mittel, B2 niedrig, B3 niedrig | In Durchlauf 2 |
| 2 | `05-plan-v2.md`, Commit `41d4673` (Fable, 7 Schritte N0 bis N7, Entscheidungen D1 und D2, Messpunkt M9) | `cba4489`, `fd502c7`, `f2f7deb`, `c079c27`, `68c8d71`, `8eae52b`, README `70fcfe0`, Protokoll `07-impl-v2.md` (Opus) | `08-audit-v2.md`, Commit `080f0c8` (Fable): Build, 59 + 56 Tests und Preflight selbst ausgeführt | B1 bis B5 behoben oder dokumentiert, neu: C1 niedrig | C1 in Durchlauf 3 |
| 3 | `10-plan-v3.md`, Commit `545f05e` (Fable, 6 Schritte P3-S0 bis P3-S5, 3 Entscheidungen P3-D1 bis P3-D3) | `4192a76`, `87fe856`, `36d50b1`, `6d681fc`, `70df541`, Protokoll `11-impl-v3.md` (Opus) | `12-audit-v3.md`, Commit `5bf8d4f` (Fable): Build, 59 + 56 Tests und Preflight selbst ausgeführt | F1 bis F4 behoben, neu: E1 niedrig, E2 Beobachtung | E1 und E2 direkt nach dem Audit korrigiert |

Der Audit 1 hielt einen neuen Durchlauf für nicht notwendig und empfahl, B1 als
Einzelfix zu behandeln. Der Hauptagent ordnete trotzdem einen zweiten Durchlauf
an, weil seine Abbruchregel bei Befunden der Stufe mittel oder höher einen neuen
Durchlauf verlangt, und weil er selbst den Befund B4 ergänzt hatte, der im Audit 1
fehlte. Nach dem Audit 2 prüfte der Hauptagent nach, fand in CHANGELOG, bei
`maxSlots` und bei Messpunkt M5 weitere Lücken und ordnete den dritten, letzten
Durchlauf an. Das Limit von 3 Durchläufen ist damit ausgeschöpft. Ein vierter
Durchlauf ist nicht vorgesehen.

### 4.2 Befunde und Status

| ID | Schwere | Befund | Status |
|----|---------|--------|--------|
| B1 | mittel | `updateWaveEnergy()` multiplizierte den Peak mit `deviceGains[key]` statt mit dem effektiven Gain; unter Solo zeigten stumme Slots weiter Pegel | Behoben in `cba4489`. Anzeige und Wellenenergie nutzen `SoloGain.effective`. Am Gerät nicht verifiziert (M9) |
| B2 | niedrig | RELEASE_NOTES beschrieb das Blip-Verhalten als hörbare Tatsache, die nur am Gerät belegbar ist | Behoben in `fd502c7` für `RELEASE_NOTES.md`. Rest siehe 6f |
| B3 | niedrig | Der Test für den leeren Key prüfte nur den Fall ohne Solo | Behoben in `f2f7deb` (zwei Assertions ergänzt) |
| B4 | dokumentiert | Der Reset von Launch at Login beim Sprung von Build 10 auf 11 war nirgends dokumentiert | Dokumentiert in `c079c27`, `68c8d71`, `8eae52b`. Kein Code-Fix, bewusste Entscheidung (siehe 6d). B4 stand nicht im Audit 1, siehe 4.3 |
| B5 | Hinweis | `preflight.sh` meldet 1 ABBRUCH wegen des alten Archivs 4.0.1 (10) | Aufgenommen und im Audit 2 unabhängig bestätigt. Nicht behebbar ohne neues Archiv, offen als Nutzeraufgabe |
| C1 | niedrig | Die Entscheidungs-ID "D1" bezeichnet zwei verschiedene Entscheidungen | Behoben in P3-S2-Commit (Kommentar verweist jetzt auf `05-plan-v2.md`) |
| F1 | niedrig | CHANGELOG Blip-Eintrag beschrieb Audio-Ergebnis als Tatsache, nicht als Code-Verhalten | Behoben in P3-S1-Commit |
| F2 | niedrig | Kommentar-ID "D1" in EngineController.swift ohne Dokument-Verweis | Behoben in P3-S2-Commit |
| F3 | niedrig | maxSlots-Einschränkung nirgends in Nutzerdoku | Behoben in P3-S3-Commit |
| F4 | niedrig | Vier Unstimmigkeiten im Abschlussbericht | Behoben in P3-S4-Commit |
| E1 | niedrig | Dieser Bericht nannte die Schrittanzahl von Plan v3 mit 4 statt 6, führte die Zeile zu Durchlauf 3 veraltet ("Audit folgt") und nannte C1 noch offen | Behoben nach dem Audit 3 (Zeile 4.1 und Zusammenfassung angepasst) |
| E2 | Beobachtung | `11-impl-v3.md` enthielt den Platzhalter "PLATZHALTER-S5" statt des Commit-Hashes | Behoben nach dem Audit 3 (Hash `70df541`) |

### 4.3 Ehrliche Vermerke zum Ablauf

- Der erste Audit-Versuch brach zweimal wegen eines Sitzungslimits ab und wurde neu
  gestartet. Das steht so im Auftrag zu diesem Bericht; in den Dokumenten des
  Ordners ist es nicht vermerkt. Der vorliegende Audit 1 ist das Ergebnis des
  erfolgreichen Laufs.
- Der Befund B4 stammt nicht aus dem Audit 1. Laut Auftrag hat ihn der Hauptagent
  ergänzt, weil der Audit 1 den Reset von Launch at Login nicht dokumentiert
  fand. `05-plan-v2.md` Abschnitt 1.1 schreibt B4 und B5 dem Planer zu und
  nennt als Quelle die Aufgabenbeschreibung; das ist eine Vereinfachung für die
  Planungs-Perspektive und ändert nichts am Sachverhalt. Die Zuschreibung ist
  in den Dokumenten nicht einheitlich, aber der Bericht gibt den Sachstand
  korrekt wieder: B4 und B5 tauchten nach Audit 1 auf, nicht im Audit selbst.
- Der Audit 2 spricht im Kopf von zwei neuen Befunden (C1, C2). C2 (Divisor der
  Wellenenergie) wird im selben Dokument als bewusste Entwurfswahl und "kein
  Befund" eingestuft. Gezählt wird hier deshalb nur C1: 0 hoch, 0 mittel, 1 niedrig.

## 5. Entscheidungen

### 5.1 Entscheidungen des Nutzers

Vor der Umsetzung bestätigt, am Gerät nicht verifiziert (Stand der Tabelle: vor der Messsitzung; Nachtrag 23.11.2026: M1, M2, M3, M8 und M9 sind gemessen und nicht negativ, siehe Abschnitt 12.1):

| ID | Entscheidung | Stand |
|----|--------------|-------|
| E1 | `maxHeight` der Liste 400 pt | Bestätigt, umgesetzt, nicht am Gerät verifiziert (M1) |
| E3 | Icon-Button in der Statuszeile | Bestätigt, umgesetzt, nicht am Gerät verifiziert (M2) |
| E4 | 0,4 Opacity für durch fremdes Solo stumme Cards | Bestätigt, umgesetzt, nicht am Gerät verifiziert (M3, M9) |
| E6 | Blip-Absorption: ausstehenden Restart verwerfen | Bestätigt, umgesetzt, **nicht am Gerät verifiziert** (M8). Fällt M8 negativ aus, ist `5798a63` umzukehren |

### 5.2 Entscheidungen der Planer

| ID | Dokument | Inhalt | Rückfall |
|----|----------|--------|----------|
| E2 | Plan v1 | Scroll-Indikator sichtbar | nicht genannt |
| E5 | Plan v1 | Keine zusätzliche Gain-Rampe für Solo, die vorhandene W1-Rampe im IOProc genügt | nicht genannt; Knacksfreiheit ist Messpunkt M3 |
| E7 | Plan v1 | Baseline der Sample-Rate bei Registrierung des Listeners | nicht genannt |
| E8 | Plan v1 | Noop-Zähler per `logger.log`, `.public`, ohne Gerätenamen | nicht genannt |
| D1 (Welle) | Plan v2 | `SoloGain.effective` auch für die Summe der Wellenenergie, stumme Slots zählen nicht | Zeile `let gain = ...` in `updateWaveEnergy()` auf `Float32(deviceGains[key] ?? 1.0)` zurücksetzen, in einem eigenen Commit |
| D2 | Plan v2 | `SoloGain.effective` bei leerem Key: ohne Solo 1,0; leerer Key unter fremdem Solo 0,0; leerer Key selbst solo 1,0. Als korrekt anerkannt und getestet | Test entfernen, Funktion bleibt |
| D1 (Launch at Login) | `05-decisions.md` | Der Reset von Launch at Login beim Sprung von Build 10 auf 11 wird akzeptiert | Consent über Builds hinweg speichern; dafür wäre vorher eine Prüfung von Guideline 2.4.5(iii) nötig |

**Offen (C1, niedrig):** Die ID "D1" bezeichnet zwei verschiedene Entscheidungen:
die Wellenenergie in `05-plan-v2.md` und den Launch-at-Login-Reset in
`05-decisions.md`. Der Code-Kommentar in `EngineController.swift` (laut Audit 2
Zeile 752, "Entscheidung D1 (Planer, 2026-11-13)") meint die Wellenenergie. Der
CHANGELOG-Verweis "docs/v4.1/05-decisions.md, D1" meint den Launch-at-Login-Reset.
Der Audit empfiehlt, den Kommentar auf "D1-wave" oder "D1 (05-plan-v2.md)" zu
präzisieren. Das ist nicht geschehen. In diesem Bericht sind beide Fälle durch den
Zusatz in Klammern getrennt.

## 6. Bekannte Eigenheiten und Restrisiken

**a) Die Wellenenergie wird durch alle Slots geteilt.** In `updateWaveEnergy()`
ist der Divisor die Gesamtzahl der konfigurierten Slots
(`engine.slotDeviceKeys.count`, `min(1, sum / Float32(slots))`). Durch Solo
stumme Slots tragen 0 zur Summe bei. Spielt unter Solo ein Gerät von N mit
Vollpegel, zeigt die Welle etwa 1/N der Energie. Der Audit 2 nennt als Beispiel
1 von 4 Slots mit `linear = 0.25` gegenüber 1,0 ohne Solo. Das Rechenbeispiel
(1 von 4 Slots, linear = 0,25) stammt aus Audit 2, Abschnitt B1. Wirkung: rein
visuell, der Audiopfad ist unberührt. Es ist Entscheidung
D1 (Welle) in `05-plan-v2.md`. Rückfall: die Zeile `let gain = ...` in
`updateWaveEnergy()` wiederherstellen. Beachtenswert: Der Plan beschreibt die
Wahl mit "stumme Slots zählen nicht", erwähnt den Divisor aber nicht ausdrücklich.
Ob die schwächere Welle am Gerät störend wirkt, ist ungeprüft.

**b) Blip-Absorption.** Es besteht das Risiko, dass ein echter Gerätewechsel
fälschlich verworfen wird. Der Code verwirft nur bei aktivem `pendingRestart`,
also innerhalb der Settle-Frist; ein Gerät, das länger fehlt, nimmt den
bisherigen Pfad. Ob Aggregate und Tap einen Blip tatsächlich unbeschadet
überstehen, ist nur am Gerät belegbar (M8). Es gibt keinen automatischen Test für
diese Änderung. Hinzu kommt die Wechselwirkung mit dem Freeze des VolumeTrackers
aus CASE-007: Bei einem absorbierten Blip läuft der Tracker ohne Freeze weiter;
das wurde im Plan und im Audit 1 als korrekt bewertet, ist aber ebenfalls nicht
am Gerät gemessen.

**c) `SlotGains.maxSlots = 16`.** Slots ab Index 16 werden von Solo nicht stumm
geschaltet, weil `engine.setOutputGain` Keys außerhalb von `maxSlots` ignoriert
(FanOutEngine.swift Z. 196 bis 199: `setOutputGain` verwirft den Aufruf;
FanOutEngine.swift Z. 598 bis 599: `buildDirectOutputSlots` loggt eine Warnung
bei mehr als 16 Slots; beide Stellen existieren und ergänzen sich). Das ist im Plan v1 (Solo,
Randfälle), im Umsetzungsprotokoll (S3) und als Messpunkt M5 dokumentiert, es gab
keine Änderung an `maxSlots`. Es steht nicht in CHANGELOG, RELEASE_NOTES oder den
App-Store-Texten; ein Nutzer erfährt davon nur durch Ausprobieren. Ungeprüft ist,
ob in der Praxis mehr als 16 Ausgaben gleichzeitig ausgewählt werden können.

**d) Launch at Login wird für Bestandsnutzer einmal zurückgesetzt.** Der Consent
ist an die Build-Nummer gebunden; beim Sprung von Build 10 auf 11 wird er
ungültig, die App startet nach dem Update nicht mehr automatisch beim Login, bis
der Nutzer den Schalter im Footer wieder setzt (Entscheidung D1 in
`05-decisions.md`, Guideline 2.4.5(iii)). Der Mechanismus wurde in 4.0.1 als D11
geprüft und von der App-Prüfung akzeptiert. Hinweise stehen in CHANGELOG,
RELEASE_NOTES, What's New und Review-Notiz. Der automatische Start des
Routings beim App-Start (`wasRouting`) ist nach Audit 2 nicht an die Build-Nummer
gebunden und bleibt erhalten. Wie Nutzer auf den Reset reagieren, ist ungeprüft.

**e) `preflight.sh` meldet 1 ABBRUCH.** Das Archiv `AudioRouterNow4 07-10-2026,
17.55.xcarchive` ist 4.0.1 (10), erwartet war 4.1 (11). Das ist laut Plan und
beiden Audits erwartet und nur durch ein neues Archiv zu beheben, vor der
Einreichung. Bekannte Warnungen daneben: `v4-appstore/` existiert noch, Commits
sind nicht gepusht.

**f) Rest-Formulierung im CHANGELOG.** B2 wurde nur für `RELEASE_NOTES.md`
behoben. `CHANGELOG.md` sagt im Abschnitt 4.1 unter "Fixed" weiterhin, die
Engine "keeps running uninterrupted". Das ist dieselbe Art Aussage, die B2
beanstandet hat. Der Audit 1 hielt die CHANGELOG-Formulierung für technisch
korrekt, der aktuelle Wortlaut stützt das nur eingeschränkt. Nicht geändert,
weil dieser Bericht nur Dokumentation in `docs/v4.1/` schreibt; als Rückmeldung an
den Hauptagenten vermerkt.

## 7. Der Nutzer muss messen

Keine dieser Messungen wurde von einem Agenten durchgeführt. Kein Build und kein
Unit-Test kann sie ersetzen. Die Spalte "Ergebnis" ist bewusst leer.

> **Nachtrag 23.11.2026:** Alle Messpunkte dieser Tabelle sind am Gerät durchgeführt
> (Ergebnisse in Abschnitt 12.1, Belege in `27-messprotokoll.md`). Die Spalte "Ergebnis"
> bleibt hier unverändert leer, damit die Tabelle den Planungsstand zeigt. M5 galt
> in der hier stehenden Fassung für `maxSlots` 16 und wurde durch Abschnitt 11
> neu gefasst (48 Zeilen gemessen).

| ID | Thema | Prüfanleitung | Erwartetes Ergebnis | Ergebnis |
|----|-------|---------------|---------------------|----------|
| M1 | ScrollView mit 45 oder mehr Einträgen | BlackHole 64ch und ein Interface mit vielen Kanälen (z.B. Scarlett 18i20) verbinden, App starten, Panel öffnen. Scroll-Indikator, Scrollbarkeit, grosser Knopf oben und Footer prüfen. Auf einem MacBook 13" prüfen, ob das Panel auf den Bildschirm passt. Zusätzlich (UI-Nachtrag 23, Variante C3): bei langer Liste prüfen, ob der grosse Start/Stop-Knopf oben (unter der Statuszeile, ausserhalb des ScrollViews) sichtbar bleibt und ob der Status-Text zusammen mit "CBs" in die Statuszeile passt, ohne Umbruch oder Abschneiden. Gerendert (Nachbau, ImageRenderer, C3): das volle Panel mit 18 Zeilen ist 589 pt hoch (C3 ohne die zweite Footer-Reihe), unter den ~700 pt eines 13-Zoll-Geraets, am Geraet zu bestaetigen | Ja zu allen Fragen: Indikator sichtbar, Liste scrollbar, grosser Knopf oben immer sichtbar, Footer immer sichtbar, nichts umgebrochen oder abgeschnitten, Panel passt auf den Bildschirm | |
| M2 | Start/Stop-Knopf oben (gewaehlter Stand C3 mit V2) | Mindestens ein Gerät konfiguriert. Im Zustand idle den grossen Knopf oben klicken, im Zustand active klicken, im Zustand starting ansehen. (Der obere Knopf ist der einzige Start/Stop-Knopf im Panel; keine Pille in der Statuszeile, keine Pille im Footer.) Offen: Start ueber den oberen Knopf ohne Absturz, Audio spielt auf den gewaehlten Geraeten | Routing startet und stoppt korrekt ueber den oberen Knopf, im Zustand starting ist er deaktiviert, kein doppelter Start bei schnellen Klicks | |
| M2b | Knopfoptik oben und Footer (gewaehlter Stand C3 mit V2) | Grosser Knopf oben: im Leerlauf mit Auswahl gefuellte Mint-Pille "Start Routing", ohne Auswahl gedimmt, beim Routen umrandet "Stop Routing", beim Starten Spinner "Connecting…". Maus darueber und druecken, mit VoiceOver navigieren. Footer (eine Reihe) prüfen: Launch at Login sichtbar und als Checkbox bedienbar, Support als Mint-Pille mit Herz und Wort "Support" (beim Aufklappen des Tip Jar X plus "Close"), Lock/Exclusive/Bug und Quit erreichbar. Offen: VoiceOver-Ausgabe, Tab-Fokus-Reihenfolge und das Verhalten des Footers bei grosser Dynamic Type (Umbruch von Launch at Login, Support, Quit) am Geraet | Der obere Knopf ist in jedem Zustand als Knopf erkennbar, Druecken sinkt kurz ein, VoiceOver liest "Start Routing"/"Stop Routing". Support ist als Knopf mit Wort erkennbar. Keine Footer-Funktion fehlt | |
| M2c | Hover-Erklaerungen im Footer (gewaehlter Stand C3 mit V2) | Mit der Maus nacheinander ueber Support, Lock, Exclusive, Bug, Quit und Launch at Login fahren und je ca. 0,4 s warten. Auch die aeussersten Elemente links (Launch at Login) und rechts (Quit) pruefen. Mit Trackpad und mit Maus testen. Offen: ob die Hover-Sprechblasen im echten, nicht-aktivierenden Panel erscheinen (Verzoegerung, Ausblenden, Clamping am Fensterrand) am Geraet | Nach kurzer Verzoegerung erscheint eine kleine Textbox ueber dem Footer mit der Erklaerung des Elements, verschwindet beim Verlassen und beim Klick, wird an beiden Fensterraendern nicht abgeschnitten (am Rand geclampt), und flackert beim Wechsel zwischen Elementen nicht. Die Texte: Support "Opens the tip jar. Tipping is optional and unlocks nothing.", Lock "Keeps macOS from switching the output device while routing.", Exclusive "Only selected devices play. The default output stays silent.", Bug "Opens a pre-filled bug report email with version info.", Quit "Quits AudioRouterNow.", Launch at Login "Starts AudioRouterNow automatically when you log in." | |
| M2d | "Add device"-Menue: scrollbar bei sehr langer Liste (Frage 25) und bereits hinzugefuegte Eintraege gekennzeichnet (V2) | Scrollbarkeit: Pruefhilfe-App "AudioRouterNow 4.1 TEST C3 LISTE.app" (Desktop) starten, Panel oeffnen, Zeile "Add device" anklicken (die Testversion zeigt sie auch im Leerlauf und fuegt 120 kuenstliche Eintraege hinzu, die kein Routing ausloesen). Kennzeichnung (V2): "AudioRouterNow 4.1 TEST C3b.app" starten, ein Mehrkanalgeraet (z.B. KA6 Ch1-2 und Ch3-4) auswaehlen, Routing starten, dann "Add device" oeffnen. Alternativ in der echten App bei aktivem Routing mit realen Geraeten. Am Geraet bereits bestaetigt (Nutzer, 17.11.2026): die Scrollbarkeit mit der Pruefhilfe "TEST C3 LISTE" und die V2-Kennzeichnung in "TEST C3b" (hinzugefuegte Eintraege markiert, verdunkelt, nicht waehlbar). Zugrunde liegende Belege: Scrollen per Messung am NSMenu (auf Bildschirmhoehe begrenzt, Scroll-Pfeil); Kennzeichnung per NSMenu-Probe (Haken plus ausgegraut, Hinweis "All outputs are added."); das echte SwiftUI-Menue in der Menueleiste der ausgelieferten App bleibt am Geraet zu bestaetigen (Details `docs/v4.1/25-add-device-liste.md`) | Das Menue ist scrollbar (Scroll-Pfeil, Scrollrad und Tastatur), alle Eintraege erreichbar. Bereits hinzugefuegte Eintraege sind gekennzeichnet (Haken) und nicht waehlbar (ausgegraut); sind alle hinzugefuegt, steht nur "All outputs are added." Klicks auf "Test Output N" tun bewusst nichts | |
| M3 | Solo ohne Knacksen | Mindestens zwei Ausgaben, Routing aktiv, Musik läuft. Solo eines Outputs setzen, einen anderen solo setzen, Solo aufheben. Während Solo den Regler einer stummen Ausgabe verschieben und nach dem Aufheben prüfen | Kein Knacksen, kein Lautstärkesprung. Nach dem Aufheben gilt die gespeicherte Lautstärke der vorher stummen Ausgaben, inklusive des verschobenen Reglerwerts | |
| M4 | Solo bei abgestecktem Gerät | Zwei Ausgaben, eine solo setzen, dann das Solo-Gerät entfernen | Alle anderen Ausgaben bleiben stumm. Nach dem Aufheben von Solo hören alle verbliebenen Ausgaben wieder | |
| M5 | Grenze `maxSlots` (16) | 17 konfigurierte Ausgaben (z.B. BlackHole 64ch, Paare 1 bis 17). Slot 1 (Index 0) solo setzen, Slot 17 (Index 16) solo setzen; prüfen, ob Slot 17 (Index 16) weiter spielt und nicht stummgeschaltet wird | Solo schaltet die Slots 0 bis 15 stumm. Ein Slot ab Index 16 spielt weiter (bekannte Einschränkung) | |
| M6 | Noop-Rate des SR-Listeners | App 15 Minuten oder länger mit aktivem Routing laufen lassen, ohne die Sample-Rate zu ändern. `log stream --predicate 'subsystem == "com.mauriciomorkun.audiorouternow"' \| grep "M4-Noop"` ausführen und den Zähler lesen | Zähler 0 oder sehr niedrig. Ein hoher Wert zeigt, dass der Listener ohne Grund feuert | |
| M7 | Restart bei echtem Rate-Wechsel | Routing aktiv, Gerät mit umschaltbarer Rate (z.B. Komplete Audio 6 oder ein USB-Interface). Rate in Audio MIDI Setup von 48 kHz auf 44,1 kHz umschalten | Warm-Restart innerhalb von 1 bis 3 Sekunden, kein "M4-Noop" im Log | |
| M8 | Blip-Absorption | Routing aktiv, USB-Gerät. Kabel kurz lösen (unter 2 Sekunden) und wieder einstecken | Kürzere oder keine Unterbrechung als bei 4.0.1. Reißt das Audio dauerhaft ab, ist `5798a63` umzukehren | |
| M9 | Meter unter Solo (Fix von B1) | Mindestens zwei Ausgaben, Routing aktiv. Solo eines Outputs setzen, eine andere Card aufklappen und die grünen Signal-Balken der durch fremdes Solo stummen Card ansehen | Die Meter zeigen 0 (Stille), passend zur 0,4 Opacity der Card. Vor dem Fix zeigten sie Pegel | |

Dazu gehört ein Blick auf die Welle unter Solo (Abschnitt 6a), der in den Plänen
kein eigener Messpunkt ist: Zeigt sie bei einem Solo-Gerät von mehreren deutlich
weniger Energie als ohne Solo, ist das erwartet (etwa 1/N).

## 8. Aufgaben des Nutzers bis zur Einreichung

Die Reihenfolge ist verbindlich. Nicht von Agenten gemacht und deshalb alle offen:
kein Push, keine Einreichung, kein Tag `v4.1`, kein Merge nach `main`, kein
Archiv, keine Eingabe in App Store Connect.

1. **Messungen M1 bis M9** durchführen (Abschnitt 7) und die Ergebnisse
   eintragen. Fällt M8 negativ aus, `5798a63` umkehren, bevor es weitergeht.
   *Erledigt 23.11.2026, kein Messpunkt negativ, `5798a63` bleibt (Abschnitt 12). Die
   Zusatzzeilen sind offen, der CPU-Vergleich mit 4.0.1 ist erledigt (kein Unterschied).*
2. **Entscheidungen bestätigen:** E1, E3, E4, E6 sind vor der Umsetzung bestätigt,
   nach den Messungen erneut prüfen. Dazu die Welle (6a) und der Launch-at-Login-Reset
   (6d) ausdrücklich annehmen oder die Rückfälle wählen.
3. **Store-Description und What's New** in App Store Connect eintragen, Quelle
   `docs/v4.1/06-appstore-texts.md` (Ersatzsatz für den Superlativ, What's New,
   Review-Notiz). Die Version 4.1 existiert erst nach dem Hochladen des Archivs.
4. **Neues Archiv bauen und signieren** (Product, Archive in Xcode).
5. **`v4/scripts/preflight.sh` erneut ausführen.** Der ABBRUCH wegen des alten
   Archivs muss verschwunden sein, es dürfen nur Warnungen bleiben (`v4-appstore/`,
   gegebenenfalls nicht gepushte Commits).
6. **Datum im CHANGELOG** (`[4.1 (11)], YYYY-MM-DD`) und den Status in CHANGELOG und
   RELEASE_NOTES auf das Einreichungsdatum setzen (laut den Dokumenten wird das
   Datum bei der Einreichung gesetzt).
7. **Tag `v4.1`** setzen, nur auf Anweisung des Nutzers.
8. **Branch `release/4.1` nach `main` mergen und pushen**, nur auf Anweisung des
   Nutzers.
9. **Einreichung** bei App Review.
10. **Support-Antworten** danach, kurz halten, Kernpunkte zuerst.

## 9. Verworfene Ansätze und Abgrenzungen

- **300 ms Blip-Fenster.** Der Hinweis im BACKLOG ging von 300 ms aus. Am Code
  passt das nicht: `hdmiSettleDelay` stellt schon ein 3-Sekunden-Fenster, der
  bisherige Wiedererscheinungs-Pfad ersetzt den Restart durch einen neuen
  2-Sekunden-Restart. Gewählt wurde stattdessen, den ausstehenden Restart zu
  verwerfen (E6). Plan v1, E6 und Anhang Punkt 4.
- **Solo über Gain.** Solo schreibt 0 über `engine.setOutputGain`, nie über
  `setDeviceGain` oder die gespeicherten `deviceGains`, damit die Stille nicht
  persistiert (R3, CASE-004). Ob ein Trennen und Verbinden der Ausgaben als
  Alternative erwogen und verworfen wurde, steht in den gelesenen Dokumenten nicht.
- **Keine eigene Rampe für Solo.** Die vorhandene W1-Rampe im IOProc genügt laut
  Plan (E5). Das ist eine Annahme, bis M3 gemessen ist.
- **Prozentuale Höhe für die Liste.** Die Variante `0.6 * NSScreen.main?.frame.height`
  wurde zugunsten fester 400 pt verworfen, weil sie mehr Zustand und Komplexität
  braucht (E1). 450 oder 500 pt blieben als Alternativen genannt.
- **Klickbarer Status-Banner statt Icon-Button.** Als Alternative zu E3 genannt,
  nicht gewählt, weil eine unerwartete Trefffläche entsteht.
- **Kein Duplikat der Solo-Logik.** `effectiveSoloGain` wurde nicht auf
  `EngineController` und zusätzlich im Test dupliziert, sondern als
  `SoloGain.effective` in den Kit verschoben (siehe 3.2).
- **Kein Code-Fix für den Launch-at-Login-Reset.** Verworfen wurden das Speichern
  des Consents über Builds hinweg und eine Sonderregel für Build 10, weil beides
  die Vorgabe der Guideline unterläuft beziehungsweise nicht wartbar ist
  (`05-decisions.md`).
- **AirPlay.** In `01-airplay-research.md` ausgelagert. Gemessen wurde am Mac des
  Nutzers nur der Zustand "nicht verbunden": ein Volumio-Gerät ist per Bonjour
  sichtbar, aber für CoreAudio und damit für die App nicht. Der Zustand
  "verbunden" wurde nicht getestet, die Entscheidung ist offen. Die Recherche
  enthält außerdem Korrekturen am ursprünglichen Agentenbericht.
- **Superlativ im Repo.** Plan v1 sah vor, den Satz im Repo zu ersetzen. Er stand
  dort nicht (siehe 3.6), es war nichts zu tun.

## 10. Dokumentenverzeichnis `docs/v4.1/`

| Datei | Inhalt |
|-------|--------|
| `README.md` | Übersicht über alle Dokumente des Ordners und Hinweis auf die Quellenlage |
| `01-airplay-research.md` | Recherche zu AirPlay: Messung auf dem Mac des Nutzers, Urteile je Weg, Korrekturen am Agentenbericht, Hypothesen und Echttest-Plan, Entscheidung offen |
| `02-plan-v1.md` | Durchführungsplan v1 mit Scope, Entscheidungen E1 bis E8, Schritten S0 bis S12, Risiken, Messpunkten M1 bis M8 und Audit-Leitfaden |
| `03-impl-v1.md` | Umsetzungsprotokoll des ersten Durchlaufs mit Commits, Abweichungen und offenen Messpunkten |
| `04-audit-v1.md` | Audit des ersten Durchlaufs mit den Befunden B1 bis B3 |
| `05-plan-v2.md` | Nachbesserungsplan für B1 bis B5 mit den Entscheidungen D1 (Welle) und D2, Messpunkt M9 und Audit-Leitfaden |
| `05-decisions.md` | Entscheidung D1 (Launch at Login) zum Reset beim Sprung von Build 10 auf 11, mit Begründung und Rückfall |
| `06-appstore-texts.md` | Textvorlagen für App Store Connect: What's New, Review-Notiz und Anleitung zum Ersetzen der Store-Description |
| `07-impl-v2.md` | Umsetzungsprotokoll des zweiten Durchlaufs mit Commits, Preflight-Ergebnis und Restrisiken |
| `08-audit-v2.md` | Audit des zweiten Durchlaufs: Status von B1 bis B5, neuer Befund C1, Testlauf, Build und Preflight |
| `09-final-report.md` | Dieser Abschlussbericht |

## 11. Nachtrag: Slots und Welle (Stand 2026-11-14)

Dieser Abschnitt ist angehängt. Die Abschnitte 1 bis 10 sind unverändert und geben den Stand vor dem Nachtrag wieder. Wo sie dem Nachtrag widersprechen, gilt der Nachtrag.

**Anlass.** Ausgaben ab Slot-Index 16 liefen mit festem Unity-Gain, Solo konnte sie nicht stumm schalten, die Pegelanzeige blieb leer, und die Welle war bei mehr als 16 Slots zu klein. Das widersprach den beiden Nutzerwünschen W1 (kein Nachteil bei mehr als 16 Ausgaben) und W2 (die Welle wird unter Solo nie kleiner).

**Dokumente.** Plan: `14-plan-nachtrag.md` (Fassung 2, Commit `5dc55f5`). Umsetzungsprotokoll: `15-impl-nachtrag.md`. Audit Durchlauf 1: `16-audit-nachtrag-v1.md`. Durchlauf 2: Plan `17-plan-nachtrag-v2.md`, Protokoll `18-impl-nachtrag-v2.md`, Audit `19-audit-nachtrag-v2.md`. Durchlauf 3: Plan `20-plan-nachtrag-v3.md`, Protokoll `21-impl-nachtrag-v3.md`. Der Endstand steht am Ende dieses Abschnitts ("Endstand des Nachtrags").

### Ergebnis je Wunsch (Code und Unit-Tests, nicht am Gerät geprüft)

**W1.** Die Kapazität liegt in einer Konstante, `OutputLimits.maxSlots = 256`. `SlotGains` und `PeakMeters` verweisen darauf. Die beiden 16er-Zweige in `FanOutEngine` (in `setOutputGain` und der Warn-Block in `buildAndStartAggregate`) und die Schranke `where i < SlotGains.maxSlots` in `updateWaveEnergy` sind entfernt. Konfiguriert werden können höchstens 255 Ausgaben, ein Slot bleibt für den synthetischen Default-Slot frei. Das Hinzufügen einer weiteren Ausgabe wird mit einer Meldung im Panel abgelehnt. `start` und `buildAndStartAggregate` werfen `RouterError.tooManyOutputs`, bevor ein Tap oder Aggregate entsteht, falls eine gespeicherte Liste zu lang ist.

**W2.** Die Welle wird mit `WaveEnergyMath.soloNeutralLinear` berechnet. Die Funktion hat keinen Solo-Parameter, Solo kann die Wellenhöhe daher nicht verändern. Die Meter der Karten behalten `SoloGain.effective` (B1 bleibt erhalten).

### Entscheidungen NT-D1 bis NT-D7

| ID | Inhalt |
|----|--------|
| NT-D1 | Kapazität 256, eine Konstante (zu bestätigen) |
| NT-D2 | Lock-Mechanik unverändert, kein Snapshot |
| NT-D3 | Feste Konstante statt dynamischer Kapazität |
| NT-D4 | Welle ignoriert Solo, Meter behalten die B1-Korrektur, ausdrücklich nicht: Welle ohne Geräte-Gain (zu bestätigen) |
| NT-D5 | Oberhalb der Kapazität: Sperre mit Meldung, Startfehler bei zu langer gespeicherter Liste (zu bestätigen) |
| NT-D6 | Wellenformel als Kit-Funktion mit index-gleichen Arrays |
| NT-D7 | Known-limitation entfällt, ersetzt durch Fixed-Einträge mit nur belegten Aussagen (zu bestätigen) |

### Überholte Aussagen in den Abschnitten oben

- Abschnitt 6a (Welle durch alle Slots geteilt, `SoloGain.effective` auch in der Summe) ist durch NT-D4 überholt. Die Entscheidung D1 (Welle) aus `05-plan-v2.md` ist abgelöst, siehe `05-decisions.md`, Eintrag D2.
- Abschnitt 6c (`maxSlots = 16`, stilles Unity-Gain ab Slot 16) ist durch NT-D1 und NT-D5 überholt. Der Known-limitation-Absatz in CHANGELOG und RELEASE_NOTES entfällt.

### Neu gefasste Messpunkte

- **M5 (neu):** Mehr als 16 Ausgaben. Ein virtuelles Gerät mit 64 Kanälen (32 Paare) plus ein Interface, mindestens 45 Zeilen. Lautstärke der 17. Ausgabe und einer Ausgabe jenseits der 32. verstellen. Solo auf der 1. Ausgabe, dann Solo auf der 17. und auf einer Ausgabe jenseits der 32. Erwartung: alle Ausgaben verhalten sich gleich, Solo schaltet die anderen stumm, die Lautstärke wirkt. Optionales lokales Experiment für die Grenze: Konstante `OutputLimits.maxSlots` temporär auf 20 senken (nicht committen), bauen, 19 Ausgaben wählen, eine weitere versuchen. Erwartung: Die Meldung erscheint, die Ausgabe wird nicht hinzugefügt. Danach zurückändern.
- **M9 (neu):** Meter und Welle unter Solo. Wie bisher zeigen die Meter der durch fremdes Solo stummen Karte 0. Neu: Die Welle im Header bleibt unter Solo gleich hoch wie ohne Solo (gleiches Material, mehrere Ausgaben, Solo setzen, wechseln und aufheben).
- **NM-1 bis NM-7** aus Abschnitt 7 von `14-plan-nachtrag.md` (Hörprüfung über 16 und 32 Ausgaben, Pegelanzeige ab der 17. Ausgabe, Welle unter Solo, CPU-Last, Bedienung bei sehr vielen Zeilen, Meldung am Limit, Speicher). Keine dieser Messungen wurde ausgeführt. Ungeprüft ist insbesondere, ob CoreAudio bei 128 bis 256 Kanalpaaren eines Geräts stabil läuft. Die Messwerte zur CPU-Last im Plan sind synthetisch.

### Endstand des Nachtrags (nach Durchlauf 3, Stand 2026-11-15)

Der Nachtrags-Zyklus lief in drei Durchläufen, das Limit ist damit ausgeschöpft. Der Audit zu Durchlauf 3 (`22-audit-nachtrag-v3.md`) hat alle Befunde geprüft und den Zyklus für abgeschlossen erklärt.

| Durchlauf | Plan | Umsetzung | Audit | Befunde |
|-----------|------|-----------|-------|---------|
| 1 | `14-plan-nachtrag.md`, `5dc55f5` | `49f1a2c` bis `634d922`, Protokoll `15-impl-nachtrag.md` | `16-audit-nachtrag-v1.md`, `8dd0838` | G1 und G2 mittel, G3 bis G5 niedrig |
| 2 | `17-plan-nachtrag-v2.md`, `23be274` | `5835733`, `dc32d9b`, `2ff74a5`, Protokoll `97f687c`, Hash-Nachtrag `07bdfef` | `19-audit-nachtrag-v2.md`, `77f0d1f` | H1 mittel, H2 und H3 niedrig |
| 3 | `20-plan-nachtrag-v3.md`, `2ae52d9` (korrigiert in `2960723`) | `e2bcc93`, `b9faad8`, `63b4d04`, Protokoll `21-impl-nachtrag-v3.md` | `22-audit-nachtrag-v3.md` | H1 und H2 behoben, H3 akzeptiert (NT3-D3), keine neuen Befunde |

| ID | Schwere | Befund | Status |
|----|---------|--------|--------|
| G1 | mittel | `testSoloDoesNotLowerTheWave` schützte W2 nicht (beide Aufrufe identisch) | Behoben in `5835733`: Signaturtest `testSoloNeutralLinearSignatureHasNoSoloedKeys`. Audit 2 hat ihn per Mutation geprüft (Parameter mit und ohne Default-Wert: Kompilierfehler) |
| G2 | mittel | `outputLimitNotice` nicht synchron mit Start und Restart | Lücke 2 (Erfolgsfall) behoben in `dc32d9b` (`performStart`, `restartRouting`). Lücke 1 (Startfehlerpfad) bewusst kein Fix (NT2-D1, laut Audit 2 genügt der Text in `errorSection`) |
| G3 | niedrig | Erklärender Kommentar im Testkörper fehlte | Behoben in `5835733` |
| G4 | niedrig | Dateiname-Verweis `16-audit-nachtrag.md` statt `-v1` | Bereits in Durchlauf 1 behoben, von Audit 2 bestätigt |
| G5 | niedrig | Je Tick eine Array-Allokation in `updateWaveEnergy` ohne Kommentar | Kommentar in `2ff74a5`, enthielt aber eine falsche Zahl (H1) |
| H1 | mittel | Kommentar nannte "~5120 Allokationen/s". Richtig: 20 Allokationen pro Sekunde, 5120 sind Element-Schreibzugriffe (20 Hz x 256) | Behoben in `e2bcc93` und `63b4d04` (nur Kommentar). Der Fehler stammte aus dem Plan `17-plan-nachtrag-v2.md` (NT2-D5), der unverändert bleibt |
| H2 | niedrig | " -- " im Testkommentar von `WaveEnergyMathTests.swift` | Behoben in `b9faad8` |
| H3 | niedrig | `warmRestartForSampleRateChange` löscht `outputLimitNotice` nicht | Akzeptierter Rest, kein Code (NT3-D3). Die Meldung ist nicht an den Routing-Zustand gebunden und bleibt nach einem SR-Warmrestart sachlich richtig, weil dieser die Ausgabeliste nicht ändert |

**Teststand zuletzt** (in Durchlauf 3 selbst ausgeführt, nach `63b4d04`): 60 swift-testing in 10 Suiten und 96 XCTest, alle grün, App-Build (Debug, `CODE_SIGNING_ALLOWED=NO`) erfolgreich. `preflight.sh`: 1 ABBRUCH (Archiv 4.0.1 (10), erwartet 4.1 (11)) und die bekannten Warnungen. `EngineController` und `MenuBarView` haben kein Test-Target, Änderungen dort sind per Lektüre und Build geprüft.

**Offen:** NM-1 bis NM-7 und M1 bis M9 (am Gerät) sowie die Nutzeraufgaben aus Abschnitt 8. Kein Push, kein Tag, keine Einreichung. Hashes der Dokumentations-Commits per `git log` auffindbar.

## Nachtrag UI (2026-11-16): Start/Stop-Knopf oben als erkennbarer Knopf

Nach dem Nachtrag-Zyklus hat der Nutzer zwei Screenshots geschickt (Leerlauf und
aktiv). Der in 4.1 ergänzte obere Start/Stop-Knopf (E3) war ein nacktes SF-Symbol
ohne sichtbare Fläche und wurde als Status-Symbol gelesen, nicht als Knopf. Da der
Knopf genau für die Nutzer existiert, die den Footer-Knopf bei langer Liste nicht
erreichen, muss er als Knopf erkennbar sein. Umgesetzt: im Leerlauf eine gefüllte
Mint-Pille mit dem Wort "Start" (spiegelt den Footer-Knopf), im aktiven Zustand ein
umrandeter runder Stop-Knopf fester Größe, der die Callback-Anzeige "CBs" nicht
verdrängt; dazu Hover, Pressed (einmalig, keine Dauer-Animation), Tooltip und
VoiceOver-Beschriftung. Die Platzierung und die Aktion bleiben wie in E3. Die
Darstellungslogik liegt testbar im Kit (`AudioRouterKit.HeaderToggle`), die View
`HeaderToggleButton` in `UI/RoutingControls.swift` liest nur ab. Teststand danach:
60 swift-testing und 105 XCTest grün (9 neue HeaderToggle-Fälle), App-Build (Debug,
`CODE_SIGNING_ALLOWED=NO`) erfolgreich. Visuell per `ImageRenderer` geprüft (Pille,
Stop-Knopf, deaktiviert, langer Status-Text passen ohne Umbruch); das echte Aussehen
in der Menüleiste und VoiceOver sind nur am Gerät belegbar. Die Messpunkte M1 und M2
sind erweitert, neue Prüfzeile M2b (Knopfoptik). Vollständige Aufzeichnung:
`23-ui-start-button-oben.md`. Entscheidung E3 bleibt bestätigt, nur die Darstellung
geändert.

### Nachtrag UI, Variante C2 (2026-11-16): Positionen getauscht

Der Nutzer mochte die C-Optik, wünschte aber den Tausch der Positionen: der grosse
Start/Stop-Knopf (vorher unten im Footer) nach ganz oben, dorthin wo in C die Pille
sass; die Pille nach unten in den Footer. Umgesetzt: der grosse `RoutingButton`
sitzt jetzt direkt unter der Statuszeile, ausserhalb des ScrollViews, und bleibt so
bei langer Liste immer sichtbar. Die kompakte Pille (gleiche Aktion, über
`HeaderToggle`) steht im Footer, Reihe 1 links, mit Quit rechts; Reihe 2 trägt
"Launch at Login" (sichtbar, Checkbox, Guideline 2.4.5(iii)) plus die Icon-Gruppe
Support, Lock (Stable Output Mode), Exclusive (CASE-008) und Bug. Keine Funktion
entfernt, nichts in ein verstecktes Menü verschoben; nur die Anordnung aufgeräumt
(zwei Reihen, einheitliche Icon-Grössen). Die Footer-Pille trägt jetzt in jedem
Zustand ein Wort ("Start"/"Stop"/"Connecting"), weil im Footer Platz ist und keine
"CBs"-Anzeige konkurriert; das steuert der neue Parameter `placement` in
`HeaderToggle.style(for:placement:)`. Die Statuszeile zeigt nur noch Punkt,
Status-Text und (aktiv) "CBs". Teststand danach: 60 swift-testing und 110 XCTest
grün (5 neue HeaderToggle-Placement-Fälle), App-Build (Debug,
`CODE_SIGNING_ALLOWED=NO`) erfolgreich. Visuell per `ImageRenderer` (Nachbau)
geprüft in fünf Zuständen (Leerlauf mit und ohne Auswahl, aktiv, langer Status-Text,
lange Liste): kein Umbruch der Pille, kein Abschneiden, Footer nicht zu eng; das
volle Panel mit 18 Zeilen ist 621 pt hoch (unter ~700 pt). Das echte Aussehen in
der Menüleiste, VoiceOver und die Tab-Fokus-Reihenfolge sind nur am Gerät belegbar.
Variante C ist unter `.claude/variants/C1-obere-pille/` gesichert und der Patch
verifiziert. Die Messpunkte M1, M2 und M2b sind auf C2 angepasst. Vollständige
Aufzeichnung: `23-ui-start-button-oben.md`, Abschnitt "Variante C2".

### Nachtrag UI, Variante C3 (2026-11-16): Footer-Pille entfernt, Support aufgewertet, Hover-Bubbles

Der Nutzer wünschte drei Änderungen gegenüber C2: der grosse Knopf bleibt oben
(wie in C2), die kompakte Start/Stop-Pille im Footer wird entfernt (sie war neben
dem immer sichtbaren oberen Knopf nutzlos), der Support-Knopf soll klarer sein, und
die Footer-Symbole sollen beim Hovern eine Erklärung zeigen. Umgesetzt: Die
Footer-Pille ist entfernt; damit war die gesamte `HeaderToggle`-Logik und ihre Tests
ungenutzt (der grosse Knopf ist ein `RoutingButton`, nicht `HeaderToggle`) und wurde
gelöscht (keine toten Codepfade). Der grosse Knopf oben ist jetzt der einzige
Start/Stop-Knopf im Panel und deckt alle Zustände schon ab (Start, Connecting, Stop,
gedimmt ohne Auswahl, Fehler wie idle). Der Support-Knopf ist eine dezente Mint-Pille
mit Herz und dem Wort "Support" (aufgeklappt X plus "Close"); von vier bewerteten
Varianten gewählt, weil das Wort den Zweck sofort klarmacht, ohne Animation, Badge
oder Zähler aufdringlich zu werden, und weil "Support" der von App Review akzeptierte,
neutrale Begriff ist (der Tip Jar ist ein freiwilliger In-App-Kauf, der nichts
freischaltet). Die Footer-Symbole bekommen eine eigene SwiftUI-Hover-Bubble im
Fenster statt `.help`: `.help`/NSToolTip ist in einem nicht aktivierenden
MenuBarExtra-Panel unzuverlässig (Key-Window-Bindung, ca. 1 s Verzögerung) und kann
am Panelrand abgeschnitten werden; die eigene Bubble ist davon unabhängig und wird
am Rand geclampt. An den Bubble-Elementen ist `.help` entfernt (kein Doppel-Tooltip);
`accessibilityLabel` bleibt. Die Tooltip-Texte liegen testbar im Kit
(`AudioRouterKit.FooterTips`, mit Validierung: nicht leer, unter 90 Zeichen, kein
Gedankenstrich, kein Superlativ). Der Footer ist jetzt eine Reihe. Teststand danach:
60 swift-testing und 110 XCTest grün (14 neue FooterTips-Fälle; die 14
HeaderToggle-Fälle sind mit der Logik entfernt, Summe gleich), App-Build (Debug,
`CODE_SIGNING_ALLOWED=NO`) erfolgreich. Visuell per `ImageRenderer` (Nachbau)
geprüft in sechs Zuständen (Leerlauf, aktiv, lange Liste, Hover über Support, Clamping
links und rechts): Support-Pille erkennbar, Bubble erscheint über dem Footer und wird
an beiden Rändern korrekt geclampt; gerenderte Höhen idle 270 pt, aktiv 247 pt, lange
Liste 589 pt (C3 spart gegenüber C2 die zweite Footer-Reihe), alle unter 700 pt. Das
echte Aussehen in der Menüleiste, das Hover-Verhalten im echten Panel, Verzögerung,
Trackpad gegen Maus, VoiceOver und die Tab-Fokus-Reihenfolge sind nur am Gerät
belegbar. Varianten C und C2 sind unter `.claude/variants/` gesichert. Die Messpunkte
M1, M2 und M2b sind auf C3 angepasst, neu M2c (Hover-Erklärungen). Vollständige
Aufzeichnung: `23-ui-start-button-oben.md`, Abschnitt "Variante C3".

## 12. Nachtrag: Messsitzung am Gerät (21. bis 23.11.2026)

Dieser Abschnitt ist angehängt. Die Abschnitte 1 bis 11 geben den Stand vor der Messsitzung wieder. Wo sie dem widersprechen ("keine Messung erledigt", leere Spalte "Ergebnis" in Abschnitt 7), gilt dieser Abschnitt. Die Einzelbelege (Zeitstempel, Screenshots, Wortlaut der Nutzerangaben, Einschränkungen je Messpunkt) stehen in `27-messprotokoll.md`.

**Durchführung.** Der Nutzer hat am Gerät gemessen, Claude hat Punkt für Punkt angeleitet, das System-Log ausgelesen (`log show`, `top`, `ps`) und die Ergebnisse eingetragen. Am App-Code, an der Store-App und an ihren Einstellungen wurde nichts verändert. Verändert wurden nur die Einstellungen der Test-App (vorübergehend, für die Messung, siehe 12.2 Punkt 6) und danach diese Dokumentation. Die Sitzung lief über mehrere Tage, weil M6 lange Laufzeiten braucht.

| Feld | Wert |
|------|------|
| Getestete App | "AudioRouterNow 4.1 TEST C3b.app", Info.plist 4.1 (11), Test-Bundle-ID `com.mauriciomorkun.audiorouternow.test`, ad-hoc signiert. Stand: Code von `release/4.1` (C3 mit V2), nach Datumsvergleich nach der letzten Swift-Änderung gebaut, byteweise Gleichheit mit HEAD nicht prüfbar |
| Gerät | MacBook Pro mit Apple M1, macOS 26.6.2 |
| Vorhandene Ausgänge | BenQ PD2700U (HDMI, 2 Kanäle), Komplete Audio 6 MK2 (USB, 6), Kopfhörerausgang (2), MacBook-Lautsprecher (2), NI Audio 4 DJ (virtuell, 4): 8 Kanalpaare |
| Zusatz am 23.11. | BlackHole 16ch und 64ch (Homebrew-Cask, Version 0.7.1) vorübergehend installiert: 8 plus 32 Paare, insgesamt 48 Zeilen. Danach wieder entfernt, belegt durch den Treiberordner (nur `CaiaqAudio`, `ParrotAudioPlugin`, `TVRemoteAudio`) und `brew list` |

### 12.1 Ergebnis je Messpunkt

Kein Messpunkt ist negativ ausgefallen. Der einzige feste Rückfall (M8, Commit `5798a63` umkehren) wurde nicht ausgelöst.

| ID | Ergebnis | Kern des Belegs |
|----|----------|-----------------|
| M1 | ok | Mit 48 Zeilen: Liste scrollt (Rad und Trackpad), oberer Knopf und Footer bleiben sichtbar, Panel passt. Eine 13"-Prüfung ist nicht belegt (Bildschirmgröße nicht erfasst) |
| M2 | ok | Oberer Knopf schaltet in allen Zuständen richtig |
| M2b | ok | Knopfoptik und Footer wie vorgesehen. Ob VoiceOver benutzt wurde, ist nicht ausdrücklich gesagt |
| M2c | ok | Hover-Erklärungen, Maus und Trackpad |
| M2d | ok | Scrollbarkeit und Kennzeichnung (Haken, ausgegraut) jetzt auch im echten Menü bestätigt |
| M3 | ok | Kein Knacksen, kein Sprung gehört. Der verschobene Reglerwert nach dem Aufheben wurde nicht ausdrücklich bestätigt |
| M4 | ok | Andere Ausgänge bleiben stumm. Welches Gerät entfernt wurde, ist nicht erfasst |
| M5 | ok | 48 Zeilen: Lautstärke und Solo auf Platz 17 und 33 (jenseits der 32) wirken wie auf Platz 1 |
| M6 | ok | Zähler 0: keine einzige Logzeile in mindestens 90 Minuten Routing (Gegenprobe per `log show`, Prozess lief durchgehend) |
| M7 | ok | Warm-Restart bei Rate-Wechsel in beide Richtungen wie erwartet. Im Log ein einzelnes "M4-Noop" 16 s nach dem Wechsel, kein Dauerfeuer |
| M8 | ok | Erster Versuch (22.11.): nicht ausgelöst, das Gerät kam erst nach etwa 3,1 s zurück. Wiederholung mit schnellem Wiedereinstecken (23.11.): dreimal "L1: Blip erkannt" nach 1,20 s, 2,03 s und 1,55 s, in keinem Versuch ein Engine-Neustart |
| M9 | ok | Meter der durch fremdes Solo stummen Karte zeigen -∞ (Screenshot), Welle bleibt gleich hoch |
| NM-1 | ok | Wie M5 |
| NM-2 | ok | Pegelbalken ab Platz 17 und 33 zeigen Pegel. Die Null unter fremdem Solo wurde nicht einzeln bestätigt |
| NM-3 | ok | Welle bleibt unter Solo gleich hoch (Beobachtung, keine Höhenmessung) |
| NM-4 | ok | CPU hängt nicht von der Zeilenzahl ab (Tabelle unten). Der Absolutwert ist gegen 4.0.1 verglichen: gleiche Größenordnung (38,7 Prozent), siehe 12.1 unten |
| NM-5 | ok für 48 Zeilen | Scrollen, Regler, Aufklappen flüssig, auch bei laufendem Routing. Ein Gerät mit 128 oder 256 Kanälen war nicht vorhanden |
| NM-6 | ok | Experiment ohne Repo-Änderung (Kopie in `/tmp` mit `maxSlots = 4`): viertes Gerät abgelehnt, Warnzeile "Output limit reached: AudioRouterNow can route to 3 outputs at once. Remove an output to add another." vollständig lesbar, Liste bleibt bei 3 Zeilen |
| NM-7 | ok | Etwa 70 KiB je Zeile (18 auf 48 Zeilen: +2 MB), passt zur Rechnung (etwa 65 KiB je Slot) |
| Zusatz: Start ohne Absturz | ok (abgeleitet) | Die App startete in der Sitzung mehrfach und lief durchgehend |

**CPU und Speicher (NM-4, NM-7).** Gemessen mit `top -l 31 -s 2` (30 Werte, der erste verworfen), `ps` für RSS, Routing aktiv, Musik. CPU ist der Wert eines einzelnen Kerns.

| Zeilen | Panel | CPU Mittel (Min bis Max) | Speicher `top` / `ps` RSS |
|--------|-------|--------------------------|---------------------------|
| 3 | zu | 41,5 % (34,8 bis 42,7) | 39 MB / 93,0 MiB |
| 18 | zu | 40,3 % (35,0 bis 41,3) | 113 MB / 155,8 MiB |
| 18 | offen | 42,6 % (37,3 bis 45,0) | 116 MB / 132,0 MiB |
| 48 | zu | 42,4 % (35,4 bis 44,5) | 115 MB / 164,6 MiB |
| 3 (Store-Version 4.0.1, Build 10) | zu | 38,7 % (30,6 bis 42,3) | 41 MB / 79,6 MiB |

**Vergleich mit 4.0.1 (23.11.2026):** Die Store-Version liegt mit 3 Zeilen bei 38,7 Prozent, 4.1 mit 3 Zeilen bei 41,5 Prozent. Der Unterschied von etwa 3 Prozentpunkten liegt im Rauschen (die Streuung von Min bis Max beträgt bei 4.1 etwa 8, bei 4.0.1 etwa 12 Punkte). Die Basislast von etwa 40 % eines Kerns hat also schon 4.0.1, es gibt keinen Hinweis auf eine Verschlechterung durch 4.1. Einschränkungen: je ein Lauf, andere Ausgänge als bei 4.1 (Kopfhörer, Komplete Audio Ch1-2 und Ch3-4; bei 4.1 war die CPU von der Zeilenzahl unabhängig), nicht verblindet; die Ursache der Basislast ist nicht untersucht.

Die Prozesse waren unterschiedlich lange gelaufen. Der Sprung von 3 auf 18 Zeilen (+74 MB) ist nicht zeilenproportional; Hypothese, ungeprüft: feste Kosten der BlackHole-Geräte (Datenströme), nicht der Slots.

### 12.2 Befunde und Beobachtungen

1. **M8 war zuerst falsch bewertet.** Am 22.11. war M8 nach der Nutzerangabe "kurze Unterbrechung, Musik läuft weiter" als ok eingetragen. Die Log-Auswertung zeigte: In beiden Versuchen lief die 3-s-Frist ungestört ab (`hdmiSettleDelay` = 3,0 s), zwei Neustarts folgten, "L1: Blip erkannt" fehlte. Die Komplete Audio kam aus Sicht der App etwa 3,1 s nach dem Verschwinden zurück (3,14 s und 3,09 s, Unsicherheit etwa ±0,1 s). Der Eintrag wurde zurückgenommen und erst nach der Wiederholung am 23.11. wieder auf ok gesetzt. Folge für die Nutzer: Die Absorption greift nur, wenn das Gerät innerhalb von 3,0 s zurück ist. Wer ein USB-Interface langsamer wieder anmeldet, bekommt weiter den regulären Neustart. Das ist so gedacht, die Frist liegt aber bei der Komplete Audio knapp unter ihrer Wiederanmeldezeit. Ob die Frist für USB-Interfaces zu knapp ist, ist eine Designfrage für später, kein Code wurde geändert.
2. **Die Anleitung zu M6 war an einer Stelle falsch.** Sie vermutete, das Subsystem der Test-App weiche wegen der Bundle-ID `.test` ab. Im Code steht das Subsystem fest als `com.mauriciomorkun.audiorouternow` (`DeviceLifecycleManager.swift`, `FanOutEngine.swift`, `EngineController.swift`, `VolumeTracker.swift`). Das Prädikat braucht keine Anpassung. Praktisch: `log stream` zeigt nur neue Einträge, ein leeres Terminal beweist für sich nichts. Die rückwirkende Abfrage `/usr/bin/log show --info --debug --predicate 'subsystem == "com.mauriciomorkun.audiorouternow"'` ist die belastbare Gegenprobe. In der zsh ist `log` ein eingebauter Befehl, deshalb den vollen Pfad `/usr/bin/log` verwenden.
3. **M7 zeigt einen einzelnen Noop** 16 s nach dem Neustart (Rate 44100, `total_noops=1`). Das ist ein Folgeping des Systems nach dem Warm-Restart. Es ist kein Dauerfeuer (M6 zählt über mindestens 90 Minuten 0), aber die Erwartung "kein M4-Noop im Log" ist für diesen Wechsel wörtlich nicht erfüllt.
4. **Die Meldung am Limit erscheint beim Anklicken, nicht beim Öffnen des Menüs** (`EngineController.addOutputConfig`). Das Menü bietet am Limit weiter alle Einträge an. Kein Mangel, aber das Ausgrauen der Einträge am Limit wäre eine mögliche Verbesserung für später.
5. **Kein Ersatz für fehlende Hardware.** Mit 8 echten Paaren war die Großliste nicht prüfbar. Die Nachmessung mit BlackHole liefert 48 Zeilen, aber nur etwa 6 davon sind hörbar (Kopfhörer, Lautsprecher, Komplete Audio, BenQ); die BlackHole-Zeilen sind Aufnahmegeräte ohne Lautsprecher. Geprüft wurde Index 16 (Platz 17) und Index 32 (Platz 33) hörbar, nicht jede Zeile.
6. **Messumgebung.** Die Auswahl der Test-App liegt in den Einstellungen der Test-Bundle-ID unter `arn.v4.outputConfigs` (JSON mit `uid`, `channelCount`, `channelOffset`). Für die Messung wurde sie mit 16 und mit 48 Einträgen vorbefüllt (nur Test-Bundle-ID, nicht die Store-App) und am Ende aus einer Sicherung im Home-Ordner (`arn-test-prefs-backup-20261123.plist`) auf die ursprünglichen 3 Zeilen zurückgesetzt. Die NM6-Testkopie (Desktop) und das Build-Verzeichnis in `/tmp` sind gelöscht. Das Repo blieb unverändert.

### 12.3 Offen nach der Messsitzung

| Punkt | Stand | Einordnung |
|-------|-------|------------|
| Zusatzzeilen: VoiceOver-Hinweis je Footer-Symbol, Tab-Fokus-Reihenfolge, Umbruch bei großer Schrift | nicht geprüft (je etwa 5 Minuten) | Vor der Einreichung empfohlen, bisher nur am Quellcode und per Nachbau belegt |
| CPU-Vergleich mit der Store-Version 4.0.1 | **erledigt 23.11.2026** | 38,7 Prozent (4.0.1) gegenüber 41,5 Prozent (4.1) bei 3 Zeilen: gleiche Größenordnung, keine Verschlechterung erkennbar. Die Basislast von etwa 40 % eines Kerns war schon in 4.0.1 vorhanden |
| Vergleich der hörbaren Pause bei M8 mit 4.0.1 | nicht gemessen | Belegt ist nur der fehlende Engine-Neustart |
| 128/256-Kanal-Gerät (NM-5) | nicht vorhanden | Für die Einreichung nicht verlangt |
| 13"-Bildschirm (M1) | Bildschirmgröße nicht erfasst | Nur das Verhalten bei 48 Zeilen ist belegt |
| Intel | nicht testbar | Das Binary ist universal, es gibt kein Intel-Gerät (E2, Option A) |
| Erneute Bestätigung E1, E3, E4, E6 und Annahme von 6a und 6d (Abschnitt 8, Punkt 2) | steht beim Nutzer aus | Die Messungen widersprechen keiner dieser Entscheidungen: M1 zeigt, dass das Scrollen bei 48 Zeilen funktioniert (die konkrete Höhe von 400 pt in E1 wurde nicht einzeln gemessen), M3 und M9 passen zu E4, M8 stützt E6. E3 (Icon-Knopf in der Statuszeile) ist durch die Entscheidung für C3 (großer Knopf oben) abgelöst und wird durch M2 nicht mehr gemessen. Der Launch-at-Login-Reset (6d) wurde nicht gemessen |

**Nächste Schritte** unverändert nach Abschnitt 8, ab Punkt 2. Jeder unumkehrbare Schritt (Archiv, Tag, Merge, Push, Einreichung) nur auf ausdrückliche Anweisung des Nutzers. Kein Push, kein Tag, keine Einreichung bisher.

### 12.4 Archiv (23.11.2026)

Archiv gebaut am 23.11.2026, 17:23 Uhr, per `xcodebuild archive` (Release, `generic/platform=macOS`) aus dem sauberen Arbeitsbaum bei HEAD `429b865`. Ablage im Xcode-Archivordner (`~/Library/Developer/Xcode/Archives/2026-11-23/`, Name "AudioRouterNow4 23-11-2026, 17.23.xcarchive", 14 MB, sichtbar im Organizer). Geprüft am Archiv selbst: Version 4.1 (11), Bundle-ID `com.mauriciomorkun.audiorouternow`, `LSMinimumSystemVersion` 14.4, universal (`x86_64 arm64`), `codesign --verify --deep --strict` gültig, Hardened Runtime, Entitlements nur App Sandbox und Audio Input (kein `get-task-allow`), dSYM vorhanden, Signatur "Apple Development" (wie beim 4.0.1-Archiv; die Neusignierung für den Store übernimmt die Verteilung im Organizer). Der Binary enthält die Endstand-Texte (Support-Hinweis, Schloss-Hinweis, "All outputs are added.", Limit-Meldung). Tests vor dem Archiv: 60 swift-testing und 129 XCTest, alle grün. Preflight: kein Abbruchgrund mehr, eine Warnung (Commits nicht gepusht).

**Noch nicht erfolgt:** Hochladen nach App Store Connect, Eintragen der Texte, Datum im CHANGELOG, Tag `v4.1`, Merge, Push, Einreichung. Der Tag gehört auf den Commit, aus dem das Archiv gebaut wurde (`429b865`) oder einen späteren reinen Doku-Commit. Alle Schritte nur auf ausdrückliche Anweisung des Nutzers.
