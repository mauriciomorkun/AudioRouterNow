# AudioRouterNow 4.1: Abschlussbericht

Phase 4 des Kreislaufs (Planung durch Fable, Umsetzung durch Opus, Audit durch
Fable, 2 Durchläufe). Geschrieben nach der Arbeit, ausschließlich aus den
Dokumenten in `docs/v4.1/`, dem Commit-Verlauf `e7db9fe^..HEAD` auf `release/4.1`
und den Angaben im Auftrag. Wo etwas in diesen Quellen nicht steht, steht hier
"ungeprüft". Dieser Bericht enthält keinen neuen Code und keine neue Messung.

## 1. Ergebnis in 5 Sätzen

1. Der Code von 4.1 (Version 4.1, Build 11) enthält eine scrollbare Geräteliste
   mit zusätzlichem Start/Stop-Schalter in der Statuszeile, einen Solo-Button pro
   Ausgabe, einen Sample-Rate-Listener mit Änderungserkennung und die Absorption
   kurzer Geräteaussetzer (Blips) beim Entfernen von Geräten, dazu die
   Release-Dokumentation und die Textvorlagen für App Store Connect.
2. Teststand zuletzt: 59 swift-testing in 10 Suiten und 56 XCTest, alle grün,
   App-Build (Debug, `CODE_SIGNING_ALLOWED=NO`) erfolgreich; beides hat der Audit 2
   selbst ausgeführt.
3. Audit 1 fand 0 hohe, 1 mittleren und 2 niedrige Befunde, Audit 2 fand 0 hohe,
   0 mittlere und 1 niedrigen Befund (C1, Namenskollision einer Entscheidungs-ID in
   der Dokumentation); alle fünf Befunde B1 bis B5 sind behoben oder dokumentiert.
   Audit 3 ist noch ausstehend (`12-audit-v3.md`).
4. Es fehlen alle Messungen am Gerät (M1 bis M9, keine ist erledigt) und die
   Einreichung (neues Archiv, App Store Connect, Tag, Merge, Push).
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
| 2 | `05-plan-v2.md`, Commit `41d4673` (Fable, 7 Schritte N0 bis N7, Entscheidungen D1 und D2, Messpunkt M9) | `cba4489`, `fd502c7`, `f2f7deb`, `c079c27`, `68c8d71`, `8eae52b`, README `70fcfe0`, Protokoll `07-impl-v2.md` (Opus) | `08-audit-v2.md`, Commit `080f0c8` (Fable): Build, 59 + 56 Tests und Preflight selbst ausgeführt | B1 bis B5 behoben oder dokumentiert, neu: C1 niedrig | C1 offen |
| 3 | `10-plan-v3.md` (Fable, 4 Schritte P3-S0 bis P3-S3 plus Bericht-Update P3-S4, 3 Entscheidungen P3-D1 bis P3-D3) | Commits P3-S1 bis P3-S4 (Opus) | `12-audit-v3.md` (Fable): folgt | F1, F2, F3, F4 | In diesem Durchlauf |

Der Audit 1 hielt einen neuen Durchlauf für nicht notwendig und empfahl, B1 als
Einzelfix zu behandeln; die Entscheidung liege beim Nutzer. Durchgeführt wurde
trotzdem ein zweiter Durchlauf, der alle Befunde bündelte. Wer das entschieden
hat, steht in den Dokumenten nicht ausdrücklich ("ungeprüft"). Das Limit von 3
Durchläufen wurde nicht ausgeschöpft.

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

Vor der Umsetzung bestätigt, am Gerät nicht verifiziert:

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

| ID | Thema | Prüfanleitung | Erwartetes Ergebnis | Ergebnis |
|----|-------|---------------|---------------------|----------|
| M1 | ScrollView mit 45 oder mehr Einträgen | BlackHole 64ch und ein Interface mit vielen Kanälen (z.B. Scarlett 18i20) verbinden, App starten, Panel öffnen. Scroll-Indikator, Scrollbarkeit, Footer und Header-Toggle prüfen. Auf einem MacBook 13" prüfen, ob das Panel auf den Bildschirm passt | Ja zu allen Fragen: Indikator sichtbar, Liste scrollbar, Footer immer sichtbar, Toggle sichtbar, Footer nicht abgeschnitten | |
| M2 | Header-Toggle | Mindestens ein Gerät konfiguriert. Im Zustand idle `play.fill` klicken, im Zustand active `stop.fill` klicken, im Zustand starting den Toggle ansehen | Routing startet und stoppt korrekt, im Zustand starting deaktiviert, kein doppelter Start | |
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
