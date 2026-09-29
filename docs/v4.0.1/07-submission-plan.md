# Ablaufplan: 4.0.1 bei App Review einreichen

> Dieses Dokument ist bewusst auf Deutsch, anders als der Rest des Ordners. Die
> übrigen Dokumente sind Berichte für Leser, dieses ist eine Arbeitsliste zum
> gemeinsamen Abhaken.

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

---

## Phase 0: Ausgangslage sichern

**0.1 🤖 Arbeitsbaum sauber und alles gepusht.**
Nichts darf uncommitted sein. Was nicht im Repository steht, lässt sich später
nicht dem eingereichten Build zuordnen.

**0.2 🤖 Version und Build bestätigen.**
`v4/Configs/AudioRouterNow4.xcconfig` muss `MARKETING_VERSION = 4.0.1` und
`CURRENT_PROJECT_VERSION = 9` enthalten. Das ist die einzige Quelle, `project.yml`
verweist nur darauf.

**0.3 🤖 Tests laufen lassen.**
`./v4/scripts/test.sh`, erwartet werden 59 swift-testing und 23 XCTest, alle grün.

**0.4 🤖 Release-Build lokal.**
Muss ohne Fehler durchlaufen, bevor Xcode überhaupt geöffnet wird.

**0.5 👤 Andere Instanzen beenden.**
`ARN-build9-NACHHER.app` vom Schreibtisch und die App Store Version 4.0.0 dürfen
beim Archivieren nicht laufen. Sie greifen auf dieselben Audiogeräte zu.

**Noch keinen Tag setzen.** Ein Tag sagt „das ist die Version". Solange die
Validierung nicht durch ist, kann sich der Stand noch ändern. Der Tag kommt in
Phase 7.

---

## Phase 1: Archiv erstellen

**1.1 👤 Xcode öffnen.**
`v4/AudioRouterNow4.xcodeproj`. Nicht die Paketdatei, sondern das Projekt.

**1.2 👤 Ziel einstellen.**
Oben in der Leiste: Schema **AudioRouterNow4**, Ziel **My Mac**. Steht dort ein
Simulator oder ein Testschema, ist „Archive" ausgegraut.

**1.3 👤 Signierung prüfen.**
Projekt anwählen, Reiter **Signing & Capabilities**, Konfiguration **Release**.
Dort muss dein Team stehen und der Haken bei automatischer Verwaltung sitzen.
⚠️ Das steht **nicht** in den Projektdateien, es kommt aus deinem Xcode. Deshalb
ist es hier ein eigener Schritt und keine Nebensache.

**1.4 👤 Clean Build Folder.**
Menü **Product**, bei gedrückter Wahltaste wird „Clean Build Folder" sichtbar.

**1.5 👤 Product, dann Archive.**
Dauert einige Minuten. Danach öffnet sich der Organizer.

**1.6 👤 Im Organizer prüfen: steht dort 4.0.1 (9)?**
⚠️ Wenn dort Build 8 steht, hat Xcode aus einem alten Zwischenstand gebaut.
Dann Schritt 1.4 und 1.5 wiederholen.

---

## Phase 2: Validieren

**2.1 👤 Im Organizer: Validate App.**
Das ist eine Prüfung durch Apple, **ohne** einzureichen. Sie findet Fehler in
Signierung, Berechtigungen und Bundle-Aufbau, bevor irgendetwas verbindlich wird.

**2.2 👤 Durchklicken bis „Validation successful".**
Bei Fehlern: Meldung vollständig kopieren und mir geben, statt zu raten.

---

## Phase 3: Hochladen

**3.1 👤 Im Organizer: Distribute App, dann App Store Connect, dann Upload.**

**3.2 👤 Warten.**
Der Build durchläuft bei Apple eine Verarbeitung, üblicherweise wenige Minuten bis
etwa eine Stunde. Du bekommst eine Mail. Vorher lässt sich der Build in App Store
Connect nicht auswählen.

⚠️ Kommt eine Mail mit einem Hinweis auf fehlende Berechtigungen oder ein
ungültiges Bundle, ist der Build **nicht** verwendbar, auch wenn der Upload
erfolgreich aussah.

---

## Phase 4: Angaben in App Store Connect

**4.1 👤 Neue Version anlegen.**
App Store Connect, App auswählen, links **App Store**, dann
**macOS App, Version hinzufügen**. Als Versionsnummer **4.0.1** eintragen.

**4.2 👤 „Was ist neu in dieser Version" einfügen.**
Der fertige Text liegt in `docs/marketing/appstore-whatsnew-4.0.1.md`, im
Codeblock. 1635 Zeichen von 4000 erlaubten. Nur Englisch, die App hat keine
weiteren Sprachen.

**4.3 👤 Build auswählen.**
Unter **Build** das Pluszeichen, dann **4.0.1 (9)**.
⚠️ Steht dort noch nichts, ist die Verarbeitung aus Phase 3 nicht fertig.

**4.4 👤 Screenshots: nichts tun.**
Die Oberfläche hat sich gegenüber 4.0.0 nicht geändert. Die vorhandenen
Screenshots bleiben gültig und werden automatisch übernommen.

**4.5 👤 Export Compliance.**
Sollte **nicht** gefragt werden, weil `ITSAppUsesNonExemptEncryption` in der
`Info.plist` bereits auf `false` steht. Falls doch gefragt wird: die App verwendet
keine eigene Verschlüsselung.

**4.6 👤 Review-Notiz schreiben.**
Text siehe unten, Abschnitt „Vorlage für die Review-Notiz". Der wichtigste Teil
ist der Hinweis auf die Berechtigung zur Audioaufnahme. Ohne sie sieht der Prüfer
eine App, die nichts tut.

**4.7 👤 Veröffentlichung wählen.**
Empfehlung: **manuell freigeben**. Dann liegt zwischen Freigabe durch Apple und
Sichtbarkeit im Store ein Moment, in dem du die Kommunikation vorbereiten kannst.
Bei 4.0.0 war das hilfreich.

---

## Phase 5: Prüfung vor dem Absenden

Diese Phase ist der Grund für die ganze Reihenfolge. **Erst wenn alles hier
stimmt, wird Phase 6 angefasst.**

**5.1 🤖 Ich prüfe gegen den Code**, was sich automatisch prüfen lässt:
Versionsnummern, dass der Arbeitsbaum dem entspricht, was gebaut wurde, und dass
im Store-Text nichts steht, was die App nicht tut.

**5.2 👤 Du prüfst in App Store Connect**, und zwar jede Zeile einzeln:

- [ ] Version steht auf 4.0.1
- [ ] Build steht auf 9, nicht 8
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
`launchAtLoginConsentBuildKey`, also an der **Build-Nummer**. Bei Build 9 ist jede
frühere Zustimmung ungültig, und `ensureLoginItemCompliance()` läuft als Erstes
beim Start und entfernt Reste.

Daraus folgt für die Review-Notiz: **der Hinweis muss drinstehen**, dass die
Einstellung nach dem Update bewusst zurückgesetzt wird. Sonst könnte der Prüfer
das als Fehler auslegen.

---

## Phase 6: Absenden

**6.1 👤 „Add for Review", dann „Submit to App Review".**

Ab hier ist nichts mehr änderbar, ohne die Einreichung zurückzuziehen.

**6.2 👤 Status notieren.**
Er wechselt auf „Waiting for Review".

---

## Phase 7: Danach

**7.1 🤖 Tag setzen und pushen.**
Erst jetzt, weil der eingereichte Stand nun feststeht.

**7.2 🤖 Dokumentation nachziehen.**
In `CHANGELOG.md`, `RELEASE_NOTES.md` und `docs/v4.0.1/README.md` steht derzeit
überall „prepared, not yet submitted". Das wird auf „in Review" geändert, mit
Datum.

**7.3 👤 Warten.**
Erfahrungswert aus 4.0.0: ein bis drei Tage.

**7.4 Bei Freigabe:**
- 🤖 Dokumentation auf „veröffentlicht" setzen
- 👤 Freigabe in App Store Connect auslösen (bei manueller Veröffentlichung)
- 🤖 Antwort an `bogdanw` auf MacRumors, der Text liegt bereit und sagt bisher
  „not submitted yet"
- 🤖 Antwort an `luisrocklu` auf X, falls noch nicht gepostet
- 🤖 `feedback/CASE-003` und `CASE-004` auf ausgeliefert setzen

**7.5 Bei Ablehnung:**
Meldung vollständig kopieren, nichts raten. Bei 2.4.5(iii) war der genannte Grund
nicht die tatsächliche Ursache, das hat damals einen Anlauf gekostet.

---

## Vorlage für die Review-Notiz

```
This update fixes two defects and adds a bug report button.

1. A crash in the animated waveform of the menu bar panel.
2. The system volume was applied twice on the default output device, making
   routed audio quieter than it should be on that one device.

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
- **Keine neuen Funktionen.** AirPlay-Überarbeitung und Solo-Schalter bleiben auf
  4.1.
- **Keine Screenshots.** Die Oberfläche ist unverändert.
