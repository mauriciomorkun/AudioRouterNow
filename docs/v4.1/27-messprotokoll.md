# AudioRouterNow 4.1: Messprotokoll der Sitzung am Gerät

> **Messsitzung durchgeführt (21. bis 23.11.2026). Ergebnisse eingetragen, Stand 23.11.2026.**
> Zusammenfassung in Abschnitt 7, Einordnung im Abschlussbericht `09-final-report.md`, Abschnitt 12.
> Die Tabelle in Abschnitt 3 und die Anleitungen in Abschnitt 4 stehen unverändert als Planungsstand,
> nur die Spalten "Ergebnis" und "Notiz" wurden ausgefüllt.
> Alle Angaben unten sind aus den vorhandenen Dokumenten abgeleitet
> (`09-final-report.md` Abschnitt 7 und Nachtrag, `26-release-plan.md` 4(e),
> `14-plan-nachtrag.md` Abschnitt 7, `25-add-device-liste.md`, die
> Test-App-Anleitung auf dem Desktop). Nichts erfunden. Wo eine Quelle etwas
> nicht hergibt, steht das ausdruecklich.

## 1. Kopf

| Feld | Wert |
|------|------|
| Zweck | Die Messpunkte M1 bis M9, M2b/M2c/M2d und NM-1 bis NM-7 am Gerät durchgehen und die Ergebnisse eintragen. Vorrang vor der Einreichung. |
| Datum der Sitzung | 21. bis 23.11.2026 (ursprünglich für den 19.11. vorgesehen; M6 brauchte lange Laufzeiten, die BlackHole-Nachmessung folgte am 23.11.) |
| Teilnehmer | Nutzer (misst am Gerät), Claude (führt Punkt für Punkt durch, trägt Ergebnisse ein) |
| Getestete App | "AudioRouterNow 4.1 TEST C3b.app" (Desktop), Bundle-ID `com.mauriciomorkun.audiorouternow.test`, Info.plist 4.1 (11) |
| Commit des Codes (HEAD) | `c393e6d` (`release/4.1`, 74 Commits vor `main`, nicht gepusht, kein Tag). Seit `47a727b` kam nur ein Doku-Commit hinzu, kein App-Code |
| macOS des Geräts | 26.6.2 (Build 25G83) |
| Hardware | MacBook Pro, Apple M1 (Seriennummer bewusst nicht erfasst) |
| Vorhandene Ausgänge | BenQ PD2700U (HDMI, 2), Komplete Audio 6 MK2 (USB, 6), Kopfhörerausgang (2), MacBook-Lautsprecher (2), NI Audio 4 DJ (virtuell, 4): 8 Kanalpaare. Für die Großlisten-Punkte am 23.11. vorübergehend BlackHole 16ch und 64ch (Homebrew, 0.7.1), danach entfernt: 48 Zeilen |

### Stand der Test-App C3b gegenüber HEAD (belegt, 18.11.2026)

- App-Binary mtime: 2026-11-17 05:02:47. Neueste Swift-Quelle (git-Arbeitsbaum):
  `AddDeviceMenuModel.swift` 2026-11-17 04:58:32, alle Swift-Quellen älter als die
  App. Das stützt: die App wurde **nach** der letzten Swift-Änderung gebaut.
- Die App-Anleitung (`ARN-4.1-TEST-LIES-MICH.txt`) nennt als Herkunft HEAD
  `e76ad3d` **plus noch nicht committete Arbeitsbaum-Änderungen**. Der heutige HEAD
  ist `47a727b`; der damals uncommittete C3/V2-Code ist inzwischen committet
  (`1a5a959`, `730b8cf`, `30c4d5e`, `01125b5`, `27dcd0e`, `4942a34`, plus die zwei
  Commits vom 18.11. am Signier-/Doku-Stand, die keinen App-Code berühren).
- **Befund:** Der Code der Test-App stimmt nach Versionsangabe (4.1/11) und
  Datumsvergleich mit dem Stand von HEAD überein. Eine **byteweise Gleichheit ist
  nicht prüfbar** (die App wurde aus einem anderen Commit plus Arbeitsbaum gebaut,
  nicht reproduzierbar signiert). Teststand der App laut Anleitung: 60 swift-testing
  plus 129 XCTest grün (112 aus C3 plus 17 neue AddDeviceMenuModel-Fälle). Falls
  während der Sitzung Zweifel bestehen, ob die App exakt dem HEAD entspricht, aus
  dem aktuellen HEAD neu bauen.

## 2. Vorbereitungs-Checkliste für die Sitzung (abhakbar)

- [ ] Produktive 4.0.1 beenden: `/Applications/AudioRouterNow4.app` (Menüleisten-Symbol beenden oder im Aktivitätsmonitor "AudioRouterNow4").
- [ ] Alle anderen Test-Apps beenden: TEST, TEST (neu), TEST C2, TEST C3, TEST C3 LISTE. Alle teilen dieselbe Test-Bundle-ID, es darf nur eine laufen.
- [ ] Prüfen, dass keine Instanz mehr läuft: `pgrep -fl AudioRouterNow` muss leer sein.
- [ ] Nur "AudioRouterNow 4.1 TEST C3b.app" starten (bei Gatekeeper-Warnung Rechtsklick > Öffnen; ad-hoc signiert, nicht notarisiert).
- [ ] Beim ersten echten Routing die Audio-Berechtigung (System Audio Recording) erteilen. Eigene Berechtigung der Test-Bundle-ID, getrennt von der produktiven App.
- [ ] Angeschlossene Audiogeräte bereitlegen (aus den Prüfleitfäden abgeleitet):
  - BlackHole 64ch (virtuelles Gerät, 32 Kanalpaare) für M1, M5, NM-1 bis NM-7.
  - Ein Interface mit vielen Kanälen, z.B. Scarlett 18i20, für M1/M5 (45+ Zeilen).
  - Komplete Audio 6 MK2 (umschaltbare Sample-Rate) für M7 und als Mehrkanalgerät für M2d.
  - MacBook-Lautsprecher und externe Kopfhörer als zwei einfache Ausgaben für M3, M4, M9.
  - Ein USB-Gerät zum kurzen Aus- und Einstecken für M8.
  - Bluetooth-Gerät nur, falls bei M3/M4 ein zweiter Ausgang gewünscht ist (von den Leitfäden nicht zwingend verlangt).
- [ ] Werkzeuge bereit: Konsole.app (für `log stream`, M6), Aktivitätsanzeige (NM-4, NM-7), Audio-MIDI-Setup (M7), Maus **und** Trackpad (M2c), VoiceOver (M2b), ggf. Bildschirmaufnahme-Rechte (falls Screenshots).
- [ ] M5/NM-6 benötigen ein lokales Experiment im Code (`OutputLimits.maxSlots` temporär auf 20 senken, nicht committen, bauen, danach zurücksetzen). Xcode bereithalten.
- [ ] Ruhe schaffen (kein Telefonat, keine Unterbrechung, da Hörprüfungen mit Musik laufen).
- [ ] Geschätzte Gesamtzeit: rund **2,5 bis 3,5 Stunden** (M6 läuft 15 Minuten nebenher). Quelle: `26-release-plan.md` 4(e).

## 3. Reihenfolge und Zeitplan

Reihenfolge nach Priorität und Dauer wie in `26-release-plan.md` 4(e), ergänzt um
die Prüfzeilen M2b/M2c/M2d und die Zusatzzeilen (Hover-Sprechblasen, VoiceOver,
Tab-Fokus, Umbruch bei großer Schrift, Start ohne Absturz).

Spalten: Nr. · Messpunkt · Was wird geprüft · Dauer · Hardware · bereits gesehen · Ergebnis · Notiz.
Dauerangaben ohne Quelle sind als "(Schätzung)" markiert.

| Nr. | Messpunkt | Was wird geprüft | Dauer | Hardware | Bereits gesehen | Ergebnis | Notiz |
|-----|-----------|------------------|-------|----------|-----------------|----------|-------|
| 1 | M1 | ScrollView ab 45+ Zeilen, oberer Knopf und Footer immer sichtbar, Panel passt auf 13" | ~10 min | BlackHole 64ch + Interface | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | Nutzer am Gerät bestätigt, 21.11.2026 ("wie sie sollen"). Keine Einzelwerte genannt (Panelhöhe, Scroll-Indikator nicht erfasst). **Einschränkung (Gerätebestand geprüft 23.11.2026):** Der Mac hat kein BlackHole. Ausgänge laut `system_profiler`: BenQ PD2700U (HDMI, 2 Kanäle), Komplete Audio 6 MK2 (6), External Headphones (2), MacBook Pro Speakers (2), NI Audio 4 DJ (virtuell, 4), das sind höchstens 8 Zeilen (Kanalpaare). Die Bedingung "45+ Zeilen" der Anleitung war damit nicht erreichbar; die Zeilenzahl bei M1 ist nicht erfasst. M1 gilt für höchstens 8 Zeilen. **Nachmessung 23.11.2026 mit 48 Zeilen** (BlackHole 16ch und 64ch per Homebrew vorübergehend installiert, Konfiguration der Test-App vorbefüllt, Routing aus): Nutzer bestätigt: 48 Zeilen sichtbar, Liste scrollt (Rad und Trackpad), Start-Routing-Knopf oben und Footer bleiben sichtbar, Panel passt auf den Bildschirm. Bildschirmgröße nicht erfasst; die 13"-Prüfung ist damit nicht belegt. Routing aktiv bei 48 Zeilen: siehe M5, NM-1, NM-4, NM-5 (Hörprüfung und Messung liefen mit 48 Zeilen und aktivem Routing, ohne Auffälligkeit). |
| 2 | M2 | Oberer Start/Stop-Knopf schaltet in allen Zuständen korrekt, kein Doppelstart | ~5 min | 1 Gerät | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | Nutzer am Gerät bestätigt, 21.11.2026. |
| 3 | M2b | Knopfoptik oben und Footer, VoiceOver liest "Start/Stop Routing" | ~10 min | 1 Gerät, VoiceOver | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | Nutzer am Gerät bestätigt, 21.11.2026. Ob VoiceOver dabei benutzt wurde, nicht ausdrücklich gesagt. |
| 4 | Zusatz: Start ohne Absturz | App startet crashfrei (Start-Smoke-Test der C3b-App wurde laut Anleitung nie gemacht) | ~2 min (Schätzung) | 1 Gerät | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | Abgeleitet, 23.11.2026: Die App C3b startete in der Sitzung mehrfach (auch nach Beenden und Neustart mit vorbefüllter Konfiguration) und lief über Tage durchgehend. Kein Nutzerurteil, sondern Beobachtung aus Prozessliste und Log. |
| 5 | M2c | Hover-Erklärungen im Footer, Clamping an beiden Rändern, Maus und Trackpad | ~10 min | Maus + Trackpad | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | Nutzer am Gerät bestätigt, 21.11.2026. |
| 6 | Zusatz: VoiceOver-Hint je Footer-Symbol | VoiceOver liest zu jedem Footer-Symbol den Erklärtext (accessibilityHint) | ~5 min (Schätzung) | VoiceOver | nein | [ ] ok  [ ] negativ  [ ] nicht pruefbar | **Nicht geprüft (Stand 23.11.2026), offen.** |
| 7 | Zusatz: Tab-Fokus | Tab-Fokus-Reihenfolge im Panel sinnvoll | ~5 min (Schätzung) | Tastatur | nein | [ ] ok  [ ] negativ  [ ] nicht pruefbar | **Nicht geprüft (Stand 23.11.2026), offen.** |
| 8 | Zusatz: Umbruch bei großer Schrift | "Launch at Login", Support, Quit bleiben einzeilig bei großer Dynamic Type / Bedienungshilfen | ~5 min (Schätzung) | Systemeinstellungen | nein | [ ] ok  [ ] negativ  [ ] nicht pruefbar | **Nicht geprüft (Stand 23.11.2026), offen.** |
| 9 | M2d | Add-device scrollbar und bereits hinzugefügte Einträge gekennzeichnet (Haken, ausgegraut) | ~10 min | Mehrkanalgerät (z.B. KA6) | teilweise (Scrollbarkeit per Prüfhilfe "TEST C3 LISTE" und V2-Kennzeichnung in C3b am 17.11. vom Nutzer bestätigt; echtes SwiftUI-Menü noch offen) | [x] ok  [ ] negativ  [ ] nicht pruefbar | Nutzer am Gerät bestätigt, 21.11.2026 ("wie sie sollen"), damit auch im echten Menü. |
| 10 | M9 | Peak-Meter unter Solo zeigen 0, Welle bleibt unter Solo gleich hoch | ~5 min | 2 Ausgaben | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | 22.11.2026, Screenshot des Nutzers (Komplete Audio 6 MK2, Ch1-2 solo, Ch3-4 abgedunkelt): Meter der stummen Karte zeigen -∞ (L und R), die Solo-Karte zeigt -33/-34 dB. Das belegt den Meter-Teil. Die Wellenhöhe ist auf einem Einzelbild nicht vergleichbar; dazu Aussage des Nutzers "scheint alles zu funktionieren". |
| 11 | M3 | Solo ohne Knacksen, kein Pegelsprung, gespeicherter Reglerwert gilt wieder | ~10 min | 2+ Ausgaben, Musik | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | 22.11.2026, Nutzer: kein Knacksen und kein Sprung aufgefallen (Hörprüfung, Komplete Audio 6 MK2, Ch1-2 und Ch3-4). Nicht ausdrücklich bestätigt: ob der Reglerwert des stummen Ausgangs nach dem Aufheben von Solo gilt. Beruht auf der Annahme E5 (vorhandene Rampe genügt). |
| 12 | M4 | Solo bei abgestecktem Gerät, andere bleiben stumm | ~5 min | 2 Ausgaben | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | 22.11.2026, Nutzer: "funktioniert". Welches Gerät entfernt wurde (abgesteckt oder Karte entfernt), nicht erfasst. |
| 13 | M7 | Warm-Restart bei echtem Rate-Wechsel (48 auf 44,1 kHz) in 1 bis 3 s | ~10 min | Interface mit umschaltbarer Rate (z.B. KA6) | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | 22.11.2026, Nutzer: reagiert wie erwartet bei beiden Wechseln (44,1 auf 48 kHz und zurück, Komplete Audio 6 MK2). Dauer des Neustarts nicht gemessen; Log-Befund (rückwirkend, 22.11.2026 20:34): 20:17:59 "M4: Sample rate changed on routed device, warm restart" (der Neustart wurde ausgelöst), 20:18:15 genau ein "M4-Noop" (rate=44100, total_noops=1), 16 s nach dem Wechsel. Die Erwartung "kein M4-Noop im Log" ist damit für diesen Wechsel nicht erfüllt (ein einzelner Folgeping nach dem Neustart, kein Dauerfeuer). Nicht erfasst: ob dieser Eintrag zum Wechsel auf 48 oder zurück auf 44,1 kHz gehört. |
| 14 | M8 | Blip-Absorption, Kabel unter 2 s lösen und einstecken. **Negativ: Commit `5798a63` umkehren** | ~10 min | USB-Gerät | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | **Abschluss 23.11.2026, 06:16: Blip-Absorption belegt.** Wiederholung mit schnellem Abziehen und Einstecken der Komplete Audio 6 MK2 (Test-App C3b, Routing aktiv, 3 Geräte), dreimal. Log (`log show`, Info und Debug) je Versuch: "Geroutetes Gerät verschwunden, Restart (debounced 3s)", danach "L1: Blip erkannt (1 UIDs zurueck, Settle-Restart verworfen)" nach 1,20 s (06:15:58.284 bis 06:15:59.486), 2,03 s (06:16:02.633 bis 06:16:04.666) und 1,55 s (06:16:08.263 bis 06:16:09.814). In allen drei Versuchen kein "restartRouting", also kein Engine-Neustart. Der Rückfall (Commit `5798a63` umkehren) ist nicht nötig. Nicht erfasst: ob die Musik hörbar pausierte (Nutzer nannte nur "dreimal gemacht"), und kein Vergleich mit 4.0.1 (Erwartung "kürzer oder keine Unterbrechung als bei 4.0.1" daher nur für den Engine-Neustart belegt, nicht für die hörbare Pause). Die Abstände zwischen den Versuchen betrugen nur 3,6 bis 4,3 s statt der angeforderten 15 s; das Log trennt sie trotzdem eindeutig. Die frühere Wiederanmeldezeit von etwa 3,1 s (siehe unten) liegt knapp über der 3-s-Frist: **ein langsameres Wiedereinstecken (über 3 s) führt weiter zum regulären Neustart.** Frühere Versuche (22.11.): **Teilbefund, Blip-Absorption nicht belegt (Korrektur 22.11.2026, 20:34 nach Log-Auswertung).** Das Log zeigt für beide Versuche (20:23:46 und 20:24:40) "Geroutetes Gerät verschwunden, Restart (debounced 3s)", dann je zwei "restartRouting" (nach 3 s und nach weiteren 2 s) und **kein** "L1: Blip erkannt". Das Gerät war also länger als die 3-s-Frist weg (oder kam erst danach zurück), der Neustart lief regulär. Die Blip-Absorption wurde damit nicht ausgelöst. Belegt ist nur die Wiederherstellung (Audio läuft nach Neustart weiter), nicht die neue Funktion. Offen: Wiederholung mit einem Gerät, das in unter 3 s zurückkommt (Komplete Audio 6 braucht beim USB-Wiederanmelden vermutlich länger). **Nachtrag 23.11.2026:** Nutzer: die Komplete Audio war unter 3 Sekunden wieder da (Schätzung nach Gefühl). Log-Zeitstempel beider Versuche: "verschwunden" bis erster Neustart 3,005 s und 3,009 s (das ist die 3-s-Frist `hdmiSettleDelay`, die ungestört ablief); zweiter Neustart 2,134 s und 2,077 s später (Re-Appear mit `btSettleDelay` = 2,0 s). Rückgerechnet kam das Gerät aus Sicht der App etwa 3,1 s nach dem Verschwinden zurück (3,14 s und 3,09 s), also knapp NACH der 3-s-Frist, bei beiden Versuchen fast gleich (spricht für eine feste Wiederanmeldezeit der Komplete Audio, nicht für Zufall). Unsicherheit etwa ±0,1 s (Zeitpunkt der Benachrichtigung, Rundung). Folge: Die Blip-Absorption greift nur, wenn das Gerät innerhalb von 3,0 s zurück ist; die Komplete Audio liegt knapp darüber. Offen: ob ein schnelleres Wiederanstecken (unter 1 s) unter 3,0 s bleibt, oder ob die Frist für USB-Schnittstellen zu knapp ist (Designfrage, kein Code geändert). Ursprünglicher Eintrag: 22.11.2026, Nutzer: kurze Unterbrechung, danach läuft die Musik von selbst weiter. M8-Negativkriterium (Audio reißt dauerhaft ab) nicht eingetreten, Commit `5798a63` bleibt. Nicht erfasst: Anzahl der Versuche, Dauer der Pause, Vergleich mit 4.0.1 (die Erwartung "kürzer oder keine Unterbrechung als 4.0.1" ist damit nicht belegt, nur das Weiterlaufen). |
| 15 | M6 | Noop-Rate des SR-Listeners, Zähler "M4-Noop" im Log | 15+ min Laufzeit | 1 Gerät, `log stream` | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | **Abgeschlossen 23.11.2026, 04:57: Zähler 0.** Nutzer wiederholte den Test am Morgen: `log stream` laufen lassen, Musik lief, keine Zeile (Screenshot 04:56:48). Gegenprobe rückwirkend (`/usr/bin/log show --last 90m --info`): 0 Einträge und damit 0 "M4-Noop" in den letzten 90 Minuten (ca. 03:27 bis 04:57), App-Prozess 95332 lief durchgehend. Annahme, vom Nutzer genannt: Routing war in dieser Zeit aktiv und die Rate wurde nicht geändert (nicht aus dem Log belegbar, da das Log keine Einträge ohne Ereignis schreibt). Der Abend-Teilversuch vom 22.11. (20:25 bis 20:34, ca. 9 Minuten) war ebenfalls ohne Eintrag. Zum Filter: **Abend-Teilversuch 22.11.2026, 20:34:** `log stream` mit `subsystem CONTAINS "audiorouternow"` startete um ca. 20:25 (Screenshot 20:25:37). Das Subsystem ist im Code fest `com.mauriciomorkun.audiorouternow` (nicht `.test`). Filter belegt: rückwirkende Abfrage (`/usr/bin/log show`) liefert 12 Einträge zwischen 20:17:59 und 20:24:45. Seit 20:24:45 bis 20:34 kein Eintrag, also kein "M4-Noop" im bisherigen Fenster (ca. 9 Minuten, Soll 15). Abschluss: Abfrage nach 20:41 wiederholen. |
| 16 | M5 | Grenze maxSlots (über 16/32 Ausgaben), Solo und Lautstärke verhalten sich gleich | ~15 min | BlackHole 64ch + Interface (17+ Ausgaben) | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | 23.11.2026, 48 Zeilen (BlackHole 16ch und 64ch vorübergehend installiert, Konfiguration vorbefüllt), Routing aktiv, Musik. Hörbare Ausgaben: Platz 1 (Kopfhörer), 17 (MacBook-Lautsprecher), 33 (Komplete Audio, also jenseits der 32.), dazu die weiteren Komplete-Audio-Paare und der BenQ-Monitor. Nutzer: Lautstärke von Platz 17 und 33 verstellt, beide reagieren; Solo auf Platz 1, 17 und 33 funktioniert (alle anderen stumm); nach dem Aufheben gelten die gespeicherten Pegel. Nicht hörbar prüfbar: die BlackHole-Zeilen (Aufnahmegeräte ohne Lautsprecher). Das lokale Limit-Experiment (maxSlots) ist NM-6. |
| 17 | NM-1 | Hörprüfung mit mehr als 16 und mehr als 32 Ausgaben | Teil der 30-45 min NM-Gruppe | BlackHole 64ch + Interface | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | 23.11.2026, Befund wie M5 (Plätze 17 und 33, 48 Zeilen): Lautstärke wirkt, Solo schaltet alle anderen stumm, gespeicherte Pegel gelten nach dem Aufheben. Grenzen: hörbar waren nur etwa 6 der 48 Zeilen; nur ein Platz jenseits der 32 (Platz 33) wurde gehört. |
| 18 | NM-2 | Pegelanzeige ab der 17. Ausgabe | Teil der NM-Gruppe | wie NM-1 | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | 23.11.2026, Nutzer: "ja" auf die Frage, ob die L/R-Balken der Karten 17 und 33 einen Pegel zeigen (unter fremdem Solo soll er 0 sein). Die Antwort war ein knappes "ja"; ob der Wert 0 unter fremdem Solo einzeln geprüft wurde, ist nicht ausdrücklich gesagt. Kein Screenshot. |
| 19 | NM-3 | Welle unter Solo bleibt gleich hoch | Teil der NM-Gruppe | 3+ Ausgaben | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | 23.11.2026, Nutzer: die Welle bleibt unter Solo gleich hoch (3 Ausgaben, Komplete Audio 6 MK2 Ch1-2 und Ch3-4, BenQ; Test-Kopie NM6, Routing aktiv, Musik). Geprüft: Solo setzen, Solo wechseln, Solo aufheben. Subjektiver Vergleich, keine Messung der Wellenhöhe; die Kopie hat denselben Wellen-Code wie 4.1 (nur `maxSlots` verändert). |
| 20 | NM-4 | CPU-Last bei 16 und 45+ Slots | Teil der NM-Gruppe | BlackHole 64ch, Activity Monitor | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | **Messwerte 23.11.2026** (Claude per `top -l 31 -s 2`, 30 Messungen, erste verworfen, Panel zu, Routing aktiv, Musik; M1-MacBook): 3 Zeilen **41,5 %** CPU (Min 34,8, Max 42,7); 18 Zeilen **40,3 %** (35,0 bis 41,3); 18 Zeilen mit offenem Panel **42,6 %** (37,3 bis 45,0); 48 Zeilen **42,4 %** (35,4 bis 44,5). Ergebnis: CPU hängt nicht von der Zeilenzahl ab (Unterschiede im Rauschen). Auffällig und ungeklärt: der absolute Wert um 40 % schon bei 3 Zeilen; ob das bei 4.0.1 gleich ist, nicht gemessen. IO-Puffer nicht verkleinert. Aussetzer und Knacken bei 48 Zeilen: Nutzer 23.11.2026: nichts, "alles läuft sauber". Damit NM-4 als ok gewertet, mit dem offenen Vorbehalt des nicht verglichenen Absolutwerts (4.0.1). Prozesse waren unterschiedlich lange gelaufen. |
| 21 | NM-5 | Bedienung der Liste bei sehr vielen Zeilen | Teil der NM-Gruppe | Gerät mit 128/256 Kanälen falls möglich | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | Ergebnis ok für 48 Zeilen (nicht für 128 bis 255 Kanäle), 23.11.2026: 48 Zeilen (kein 128/256-Kanal-Gerät vorhanden), Routing aus: Scrollen, Regler ziehen und Karte weit unten aufklappen laufen flüssig (Nutzer). Mit aktivem Routing (48 Zeilen, 23.11.2026): Panel geöffnet, Regler und Solo bedient (siehe M5), Nutzer: alles läuft sauber, nichts knackt oder setzt aus. Nicht geprüft: Aufklappen mehrerer Karten gleichzeitig, 128/256-Kanal-Gerät. Bewertung: ok für 48 Zeilen, nicht für 128 bis 255. |
| 22 | NM-6 | Meldung bei Ausgabenlimit (lokales Experiment maxSlots=20) | Teil der NM-Gruppe | Xcode (Code-Experiment) | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | 23.11.2026. Experiment ohne Änderung am Repo: v4 nach `/tmp/arn-nm6/v4` kopiert, dort `OutputLimits.maxSlots = 4` gesetzt (sichtbare Grenze 3), Release gebaut, als "AudioRouterNow 4.1 TEST NM6.app" (Test-Bundle-ID, ad-hoc signiert) auf den Desktop gelegt. Konfiguration: 3 Zeilen (Komplete Audio 6 MK2 Ch1-2 und Ch3-4, BenQ). Beim Versuch, ein viertes Gerät zu wählen, erschien (Screenshot 06:03:40) eine orange Warnzeile unter dem Start/Stop-Knopf: "Output limit reached: AudioRouterNow can route to 3 outputs at once. Remove an output to add another." Text vollständig lesbar, zweizeilig, nichts abgeschnitten; Liste blieb bei 3 Zeilen, Routing aktiv ("Routing → 3 devices"), Layout heil. Die Meldung kommt erst beim Anklicken eines Eintrags, nicht beim Öffnen des Menüs (so im Code, `addOutputConfig`). Beobachtung, kein Mangel: das Menü bietet am Limit weiter alle Einträge an (Ausgrauen als mögliche spätere Verbesserung). Nicht geprüft: Zurücknehmen der Meldung durch Entfernen einer Zeile. Das Repo und die Konstante 256 blieben unverändert. |
| 23 | NM-7 | Speicher bei 45+ Slots | Teil der NM-Gruppe | Activity Monitor | nein | [x] ok  [ ] negativ  [ ] nicht pruefbar | **Messwerte 23.11.2026** (`top` MEM / `ps` RSS, nach 60 s Routing): ohne Routing 57,7 MiB RSS (Ausgangswert alter Prozess); 3 Zeilen 39 MB / 93,0 MiB; 18 Zeilen 113 MB / 155,8 MiB; 48 Zeilen 115 MB / 164,6 MiB. Von 18 auf 48 Zeilen +2 MB (`top`), das sind etwa 70 KiB je Zeile und passt zur Rechnung (ca. 65 KiB je Slot). Der Sprung von 3 auf 18 Zeilen (+74 MB `top`) ist nicht zeilenproportional; Hypothese (ungeprüft): feste Kosten der 16- und 64-Kanal-BlackHole-Geräte (Datenströme), nicht der Slots. Die Prozesse waren unterschiedlich lange gelaufen. |

## 4. Anleitungen je Messpunkt

Gekürzt aus den Prüfleitfäden. Erwartung und Verhalten bei negativem Ergebnis sind genannt.

### M1 ScrollView ab 45+ Einträgen
1. BlackHole 64ch und ein Interface mit vielen Kanälen (z.B. Scarlett 18i20) verbinden.
2. App starten, Panel öffnen.
3. Scroll-Indikator, Scrollbarkeit prüfen.
4. Prüfen, ob der große Start/Stop-Knopf oben (unter der Statuszeile, außerhalb des ScrollViews) immer sichtbar bleibt.
5. Prüfen, ob der Footer immer sichtbar bleibt.
6. Prüfen, ob der Status-Text zusammen mit "CBs" in die Statuszeile passt, ohne Umbruch oder Abschneiden.
7. Auf einem 13"-Gerät prüfen, ob das Panel auf den Bildschirm passt (gerendert C3: 589 pt bei 18 Zeilen, unter ~700 pt, am Gerät zu bestätigen).
- Erwartung: Indikator sichtbar, Liste scrollbar, oberer Knopf und Footer immer sichtbar, nichts umgebrochen oder abgeschnitten, Panel passt.
- Negativ: in der Notiz festhalten, welches Element fehlt oder abgeschnitten ist; kein definierter Rückfall im Bericht.

### M2 Start/Stop-Knopf oben
1. Mindestens ein Gerät konfigurieren.
2. Im Zustand idle den großen oberen Knopf klicken.
3. Im Zustand active den Knopf klicken.
4. Im Zustand starting ansehen (Knopf deaktiviert).
5. Schnell doppelklicken und prüfen, dass kein doppelter Start passiert.
- Erwartung: Routing startet und stoppt korrekt über den oberen Knopf, im Zustand starting deaktiviert, kein doppelter Start. Audio spielt auf den gewählten Geräten.
- Negativ: in der Notiz festhalten, kein definierter Rückfall im Bericht.

### M2b Knopfoptik oben und Footer, VoiceOver
1. Oberer Knopf: im Leerlauf mit Auswahl gefüllte Mint-Pille "Start Routing"; ohne Auswahl gedimmt; beim Routen umrandet "Stop Routing"; beim Starten Spinner "Connecting…".
2. Maus darüber (hellt auf), drücken (sinkt kurz ein).
3. Mit VoiceOver über den Knopf navigieren.
4. Footer prüfen: Launch at Login sichtbar und als Checkbox bedienbar; Support als Mint-Pille mit Herz und Wort "Support" (beim Aufklappen des Tip Jar X plus "Close"); Lock, Exclusive, Bug und Quit erreichbar.
- Erwartung: oberer Knopf in jedem Zustand als Knopf erkennbar, VoiceOver liest "Start Routing"/"Stop Routing", Support als Knopf mit Wort erkennbar, keine Footer-Funktion fehlt.
- Negativ: in der Notiz festhalten.

### M2c Hover-Erklärungen im Footer
1. Mit der Maus nacheinander über Support, Lock, Exclusive, Bug, Quit und Launch at Login fahren, je ca. 0,4 s warten.
2. Die äußersten Elemente links (Launch at Login) und rechts (Quit) prüfen (Clamping am Fensterrand).
3. Mit Trackpad und mit Maus testen.
- Erwartung: kleine Textbox über dem Footer erscheint, verschwindet beim Verlassen und beim Klick, wird an beiden Rändern geclampt, flackert beim Wechsel nicht. Texte: Support "Opens the tip jar. Tipping is optional and unlocks nothing."; Lock "Keeps macOS from switching the output device while routing."; Exclusive "Only selected devices play. The default output stays silent."; Bug "Opens a pre-filled bug report email with version info."; Quit "Quits AudioRouterNow."; Launch at Login "Starts AudioRouterNow automatically when you log in."
- Negativ: in der Notiz festhalten.

### M2d Add-device-Menü: scrollbar und Kennzeichnung
1. Scrollbarkeit (bereits am 17.11. bestätigt): Prüfhilfe "AudioRouterNow 4.1 TEST C3 LISTE.app" starten, Panel öffnen, "Add device" anklicken (zeigt 120 künstliche Einträge, kein Routing).
2. Kennzeichnung V2 (bereits am 17.11. bestätigt): "TEST C3b.app" starten, ein Mehrkanalgerät (z.B. KA6 Ch1-2 und Ch3-4) auswählen, Routing starten, dann "Add device" öffnen.
3. Offen: dasselbe im **echten SwiftUI-Menü** der ausgelieferten App bestätigen.
- Erwartung: Menü scrollbar (Scroll-Pfeil, Scrollrad, Tastatur), alle Einträge erreichbar. Hinzugefügte Einträge mit Haken, ausgegraut, nicht wählbar; sind alle hinzugefügt, nur "All outputs are added."
- Negativ: in der Notiz festhalten. Belegt bisher nur per NSMenu-Probe, nicht am echten SwiftUI-Menü (`25-add-device-liste.md`).

### M3 Solo ohne Knacksen
1. Mindestens zwei Ausgaben, Routing aktiv, Musik läuft.
2. Solo eines Outputs setzen, einen anderen solo setzen, Solo aufheben.
3. Während Solo den Regler einer stummen Ausgabe verschieben; nach dem Aufheben prüfen.
- Erwartung: kein Knacksen, kein Lautstärkesprung. Nach dem Aufheben gilt die gespeicherte Lautstärke inkl. des verschobenen Reglerwerts.
- Negativ: Die Knacksfreiheit beruht auf der Annahme E5 (die vorhandene W1-Rampe genügt). Negativ in der Notiz festhalten; kein definierter Rückfall.

### M4 Solo bei abgestecktem Gerät
1. Zwei Ausgaben, eine solo setzen.
2. Das Solo-Gerät entfernen.
- Erwartung: alle anderen Ausgaben bleiben stumm. Nach dem Aufheben von Solo hören alle verbliebenen wieder.
- Negativ: in der Notiz festhalten.

### M5 Grenze maxSlots (Nachtrag-Fassung)
1. Ein virtuelles Gerät mit 64 Kanälen (32 Paare, BlackHole 64ch) plus ein Interface, mindestens 45 Zeilen.
2. Lautstärke der 17. Ausgabe und einer Ausgabe jenseits der 32. verstellen.
3. Solo auf der 1. Ausgabe, dann auf der 17., dann auf einer jenseits der 32.
4. Optionales lokales Experiment für die reine Grenze: Konstante `OutputLimits.maxSlots` temporär auf 20 senken (nicht committen), bauen, 19 Ausgaben wählen, eine weitere versuchen. Danach zurücksetzen.
- Erwartung: alle Ausgaben verhalten sich gleich, Solo schaltet die anderen stumm, die Lautstärke wirkt. Beim Experiment: Meldung erscheint, Ausgabe wird nicht hinzugefügt.
- 17 echte Geräte sind nicht nötig (BlackHole 64ch liefert 32 Paare). Ohne BlackHole 64ch: **nicht prüfbar ohne** virtuelles Mehrkanalgerät.
- Negativ: in der Notiz festhalten.

### M6 Noop-Rate des SR-Listeners
1. App 15 Minuten oder länger mit aktivem Routing laufen lassen, ohne die Sample-Rate zu ändern.
2. Ausführen: `log stream --predicate 'subsystem == "com.mauriciomorkun.audiorouternow"' | grep "M4-Noop"` und den Zähler lesen.
- Erwartung: Zähler 0 oder sehr niedrig. Ein hoher Wert zeigt, dass der Listener grundlos feuert.
- Hinweis (korrigiert 23.11.2026): Das Subsystem steht im Code fest als `com.mauriciomorkun.audiorouternow` (nicht `.test`), das Prädikat aus dem Bericht stimmt also auch für die Test-App. Praktisch bewährt: `log stream --predicate 'subsystem CONTAINS "audiorouternow"'` mitlaufen lassen und danach rückwirkend mit `/usr/bin/log show --last 90m --info --predicate 'subsystem == "com.mauriciomorkun.audiorouternow"'` gegenprüfen (`log stream` zeigt nur neue Einträge; in der zsh ist `log` ein eingebauter Befehl, daher `/usr/bin/log`).
- Negativ: in der Notiz festhalten.

### M7 Restart bei echtem Rate-Wechsel
1. Routing aktiv, Gerät mit umschaltbarer Rate (z.B. Komplete Audio 6).
2. Rate in Audio MIDI Setup von 48 kHz auf 44,1 kHz umschalten.
- Erwartung: Warm-Restart innerhalb von 1 bis 3 Sekunden, kein "M4-Noop" im Log.
- Negativ: in der Notiz festhalten.

### M8 Blip-Absorption
1. Routing aktiv, USB-Gerät.
2. Kabel kurz lösen (unter 2 Sekunden) und wieder einstecken.
- Erwartung: kürzere oder keine Unterbrechung als bei 4.0.1.
- **Negativ (M8-Regel):** Reißt das Audio dauerhaft ab, ist Commit `5798a63` umzukehren, bevor es weitergeht (`09-final-report` Z. 313, 326f).

### M9 Meter und Welle unter Solo
1. Mindestens zwei Ausgaben, Routing aktiv.
2. Solo eines Outputs setzen, eine andere Card aufklappen, die grünen Signal-Balken der durch fremdes Solo stummen Card ansehen.
3. Welle im Header ansehen: unter Solo gleich hoch wie ohne Solo (gleiches Material, Solo setzen, wechseln, aufheben).
- Erwartung: Meter zeigen 0 (Stille), passend zur 0,4 Opacity der Card. Welle bleibt unter Solo gleich hoch. Vor dem Fix (B1) zeigten die Meter Pegel.
- Negativ: in der Notiz festhalten.

### NM-1 Hörprüfung über 16 und 32 Ausgaben
1. Virtuelles Gerät mit 64 Kanälen (32 Paare) plus Interface (z.B. 10 Paare) plus Standardgerät, mindestens 45 Zeilen, Routing aktiv.
2. Lautstärke einer Ausgabe ab der 17. und einer jenseits der 32. verstellen.
3. Solo auf der 1. Ausgabe, dann auf der 17., dann auf einer jenseits der 32.
- Erwartung: jede Ausgabe reagiert auf Lautstärke, Solo schaltet alle anderen stumm, nach Aufheben gelten die gespeicherten Pegel.

### NM-2 Pegelanzeige ab der 17. Ausgabe
1. Wie NM-1, Karte der 17. und einer späteren Ausgabe aufklappen.
- Erwartung: Signal-Balken zeigen Pegel, unter fremdem Solo 0.

### NM-3 Welle unter Solo
1. Mindestens drei Ausgaben, gleiches Material, Wellenhöhe ohne Solo ansehen.
2. Solo setzen, Solo wechseln, Solo aufheben.
- Erwartung: Wellenhöhe bleibt gleich, nur die Karten-Meter ändern sich.

### NM-4 CPU-Last
1. Activity Monitor öffnen, CPU-Anteil von AudioRouterNow bei 16 und bei 45 oder mehr Slots über einige Minuten beobachten, wenn möglich bei kleinem IO-Buffer.
- Erwartung: Anstieg gering (Hochrechnung etwa 1 Prozent des Callback-Budgets bei 256 Slots, synthetisch). Auffälligkeit (Aussetzer, Knacken) melden.
- Rückfall bei Auffälligkeit (`14-plan-nachtrag` Z. 255): Snapshot-Struktur erwägen.

### NM-5 Bedienung der Liste bei sehr vielen Zeilen
1. Panel öffnen, scrollen, Regler ziehen, Karten aufklappen bei 45 oder mehr Zeilen, falls möglich bei einem Gerät mit 128 oder 256 Kanälen.
- Erwartung: Panel bleibt bedienbar, kein Absturz (CASE-003 beachten).
- Rückfall bei Auffälligkeit: `LazyVStack` für sehr lange Listen erwägen (Folgeschritt).

### NM-6 Meldung bei Ausgabenlimit
1. Lokales Experiment: `OutputLimits.maxSlots` temporär auf 20 senken (nicht committen), bauen.
2. 19 Ausgaben wählen, eine weitere versuchen.
- Erwartung: Meldung erscheint, Ausgabe wird nicht hinzugefügt, Layout bleibt heil. Danach Konstante zurücksetzen.

### NM-7 Speicher
1. Activity Monitor, Speicher bei 45 oder mehr Slots.
- Erwartung: Zuwachs im Bereich einiger MiB (Rechnung etwa 65 KiB je Slot).

## 5. Nach der Sitzung

- Ergebnisse eintragen in `09-final-report.md` (ersatzweise Abschnitt 12, die Spalte "Ergebnis" in Abschnitt 7 bleibt als Planungsstand leer), dazu in `TODO.md` und in das Memory `project_audiorouternow_v41_status.md`. **Erledigt 23.11.2026.**
- Negative Ergebnisse als Liste "Nachbesserung nötig" führen. Fällt **M8** negativ aus, zuerst Commit `5798a63` umkehren.
- Entscheidung zum Weitergehen: Archiv nur, wenn **keine Blocker** offen sind (E1, E3, E4, E6 nach den Messungen erneut prüfen; Welle 6a und Launch-at-Login-Reset 6d annehmen oder Rückfall wählen).
- Nächster Schritt laut Release-Plan (`26-release-plan.md` Abschnitt 5, `09-final-report` Abschnitt 8): neues 4.1-Archiv bauen und signieren (behebt den Preflight-ABBRUCH), Preflight erneut, App-Store-Connect-Texte eintragen, Datum im CHANGELOG, Tag `v4.1`, Merge nach `main`, Push, Einreichung. Jeder unumkehrbare Schritt nur auf ausdrückliche Anweisung des Nutzers.

## 6. Ergebnis- und Notizfelder

Stand 23.11.2026: Die Spalten "Ergebnis" und "Notiz" in Abschnitt 3 sind ausgefüllt. Die
Spalte "bereits gesehen" gilt weiter als Stand vor der Sitzung (für M2d teilweise,
Quelle 17.11.2026). Offen sind nur die drei Zusatzzeilen VoiceOver-Hinweis, Tab-Fokus
und Umbruch bei großer Schrift (Zeilen 6 bis 8). Jede Nutzerangabe steht mit Datum
und, wo vorhanden, mit Beleg (Screenshot, Zeitstempel) in der Notiz. Wo eine Angabe
nicht ausdrücklich gemacht wurde, steht das dort (zum Beispiel bei M2b, M3, M4, M8).

## 7. Zusammenfassung der Sitzung (Stand 23.11.2026)

**Ergebnis:** 20 von 23 Zeilen der Tabelle in Abschnitt 3 sind ok. Keine Zeile ist
negativ. Offen sind 3 Zusatzzeilen (VoiceOver-Hinweis je Footer-Symbol, Tab-Fokus,
Umbruch bei großer Schrift). Der feste Rückfall aus M8 (Commit `5798a63` umkehren)
wurde nicht ausgelöst.

Hinweis zur Zählung: Die Tabelle hat 23 Zeilen, davon 4 Zusatzzeilen und 19 Hauptzeilen
(M1 bis M9 mit M2b, M2c, M2d sowie NM-1 bis NM-7). Alle 19 Hauptzeilen sind ok. Von den
4 Zusatzzeilen ist "Start ohne Absturz" ok (abgeleitet), die anderen drei sind offen.
Daraus folgen 20 ok und 3 offen.

| Gruppe | Zeilen | Ergebnis |
|--------|--------|----------|
| Oberfläche | M1, M2, M2b, M2c, M2d | ok (M1 mit 48 Zeilen, 13"-Prüfung nicht belegt) |
| Solo | M9, M3, M4 | ok |
| Geräteverhalten | M7, M8, M6 | ok (M8 erst nach Wiederholung, siehe unten) |
| Viele Ausgänge | M5, NM-1 bis NM-7 | ok (48 Zeilen, kein 128/256-Kanal-Gerät) |
| Zusatzzeilen | Start ohne Absturz | ok (abgeleitet) |
| Zusatzzeilen | VoiceOver-Hinweis, Tab-Fokus, große Schrift | offen |

**Was über die Ergebnisse hinaus herauskam:**

1. **M8 wurde falsch eingetragen und korrigiert.** Erst "ok" nach der Nutzerangabe, dann
   nach der Log-Auswertung zurückgenommen (Gerät kam nach etwa 3,1 s zurück, Frist 3,0 s,
   Blip nicht erkannt), dann "ok" nach der Wiederholung mit schnellem Einstecken (dreimal
   "L1: Blip erkannt", kein Engine-Neustart). Langsameres Wiedereinstecken (über 3 s) führt
   weiter zum regulären Neustart.
2. **CPU um 40 % eines Kerns schon bei 3 Zeilen**, unabhängig von der Zeilenzahl (3, 18
   und 48 Zeilen: 41,5, 40,3 und 42,4 Prozent). Der Absolutwert ist nicht gegen 4.0.1
   verglichen. Das ist der wichtigste offene Punkt der Sitzung.
3. **Speicher** etwa 70 KiB je Zeile (passt zur Planung).
4. **M6-Prädikat:** Das Subsystem ist im Code fest, die frühere Vermutung (`.test`) war
   falsch. Gegenprobe immer rückwirkend mit `/usr/bin/log show`.
5. **Limit-Meldung** erscheint beim Anklicken, nicht beim Öffnen des Menüs. Ausgrauen der
   Einträge am Limit als mögliche Verbesserung für später.

**Messumgebung und Rückbau (23.11.2026):** BlackHole 16ch und 64ch per Homebrew installiert,
Audio-Dienst neu gestartet, Test-Konfiguration vorbefüllt (16, dann 48 Zeilen). Rückbau:
BlackHole entfernt (Treiberordner und `brew list` geprüft), Test-Einstellungen auf die
ursprünglichen 3 Zeilen zurückgesetzt, NM6-Testkopie und Build-Verzeichnis gelöscht, Repo
unverändert. Die Sicherung der Einstellungen liegt im Home-Ordner
(`arn-test-prefs-backup-20261123.plist`) und kann gelöscht werden, wenn der Nutzer es sagt.

**Nächste Schritte:** siehe Abschnitt 5 und `09-final-report.md` Abschnitt 12.3.
