# AudioRouterNow 4.1: Umsetzungsprotokoll v1

Umsetzer: Opus (Phase 2 des Fable/Opus/Fable-Kreislaufs), nach Plan
`docs/v4.1/02-plan-v1.md` (Commit `e7db9fe`).

Stil wie `docs/v4.0.1/`. Dieses Protokoll trennt strikt zwischen belegt,
gebaut, getestet und offen (Nutzer muss messen).

---

## Rahmen und Abweichungen vom Plan (gelten vorrangig)

Der Hauptagent hat einen Stand nachgereicht, der dem Plan an einzelnen
Stellen vorgeht:

- **S0 ohne Lizenz-Schritt.** Die Xcode-Lizenz ist akzeptiert. Der Plan-Schritt
  "sudo xcodebuild -license accept" entfaellt. `xcode-select` zeigt weiter auf
  die Command Line Tools, deshalb bekommt jeder Xcode-Aufruf
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` vorangestellt
  (`v4/scripts/test.sh` setzt das selbst).
- **Bestaetigte Entscheidungen:** E1 (maxHeight 400 pt), E3 (Icon-Button in der
  Statuszeile), E4 (0.4-Opacity fuer durch fremdes Solo stummgeschaltete Cards),
  E6 (Blip verwirft den Restart). Genau diese sind umgesetzt. Sie bleiben im
  Bericht trotzdem als "vom Nutzer bestaetigt" markiert, nicht als "am Geraet
  verifiziert".
- **S10** bleibt reine Nutzeraufgabe (App Store Connect), im Repo nur S9.

---

## Baseline (S0)

| Pruefung | Ergebnis |
|----------|----------|
| Branch | `release/4.1`, `git status` sauber |
| Testsuite | `bash scripts/test.sh`: **59 Tests in 10 Suiten, alle gruen** |
| App-Build | **BUILD SUCCEEDED** |

Funktionierender App-Build-Befehl (verifiziert, keine Projektdatei dauerhaft
geaendert):

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project AudioRouterNow/v4/AudioRouterNow4.xcodeproj \
  -scheme AudioRouterNow4 -configuration Debug CODE_SIGNING_ALLOWED=NO
```

Versionsdaten vor S1: `MARKETING_VERSION = 4.0.1`, `CURRENT_PROJECT_VERSION = 10`.

---

## Schritt-Protokoll

### S0 Baseline, entfällt als Lizenz-Schritt, erledigt
Lizenz bereits akzeptiert. Tests 59/59 gruen, App-Build SUCCEEDED. Branch
`release/4.1` sauber. Preflight-Nebenbefund: ein ABBRUCH "Archiv ist 4.0.1 (10)"
betrifft ein altes, auf der Platte liegendes Archiv, nicht die Versionsquelle;
die Versionspruefung selbst meldet "xcconfig sagt 4.1 (11)" OK. Kein Commit (S0).

### S1 Versionsnummer auf 4.1 (Build 11), erledigt
- Commit: `04a0589`
- Datei: `v4/Configs/AudioRouterNow4.xcconfig` (4.0.1/10 → 4.1/11)
- Test: 59/59 gruen. Preflight: "xcconfig sagt 4.1 (11)" OK, "Keine zweite
  Versionsquelle" OK, "Tag v4.1 existiert noch nicht" OK.
- Abweichung: keine.

### S2 ScrollView + Header-Toggle, erledigt (Build), Messung offen
- Commit: `7700c3f`
- Datei: `v4/AudioRouterNow4/MenuBarView.swift`
- Geraeteliste in `ScrollView(.vertical).frame(maxHeight: 400)` gekapselt (E1),
  Footer bleibt ausserhalb, `.fixedSize(vertical: true)` am Root bleibt. Header-
  Toggle (SF Symbol play.fill/stop.fill/ellipsis) rechts in der Status-Bar (E3).
- Abweichung (minimal): Die Disabled-Bedingung des Toggles wurde auf
  `ui == .starting || (controller.outputConfigs.isEmpty && !ui.isActive)` gesetzt,
  deckungsgleich mit `RoutingButton.disabled`. Der Plan skizzierte
  `(ui == .idle && outputConfigs.isEmpty)`, was im error-Zustand abweichen wuerde.
  Begruendung: Plan verlangt "genau dieselbe Aktionslogik wie RoutingButton".
- Build SUCCEEDED, keine Warnungen. Test: 59/59 gruen (UI nicht in Tests).
- NUTZER MUSS MESSEN: M1 (ScrollView, 45+ Eintraege, Footer sichtbar, 13"-Panel),
  M2 (Toggle startet/stoppt, starting deaktiviert).

### S3 Solo-Zustand in EngineController, erledigt (Build)
- Commit: `aabe549` (plus Delegations-Edit in `6e71278`, siehe S4)
- Datei: `v4/AudioRouterNow4/EngineController.swift`
- `soloedKeys` (@Published, Session-only), `toggleSolo(for:)`, `applySoloGains()`.
  `setDeviceGain` solo-aware: persistiert IMMER den User-Wert, gibt der Engine 0,
  wenn der Slot durch fremdes Solo stumm ist. Solo wirkt nur ueber
  `engine.setOutputGain`, nie ueber `setDeviceGain`/`saveDeviceGains` (CASE-004/R3,
  A1). `soloedKeys = []` in `stopRouting()` (A5). `applySoloGains()` nach
  `performStart()`, `restartRouting()`, `applyOutputsIfRouting()` und
  `warmRestartForSampleRateChange()`, jeweils nur bei nicht-leerem Solo (A6).
- Build SUCCEEDED. Test: 59/59 gruen.
- Randfall M5 (Slots >= maxSlots=16): `engine.setOutputGain` ignoriert Keys
  ausserhalb maxSlots bereits (FanOutEngine.swift:196), Solo kann solche Slots
  nicht stummschalten. Bekannt und dokumentiert, keine Aenderung an maxSlots.

### S4 Unit-Tests fuer Solo-Logik, erledigt
- Commit: `6e71278`
- ABWEICHUNG/LÜCKE (dokumentiert): Der Plan legte `effectiveSoloGain` als static
  auf `EngineController` (App-Target) und wollte es aus dem SPM-Test-Target
  testen. Das ist unmoeglich: die SPM-Tests importieren nur `AudioRouterKit`,
  der App-Target ist nicht erreichbar. Konservativste Loesung: die reine Funktion
  als `SoloGain.effective` in eine neue Kit-Datei (`SoloGain.swift`) verschoben,
  `EngineController` delegiert daran. Eine einzige Quelle der Wahrheit, kein
  Duplikat (das waere genau der CASE-004-Fehler). Neue Kit-Dateien sind laut Plan
  (Leitplanken) ausdruecklich erlaubt.
- Neue Dateien: `SoloGain.swift` (Kit), `SoloGainTests.swift` (7 XCTest-Faelle).
- Test: 59 swift-testing + XCTest inkl. 7 neuer SoloGainTests, alle gruen.
- Build SUCCEEDED.

### S5 Solo-Button in DeviceCardView, erledigt (Build), Messung offen
- Commit: `146fbbb`
- Datei: `v4/AudioRouterNow4/UI/DeviceCardView.swift`
- `soloButton` (SF Symbol s.circle / s.circle.fill) rechts vom Chevron, nur im
  Active-Zustand, ruft `controller.toggleSolo(for:)`. `isMutedBySolo`-Computed
  setzt die Card-Opacity auf 0.4, wenn der Slot durch fremdes Solo stumm ist (E4).
- Build SUCCEEDED. Test: 59/59 gruen.
- NUTZER MUSS MESSEN: M3 (Solo ohne Knacksen), M4 (Solo bei abgestecktem Geraet).

### S6 SR-Listener mit Aenderungserkennung, erledigt (Build)
- Commit: `695e617`
- Datei: `v4/AudioRouterKit/Sources/AudioRouterKit/DeviceLifecycleManager.swift`
- `srBaselines`, `srNoopCount`, statische `readNominalSampleRate` und
  `srChangedSignificantly` (0.5 Hz Toleranz, nil → konservativ true, R4).
  `registerSRListeners` liest Baseline je Device, Block vergleicht; nur echter
  Wechsel triggert `scheduleSRRestart`, sonst M4-Noop-Log (.log, .public, ohne
  Geraetenamen). `stop()` setzt `srBaselines` zurueck, `srNoopCount` bleibt.
- Build SUCCEEDED. Test: 59/59 gruen.

### S7 Unit-Tests fuer SR-Aenderungserkennung, erledigt
- Commit: `d5b08e5`
- Neue Datei: `SRListenerTests.swift` (6 XCTest-Faelle: gleiche Rate, kleine
  Aenderung, echter Wechsel, nil konservativ, Grenze 0.5 exakt, knapp darueber).
- Test: alle gruen. Build SUCCEEDED.

### S8 Entprellen beim Entfernen von Geraeten, erledigt (Build), Messung offen
- Commit: `5798a63`
- Datei: `v4/AudioRouterKit/Sources/AudioRouterKit/DeviceLifecycleManager.swift`
- L1-Re-Appear-Pfad: ist `pendingRestart != nil` (Geraet kam innerhalb der
  Settle-Frist zurueck, Blip), wird der ausstehende Restart verworfen statt
  durch einen neuen 2-s-Restart ersetzt (E6, A8). Ausserhalb der Frist
  (pendingRestart == nil) unveraendert der 2-s-Pfad.
- Build SUCCEEDED. Test: 59/59 gruen.
- NUTZER MUSS MESSEN: M8 (USB-Blip, keine/kuerzere Unterbrechung; bei dauerhaftem
  Audio-Riss ist S8 umzukehren).

### S9 Store-Description-Pruefung im Repo, erledigt, KEIN Commit (nichts zu aendern)
- ABWEICHUNG vom Plan-Akzeptanzkriterium: Der Plan verlangt, den Satz
  "the only sandboxed" in README/RELEASE_NOTES/landing-page zu ersetzen und per
  `grep -r` keine Treffer mehr zu haben. Am Repo geprueft (`git grep` auf
  getrackte Dateien): KEINE getrackte, nutzersichtbare Datei enthaelt den Satz.
  Er steht nur in `MARKETING.md`, `BACKLOG.md` und `LAUNCH_EXECUTION.md`, und
  diese drei sind alle **gitignored** (nicht Teil des Repos), sowie im Plan
  selbst (`docs/v4.1/02-plan-v1.md`, der den grep-Zielstring zitiert).
  `MARKETING.md` ist zudem per Projektregel tabu (Marketing, gitignored).
- Folge: im committeten Repo ist nichts zu ersetzen, das Akzeptanzkriterium ist
  bereits erfuellt. Kein Commit fuer S9. Die eigentliche Superlativ-Stelle liegt
  in der App-Store-Connect-Description (S10, nur Nutzer).
- `git grep -l "the only sandboxed" -- README.md RELEASE_NOTES.md 'landing-page/*'`
  liefert keine Treffer.

### S10 Store-Description in App Store Connect, NUTZER MUSS EINTRAGEN
- Reine Nutzeraufgabe (externes System). Keine Repo-Aenderung, kein Commit.
- Vorlage (aus Plan/BACKLOG): "AudioRouterNow runs fully sandboxed. No kernel
  extension. No virtual driver. No reboot."

### S11 CHANGELOG und RELEASE_NOTES, erledigt
- Commit: `8f0496e`
- Dateien: `CHANGELOG.md` (Abschnitt `[4.1 (11)], YYYY-MM-DD`), `RELEASE_NOTES.md`
  (Abschnitt "AudioRouterNow 4.1 (Build 11), not yet submitted").
- Rein technischer Inhalt, keine Marketing-Texte, keine Nutzernamen, keine
  Em-Dashes in den neuen Zeilen (geprueft, 0 Treffer im Diff). Datum als
  Platzhalter bis zur Einreichung.
- Test: 59/59 gruen (Docs ohne Testwirkung).

### S12 Abschluss-Testlauf und preflight, erledigt, KEIN Commit
- Testsuite: **59 swift-testing in 10 Suiten + 56 XCTest, alle gruen.** XCTest von
  43 (Baseline) auf 56 gestiegen (+13: 7 Solo, 6 SR).
- App-Build: **BUILD SUCCEEDED.**
- Preflight: Version "4.1 (11)" OK, "Keine zweite Versionsquelle" OK, "Tag v4.1
  existiert noch nicht" OK. WARNUNG `v4-appstore/` (bekannt, erwartet). WARNUNG
  nicht committet/nicht gepusht (nur dieses Protokoll offen; kein Push ist
  Absicht). ABBRUCH "Archiv ist 4.0.1 (10)" betrifft das alte, auf der Platte
  liegende Release-Archiv von 07.10.2026, NICHT die aktuelle Quelle; ein frisches
  4.1-Archiv entsteht erst beim Einreichen (ausserhalb dieses Scopes).

---

## Gesamtstand

| Kennzahl | Wert |
|----------|------|
| Plan-Schritte | 13 (S0-S12) |
| Erledigt (Code/Doku) | S0, S1, S2, S3, S4, S5, S6, S7, S8, S9, S11, S12 |
| Nutzeraufgabe | S10 (App Store Connect) |
| Commits | `04a0589` bis `8f0496e` (plus dieses Protokoll) |
| Testsuite vorher | 59 swift-testing + 43 XCTest |
| Testsuite nachher | 59 swift-testing + 56 XCTest, alle gruen |
| App-Build | SUCCEEDED (Debug, CODE_SIGNING_ALLOWED=NO) |

## Abweichungen und Luecken

1. **S4 (Testbarkeit):** `effectiveSoloGain` nicht als static auf
   `EngineController` (App-Target, aus SPM-Tests unerreichbar), sondern als
   `SoloGain.effective` in einer neuen Kit-Datei. Eine Quelle der Wahrheit,
   kein Duplikat. Neue Kit-Dateien sind laut Plan erlaubt.
2. **S2 (Disabled-Logik):** Header-Toggle nutzt exakt
   `RoutingButton.disabled` statt der Plan-Skizze, um die geforderte Deckung mit
   RoutingButton herzustellen (weicht nur im error-Zustand von der Skizze ab).
3. **S9 (nichts zu ersetzen):** Der Superlativ steht in keiner getrackten,
   nutzersichtbaren Datei; alle Fundstellen sind gitignored oder der Plan selbst.
   Kein Commit noetig, Akzeptanzkriterium bereits erfuellt.

## NUTZER MUSS MESSEN (offen, aus dem Plan, Abschnitt 6)

Keiner dieser Punkte ist durch Build oder Unit-Test verifizierbar. Alle offen.

- **M1 ScrollView, 45+ Eintraege.** BlackHole 64ch + Interface verbinden, Panel
  oeffnen: Scroll-Indikator sichtbar, Liste scrollbar, Footer immer sichtbar,
  Header-Toggle sichtbar; auf MacBook 13" passt das Panel auf den Bildschirm.
- **M2 Header-Toggle.** idle: play.fill startet; active: stop.fill stoppt;
  starting: deaktiviert. Kein Doppelstart.
- **M3 Solo ohne Knacksen.** Zwei+ Outputs, Routing aktiv, Musik: Solo ein/aus,
  anderen solo'en, Regler eines stummen Outputs bewegen; nach Solo-Aufheben
  gilt der neue Wert. Kein Knacksen, kein Pegelsprung.
- **M4 Solo bei abgestecktem Geraet.** Solo-Geraet entfernen: alle anderen stumm;
  nach Solo-Aufheben hoeren alle verbliebenen wieder.
- **M5 maxSlots-Grenze (16).** Genau 16 Outputs: Solo deaktiviert Slots 0-15,
  Slot 16+ spielt weiter (bekannte Einschraenkung, `setOutputGain` ignoriert
  Keys ausserhalb maxSlots).
- **M6 SR-Noop-Rate.** 15+ min aktiv ohne SR-Wechsel, `log stream` auf
  `com.mauriciomorkun.audiorouternow` nach "M4-Noop" greppen; Zaehler soll 0 oder
  sehr niedrig sein.
- **M7 SR-Restart bei echtem Wechsel.** Rate per Audio MIDI Setup 48→44.1 kHz:
  Warm-Restart innerhalb 1-3 s, kein "M4-Noop".
- **M8 Blip-Absorption.** USB-Kabel unter 2 s loesen und einstecken: kuerzere
  oder keine Unterbrechung als 4.0.1. Reisst Audio dauerhaft, S8 umkehren.

## Vom Nutzer bestaetigte Entscheidungen (nicht am Geraet verifiziert)

E1 (maxHeight 400 pt), E3 (Icon-Button in der Status-Bar), E4 (0.4-Opacity fuer
stumm-durch-Solo), E6 (Blip-Restart verwerfen). Vom Nutzer vor der Umsetzung
bestaetigt, am Geraet NICHT verifiziert (siehe M1-M8).

## Schritte mit Restrisiko

- **S2 (R1, CASE-003):** ScrollView im View-Baum, in dem der gemeldete Absturz
  auftrat. `maxHeight: 400` gibt eine endliche Hoehe, kein GeometryReader/
  PreferenceKey. Absturzfreiheit nur am Geraet belegbar (M1).
- **S3/S5 (R2/R3, CASE-004):** Solo schreibt 0 ueber `engine.setOutputGain`, die
  W1-Rampe im IOProc bleibt unberuehrt. `deviceGains`/UserDefaults werden von
  Solo nie geschrieben. Knacksfreiheit am Geraet (M3).
- **S6 (R4):** Konservativer nil-Fall deckt den gefaehrlicheren Fehlerzweig,
  Unit-Test vorhanden. Reale Noop-Rate nur am Geraet (M6/M7).
- **S8 (R5/E6, CASE-007-Wechselwirkung):** Verwerfen nur bei aktivem
  pendingRestart (innerhalb der Frist). Der VolumeTracker-Freeze aus CASE-007
  wird beim naechsten echten Restart durch `start()` geloescht; bei einem
  absorbierten Blip laeuft der Tracker ohne Freeze weiter (korrekt). Blip-
  Unversehrtheit nur am Geraet (M8).
