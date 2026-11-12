# AudioRouterNow 4.1: Durchführungsplan v1

Erstellt: 2026-11-12 (Planer: Fable 5, Phase 1 des Fable/Opus/Fable-Kreislaufs)

---

## 1. Kopf

### 1.1 Ziel

v4.1 bringt fünf inhaltliche Punkte: (P1) ScrollView für die Geräteliste
und Start/Stop-Toggle im Header, (P2) Solo-Button pro Output, (P3) SR-Listener
prüft tatsächliche Ratenänderung und Entprellen beim Entfernen von Geräten,
(P4) Store-Description ohne Superlativ und (P5) Versions- und Release-Mechanik.

### 1.2 Scope-Freeze (verbindlich)

Enthalten: P1, P2, P3, P4, P5.

Ausdrücklich ausgeschlossen: AirPlay-Integration (Recherche unter
`docs/v4.1/01-airplay-research.md`, Echttest gegen Hardware offen), Per-App-
Routing, Bluetooth-Latenzkompensation, Intel-Support, Marketing-Inhalte,
`v4-appstore/` aufräumen, Einreichung bei App Store Connect, kein Push.

### 1.3 Branch

`release/4.1` (bereits vorhanden, sauber, keine offenen Änderungen zum
Zeitpunkt der Planung).

### 1.4 Baseline (Build und Tests)

**Xcode-Lizenz nicht angenommen.** Beim Planer schlägt `sudo xcodebuild
-license accept` fehl (kein sudo-Terminal), damit ist der Swift-Test-Lauf
(`v4/scripts/test.sh`) in dieser Phase gesperrt. Der Umsetzer MUSS als
allerersten Schritt die Lizenz annehmen (`sudo xcodebuild -license accept`)
und dann den vollständigen Test-Lauf ausführen.

Erwarteter Befehl fuer den Test-Lauf:
```
cd /Users/mauriciomorkun/AudioRouterNow/v4
bash scripts/test.sh
```

Erwartetes Ergebnis (Referenz `docs/v4.0.1/04-verification.md`): 7 Test-
Suiten, mindestens 59 Faelle, alle gruen. Der genaue Zaehlstand ist nach
Annahme der Lizenz durch den Umsetzer in den Plan-Abschluss einzutragen.

Fuer einen Build ohne Einreichung gilt: `CODE_SIGNING_ALLOWED=NO` in der
Debug-Konfiguration erlaubt einen lokalen Build (kein Archiv, keine
Notarisierung). Befehl (ungeprüft, durch den Umsetzer zu verifizieren):
```
xcodebuild build \
  -project v4/AudioRouterNow4.xcodeproj \
  -scheme AudioRouterNow4 \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "^(error:|Build succeeded)"
```

Keine Projektdateien dauerhaft aendern, um den Build zu ermoeglichen
(kein `CODE_SIGNING_ALLOWED=NO` in Projektdateien eintragen).

Aktuelle Versionsdaten (verifiziert):
- `MARKETING_VERSION = 4.0.1`
- `CURRENT_PROJECT_VERSION = 10`
- Datei: `v4/Configs/AudioRouterNow4.xcconfig`

Consent-Schluessel (verifiziert in `EngineController.swift:113-128`):
- `arn.v4.launchAtLoginExplicitlyOptedIn`
- `arn.v4.launchAtLoginConsentBuildNumber`
- Prüfung: `hasValidLaunchAtLoginConsent()` vergleicht den gespeicherten Build-
  String gegen `CFBundleVersion`. Bei Build-Nummer-Aenderung von 10 auf 11
  loescht `ensureLoginItemCompliance()` beim ersten Start automatisch veraltete
  Eintraege und deregistriert das Login-Item, falls kein gultiger Consent
  vorliegt. Das Verhalten ist korrekt und Absicht (Guideline 2.4.5(iii)).

### 1.5 Leitplanken

- Kein Lock ausser `os_unfair_lock` im Echtzeitpfad.
- Kein Alloc im IOProc (kein neues Array, kein neues Objekt).
- Keine neuen Swift-Dateien in `v4/AudioRouterNow4/` (Signierungsverlust durch
  XcodeGen, Ausnahme nur mit explizitem Plan-Schritt).
- Neue Swift-Dateien im SPM-Package `AudioRouterKit` sind unproblematisch:
  SwiftPM findet sie automatisch.
- `deviceGains` (UserDefaults) wird durch Solo nie beschrieben.
- Footer bleibt ausserhalb des ScrollViews.
- Keine Marketing-Texte, keine Nutzernamen in Commits oder Docs.
- Konventionelle Commit-Messages, Scope in Klammern.

---

## 2. Entscheidungen

### E1: maxHeight des ScrollViews (P1)

Frage: Fixer Wert oder prozentual von der Bildschirmhoehe?

Optionen:
- A) Fixer Wert 400 pt
- B) Fixer Wert 500 pt
- C) `0.6 * NSScreen.main?.frame.height`

Wahl: **A, 400 pt**.

Begruendung: Ein MacBook 13" hat typisch 800 pt nutzbare Panel-Hoeche unter
der Menue-Bar. 400 pt = 50 %, laesst 50 % fuer Header (ca. 100 pt), Status-
Bar, Volume-Slider, Footer und Luft. 500 pt riskiert auf kleinen Displays
(MacBook 13" in Standard-Aufloesung) einen Footer-Abschnitt. 400 pt zeigt bei
45 Eintraegen (je ca. 44 pt) etwa 9 Eintraege auf einmal, was klar scrollbar
signalisiert. Der prozentuale Ansatz (C) verlangt `NSScreen`-Zugriff im
SwiftUI-Body, erfordert `.onAppear` mit einem @State fuer die Hoehe und
wuerde den View komplexer machen als noetig.

ENTSCHEIDUNG NUTZER BESTÄTIGEN: 400 pt als maxHeight fuer den ScrollView.
Alternative: 450 pt oder 500 pt falls der Nutzer ein anderes Verhaeltnis
bevorzugt.

### E2: Scroll-Indikator (P1)

Wahl: **sichtbar (kein `.scrollIndicators(.hidden)`)**.

Begruendung: Ein sichtbarer Indikator signalisiert dem Nutzer sofort, dass die
Liste scrollbar ist. macOS-Material passt sich optisch an.

### E3: Header-Toggle-Platzierung (P1)

Frage: Klickbarer Status-Text oder separates Icon?

Wahl: **Kleiner Play/Stop-Button rechts in der Status-Bar, neben dem
Callback-Zaehler.**

Begruendung: Den Status-Text selbst anklickbar zu machen (RoutingButton-
Duplikat auf Text) erzeugt eine unerwartete Treffflaeche. Ein Icon-Button
rechts in der vorhandenen HStack-Zeile (`statusBar`) ist diskret, bleibt in
der bestehenden UI-Sprache (SF Symbols, `.plain` ButtonStyle) und benoetigt
keinen neuen View-Baustein. Der Button ist im `.starting`-Zustand deaktiviert.

ENTSCHEIDUNG NUTZER BESTÄTIGEN: Ein Icon-Button (SF Symbol `play.fill` /
`stop.fill`) rechts in der Status-Bar. Alternative: den gesamten Status-Banner
(`statusBar`-HStack) als Schaltflaeche.

### E4: Solo-Visueller Zustand (P2)

Frage: Wie unterscheidet sich "solo aktiv" von "durch anderes Solo stumm"?

Wahl: **Zwei Zustaende: (a) Solo-Button leuchtet in `ARNColor.accent` wenn der
eigene Slot solo'ed ist, (b) DeviceCardView zeigt `.opacity(0.4)` wenn der
Slot durch ein fremdes Solo stummgeschaltet ist.**

Begruendung: Dasselbe Muster wie der STARTING-Dimm-Effekt (`state.isStarting`
setzt `.opacity(0.55)` in `DeviceCardView`). Kein neuer Design-Token noetig.

ENTSCHEIDUNG NUTZER BESTÄTIGEN: Visueller Kontrast fuer stumm-durch-Solo
(0.4-Opacity der ganzen Card).

### E5: Gain-Rampe fuer Solo (P2)

Frage: Braucht ein Solo-Schaltvorgang eine Rampe im IOProc?

Analyse: `SlotGains.set(_:slotIndex:)` schreibt sofort ohne Rampe. Der IOProc
hat allerdings bereits einen linearen Gain-Ramp (W1, `lastSV`-Array in
`makeDirectIOBlock`) fuer jeden Gain-Sprung: `svStep = (targetSV - currentSV)
/ Float32(n)` wird bei jedem Callback berechnet. Wenn der Gain sich innerhalb
eines Callbacks von 0.7 auf 0.0 aendert, rampt der IOProc innerhalb dieses
Callbacks linear. Das dauert bei 512 Frames / 48 kHz ca. 10 ms und ist
ausreichend um Zipper-Noise zu vermeiden. Die bestehende W1-Rampe genuegt.

Wahl: **Keine zusaetzliche Rampe. Der bestehende W1-Ramp im IOProc genuegt.**

Begruendung: Keine neue Zustandsvariable im RT-Pfad, kein Alloc, kein neuer
Lock.

### E6: Blip-Fenster fuer Entprellen (P3)

Frage: Wie gross ist das Blip-Erkennungsfenster?

Analyse am Code (`DeviceLifecycleManager.swift`): Ein Verschwinden eines
Gerats loest bereits einen `hdmiSettleDelay = 3.0s`-Restart aus. Der
Re-Appear-Pfad (L1) ersetzt diesen Restart durch einen neuen 2-s-Restart
(`btSettleDelay`). Ein Blip erzeugt also bereits ca. 2 s nach Rueckkehr
genau einen Restart. Der BACKLOG-Vorschlag "300 ms" war fuer einen Ist-Stand
ohne Settle-Delay formuliert, passt nicht.

Die eigentliche Verbesserung: Wenn das Geraet INNERHALB des 3-s-HDMI-Fensters
zurueckkehrt, soll der ausstehende Restart verworfen werden (nicht durch einen
neuen 2-s-Restart ersetzt).

Implementierung: Im `handleDevicesChanged`-Re-Appear-Pfad (L1) pruefen: ist
noch ein `pendingRestart` aktiv (Geraet kam innerhalb der Settle-Frist zurueck),
diesen verwerfen statt `scheduleRestart` aufzurufen.

KERNRISIKO: Verwerfen ist nur korrekt, wenn Aggregate und Tap den Blip
unbeschadet ueberstehen. Das ist am Geraet zu messen, nicht belegbar aus dem
Code. Der Umsetzer implementiert die Logik, markiert sie aber explizit als
"unbelegt fuer Blips laenger als 1 Frame".

Wahl: **Blip-Erkennung: pendingRestart verwerfen wenn Geraet innerhalb der
laufenden Settle-Frist zurueckkommt (kein neuer Restart). Fuer Geraete, die
ausserhalb der Frist zurueckkehren, gilt weiterhin der bestehende 2-s-Pfad.**

ENTSCHEIDUNG NUTZER BESTÄTIGEN: Verwerfen des Restarts bei Blip-Erkennung.
Falls am Geraet Audio-Aussetzer auftreten, ist die Entscheidung umzukehren.

### E7: SR-Aenderungserkennung: Baseline-Zeitpunkt (P3)

Wahl: **Baseline bei Registrierung des Listeners (1 s nach Start), als
lokale Variable im Closure.**

Begruendung: Die Registrierung laeuft bereits auf der Lifecycle-Queue. Die
aktuelle Rate pro deviceID wird dort einmal gelesen und im Closure gefangen.
Kein neues Dictionary, kein Lock ausser dem bereits vorhandenen Queue-Modell.

### E8: OSLog-Level fuer SR-Zaehler (P3)

Frage: Wie soll gezaehlt werden, wie oft der SR-Listener ohne Aenderung
gefeuert hat?

Wahl: **`logger.log(...)` (Level `.default`, persistent, `.public`) mit einem
In-Session-Zaehler (struct-local var in `scheduleSRRestart` oder eine
Queue-gebundene property in DeviceLifecycleManager). Format: "M4-Noop: SR
trigger without change, total=\(zähler)".**

Begruendung: `logger.debug` wird nicht auf die Platte geschrieben. `.log` oder
`.info` landen im OSLog und sind mit `log stream` oder Console.app auslesbar.
Kein Geraetename im Log-String (privacy .public nur fuer Zaehler).

---

## 3. Schritte

### Schritt S0: Baseline und Branch-Pruefung

**ID:** S0
**Datei:** keine Produktivdatei

Vorgehen:
1. `sudo xcodebuild -license accept` ausfuehren.
2. `cd /Users/mauriciomorkun/AudioRouterNow/v4 && bash scripts/test.sh`
   ausfuehren. Ergebnis notieren (Anzahl Tests, gruen/rot).
3. Sicherstellen, dass `git branch` `release/4.1` zeigt und `git status`
   sauber ist.

Akzeptanzkriterium: Alle Tests gruen.

Commit: keiner in S0.

---

### Schritt S1: Versionsnummer auf 4.1 anheben

**ID:** S1
**Datei:** `v4/Configs/AudioRouterNow4.xcconfig`

Aenderung:
```
MARKETING_VERSION = 4.1
CURRENT_PROJECT_VERSION = 11
```

Begruendung: Der Consent-Check in `EngineController.hasValidLaunchAtLoginConsent()`
vergleicht `CFBundleVersion` (Build-Nummer) mit dem gespeicherten Consent-Build.
Mit Build 11 loescht `ensureLoginItemCompliance()` den veralteten Build-10-Consent
beim naechsten Start und fordert ggf. erneute Zustimmung. Das ist das korrekte
Verhalten gemaess Guideline 2.4.5(iii) und ausdrücklich gewollt.

Akzeptanzkriterium:
- `awk -F'= *' '/^MARKETING_VERSION/{print $2}' v4/Configs/AudioRouterNow4.xcconfig`
  liefert `4.1`.
- `awk -F'= *' '/^CURRENT_PROJECT_VERSION/{print $2}' v4/Configs/AudioRouterNow4.xcconfig`
  liefert `11`.

Test: `v4/scripts/preflight.sh` laufen lassen und prüfen, dass keine
ABBRUCH-Meldung zu "Versionsquelle im Projekt" erscheint.

Commit: `chore(config): bump version to 4.1 (build 11)`

---

### Schritt S2: ScrollView fuer Geraete-Liste und Header-Toggle

**ID:** S2
**Datei:** `v4/AudioRouterNow4/MenuBarView.swift`

Hintergrund (am Code verifiziert):
- Z. 78: `.fixedSize(horizontal: false, vertical: true)` auf dem Root-VStack.
  Das muss bleiben, darf aber NUR auf den Teilen ausserhalb des ScrollViews
  wirken (Header, Status-Bar, Conditional Sections, Footer).
- Z. 69-73: `RoutingButton` und `FooterRow` im `.padding(14)`-VStack, MUSS
  ausserhalb des ScrollViews bleiben.
- Z. 87-101: `.task`-Loop (3-s-Zyklus) darf Scroll-Position nicht
  zuruecksetzen. Da `refreshAvailableDevices()` nur `@Published availableDevices`
  neu befuellt und SwiftUI die Identitaet der Rows ueber `id: \.uid` trackt,
  bleibt die Scroll-Position erhalten, solange die UIDs stabil sind. Kein
  zusaetzliches Scroll-Position-Restoration noetig.

Aenderung am `body`-VStack:

Den Teil zwischen Divider (Z. 67) und zweitem Divider (Z. 67 Trennlinie vor
Footer) durch einen ScrollView ersetzen. Konkreter Umbau:

```swift
// VORHER (vereinfacht):
VStack(alignment: .leading, spacing: 0) {
    WaveHeaderView(...)
    statusBar(ui)       // NEU: mit Header-Toggle
    // ... tcc/error/volume
    deviceListSection(ui)
    Divider()
    VStack(spacing: 10) {
        RoutingButton(state: ui)
        FooterRow()
    }
    .padding(14)
}
.frame(width: 320)
.fixedSize(horizontal: false, vertical: true)

// NACHHER:
VStack(alignment: .leading, spacing: 0) {
    WaveHeaderView(...)
    statusBar(ui)       // NEU: mit Header-Toggle
    // ... tcc/error/volume
    ScrollView(.vertical) {
        deviceListSection(ui)
    }
    .frame(maxHeight: 400)
    Divider()
    VStack(spacing: 10) {
        RoutingButton(state: ui)
        FooterRow()
    }
    .padding(14)
}
.frame(width: 320)
.fixedSize(horizontal: false, vertical: true)
```

Erklaerung zum `.fixedSize`-Problem: Das Root-VStack bekommt weiterhin
`.fixedSize(vertical: true)`. Der ScrollView selbst hat `.frame(maxHeight: 400)`,
was ihm eine obere Grenze gibt. SwiftUI kann dann die ideale Hoeche des
Root-VStack berechnen: Header (fix) + Status-Bar (fix) + ScrollView (max 400,
aber tatsaechlich min(Inhalt, 400)) + Divider + Footer (fix). Das loest die
Kollision zwischen `.fixedSize` und ScrollView, weil der ScrollView jetzt
eine definierte Maximalhoehe hat und nicht mehr "unendlich" ist.

Header-Toggle in `statusBar(_:)` (Z. 149-164):
Den existierenden HStack um einen Button rechts erweitern, rechts vom
Callback-Zaehler (der nur im `.active`-Zustand erscheint):

```swift
private func statusBar(_ ui: ARNUIState) -> some View {
    HStack(spacing: 7) {
        PulsingDot(...)
        Text(statusText(ui))
            ...
        Spacer()
        if ui == .active {
            Text("CBs \(controller.totalCallbacks)")
                ...
        }
        // NEU: Header-Toggle (ausserhalb des ScrollViews, immer sichtbar)
        Button(action: headerToggleAction(ui)) {
            Image(systemName: headerToggleIcon(ui))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ui == .starting
                    ? Color.secondary
                    : ARNColor.accent)
        }
        .buttonStyle(.plain)
        .disabled(ui == .starting || (ui == .idle && controller.outputConfigs.isEmpty))
        .accessibilityLabel(ui == .active ? "Stop Routing" : "Start Routing")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
}

private func headerToggleIcon(_ ui: ARNUIState) -> String {
    switch ui {
    case .idle, .error: return "play.fill"
    case .starting:     return "ellipsis"
    case .active:       return "stop.fill"
    }
}

private func headerToggleAction(_ ui: ARNUIState) -> () -> Void {
    return {
        switch ui {
        case .active:        controller.stopRouting()
        case .idle, .error:  controller.startRouting()
        case .starting:      break
        }
    }
}
```

Wichtig: Genau dieselbe Aktionslogik wie `RoutingButton`. Kein neuer
Controller-Methode noetig.

Akzeptanzkriterium:
- Build ohne Fehler.
- Tests gruen (keine Views in Tests, dieser Schritt prueft nur per Build).
- NUTZER MUSS MESSEN: Panel mit 45+ Eintraegen (BlackHole 64ch + Scarlett 18i20)
  oeffnen. Scroll-Indikator sichtbar, Footer immer sichtbar, Start-Toggle im
  Header klickbar. Auf MacBook 13" pruefen: Panel passt auf den Bildschirm.

Commit: `feat(ui): add scroll view for device list and header start/stop toggle`

---

### Schritt S3: Solo-Zustand in EngineController

**ID:** S3
**Datei:** `v4/AudioRouterNow4/EngineController.swift`

Neue `@Published`-Property und Methoden fuer den Solo-Zustand:

```swift
/// Solo-Zustand (Session-only, nicht persistiert).
/// Key = Composite-Key "<uid>:<channelOffset>", true = dieser Slot ist solo'ed.
/// Ist mindestens ein Key true, spielen nur solo-Keys; alle anderen werden mit
/// einem effektiven Gain von 0 bespielt (via setOutputGain, nicht deviceGains).
@Published private(set) var soloedKeys: Set<String> = []
```

Methode `toggleSolo(for config: OutputConfig)`:

```swift
func toggleSolo(for config: OutputConfig) {
    let key = "\(config.uid):\(config.channelOffset)"
    if soloedKeys.contains(key) {
        soloedKeys.remove(key)
    } else {
        soloedKeys.insert(key)
    }
    applySoloGains()
}
```

Methode `applySoloGains()` (private):

```swift
private func applySoloGains() {
    // soloedKeys ist leer: alle Gains auf deviceGains-Wert zuruecksetzen.
    // soloedKeys nicht leer: solo-Slots auf deviceGains-Wert, alle anderen auf 0.
    let hasSolo = !soloedKeys.isEmpty
    for key in engine.slotDeviceKeys {
        let baseGain = Float32(deviceGains[key] ?? 1.0)
        let effectiveGain: Float32
        if hasSolo {
            effectiveGain = soloedKeys.contains(key) ? baseGain : 0.0
        } else {
            effectiveGain = baseGain
        }
        engine.setOutputGain(effectiveGain, forKey: key)
    }
}
```

Wichtige Regeln:
- `deviceGains` wird NICHT veraendert (kein `setDeviceGain`-Aufruf in
  `applySoloGains`).
- `setDeviceGain` muss Solo-aware werden: wenn Solo aktiv, die
  `deviceGains`-Aenderung schreiben, aber den effektiven Gain nur fuer den
  betroffenen Key berechnen:

```swift
func setDeviceGain(_ value: Double, for config: OutputConfig) {
    let key = "\(config.uid):\(config.channelOffset)"
    let clamped = max(0.0, min(1.0, value))
    deviceGains[key] = clamped
    Self.saveDeviceGains(deviceGains)
    // NEU: Wenn Solo aktiv und dieser Slot nicht solo'ed, Gain bleibt 0.
    let soloActive = !soloedKeys.isEmpty
    let effectiveGain: Float32
    if soloActive && !soloedKeys.contains(key) {
        effectiveGain = 0.0
    } else {
        effectiveGain = Float32(clamped)
    }
    engine.setOutputGain(effectiveGain, forKey: key)
}
```

Solo-Reset bei Stop/Restart:
In `stopRouting()` hinzufuegen:
```swift
soloedKeys = []
```

Solo-Reset bei Warm-Restart: Nach `engine.updateOutputs(...)` oder
`engine.start(...)` wird `applySoloGains()` aufgerufen, damit der neue
Slot-Index-Stand den Solo-Zustand korrekt zurueckspielt. Konkret in
`performStart()` nach `engine.setOutputGains` und vor `try engine.start(...)`:
Nein, es muss NACH dem Start gesetzt werden, da `slotDeviceKeys` erst nach dem
Start aktuell sind:

```swift
// in performStart(), nach startPolling() und startLifecycle():
if !soloedKeys.isEmpty { applySoloGains() }
```

Analoges Muster in `applyOutputsIfRouting()` und
`warmRestartForSampleRateChange()` nach `engine.updateOutputs()`.

Randfaelle:
- Solo-Geraet wird abgesteckt: `soloedKeys` behaelt den Key, aber
  `engine.slotDeviceKeys` enthaelt ihn nicht mehr. `applySoloGains()`
  iteriert `engine.slotDeviceKeys` und setzt alle anderen auf 0. Ergebnis:
  alle verbliebenen Outputs stumm, bis Solo aufgehoben wird. Das ist
  konsistentes DAW-Verhalten.
- Solo-Geraet steckt zurueck: nach Warm-Restart aktualisiert `applySoloGains()`
  die Gains korrekt.
- Routing stoppen: `soloedKeys = []` in `stopRouting()` reset't den Zustand.
- SlotGains.maxSlots (16): Slots >= 16 spielen mit Unity-Gain (W3, bekanntes
  Verhalten). Solo kann diese Slots nicht stummschalten. Das ist dokumentiert
  in `FanOutEngine.swift:598-600`. Fuer 4.1 keine Aenderung an `maxSlots`.
  NUTZER MUSS MESSEN: bei exakt 16 Slots pruefen, ob Solo den letzten Slot
  noch deaktiviert.

Akzeptanzkriterium: (a) Build gruen. (b) Unit-Tests fuer `applySoloGains`-
Logik (Schritt S4).

Commit: `feat(engine): solo state in EngineController, session-only, no persistence`

---

### Schritt S4: Unit-Tests fuer Solo-Logik

**ID:** S4
**Datei:** `v4/AudioRouterKit/Tests/AudioRouterKitTests/` (neue Datei
`SoloGainTests.swift` im SPM-Package, kein XcodeGen-Lauf noetig)

Testfaelle als reine Logik-Tests (ohne EngineController, ohne CoreAudio):

Die eigentliche Logik ist `applySoloGains` in `EngineController`. Da
`EngineController` ein `@MainActor`-ObservableObject ist und echte CoreAudio-
Calls macht, ist ein Unit-Test dort schwierig. Stattdessen wird die Kern-
Entscheidungslogik als reine Funktion extrahiert:

```swift
// In EngineController hinzufuegen (nonisolated static, testbar):
nonisolated static func effectiveSoloGain(
    key: String,
    soloedKeys: Set<String>,
    deviceGains: [String: Double]
) -> Float32 {
    let base = Float32(deviceGains[key] ?? 1.0)
    if soloedKeys.isEmpty { return base }
    return soloedKeys.contains(key) ? base : 0.0
}
```

Testfaelle:
- Kein Solo: alle Keys liefern deviceGains-Wert.
- Ein Key solo'ed: dieser Key = deviceGains-Wert, alle anderen = 0.
- Mehrere Keys solo'ed: alle solo-Keys = deviceGains-Wert, Rest = 0.
- Solo-Key nicht in deviceGains: liefert 1.0 (Unity-Default).
- Solo-Key = "": kein Absturz.
- deviceGains-Wert = 0.5, Key solo'ed: liefert 0.5 (nicht 1.0).
- deviceGains-Wert = 0.5, Key NICHT solo'ed bei aktivem Solo: liefert 0.0.

Akzeptanzkriterium: Alle neuen Tests gruen, vorhandene Tests unveraendert
gruen.

Commit: `test(kit): solo-gain logic tests`

---

### Schritt S5: Solo-Button in DeviceCardView

**ID:** S5
**Datei:** `v4/AudioRouterNow4/UI/DeviceCardView.swift`

Solo-Button wird im `header` der `DeviceCardView` eingefuegt, rechts neben
dem Geraetepfeil (Chevron), links vom Remove-Button:

In `DeviceCardView.header`:
```swift
// Existierender Code (Z. 77-83):
if state.isActive {
    Image(systemName: "chevron.right")
        ...
}
removeButton

// NEU: Solo-Button zwischen Chevron und Remove, nur im Active-Zustand:
if state.isActive {
    Image(systemName: "chevron.right")
        ...
    soloButton   // NEU
}
removeButton
```

`soloButton` als neue `@ViewBuilder`-Property:
```swift
@ViewBuilder private var soloButton: some View {
    let key = "\(config.uid):\(config.channelOffset)"
    let isSoloed = controller.soloedKeys.contains(key)
    let soloActive = !controller.soloedKeys.isEmpty
    let isMutedBySolo = soloActive && !isSoloed

    Button {
        controller.toggleSolo(for: config)
    } label: {
        Image(systemName: "s.circle\(isSoloed ? ".fill" : "")")
            .font(.system(size: 12))
            .foregroundStyle(isSoloed ? ARNColor.accent : Color.secondary.opacity(0.6))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isSoloed ? "Solo active, tap to unsolo" : "Solo")
    .help(isSoloed ? "Solo: only this output plays. Tap to unsolo."
                   : "Solo: mute all other outputs")
}
```

Stummgeschaltete Cards (durch fremdes Solo):
In der `.opacity`-Modifikator-Zeile der `DeviceCardView`:
```swift
// Existierend (Z. 55):
.opacity(state.isStarting ? 0.55 : 1.0)
// NEU:
.opacity(isMutedBySolo ? 0.4 : (state.isStarting ? 0.55 : 1.0))
```

`isMutedBySolo` als computed var:
```swift
private var isMutedBySolo: Bool {
    guard state.isActive else { return false }
    let key = "\(config.uid):\(config.channelOffset)"
    return !controller.soloedKeys.isEmpty && !controller.soloedKeys.contains(key)
}
```

Akzeptanzkriterium: (a) Build gruen. (b) NUTZER MUSS MESSEN: Solo-Button
erscheint pro Card im Active-Zustand. Klick auf Solo einer Card dimmt die
anderen. Zweiter Klick hebt Solo auf. Lautstaerke-Regler der nicht-solo-
Cards bleibt unveraendert (deviceGains unveraendert).

Commit: `feat(ui): solo button per device card`

---

### Schritt S6: SR-Listener mit Aenderungserkennung

**ID:** S6
**Datei:** `v4/AudioRouterKit/Sources/AudioRouterKit/DeviceLifecycleManager.swift`

Ist-Stand (verifiziert Z. 300-315):

```swift
let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
    guard let self, self.srListenersActive else { return }
    self.scheduleSRRestart()
}
```

Der Block ignoriert deviceID und aktuellen Wert. Fix: Baseline bei der
Registrierung lesen, im Block pruefen.

Neue private property (Queue-gebunden):
```swift
/// Baseline-Sample-Rates pro deviceID zum Zeitpunkt der SR-Listener-Registrierung.
/// Nur auf `queue` lesen/schreiben. Key = AudioObjectID.
private var srBaselines: [AudioObjectID: Double] = [:]

/// Zaehler fuer SR-Listener-Feuerungen ohne tatsaechliche Ratenänderung.
private var srNoopCount: Int = 0
```

Hilfsfunktion (nonisolated static, testbar):
```swift
/// Liest die aktuelle NominalSampleRate eines Geraets. `nil` = nicht lesbar.
nonisolated static func readNominalSampleRate(
    for deviceID: AudioObjectID
) -> Double? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr
    else { return nil }
    return Double(rate)
}

/// Reine Entscheidungsfunktion: soll ein SR-Restart ausgeloest werden?
/// - Parameters:
///   - newRate: aktuell gelesene Rate (nil = nicht lesbar, konservativ: restart).
///   - baselineRate: Rate zum Zeitpunkt der Listener-Registrierung.
/// - Returns: true = Restart ausloesen (conservative default bei Lesefehler).
nonisolated static func srChangedSignificantly(
    newRate: Double?,
    baselineRate: Double
) -> Bool {
    guard let new = newRate else { return true }  // Lesefehler: konservativ
    return abs(new - baselineRate) > 0.5          // 0.5 Hz Toleranz
}
```

Aenderung in `registerSRListeners(for uids:)`:
```swift
private func registerSRListeners(for uids: Set<String>) {
    srBaselines = [:]  // Reset vor jeder Registrierung
    for uid in uids {
        guard let deviceID = Self.deviceIDForUID(uid) else { continue }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &addr) else { continue }
        // Baseline lesen
        let baseline = Self.readNominalSampleRate(for: deviceID) ?? 0.0
        srBaselines[deviceID] = baseline
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.srListenersActive else { return }
            let current = Self.readNominalSampleRate(for: deviceID)
            if Self.srChangedSignificantly(newRate: current, baselineRate: baseline) {
                // Baseline auf neuen Wert setzen, damit Folge-Pings nicht
                // erneut triggern (pending SR-Restart ist bereits unterwegs).
                self.srBaselines[deviceID] = current ?? baseline
                self.scheduleSRRestart()
            } else {
                self.srNoopCount += 1
                self.logger.log("M4-Noop: SR trigger without change device=\(deviceID, privacy: .public) rate=\(current ?? -1, privacy: .public) total_noops=\(self.srNoopCount, privacy: .public)")
            }
        }
        AudioObjectAddPropertyListenerBlock(deviceID, &addr, queue, block)
        srListenerBlocks.append((deviceID: deviceID, block: block))
    }
}
```

Wichtig: `srNoopCount` und `srBaselines` werden in `stop()` nicht zurueck-
gesetzt (Zaehler soll Session-uebergreifend akkumulieren).
In `stop()` lediglich `srBaselines = [:]` ergaenzen.

Akzeptanzkriterium: (a) Build gruen. (b) Unit-Tests (Schritt S7).

Commit: `fix(lifecycle): sr listener checks actual rate change before restart`

---

### Schritt S7: Unit-Tests fuer SR-Aenderungserkennung

**ID:** S7
**Datei:** `v4/AudioRouterKit/Tests/AudioRouterKitTests/SRListenerTests.swift` (neu, SPM)

Testfaelle fuer `srChangedSignificantly(newRate:baselineRate:)`:
- Gleiche Rate (z.B. 48000.0 / 48000.0): liefert false.
- Rate um < 0.5 Hz veraendert: liefert false.
- Rate um > 0.5 Hz veraendert (z.B. 44100.0 vs. 48000.0): liefert true.
- newRate = nil (Lesefehler): liefert true (konservativ).
- Toleranzgrenze: 0.5 Hz exakt: liefert false (nicht > 0.5).

Testfaelle fuer `effectiveSoloGain` (hier zusammengefasst mit S4, falls
`SoloGainTests.swift` und `SRListenerTests.swift` in eine Datei):
Siehe S4.

Akzeptanzkriterium: Alle neuen Tests gruen, vorhandene Tests gruen.

Commit: `test(kit): sr-change-detection tests`

---

### Schritt S8: Entprellen beim Entfernen von Geraeten

**ID:** S8
**Datei:** `v4/AudioRouterKit/Sources/AudioRouterKit/DeviceLifecycleManager.swift`

Ist-Stand (verifiziert `handleDevicesChanged`, Z. 253-273):

```swift
let nowAvailable = lastKnownMissingUIDs.intersection(present)
lastKnownMissingUIDs = missing
if !nowAvailable.isEmpty {
    // L1: Re-Appear
    scheduleRestart(after: Self.btSettleDelay)  // 2 s
    return
}
guard !missing.isEmpty else { return }
scheduleRestart(after: Self.hdmiSettleDelay)    // 3 s
```

Ein Blip erzeugt: Verschwinden => `scheduleRestart(after: 3s)`. Innerhalb der
3 Sekunden Rueckkehr => L1-Pfad ruft `scheduleRestart(after: 2s)`, ersetzt den
3-s-Restart durch einen 2-s-Restart. Ergebnis: immer noch ein Restart.

Fix: Im L1-Pfad pruefen, ob noch ein `pendingRestart` aktiv ist. Wenn ja,
ist das Geraet innerhalb der Settle-Frist zurueckgekehrt. Restart verwerfen.

```swift
// L1: Re-Appear
let nowAvailable = lastKnownMissingUIDs.intersection(present)
lastKnownMissingUIDs = missing
if !nowAvailable.isEmpty {
    if pendingRestart != nil {
        // Geraet kam innerhalb der Settle-Frist zurueck: Blip erkannt.
        // Restart verwerfen, Engine laeuft weiter ohne Unterbrechung.
        pendingRestart?.cancel()
        pendingRestart = nil
        logger.log("L1: Blip erkannt (\(nowAvailable.count, privacy: .public) UIDs zurueck, Settle-Restart verworfen)")
    } else {
        // Geraet war laenger weg als die Settle-Frist: normaler Re-Appear.
        scheduleRestart(after: Self.btSettleDelay)
    }
    return
}
```

Risiko (CASE-007-Wechselwirkung): `VolumeTracker.settleFreezeDurationConst = 4.0 s`.
Ein Blip von bis zu 3 s wird jetzt ohne Restart absorbiert. Der VolumeTracker-
Freeze haette nach einem abgesagten Restart keine Gelegenheit, sich selbst
zurueckzusetzen. Das ist kein Problem, weil der Freeze durch `start()` im
naechsten echten Restart-Zyklus geloescht wird. Bei einem Blip lauft der
Tracker ohne Freeze weiter, was korrekt ist.

Akzeptanzkriterium: (a) Build gruen. (b) NUTZER MUSS MESSEN: USB-Aussetzer
(Kabel kurz loesen und wieder einstecken, so dass macOS einen Disconnect/
Connect-Event sendet). Erwartet: kein Audio-Aussetzer oder eine kuerzere
Unterbrechung als bisher. Wenn Audio reisst, ist der Blip laenger als 3 s
und die bestehende Restart-Logik greift. Wenn Audio dauerhaft reisst: die
Aenderung ist umzukehren.

Commit: `fix(lifecycle): absorb device blips within settle window`

---

### Schritt S9: Store-Description-Pruefung im Repo

**ID:** S9
**Dateien:** `README.md`, `RELEASE_NOTES.md`, `landing-page/`

Vorgehen: Im gesamten Repo nach dem Superlativ-Satz suchen:
```
grep -r "the only sandboxed" /Users/mauriciomorkun/AudioRouterNow/
```

Alle Treffer durch den neuen Satz ersetzen:
"AudioRouterNow runs fully sandboxed. No kernel extension. No virtual driver.
No reboot."

Die eigentliche Store-Description liegt in App Store Connect, nicht im Repo.
Ein Schritt-Eintrag genuegt.

Akzeptanzkriterium: `grep -r "the only sandboxed" /path/` liefert keine
Treffer mehr.

Commit: `docs: replace "the only" superlative with factual description`

---

### Schritt S10: Store-Description in App Store Connect

**ID:** S10

Dieser Schritt kann nur vom Nutzer ausgefuehrt werden. Der Umsetzer und der
Auditor markieren ihn als "NUTZER MUSS EINTRAGEN".

Vorgehen:
1. App Store Connect oeffnen.
2. AudioRouterNow App, Version 4.1 anlegen (falls noch nicht vorhanden).
3. Im Feld "Description" den Satz suchen:
   "AudioRouterNow is the only sandboxed multi-output solution on the Mac
   App Store"
4. Ersetzen durch:
   "AudioRouterNow runs fully sandboxed. No kernel extension. No virtual
   driver. No reboot."
5. Speichern.

Kein Commit fuer diesen Schritt (kein Repo-Inhalt aendert sich).

---

### Schritt S11: CHANGELOG und RELEASE_NOTES

**ID:** S11
**Dateien:** `CHANGELOG.md`, `RELEASE_NOTES.md`

Stil: `docs/v4.0.1/02-decisions.md` und `CHANGELOG.md` (Z. 70-120 fuer 4.0.1)
als Muster. Ausschliesslich technische Beschreibung, keine Marketing-Texte,
keine Nutzernamen.

CHANGELOG.md: Neuen Abschnitt `[4.1], YYYY-MM-DD` einfuegen (Datum =
Einreichungsdatum, beim Planen noch offen, Platzhalter eintragen).

Inhalt fuer jeden fixen Punkt:
- Scroll: "Device list is now scrollable when many devices are configured.
  The start/stop button in the footer is always visible. An additional
  start/stop toggle has been added to the status bar at the top."
- Solo: "Solo button per output: tap to hear only that output; all others
  are silenced without affecting their stored gain settings. Session-only,
  resets on restart."
- SR-Listener: "The sample rate listener no longer triggers an engine restart
  when the sample rate notification fires but the rate did not actually change."
- Entprellen: "Device reconnect within the settle window no longer causes an
  engine restart."
- Description: "App description updated: removed unverifiable superlative."

Akzeptanzkriterium: Kein Marketing-Inhalt, kein Nutzername.

Commit: `docs(changelog): release notes for v4.1`

---

### Schritt S12: Abschluss-Testlauf und preflight

**ID:** S12

Vorgehen:
1. `cd /Users/mauriciomorkun/AudioRouterNow/v4 && bash scripts/test.sh`
   Alle Tests gruen. Zaehlstand notieren.
2. `v4/scripts/preflight.sh` laufen lassen.
   Erwartetes Ergebnis: "Tag v4.1 existiert noch nicht" (OK), "xcconfig
   sagt 4.1 (11)", "Kein zweiter Projektbaum vorhanden" (kein ABBRUCH
   fuer v4-appstore/ wenn es noch da ist, nur WARNUNG).

Commit: keiner. S12 ist reine Verifikation.

---

## 4. Verbotsliste

Der Umsetzer darf NICHT:
- Den FanOutEngine-Echtzeitpfad (IOProc-Block, `makeDirectIOBlock`) aendern,
  ausser S3 erfordert explizit `applySoloGains()` nach Start/Update.
- `deviceGains` (UserDefaults) durch Solo-Operationen beschreiben.
- Entitlements aendern (`AudioRouterNow4.entitlements`,
  `AudioRouterNow4-Debug.entitlements`).
- `v4-appstore/` oder `legacy-v3/` anfassen.
- Auf den Remote pushen (`git push`).
- Bei App Store Connect einreichen.
- Neue Swift-Dateien in `v4/AudioRouterNow4/` erstellen, ohne dass dieser
  Plan einen expliziten Schritt dafuer enthaelt.
- Marketing-Texte in Commits oder Dokumentation schreiben.
- Nutzernamen oder E-Mail-Adressen in irgendeiner Datei erwaehnen.
- `--no-verify` beim Commit verwenden.
- SlotGains.maxSlots veraendern.
- Den W1-Ramp-Mechanismus im IOProc veraendern.

---

## 5. Risiken

### R1: CASE-003 (Display-Cycle-Absturz) bei ScrollView (P1)

Das ScrollView wird in den vorhandenen View-Baum eingefuegt, in dem der
gemeldete Absturz auftrat. Layout-Schleifen (infinite height), NaN-Groessen
oder unerwartete fixedSize-Interaktionen koennen neue Absturzpfade oeffnen.

Gegenmassnahme:
- `maxHeight: 400` auf dem ScrollView stellt sicher, dass der View nie eine
  "unendliche" ideale Groesse hat.
- Kein neues PreferenceKey, kein GeometryReader im ScrollView.
- Build + Xcode-Preview nach S2 ausfuehren. Kein Absturz im Preview = erste
  Barriere. NUTZER MUSS MESSEN: Panel mit unterschiedlichen Listenlaengen.

### R2: Lautstaerke-Sprung beim Solo (CASE-004/007-Muster, P2)

Solo schreibt Gain 0.0 auf nicht-solo-Slots via `engine.setOutputGain`. Der
IOProc hat W1-Ramp (10 ms bei 512 Frames). Kein sofortiger Sprung erwartet.

Gegenmassnahme:
- W1-Ramp ist bereits im IOProc, keine Aenderung noetig.
- NUTZER MUSS MESSEN: Solo ein/ausschalten waehrend Musik lauft. Kein
  Knacksen erwartet.

### R3: deviceGains-Verschmutzung durch Solo (P2)

Das groesste Risiko: wenn irgendwo `setDeviceGain` statt `setOutputGain`
aufgerufen wird fuer einen Solo-stummgeschalteten Slot, schreibt es 0 in
UserDefaults und persistiert die Stille.

Gegenmassnahme:
- `applySoloGains()` ruft ausschliesslich `engine.setOutputGain` (kein
  `setDeviceGain`).
- Schritt S3 enthaelt den expliziten Hinweis in der Code-Skizze.
- Auditor prueft diesen Punkt explizit in Checkliste (Punkt A5).

### R4: SR-Listener-Fehlererkennung unterdrueckt noetige Restarts (P3)

Die neue Prueflinie hat die gefaehrlichere Fehlerrichtung als der Ist-Stand.

Gegenmassnahme:
- `nil` (Lesefehler) = `true` (Restart ausfuehren, konservativ).
- `srChangedSignificantly` hat eine Toleranz von 0.5 Hz, die nur
  winzige Schwankungen ignoriert; reale Rate-Wechsel (44100 vs. 48000) sind
  3900 Hz auseinander.
- Unit-Tests (S7) decken den nil-Fall ab.

### R5: Blip-Erkennung absorbiert echtes Entfernen (P3)

Wenn ein Nutzer ein Geraet dauerhaft entfernt aber der Disconnect-Event
zuvor noch einen pendingRestart erzeugt hat, koennte das Verwerfen falsch
sein. Das trifft nur zu, wenn das Geraet physisch entfernt wurde UND kein
neues Event folgt.

Gegenmassnahme:
- Der Blip-Pfad greift nur innerhalb der aktiven Settle-Frist (3 s / 2 s).
  Danach laeuft der normale Re-Appear-Pfad und der Reset findet statt.
- NUTZER MUSS MESSEN: Geraet dauerhaft entfernen. Erwartet: nach Ablauf der
  3-s-Frist Restart ohne Blip-Absorption.

### R6: ScrollView-Scroll-Position bei 3-s-Poll-Reset (P1)

`refreshAvailableDevices()` befuellt `availableDevices` neu. SwiftUI
vergleicht Eintraege ueber `id: \.uid`. Solange UIDs stabil sind, wird
die Scroll-Position nicht zurueckgesetzt. Wenn Geraete ein/ausgesteckt
werden, kann sich die Liste aendern.

Gegenmassnahme: Kein zusaetzlicher Code noetig. SwiftUI-Standard-Verhalten
reicht.

---

## 6. Messpunkte "NUTZER MUSS MESSEN"

Diese Punkte koennen nicht durch Build oder Unit-Test verifiziert werden
und duerfen von Umsetzer und Auditor NIE als verifiziert gemeldet werden.

### M1: ScrollView mit 45+ Eintraegen (P1)

**Vorbedingung:** BlackHole 64ch und Scarlett 18i20 (oder aequivalent viele
virtuelle Geraete) verbunden. App starten.

**Vorgehen:** Panel oeffnen. Scroll-Indikator sichtbar? Liste scrollbar?
Footer immer sichtbar? Header-Toggle im Status-Banner sichtbar? Auf MacBook
13" pruefen: passt das Panel auf den Bildschirm (Footer nicht abgeschnitten)?

**Erwartetes Ergebnis:** Ja zu allen Fragen.

### M2: Header-Toggle-Verhalten (P1)

**Vorbedingung:** Mindestens ein Geraet konfiguriert.

**Vorgehen:** (a) Im IDLE-Zustand: Toggle-Icon (play.fill) klicken. App startet
Routing. (b) Im ACTIVE-Zustand: Toggle-Icon (stop.fill) klicken. App stoppt.
(c) Im STARTING-Zustand: Toggle-Icon ist deaktiviert (kein Klick moeglich).

**Erwartetes Ergebnis:** Routing startet und stoppt korrekt. Kein doppeltes
Starten.

### M3: Solo ohne Knacksen (P2)

**Vorbedingung:** Mindestens zwei Outputs konfiguriert, Routing aktiv,
Musik laeuft.

**Vorgehen:** Solo-Button eines Outputs druecken. Anderen Output solo'en.
Solo aufheben. Lautstaerke-Regler des stummgeschalteten Outputs waehrend
Solo verschieben: beim Solo-Aufheben muss der neue Wert hoerbar sein.

**Erwartetes Ergebnis:** Kein Knacksen, kein Lautstaerkesprung. Nach Solo-
Aufheben ist die gespeicherte Lautstaerke der vorher stummgeschalteten
Outputs unveraendert aktiv.

### M4: Solo bei abgestecktem Geraet (P2)

**Vorbedingung:** Zwei Outputs, einer wird solo'ed, dann das solo-Geraet
entfernen.

**Erwartetes Ergebnis:** Alle anderen Outputs stumm (kein Audio). Nach
Solo-Aufheben hoeren alle verbliebenen Outputs wieder.

### M5: SlotGains.maxSlots-Grenze bei Solo (P2)

**Vorbedingung:** Genau 16 konfigurierte Outputs (z.B. BlackHole 64ch,
Paare 1-16).

**Vorgehen:** Slot 1 (Index 0) solo'en. Slot 16 (Index 15) solo'en. Pruefen
ob Slot 17 (Index 16, ausserhalb maxSlots) weiter spielt.

**Erwartetes Ergebnis:** Solo deaktiviert Slots 0-15. Slot 16+ spielt weiter
(bekannte Einschraenkung).

### M6: SR-Listener-Noop-Rate messen (P3)

**Vorbedingung:** App 15+ Minuten mit aktivem Routing laufen lassen ohne
Sample-Rate-Wechsel.

**Vorgehen:** `log stream --predicate 'subsystem == "com.mauriciomorkun.audiorouternow"'
| grep "M4-Noop"` ausfuehren. Zaehler pruefen.

**Erwartetes Ergebnis:** Zaehler bleibt 0 oder sehr niedrig, wenn keine
Sample-Rate-Wechsel stattgefunden haben. Ein erhoehteer Wert zeigt, dass
die Listener wirklich ohne Grund gefeuert haben.

### M7: SR-Restart bei echtem Rate-Wechsel (P3)

**Vorbedingung:** App mit aktivem Routing, ein Geraet dessen Sample-Rate
umschaltbar ist (z.B. Komplete Audio 6 oder USB-Interface).

**Vorgehen:** Rate per Audio MIDI Setup von 48 kHz auf 44.1 kHz umschalten.

**Erwartetes Ergebnis:** App startet innerhalb von 1-3 Sekunden einen Warm-
Restart (kein "M4-Noop" im Log).

### M8: Blip-Absorption (P3)

**Vorbedingung:** App mit aktivem Routing, USB-Geraet.

**Vorgehen:** USB-Kabel kurz loesen (unter 2 Sekunden) und wieder einstecken.

**Erwartetes Ergebnis:** Kuerzere oder keine Unterbrechung als bei 4.0.1.
Falls Audio dauerhaft reisst: Schritt S8 ist umzukehren.

---

## 7. Audit-Leitfaden

Der Auditor prueft die folgenden Punkte am Code (in der Reihenfolge ihrer
Risikoprioritaet):

### A1: deviceGains bleibt unberuehrt durch Solo

Pruefen: Suche `setDeviceGain` in `EngineController.swift`. Darf im
Zusammenhang mit `soloedKeys`, `toggleSolo` oder `applySoloGains` NICHT
aufgerufen werden. Nur `engine.setOutputGain` ist erlaubt.

Pruefen: `deviceGains`-Dictionary wird in `applySoloGains()` nur gelesen,
nicht geschrieben.

Pruefen: `saveDeviceGains` wird in `applySoloGains()` NICHT aufgerufen.

### A2: Footer ausserhalb des ScrollViews

Pruefen: Im `body` von `MenuBarView` liegt der VStack mit `RoutingButton` und
`FooterRow` NACH dem `ScrollView`, nicht darin.

### A3: Hoehe geclampt

Pruefen: Der `ScrollView` in `MenuBarView` hat `.frame(maxHeight: 400)` ODER
einen vergleichbaren Clamp. Kein unbegrenztes `.fixedSize` innerhalb des
ScrollViews.

### A4: fixedSize bleibt am Root-VStack

Pruefen: `.fixedSize(horizontal: false, vertical: true)` steht auf dem
aeusersten VStack des `body`, nicht entfernt worden.

### A5: Solo-Reset bei stopRouting

Pruefen: `soloedKeys = []` in `stopRouting()` vorhanden.

### A6: applySoloGains nach Restart-Pfaden

Pruefen: `applySoloGains()` wird nach `engine.start(...)` in `performStart()`
aufgerufen, wenn `soloedKeys` nicht leer ist. Analoges in
`applyOutputsIfRouting()` und `warmRestartForSampleRateChange()`.

### A7: SR-Listener-Konservatismus

Pruefen: `srChangedSignificantly(newRate: nil, ...)` liefert `true`. Unit-
Test deckt diesen Fall ab.

### A8: Blip-Verwerfen nur bei aktivem pendingRestart

Pruefen: Der L1-Blip-Pfad in `handleDevicesChanged` verwirft nur dann, wenn
`pendingRestart != nil`. Ohne ausstehenden Restart greift der normale 2-s-Pfad.

### A9: Keine ENTSCHEIDUNG NUTZER BESTÄTIGEN als verifiziert gemeldet

Pruefen: Punkte E1 (maxHeight), E3 (Header-Toggle), E4 (Solo-Optik), E6
(Blip-Verwerfen) und alle M-Punkte sind im Abschlussbericht als OFFEN
oder NUTZER aufgefuehrt, nicht als "verifiziert".

### A10: Keine neuen Dateien in v4/AudioRouterNow4/ ohne Plan-Schritt

Pruefen: `git diff --name-only release/4.1^..release/4.1 -- v4/AudioRouterNow4/`
zeigt keine neuen .swift-Dateien, die nicht in diesem Plan vorgesehen sind.

### A11: Tests gruen und Anzahl gestiegen

Pruefen: `v4/scripts/test.sh` laeuft durch. Anzahl Testfaelle hoeher als
Baseline (mindestens +10 neue Faelle durch S4 und S7).

### A12: Conventional Commits und kein Push

Pruefen: `git log --oneline release/4.1 ^main` zeigt nur die Commits dieser
Planing-Runde. Kein `origin/release/4.1` existiert.

### A13: Version angehoben

Pruefen: `AudioRouterNow4.xcconfig` hat `MARKETING_VERSION = 4.1` und
`CURRENT_PROJECT_VERSION = 11`.

### A14: Superlativ aus Repo entfernt

Pruefen: `grep -r "the only sandboxed" /Users/mauriciomorkun/AudioRouterNow/`
liefert keine Treffer.

---

## 8. Abschlussschritte und Bericht-Eckdaten

Nach S12 (Abschluss-Testlauf und preflight) folgt:

1. Consent-Pruefung: `EngineController.ensureLoginItemCompliance()` wird beim
   naechsten App-Start mit Build 11 den Build-10-Consent loeschen. Erwartet:
   korrekt. Kein Code-Fix noetig, Verhalten ist dokumentiert in
   `EngineController.swift:252-273`.

2. Docs erstellen: `docs/v4.1/02-plan-v1.md` ist dieser Plan (bereits
   committed nach Schritt 0 des Kreislaufs). Fuer die Abschluss-Doku die
   Datei `docs/v4.1/03-implementation-report.md` durch den Sonnet-Agenten
   erstellen lassen (Phase 5 des Kreislaufs).

3. Preflight: `v4/scripts/preflight.sh` liefert maximal WARNUNGen, keine
   ABBRUCH-Meldungen (ausser "v4-appstore/ existiert noch", das ist eine
   bekannte WARNUNG, keine neue). Tag v4.1 fehlt noch: OK fuer diesen
   Zeitpunkt.

4. ENTSCHEIDUNG NUTZER BESTÄTIGEN-Punkte fuer den Abschlussbericht:
   - E1: maxHeight 400 pt akzeptiert?
   - E3: Icon-Button in Status-Bar akzeptiert?
   - E4: 0.4-Opacity fuer stumm-durch-Solo akzeptiert?
   - E6: Blip-Verwerfen bei aktivem pendingRestart akzeptiert?

5. NUTZER MUSS MESSEN-Punkte fuer den Abschlussbericht (offen bis zur
   Hardware-Messung):
   - M1 bis M8 wie in Abschnitt 6 beschrieben.

---

## Anhang: Abweichungen am Code versus Vorbeschreibung

Diese Punkte hat der Planer am Code anders vorgefunden als in der Aufgaben-
beschreibung behauptet:

1. **Zeilennummern.** `MenuBarView.swift:78` stimmt exakt (`.fixedSize` ist
   auf Z. 78). `EngineController.swift:117-165` stimmt ungefaehr, der
   Consent-Block beginnt auf Z. 103. `DeviceLifecycleManager.swift:270-272`
   fuer `hdmiSettleDelay` ist korrekt (Z. 272 in `handleDevicesChanged`).
   `registerSRListeners` beginnt auf Z. 300 (korrekt). `DeviceVolumeRow` ist
   ab Z. 358 in `DeviceCardView.swift` (nicht Z. 358 wie behauptet, aber nah).

2. **Solo-Button in der Vorbeschreibung als "DeviceCardView.swift ca. Z. 358"**
   ist `DeviceVolumeRow` (der Lautstaerke-Regler). Der Solo-Button selbst
   existiert noch nicht, weil er neu ist.

3. **`EngineController.setDeviceGain` ca. Z. 456**: am Code Z. 455 (nah
   genug). Peak-Multiplikation in `updateWaveEnergy` Z. 697 ff. korrekt.

4. **Blip-Fenster:** Die Vorbeschreibung behauptete "300 ms" als Backlog-
   Vorschlag. Am Code verifiziert: der Ist-Stand hat bereits ein 3-s-Fenster
   durch `hdmiSettleDelay`. Der Plan verwendet daher einen anderen Ansatz als
   die naive 300-ms-Implementierung.

5. **Tests konnten nicht laufen:** Xcode-Lizenz nicht angenommen, kein
   `sudo`-Terminal verfuegbar. Test-Lauf ist in S0 als Pflicht-Erster-Schritt
   des Umsetzers beschrieben.

6. **`slotTargetSV` und `effectiveVolume` als public nonisolated static:**
   korrekt in `FanOutEngine.swift` vorhanden, fuer Unit-Tests testbar.
   `computeSlotAppliesVol` ebenso. Das Muster fuer `effectiveSoloGain`
   (S3) folgt genau diesem Schema.
