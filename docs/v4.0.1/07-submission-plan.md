# Ablaufplan: 4.0.1 bei App Review einreichen

> Dieses Dokument ist bewusst auf Deutsch, anders als der Rest des Ordners. Die
> übrigen Dokumente sind Berichte für Leser, dieses ist eine Arbeitsliste zum
> gemeinsamen Abhaken.

## Stand

| Phase | Stand |
|---|---|
| 0: Ausgangslage sichern | ⬜ offen, fuer Build 10 noch nicht gelaufen |
| 1: Archiv erstellen | ⬜ offen, Build-9-Archiv veraltet |
| 2: Validieren | ⬜ offen |
| 3: Hochladen | ⬜ offen |
| 4: Angaben in App Store Connect | ⬜ offen, liegt beim User |
| 5.1: Pruefung gegen den Code | ⬜ offen, muss fuer Build 10 wiederholt werden |
| 5.2: Pruefung in App Store Connect | ⬜ offen, liegt beim User |
| 6: Absenden | ⬜ offen |
| 7: Danach | ⬜ offen |

**Build 9 wurde am 01.10.2026 hochgeladen, aber nie eingereicht. CASE-007 und CASE-008
wurden am 06.10.2026 committed und erhoehen die Build-Nummer auf 10. Die Phasen 0 bis 3
muessen fuer Build 10 neu durchlaufen werden.** Was beim ersten Durchlauf geschah, steht
in [08-submission-log.md](08-submission-log.md).

Was beim Durchlaufen der Phasen 0 bis 3 tatsächlich geschah, steht in
[08-submission-log.md](08-submission-log.md). Dieses Dokument sagt, was geschehen
soll, das andere sagt, was geschah.

## Warum die Prüfung vor dem Absenden liegt

Beim Code gilt: planen, umsetzen, prüfen, bei Befunden wiederholen. Das
funktioniert, weil jeder Schritt umkehrbar ist.

Hier nicht. **„Submit for Review" ist der einzige Schritt, der sich nicht
zurücknehmen lässt**, ohne die Einreichung zurückzuziehen. Eine Prüfung danach
stellt nur fest, dass es zu spät ist. Deshalb sitzt die vollständige Prüfung in
Phase 5, **vor** dem Absenden in Phase 6.

## Legende

| Zeichen | Bedeutung |
|---|---|
| 🤖 | Kann Claude erledigen |
| 👤 | Musst du machen, Xcode-Oberfläche oder App Store Connect |
| ⚠️ | Hier ist schon einmal etwas schiefgegangen |
| ✅ | Erledigt, mit Datum und dem, was dabei herauskam |
| ⬜ | Offen |

Kursive Zeilen unter einem Schritt halten fest, was bei der Ausführung
tatsächlich geschah. Der Schritt selbst bleibt unverändert, damit der Plan beim
nächsten Release wieder benutzbar ist.

---

## Phase 0: Ausgangslage sichern ⬜ offen, fuer Build 10 wiederholen

> **Historisches Protokoll: Build 9.** Die kursiven Notizen in dieser Phase
> beschreiben den Durchlauf vom 01.10.2026, der Build 9 produzierte. Fuer
> Build 10 laeuft diese Phase neu.

**0.1 ⬜ 🤖 Arbeitsbaum sauber und alles gepusht.**
Nichts darf uncommitted sein. Was nicht im Repository steht, lässt sich später
nicht dem eingereichten Build zuordnen.
*Erledigt 01.10.2026, Arbeitsbaum war sauber.*

**0.2 ⬜ 🤖 Version und Build bestätigen.**
`v4/Configs/AudioRouterNow4.xcconfig` muss `MARKETING_VERSION = 4.0.1` und
`CURRENT_PROJECT_VERSION = 10` enthalten. Das ist die einzige Quelle, `project.yml`
verweist nur darauf.
*Bestätigt 07.10.2026: MARKETING_VERSION = 4.0.1, CURRENT_PROJECT_VERSION = 10.*

**0.3 ⬜ 🤖 Tests laufen lassen.**
`./v4/scripts/test.sh`, erwartet werden 59 swift-testing in AudioRouterKit, alle grün.
*Erledigt 07.10.2026, alle 59 swift-testing Tests gruen.*

**0.4 ⬜ 🤖 Release-Build lokal.**
Muss ohne Fehler durchlaufen, bevor Xcode überhaupt geöffnet wird.
*Erledigt 01.10.2026, fehlerfrei.*

**0.5 ⬜ 👤 Andere Instanzen beenden.**
`ARN-build9-NACHHER.app` vom Schreibtisch und die App Store Version 4.0.0 dürfen
beim Archivieren nicht laufen. Sie greifen auf dieselben Audiogeräte zu.
*Erledigt 01.10.2026.*

**0.6 ⬜ 🤖 Vorflug-Prüfung ausführen.**

```sh
./v4/scripts/preflight.sh
```

Prüft in einem Durchlauf: doppelter Projektbaum, Version aus einer einzigen
Quelle, ob die Version schon getaggt und damit ausgeliefert ist, Arbeitsbaum,
Berechtigungen, und nach dem Archivieren, ob das Archiv aus dem **richtigen**
Baum stammt.

Das Skript existiert, weil am 01.10.2026 ein Archiv aus dem falschen Baum kam.
Aus v3.4.6 stammt die Lehre, dass eine Notiz in einem Dokument kein Tor ist.
**Nach Phase 1 noch einmal ausführen**, dann prüft Abschnitt 6 das frische
Archiv.

*Zur Entstehung, damit die Reihenfolge nicht falsch gelesen wird: dieser Schritt
stand am 01.10. noch nicht im Plan. Das Skript wurde erst **nach** dem falschen
Archivlauf geschrieben (`41246bc`) und konnte den Fehler, aus dem es entstand,
nicht verhindern. Nach dem zweiten, korrekten Archivlauf ist es gelaufen und hat
bestanden. Für jedes künftige Release greift es ab Phase 0.*

**Noch keinen Tag setzen.** Ein Tag sagt „das ist die Version". Solange die
Validierung nicht durch ist, kann sich der Stand noch ändern. Der Tag kommt in
Phase 7.

---

## Phase 1: Archiv erstellen ⬜ offen, Build 9 veraltet

> **Historisches Protokoll: Build 9.** Die kursiven Notizen in dieser Phase
> beschreiben den Archivlauf vom 01.10.2026, der Build 9 produzierte. Fuer
> Build 10 laeuft diese Phase neu, beginnend mit einem frischen Clean Build Folder.

**1.1 ⬜ 👤 Xcode öffnen.**

⚠️ **Es gibt zwei Projekte mit identischem Namen.** Das ist am 01.10.2026
tatsächlich schiefgegangen: der erste Archivlauf kam aus dem falschen Baum und
erzeugte ein Archiv mit **4.0.0 (7)** statt 4.0.1 (9).

> **Diese Warnung hat sich bewährt, und zwar als einzige Instanz.** Sie war der
> Grund, überhaupt in den Organizer zu schauen, statt direkt auf „Distribute" zu
> gehen. Der falsche Build hätte Validierung **und** Upload bestanden, beide
> prüfen Signierung und Bundle-Aufbau, keiner prüft, aus welchem Verzeichnis
> gebaut wurde. Aufgeschlagen wäre er erst bei Apple, mit der Meldung, dass Build
> 7 schon existiert, und zu dem Zeitpunkt wäre die Ursache nicht mehr naheliegend
> gewesen. Gefangen hat ihn Schritt 1.6, die Sichtprüfung. Der Rest des Plans
> hätte ihn durchgelassen. Das ist der Grund, warum aus der Warnung danach ein
> Skript wurde, siehe Schritt 0.6.

| Pfad | Was es ist |
|---|---|
| `v4/AudioRouterNow4.xcodeproj` | **das richtige**, 4.0.1 (10) |
| `v4-appstore/AudioRouterNow4/AudioRouterNow4.xcodeproj` | toter Altbestand, 4.0.0 (7), seit `b42d692` untracked |

In Xcode heißen beide nur „AudioRouterNow4". Über die Liste zuletzt geöffneter
Projekte ist das falsche schneller erreichbar als das richtige. Deshalb über den
Befehl öffnen, nicht über die Liste:

```sh
open ~/AudioRouterNow/v4/AudioRouterNow4.xcodeproj
```

**Woran du den falschen Baum sofort erkennst:** Im Reiter
**Signing & Capabilities** ist dort **kein Team** eingetragen, und der General-Tab
zeigt Version 4.0.0, Build 7. Der Altbaum hat gar keine `MARKETING_VERSION`.

**Nachweis im Zweifelsfall**, nach dem Archivieren:

```sh
ARCH=$(ls -dt ~/Library/Developer/Xcode/Archives/*/*.xcarchive | head -1)
strings "$ARCH/dSYMs/"*.dSYM/Contents/Resources/DWARF/* \
  | grep -oE "/AudioRouterNow/(v4|v4-appstore)/" | sort | uniq -c
```

Es dürfen **nur** Treffer auf `/v4/` erscheinen.

*Am 01.10. zweimal angewendet. Erster Lauf: 114 Treffer auf `/v4-appstore/`, keiner
auf `/v4/`, also das falsche Archiv. Zweiter Lauf: 110 Treffer auf `/v4/`, keiner
auf `/v4-appstore/`. Der zweite Wert ist am verbliebenen Archiv nachprüfbar, das
falsche Archiv wurde verworfen.*

**1.2 ⬜ 👤 Ziel einstellen.**
Oben in der Leiste: Schema **AudioRouterNow4**, Ziel **My Mac**. Steht dort ein
Simulator oder ein Testschema, ist „Archive" ausgegraut.

**1.3 ⬜ 👤 Signierung prüfen.**
Projekt anwählen, Reiter **Signing & Capabilities**, oben von **All** auf
**Release** umschalten. Dort muss dein Team stehen und der Haken bei automatischer
Verwaltung sitzen.

⚠️ **Das stand nicht in den Projektdateien, inzwischen schon.** Geprüft am
01.10.2026: `project.pbxproj` enthielt weder `DEVELOPMENT_TEAM` noch
`CODE_SIGN_STYLE` noch `CODE_SIGN_IDENTITY`. Xcode löste beides zur Bauzeit aus
dem angemeldeten Entwicklerkonto auf. Das funktioniert, solange genau ein Team
hinterlegt ist, und hat bei 4.0.0 so funktioniert, war aber aus dem Repository
nicht prüfbar.

Mit `1a8257a` schrieb Xcode die Werte in `project.pbxproj`, als das **richtige**
Projekt geöffnet wurde. Seitdem trägt das Projekt seine Signierung selbst.

⚠️ **Der Haken bleibt bestehen:** die Werte stehen in `project.pbxproj`, **nicht**
in `v4/project.yml`. Das Projekt wird aus `project.yml` erzeugt, ein
`xcodegen`-Lauf würde sie also wieder entfernen. Die dauerhafte Lösung gehört in
`project.yml` und liegt als Rückstandspunkt in `BACKLOG.md`, bewusst nicht mitten
in einer laufenden Einreichung.

⚠️ **Deshalb vor dem Archivieren kein `xcodegen` laufen lassen.** Das Projekt wird
aus `v4/project.yml` erzeugt (`scripts/xcodegen.sh`), und eine Neugenerierung setzt
alles zurück, was in der Oberfläche eingestellt wurde.

Steht bei **Signing Certificate** „Development", ist das **kein Fehler**. Bei
automatischer Verwaltung wählt Xcode erst beim Archivieren das
Distributions-Zertifikat. Die Anzeige in dieser Ansicht ist nicht das, was im
Archiv landet.

**1.4 ⬜ 👤 Clean Build Folder.**
Menü **Product**, bei gedrückter Wahltaste wird „Clean Build Folder" sichtbar.

**1.5 ⬜ 👤 Product, dann Archive.**
Dauert einige Minuten. Danach öffnet sich der Organizer.
*Am 01.10. zweimal gelaufen. Der erste Lauf kam aus dem falschen Baum, der zweite war
korrekt.*

**1.6 ⬜ 👤 Im Organizer prüfen: steht dort 4.0.1 (10)?**
⚠️ Wenn dort Build 9 steht, hat Xcode aus einem alten Zwischenstand gebaut.
Dann Schritt 1.4 und 1.5 wiederholen.
*Am 01.10. hat dieser Schritt den Fehler gefangen. Im Organizer stand nach dem ersten
Lauf 4.0.0 (7), nicht 4.0.1 (9). Nach dem zweiten Lauf stand dort 4.0.1 (9). Fuer
Build 10 muss hier 4.0.1 (10) stehen.*

---

## Phase 2: Validieren ⬜ offen

> **Historisches Protokoll: Build 9.** Die kursive Notiz unten beschreibt die
> Validierung vom 01.10.2026 am Build-9-Archiv. Fuer Build 10 laeuft diese Phase neu.

**2.1 ⬜ 👤 Im Organizer: Validate App.**
Das ist eine Prüfung durch Apple, **ohne** einzureichen. Sie findet Fehler in
Signierung, Berechtigungen und Bundle-Aufbau, bevor irgendetwas verbindlich wird.

**2.2 ⬜ 👤 Durchklicken bis „Validation successful".**
Bei Fehlern: Meldung vollständig kopieren und mir geben, statt zu raten.
*Erledigt 01.10.2026 am Build-9-Archiv, „Validation successful", keine Warnungen.*

> Festzuhalten, weil es die Grenze dieser Prüfung zeigt: die Validierung hätte
> auch das **falsche** Archiv bestanden. Sie prüft, ob das Bundle korrekt gebaut
> und signiert ist, nicht ob es die Version enthält, die man einreichen wollte.

---

## Phase 3: Hochladen ⬜ offen

> **Historisches Protokoll: Build 9.** Die kursiven Notizen unten beschreiben den
> Upload vom 01.10.2026, der Build 9 zu Apple brachte. Build 9 wurde nie eingereicht
> und ist durch Build 10 ueberholt. Fuer Build 10 laeuft diese Phase neu.

**3.1 ⬜ 👤 Im Organizer: Distribute App, dann App Store Connect, dann Upload.**
*Erledigt 01.10.2026, Upload von Build 9 erfolgreich um 17:26.*

**3.2 ⬜ 👤 Warten.**
Der Build durchläuft bei Apple eine Verarbeitung, üblicherweise wenige Minuten bis
etwa eine Stunde. Du bekommst eine Mail. Vorher lässt sich der Build in App Store
Connect nicht auswählen.
*Keine Mail mit Beanstandungen eingegangen. Build 9 liegt bei Apple, wird aber nicht
eingereicht.*

> **Ab hier ist der Build hochgeladen, aber nicht eingereicht.** Das ist kein
> Zwischenstand auf dem Weg zur Review, sondern ein eigener Zustand: Apple hat den
> Build, App Review hat ihn nicht. Es läuft keine Uhr, es wartet niemand auf eine
> Antwort, und nichts davon ist nach außen sichtbar.

⚠️ Kommt eine Mail mit einem Hinweis auf fehlende Berechtigungen oder ein
ungültiges Bundle, ist der Build **nicht** verwendbar, auch wenn der Upload
erfolgreich aussah.

---

## Phase 4: Angaben in App Store Connect ⬜ offen

> Diese Phase ist noch nicht angefasst. Es ist keine Version 4.0.1 angelegt. Der
> am 01.10. hochgeladene Build 9 ist zwar auswählbar, wird aber nicht eingereicht:
> Build 10 muss erst archiviert und hochgeladen werden.

**4.1 ⬜ 👤 Neue Version anlegen.**
App Store Connect, App auswählen, links **App Store**, dann
**macOS App, Version hinzufügen**. Als Versionsnummer **4.0.1** eintragen.

**4.2 ⬜ 👤 „Was ist neu in dieser Version" einfügen.**
Der fertige Text liegt in `docs/marketing/appstore-whatsnew-4.0.1.md`, im
Codeblock. **ca. 2184 Zeichen** von 4000 erlaubten. Nur Englisch, die App hat keine
weiteren Sprachen.

*Zuvor stand hier 1747. Der Text wurde fuer Build 10 ergänzt: CASE-007 und CASE-008
sind nun enthalten. Zuvor war er in Phase 5.1 von 1635 auf 1747 gewachsen, weil der
Datenschutzsatz drei übermittelte Angaben nannte, die App aber fünf sendet. Begründung
siehe [08-submission-log.md](08-submission-log.md).*

**4.3 ⬜ 👤 Build auswählen.**
Unter **Build** das Pluszeichen, dann **4.0.1 (10)**.
⚠️ Steht dort noch nichts, ist die Verarbeitung aus Phase 3 nicht fertig.
*Phase 3 laeuft fuer Build 10 noch. Der am 01.10. hochgeladene Build 9 ist zwar
auswählbar, wird aber nicht eingereicht.*

**4.4 ⬜ 👤 Screenshots: nichts tun.**
Die Oberfläche hat sich gegenüber 4.0.0 nicht geändert. Die vorhandenen
Screenshots bleiben gültig und werden automatisch übernommen.

**4.5 ⬜ 👤 Export Compliance.**
Sollte **nicht** gefragt werden, weil `ITSAppUsesNonExemptEncryption` in der
`Info.plist` bereits auf `false` steht. Falls doch gefragt wird: die App verwendet
keine eigene Verschlüsselung.

**4.6 ⬜ 👤 Review-Notiz schreiben.**
Text siehe unten, Abschnitt „Vorlage für die Review-Notiz". Der wichtigste Teil
ist der Hinweis auf die Berechtigung zur Audioaufnahme. Ohne sie sieht der Prüfer
eine App, die nichts tut.

**4.7 ⬜ 👤 Veröffentlichung wählen.**
Empfehlung: **manuell freigeben**. Dann liegt zwischen Freigabe durch Apple und
Sichtbarkeit im Store ein Moment, in dem du die Kommunikation vorbereiten kannst.
Bei 4.0.0 war das hilfreich.

---

## Phase 5: Prüfung vor dem Absenden

Diese Phase ist der Grund für die ganze Reihenfolge. **Erst wenn alles hier
stimmt, wird Phase 6 angefasst.**

**5.1 ⬜ 🤖 Ich prüfe gegen den Code**, was sich automatisch prüfen lässt:
Versionsnummern, dass der Arbeitsbaum dem entspricht, was gebaut wurde, und dass
im Store-Text nichts steht, was die App nicht tut. **Fuer Build 10 neu, weil der
Store-Text jetzt CASE-007 und CASE-008 beschreibt.**

*Am 01./02.10.2026 fuer Build 9 gelaufen. Jede nachprüfbare Aussage des Store-Textes
wurde gegen den Quellcode gehalten, sechs Aussagen bestätigt, **ein Befund**: der
Datenschutzsatz nannte drei übermittelte Angaben, `openBugReport()` sendet fünf.
Korrigiert durch Ergänzen, nicht Kürzen. Belegtabelle und Begründung in
[08-submission-log.md](08-submission-log.md). Fuer Build 10 sind zusaetzlich die
neuen Aussagen zu CASE-007 (Settle-Freeze) und CASE-008 (Exklusiv-Modus) zu pruefen.*

**5.2 ⬜ 👤 Du prüfst in App Store Connect**, und zwar jede Zeile einzeln:

- [ ] Version steht auf 4.0.1
- [ ] Build steht auf 10, nicht 9
- [ ] „Was ist neu" ist vollständig eingefügt, auch der Abschnitt zu „Launch at Login"
- [ ] Review-Notiz ist eingetragen
- [ ] Support-URL zeigt auf `audiorouternow.mauriciomorkun.com/support/`
- [ ] Die beiden Trinkgeld-Produkte sind weiterhin aktiv

**5.3 ⚠️ Das Risiko aus der Vergangenheit: Richtlinie 2.4.5(iii).**

Build 3 wurde abgelehnt, weil eine alte Login-Item-Registrierung ein Update
überlebte und die App auf dem Rechner des Prüfers automatisch startete.
Registrierungen hängen an der Bundle-ID, nicht am Programm, und überdauern
Updates.

Der eingebaute Schutz: die Zustimmung hängt an
`launchAtLoginConsentBuildKey`, also an der **Build-Nummer**. Bei Build 10 ist jede
frühere Zustimmung ungültig, und `ensureLoginItemCompliance()` läuft als Erstes
beim Start und entfernt Reste.

Daraus folgt für die Review-Notiz: **der Hinweis muss drinstehen**, dass die
Einstellung nach dem Update bewusst zurückgesetzt wird. Sonst könnte der Prüfer
das als Fehler auslegen.

---

## Phase 6: Absenden ⬜ offen

**6.1 ⬜ 👤 „Add for Review", dann „Submit to App Review".**

Ab hier ist nichts mehr änderbar, ohne die Einreichung zurückzuziehen.

**Dieser Schritt ist nicht erfolgt.** Der Upload vom 01.10. ist nicht dieser
Schritt und ersetzt ihn nicht.

**6.2 ⬜ 👤 Status notieren.**
Er wechselt auf „Waiting for Review".

---

## Phase 7: Danach ⬜ offen

**7.1 ⬜ 🤖 Tag setzen und pushen.**
Erst jetzt, weil der eingereichte Stand nun feststeht.

⚠️ **Dabei fällt eine Altlast an.** Für v4 existiert **kein einziger Tag**, Stand
03.10.2026 unverändert. Getaggt sind nur `v3.4.0` bis `v3.4.6`. Der Stand, der im
App Store liegt, ist nirgends markiert. Deshalb war `v4-appstore/` faktisch das
einzige greifbare Abbild der ausgelieferten Version, und genau dieser Ordner hat
am 01.10. das falsche Archiv erzeugt.

In dieser Reihenfolge nachholen:

1. `v4.0.0` nachtaggen auf **`6e32199`**, dem letzten Commit vor dem Archivlauf
   vom 13.08.2026. Geprüft: dort steht `MARKETING_VERSION = 4.0.0`,
   `CURRENT_PROJECT_VERSION = 7`.
2. `v4.0.1` auf den eingereichten Stand.
3. **Erst dann** `v4-appstore/` entfernen, 594 MB. Umbenennen ist die umkehrbare
   Variante.

Der Ordner wird erst entbehrlich, wenn der Tag seine Aufgabe übernommen hat.

Vollständig in
`~/.claude/projects/-Users-mauriciomorkun/memory/project_audiorouternow_v4_tags_pending.md`.

**7.2 ⬜ 🤖 Dokumentation nachziehen.**
In `CHANGELOG.md`, `RELEASE_NOTES.md` und `docs/v4.0.1/README.md` steht derzeit
überall „uploaded, not submitted", mit dem Datum des Uploads. Das wird auf
„in Review" geändert, mit Datum.

**7.3 ⬜ 👤 Warten.**
Erfahrungswert aus 4.0.0: ein bis drei Tage.

**7.4 ⬜ Bei Freigabe:**
- 🤖 Dokumentation auf „veröffentlicht" setzen
- 👤 Freigabe in App Store Connect auslösen (bei manueller Veröffentlichung)
- 🤖 Antwort an den Melder von CASE-004 auf MacRumors, der Text liegt bereit und
  sagt bisher „not submitted yet"
- 🤖 Antwort an den Melder des Sample-Rate-Nebenbefunds auf X, falls noch nicht
  gepostet
- 🤖 `feedback/CASE-003` und `CASE-004` auf ausgeliefert setzen

**7.5 ⬜ Bei Ablehnung:**
Meldung vollständig kopieren, nichts raten. Bei 2.4.5(iii) war der genannte Grund
nicht die tatsächliche Ursache, das hat damals einen Anlauf gekostet.

---

## Vorlage für die Review-Notiz

```
This update fixes four defects and adds two features.

1. A crash in the animated waveform of the menu bar panel.
2. The system volume was applied twice on the default output device, making
   routed audio quieter than expected on that one device.
3. A brief volume jump when plugging in headphones or switching the main output.
   The app now waits for the device transition to settle before adopting the
   new device's volume level.
4. The built-in speakers played audio even when only an external device was
   selected. A new exclusive routing mode (footer toggle) lets you route to
   selected devices only.

To test routing you need to allow audio recording when macOS asks. The app uses
the Process Tap API to read system audio. Nothing is recorded or stored, the
audio is passed straight to the selected output devices. Without this permission
the app will appear to do nothing.

Steps:
1. Open the app from the menu bar icon.
2. Allow audio recording when prompted.
3. Select one or more output devices.
4. Play any audio. It should come out of all selected devices.

Note on Launch at Login: this update deliberately resets that setting. The
consent is tied to the exact build number it was granted for, so that an app
update can never silently keep launching the app. This is the fix for the
guideline 2.4.5(iii) issue from an earlier submission, working as intended.

Contact: dev@mauriciomorkun.com
```

---

## Was in diesem Update NICHT passiert

Festgehalten, damit es nicht versehentlich mitgeht:

- **Kein Fix am Sample-Rate-Listener.** Der Befund vom 29.09. steht im Rückstand,
  ausdrücklich nicht in diesem Release. Begründung dort: die Fehlerrichtung würde
  sich ins Gefährlichere umkehren.
- **AirPlay-Überarbeitung und Solo-Schalter** bleiben auf 4.1.
- **Keine Screenshots.** Die Oberfläche ist unverändert.
