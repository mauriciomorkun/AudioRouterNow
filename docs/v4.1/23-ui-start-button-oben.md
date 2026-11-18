# 4.1 Nachtrag (UI): Start/Stop-Knopf oben als erkennbarer Knopf

Erstellt: 2026-11-16. Teil des 4.1-Zyklus, nach dem Nachtrag (Doku 14 bis 22).
Betrifft nur die Darstellung und Anordnung des Start/Stop-Knopfes, nicht die Engine.

**Aktuell: Variante C3** (grosser Knopf oben bleibt, Footer-Pille entfernt,
Support-Knopf aufgewertet, eigene Hover-Bubbles im Footer, siehe Abschnitt ganz
unten). Varianten C und C2 bleiben als Verlauf stehen.

- Variante C (die Pille oben in der Statuszeile, der grosse Knopf unten im Footer)
  ist unter `.claude/variants/C1-obere-pille/` gesichert.
- Variante C2 (grosser Knopf oben, Pille im Footer) ist unter
  `.claude/variants/C2-grosser-knopf-oben/` gesichert.

## Entscheidungsstand und Vergleich

**Stand 17.11.2026: Der Nutzer hat C3 mit V2 gewaehlt (C3b).** Alle drei Varianten
lagen fertig im Arbeitsbaum von `release/4.1`, je mit eigener Test-App auf dem Desktop
und eigener Sicherung unter `.claude/variants/`. Der Arbeitsbaum entspricht dem
gewaehlten Stand C3 (plus V2 = C3b). C und C2 sind verworfen und nur noch als Patches
archiviert. Urzustand (P1, nacktes Icon) und die Pruefhilfe (C3 LISTE) standen nicht
zur Wahl. Die folgende Vergleichstabelle bleibt als historischer Verlauf stehen.

| Kriterium | C (Pille oben, grosser Knopf im Footer) | C2 (grosser Knopf oben, Pille im Footer) | C3 (grosser Knopf oben, einzig; Footer eine Reihe) |
|-----------|------------------------------------------|-------------------------------------------|-----------------------------------------------------|
| Erkennbarkeit des Starts | Pille oben plus grosser Knopf unten, beide beschriftet | Grosser Knopf oben immer sichtbar, Pille unten redundant | Ein grosser, beschrifteter Knopf oben, eindeutig |
| Platzbedarf / Fensterhoehe (ImageRenderer-Nachbau) | nicht separat gerendert; Nettohoehe aehnlich C2 (Doku-Abschnitt C2) | volle Liste 621 pt (zwei Footer-Reihen) | volle Liste 589 pt (eine Reihe, rund 40 pt weniger als C2) |
| Aenderungsumfang im Code | `HeaderToggle`-Logik plus Statuszeilen-Pille | zusaetzlich `HeaderTogglePlacement`, Footer in zwei Reihen | `HeaderToggle` komplett entfernt; `FooterTips`, Hover-Bubble, Support-Pille neu |
| Risiko | Footer-Knopf bei langer Liste wieder ausser Sicht (Ausgangsfall) | zwei Start-Elemente, Redundanz; mehr Hoehe | Hover-Bubble und Dynamic-Type-Umbruch nur am Geraet voll belegbar |
| App-Review (Launch at Login) | Checkbox sichtbar, Guideline 2.4.5(iii) erfuellt | Checkbox sichtbar, erfuellt | Checkbox sichtbar, erfuellt; Support als neutraler Knopf, kein Guideline-Risiko (Audit 24) |
| Support-Sichtbarkeit | Icon im Footer | Icon in der Footer-Icon-Gruppe | Mint-Pille mit Herz und Wort "Support", am klarsten |
| Barrierefreiheit | a11y-Label vorhanden | a11y-Label ergaenzt | a11y-Label plus `accessibilityHint` aus `FooterTips`; VoiceOver der Bubble nur am Geraet |
| Am Geraet noch zu pruefen | M1, M2, M2b | M1, M2, M2b | M1, M2, M2b, M2c (Hover), M2d (V2 im C3b) |

**Empfehlung des Dokumentierenden (Einschaetzung, nicht die Entscheidung):** C3.
Begruendung: C3 hat genau einen, gut beschrifteten Start/Stop-Knopf an der Stelle,
die den Ausgangsfall (Footer bei langer Liste ausser Sicht) loest, vermeidet die
Redundanz von C2 (zweites Start-Element), spart Hoehe (eine Footer-Reihe) und macht
den Support-Knopf am klarsten. Die offenen Punkte von C3 (Hover-Bubble, Dynamic-Type-
Umbruch, VoiceOver) sind am Geraet pruefbar und im Audit `24-audit-ui-c3.md` als
"Freigabe mit Auflagen" ohne Blocker eingestuft. Diese Einschaetzung ersetzt die
Messungen M1/M2/M2b/M2c nicht; der Nutzer trifft die Wahl nach dem Test am Geraet.

**Entscheidung: C3 mit V2, 17.11.2026.**

- Gewaehlte Variante: C3 mit V2 (Stand der Test-App "AudioRouterNow 4.1 TEST C3b").
- Datum: 17.11.2026.
- Begruendung (soweit bekannt): C3 gefaellt dem Nutzer am Geraet; die V2-Kennzeichnung
  (hinzugefuegte Ausgaenge mit Haken, ausgegraut, nicht waehlbar) hat er in "TEST C3b"
  am Geraet gesehen, die Scrollbarkeit des "Add device"-Menues mit der Pruefhilfe
  "TEST C3 LISTE" am Geraet bestaetigt. Weitere Begruendungen nicht festgehalten.
- Folgen: C und C2 sind verworfen und nur noch als Patches unter `.claude/variants/`
  archiviert; der obere Knopf ist der einzige Start/Stop-Knopf, Support ist ein
  beschrifteter Knopf, die Hover-Erklaerungen und der einreihige Footer bleiben, V2
  ist Teil der finalen 4.1.
- Danach: Stand C3 mit V2 committen, CHANGELOG/RELEASE_NOTES angleichen (RELEASE_NOTES
  auf den Endstand bringen), Banner im Abschlussbericht und der README-Abschnitt sind
  geschlossen (siehe `README.md`, "Entscheidung: Bedienoberflaeche").

## Problem

Der in 4.1 ergaenzte Start/Stop-Knopf oben in der Statuszeile (Commit `7700c3f`,
Entscheidung E3) war ein nacktes SF-Symbol ohne sichtbare Flaeche und ohne Wort:

- Leerlauf: links ein grauer Punkt mit "No routing active", rechts ein kleines
  gruenes Dreieck (`play.fill`). Es sah wie ein Status-Symbol aus, nicht wie eine
  Schaltflaeche.
- Aktiv: rechts ein kleines gruenes Quadrat (`stop.fill`) neben dem Zaehler
  "CBs 435", ebenfalls ohne Knopfoptik.

Hintergrund: Der obere Knopf existiert, weil zwei Nutzer bei langer Geraeteliste
den Footer-Knopf ("Start Routing" / "Stop Routing") nicht erreichten. Wer den
Footer nicht sieht, muss den oberen Knopf als Bedienelement erkennen. Das war
nicht gegeben.

Belegt durch zwei Screenshots des Nutzers vom 16.11.2026 (Leerlauf und aktiv).

Ziel: Der obere Knopf soll intuitiv als druckbarer Knopf lesbar sein, zum Starten
und zum Stoppen.

## Variantenvergleich

| Variante | Erkennbarkeit | Platzbedarf | Konsistenz zum Footer | Risiko |
|----------|---------------|-------------|------------------------|--------|
| A: Pille mit Icon und Wort ("Start"/"Stop"), gefuellt bei Start, umrandet bei Stop, in beiden Zustaenden | Hoch | Hoch (ca. 62 bis 72 pt). Im aktiven Zustand Konkurrenz mit "CBs 435" und langem Status-Text | Sehr hoch (spiegelt den Footer exakt) | Enge im aktiven Zustand, der Status-Text koennte komprimiert werden |
| B: Runder Icon-Knopf mit Flaeche (gefuellter Mint-Kreis bei Start, umrandeter Kreis bei Stop), 28 pt, kein Wort | Mittel bis hoch | Niedrig (28 x 28 pt fest) | Hoch (Farblogik wie Footer) | Gering, aber Icon allein ist weniger explizit als ein Wort |
| C (gewaehlt): Wort nur im Leerlauf. Leerlauf gefuellte Mint-Pille mit "Start"; aktiv umrandeter runder Stop-Knopf 28 pt ohne Wort | Hoch im Leerlauf, mittel bis hoch aktiv | Mittel: Leerlauf hat viel Platz (kurzer Text), aktiv bleibt kompakt | Hoch | Zwei leicht verschiedene Formen je Zustand, jeweils zustandsgerecht |

### Platzrechnung

Panel fest 320 pt, minus 2 x 14 pt Padding = 292 pt nutzbar. Im aktiven Zustand
teilen sich die Zeile: Status-Punkt (8), "Routing -> N devices", Spacer,
"CBs 435" (monospaced), Knopf. Eine Pille mit Wort "Stop" wuerde hier eng; eine
`HStack` bricht zwar nicht um, sondern komprimiert zuerst den sekundaeren
Status-Text, aber die Callback-Anzeige soll sichtbar bleiben. Im Leerlauf ist der
Text kurz ("No routing active"), dort ist reichlich Platz fuer die Pille mit Wort.

## Gewaehlte Loesung (Variante C)

Begruendung in drei Saetzen: Das Erkennungsproblem ist im Leerlauf am groessten,
weil genau dort der Footer-Knopf bei langer Liste ausser Sicht liegt und der obere
Knopf der einzige sichtbare Startpunkt ist. Deshalb traegt der Leerlauf-Knopf eine
volle Mint-Pille mit dem Wort "Start" (spiegelt den gefuellten Footer-Knopf), wo
der Platz reichlich ist. Im aktiven Zustand genuegt ein deutlich umrandeter runder
Stop-Knopf fester Groesse, der die Callback-Anzeige "CBs" nicht verdraengt.

Die Entscheidung "Aussehen, Wort, aktiv oder nicht" liegt testbar im SPM-Paket
(`AudioRouterKit.HeaderToggle`, `HeaderToggleStyle`, `HeaderTogglePhase`). Die
View `HeaderToggleButton` (im App-Target, in `UI/RoutingControls.swift`) liest nur
ab. Platzierung (rechts in der Statuszeile) und Aktion (gleich dem `RoutingButton`,
kein neuer Controller-Pfad) bleiben wie in E3.

## Zustaende

| Zustand | Aussehen | Aktiv? | Aktion |
|---------|----------|--------|--------|
| Leerlauf mit gewaehlten Ausgaengen | gefuellte Mint-Pille, Icon `play.fill` + "Start", schwarzer Text | ja | `startRouting()` |
| Leerlauf ohne gewaehlte Ausgaenge | gleiche Pille, aber `opacity 0.5` und deaktiviert (deckungsgleich mit `RoutingButton.disabled`) | nein | keine |
| Starting (Uebergang) | reiner Icon-Knopf, Mint-Spinner statt Symbol, deaktiviert | nein | keine |
| Aktiv | umrandeter runder Stop-Knopf, Icon `stop.fill`, Mint-Rand und dezente Mint-Fuellung, kein Wort | ja | `stopRouting()` |
| Fehler | verhaelt sich wie Leerlauf (bietet "Start" an) | abhaengig von Konfiguration | `startRouting()` |

Die Disabled-Bedingung ist `HeaderToggle.isDisabled`, deckungsgleich mit
`RoutingButton.disabled`: im Starting-Zustand immer, sonst nur wenn nichts
konfiguriert ist und nicht gerade aktiv. Keine Aenderung am Footer-Knopf, am
ScrollView (maxHeight 400), am Solo-Knopf oder am Limit-Hinweis (E1, E3, E4, E6
unveraendert).

## Barrierefreiheit

- Trefferflaeche mindestens 28 x 28 pt (`minWidth`/`minHeight`), `contentShape`
  auf die ganze Kapsel.
- Hover-Zustand: Fuellung hellt auf (gefuellt 1.0 -> 0.85, umrandet 0.10 -> 0.18),
  Rand verstaerkt. Kein Dauer-Effekt.
- Pressed-Zustand: dezentes Einsinken (`scaleEffect 0.94`, `opacity 0.85`) ueber
  einen eigenen `ButtonStyle`, Dauer 0.12 s, einmalig pro Druck. Keine
  Dauer-Animation. `accessibilityReduceMotion` ist nicht gesondert noetig, weil
  der Effekt nur waehrend des Drucks laeuft und nicht von selbst wiederholt.
- `.help`-Tooltip: "Start routing" / "Stop routing" / "Connecting devices".
- VoiceOver: `accessibilityLabel` ("Start Routing" / "Stop Routing" /
  "Connecting devices") und `accessibilityHint` (erklaert das Ergebnis). Nicht nur
  das Icon.
- Tastatur/Fokus: nicht veraendert. Der Knopf liegt in der Statuszeile oberhalb
  der Geraeteliste, erhaelt also den Fokus frueh (das war der Tab-Workaround fuer
  die betroffenen Nutzer). Die konkrete Fokus-Reihenfolge ist nur am Geraet mit
  Voll-Tastatur-Zugriff pruefbar, hier nicht geprueft.

## Aenderungen

- `v4/AudioRouterKit/Sources/AudioRouterKit/HeaderToggle.swift` (neu): reine Logik
  `HeaderTogglePhase`, `HeaderToggleStyle`, `HeaderToggle.style(for:)`,
  `HeaderToggle.isDisabled(phase:hasConfiguredOutputs:)`.
- `v4/AudioRouterKit/Tests/AudioRouterKitTests/HeaderToggleTests.swift` (neu):
  9 XCTest-Faelle.
- `v4/AudioRouterNow4/UI/RoutingControls.swift`: neue View `HeaderToggleButton`
  plus privater `HeaderTogglePressStyle` (kein neues File im App-Target).
- `v4/AudioRouterNow4/MenuBarView.swift`: `statusBar` nutzt jetzt
  `HeaderToggleButton`; die alten Hilfsfunktionen `headerToggleIcon` und
  `headerToggleAction` entfernt.

## Tests

- SPM: 60 swift-testing plus 105 XCTest gruen (vorher 96 XCTest, dazu 9 neue
  HeaderToggle-Faelle). Lauf: `DEVELOPER_DIR=.../Xcode.app/... bash v4/scripts/test.sh`.
- App-Build: Release ohne Apple-Signatur, siehe Abschnitt Testversion.

## Was nicht geprueft ist

- Echtes Aussehen in der Menueleiste (Pille, Rand, Hover, Pressed) am Geraet.
- VoiceOver-Ausgabe und Vollbild-Tastatur-Fokus-Reihenfolge am Geraet.
- Verhalten bei sehr langem Status-Text zusammen mit der Pille auf einem kleinen
  Bildschirm (nur durch die Layout-Logik begruendet, nicht gemessen).

## Arbeitsstand (Variante C, historisch)

- Logik im Kit plus Tests geschrieben, Tests gruen (60 plus 105): erledigt.
- View umgebaut (`HeaderToggleButton`, `HeaderTogglePressStyle`), `statusBar`
  umgestellt, alte Hilfsfunktionen entfernt: erledigt.
- Dieses Dokument angelegt: erledigt.
- App-Build (Debug, `CODE_SIGNING_ALLOWED=NO`, in /tmp-Kopie): BUILD SUCCEEDED,
  keine Warnung bei HeaderToggle.
- Visuelle Pruefung per `ImageRenderer`: erledigt. Die vier Zustaende plus langer
  Status-Text rendern ohne Umbruch oder Abschneiden; der Knopf ist als Knopf
  lesbar. Das ist ein Nachbau der Statuszeile, nicht die echte App in der
  Menueleiste.
- README-Inhaltstabelle, CHANGELOG (Rubrik Changed), 09-final-report
  (Nachtrag-Absatz plus M1/M2 erweitert, neue Zeile M2b): erledigt.
- Testversion neu gebaut: erledigt (Ablage als "AudioRouterNow 4.1 TEST (neu).app",
  weil die alte Testversion beim Nutzer lief und nicht ersetzt werden durfte).
- LIES-MICH aktualisiert, git-Status ausgegeben: erledigt.
- Nicht geprueft: echtes Aussehen in der Menueleiste, VoiceOver-Ausgabe,
  Tastatur-Fokus-Reihenfolge, Verhalten auf kleinem Bildschirm. Diese bleiben den
  Messpunkten M1/M2/M2b am Geraet vorbehalten.

---

# Variante C2 (aktuell): Positionen getauscht

Erstellt: 2026-11-16, nach Variante C. Der Nutzer mochte die C-Optik, wuenschte aber
den Tausch: der grosse Knopf (frueher unten im Footer) nach ganz oben, dorthin wo in
C die Pille sass; die Pille nach unten in den Footer. Den Footer dabei aufraeumen,
die Pille dort weiterhin als Start-Knopf erkennbar halten. Keine Funktion verlieren.

## Wunsch (Zitat sinngemaess)

"Der grosse Start-Routing-Knopf, der unten im Footer ist, soll dahin, wo jetzt die
Play-Pille ist, also ganz oben. Und die Play-Pille soll unten im Footer sein. Den
Footer aufraeumen, die Pille so gestalten, dass sie als Play-Pille erkennbar und
intuitiv nutzbar bleibt."

## Layout

Reihenfolge von oben nach unten (ASCII, Panel-Breite 320 pt):

```
Leerlauf mit Auswahl              Aktiv                              Leerlauf ohne Auswahl
┌──────────────────────────┐     ┌──────────────────────────┐       ┌──────────────────────────┐
│  ~~~ Wellen-Header ~~~    │     │  ~~~ Wellen-Header ~~~    │       │  ~~~ Wellen-Header ~~~    │
│ • No routing active       │     │ • Routing → 2 devices  CBs 435│   │ • No routing active       │
│ ┌──────────────────────┐  │     │ ┌──────────────────────┐  │       │ ┌──────────────────────┐  │
│ │  ▶  Start Routing     │  │     │ │  ■  Stop Routing      │  │       │ │  ▶  Start Routing     │  │ (gedimmt 0.5,
│ └──────────────────────┘  │     │ └──────────────────────┘  │       │ └──────────────────────┘  │  deaktiviert)
│ ┌─ ScrollView max 400 ─┐  │     │ ┌─ ScrollView max 400 ─┐  │       │ ┌─ ScrollView max 400 ─┐  │
│ │ ☐ Gerät 1            │  │     │ │ Volume ───────── 72% │  │       │ │ ☐ Gerät 1            │  │
│ │ ☐ Gerät 2 …          │  │     │ │ ▸ Gerät 1  [Solo]    │  │       │ │ ☐ Gerät 2 …          │  │
│ └──────────────────────┘  │     │ └──────────────────────┘  │       │ └──────────────────────┘  │
│ ─────────────────────────│     │ ─────────────────────────│       │ ─────────────────────────│
│ (⬤▶ Start)         Quit   │     │ (⬤■ Stop)          Quit   │       │ (⬤▶ Start, dim)    Quit   │
│ ───────────────────────── │     │ ───────────────────────── │       │ ───────────────────────── │
│ ☑ Launch  ♥  🔒  🔇  🐞    │     │ ☑ Launch  ♥  🔒  🔇  🐞    │       │ ☑ Launch  ♥  🔒  🔇  🐞    │
└──────────────────────────┘     └──────────────────────────┘       └──────────────────────────┘
```

Weitere Zustaende:

- **Starting (Uebergang):** Grosser Knopf oben zeigt Mint-Spinner plus "Connecting…",
  deaktiviert. Footer-Pille: Spinner plus Wort "Connecting", deaktiviert. Statuszeile
  "Connecting devices…" mit pulsierendem Punkt.
- **Fehler:** verhaelt sich wie Leerlauf (beide bieten "Start"). Zusaetzlich die
  rote `errorSection` zwischen grossem Knopf und ScrollView.
- **Langer Status-Text:** Im Leerlauf ("No routing active", kurz) kein Problem. Der
  Text liegt jetzt allein in der Statuszeile (kein Knopf mehr daneben), hat also mehr
  Platz als in C. Im aktiven Zustand teilen sich Text und "CBs 435" die Zeile wie
  bisher; der grosse Knopf ist eine eigene Zeile darunter und konkurriert nicht.
- **Lange Geraeteliste:** ScrollView `maxHeight: 400` unveraendert. Grosser Knopf und
  Footer liegen ausserhalb und bleiben sichtbar.

## Footer-Aufraeumen

Der Footer hat jetzt zwei Reihen statt einer (plus den weiter oben aufklappbaren
TipJar-Bereich). Reihe 1: die Start/Stop-Pille links (primaer), Quit rechts. Ein
`Divider`. Reihe 2: Launch at Login links (Checkbox, sichtbar), rechts die
sekundaeren Icons Support, Lock, Exclusive, Bug als kompakte Gruppe.

Was die bisherigen Footer-Elemente tun (am Code belegt, `UI/RoutingControls.swift`,
`FooterRow`):

| Element | Funktion (Controller) | vorher | nachher | Grund |
|---------|------------------------|--------|---------|-------|
| Start/Stop-Pille | `startRouting()` / `stopRouting()` ueber `HeaderToggle` | oben in der Statuszeile (C) | Footer Reihe 1 links, primaer, mit Wort in jedem Zustand | Wunsch C2: Pille nach unten |
| Grosser Knopf | `RoutingButton`, gleiche Aktion | Footer unten (C) | oben unter der Statuszeile, ausserhalb ScrollView | Wunsch C2: grosser Knopf nach oben; bleibt immer sichtbar |
| Launch at Login | `launchAtLogin` / `requestLaunchAtLoginEnable()` Consent-Gate | Footer, eine Reihe | Footer Reihe 2 links, sichtbar, Checkbox | Guideline 2.4.5(iii): sichtbar und bedienbar, nicht versteckt |
| Support (Herz) | klappt `TipJarView` auf | Textlabel "Support"/"Hide" | reines Icon (Herz/x) mit Tooltip und a11y-Label | Platz in Reihe 2; Funktion und Sichtbarkeit unveraendert |
| Lock | `lockOutputDevice` (Stable Output Mode) | Icon | Icon, groesser (12 pt), a11y-Label ergaenzt | nur Anordnung, nicht versteckt |
| Exclusive | `exclusiveRouting` (CASE-008) | Icon | Icon, groesser, a11y-Label ergaenzt | nur Anordnung, nicht versteckt |
| Bug | `openBugReport()` | Icon | Icon, groesser, a11y-Label ergaenzt | nur Anordnung, nicht versteckt |
| Quit | `NSApplication.shared.terminate` | Textbutton rechts | Reihe 1 rechts, Tooltip ergaenzt | zur Pille gruppiert |

Kein Element wandert in ein verstecktes Overflow-Menue. Begruendung: Lock, Exclusive
und Bug sind je ein einzelner Klick und waeren in einem Menue schlechter erreichbar;
es gibt keinen Platzzwang, der das rechtfertigt. Aufgeraeumt wird nur durch die
Zwei-Reihen-Anordnung und einheitliche Icon-Groessen (12 pt). Support behaelt sein
Verhalten (klappt den TipJar auf), nur das Textlabel wurde zum Icon mit Tooltip, weil
Reihe 2 sonst zu breit wird; die Sichtbarkeit bleibt (Herz-Icon in Mint).

## Pille im Footer: weiterhin als Start-Knopf erkennbar

Die Footer-Pille nutzt dieselbe View `HeaderToggleButton`, jetzt mit
`placement: .footer`. Unterschied zur Statuszeilen-Variante (C1): im Footer traegt
die Pille in **jedem** Zustand ein Wort (Leerlauf "Start", aktiv "Stop", Starting
"Connecting"), weil im Footer Platz ist und keine "CBs"-Anzeige daneben konkurriert.
In der Statuszeile trug der aktive Knopf bewusst kein Wort (CBs-Platz); diese Regel
gilt im Footer nicht mehr. Erhalten bleiben: Mint-Fuellung im Leerlauf mit
`play.fill` plus "Start", umrandeter Zustand beim Routen, Mindest-Trefferflaeche
28 x 28 pt (`minWidth`/`minHeight`), Hover (Fuellung hellt auf, Rand verstaerkt),
Pressed (einmaliges Einsinken, keine Dauer-Animation), `.help`-Tooltip,
`accessibilityLabel`/`accessibilityHint`, Dimmen auf 0.5 und Deaktivieren ohne
Auswahl. Die Pille ist im Footer breiter als in der Statuszeile, weil sie das Wort
"Stop"/"Connecting" jetzt auch aktiv traegt; sie bricht nicht um, weil rechts nur
"Quit" steht und ein `Spacer` dazwischen liegt.

## Hoehenrechnung (kleiner Bildschirm)

Grobe Schaetzung der Inhaltshoehe (Panel 320 pt breit, feste Werte aus dem Code):

| Block | Hoehe |
|-------|-------|
| Wellen-Header | ~56 pt (unveraendert) |
| Statuszeile (8+8 Padding + Text) | ~33 pt |
| Grosser Knopf (`RoutingButton`, 9+9 Padding + Text, dazu top 2 + bottom 8) | ~44 pt |
| ScrollView | bis 400 pt (gedeckelt) |
| Divider | ~1 pt |
| Footer (Padding 14+14, Reihe 1 ~28, Divider ~9, Reihe 2 ~17, Spacing 2x8) | ~98 pt |

- **Leerlauf, kurze Liste (ScrollView ~120 pt):** 56+33+44+120+1+98 ≈ 352 pt.
- **Volle Liste (ScrollView 400 pt):** 56+33+44+400+1+98 ≈ 632 pt.

Unter der Menueleiste stehen auf einem 13-Zoll-MacBook etwa 700 pt zur Verfuegung.
632 pt bleiben darunter. Die bisherige Grenze `maxHeight: 400` (aus 4.1 P1, E1) wird
daher **nicht** gesenkt. Gegenueber C ist die Nettohoehe aehnlich: oben kommt der
grosse Knopf dazu (~44 pt), der Footer verliert den grossen Knopf aus seinem VStack,
gewinnt aber Reihe 1 mit Pille plus Divider (~37 pt). Die Rechnung ist eine
Schaetzung aus den festen Padding- und Schriftwerten, nicht am Geraet gemessen.

## Barrierefreiheit und Fokus

- Beide Knoepfe (oben gross, unten Pille) rufen dieselbe Aktion ueber den
  `EngineController` auf (`startRouting()` / `stopRouting()`). Kein doppelter
  Start/Stop: der `starting`-Zustand deaktiviert beide (die Disabled-Logik
  `HeaderToggle.isDisabled` bzw. `RoutingButton.disabled` ist in diesem Zustand
  immer true), wie schon in C. Schnelle Doppelklicks laufen damit in denselben
  `isStarting`-Schutz wie bisher.
- Tab-Fokus: Der grosse Knopf liegt jetzt direkt unter der Statuszeile, noch vor dem
  ScrollView und dem Footer. Er erhaelt den Fokus im Tab-Weg also frueh (das war der
  Workaround fuer die betroffenen Nutzer). Die genaue Fokus-Reihenfolge ist nur am
  Geraet mit Voll-Tastatur-Zugriff pruefbar, hier nicht geprueft.
- Die Footer-Icons (Support, Lock, Exclusive, Bug) haben jetzt zusaetzlich ein
  `accessibilityLabel`, weil sie reine Icons ohne sichtbaren Text sind.

## Aenderungen (C2)

- `v4/AudioRouterKit/Sources/AudioRouterKit/HeaderToggle.swift`: neues `enum
  HeaderTogglePlacement` (`statusBar`, `footer`), neue Ueberladung
  `style(for:placement:)`. Die alte Signatur `style(for:)` bleibt und entspricht
  `placement: .statusBar` (kein Verhaltenswechsel fuer C1-Pfade).
- `v4/AudioRouterKit/Tests/AudioRouterKitTests/HeaderToggleTests.swift`: 5 neue
  XCTest-Faelle (Default gleich Statuszeile, Footer traegt Wort aktiv/starting,
  Leerlauf behaelt Wort, Platzierung aendert Aktion/Icon/Fuellung nicht).
- `v4/AudioRouterNow4/UI/RoutingControls.swift`: `HeaderToggleButton` bekommt
  `placement` (Default `.statusBar`). `FooterRow` bekommt `state: ARNUIState`,
  zwei Reihen statt einer, Pille in Reihe 1, Support als Icon.
- `v4/AudioRouterNow4/MenuBarView.swift`: grosser `RoutingButton` jetzt direkt unter
  der Statuszeile (ausserhalb ScrollView), aus der Statuszeile entfernt;
  `FooterRow(state: ui)` ohne eigenen `RoutingButton` darueber.

Kein neues File im App-Target. Engine, ScrollView-Grenze, Solo, Limit-Hinweis,
Volume, Fehler-/TCC-Abschnitte unveraendert.

## Tests (C2)

- SPM: 60 swift-testing plus 110 XCTest gruen (vorher 105; 5 neue
  HeaderToggle-Placement-Faelle). Lauf:
  `DEVELOPER_DIR=.../Xcode.app/... bash v4/scripts/test.sh`.
- App-Build: Debug ohne Apple-Signatur, BUILD SUCCEEDED (siehe Arbeitsstand C2).
- Visuell per `ImageRenderer`: Nachbau des gesamten Fensters in den Zustaenden
  Leerlauf mit Auswahl, Leerlauf ohne Auswahl, aktiv, langer Status-Text, lange
  Liste. Das ist ein Nachbau, nicht die echte App in der Menueleiste.

## Sicherung von Variante C

Vor der Umstellung auf C2 wurde Variante C vollstaendig gesichert unter
`.claude/variants/C1-obere-pille/` (gitignored):

- `C1.patch` (`git diff` des C-Arbeitsbaums gegen HEAD),
- `23-ui-start-button-oben.md` (C-Stand des Dokuments),
- `HeaderToggle.swift` und `HeaderToggleTests.swift` (C-Stand).

Verifiziert: Der Patch wendet sich sauber auf einen frischen HEAD-Baum an
(`git apply --check` auf einer /tmp-Kopie: OK). Rueckweg zu C: Arbeitsbaum
zuruecksetzen und `C1.patch` anwenden.

## Was bei C2 nicht geprueft ist

- Echtes Aussehen in der Menueleiste (grosser Knopf oben, Pille im Footer, Hover,
  Pressed, Rand) am Geraet.
- VoiceOver-Ausgabe und die Tab-Fokus-Reihenfolge am Geraet.
- Die Hoehenrechnung ist geschaetzt aus festen Werten, nicht auf einem 13-Zoll-Geraet
  gemessen. Ob das volle Panel (volle Liste) wirklich auf den Bildschirm passt, ist
  am Geraet zu bestaetigen (Messpunkt M1).
- Verhalten bei sehr langem Status-Text zusammen mit der aktiven "CBs"-Anzeige auf
  kleinem Bildschirm (nur aus der Layout-Logik begruendet).

## Arbeitsstand (C2)

- Kit erweitert (`HeaderTogglePlacement`, `style(for:placement:)`) plus 5 Tests,
  Tests gruen (60 plus 110): erledigt.
- View umgebaut (`HeaderToggleButton.placement`, `FooterRow(state:)` mit zwei Reihen,
  grosser Knopf oben in `MenuBarView`, Pille aus der Statuszeile entfernt): erledigt.
- Dieses Dokument um den C2-Abschnitt erweitert, C als Verlauf behalten, aktueller
  Stand markiert: erledigt.
- App-Build (Debug, `CODE_SIGNING_ALLOWED=NO`, /tmp-Kopie): BUILD SUCCEEDED, keine
  Fehler in MenuBarView/RoutingControls/HeaderToggle.
- Visuelle Pruefung per `ImageRenderer`: erledigt. Alle fuenf Zustaende (Leerlauf mit
  Auswahl, Leerlauf ohne Auswahl, aktiv, langer Status-Text, lange Liste) rendern
  ohne Umbruch der Pille, ohne Abschneiden, Footer nicht zu eng. Gerenderte Hoehen:
  idle 302 pt, aktiv 338 pt, langer Status 368 pt, lange Liste (18 Zeilen) 621 pt,
  alle unter 700 pt. Der grosse Knopf oben und der Footer bleiben bei langer Liste
  sichtbar. Nachbau, nicht die echte App: WaveHeaderView, ARNColor und die
  Menueleisten-Darstellung sind nicht abgebildet, die Mint-Farbe ist angenaehert.
- CHANGELOG (Changed), README, 09-final-report (M1/M2/M2b auf C2): erledigt.
- Testversion "AudioRouterNow 4.1 TEST C2.app" nach ~/Desktop: erledigt.
  Release-Build ohne Apple-Signatur, Bundle-ID `com.mauriciomorkun.audiorouternow.test`,
  Name "AudioRouterNow 4.1 TEST C2", ad-hoc signiert mit app-sandbox und
  device.audio-input plus Hardened Runtime, `codesign --verify --deep --strict`
  valid, Entitlements vorhanden, universal (x86_64+arm64), Info.plist 4.1 (11). Die
  beiden anderen Test-Apps auf dem Desktop unberuehrt. Smoke-Test: keine andere
  Instanz lief, App startete crashfrei (5 s) und wurde beendet. LIES-MICH um den
  C2-Abschnitt ergaenzt.
- Sicherung von C unter `.claude/variants/C1-obere-pille/`: erledigt und verifiziert.
- /tmp-Zwischenstaende aufgeraeumt, kein Commit, kein Push, kein Tag.

---

# Variante C3 (aktuell): Footer-Pille entfernt, Support aufgewertet, Hover-Bubbles

Erstellt: 2026-11-16, nach Variante C2. Drei Wuensche des Nutzers:

1. Der grosse "Start Routing"-Knopf bleibt oben, genau wie in C2 positioniert.
2. Die kompakte Start/Stop-Pille im Footer (Reihe 1 links) wird entfernt. Der
   Nutzer findet sie dort nutzlos, weil der grosse Knopf oben schon immer sichtbar
   ist. Der grosse Knopf oben ist danach der einzige Start/Stop-Knopf im Panel
   (das Menueleisten-Symbol bietet keinen Toggle; E3 betraf nur den Knopf im
   Panel, das Statusbar-Icon oeffnet nur das Panel und bleibt unveraendert).
3. Der Support-Knopf (Herz) soll etwas mehr in den Vordergrund, ohne aufdringlich
   zu sein.
4. Beim Hovern ueber die Footer-Symbole soll eine kleine Textbox erklaeren, was
   das Symbol tut.

Keine Funktion ausser der Footer-Pille wird entfernt. Launch at Login, Support,
Lock, Exclusive, Bug und Quit bleiben alle sichtbar und bedienbar.

## 1. Entfernen der Footer-Pille (tote Logik pruefen)

Die Footer-Pille war die einzige Nutzung von `HeaderToggleButton` mit
`placement: .footer`. Der grosse Knopf oben ist ein `RoutingButton`, kein
`HeaderToggleButton`. Nach dem Entfernen der Footer-Pille wird
`HeaderToggleButton` **nirgends mehr** verwendet (Suche:
`grep -rn HeaderToggleButton v4/AudioRouterNow4` ergibt nach der Aenderung keinen
Treffer ausserhalb der Definition). Damit ist auch `HeaderTogglePlacement`,
`HeaderToggle.style(for:placement:)`, die alte `HeaderToggle.style(for:)`, der
`HeaderTogglePressStyle` und die gesamte `HeaderToggle.swift` samt Tests ungenutzt.

Entscheidung: Die komplette `HeaderToggle`-Logik und ihre Tests werden entfernt,
weil sie nach C3 keine lebende Nutzung mehr haben (keine toten Codepfade
hinterlassen). Der grosse Knopf oben bleibt der vorhandene `RoutingButton`, der
alle geforderten Zustaende schon abdeckt: Start (idle/error, gefuellte Mint-Pille
"Start Routing"), Connecting (starting, Spinner, deaktiviert), Stop (active,
umrandet "Stop Routing"), gedimmt und deaktiviert ohne Auswahl
(`disabled = state == .starting || (outputConfigs.isEmpty && !state.isActive)`),
Fehler (verhaelt sich wie idle). Es geht also keine Funktion des oberen Knopfes
verloren. Das Entfernen betrifft nur die Pille und die nur fuer sie gebaute
Kit-Logik.

Betroffene Dateien beim Entfernen:
- `v4/AudioRouterNow4/UI/RoutingControls.swift`: `HeaderToggleButton` und
  `HeaderTogglePressStyle` geloescht.
- `v4/AudioRouterKit/Sources/AudioRouterKit/HeaderToggle.swift`: geloescht.
- `v4/AudioRouterKit/Tests/AudioRouterKitTests/HeaderToggleTests.swift`: geloescht.
- `v4/AudioRouterNow4/MenuBarView.swift`: unveraendert beim grossen Knopf; nur die
  `FooterRow` aendert sich (siehe Layout).

## 2. Support-Knopf: Brainstorm und Bewertung

Rahmen (App-Review und Stil): Der Tip Jar ist ein freiwilliger In-App-Kauf
(`TipJarView`, zwei StoreKit-Produkte Coffee und Beer). Es wird nichts
freigeschaltet, die App ist ohne Kauf voll nutzbar. Guideline-Risiko entsteht nur
durch eine irrefuehrende oder aufdringliche Formulierung. Der vorhandene,
akzeptierte Wortlaut ist neutral ("Support AudioRouterNow", Tooltip
"Support the developer", Danke "Thank you! It means a lot"). C3 bleibt bei dieser
Sprache. Leitplanken: keine Dauer-Animation, kein Badge, kein Pulsieren, keine
Zaehler, keine erneute Aufforderung, keine Superlative, neutraler englischer Text,
barrierefrei.

Vier Varianten:

| Variante | Beschreibung | Verstaendlichkeit | Aufdringlichkeit | Platz | App-Review-Risiko | Palette (Mint) |
|----------|--------------|-------------------|------------------|-------|-------------------|----------------|
| S1: Herz plus Wort "Support" als dezente Mint-Pille mit duennem Rand, links in Reihe 2 vor der Icon-Gruppe | Icon und Wort zusammen | Hoch (Wort erklaert das Herz) | Gering bis mittel (eine ruhige Pille, kein Effekt) | Mittel (Wort braucht ca. 60 bis 70 pt) | Gering (neutrales Wort "Support", nichts freigeschaltet) | Hoch (Mint-Pille wie die obere Start-Pille, konsistent) |
| S2: Herz plus "Tip" oder "Say thanks" | Icon und Kurzwort | Hoch, aber "Tip"/"Say thanks" wirkt staerker nach Geldaufforderung | Mittel bis hoch ("Say thanks" ist appellierender) | Gering ("Tip") bis mittel | Mittel (naeher an direkter Spendenaufforderung) | Hoch |
| S3: Eigener Platz am linken Rand mit mehr Gewicht als die Icons (groesser, abgesetzt), reines Herz | Mittel (Herz allein bleibt mehrdeutig) | Gering (nur Position, kein Appell) | Gering | Gering | Mittel (Groesse ohne Wort kann wie Werbung wirken) |
| S4: reines Herz, dezente Fuellung erst beim Hover plus Tooltip | Niedrig bis mittel (ohne Hover wie bisher mehrdeutig) | Sehr gering | Sehr gering | Gering | Niedrig, aber loest das Verstaendnisproblem nicht ("etwas mehr in den Vordergrund" verfehlt) |

**Gewaehlt: S1** (Herz plus Wort "Support" als dezente Mint-Pille mit duennem
Rand). Begruendung in drei Saetzen: Das Wort "Support" macht das Herz sofort
verstaendlich und hebt den Knopf sichtbar hervor, ohne mit Animation, Badge oder
Zaehler aufdringlich zu werden. Die Mint-Pille spiegelt die obere Start-Pille und
bleibt damit in der Palette konsistent. Der Wortlaut "Support" ist der schon von
App Review akzeptierte, neutrale Begriff und traegt kein Guideline-Risiko, weil
nichts freigeschaltet wird und keine wiederholte Aufforderung entsteht.

Verworfen in einer Zeile: S2 (Wort appellierender, naeher an direkter
Geldaufforderung), S3 (Herz allein bleibt mehrdeutig, Groesse ohne Wort kann
werblich wirken), S4 (loest das Verstaendnisproblem nicht, bleibt zu versteckt).

Umsetzung S1: Die Support-Pille zeigt im eingeklappten Zustand ein Herz plus
"Support" (Mint-Text, dezente Mint-Fuellung `opacity 0.10`, duenner Mint-Rand
`opacity 0.35`). Beim Aufklappen des Tip Jar wechselt sie auf ein X plus "Close"
(sekundaere Farbe), damit klar ist, dass derselbe Knopf wieder schliesst. Keine
Dauer-Animation; die Fuellung hellt nur beim Hover leicht auf (0.10 auf 0.16).
`accessibilityLabel` bleibt "Support the developer" bzw. "Hide support".

## 3. Hover-Erklaerungen: Verfahren und technische Pruefung

### Technische Annahme zu `.help` (NSToolTip)

`.help(_:)` bildet auf macOS auf NSToolTip ab. Zwei bekannte Einschraenkungen:
der Tooltip erscheint erst nach ca. 1 Sekunde, und NSToolTip ist an das
Key-Window gebunden. Ein `MenuBarExtra(.window)`-Panel aktiviert die App nicht
zwingend und ist oft nicht das Key-Window; dann erscheint der System-Tooltip
verzoegert oder gar nicht. Zusaetzlich wird eine Tooltip-Box, die ueber den
Panel-Rand ragt, abgeschnitten.

Belegt ist aus der Apple-Doku (`View/help(_:)`) nur, dass `.help` einen
Hilfe-Tooltip beim Hover zeigt und auf macOS am prominentesten ist; die Doku
nennt die Key-Window-Bindung nicht ausdruecklich. Die Key-Window-Abhaengigkeit
und die 1-Sekunden-Verzoegerung von NSToolTip sind langjaehriges, aber hier nicht
aus einer einzelnen Apple-Quelle hart belegtes AppKit-Verhalten. Statt die
Annahme per Experiment zu pruefen (ein Experiment im nackten Fenster bildet das
echte, nicht-aktivierende MenuBarExtra-Panel ohnehin nicht ab, waere also kein
gueltiger Beleg), wird das Verfahren so gewaehlt, dass es von NSToolTip
**unabhaengig** ist.

### Entscheidung: Verfahren (a), eigene SwiftUI-Hover-Bubble im Fenster

Gewaehlt ist (a): eine eigene SwiftUI-Hover-Bubble innerhalb des Panels. Grund:
Sie haengt nicht am Key-Window und nicht an NSToolTip, erscheint also auch im
nicht-aktivierenden Panel, und sie laesst sich am Fensterrand clampen, sodass
nichts abgeschnitten wird. (b) (feste Hinweiszeile) waere robust, kostet aber
dauerhaft Hoehe und wirkt statisch; (c) (`.help` behalten) ist genau das
unzuverlaessige Verhalten. (a) ist nur dann schlechter als (b), wenn Clamping
oder Ausblenden flackern; beides ist hier bewusst einfach gehalten (siehe unten),
daher (a).

Genau EIN Verfahren: An den Footer-Elementen mit eigener Bubble wird `.help`
**entfernt** (kein Doppel-Tooltip). `accessibilityLabel` und, wo sinnvoll,
`accessibilityHint` bleiben fuer VoiceOver erhalten (die Bubble ist rein visuell).

Technischer Entwurf der Bubble:
- Ein `@State var hoveredTip: FooterTip?` in `FooterRow`. Jedes Footer-Element
  setzt beim `onHover` nach einer kurzen Verzoegerung (0.35 s) seine `FooterTip`,
  beim Verlassen loescht es sie (nur wenn es noch die aktuelle ist, gegen
  Flackern beim Wechsel zwischen Icons).
- Die Bubble liegt als `overlay(alignment: .top)` ueber der Footer-Reihe mit
  hohem `zIndex`, erscheint **ueber** den Icons (der Footer liegt unten im Panel,
  nach unten waere kein Platz).
- Horizontales Clamping: Ein `GeometryReader` misst die Panel-Breite; die Bubble
  wird mit einem berechneten `offset` so verschoben, dass sie zwischen linkem und
  rechtem Rand (mit 8 pt Puffer) bleibt. Die Ankerposition je Element kommt aus
  einer `anchorPreference`/`PreferenceKey`, die die Mitte des gehoverten Elements
  im Footer-Koordinatenraum meldet.
- Ausblenden: beim Verlassen des Elements, beim Klick (die Aktion schliesst den
  Hover-Zustand), und beim Schliessen des Panels (die View wird nicht abgebaut,
  aber `onDisappear` bzw. ein Reset beim erneuten `onAppear` setzt `hoveredTip`
  auf `nil`). Kein Dauer-Effekt, nur ein kurzes `opacity`-Ein/Aus (0.12 s).

Die Bubble-Texte liegen testbar im Kit (`FooterTips` in neuer Datei
`FooterTips.swift`), mit Tests (nicht leer, Laenge unter 90 Zeichen, kein
Gedankenstrich, kein " -- ", kein Superlativ per Wortliste).

### Tooltip-Texte (englisch, sachlich, am Code belegt)

Bedeutung am Code geprueft (`EngineController`, `FooterRow`):

- **Support** (Herz, `showTipJar`): oeffnet den Tip Jar (freiwilliger IAP).
  Text: "Opens the tip jar. Tipping is optional and unlocks nothing." (<90).
- **Lock** (`lockOutputDevice`, Stable Output Mode): verhindert, dass macOS das
  Ausgabegeraet waehrend des Routings wechselt (z.B. bei Bluetooth-Verbindung).
  Text: "Keeps macOS from switching the output device while routing." (<90).
- **Exclusive** (durchgestrichener Lautsprecher, `exclusiveRouting`, CASE-008):
  nur die ausgewaehlten Geraete spielen, der Default bleibt stumm.
  Text: "Only selected devices play. The default output stays silent." (<90).
- **Bug** (`openBugReport`): oeffnet eine vorausgefuellte E-Mail mit App-Version
  und Systemdaten. Text: "Opens a pre-filled bug report email with version info." (<90).
- **Quit** (`terminate`): beendet die App. Text: "Quits AudioRouterNow." (<90).
- **Launch at Login** (`requestLaunchAtLoginEnable`): startet die App beim
  Anmelden. Text: "Starts AudioRouterNow automatically when you log in." (<90).

Alle Texte: ein Satz, kein Gedankenstrich, kein " -- ", kein Superlativ, keine
Aussage ueber das Audio-Ergebnis, die der Code nicht stuetzt.

## 4. Neues Footer-Layout (ohne Pille)

Ohne die Start/Stop-Pille wird Reihe 1 frei. Neues Layout: eine ruhige Zeile. Die
sekundaeren Elemente liegen alle in einer Reihe, Launch at Login links (Checkbox,
sichtbar), dann die Support-Pille (S1), dann die Icon-Gruppe Lock, Exclusive, Bug,
und rechts Quit. Begruendung: Ohne die Pille braucht es keine zweite Reihe mehr;
eine Reihe ist ruhiger und spart Hoehe. Launch at Login und Quit bleiben an ihren
gewohnten Enden.

```
Leerlauf mit Auswahl                 Aktiv                               Leerlauf ohne Auswahl
┌──────────────────────────┐        ┌──────────────────────────┐        ┌──────────────────────────┐
│  ~~~ Wellen-Header ~~~    │        │  ~~~ Wellen-Header ~~~    │        │  ~~~ Wellen-Header ~~~    │
│ • No routing active       │        │ • Routing → 2 devices CBs 435│     │ • No routing active       │
│ ┌──────────────────────┐  │        │ ┌──────────────────────┐  │        │ ┌──────────────────────┐  │
│ │  ▶  Start Routing     │  │        │ │  ■  Stop Routing      │  │        │ │  ▶  Start Routing     │  │ (gedimmt 0.5,
│ └──────────────────────┘  │        │ └──────────────────────┘  │        │ └──────────────────────┘  │  deaktiviert)
│ ┌─ ScrollView max 400 ─┐  │        │ ┌─ ScrollView max 400 ─┐  │        │ ┌─ ScrollView max 400 ─┐  │
│ │ ☐ Gerät 1            │  │        │ │ Volume ───────── 72% │  │        │ │ ☐ Gerät 1            │  │
│ │ ☐ Gerät 2 …          │  │        │ │ ▸ Gerät 1  [Solo]    │  │        │ │ ☐ Gerät 2 …          │  │
│ └──────────────────────┘  │        │ └──────────────────────┘  │        │ └──────────────────────┘  │
│ ───────────────────────── │        │ ───────────────────────── │        │ ───────────────────────── │
│ ☑ Launch (♥ Support) 🔒🔇🐞  Quit │  │ ☑ Launch (♥ Support) 🔒🔇🐞  Quit │  │ ☑ Launch (♥ Support) 🔒🔇🐞  Quit │
└──────────────────────────┘        └──────────────────────────┘        └──────────────────────────┘
```

Hover-Bubble (schematisch, erscheint ueber dem gehoverten Element, am Rand
geclampt):

```
          ┌───────────────────────────────┐
          │ Only selected devices play.   │   ← Bubble ueber dem Exclusive-Icon
          │ The default output stays …    │
          └───────────────▼───────────────┘
│ ☑ Launch (♥ Support) 🔒 [🔇] 🐞   Quit │
```

### Hoehenrechnung

Gegenueber C2 entfaellt die Footer-Reihe 1 (Pille) samt Divider. Der Footer hat
jetzt nur eine Reihe.

| Block | Hoehe |
|-------|-------|
| Wellen-Header | ~56 pt (unveraendert) |
| Statuszeile | ~33 pt |
| Grosser Knopf oben (`RoutingButton`, top 2 + bottom 8) | ~44 pt |
| ScrollView | bis 400 pt (gedeckelt) |
| Divider | ~1 pt |
| Footer (Padding 14+14, eine Reihe ~28) | ~56 pt |

- **Leerlauf, kurze Liste (ScrollView ~120 pt):** 56+33+44+120+1+56 ≈ 310 pt.
- **Volle Liste (ScrollView 400 pt):** 56+33+44+400+1+56 ≈ 590 pt.

C2 hatte idle ~302 pt und volle Liste 621 pt (gemessen per ImageRenderer). C3
spart durch die wegfallende zweite Footer-Reihe plus deren Divider rund 40 pt in
der Hoehe; die volle Liste liegt nun bei etwa 580 bis 590 pt, klar unter 700 pt.
Die Grenze `maxHeight: 400` bleibt unveraendert. Die Rechnung ist eine Schaetzung
aus festen Padding- und Schriftwerten plus den gerenderten C2-Hoehen, nicht am
Geraet gemessen.

## 5. Barrierefreiheit (C3)

- Grosser Knopf oben: unveraendert (`RoutingButton`), Tooltip und a11y waren dort
  schon vorhanden (`RoutingButton` nutzt keinen eigenen Tooltip, nur sichtbaren
  Text; Text ist selbsterklaerend).
- Support-Pille: `accessibilityLabel` "Support the developer" / "Hide support".
  Mindest-Trefferflaeche 28 pt Hoehe (Pille), `contentShape`.
- Footer-Icons und Launch/Quit: `accessibilityLabel` (und wo sinnvoll Hint)
  bleiben. Die Hover-Bubble ist rein visuell und ersetzt das `.help` an genau den
  Elementen, die eine Bubble bekommen; VoiceOver liest weiter das a11y-Label.
- Hover-Bubble erscheint mit 0.35 s Verzoegerung, verschwindet beim Verlassen,
  Klick und Panel-Schliessen. Keine Dauer-Animation, nur kurzes Ein/Ausblenden.
- `accessibilityReduceMotion` nicht gesondert noetig: der einzige Effekt ist ein
  einmaliges 0.12-s-Opacity, keine wiederholte Bewegung.

## 6. Aenderungen (C3)

- `v4/AudioRouterKit/Sources/AudioRouterKit/HeaderToggle.swift`: **geloescht**
  (nur fuer die Footer-Pille gebraucht, nach C3 ungenutzt).
- `v4/AudioRouterKit/Tests/AudioRouterKitTests/HeaderToggleTests.swift`:
  **geloescht**.
- `v4/AudioRouterKit/Sources/AudioRouterKit/FooterTips.swift`: **neu**, reine
  Texte (`FooterTips`, ein Eintrag je Element) plus eine Validierungsfunktion.
- `v4/AudioRouterKit/Tests/AudioRouterKitTests/FooterTipsTests.swift`: **neu**,
  prueft nicht leer, Laenge < 90, kein Gedankenstrich, kein " -- ", kein
  Superlativ per Wortliste.
- `v4/AudioRouterNow4/UI/RoutingControls.swift`: `HeaderToggleButton` und
  `HeaderTogglePressStyle` entfernt. `FooterRow` neu aufgebaut: eine Reihe,
  Support als Mint-Pille (S1), Hover-Bubble-Overlay mit Clamping, `.help` an den
  Bubble-Elementen entfernt, `FooterTip`-Enum fuer den Hover-Zustand.
- `v4/AudioRouterNow4/MenuBarView.swift`: grosser Knopf oben unveraendert; nur der
  Aufruf `FooterRow(state: ui)` bleibt (die Pille braucht den Zustand nicht mehr,
  aber die Reihe bleibt in einer Reihe; `state` wird fuer C3 nicht mehr gebraucht
  und entfaellt, falls `FooterRow` ihn nicht mehr nutzt).

Kein neues File im App-Target (FooterTips liegt im SPM-Paket). Engine,
ScrollView-Grenze, Solo, Limit-Hinweis, Volume, Fehler-/TCC-Abschnitte und der
grosse Knopf oben unveraendert.

## 6b. Audit-Nachbesserung (C3, nach `24-audit-ui-c3.md`)

Der unabhaengige Audit (`24-audit-ui-c3.md`, Urteil "Freigabe mit Auflagen", keine
Blocker) nannte vier Punkte. Alle behoben:

1. **Doku-Nachzug im Abschlussbericht 3.1.** `09-final-report.md` Abschnitt 3.1
   beschrieb den in C3 entfernten Statuszeilen-Toggle (E3) noch als Endstand. Ein
   Hinweis-Kasten stellt jetzt klar, dass der grosse Knopf oben der einzige
   Start/Stop-Knopf ist und die Statuszeilen- und Footer-Pille entfernt sind, mit
   Verweis auf diesen Nachtrag. CHANGELOG und README waren bereits auf C3 (geprueft).
2. **"Launch at Login" bricht nicht mehr um.** Am Toggle `lineLimit(1)`,
   `minimumScaleFactor(0.8)` und `fixedSize(horizontal: true)`. Beim Rendern des
   Footers zeigte sich, dass auch die Support-Pille ("Support") und "Quit" ohne
   `lineLimit`/`fixedSize` umbrechen, sobald die Reihe eng wird; beide haben jetzt
   dieselbe Absicherung. Per ImageRenderer in drei Schriftstufen geprueft: die Reihe
   bleibt einzeilig (50 pt), nichts abgeschnitten. Hinweis: feste Punktgroessen
   (`.font(.system(size:))`) reagieren kaum auf Dynamic Type, der echte Umbruch
   traete nur bei echter System-Skalierung auf; die Absicherung wirkt unabhaengig
   davon. Am Geraet mit grossen Bedienungshilfen-Stufen endgueltig zu bestaetigen.
3. **accessibilityHint fuer jedes Footer-Symbol.** Die `tracked(_:_:)`-Methode setzt
   jetzt `accessibilityHint(tip.text)` aus `FooterTip.text` (Quelle: `FooterTips`),
   also derselbe Text wie die Hover-Bubble, keine zweite Textkopie. Gilt fuer
   Support, Lock, Exclusive, Bug, Quit und Launch at Login. Zwei neue Tests im Kit
   (`testTipConstantsAreTheExpectedSourceOfTruth`, `testAllTipsAreUnique`) nageln die
   sechs Texte fest.
4. **Lock und Exclusive rufen beim Klick `clearHover()`** wie Support, Bug und Quit.

## 7. Was bei C3 nicht geprueft ist

- Ob die eigene Hover-Bubble im echten, nicht-aktivierenden MenuBarExtra-Panel so
  erscheint wie im Nachbau, inklusive der 0.35-s-Verzoegerung und des Ausblendens
  beim Panel-Schliessen. Nur am Geraet belegbar.
- Hover-Verhalten auf Trackpad gegen Maus (onHover feuert bei beiden, aber das
  genaue Timing ist nicht gemessen).
- Das echte Clamping am linken und rechten Fensterrand in der Menueleiste (im
  Nachbau geprueft, am Geraet zu bestaetigen).
- VoiceOver-Ausgabe und Tab-Fokus-Reihenfolge am Geraet.
- Die technische Annahme zu `.help`/NSToolTip im nicht-aktivierenden Panel ist
  begruendet, aber nicht aus einer einzelnen Apple-Quelle hart belegt; C3 umgeht
  sie durch das eigene Verfahren.

## Arbeitsstand (C3)

- C2-Sicherung unter `.claude/variants/C2-grosser-knopf-oben/` erstellt und per
  `git apply --check` auf frischem HEAD verifiziert (OK): erledigt.
- Dieses Dokument um den C3-Abschnitt erweitert, Stand-Markierung im Kopf auf C3,
  C und C2 als Verlauf behalten: erledigt.
- Kit erweitert (`FooterTips.swift` neu plus `FooterTipsTests.swift`),
  `HeaderToggle.swift` und `HeaderToggleTests.swift` geloescht: erledigt.
- View umgebaut (`HeaderToggleButton` und `HeaderTogglePressStyle` entfernt,
  `FooterRow` neu in einer Reihe mit Support-Pille S1 und eigener Hover-Bubble,
  `.help` an den Bubble-Elementen entfernt, `MenuBarView` ruft `FooterRow()` ohne
  `state`): erledigt. Konsistenz geprueft: keine HeaderToggle-Reste im Quellcode,
  kein `FooterRow(state:)`.
- Tests: `DEVELOPER_DIR=.../Xcode.app/... bash v4/scripts/test.sh`:
  60 swift-testing in 10 Suiten plus 110 XCTest, alle gruen. FooterTipsTests:
  14 Faelle gruen. (Vorher 110 XCTest inkl. 14 HeaderToggleTests; jetzt 110 ohne
  HeaderToggle, dafuer mit 14 FooterTips, Summe gleich.)
- App-Build (Debug, `CODE_SIGNING_ALLOWED=NO`, /tmp-Kopie, xcodegen generate):
  BUILD SUCCEEDED. Keine neue Warnung in RoutingControls/FooterTips/MenuBarView;
  die verbliebenen Code-Warnungen betreffen vorbestehenden FanOutEngine-Code.
- Visuelle Pruefung per `ImageRenderer` (Nachbau, nicht die echte App in der
  Menueleiste): sechs Zustaende gerendert und mit dem Read-Tool angesehen: Leerlauf,
  aktiv, lange Liste (18 Zeilen), Hover-Bubble ueber dem Support-Knopf, Clamping am
  linken Rand (Launch-at-Login), Clamping am rechten Rand (Quit). Ergebnis: die
  Support-Pille ist als Knopf mit Wort erkennbar, die Bubble erscheint ueber dem
  Footer und wird an beiden Raendern korrekt geclampt (nichts abgeschnitten).
  Gerenderte Fensterhoehen: idle 270 pt, aktiv 247 pt, lange Liste 589 pt, alle
  unter 700 pt. Grosser Knopf oben und Footer bleiben bei langer Liste sichtbar.
  Beobachtung: "Launch at Login" bricht im engen Nachbau zweizeilig um, wenn
  Support-Pille und Icons gleichzeitig Platz brauchen; das ist auch im echten Panel
  moeglich, bleibt aber sichtbar und bedienbar. Am Geraet pruefen (M2b). Der
  Nachbau nutzt die echte C3-Clamping-Formel, aber angenaeherte Farben, keinen
  echten Wellen-Header und nicht das MenuBarExtra-Fenster.
- Doku: CHANGELOG.md (4.1 Changed auf C3-Endstand umformuliert: grosser Knopf oben
  als einziger Start/Stop-Knopf, Support als beschrifteter Knopf, Hover-Erklaerungen;
  die Added-Zeile zum Status-Bar-Toggle korrigiert), docs/v4.1/README.md (Zeile 23
  auf drei Teile C/C2/C3), docs/v4.1/09-final-report.md (M1/M2/M2b auf C3, neu M2c
  fuer die Hover-Erklaerungen, neuer Nachtrag-Absatz C3): erledigt.
- Testversion "AudioRouterNow 4.1 TEST C3.app" nach ~/Desktop: erledigt.
  Release-Build ohne Apple-Signatur, Bundle-ID
  `com.mauriciomorkun.audiorouternow.test`, Name "AudioRouterNow 4.1 TEST C3",
  ad-hoc signiert mit app-sandbox und device.audio-input plus Hardened Runtime,
  `codesign --verify --deep --strict` valid, Entitlements vorhanden (adhoc,runtime),
  Info.plist 4.1 (11). Die drei anderen Test-Apps auf dem Desktop unberuehrt.
  Start-Smoke-Test NICHT gemacht: beim Bauen lief die Instanz "TEST C2" noch, es
  soll immer nur eine Instanz laufen; Start-Crashfreiheit der neuen App ungeprueft.
  LIES-MICH um den C3-Abschnitt und die Zuordnung der vier Apps ergaenzt.
- /tmp-Zwischenstaende aufgeraeumt. Kein Commit, kein Push, kein Tag.

## Arbeitsstand (C3, Audit-Nachbesserung nach `24-audit-ui-c3.md`)

- Abschnitt 6b (Audit-Nachbesserung) oben ergaenzt. Vier Audit-Punkte behoben:
  (1) Abschlussbericht 3.1 um C3-Hinweis ergaenzt (grosser Knopf oben einziger
  Start/Stop-Knopf), CHANGELOG/README als bereits konsistent geprueft; (2) Launch at
  Login, Support-Pille und Quit mit `lineLimit(1)` plus `fixedSize` gegen Umbruch,
  Launch zusaetzlich `minimumScaleFactor(0.8)`; (3) `accessibilityHint` aus
  `FooterTip.text` (Quelle `FooterTips`) an allen sechs Footer-Elementen ueber die
  `tracked`-Methode, plus zwei neue Kit-Tests; (4) `clearHover()` auch in Lock und
  Exclusive.
- Tests: 60 swift-testing plus 112 XCTest (2 neue FooterTips-Faelle), alle gruen.
- Debug-Build (CODE_SIGNING_ALLOWED=NO, /tmp): BUILD SUCCEEDED, keine Warnung in
  RoutingControls/FooterTips/MenuBarView.
- Launch-at-Login-Reihe per ImageRenderer in drei Schriftstufen geprueft und die PNGs
  gelesen: einzeilig, nichts abgeschnitten (Reihe 50 pt). Nachbau, nicht das echte
  Panel; feste Punktgroessen reagieren kaum auf Dynamic Type, der Umbruch bei grosser
  System-Skalierung ist nur am Geraet endgueltig belegbar.
- Testversion "AudioRouterNow 4.1 TEST C3.app" neu gebaut und ersetzt (TEST C3 lief
  nicht; C2 lief, daher kein Start-Smoke-Test). Verifiziert: adhoc+runtime,
  Entitlements app-sandbox und device.audio-input, 4.1 (11). Die drei anderen
  Test-Apps unberuehrt. LIES-MICH kurz aktualisiert.
- Kein Commit, kein Push, kein Tag.
- Finaler git-Status: ` M .gitignore` (nicht von dieser Arbeit), ` M CHANGELOG.md`,
  ` M docs/v4.1/09-final-report.md`, ` M docs/v4.1/README.md`,
  ` M v4/AudioRouterNow4/MenuBarView.swift`,
  ` M v4/AudioRouterNow4/UI/RoutingControls.swift`, `?? 23-ui-start-button-oben.md`,
  `?? 24-audit-ui-c3.md`, `?? FooterTips.swift`, `?? FooterTipsTests.swift`. Die
  geloeschten HeaderToggle-Dateien waren untracked und erscheinen daher nicht im
  Status.
