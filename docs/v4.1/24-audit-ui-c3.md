# 24 Audit UI, Variante C3 (unabhaengige Pruefung)

Pruefer: unabhaengiger Opus-Agent (Vorgehen nach /sc:analyze). Datum 2026-11-16.
Branch `release/4.1`, Aenderung C3 uncommitted im Arbeitsbaum. Der Pruefer hat
nichts am Repo geaendert; Bash nur lesend, Tests nach /tmp.

## Kurzurteil

**Freigabe mit Auflagen.** Code und Tests sind sauber, der Auftrag ist in allen
vier Punkten umgesetzt, die tote `HeaderToggle`-Logik ist restlos entfernt, 60 + 110
Tests gruen, die Test-App korrekt signiert. Die Auflagen sind klein und betreffen
Dokumentation und ein Layout-Risiko bei grosser Dynamic Type, kein Blocker.

## Pruefpunkte A bis H

| Punkt | Thema | Status |
|-------|-------|--------|
| A | Tooltip-Texte am Code belegt, Accessibility | ERFUELLT (ein kosmetischer Hinweis) |
| B | Hover-Bubble Robustheit, Clamping | ERFUELLT (Punkte nur am Geraet) |
| C | Entfernte Pille, keine Reste, Doku-Konsistenz | ERFUELLT mit Mangel (Doku) |
| D | Footer-Layout, Umbruch, Hoehen | ERFUELLT mit Risiko (Dynamic Type) |
| E | App-Review-Regeln | ERFUELLT |
| F | Tests und Stil | ERFUELLT |
| G | Test-App Signierung und Metadaten | ERFUELLT |
| H | Regressionen, Ehrlichkeit der Pruefzeilen | ERFUELLT |

## A. Tooltip-Texte am Code belegt

Quelle: `v4/AudioRouterKit/Sources/AudioRouterKit/FooterTips.swift:32-47`, in der
View gelesen ueber `FooterTip.text` (`RoutingControls.swift:175-184`).

- Support: "Opens the tip jar. Tipping is optional and unlocks nothing."
  `TipJarStore.purchase` (`TipJarStore.swift:119-149`) ruft nach `verified` nur
  `transaction.finish()` und zeigt kurz `showThankYou`. Kein Entitlement, kein
  Flag, kein Freischalten (Grep `unlock/entitlement/hasPurchased` ohne Treffer im
  App-Target). Consumable, No-op-Listener (158-166). Aussage korrekt. ERFUELLT.
- Lock: "Keeps macOS from switching the output device while routing."
  `lockOutputDevice` (`EngineController.swift:183-196`, `setOutputLock` 842).
  Aussage korrekt. ERFUELLT.
- Exclusive: "Only selected devices play. The default output stays silent."
  `exclusiveRouting` an `engine.start(..., exclusive:)`
  (`EngineController.swift:349,432,603`). Aussage korrekt. ERFUELLT.
- Bug: "Opens a pre-filled bug report email with version info." `openBugReport`
  (`EngineController.swift:649-700`) baut eine mailto mit App-Version, Build,
  macOS, Hardware, Anzahl Ausgaben, Routing-Zustand. "version info" ist eher
  untertrieben, nicht falsch. ERFUELLT.
- Quit: "Quits AudioRouterNow." `NSApplication.shared.terminate`
  (`RoutingControls.swift:277`). ERFUELLT.
- Launch at Login: "Starts AudioRouterNow automatically when you log in." Toggle
  auf `controller.launchAtLogin` mit Consent-Gate
  (`RoutingControls.swift:254-263`). ERFUELLT.

accessibilityLabel ohne Hover: Support (315), Lock (330), Exclusive (343), Bug
(357), Quit (279). Launch at Login traegt das sichtbare Toggle-Label. Alle
Elemente sind auch ohne Hover benannt. ERFUELLT.

Hinweis (kosmetisch, siehe Maengelliste): Kein `accessibilityHint` im Footer
gesetzt (Grep ohne Treffer). Der erklaerende Satz ist nur in der visuellen Bubble;
VoiceOver liest den Kurztitel, nicht die Erklaerung. Die Doku
(`23-...md:490-491`) kuendigt `accessibilityHint` "wo sinnvoll" an; der
Abschlussbericht (`09-final-report.md:502`) sagt dagegen korrekt nur
"accessibilityLabel bleibt". Code und Abschlussbericht stimmen ueberein; der Satz
in 23 ist leicht ueberzogen.

## B. Hover-Bubble Robustheit

Code: `RoutingControls.swift:360-459`.

- Verzoegerung: 0.35 s ueber `DispatchQueue.main.asyncAfter`
  (`enterHover` 414-423). Kein `Task`, daher keine Task-Cancellation; stattdessen
  ein `pendingTip`-Vergleich (419): die verzoegerte Einblendung feuert nur, wenn
  der Zeiger seitdem auf demselben Element blieb. Das Rennen zwischen zwei
  Verzoegerungen ist damit korrekt entschaerft (ein spaeter geplantes `enter`
  ueberschreibt `pendingTip`, das fruehere no-op't am Guard). Funktional gleichwertig
  zur Task-Cancellation. ERFUELLT.
- Ausblenden beim Verlassen: `leaveHover` (425-430) loescht `pendingTip` und
  `hoveredTip`, aber nur wenn das verlassene Element das aktive ist (korrekt gegen
  Flackern beim Wechsel). ERFUELLT.
- Ausblenden bei Klick: Support (290), Bug (349), Quit (277) rufen `clearHover()`.
  Lock und Exclusive rufen es nicht, bleiben aber unter dem Cursor, also bleibt die
  Bubble sichtbar und zeigt weiter den (unveraenderten) Text. Kein Defekt, da der
  Tooltip-Text zustandsneutral formuliert ist. Hinweis (kosmetisch): nach einem
  Lock/Exclusive-Klick koennte die Bubble kurz den alten Zustand suggerieren; da der
  Text aber generisch ist ("while routing"), nicht irrefuehrend.
- Panel schliesst: `onDisappear { clearHover() }` (246). ERFUELLT.
- Swift-6-Concurrency: Alles laeuft im View-Body auf dem MainActor;
  `asyncAfter(deadline:)` auf `DispatchQueue.main`. `FooterTip` ist `Equatable`,
  kein geteilter Zustand ueber Aktorgrenzen. Kein Retain-Cycle (Struct-Semantik,
  keine Klassen-Closure-Referenz). Kein Timer-Objekt, das lecken koennte. ERFUELLT.
- Clamping (390-405) mathematisch nachgerechnet mit der tatsaechlichen Breite:
  Panel 320, FooterRow `.padding(14)` je Seite -> `rowWidth` R ca. 292. `bubbleWidth`
  W = 220, half = 110, `edgePadding` = 8. minCenter = 118, maxCenter = 292 − 110 − 8
  = 174. Da maxCenter >= minCenter, ist das Clamping aktiv und begrenzt den
  Bubble-Mittelpunkt auf [118, 174]. Linkes Element (Anker ca. 60): center 60 ->
  geklemmt auf 118, linke Kante 118 − 110 = 8 (= edgePadding). Rechtes Element
  (Quit, Anker ca. 278): center 278 -> geklemmt auf 174, rechte Kante 174 + 110 =
  284 (= R − 8). Die Bubble bleibt in beiden Extremen innerhalb der Reihe. Math
  korrekt. ERFUELLT. (Hinweis: die Bubble ist mit 220 fast so breit wie die Reihe
  292, sie wandert also kaum; bei grossem Text wird sie faktisch fast immer mittig
  stehen. Das ist tolerierbar.)
- Verdeckung durch die ScrollView-Liste: Die Bubble ist ein `overlay` auf
  `footerControls` im Footer, der BEWUSST ausserhalb des ScrollViews und unter einem
  Divider liegt (`MenuBarView.swift:88-105`). `offset(y: -34)` schiebt sie nach
  oben ueber den Footer in den Divider-Bereich, `zIndex(100)`. Da der ScrollView
  oberhalb endet, kann die Liste die Bubble nicht ueberlagern. ERFUELLT (am Geraet
  zu bestaetigen, dass der −34-Versatz den Divider-Bereich nicht ungluecklich
  ueberdeckt).
- Klicks abfangen: `allowsHitTesting(false)` (381). Die Bubble faengt keine Klicks.
  ERFUELLT.
- Flimmern, weil die Bubble unter dem Cursor erscheint: Die Bubble steht 34 pt
  ueber der Reihe und ist hit-test-transparent; sie kann das `onHover` des Icons
  nicht stoeren. Risiko gering. Nur am Geraet voll belegbar (NICHT PRUEFBAR ohne
  Geraet).

## C. Entfernte Pille und Reste

- Aktives Kit: `HeaderToggle.swift` und `HeaderToggleTests.swift` existieren NICHT
  mehr in `v4/AudioRouterKit/Sources/AudioRouterKit/` bzw. `/Tests/` (Verzeichnis
  gelistet). Grep nach `HeaderToggle*` im aktiven Code: 0 Treffer. Alle 167 Treffer
  liegen in `.claude/variants/C1-*`, `.claude/variants/C2-*`, `docs/` (Plan- und
  Berichtshistorie) und `docs/v4.1/02-plan-v1.md` (Planhistorie). Keine toten
  Codepfade. ERFUELLT.
- Statusbar-Toggle (P1/E3): Die fruehere Icon-Schaltflaeche in der Statuszeile und
  die Hilfsfunktionen `headerToggleIcon`/`headerToggleAction` sind aus
  `MenuBarView.swift` entfernt (Diff: −44 Zeilen in der Funktion `statusBar`). Das
  ist fuer C3 beabsichtigt und richtig (der grosse Knopf oben ersetzt sie), aber es
  bedeutet: Das in **Abschnitt 3.1** des Abschlussberichts (`09-final-report.md:66-75`)
  beschriebene Status-Bar-Icon-Toggle (E3) existiert nicht mehr. Die spaeteren
  Nachtrag-Abschnitte C2 (471) und C3 (491) stellen das klar, 3.1 selbst traegt aber
  keinen Vorwaerts-Hinweis und liest sich wie der Endstand. -> **Mangel (sollte
  behoben werden): ein Satz in 3.1, dass E3 im Nachtrag C3 entfernt wurde.**
- Funktionsverlust des oberen Knopfs: Der obere Knopf ist ein `RoutingButton`
  (`MenuBarView.swift:50`, `RoutingControls.swift:89-155`) und deckt alle Zustaende
  ab: Start (idle/error, gefuellte Mint-Pille), Connecting (Spinner, deaktiviert),
  Stop (umrandet), gedimmt ohne Auswahl (`disabled` 133-135). Fehler = idle-Optik.
  Keine Funktion verloren. ERFUELLT.
- Doku-Konsistenz CHANGELOG/README/23: CHANGELOG (125-140) beschreibt oberen
  Knopf als einzigen Start/Stop-Knopf, Support-Button, Hover-Bubble; konsistent mit
  C3. README-Eintrag (35) und 23-...md-Abschnitt C3 konsistent. Abschlussbericht
  C3-Abschnitt (483-517) konsistent und ehrlich. Nur 3.1 (siehe oben) haengt
  historisch nach.

## D. Footer-Layout

Eine Reihe (`footerControls`, `RoutingControls.swift:251-281`): Launch at Login,
Support-Pille, Spacer, Lock, Exclusive, Bug, Quit. HStack spacing 10, Rahmenbreite
292 (320 − 28).

- Grobe Breitenschaetzung bei Standard-Textgroesse (System 11): "Launch at Login"
  Checkbox ca. 120 pt, Support-Pille ca. 70 pt, drei Icons je 12 pt plus Spacing,
  Quit ca. 30 pt, dazu 6 × spacing 10 = 60 pt. Summe der festen Teile ca. 305 pt,
  der `Spacer` traegt den Ausgleich. Das ist bei 292 pt bereits knapp; bei
  Standardgroesse rettet der flexible Spacer das Layout (er schrumpft auf 0), es
  passt gerade. Der Umsetzer meldet selbst, dass "Launch at Login" bei engem Platz
  zweizeilig umbrechen kann. Das ist plausibel: SwiftUI bricht Text eher um, als die
  Reihe zu sprengen, sobald Dynamic Type / Bedienungshilfen die Schrift vergroessern
  (ab ca. "Large"/"xLarge"). -> **Mangel (sollte behoben werden): an "Launch at
  Login" `lineLimit(1)` plus `fixedSize(horizontal: true, vertical: false)`, damit
  es nicht umbricht; wird es dadurch abgeschnitten, ist eine zweite Reihe die
  robustere Loesung.** Kein Blocker, weil es nur bei vergroesserter Schrift auftritt
  und keine Funktion verliert.
- Fensterhoehen: Die Werte (idle 270, aktiv 247, lange Liste 589 pt) stammen aus
  dem `ImageRenderer`-Nachbau (`09-final-report.md:511`), nicht vom echten Panel.
  Plausibel gegen den Deckel `maxHeight: 400` am ScrollView plus Statuszeile,
  oberem Knopf, Divider und einreihigem Footer; dass C3 gegenueber C2 (621 pt) durch
  die eingesparte zweite Footer-Reihe niedriger liegt, ist stimmig. Alle unter 700.
  Die konkrete Zahl ist nur am Geraet belegbar (der Nachbau ist eine Annaeherung);
  so ist sie im Bericht auch als Nachbau gekennzeichnet. ERFUELLT (als Schaetzung).

## E. App-Review-Regeln

- Launch at Login bleibt als sichtbare Checkbox bedienbar
  (`RoutingControls.swift:254-264`, `toggleStyle(.checkbox)`), Guideline 2.4.5(iii),
  Entscheidung D1 (`docs/v4.1/05-decisions.md`). ERFUELLT.
- Support-Pille: Begriff "Support", Herz, dezente Mint-Fuellung, kein Badge, kein
  Zaehler, keine Dauer-Animation, kein Preis im UI. Oeffnet den Tip Jar (freiwilliger
  In-App-Kauf, der nichts freischaltet, Beleg siehe A). Keine Irrefuehrung, nicht
  aufdringlich, kein Dauerhinweis. Unkritisch bezueglich Spenden-/IAP-Richtlinien,
  soweit am Code und Text belegbar (keine Rechtsberatung). ERFUELLT.

## F. Tests und Stil

Lauf: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash
v4/scripts/test.sh` nach /tmp. Ergebnis: **60 swift-testing in 10 Suites, 0
Fehler; 110 XCTest, 0 Fehler.** Entspricht der Erwartung (60 + 110). `git status
--short` vor und nach dem Lauf identisch (test.sh nutzt `.build`, gitignored; das
Skript aendert keine Repo-Datei). ERFUELLT.

FooterTipsTests (14 Methoden, echte Inhaltspruefung, keine Scheintests): nicht
leer (19), Laenge <= 90 (25), Em-Dash (33), Doppelbindestrich (40), Superlativ-
Wortliste (46), isValid auf allen Texten (56); isValid als Waechter, der ablehnt:
leer (64), zu lang (68), Em-Dash (73), Doppelbindestrich (77), Superlativ (81),
Wortgrenze "bestimmt" nicht faelschlich abgelehnt (90), genau 6 Elemente (98).
Aussagekraeftig. ERFUELLT.

Stil neue Zeilen (`git diff -U0 | grep '^+'`): kein " — ", kein " -- ", kein
Em-Dash-Zeichen, kein Superlativ, kein Klarname (ausser Copyright-Zeile).
ERFUELLT.

Keine neue Datei im App-Target: FooterTips.swift und FooterTipsTests.swift liegen
im SPM-Paket; die View-Aenderung liegt in der bestehenden RoutingControls.swift.
ERFUELLT.

## G. Test-App

`~/Desktop/AudioRouterNow 4.1 TEST C3.app` (gebaut 2026-11-16 19:40):
- `codesign --verify --deep --strict` exit 0.
- Entitlements: `com.apple.security.app-sandbox` true, `device.audio-input` true.
- Bundle-ID `com.mauriciomorkun.audiorouternow.test`, Version 4.1, Build 11,
  Anzeigename "AudioRouterNow 4.1 TEST C3".
Die drei anderen Test-Apps unveraendert (Zeitstempel 04:42, 05:37, 09:31, alle vor
dem C3-Build 19:40). Keine App gestartet. ERFUELLT.

## H. Sonstiges

- Regressionen gegen M1, M2, M2b: M2 und M2b sind im Abschlussbericht auf C3
  angepasst (283-284), neu M2c fuer die Hover-Erklaerungen (285) mit den exakten
  Texten. Keine Code-Regression erkennbar; der obere Knopf ist unveraendert aus C2
  uebernommen. ERFUELLT.
- Ehrlichkeit der neuen Pruefzeilen: M2b und M2c sind vollstaendig und ehrlich
  formuliert; das "nicht am Geraet geprueft" steht im C3-Abschnitt (513-515)
  ausdruecklich (echtes Aussehen, Hover-Verhalten, Verzoegerung, Trackpad gegen
  Maus, VoiceOver, Tab-Fokus). ERFUELLT.

Verbleibende Risiken: (1) Hover nur am Geraet voll belegbar (Verzoegerung,
Flackern, Trackpad gegen Maus, −34-Versatz ueber dem Divider). (2) "Launch at
Login"-Umbruch bei grosser Dynamic Type (D). (3) VoiceOver bekommt die
Erklaerung nicht (nur Kurzlabel), falls das gewuenscht ist. (4) Die
gerenderten Hoehen sind Nachbau, nicht das echte Panel.

## Maengel nach Schwere

### Blocker
Keine.

### Sollte behoben werden
1. **Doku-Nachzug in 3.1** (`09-final-report.md:66-75`): E3-Status-Bar-Toggle ist
   in C3 entfernt, 3.1 beschreibt es noch als Endstand. Korrektur: ein Satz, der
   auf den Nachtrag C3 verweist (Toggle entfernt, grosser Knopf oben ist der einzige
   Start/Stop-Knopf).
2. **"Launch at Login" Umbruch** (`RoutingControls.swift:254`): bei vergroesserter
   Schrift droht Zweizeiligkeit. Korrektur: `.lineLimit(1)` plus
   `.fixedSize(horizontal: true, vertical: false)` am Toggle; falls es dadurch
   abgeschnitten wirkt, zweite Footer-Reihe. Nur am Geraet mit grosser Dynamic Type
   endgueltig zu bewerten.

### Kosmetisch
3. **VoiceOver-Erklaerung**: Kein `accessibilityHint` gesetzt. Optional den
   FooterTips-Text als `accessibilityHint` an die Elemente haengen, damit VoiceOver
   dieselbe Erklaerung liest wie die Bubble. Der Satz in `23-...md:490-491` ("Hint
   bleibt wo sinnvoll") sonst leicht entschaerfen.
4. **Nicht-C3-Diff**: `.gitignore` enthaelt eine Aenderung
   (`docs/homepage-redesign/`), die nichts mit C3 zu tun hat. Nicht mit dem
   C3-Commit vermischen; separat behandeln.
5. **Bubble nach Lock/Exclusive-Klick** (`RoutingControls.swift:320-344`): kein
   `clearHover()` bei diesen zwei Knoepfen. Unkritisch, weil der Text zustandsneutral
   ist; optional zur Konsistenz mit Support/Bug ergaenzen.

## Nur am Geraet pruefbar
- Echtes Hover-Verhalten im nicht-aktivierenden MenuBarExtra-Panel: Verzoegerung
  0,35 s, Ausblenden, Flackerfreiheit beim Wechsel, Trackpad gegen Maus.
- Der `offset(y: -34)` der Bubble ueber dem Divider (Ueberdeckung, Abschnitt).
- "Launch at Login"-Umbruch bei grossen Dynamic-Type-Stufen.
- VoiceOver-Reihenfolge und Tab-Fokus (grosser Knopf frueh im Fokus).
- Echte Fensterhoehen (die Zahlen sind ImageRenderer-Nachbau).
- Absturzfreiheit im echten View-Baum (Bezug CASE-003, R1).
