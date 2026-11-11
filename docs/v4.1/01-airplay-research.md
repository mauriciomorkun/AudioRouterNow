# AirPlay in AudioRouterNow 4: Recherche und Nachprüfung

**Stand:** 11.11.2026
**Status:** Entscheidung offen (siehe letzter Abschnitt)

## Fragestellung

Ein Nutzer sieht in der App keine AirPlay-Geräte in der Ausgabeliste. Ziel ist,
dass AirPlay-Geräte angezeigt und als Audioziel genutzt werden können. Dieses
Dokument klärt, was davon mit den Mitteln einer sandboxed Mac-App-Store-App
heute möglich ist, und trennt dabei Beleg, Messung und Annahme.

## Methode

1. Erste Recherche durch das Fable-Modell (Quellensuche, API-Bewertung, Konfidenzen).
2. Nachprüfung durch den Hauptagenten: Code gelesen, Entitlements gelesen, einen
   Teil der zitierten Foren-Threads per WebFetch nachgeprüft, eine lesende Messung
   auf dem Mac des Nutzers ausgewertet.

Die Trennung ist durchgehend: eine Aussage gilt nur so weit, wie ihre Markierung
in den Tabellen reicht.

## Gemessene Fakten (Mac des Nutzers, 10.11.2026, macOS 26, nur lesend)

Alle folgenden Punkte sind auf echter Hardware gemessen, nicht aus dem Code
abgeleitet.

- `dns-sd -B _raop._tcp local.` (zweimal, je 7 bis 8 Sekunden) findet drei
  AirPlay-Empfänger im Netz: zwei MacBooks und ein Volumio-Gerät des Nutzers
  (Raspberry Pi mit shairport-sync). Die Abfrage `_airplay._tcp` findet nur die
  zwei MacBooks.
- Die CoreAudio-Abfrage (`kAudioHardwarePropertyDevices` plus
  `kAudioDevicePropertyTransportType`) und `system_profiler SPAudioDataType`
  listen sieben Geräte. KEIN Gerät hat den Transporttyp AirPlay (`airp`).
  `grep -ci airplay` auf der Geräteliste ergibt 0.
- Schluss daraus: Das Volumio-Gerät ist im Netz sichtbar, aber für CoreAudio und
  damit für die App unsichtbar, solange es nicht verbunden ist. Die Hypothese
  "AirPlay erscheint erst nach Verbindung" ist für den Zustand "nicht verbunden"
  bestätigt. Der Zustand "verbunden" wurde NICHT getestet.

### Was der Code dazu tatsächlich tut (nachgeprüft)

- `FanOutEngine.availableOutputDevices()` in
  `v4/AudioRouterKit/Sources/AudioRouterKit/FanOutEngine.swift` (Zeilen 1223 bis
  1254) fragt ausschließlich CoreAudio ab (`kAudioHardwarePropertyDevices`),
  filtert auf Geräte mit Output-Kanälen, schließt Aggregate-Geräte aus und liefert
  `uid`, `name`, `channelCount`. Es gibt keinen Transport-Filter und keinerlei
  Bonjour- oder Netzwerkcode im Repo. Folge: Erscheint ein Gerät nicht in
  CoreAudio, kann die App es gar nicht sehen.
- Die Entitlements in `v4/AudioRouterNow4/AudioRouterNow4.entitlements` enthalten
  genau zwei Keys: `com.apple.security.app-sandbox` und
  `com.apple.security.device.audio-input`. Kein Netzwerk-Entitlement.

## Urteile je Weg mit Konfidenz und Beleg-Qualität

Wege im Sinne möglicher Lösungsrichtungen:

- Weg B: AirPlay-Geräte aus dem Netz per Bonjour entdecken und anzeigen.
- Weg C: ein entdecktes AirPlay-Gerät aus der App heraus verbinden.
- Zusatzfrage: taugt ein verbundenes AirPlay-Gerät als Sub-Device des privaten
  Aggregate Device, auf dem die App aufbaut.

### Weg B, Bonjour-Entdeckung anzeigen

Urteil des Recherche-Agenten: "möglich mit Einschränkungen", Konfidenz 80 Prozent.

| Aussage | Quelle / Messung | Status |
|---|---|---|
| AirPlay-Empfänger lassen sich per Bonjour (`_raop._tcp`, `_airplay._tcp`) im Netz finden | `dns-sd`-Messung am 10.11.2026, drei bzw. zwei Geräte gefunden | gemessen |
| Nötig: Entitlement `com.apple.security.network.client` | Fable-Agent (Sekundärquellen: Xojo-Forum, OrcaSlicer-PR, Tauri-Issue) | belegt (nur Sekundärquellen, nicht Apple) |
| Nötig: `NSBonjourServices` (`_raop._tcp`, `_airplay._tcp`) und `NSLocalNetworkUsageDescription` in der Info.plist | Fable-Agent, gleiche Sekundärquellen | belegt (nur Sekundärquellen, nicht Apple) |
| Einmaliger Local-Network-Systemdialog beim ersten Scan | Fable-Agent, gleiche Sekundärquellen | belegt (nur Sekundärquellen, nicht Apple) |
| Früherer `NWBrowser`-Bug `PolicyDenied(-65570)` unter macOS 15.4/15.5, behoben ab 15.6 | Apple Developer Forums Thread 780655, vom Agenten zitiert | ungeprüft |

Vorbehalt: Die Belege für die Voraussetzungen sind durchweg Sekundärquellen,
keine Apple-Dokumentation. Vor einer Umsetzung sind sie gegen Apples offizielle
Doku zu Local Network Privacy und Bonjour in der Sandbox zu prüfen.

### Weg C, aus der App heraus verbinden

Urteil des Recherche-Agenten: "nicht möglich über eine öffentliche,
sandbox-taugliche API", Konfidenz 90 Prozent.

| Aussage | Quelle / Messung | Status |
|---|---|---|
| Keine öffentliche, sandbox-taugliche API gefunden, mit der eine Drittanbieter-App ein AirPlay-Gerät verbindet | Negativbefund des Fable-Agenten | nicht gefunden (kein Beweis der Unmöglichkeit) |
| `AVRoutePickerView` ist auf den eigenen AVPlayer der App beschränkt | zweitrangiges Zitat, vom Agenten genannt | nicht gefunden (nur Sekundärzitat) |
| `AVOutputContext` als öffentliche API nutzbar | Fable-Agent | nicht verifiziert |
| Entitlements `com.apple.avfoundation.allows-access-to-device-list` und `...allows-set-output-device` werden Drittanbietern nicht erteilt | GitHub-Repo Optimus-Player/AirPlay-Enabler (README) | Hinweis, nicht als Apple-Beleg zu werten |
| Ein eigenes RAOP-Protokoll wäre nicht App-Store-tauglich | Einschätzung des Agenten | Annahme (plausibel, riskant) |

Vorbehalt: Das ist ein Negativbefund. "Keine API gefunden" ist nicht dasselbe
wie "bewiesen unmöglich". Die Punkte sind als "nicht gefunden" zu lesen.

### Zusatzfrage, AirPlay als Sub-Device des privaten Aggregate Device

Urteil des Recherche-Agenten: "unklar, Hinweise negativ", Konfidenz 75 Prozent.
Die Architektur der App baut ein privates Aggregate Device aus Sub-Devices; ob
ein verbundenes AirPlay-Gerät darin als Sub-Device taugt, ist offen.

| Beleg | Inhalt | Status |
|---|---|---|
| Apple Developer Forums Thread 17664 (macOS 10.11, ca. 2015) | Ein Entwickler schreibt, AirPlay-Geräte seien unter 10.11 in `kAudioHardwarePropertyDevices` nur sichtbar, wenn sie in den Systemeinstellungen als System-Ausgabe gewählt sind. Ein Workaround über `kAudioHardwarePropertyTranslateUIDToDevice` liefere ein Handle, aber "AirPlay devices have no data sources and cannot stream audio unless selected as the system output". Keine Antwort von Apple im Thread. | belegt, aber alt (11 Jahre), heutiges Verhalten unter macOS 26 ungeprüft. Vom Hauptagenten per WebFetch nachgeprüft, Inhalt steht so im Thread |
| Apple Developer Forums Thread 750483 (April 2024) | Anderes Problem als zunächst dargestellt: dort listet `kAudioHardwarePropertyDevices` keine AirPlay-Geräte, wenn ein virtueller Treiber (BoomAudio) als System-Ausgabe gewählt ist. Keine Antworten, Feedback FB7543204, ungelöst. Relevanz: die Sichtbarkeit von AirPlay in CoreAudio hängt offenbar vom gewählten System-Ausgabegerät ab | belegt, vom Hauptagenten geprüft |
| Apple Community Thread 250260702 | AirPlay als Aggregate-Sub-Device wird offline bzw. stumm | ungeprüft (nur vom Agenten zitiert) |
| openradar #23049205 | "CoreAudio can no longer enumerate AirPlay devices" | ungeprüft (nur vom Agenten zitiert) |

Offen und nur durch Echttest zu klären: ob ein verbundenes AirPlay-Gerät als
Sub-Device eines Aggregate taugt, wie groß Drift und Latenz sind (die Recherche
nennt 200 ms bis 2 s, nicht gemessen), und wie sich ein Dropout verhält.

## Korrekturen am Agenten-Bericht

Diese Punkte im ursprünglichen Fable-Bericht waren falsch oder unverifiziert und
werden hier richtiggestellt:

- Der Agent nannte `EngineController.swift:384-387` als Deep-Link-Muster. Das ist
  falsch; dort steht `stopRouting()`. Richtig: `EngineController.swift:560`,
  `openTCCSettings()` nutzt `NSWorkspace.shared.open(URL)` mit
  `FanOutEngine.tccDeepLink`. Der Kommentar bei Zeile 567 hält fest, dass
  `NSWorkspace.open` in der Sandbox ohne zusätzliches Entitlement funktioniert.
- Der Agent schlug `x-apple.systempreferences:com.apple.preference.sound` als
  Deep-Link zur Ton-Einstellung vor. Das ist unverifiziert und für macOS 26
  vermutlich veraltet. Status: zu prüfen, nicht als gegeben übernehmen.
- Die bisherige BACKLOG-Aussage "AirPlay-Geräte erscheinen in der Geräteauswahl,
  sobald macOS sie kennt" war eine reine Code-Annahme, nie am Gerät geprüft, und
  ist für nicht verbundene Geräte falsch (siehe Messung). Im BACKLOG als
  korrigiert gekennzeichnet.

## Folgen für die Architektur

- Die App sieht nur, was CoreAudio zeigt. Ein nicht verbundenes AirPlay-Gerät
  taucht dort nicht auf, also auch nicht in der App. Das ist der gemessene
  Normalzustand, kein Fehler im Code.
- Die Rang-Logik für AirPlay existiert bereits: `deviceTransportRank()`
  (`FanOutEngine.swift:1287`) ordnet `kAudioDeviceTransportTypeAirPlay` zusammen
  mit Bluetooth in Rang 4 ein, wird also nie Clock-Master, bleibt aber routbar.
  Das greift erst, wenn ein AirPlay-Gerät überhaupt in CoreAudio erscheint.
- Wichtigster Zusammenhang: Selbst wenn Weg B Geräte im Netz anzeigt, kann die App
  sie nach heutigem Kenntnisstand nicht selbst verbinden (Weg C nicht belegt).
  Anzeigen allein löst "nutzen" also nicht. Verbinden bleibt eine Handlung, die
  der Nutzer in macOS (Kontrollzentrum oder Ton-Einstellung) ausführt.

## Handlungsoptionen

Grobe Aufwandsschätzung und Review-Risiko je Option. Keine davon ist beschlossen.

### Option A: Hinweis-UI "AirPlay-Gerät zuerst in macOS verbinden"

Ein kurzer Hinweis in der App, dass AirPlay-Geräte erst nach Verbindung über
macOS erscheinen, optional mit einem Deep-Link zur Ton-Einstellung.

- Aufwand: gering (reiner UI-Text plus einen bestehenden Deep-Link-Mechanismus nutzen).
- Review-Risiko: gering. Kein neues Entitlement, kein Netzwerkzugriff.
- Offener Punkt: der genannte Deep-Link `x-apple.systempreferences:com.apple.preference.sound`
  ist unverifiziert (siehe Korrekturen). Vor Nutzung prüfen oder weglassen.

### Option B: Bonjour-Anzeige der Geräte "in der Umgebung" (grau), mit Anleitung

Die App scannt per Bonjour nach `_raop._tcp` / `_airplay._tcp` und zeigt
gefundene Geräte ausgegraut als "in der Umgebung, zuerst in macOS verbinden".

- Aufwand: mittel (neuer Bonjour-Scan, neue Entitlement- und Info.plist-Einträge,
  Umgang mit dem Local-Network-Dialog, Datenschutz-Begründung).
- Review-Risiko: mittel. Neues Netzwerk-Entitlement und Local-Network-Zugriff
  müssen gegenüber App Review nachvollziehbar begründet sein, und die Belege dafür
  sind bisher nur Sekundärquellen (gegen Apple-Doku prüfen).
- Nutzen allein: zeigt an, verbindet nicht. Löst die eigentliche Frage nur halb.

### Option C: Verbinden aus der App

Derzeit nicht als über eine öffentliche, sandbox-taugliche API möglich belegt
(siehe Weg C). Nicht weiterverfolgen, bis ein belastbarer Beleg vorliegt.

### Option D: Test der Default-Slot-Hypothese

Siehe den Hypothesen-Abschnitt unten. Reiner Echttest, kein Code nötig, um die
Hypothese zunächst zu prüfen.

- Aufwand: gering bis mittel (nur Messung, kein Code, solange die Hypothese nur geprüft wird).
- Review-Risiko: keins, da reine Messung.

## Hypothesen (vor Umsetzung gegen den Code prüfen)

### H1: Default-Slot (Annahme des Hauptagenten)

Nach CASE-008 (`feedback/CASE-008_selbstfund_lautsprecher-spielen-trotz-routing.md`,
Code in `FanOutEngine.swift` um Zeile 425 bis 500) hängt die Engine im
Standard-Modus das aktuelle System-Default-Gerät als zusätzlichen Schreib-Slot an
(`shouldAppendDefaultSlot(hasResolvableUserOutputs:exclusiveRouting:)`).

Hypothese: Ist ein AirPlay-Gerät als System-Ausgabe gewählt, wäre es der
Default-Slot und könnte so unabhängig von der Aggregate-Sub-Device-Frage als Ziel
funktionieren.

Nachgeprüft am Code (`buildAndStartAggregate`, Zeilen 425 bis 495): Der
Default-Output wird im Standard-Modus als Slot angehängt und ist Master-Kandidat.
Zugleich dokumentiert der Code eine bekannte Einschränkung (Zeilen 450 bis 457):
Im Exklusiv-Modus mit ausschließlich BT-/AirPlay-Outputs (alle Rang 4) fällt die
Master-Elektion auf ein solches Gerät zurück, entgegen der Regel "BT/AirPlay nie
Master", mit schlechterer Clock-Stabilität. Eine Diagnose-Warnung macht den Fall
sichtbar, ändert das Verhalten aber nicht.

Bewertung: Die Hypothese ist plausibel, weil der Default-Slot-Pfad existiert und
ein als System-Ausgabe gewähltes AirPlay-Gerät in CoreAudio erscheinen sollte
(Thread 17664 deutet genau darauf hin). Sie bleibt dennoch eine zu testende
Hypothese, kein Beleg: der Code wurde nie gegen ein echtes AirPlay-Gerät
ausgeführt, und die Clock-Einschränkung könnte im Standard-Modus (Default-Slot
vorhanden, also Rang-0-bis-3-Master wählbar) entschärft sein, im Exklusiv-Modus
dagegen nicht. Nur der Echttest klärt es.

### H2: Eigener Ausgabepfad für AirPlay (Annahme des Hauptagenten)

Falls AirPlay als Aggregate-Sub-Device scheitert, wäre eine mögliche
Alternativarchitektur ein eigener Ausgabepfad (separater IOProc, eigener
Ringpuffer mit Drift-Kompensation) nur für AirPlay-Geräte.

Status: reine Idee, ungeprüft, hoher Aufwand, berührt den Echtzeitpfad. Hier gilt
die Vorsicht aus CASE-004 und CASE-007 (doppelte Lautstärke, Lautstärke-Sprung),
jede Änderung am IO-Pfad ist risikoreich. Nicht ohne vorherige Messung angehen.

## Echttest-Plan (Volumio-Gerät des Nutzers)

Reiner Test gegen echte Hardware. Je Schritt ein erwartetes Ergebnis und ein
leeres Feld für das tatsächliche Ergebnis. Die Felder bleiben leer, bis der Test
gelaufen ist.

### Schritt 1: Gerät verbinden

AirPlay-Gerät (Volumio) im macOS-Kontrollzentrum als Ausgabe verbinden.

- Erwartet: Systemton geht an das Gerät.
- Tatsächlich:

### Schritt 2: Erscheint es in der App

Nach Verbindung `availableOutputDevices()` bzw. die Geräteauswahl der App prüfen.

- Erwartet: Das Gerät erscheint in der Liste (das ist genau der Punkt, der im
  nicht verbundenen Zustand gemessen fehlte).
- Tatsächlich:

### Schritt 3: Als einziges Ziel

Nur das AirPlay-Gerät als Ausgabe wählen, Routing starten.

- Erwartet: Ton kommt am Gerät an, stabil.
- Tatsächlich:

### Schritt 4: Als zweites Ziel neben USB

AirPlay plus ein USB-Gerät gleichzeitig routen.

- Erwartet: beide Ausgänge spielen; USB wird Clock-Master (Rang 0), AirPlay bleibt
  Slave (Rang 4). Der Fan-Out-Ausgleich hält beide synchron, soweit die
  AirPlay-Latenz das zulässt.
- Tatsächlich:

### Schritt 5: AirPlay als System-Standardgerät (H1)

Das AirPlay-Gerät in macOS als System-Ausgabe wählen, dann die App im
Standard-Modus (Default-Slot aktiv) routen.

- Erwartet (Hypothese H1): Das AirPlay-Gerät ist der Default-Slot und spielt,
  unabhängig von der Sub-Device-Frage.
- Tatsächlich:

### Schritt 6: Dropout

Strom oder WLAN des AirPlay-Geräts während des Routings trennen.

- Erwartet: Die App bleibt stabil, der Ausfall wirkt nicht wie ein App-Absturz,
  die anderen Ausgänge laufen weiter.
- Tatsächlich:

### Schritt 7: Latenzanzeige

Prüfen, ob die hohe AirPlay-Latenz dem Nutzer sichtbar gemacht wird.

- Erwartet: offen. Zu beobachten, ob ein merklicher Versatz entsteht und ob die
  UI ihn erklärt oder ob er wie ein Fehler wirkt.
- Tatsächlich:

### Schritt 8: Stabilität über mehrere Minuten

Routing mit AirPlay mehrere Minuten laufen lassen.

- Erwartet: kein Drift-Aufbau, kein Stummwerden, keine wachsende Latenz.
- Tatsächlich:

## Entscheidung offen

Der Stand ist Recherche plus eine lesende Messung. Kein Echttest mit verbundenem
Gerät ist gelaufen, kein Code ist geändert. Fragen an den Nutzer:

1. Genügt Weg A (nur ein Hinweis in der App, dass AirPlay-Geräte zuerst in macOS
   zu verbinden sind), oder soll Weg B umgesetzt werden (Bonjour-Anzeige mit
   Local-Network-Dialog und dem damit verbundenen Review-Risiko)?
2. Soll 4.1 auf das Ergebnis des Echttests mit dem Volumio-Gerät warten, bevor
   über A oder B entschieden wird?
