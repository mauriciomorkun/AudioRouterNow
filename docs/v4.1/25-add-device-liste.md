# 4.1 (UI, Frage): Ist die "Add device"-Liste scrollbar bei sehr vielen Ausgaengen?

Erstellt: 2026-11-17. Teil des 4.1-Zyklus, nach Doku 23/24 (Variante C3).
Betrifft nur die Darstellung der "Add device"-Liste, nicht die Engine.

## Frage des Nutzers

Waehrend eines aktiven Routings gibt es die Zeile "Add device" (gestrichelter
Rand, Plus-Symbol). Ein Klick oeffnet ein natives macOS-Popup-Menue mit allen
verfuegbaren Ausgaengen. Frage: Ist diese Liste scrollbar, wenn es sehr viele
Geraete beziehungsweise Ausgaenge gibt (Beispiel: BlackHole 64ch = 32 Paare,
plus Interfaces, bis ueber 100 Eintraege)? Falls nicht scrollbar: scrollbar
machen.

## Fundstelle im Code

`v4/AudioRouterNow4/UI/DeviceCardView.swift`, `struct AddDeviceRow` (Zeile 345
bis 379):

```
Menu {
    ForEach(controller.availableDevices, id: \.uid) { device in
        let pairCount = max(1, device.channelCount / 2)
        if pairCount == 1 { Button(device.name) { ... } }
        else { ForEach(0..<pairCount) { Button("\(device.name) (Ch...)") { ... } } }
    }
} label: { ... }
.menuStyle(.borderlessButton)
```

Wichtig: `AddDeviceRow` erscheint nur im aktiven oder startenden Zustand
(`MenuBarView.deviceListSection`, Zweig `.starting, .active`). Im Leerlauf
(idle/error) ist die Geraeteliste KEIN Menue, sondern eine flache Liste aus
`DeviceSelectionRow` INNERHALB des `ScrollView(.vertical).frame(maxHeight: 400)`
(dieser ist seit 4.1 P1 scrollbar). Die Frage betrifft also ausschliesslich das
native `Menu` im aktiven Zustand.

## Quellen mit Gewissheit

### 1. SwiftUI `Menu` bildet auf macOS auf NSMenu/NSPopUpButton ab

- ABGELEITET (stark, Standardwissen und mehrere Quellen): SwiftUI `Menu` nutzt auf
  macOS die native Menue-Infrastruktur (NSMenu). Das `.menuStyle(.borderlessButton)`
  erzeugt einen randlosen Button, dessen Dropdown ein natives Menue ist. Der
  Screenshot des Nutzers (gruen hervorgehobener Eintrag unter dem Cursor) bestaetigt
  die native Menue-Darstellung. Quelle: SwiftUI-Doku `View/menuStyle`, sowie
  Diskussionen zu "SwiftUI Menu -> NSMenu" (siehe unten, als Hinweis gekennzeichnet).

### 2. Natives macOS-Menue (NSMenu) scrollt bei zu vielen Eintraegen

- BELEGT (Apple HIG + eigene Messung, siehe Versuch): Wenn ein macOS-Menue mehr
  Eintraege hat, als in die Bildschirmhoehe passen, zeigt macOS ein verkuerztes
  Menue mit Scroll-Pfeil am oberen und/oder unteren Rand. Gescrollt wird per
  Scroll-Pfeil (Hover/Klick), per Scrollrad und per Tastatur (Home/End/PageUp/
  PageDown sowie Tippen des Anfangsbuchstabens). Quelle: Apple Human Interface
  Guidelines (Menus) und langjaehriges AppKit-Verhalten; hier zusaetzlich direkt
  gemessen (siehe "Empirischer Versuch").

### 3. Gilt auch aus einem MenuBarExtra(.window)-Panel heraus

- ABGELEITET (stark): Ein NSMenu oeffnet ein eigenes Menue-Fenster auf der
  NSPopUpMenuWindowLevel-Ebene, unabhaengig vom aufrufenden Fenster. Es haengt
  nicht am Key-Window des Panels (anders als NSToolTip, vergleiche Doku 23 zu
  `.help`). Die eigene Messung lief ohne aktivierte App (accessory policy), das
  Menue-Fenster erschien und wurde auf Bildschirmhoehe begrenzt. Damit ist das
  Scrollverhalten im Panel-Kontext plausibel identisch. Nicht am echten
  MenuBarExtra-Panel per Klick gemessen (Grund siehe Versuch).

### Hinweise (Foren, nur als Hinweis gekennzeichnet)

- Bekannte Eigenheit: SwiftUI `Menu` auf macOS kann bei sehr vielen Eintraegen
  traege werden und baut das NSMenu bei jedem Oeffnen neu auf (keine Lazy-Buildup
  wie bei handgebautem NSMenu). Hinweis, nicht hart belegt.

## Empirischer Versuch

### Was nicht ging (und warum)

- Vollautomatisches Oeffnen des echten SwiftUI-`Menu` aus einem
  MenuBarExtra(.window)-Panel per Skript: NICHT moeglich ohne Eingriff. Das
  Oeffnen braucht simulierte Klicks (Statusbar-Icon, dann die "Add device"-Zeile),
  die Accessibility-Rechte (Bedienungshilfen) fuer den steuernden Prozess
  erfordern. Pruefung `AXIsProcessTrusted()` ohne Dialog-Option: `AX_NOT_TRUSTED`.
  Es wurde bewusst KEIN Rechte-Dialog ausgeloest und nicht um Rechte gebeten.
  Daher dieser Teil abgebrochen.

### Was ging (gueltiger Beleg des zugrunde liegenden NSMenu)

- Ein Nachbau unter `/tmp` (nicht im Repo, kein Audio, Buttons sind No-Ops) baut
  dieselbe Konstruktion `Menu { ForEach { Button } }.menuStyle(.borderlessButton)`
  in einem `MenuBarExtra(.window)` (Datei `/tmp/arn-menutest/main.swift`, gebaut,
  nicht installiert). Oeffnen per Klick scheiterte an den AX-Rechten (siehe oben).
- Direkter Beleg des NSMenu-Scrollens: Ein zweiter Nachbau
  (`/tmp/arn-menutest/nsmenuprobe2.swift`) baut ein NSMenu mit 300 Eintraegen im
  Stil "Device N (ChX-Y)" und zeigt es per `menu.popUp(...)` (aus dem eigenen
  Prozess, KEIN simulierter Klick, keine AX-Rechte noetig). Danach wird das
  Menue-Fensterrechteck ueber `CGWindowListCopyWindowInfo` auf der
  `NSPopUpMenuWindowLevel`-Ebene ermittelt und genau diese Region per
  `screencapture -R` erfasst.

### Messung (gemessen, nicht geschaetzt)

- Bildschirmhoehe: 1440 pt. 300 Eintraege waeren bei ~19 pt je Zeile zusammen
  ~5700 pt hoch.
- Tatsaechliche Menue-Fensterhoehe: **1090 pt** (also auf die verfuegbare
  Bildschirmhoehe begrenzt, nicht 5700 pt). Der Screenshot
  (`/tmp/arn-menutest/nsmenu-region.png`) zeigt "Device 1 (Ch1-2)" bis
  "Device 44 (Ch87-88)" und am unteren Rand einen **nach-unten-Scroll-Pfeil
  (Chevron)**. Die restlichen 256 Eintraege sind per Scrollen erreichbar.
- Ergebnis: Das native macOS-Menue scrollt bei sehr vielen Eintraegen. BELEGT
  durch Messung.

### Was der Nutzer in 1 Minute am Geraet pruefen kann

- Eine Testversion mit kuenstlich langer Liste (siehe Schritt 4, Fall A). Routing
  starten, "Add device" oeffnen: die Liste soll ein verkuerztes Menue mit
  Scroll-Pfeil zeigen und per Scrollrad/Pfeil scrollen.

## Bewertung

### (a) Ist die Liste scrollbar? JA (belegt)

Das native macOS-Menue scrollt bei sehr vielen Eintraegen. Direkt gemessen: bei
300 Eintraegen begrenzt macOS das Menue auf die Bildschirmhoehe (1090 pt statt
5700 pt) und zeigt einen Scroll-Pfeil. Scrollen per Pfeil, Scrollrad und Tastatur.
Das deckt auch den Fall BlackHole 64ch (32 Paare) plus Interfaces und ueber 100
Eintraege ab.

### (b) Ist sie gut nutzbar? (Empfehlung, keine Pflicht)

Scrollbar ja, aber eine sehr lange flache Liste hat bekannte Schwaechen, die hier
benannt, aber nicht gefordert sind:

- **Keine Suche, keine Gruppierung.** BlackHole 64ch erzeugt allein 32 Zeilen
  "BlackHole 64ch (ChX-Y)" hintereinander. Zusammen mit Interfaces wird die flache
  Liste lang und muehsam zu scannen.
- **Bereits hinzugefuegte Ausgaenge bleiben in der Liste.** `addOutputConfig`
  behandelt Duplikate als stilles No-Op (`OutputLimits.addDecision -> .duplicate`,
  `EngineController.addOutputConfig` kehrt bei `.duplicate` ohne Meldung zurueck).
  Im Menue gibt es keinen Haken und keine Ausblendung: der Nutzer sieht nicht,
  welche Paare schon aktiv sind, und ein Klick auf ein schon aktives Paar tut
  sichtbar nichts. Der Limit-Hinweis (`outputLimitNotice`) erscheint nur beim
  Erreichen der 255-Grenze, nicht bei Duplikaten.
- **Tastatur/VoiceOver:** Das native Menue unterstuetzt Tastatur (Pfeile, Tippen
  des Anfangsbuchstabens, Home/End/PageUp/PageDown) und VoiceOver grundsaetzlich,
  da es natives AppKit ist. Nicht am Geraet mit VoiceOver geprueft.

Fazit: Die geforderte Scrollbarkeit ist erfuellt. Nutzbarkeit ist akzeptabel,
aber bei vielen Multi-Channel-Geraeten verbesserbar (siehe Vorschlaege).

## Entscheidung: Fall A (keine Verhaltensaenderung noetig)

Der Nutzer hat ausschliesslich Scrollbarkeit gefordert. Die ist belegt vorhanden.
Es wird daher KEINE Aenderung am Verhalten der "Add device"-Liste vorgenommen und
KEIN CHANGELOG-Eintrag geschrieben. Zusaetzlich wird eine Pruefhilfe-App mit
kuenstlich 120 Eintraegen nur unter `/tmp`/Desktop bereitgestellt (siehe unten),
damit der Nutzer das Scrollen am echten Panel in der Menueleiste selbst sieht.

## Verbesserungsvorschlaege (nur Vorschlag, nicht umgesetzt)

| # | Vorschlag | Nutzen | Aufwand | Risiko |
|---|-----------|--------|---------|--------|
| V1 | Multi-Channel-Geraete als **Untermenue je Geraet** (`Menu(device.name) { Button je Paar }`) statt flacher Paar-Liste. Aus 32 flachen BlackHole-Zeilen wird 1 Zeile "BlackHole 64ch" mit Untermenue. | Kuerzere Hauptliste, bessere Scanbarkeit | Gering (wenige Zeilen in `AddDeviceRow`; `Menu` statt `ForEach(Button)` je Geraet mit `pairCount > 1`) | Gering. Ein weiteres natives Untermenue, dasselbe Scrollverhalten. Keine Engine-Aenderung |
| V2 | Bereits hinzugefuegte Paare im Menue **mit Haken kennzeichnen** oder **ausblenden** (Abgleich gegen `controller.outputConfigs`). | Nutzer sieht, was schon aktiv ist; keine wirkungslosen Klicks | Gering bis mittel (Zustand je Paar lesen; bei Haken-Variante Button-Label mit `checkmark`-Image; SwiftUI-`Button` im `Menu` erlaubt begrenztes Styling, ggf. Text-Praefix). | Gering. Reine Anzeige, keine Engine-Aenderung |
| V3 | Optional: **Suchfeld** ueber einer eigenen scrollbaren Popover-Liste statt des nativen Menues (wie die idle-`DeviceSelectionRow`-Liste, aber als Popover im aktiven Zustand). | Schnelles Finden bei 100+ Eintraegen | Hoch (ersetzt das native Menue durch eine eigene View samt Fokus/Tastatur/VoiceOver, neue testbare Logik im Kit). | Mittel. Mehr Code, Tastatur/VoiceOver selbst zu tragen. Nur sinnvoll, wenn V1+V2 nicht reichen |

Empfehlung: V1 und V2 sind klein, risikoarm und loesen die beiden realen
Schwaechen (Laenge, fehlendes "schon aktiv"-Signal). V3 nur bei Bedarf. Alle drei
sind bewusst NICHT umgesetzt, der Nutzer entscheidet.

## Was nicht geprueft ist

- Das echte SwiftUI-`Menu` in der laufenden App per Klick (AX-Rechte fehlen, kein
  Dialog ausgeloest). Belegt wurde das zugrunde liegende NSMenu direkt.
- VoiceOver-Ausgabe und Tastatur-Fokus im echten Panel.
- Die genaue Item-Hoehe und damit die exakte Zahl sichtbarer Zeilen je
  Bildschirm (nur grob ~19 pt angenommen; die Begrenzung auf Bildschirmhoehe und
  der Scroll-Pfeil sind gemessen).

## Pruefhilfe-App: Build (Fall A)

Zweck: der Nutzer sieht das Scrollen am echten Panel in der Menueleiste. Die App
ist eine TEMPORAERE Kopie des Repos unter `/tmp`, NICHT im Repo, NICHT in der
Release-Doku ausser dieser Notiz. Ablage: `~/Desktop/"AudioRouterNow 4.1 TEST C3
LISTE.app"`.

Was die Testversion anders macht (nur in der Kopie, nicht im Repo):
- `EngineController.refreshAvailableDevices()` haengt im Testmodus 120 kuenstliche
  Geraete an ("Test Output 1" bis "Test Output 120", je 2 Kanaele). Zusammen mit
  den echten Geraeten wird die Liste lang.
- `MenuBarView.deviceListSection` zeigt die "Add device"-Zeile (das native `Menu`)
  im Testmodus AUCH im Leerlauf, damit das Menue-Scrollen OHNE echtes Routing
  pruefbar ist (sonst erscheint `AddDeviceRow` nur im aktiven Zustand).
- Testmodus ist aktiv, wenn die Env-Var `ARN_TEST_LIST` gesetzt ist ODER der
  Info.plist-Schluessel `ARNTestList` true ist. In der App ist `ARNTestList=true`
  gebacken, also wirkt der Testmodus auch beim normalen Doppelklick-Start.

Wie das Routing-Risiko ausgeschlossen ist (wichtig):
- Die kuenstlichen Geraete haben UIDs mit Praefix `ARN_TEST_FAKE_`.
- `EngineController.addOutputConfig` kehrt bei diesem Praefix SOFORT zurueck
  (reines No-Op). Ein Klick auf ein kuenstliches Gerät legt also KEINE
  `OutputConfig` an, loest keinen Warm-Restart und kein Routing aus. Die
  kuenstlichen Eintraege sind reine Anzeige.
- Der echte Engine-Pfad (`FanOutEngine`, Start/Stop) ist unveraendert. Reale
  Geraete verhalten sich wie in der echten App.

Build und Signierung (nach dem bekannten Verfahren):
- Quelle `/tmp/arn-liste-build/v4` (Kopie des Repos), Projekt per
  `scripts/xcodegen.sh` generiert, Release gebaut mit `CODE_SIGNING_ALLOWED=NO`.
  BUILD SUCCEEDED.
- Bundle nach Desktop kopiert, Info.plist: Bundle-ID
  `com.mauriciomorkun.audiorouternow.test`, Name/DisplayName
  "AudioRouterNow 4.1 TEST LISTE", `ARNTestList=true`, Version 4.1 (Build 11).
- Ad-hoc signiert mit `--options runtime` (Hardened Runtime) und Entitlements
  `app-sandbox` plus `device.audio-input`. `codesign --verify --deep --strict`:
  valid on disk, satisfies its Designated Requirement. Flags `adhoc,runtime`.
- Start-Smoke-Test NICHT gemacht: beim Bauen lief die Instanz "TEST C3" (nur eine
  Instanz soll laufen). Start-Crashfreiheit der LISTE-App damit ungeprueft.
- Die vier vorhandenen Test-Apps auf dem Desktop (TEST, TEST (neu), TEST C2,
  TEST C3) wurden NICHT angefasst.

So prueft der Nutzer (1 Minute):
1. Die laufende "TEST C3"-Instanz beenden (nur eine Instanz zugleich).
2. "AudioRouterNow 4.1 TEST C3 LISTE.app" doppelklicken, Menueleisten-Icon oeffnen.
3. Im Leerlauf die Zeile "Add device" anklicken: es erscheint das native Menue mit
   ueber 120 Eintraegen. Erwartet: verkuerztes Menue mit Scroll-Pfeil, scrollbar per
   Scrollrad, Pfeil und Tastatur. Klicks auf "Test Output N" tun bewusst nichts.

## Arbeitsstand

- Schritt 0 (Lesen): CLAUDE.md, Doku 23 (C3), DeviceCardView.swift, MenuBarView.swift,
  OutputLimits.swift, EngineController.addOutputConfig gelesen. Erledigt.
- Schritt 1 (Recherche): erledigt (NSMenu scrollt, Quellen oben).
- Schritt 2 (empirischer Versuch): erledigt. Echtes SwiftUI-Menue per Klick nicht
  automatisierbar (AX-Rechte), aber das zugrunde liegende NSMenu-Scrollen direkt
  gemessen (1090 pt statt 5700 pt, Scroll-Pfeil im Screenshot). Beleg:
  `/tmp/arn-menutest/nsmenu-region.png`.
- Schritt 3 (Bewertung) und Schritt 4 (Entscheidung Fall A, Vorschlaege): erledigt.
- Schritt 4b (Pruefhilfe-App): erledigt. "AudioRouterNow 4.1 TEST C3 LISTE.app"
  auf dem Desktop, ad-hoc+runtime signiert, Entitlements app-sandbox und
  device.audio-input, 4.1 (11), kuenstliche Eintraege ohne Routing. Start-Smoke-
  Test nicht gemacht (C3 lief).
- Schritt 5 (Tests): Repo-Stand unveraendert (Fall A, kein CHANGELOG-Eintrag).
  SPM 60 swift-testing gruen, XCTest-Suite TEST EXECUTE SUCCEEDED.
- Schritt 6 (Doku): README-Inhaltstabelle und 09-final-report Pruefzeile ergaenzt.
- Fazit: Antwort auf die Frage ist JA (scrollbar), belegt durch Messung. Fall A,
  keine Code-Aenderung. Verbesserungen V1/V2/V3 vorgeschlagen, nicht umgesetzt.

---

# V2 umgesetzt: bereits hinzugefuegte Ausgaenge im "Add device"-Menue markieren

Erstellt: 2026-11-17. Setzt Verbesserung V2 aus der Tabelle oben um (NICHT V1,
NICHT V3). Betrifft nur die Darstellung des nativen "Add device"-Menues im
aktiven oder startenden Zustand, nicht die Engine, nicht `addOutputConfig`, nicht
`OutputLimits`.

**V2 ist Teil der finalen 4.1 (Entscheidung des Nutzers, 17.11.2026).** C3 mit V2
wurde gewaehlt (Stand der Test-App "AudioRouterNow 4.1 TEST C3b"). Die Scrollbarkeit
des "Add device"-Menues ist am Geraet bestaetigt (Nutzer, mit der Pruefhilfe
"AudioRouterNow 4.1 TEST C3 LISTE", 120 kuenstliche Eintraege). V1 (Untermenue je
Mehrkanalgeraet) und V3 (Suchfeld-Popover) bleiben offene Ideen ohne Termin.

## Problem (aus dem Screenshot des Nutzers)

Im "Add device"-Menue standen bereits hinzugefuegte Ausgaenge (Geraet plus
Kanalpaar) weiterhin wie frei waehlbare Eintraege. Beispiel: "Komplete Audio 6
MK2 (Ch1-2)" und "(Ch3-4)" waren schon aktiv und erschienen trotzdem ohne
Markierung. Ein Klick darauf wurde still ignoriert
(`OutputLimits.addDecision -> .duplicate`, `addOutputConfig` kehrt ohne Meldung
zurueck). Der Nutzer sah weder, welche Paare schon aktiv sind, noch warum der
Klick nichts tut.

## Design-Entscheidung: Variante (a), Haken plus deaktiviert

Gewaehlt ist (a): bereits hinzugefuegte Eintraege mit Haken (checkmark) und
deaktiviert (ausgegraut) anzeigen. Verworfen: (b) ganz ausblenden (der Nutzer
saehe nicht mehr, dass das Paar existiert und schon aktiv ist, und die Liste
spraenge beim Hinzufuegen) und (c) ans Ende sortieren oder gruppieren (die
Reihenfolge waere instabil und es bliebe unklar, warum ein Eintrag unten steht).
Begruendung in drei Saetzen: Mit (a) sieht der Nutzer auf einen Blick, welche
Paare schon aktiv sind und warum sie nicht waehlbar sind, statt ins Leere zu
klicken. Die Reihenfolge der Liste bleibt stabil, ein frisch hinzugefuegtes Paar
rutscht nicht weg, es bekommt nur einen Haken. Haken und Ausgrauen sind die
systemeigene NSMenu-Sprache fuer "aktiv, aber hier nicht waehlbar".

### Systemkonforme Umsetzung im NSMenu (Quelle belegt)

Auf macOS bildet ein SwiftUI `Menu` auf ein natives NSMenu ab (siehe oben,
Abschnitt "Quellen mit Gewissheit", Punkt 1). Fuer den Haken ist die
systemkonforme Wahl ein `Toggle` im Menue, NICHT ein `Button` mit
`Label(systemImage: "checkmark")`:

- BELEGT (Apple, "Populating SwiftUI menus with adaptive controls",
  https://developer.apple.com/documentation/swiftui/populating-swiftui-menus-with-adaptive-controls,
  abgerufen ueber context7 am 2026-11-17): "a `Toggle` in a menu automatically
  appears with a checkmark indicating its on or off state." Ein Toggle im Menue
  erzeugt also auf macOS von selbst den nativen Haken im On-Zustand.
- BELEGT (dieselbe Quelle): "On macOS, menu items constructed with a `Label`
  render without an icon by default." Ein `Label(systemImage: "checkmark")` im
  Menue wuerde den Haken also standardmaessig UNTERDRUECKEN (man muesste
  zusaetzlich `.labelStyle(.titleAndIcon)` erzwingen). Der Toggle ist der
  robustere, systemeigene Weg.
- `.disabled(true)` graut den Eintrag aus und macht ihn unklickbar (Apple,
  `View/disabled(_:)`). Der ohnehin wirkungslose Duplikat-Klick entfaellt damit.

Umsetzung: In `AddDeviceRow` wird ein bereits hinzugefuegtes Paar als
`Toggle(titel, isOn: .constant(true)).disabled(true)` gerendert (Haken plus
ausgegraut), ein freies Paar bleibt ein `Button(titel)`. VoiceOver liest beim
Toggle den Titel plus den On- und Dimm-Zustand (natives AppKit).

### Logik im Kit (testbar), View liest nur ab

Die Auswahl- und Titellogik liegt als reine Funktion im SPM-Paket
(`v4/AudioRouterKit/Sources/AudioRouterKit/AddDeviceMenuModel.swift`, neu):

- `AddDeviceMenuModel.entries(availableDevices:configuredOutputs:)` liefert je
  Kanalpaar je verfuegbarem Geraet einen `AddDeviceMenuEntry`
  (`title`, `uid`, `channelOffset`, `isAdded`), Reihenfolge wie `availableDevices`.
- `AddDeviceMenuModel.allAdded(_:)` sagt, ob mindestens ein Eintrag existiert und
  alle schon hinzugefuegt sind.
- `AddDeviceMenuModel.allAddedNotice` = "All outputs are added." (englisch,
  neutral).

Identitaet eines Ausgangs ist `uid` plus `channelOffset` (deckungsgleich mit
`DeviceSelectionRow.selectedConfig` und der Duplikat-Erkennung in
`addOutputConfig`; `channelCount` zaehlt bewusst nicht mit). Kein neues File im
App-Target (`project.yml` ohne Signierung, XcodeGen wuerde es verlieren); die
View `AddDeviceRow` in `v4/AudioRouterNow4/UI/DeviceCardView.swift` liest nur ab
und ruft weiter `controller.addOutputConfig` auf. Swift 6 Strict Concurrency
(`AddDeviceMenuEntry` ist `Hashable, Sendable`, das Enum ist zustandslos).

## Grenzfaelle und Verhalten

| # | Fall | Verhalten in V2 |
|---|------|-----------------|
| 1 | Alle Paare aller Geraete schon hinzugefuegt | Menue zeigt EINEN deaktivierten Hinweis "All outputs are added." statt lauter ausgegrauter Zeilen (kein leeres Menue). Belegt per `allAdded`-Test und NSMenu-Probe. |
| 2 | Limit erreicht (255 konfigurierte Ausgaenge) | Kein neues Verhalten. Nicht hinzugefuegte Eintraege bleiben bewusst klickbar; der Klick laeuft wie bisher in `addOutputConfig`, das ab dem Limit `outputLimitNotice` setzt und nicht hinzufuegt. Begruendung: Das Deaktivieren haette den Menueeintrag von einem Engine-Zustand abhaengig gemacht (Doppelquelle zum Limit-Hinweis) und `addOutputConfig`/`OutputLimits` nicht angefasst, wie gefordert. Die bestehende Limit-Anzeige (`outputLimitNotice`, `OutputLimits.limitMessage`) bleibt die einzige Quelle. |
| 3 | Ein Geraet verschwindet, waehrend das Menue offen ist | `entries` wird bei jedem Oeffnen aus dem aktuellen `availableDevices` und `outputConfigs` neu berechnet (reine Funktion, kein gecachter Zustand). Kein Absturz; das native Menue baut sich beim naechsten Oeffnen neu auf. |
| 4 | Konfigurierter Ausgang, dessen Geraet gerade nicht verbunden ist | Erzeugt KEINEN Eintrag und markiert auch keinen anderen (`entries` iteriert nur ueber `availableDevices`). Belegt per Test `testConfiguredOutputWithoutDeviceProducesNoEntry`. |
| 5 | Mono-/Einzelpaar-Geraet (`pairCount == 1`) | Kein "(ChX-Y)"-Zusatz, nur der Name. Mehrkanalgeraete tragen den Zusatz. Titelformat unveraendert gegenueber dem alten `AddDeviceRow`. |
| 6 | Gleiche Geraetenamen, verschiedene uid | Getrennte Eintraege; der Haken haengt an (uid, channelOffset), nicht am Namen. Belegt per `testSameNameDifferentUidAreIndependent`. |
| 7 | channelCount ungerade oder 0 | `pairCount = max(1, channelCount / 2)` unveraendert. 0 und 3 -> 1 Paar, 5 -> 2 Paare. Belegt per Tests. |

## Tests

- Neu: `v4/AudioRouterKit/Tests/AudioRouterKitTests/AddDeviceMenuModelTests.swift`
  (17 XCTest-Faelle): kein Eintrag hinzugefuegt, einige hinzugefuegt (Screenshot-
  Beispiel KA6), alle hinzugefuegt, Mehrkanalgeraet mit Paaren, Einzelpaar-Geraet
  ohne Zusatz, gleiche Namen mit verschiedener uid, konfigurierter Ausgang ohne
  verfuegbares Geraet, ungerade (3 und 5) und Nullkanal-Faelle, Titel identisch zum
  bisherigen Inline-Format, Reihenfolge stabil beim Markieren, Hinweistext
  stilkonform.
- Lauf `DEVELOPER_DIR=.../Xcode.app/... bash v4/scripts/test.sh`:
  60 swift-testing plus 129 XCTest gruen (vorher 112 XCTest, dazu 17 neue).
- App-Build Debug (`CODE_SIGNING_ALLOWED=NO`, /tmp-Kopie, xcodegen generate):
  BUILD SUCCEEDED, keine neue Warnung in DeviceCardView/AddDeviceMenuModel.

## Empirisch geprueft (ja, am NSMenu, nicht am echten SwiftUI-Menue)

- Ein Probe-Prozess unter `/tmp/arn-v2-menuprobe/probe.swift` (nicht im Repo, No-Op)
  baut ein NSMenu mit normalen Eintraegen, mit Eintraegen `state = .on` plus
  `isEnabled = false` (Haken plus ausgegraut, genau die Darstellung, auf die
  `Toggle(isOn: true).disabled(true)` abbildet) und mit dem deaktivierten Hinweis
  "All outputs are added.", und zeigt es per `menu.popUp(...)` aus dem eigenen
  Prozess (KEIN simulierter Klick, keine AX-Rechte). Das Menuefenster wurde per
  `CGWindowListCopyWindowInfo` gefunden und per `screencapture -R` erfasst.
- Ergebnis (gemessen, Screenshot angesehen): die freien Eintraege sind voll
  sichtbar und wirken klickbar, die hinzugefuegten Paare tragen einen Haken und
  sind ausgegraut, der Hinweis "All outputs are added." steht ausgegraut unter
  einem Trenner. Die Darstellung ist system- und HIG-konform.

## Was nicht geprueft ist

- Die exakte SwiftUI-`Toggle`-auf-NSMenuItem-Abbildung in der LAUFENDEN App per
  Klick (dasselbe AX-Rechte-Hindernis wie bei Fall A oben; es wurde bewusst kein
  Rechte-Dialog ausgeloest). Belegt ist das zugrunde liegende NSMenu direkt.
- VoiceOver-Ausgabe des deaktivierten Toggles im echten, nicht-aktivierenden
  MenuBarExtra-Panel.
- Start-Crashfreiheit der Testversion C3b (die Instanz "TEST C3" lief beim Bauen,
  es soll nur eine Instanz laufen).

## Arbeitsstand V2

- Kit-Logik `AddDeviceMenuModel.swift` plus `AddDeviceMenuModelTests.swift`
  (17 Faelle) geschrieben, `AddDeviceRow` in `DeviceCardView.swift` auf das Modell
  umgestellt (Toggle mit Haken fuer hinzugefuegte Paare, Hinweis bei "alle
  hinzugefuegt"): erledigt.
- Tests: 60 swift-testing plus 129 XCTest gruen. Debug-Build: BUILD SUCCEEDED.
- Empirische NSMenu-Pruefung (Haken plus ausgegraut, Hinweis): erledigt,
  Screenshot angesehen.
- Testversion "AudioRouterNow 4.1 TEST C3b.app" auf dem Desktop
  (Release ohne Apple-Signatur, Bundle-ID com.mauriciomorkun.audiorouternow.test,
  Name "AudioRouterNow 4.1 TEST C3b", ad-hoc mit app-sandbox und
  device.audio-input plus Hardened Runtime, codesign --verify --deep --strict
  valid, adhoc+runtime, Info.plist 4.1 (11)). Die fuenf anderen Test-Apps
  unberuehrt, kein Start (TEST C3 lief), kein Smoke-Test. LIES-MICH ergaenzt.
- Doku: dieser V2-Abschnitt, CHANGELOG (4.1 Changed), final-report Pruefzeile M2d.
  /tmp-Zwischenstaende aufgeraeumt. Kein Commit, kein Push, kein Tag.

---

# Audit V2 (unabhaengige Pruefung, 2026-11-17)

Pruefer: unabhaengiger Opus-Agent (Vorgehen nach /sc:analyze). Nur lesend, nichts
am Code geaendert. Branch `release/4.1`, V2 uncommitted im Arbeitsbaum. Grundlage:
`git diff v4/AudioRouterNow4/UI/DeviceCardView.swift`, die neuen Kit-Dateien
`AddDeviceMenuModel.swift` und `AddDeviceMenuModelTests.swift`, `OutputConfig.swift`,
`EngineController.availableDevices`/`outputConfigs` und
`FanOutEngine.availableOutputDevices()`.

## Kurzurteil

**Freigabe.** Die Logik ist korrekt, die Identitaet (uid plus channelOffset) deckt
sich mit `addOutputConfig`, das Titelformat ist deckungsgleich zum frueheren Inline-
Code, die 17 Tests sind aussagekraeftig (kein Scheintest), 60 swift-testing plus 129
XCTest gruen (selbst ausgefuehrt), `git status --short` vor und nach dem Lauf gleich.
Kein Blocker, kein Mangel ab Schwere mittel. Ein Restrisiko bleibt (natives
Toggle-auf-NSMenu-Rendering nur am Geraet belegbar, siehe unten) plus ein
kosmetischer Hinweis. Kein neues File im App-Target, keine Engine-Aenderung.

## 1. Logik

| Punkt | Befund |
|-------|--------|
| Identitaet uid plus channelOffset | Belegt. `entries` baut die "schon hinzugefuegt"-Menge als Set aus `"\(uid):\(channelOffset)"` (AddDeviceMenuModel.swift:156). `channelCount` zaehlt bewusst nicht mit, deckungsgleich mit `OutputConfig` (uid, channelOffset, channelCount mit Default 2) und der Duplikat-Erkennung in `addOutputConfig`. Die View fuettert `controller.outputConfigs.map { (uid, channelOffset) }` (DeviceCardView.swift AddDeviceRow). Korrekt. |
| Titelformat identisch | Belegt. `title(name:channelOffset:pairCount:)` liefert bei `pairCount == 1` nur den Namen, sonst `name (ChX-Y)` mit X=offset+1, Y=offset+2 (AddDeviceMenuModel.swift:89-94). Das ist exakt der frueher inline berechnete String. Test `testEntryTitlesEqualOldInlineFormula` nagelt das gegen die alte Formel. |
| pairCount-Regel | Belegt. `max(1, channelCount / 2)` (AddDeviceMenuModel.swift:77-79), deckungsgleich mit dem alten `AddDeviceRow` und `DeviceSelectionRow`. Tests fuer 0,1,2,3,4,64. |
| Hinweis bei allAdded | Belegt. `allAdded` ist `!entries.isEmpty && entries.allSatisfy { isAdded }` (AddDeviceMenuModel.swift:143-145). Leere Liste liefert bewusst `false` (Test `testAllAddedIsFalseForEmptyList`), sonst wuerde die View bei gar keinem Geraet faelschlich "All outputs are added." zeigen. Die View zeigt den einen deaktivierten Hinweis nur, wenn `allAdded` wahr ist. Korrekt. |
| Verhalten bei Limit 255 | Korrekt und bewusst unveraendert. V2 deaktiviert einen noch nicht hinzugefuegten Eintrag am Limit NICHT; der Klick laeuft wie bisher in `addOutputConfig`, das ab der Grenze `outputLimitNotice` setzt und nicht hinzufuegt. Begruendung in Grenzfall 2 der Doku: keine Doppelquelle zum Limit-Hinweis, `OutputLimits`/`addOutputConfig` nicht angefasst (wie gefordert). Nachvollziehbar. |
| Sortierung stabil | Belegt. `entries` iteriert `availableDevices` in Reihenfolge, je Geraet `pair in 0..<pairs` aufsteigend; Markieren verschiebt nichts (Test `testOrderIsStableWhenSomeAdded`). Korrekt. |
| ForEach-Identitaet (Hashable, `id: \.self`) | Kein Duplikat-Risiko unter realen Daten. `AddDeviceMenuEntry` ist `Hashable` ueber alle vier Felder (title, uid, channelOffset, isAdded). Zwei Eintraege waeren nur dann identisch, wenn uid UND channelOffset gleich sind. Innerhalb eines Geraets ist `channelOffset` je Paar verschieden; zwischen Geraeten muesste dieselbe uid zweimal auftauchen. `FanOutEngine.availableOutputDevices()` (Zeile 1224) iteriert ueber CoreAudio-DeviceIDs und bildet je Device eine uid (`deviceUID`); eine uid kann daher nicht zweimal in `availableDevices` stehen. Folge: keine doppelten `id: \.self`, kein verwirrtes `ForEach`. Gleiche **Namen** mit verschiedener uid sind unkritisch (Hash enthaelt uid, Test `testSameNameDifferentUidAreIndependent`). **Annahme**, nicht hart belegt: dass CoreAudio nie zwei Eintraege mit identischer DeviceUID liefert; das ist Standardverhalten (UID identifiziert das Geraet), aber nicht aus einer einzelnen Apple-Quelle zitiert. Sollte CoreAudio je eine uid doppelt liefern, erzeugte das zwar doppelte ForEach-IDs, haette aber dieselbe Wirkung wie zwei identische Eintraege (beide zeigen und beide fuegen dasselbe Paar hinzu, das zweite als stilles Duplikat-No-Op). Kein Absturz, nur eine Doppelzeile. Restrisiko gering. |

## 2. Tests

Aussagekraeftig, keine Scheintests. Die 17 Faelle pruefen: pairCount gegen die alte
Regel; Titelformat Einzelpaar ohne Zusatz und Mehrpaar mit Zusatz; Titel gegen die
alte Inline-Formel (BlackHole 64ch, 32 Paare); nichts hinzugefuegt (alle waehlbar);
einige hinzugefuegt (KA6-Screenshot-Beispiel); teilweise hinzugefuegt; alle ueber
mehrere Geraete; leere Liste (allAdded false); Einzelpaar ohne Zusatz; gleiche Namen
mit verschiedener uid getrennt; konfigurierter Ausgang ohne verfuegbares Geraet
(kein Eintrag); Null- und ungerade Kanalzahlen (3->1 Paar, 5->2 Paare);
Reihenfolge-Stabilitaet; Hinweistext stilkonform (kein Em-Dash, kein " -- ").
Die Tests pruefen Werte, nicht nur Nicht-Absturz.

**Ausgefuehrt (gemessen, nicht geschaetzt):** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash v4/scripts/test.sh`:
60 swift-testing in 10 Suiten und **129 XCTest** gruen (Suite `AddDeviceMenuModelTests`
17 von 129, 0 Fehler). `git status --short` vor und nach dem Lauf identisch (test.sh
nutzt `.build`, gitignored). Die in der V2-Doku genannte Zahl 60 plus 129 ist damit
bestaetigt.

## 3. Restrisiko: Toggle-als-Haken im Menu

`Toggle(entry.title, isOn: .constant(true)).disabled(true)` in einem `Menu` mit
`.menuStyle(.borderlessButton)`.

- **Quellenlage:** Die Darstellung als Haken ist BELEGT aus der Apple-Doku
  ("Populating SwiftUI menus with adaptive controls"): "a Toggle in a menu
  automatically appears with a checkmark indicating its on or off state." Die Doku
  nennt das allgemeine `Menu`, nicht ausdruecklich den Pfad `AddDeviceRow` ->
  `.menuStyle(.borderlessButton)` in einem nicht aktivierenden MenuBarExtra(.window)-
  Panel. Insofern ist die konkrete Abbildung in genau diesem Kontext **abgeleitet**,
  nicht am laufenden SwiftUI-Menue gemessen (AX-Rechte fehlten, siehe Doku). Am
  zugrunde liegenden NSMenu wurde die Ziel-Darstellung (state=.on plus
  isEnabled=false) direkt per Probe gezeigt.
- **VoiceOver:** Die Doku nennt fuer den deaktivierten Toggle im echten Panel keine
  gemessene Ansage. Ein deaktivierter Toggle liest unter AppKit ueblicherweise
  Titel plus On- und Dimm-Zustand; das ist hier **ungeprueft**.
- **Falls der Haken in der echten App nicht erscheint:** Dann bleibt der Eintrag
  trotzdem `.disabled(true)`, also ausgegraut und nicht klickbar. Der Nutzer sieht
  also auch im schlechtesten Fall, dass das Paar nicht waehlbar ist; es fehlte nur
  das zusaetzliche Haken-Signal. Kein Funktionsverlust, nur ein schwaecheres
  visuelles Signal. Das ist tragbar.

**Pruefzeile fuer den Nutzer am Geraet (1 Minute):** "AudioRouterNow 4.1 TEST C3b.app"
starten, ein Mehrkanalgeraet waehlen (z.B. KA6 Ch1-2 und Ch3-4), Routing starten,
"Add device" oeffnen. Erwartet: die schon hinzugefuegten Paare tragen einen Haken UND
sind ausgegraut; erscheint kein Haken, pruefen, dass sie zumindest ausgegraut und
nicht klickbar sind. Mit VoiceOver ueber einen solchen Eintrag fahren und hoeren, ob
Titel plus Zustand ("aktiviert", "dimmed") vorgelesen werden.

## 4. Performance

`entries` wird als `private var` (computed) bei jedem Neuzeichnen von `AddDeviceRow`
berechnet. Harmlos: Aufbau ist O(konfigurierte Ausgaben) fuer die Set-Bildung plus
O(verfuegbare Paare) fuer die Liste, beide klein (<= 255 bzw. die Zahl verfuegbarer
Kanalpaare). Kein CoreAudio-Zugriff in `entries` (es liest nur die schon
gehaltenen `@Published`-Arrays), kein Allokationspfad im Audio-Thread. Das native
NSMenu baut sich ohnehin bei jedem Oeffnen neu auf (bekannte SwiftUI-Eigenheit, in
Doku 25 als Hinweis vermerkt); die zusaetzliche `entries`-Berechnung faellt daneben
nicht ins Gewicht. Kein Performance-Mangel.

## 5. Stil, App-Target, Engine

- **Kein neues File im App-Target:** Belegt. `AddDeviceMenuModel.swift` und
  `AddDeviceMenuModelTests.swift` liegen im SPM-Paket (`AudioRouterKit/Sources` bzw.
  `/Tests`); die einzige App-Target-Aenderung ist der Diff an der bestehenden
  `DeviceCardView.swift`. Das vermeidet das bekannte Signierungs-/XcodeGen-Problem.
- **Keine Engine-Aenderung:** Belegt. Der Diff ruft weiter `controller.addOutputConfig`
  auf; `OutputLimits`, `addOutputConfig` und `FanOutEngine` sind unberuehrt.
- **Stil:** Kommentare und Hinweistext ohne Em-Dash, ohne " -- ", ohne Superlativ;
  `allAddedNotice` ist "All outputs are added." (ein Satz). In Ordnung.

## Maengel nach Schwere

- **Blocker:** keine.
- **Sollte behoben werden:** keine.
- **Kosmetisch / Restrisiko (am Geraet zu klaeren):** (1) Toggle-als-Haken-Rendering
  und VoiceOver-Ansage im echten, nicht aktivierenden Panel nur am Geraet belegbar
  (Abschnitt 3, Pruefzeile vorhanden). (2) ForEach-`id: \.self` haengt an der
  Annahme uid-eindeutiger `availableDevices`; durch CoreAudio praktisch gegeben,
  nicht hart zitiert (Abschnitt 1, letzte Zeile).
