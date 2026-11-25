# AudioRouterNow 4.1: Release-Runbook (vom Archiv bis zur Nachsorge)

Stand 24.11.2026. Dieses Dokument ordnet alles, was für das Release von 4.1 (Build 11) noch zu tun ist,
und hält fest, was schon belegt ist. Es enthält nur den technischen und organisatorischen Ablauf der
App. Marketing-Inhalte stehen bewusst nicht hier (Regel: Marketing kommt nie ins Repository).

Erarbeitet aus fünf unabhängigen Prüfungen (Release-Technik, Qualität, Compliance und Vor-Push-Audit,
Marketing, Register aller offenen Punkte), jeweils im Opus-Modell und nur lesend, danach von Claude
gegen Git und Code nachgeprüft. Jede Aussage trägt eine Einordnung: **belegt** (mit Quelle),
**gemessen**, **ungeprüft** oder **Annahme**. Jeder unumkehrbare Schritt geschieht nur auf
ausdrückliche Anweisung des Nutzers.

## 1. Ist-Stand (belegt)

| Punkt | Stand | Quelle |
|-------|-------|--------|
| Code | Version 4.1 (Build 11) auf `release/4.1`, 81 Commits vor `origin/main`, 79 vor lokalem `main`, nicht gepusht, kein Tag `v4.1` | `git rev-list --count`, `git tag` |
| Archiv | gebaut am 23.11.2026 um 17:23 aus Commit `429b865` (Archiv-Stand; aktueller HEAD ist `013f50c`, seither nur Doku-Commits), 4.1 (11), universal, signiert, im Xcode-Archivordner | `09-final-report.md` 12.4 |
| Upload | erledigt 24.11.2026 (Nutzerangabe): Build 4.1 (11) ist bei App Store Connect angekommen und unter TestFlight, macOS, verarbeitet. Beim ersten Versuch blockierte ein offener Hinweis "PLA Update available" (Lizenzvereinbarung im Entwicklerkonto nicht akzeptiert) die Verteilung, danach lief der Upload (Ablauf im Einzelnen nicht erfasst) | Nutzerangabe, Portal-Screenshots |
| Portal | Eingereicht 25.11.2026 (Nutzerangabe). Status "Waiting for Review". Alle Felder gesetzt: 5 Screenshots (C3-Motive 2880x1800), What's New (Langfassung mit 255), Review-Notiz (6 Punkte), Superlativ ersetzt, Promotional Text Variante A, Subtitle/Keywords angepasst, Privacy gecheckt. 4.0.1 bleibt "Ready for Distribution". | Nutzerangabe |
| App-Code seit dem Archiv | unverändert (`git diff --stat 429b865..HEAD v4` leer, geprüft 24.11.2026) | Git |
| Preflight | kein Abbruchgrund, eine Warnung (Commits nicht gepusht) | `v4/scripts/preflight.sh` |
| Tests | 60 swift-testing, 129 XCTest, alle grün (23.11.2026) | `scripts/test.sh` |
| Messungen am Gerät | 23 von 23 Zeilen ok, keine negativ, keine offen | `27-messprotokoll.md` |
| CPU gegen 4.0.1 | 38,7 Prozent (4.0.1) gegen 41,5 Prozent (4.1), kein Unterschied | `09-final-report.md` 12.1 |
| Entscheidungen | C3 mit V2, E2 = Option A (universal), Launch-at-Login-Reset angenommen, Gerätename in den Screenshots bleibt | `09-final-report.md` 12.5 |
| Store-Texte | What's New, Review-Notiz, Ersatzsatz für den Superlativ liegen vor | `06-appstore-texts.md` |
| Screenshots | fünf Motive in 2880x1800 und 2560x1600 gebaut | `screenshots/appstore-vorlage/` (gitignoriert) |
| Landing-Page | zwei Dateien für 4.1 vorbereitet, nicht deployt | `landing-page/index.html`, `support/index.html` |
| Fast-Forward | `main` ist Vorfahre von `release/4.1`, FF-Merge möglich. Die zwei Commits, um die `main` dem Remote voraus ist (`8cc22c8`, `d8f6fc3`), sind in `release/4.1` enthalten | `git merge-base --is-ancestor` |

## 2. Vier Tore (Gates)

| Tor | Bedingung | Danach erlaubt |
|-----|-----------|----------------|
| A, Upload | Housekeeping erledigt, Zusatzzeilen geprüft (erledigt 24.11.2026), Nutzer sagt "Upload" | Upload über den Organizer |
| B, Einreichung | Build verarbeitet, Store-Texte, Screenshots, Export-Compliance-Frage geklärt und Angaben im Portal gesetzt, Superlativ-Ersatz eingetragen. Der TestFlight-Test (S06) ist keine Vorbedingung, er läuft parallel zur Prüfung | "Submit to App Review", Release manuell |
| C, Release | Apple hat genehmigt, TestFlight-Smoke-Test (S06) bestanden (empfohlen), Nutzer sagt "Release" | manuelle Freigabe im Portal |
| D, Öffentlichkeit | Store zeigt 4.1, Update-Test am eigenen Mac bestanden | Tag, Merge, Push, Landing-Page-Deploy, Antworten an Nutzer, alles Öffentliche |

## 3. Runbook

Legende: Nutzer, Claude. U = unumkehrbar.

| Nr. | Schritt | Wer | Ort | Vorbedingung | Prüfung danach | U |
|-----|---------|-----|-----|--------------|----------------|---|
| S01 | Überholte Stellen in Doku und Memory angleichen (siehe 6) | Claude | Repo, Memory | nichts | Querlesen, Stilregel, Commit lokal | nein |
| S02 | Zusatzzeilen am Gerät (VoiceOver-Hinweis, Tab-Fokus-Reihenfolge, Umbruch bei großer Schrift): **erledigt 24.11.2026** auf Nutzerangabe, Einzelbeobachtungen nicht erfasst. Der Code enthält die Korrekturen (`accessibilityHint` in `RoutingControls.swift:465`, `lineLimit(1)` plus `fixedSize` in Zeile 254 bis 273) | Nutzer | Gerät | nichts | Ergebnis in `27-messprotokoll.md` Zeilen 6 bis 8 | nein |
| S03 | Optional: Liste mit 120 bis 200 Zeilen prüfen, weil drei Nutzer mit etwa 125 Zeilen schreiben. Bisher gemessen sind 48 Zeilen. Verfahren: Konfiguration der Test-App vorbefüllen (`arn.v4.outputConfigs`). Ob künstliche, nicht vorhandene Geräte-Kennungen als Zeilen erscheinen, ist ungeprüft | Claude, Nutzer | Gerät | nichts | Ergebnis ins Messprotokoll | nein |
| S04 | Upload: Xcode, Organizer, Archiv "AudioRouterNow4 23-11-2026, 17.23", Distribute App, App Store Connect, Upload. Im Organizer muss "4.1 (11)" stehen (am 01.10.2026 wurde so ein falsches Archiv erkannt) | Nutzer | Xcode | Tor A | Mail von Apple über die Verarbeitung | teilweise: Der Upload ist keine Einreichung, aber Build 11 ist danach bei Apple belegt. Nach einer Ablehnung folgt Build 12 (die Build-Nummer muss höher sein als die zuletzt hochgeladene) |
| S05 | Verarbeitung abwarten (Minuten bis etwa eine Stunde) | Nutzer | App Store Connect | S04 | Build 11 ist unter "Build" wählbar | nein |
| S06 | TestFlight-Update-Test des echten Store-Builds, parallel zu S07 und zur Apple-Prüfung (die Verarbeitung für TestFlight ist ein eigener Wartepunkt nach S05). Er gatet nicht die Einreichung, sondern Tor C. Zweck: die einzige am Store-Build noch unbelegte Stelle schließen, nämlich der Update-Pfad über eine bestehende 4.0.1-Installation. Smoke-Test siehe 4 | Nutzer | Mac, TestFlight | S05, interner Tester | Tabelle in 4 | nein |
| S07 | App Store Connect: Version 4.1 anlegen, Build 11 wählen, "What's New" und Review-Notiz aus `06-appstore-texts.md` eintragen, in der Description den Superlativ-Satz ersetzen (nur im Portal vorhanden), Promotional Text prüfen, fünf Screenshots hochladen (fünf C3-Motive, 2880x1800 oder 2560x1600, erlaubt sind 1 bis 10 Bilder laut `26-release-plan.md` 4(f), beim Hochladen im Portal bestätigen), Altersfreigabe und App-Privacy-Angaben gegen 4.0.1 gegenprüfen (in keiner 4.1-Unterlage erwähnt, Annahme: unverändert), Export-Compliance: der Schlüssel `ITSAppUsesNonExemptEncryption` steht in `v4/AudioRouterNow4/Info.plist` (Zeile 35, belegt), die Frage sollte entfallen, falls sie doch gestellt wird: keine eigene Verschlüsselung, Veröffentlichung auf manuell. Vorschlag für die Review-Notiz (Entscheidung beim Nutzer): ein Satz, dass Solo und Fan-out mindestens zwei Ausgabegeräte brauchen und die eingebauten Lautsprecher plus ein zweites Gerät (Kopfhörer, Monitor) genügen | Nutzer | App Store Connect | S05 | alle Felder gesetzt | nein |
| S08 | Einreichen ("Submit to App Review") | Nutzer | App Store Connect | Tor B | Status "Waiting for Review" | ja |
| S09 | Datum und Status in `CHANGELOG.md` (`[4.1 (11)], YYYY-MM-DD`) und `RELEASE_NOTES.md` ("not yet submitted" entfernen) setzen, lokal committen | Claude | Repo | S08 | Preflight, Stilregel | nein |
| S10 | Apple-Prüfung abwarten. Erfahrung 4.0.x: 1 bis 3 Tage. Dauert sie länger als 3 Tage: den Nutzern, denen eine Zeitangabe gemacht wurde, eine kurze neutrale Zwischennachricht schicken, keine neue Terminzusage | Nutzer | App Store Connect | S08 | Status "Pending Developer Release" | nein |
| S10a | Bei Ablehnung: die Meldung vollständig kopieren und nicht raten (bei 4.0.x war ein genannter Grund einmal nicht die Ursache). Behebung, Build-Nummer auf 12 erhöhen, neues Archiv, zurück zu Tor A. Es wird kein Tag gesetzt | Nutzer, Claude | App Store Connect, Repo | S10 | neuer Build in Prüfung | nein |
| S11 | Freigabe: "Release this version" auslösen | Nutzer | App Store Connect | Tor C | Status "Ready for Sale" | ja |
| S12 | Prüfung nach dem Release: Store-Seite zeigt 4.1, Update über eine echte 4.0.1-Installation, Launch-at-Login-Reset beobachten | Nutzer | Mac | S11 | Tor D | nein |
| S13 | Tag `v4.1` setzen und pushen erst nach dem Release, nie vorher: Bei einer Ablehnung bekäme sonst ein bereits gepushter Tag einen nie veröffentlichten Stand, und ein gepushter Tag lässt sich nur per Force-Push zurückziehen (Annahme). Der Tag zeigt auf den Commit, der das CHANGELOG-Datum trägt (vorher belegen, dass seit `429b865` kein App-Code geändert wurde); ein Build 12 bekäme den Tag. FF-Merge von `release/4.1` nach `main`, Push von `main` und Tag. Der Push enthält auch die zwei ausstehenden Commits von `main` | Claude | Terminal | Tor D, ausdrückliche Anweisung | `git ls-remote --tags origin` | ja |
| S14 | Doku auf "released": `CHANGELOG.md`, `RELEASE_NOTES.md`, Wurzel-`README.md`, `docs/v4.1/README.md`, Memory, `LAUNCH_EXECUTION.md` | Claude | Repo | S13 | Querlesen | nein |
| S15 | Optional: GitHub-Release `v4.1` ohne Binary. Für `v4.0.0` und `v4.0.1` gibt es Tags, aber keine GitHub-Releases (nur v3.x). Nur falls Konsistenz gewünscht | Claude | GitHub | S13 | `gh release list` | nein |
| S16 | Branch `release/4.1` nach dem Push löschen (zeigt dann auf denselben Commit wie `main`, der Tag sichert den Stand) | Claude | Terminal | S13 | `git branch -a` | nein |
| S17 | Landing-Page und Support-Seite deployen, erst nach Tor D und nur mit Freigabe, kein `rsync --delete` auf die Server-Wurzel. Ob ein Cron vom 4.0.1-Release noch aktiv ist, ist ungeprüft (lesend prüfbar) | Claude | Webserver | Tor D, Freigabe | Seite zeigt 4.1 | nein |
| S18 | Nachsorge 48 Stunden: Absturzberichte in Xcode und App Store Connect, Rezensionen, Support-Eingang, Bereitschaft für 4.1.1 | Nutzer, Claude | Portal, Postfach | S11 | keine neuen schweren Fehler | nein |

Beispielzeitplan, wenn heute (Dienstag 24.11.2026) hochgeladen wird: Dienstag S01 bis S04, Mittwoch S05
bis S09, Donnerstag und Freitag Apple-Prüfung, Release Freitag oder Montag. Die Zusage "diese Woche,
spätestens nächste Woche" ist damit machbar, aber sie hängt an der Dauer der Apple-Prüfung, die ich
nicht beeinflussen kann (Annahme: 1 bis 3 Tage). Ein Freitag-Release ist optimistisch, intern ist mit
"nächste Woche" zu planen.

## 4. Smoke-Test des Store-Builds (S06, etwa 10 Schritte)

Ausgangslage: Store-Version 4.0.1 auf dem Mac installiert, Ausgänge konfiguriert, Launch at Login an.
Danach den TestFlight-Build 4.1 (11) darüber installieren.

1. Start ohne Absturz.
2. Das Onboarding erscheint nicht erneut (Code: `hasShownOnboarding` bleibt, ungeprüft am echten Update).
3. Ausgänge und Lautstärken sind erhalten (`arn.v4.outputConfigs`, `arn.v4.deviceGains`).
4. Kein neuer Berechtigungsdialog beim Routing (Annahme: Bundle-ID und Signatur unverändert).
5. Audio läuft auf allen konfigurierten Geräten.
6. Oberer Start/Stop-Knopf und Footer erreichbar.
7. Solo an einem Ausgang, danach aufheben.
8. "Launch at Login" ist zurückgesetzt (gewollt) und hält nach erneutem Aktivieren über einen Neustart.
9. "Add device": bereits hinzugefügte Einträge mit Haken und ausgegraut.
10. USB-Gerät kurz abziehen und innerhalb von etwa 2 Sekunden wieder einstecken: kein Abriss.

Hinweis: Dass TestFlight eine bestehende Store-Installation in-place ersetzt und die Einstellungen
erhält, ist eine Annahme und ungeprüft. Falls nicht, ist der Schritt 12 nach dem Release der Ersatz.

## 5. Risikoregister

| ID | Risiko | Wahrscheinlichkeit | Auswirkung | Einordnung | Gegenmaßnahme | Blocker |
|----|--------|--------------------|-----------|------------|---------------|---------|
| R1 | Echter Update-Pfad (Berechtigung, Einstellungen, Reset) am Store-Build nicht beobachtet | mittel | hoch | **geschlossen (S06 bestanden 25.11.2026)** | S06 und S12 | nein, vor Tor C |
| R2 | Liste mit 49 bis 255 Zeilen nie real geprüft, drei Nutzer mit etwa 125 | mittel | mittel | ungeprüft | S03, Rückmeldung der Nutzer nach dem Release | nein |
| R3 | Screenshots mit alter Oberfläche führen zur Ablehnung (Guideline 2.3) | mittel | hoch | Annahme | nur die neuen Motive hochladen | ja für S07 |
| R4 | Superlativ in der Live-Description (Guideline 2.3) | mittel | mittel | Annahme | Ersatzsatz vor S08 eintragen | ja für S08 |
| R5 | Guideline 2.4.5(iii) beim Launch-at-Login-Reset | gering | mittel | belegt: in Build 10 akzeptiert, Review-Notiz nennt es | Review-Notiz wortgleich übernehmen | nein |
| R6 | Blip-Absorption greift nur bei Rückkehr unter 3,0 s, die Komplete Audio kommt nach etwa 3,1 s | mittel | niedrig | gemessen | in der Doku vermerkt, Designfrage für 4.2 | nein |
| R7 | Zusatzzeilen ungeprüft (Code-Korrekturen vorhanden) | niedrig | niedrig | belegt (Code), ungeprüft (Gerät) | S02 | nein |
| R8 | CASE-003-Absturzpfad in 4.1 nicht erneut verifiziert | niedrig | hoch | ungeprüft | S06, S18 | nein |
| R9 | Vorgestellte Aussage über Verhalten bei vielen Zeilen oder Pausenlänge ohne Messung | mittel | mittel | belegt: nicht gemessen | in öffentlichen Texten nur belegte Aussagen verwenden | nein |

Rückfallplan nach dem Release: Ein Downgrade gibt es im Store nicht. Möglich sind ein Notfall-Update
4.1.1 mit beschleunigter Prüfung (Stunden bis zwei Tage, Annahme) oder das Entfernen aus dem Verkauf
(schnell, nimmt 4.1 auch für Neukunden, Bestandsnutzer behalten ihre Version). Vorbereitung jetzt:
`release/4.1` sauber halten, Tag erst beim Release setzen, in den ersten 48 Stunden Berichte und
Rezensionen beobachten.

## 6. Vor-Push-Audit (Ergebnis) und Doku-Aufräumliste

**Audit der Commits und Dateien, die mit dem Push öffentlich werden** (81 Commits vor `origin/main`):

- Keine Zugangsdaten, Tokens, Schlüssel, Server-IPs, SSH-Angaben oder Klarnamen von Support-Kontakten
  in getrackten Dateien (belegt, Suche leer). `git ls-files -ci --exclude-standard` ist leer, es ist
  also keine gitignorierte Datei getrackt (belegt).
- Die Apple-Team-Kennung steht in `project.pbxproj` (4 Vorkommen). Sie steht auf `origin/main` genauso
  (4 Vorkommen) und wird durch den Push nicht neu veröffentlicht (belegt). Eine Team-Kennung ist kein
  Zugangsdatum.
- Der lokale Benutzername steht in 41 neuen Zeilen in 14 Dokumenten unter `docs/v4.1/` (nur Pfade, kein
  Code). Kosmetisch, nicht blockierend.
- Die Umami-Website-Kennung in der Landing-Page ist öffentlich ausgeliefertes HTML und steht schon auf
  `origin/main`.
- `docs/v4.0.1/` und `docs/v3.4.6/` sind bereits öffentlich (15 Dateien auf `origin/main`). Der Baum
  `docs/v4.1/` würde mit dem Push ebenfalls öffentlich (Pläne, Audits, Messprotokoll, dieses Runbook).
  Das folgt dem bisherigen Muster, ist aber eine Entscheidung des Nutzers (siehe 7).

**Überholte Stellen** (in S01 anzugleichen):

- `26-release-plan.md` Abschnitt 1 und 2 nennen noch den Stand vom 17.11. (65 Commits, ein ABBRUCH,
  unverbuchter Arbeitsbaum). Die Nachträge am Dateiende gelten.
- `09-final-report.md` Abschnitt 8 (letzter Absatz der Aufgabenliste) nennt "kein Archiv" als offen,
  Abschnitt 12.4 gilt.
- `27-messprotokoll.md` Kopf nennt HEAD `c393e6d` und 74 Commits, das Archiv stammt aus `429b865`.
- `.claude/CLAUDE.md` und `project_audiorouternow_v41_status.md` (Memory): Commit-Zahl und der Testwert
  "96 XCTest" sind überholt (aktuell 129).
- `26-release-plan.md` Schritt 12 (Zeile 387) sagt, der Tag komme "nach erfolgreicher Validierung/Einreichung". Das ist zu präzisieren: Der Tag kommt nach dem Release (S13), wie bei 4.0.1.
- `26-release-plan.md:548` enthält ein maskiertes Fragment der Team-Kennung. Entfernen.
- `26-release-plan.md` Zeilen 345 bis 349 enthalten einen ASO-Absatz (Subtitle, Schlüsselwörter). Das ist
  Marketing-Inhalt und gehört laut Projektregel nicht in öffentliche Dateien (siehe 7).
- `CHANGELOG.md:70` und `RELEASE_NOTES.md:156` tragen "YYYY-MM-DD" und "not yet submitted": wird in S09 und
  S14 gesetzt.

## 7. Entscheidungen des Nutzers

| Nr. | Frage | Empfehlung |
|-----|-------|------------|
| D1 | TestFlight-Update-Test des Store-Builds (S06) | ja, er läuft parallel zur Apple-Prüfung und verzögert nichts |
| D2 | `docs/v4.1/` mit dem Push öffentlich machen (wie bei 4.0.1 und 3.4.6) | ja, nach Bereinigung nach 6 |
| D3 | ASO-Absatz in `26-release-plan.md`: entfernen. Er bleibt in der Historie sichtbar, außer die lokale, nicht gepushte Historie wird vorher bereinigt (aufwendig, nicht empfohlen) | entfernen, Historie belassen |
| D4 | Kosmetik: lokale Pfade durch `~/` ersetzen, Team-Fragment entfernen | ja, mechanisch und umkehrbar |
| D5 | GitHub-Release `v4.1` ohne Binary (S15) | optional, nein ist vertretbar |
| D6 | Zusatzzeilen und optionaler Großlisten-Test vor dem Upload (S02, S03) | S02 ja, S03 optional |
| D7 | Bestätigung der UI-Entscheidungen E1, E4, E6 aus dem 4.1-Plan und von 6a (nicht zu verwechseln mit den Homepage-Entscheidungen HP-E1 bis HP-E8) | nicht blockierend, die Messungen widersprechen keiner |

Weitere Entscheidungen zu Zeitpunkt und Marketing (D8, D9) stehen nur im privaten Gesamtplan, nicht im Repository.

## 8. Übergabe: Stand der Portal-Schritte (aktualisiert 25.11.2026)

P1 bis P8 sind vollständig erledigt. 4.1 (Build 11) wurde am 25.11.2026 bei Apple eingereicht.
Einordnung: **Nutzerangabe** = vom Nutzer gemeldet, von Claude nicht gegengeprüft.

| Nr. | Portal-Schritt | Stand | Einordnung |
|-----|----------------|-------|------------|
| P1 | Build 4.1 (11) ist unter TestFlight, macOS, verarbeitet | erledigt 24.11.2026 | Nutzerangabe |
| P2 | Version 4.1 anlegen, Build 11 wählen, Release auf "Manually release this version", Save | erledigt 24.11.2026 | Nutzerangabe |
| P3 | Screenshots: 5 neue C3-Motive (2880x1800), Reihenfolge 01 bis 05, alte 4.0.1-Bilder entfernt | erledigt 25.11.2026 | Nutzerangabe |
| P4 | "What's New" (Langfassung mit 255-Limit, `06-appstore-texts.md` Abschnitt 4) eingetragen | erledigt 25.11.2026 | Nutzerangabe |
| P5 | Review-Notiz (6 Punkte, inkl. Output-Limit-Nachtrag) und Kontakt eingetragen | erledigt 25.11.2026 | Nutzerangabe |
| P6 | Superlativ ersetzt durch "runs fully sandboxed. No kernel extension. No virtual driver. No reboot." Promotional Text: Variante A ("Send your Mac's audio...volume keys keep working...") | erledigt 25.11.2026 | Nutzerangabe |
| P7 | App-Privacy gecheckt (unverändert), Altersfreigabe-Bereich nicht geöffnet, Export-Compliance kein Blocker | erledigt 25.11.2026 | Nutzerangabe |
| P8 | "Submit to App Review" geklickt | erledigt 25.11.2026, U | Nutzerangabe |
| P9 | S09 (CHANGELOG-Datum "2026-11-24", RELEASE_NOTES "submitted") committed (`3122566`). S06 TestFlight-Smoke-Test: alle 10 Punkte bestanden (25.11.2026): Start, Onboarding, Einstellungen erhalten, Berechtigungen, Audio, Start/Stop, Solo, Launch-at-Login-Reset, Add-device-Markierung, Blip-Absorption. | S09 erledigt, S06 bestanden. Tor C freigegeben. | Nutzerangabe |

**Offene Fragen an den Nutzer für P4 bis P7:**
1. Soll die ergänzte "What's New"-Fassung (mit 255) verwendet werden oder die ältere Vorlage?
2. Subtitle und Keywords (Tipp vom 28.10.2026, siehe Memory zu ASO): jetzt mit 4.1 ändern oder bewusst nicht? Sie sind nicht Teil der 4.1-Änderungen und werden von dieser Doku nicht vorgegeben.
3. Zeitpunkt der Einreichung, da Release danach manuell erfolgt.

**Beobachtungen vom Upload (für die Doku, nicht für den Code):**
- Eine nicht akzeptierte Programmlizenz (PLA) im Entwicklerkonto sperrt die Verteilung aus dem Organizer. Meldungen "No signing certificate Mac App Distribution / Mac Installer Distribution found" sind in diesem Fall Folgefehler: Xcode kann die Zertifikate wegen der Sperre nicht anlegen. Das Archiv selbst war nicht betroffen und musste nicht neu gebaut werden. Es ist der Kontoinhaber, der die Vereinbarung akzeptiert.
- In der Schlüsselbundverwaltung lagen am 24.11.2026 vor dem Upload nur "Apple Development" und "Developer ID Application", keine App-Store-Verteilungszertifikate (geprüft per `security find-identity`).
- Xcode-Projektansicht: "App Category: None" und leerer "Display Name" sind nur die Anzeige. Die Kategorie steht in der `Info.plist` (`public.app-category.utilities`, im Archiv geprüft).
