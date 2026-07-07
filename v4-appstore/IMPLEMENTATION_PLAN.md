# AudioRouterNow v4.0 — Implementierungsplan (Synthese)

**Stand:** 2026-07-06 | **Methode:** Dual-Agent (Fable) + Synthese + Audit | **Status:** Planung

---

## Implementierungsstatus

| Phase | Status | Datum | Audit | Commit |
|---|---|---|---|---|
| Phase 0: Projekt-Setup | ✅ Abgeschlossen | 06.07.2026 | Dual-Fable PASS (Iter 2/3) | `8543785` |
| Phase 1: Process Tap PoC | ✅ Code fertig | 06.07.2026 | Dual-Fable PASS (Iter 1/3) | `5b4e9e5` |
| Phase 1: Go/No-Go Entscheid | ⏳ Manuelle Tests ausstehend | — | — | — |
| Phase 2: Multi-Output Fan-out | ⏳ Wartet auf Go/No-Go | — | — | — |
| Phase 3: PI-Regler + Clock-Drift | ⏳ Wartet auf Phase 2 | — | — | — |
| Phase 4: Menu Bar UI | ⏳ Wartet auf Phase 3 | — | — | — |
| Phase 5: Robustheit + Beta | ⏳ Wartet auf Phase 4 | — | — | — |
| Phase 6: App Store Submission | ⏳ Wartet auf Phase 5 | — | — | — |

### Phase-1-Implementierungsdetails (06.07.2026)

**Implementierte API-Sequenz:**
1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` — global, `.unmuted`, `isPrivate = true`
2. `AudioHardwareCreateProcessTap` → `tapID` — kein TCC-Prompt hier
3. `AudioHardwareCreateAggregateDevice` — privat, Default-Output als Sub-Device, Tap via `kAudioAggregateDeviceTapListKey`
4. `AudioDeviceCreateIOProcIDWithBlock` — allokationsfrei, Silence-Heuristik (200 Callbacks ≈ 2,1s), kein MainActor-Capture
5. `AudioDeviceStart` — **TCC-Prompt feuert hier**
6. Teardown invers + idempotent (AudioCap-konform)

**Offene Phase-2-Schulden (kein Blocker für Go/No-Go):**
- `start()` async erforderlich (blockiert derzeit Main-Thread ~3 Min bei TCC/HAL-Hang)
- Env-Gate `ARN_HW_TESTS=1` für Hardware-Tests in CI
- Property-Listener für SR-/Device-Wechsel (Test 4.2 — Phase 3)

**Root Cause IOProc Crash (behoben 07.07.2026):**
- **Symptom:** `EXC_BREAKPOINT` auf `com.apple.audio.IOThread.client` sofort nach `AudioDeviceStart` — Stack: `HALC_ProxyIOContext::IOWorkLoop` → IOProc-Closure → `swift_task_checkIsolatedSwift` → `dispatch_assert_queue` → `_dispatch_assert_queue_fail`.
- **Ursache:** Der IOProc-Block war INLINE in `TapEngine.start()` definiert. `TapEngine` ist `@MainActor`, `start()` damit implizit auch — und eine in einer `@MainActor`-Methode definierte Closure ERBT diese Isolation, selbst wenn sie `self` nicht captured und nur Sendable-Werte berührt. Swift Concurrency emittiert dann bei jeder Invokation einen `swift_task_checkIsolatedSwift`-Runtime-Check. CoreAudio ruft den IOProc aber auf seinem Realtime-Thread auf (nicht Main Queue) → Assert schlägt fehl → Crash. Die Sandbox war NICHT die Ursache (gleicher Crash mit `app-sandbox = false` verifiziert).
- **Fix:** `private nonisolated static func makeIOBlock(metrics:)` in `TapEngine` — die Factory erstellt den Block außerhalb jeder Actor-Isolation, dadurch kein Concurrency-Check auf dem RT-Thread. Ausführliche Root-Cause-Doku als Kommentar direkt an der Methode.
- **⚠️ Warnung für Phase 2+ (Pflichtregel):** ALLE Callbacks/Closures, die auf Realtime-/CoreAudio-Threads laufen (IOProcs, `AudioObjectAddPropertyListenerBlock`, Fan-out-Callbacks), MÜSSEN in einem `nonisolated`-Kontext erstellt werden — niemals inline in `@MainActor`-Methoden. Betrifft insbesondere die Phase-2-Fan-out-IOProcs pro Ziel-Device und die Phase-3-Property-Listener.

**Technische Entscheidungen Phase 1:**
- Silence-Heuristik statt privater TCC-SPI (MAS-konform, Guideline 2.5.1)
- `TapIOMetrics` als `Sendable`-Box für Realtime-Pfad (Swift 6 konform)
- `tccDeepLink` als `nonisolated static` (kein MainActor nötig)
- 20/20 Tests grün, CI-safe (fangen RouterError ohne Hardware)

---

## Vergleich: Agent A vs Agent B

Beide Agents haben unabhängig voneinander denselben Befund produziert: Die PLAN.md-Schätzung von ~10 Wochen Teilzeit unterschlägt zwei kritische Arbeitspakete, die in v3 bereits Probleme verursacht haben — die Latenz-Kompensation als eigenes Arbeitspaket (v3 ist daran einmal gescheitert) und den Uninstaller-Helper als separates Signing-/Notarisierungs-Artefakt. Beide Agents korrigieren auf 11–13 Wochen Teilzeit, aus denselben Gründen, unabhängig voneinander. Das ist ein starkes konvergentes Signal.

**Konvergenz A+B:** 11–13 Wochen einplanen. Puffer in Phase 3 (PI-Regler) und Phase 6 (Submission), nicht ans Ende.

**Hauptunterschied:** Agent A betont frühes Testen von AirPlay-Geräten als IOProc-Ziel (Phase 1, nicht Phase 5) und legt Wert auf die SPM-Package-Struktur ab Tag 1 für testbare Engine-Komponenten. Agent B betont explizit das Verwerfen von Prototyp-Code und das Erwartungsmanagement bei BT-Sync-Feedback in der Beta-Phase.

**Entitlement-Widerspruch (offen):** Beide Pläne erwähnen `com.apple.security.device.audio-input` als TCC-Entitlement-Pfad, aber Rogue Amoeba und insidegui/AudioCap nutzen teilweise unterschiedliche Entitlement-Kombinationen. Vor Phase 0 klären: welches Entitlement reicht tatsächlich für `AudioHardwareCreateProcessTap` im MAS-Sandbox-Kontext?

---

## Finaler Implementierungsplan

### Executive Summary

AudioRouterNow v4.0 ist ein vollständiger Swift-Rewrite der bisherigen HAL-Plugin-Architektur (v3.x) auf Basis der Apple Process Tap API (macOS 14.2+). Der Plan ist strukturell solide — Architektur tragfähig, Phasenreihenfolge konsistent, keine technische Sackgasse identifiziert. Die Zeitschätzung aus PLAN.md (~10 Wochen) ist zu optimistisch; realistisch sind 11–13 Wochen Teilzeit. Der einzige echte Go/No-Go-Punkt ist Phase 1: Apple Music muss empirisch über einen Process Tap routbar sein. Erst danach beginnt die eigentliche Implementierung.

**Doppelte Distributions-Lane:** App Store (MAS) + GitHub/Developer-ID laufen parallel ab Phase 6. Das verdoppelt die Signing- und Release-Checklisten und ist ein eigenes Arbeitspaket, das explizit eingeplant werden muss.

---

### Phasen

#### Phase 0: Entitlement + Projekt-Setup (Woche 1)

**Ziel:** Leeres, signierbares, sandboxtes App-Skelett mit funktionierendem Test-Target.

**Key Tasks:**
- Neues Xcode-Projekt anlegen (Swift, Mac App Store Target, Hardened Runtime)
- SPM-Package `AudioRouterKit` ab Tag 1 als eigenes Target — nicht alles im App-Target. Falsche Projekt-Struktur macht Engine-Unit-Tests später mühsam.
- `swift test` läuft gegen `AudioRouterKit` ohne UI-Bootstrap
- Entitlement-Inventur: `com.apple.security.app-sandbox`, `com.apple.security.device.audio-input`, `NSAudioCaptureUsageDescription` — tatsächlich benötigte Kombination für MAS-Sandbox + Process Tap verifizieren
- Zertifikate und Provisioning Profiles inventarisieren (Apple Distribution + Developer ID) — frühzeitig klären, nicht erst in Phase 6
- macOS API-Versionsverhalten: `AudioHardwareCreateProcessTap` verhält sich auf 14.2 anders als auf 15.x — prüfen ob Minimum auf 14.4 angehoben werden muss

**Verifikation:** Leeres `MenuBarExtra` startet auf sauberem System, `codesign -dv` zeigt Sandbox + korrekte Signatur, `swift test` läuft ohne UI-Bootstrap.

**Deliverable:** Signierbares App-Skelett + CI-Pipeline-Grundstruktur

**Wichtige Regel:** Prototyp-Code in dieser Phase ist Wegwerf-Code — bewusst so behandeln und nicht schleichend in Produktionscode verwandeln.

---

#### Phase 1: Process Tap Proof of Concept — Go/No-Go-Entscheid (Woche 1–2)

**Ziel:** Empirisch bestätigen dass Apple Music über einen Process Tap routbar ist. Das ist der einzige echte Go/No-Go für das gesamte Projekt.

**Key Tasks:**
- Minimale Swift-App die System-Audio via `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` capturt
- Apple Music Streaming, Downloads und Lossless testen — Routing bestätigt oder widerlegt
- Apple TV+ testen (Stille erwartet, zur Dokumentation)
- AirPlay-Geräte frühzeitig als IOProc-Ziel testen — sie verhalten sich anders als physische Devices (wichtig: nicht auf Phase 5 verschieben)
- TCC-Prompt: erscheint, wird persistiert, Ablehnung ist erkennbar und führt zu graceful degradation mit Deep-Link in Systemeinstellungen
- TCC-Deep-Link-URL für System Audio Recording kann sich zwischen macOS-Versionen ändern — auf 14.2 und aktuellem macOS verifizieren

**Testpunkte:**
- Integrationstest: Komplete Audio 6 MK2 Ch1-2 UND Ch3-4 gleichzeitig + MacBook-Speaker/AirPods parallel (≥3 Outputs), hörbar sauber, 1h stabil
- Achtung: Drift-Underruns nach Minuten sind OHNE Phase 3 normal — Testerwartung entsprechend setzen, nicht als Bug werten

**Go/No-Go-Kriterien:**
- Apple Music Streaming routbar: Go
- Apple Music Lossless routbar: Go
- Selbst-Aufnahme-Loop ausgeschlossen: Go
- SR-/Format-Wechsel des Default-Geräts während der Tap läuft führt nicht zum Crash und ist über Property-Listener beobachtbar: Go
- Go/No-Go-Entscheid formal in PLAN.md §0.10 dokumentieren und PROTOTYPE_RESULTS.md in v4-appstore/ anlegen

**Dependencies:** Phase 0 Entitlement-Setup abgeschlossen

**Deliverable:** PROTOTYPE_RESULTS.md mit Testergebnissen + formaler Go/No-Go-Entscheid

**Eingangskriterium für Phase 4 (UI-Verdrahtung):** Der Phase-0-Placeholder
`TapEngine.start()` setzt `status = .routing` OHNE reale Arbeit (Fake-Erfolg,
Audit-Befund 2026-07-06). Bevor die UI in Phase 4 gegen `RouterStatus`
verdrahtet wird, MUSS dieser Fake-Übergang durch den echten Tap-Aufbau
(CATapDescription + AudioHardwareCreateProcessTap + TCC-Preflight) ersetzt
sein — sonst zeigt die UI "Routing aktiv" ohne Audio.

---

#### Phase 2: Multi-Output Fan-out (Woche 3–4)

**Ziel:** Tap-Stream auf N Outputs verteilen via direkter CoreAudio IOProcs (Option B).

**Key Tasks:**
- IOProc-Architektur mit SPSC-Ring-Buffer pro Output-Device
- Sample-Rate-Konversion zwischen Tap und Output — Architektur so schneiden dass bei SR-Gleichheit Converter und Resampler beide als Bypass laufen (Doppel-Konversion kostet CPU und Qualität)
- Channel-Offset-Support für Mehrkanal-Interfaces (KA6 Ch1-2 vs. Ch3-4)
- Golden-Tests für PI-Regler-Logik VOR dem Port aus C nach Swift — Port-Fehler in der Regelungstechnik sind subtil und erst nach Stunden hörbar
- `SMAppService.mainApp`-Login-Item + Toggle-Backend (früh integrieren, vermeidet UI-Nacharbeit)
- Zeitpuffer für Phase 2 einplanen — Golden-Tests und Resampler-Bypass-Architektur sind unterschätzte Arbeitspakete

**Testpunkt:** Gleichzeitige Ausgabe auf Komplete Audio 6 MK2 Ch1-2 UND Ch3-4 plus MacBook-Speaker, hörbar sauber.

**Dependencies:** Phase 1 Go/No-Go bestanden

**Deliverable:** Laufender Fan-out mit ≥3 gleichzeitigen Outputs

---

#### Phase 3: PI-Regler + Clock-Drift-Kompensation (Woche 5–6)

**Ziel:** Port des bestehenden PI-Reglers aus C nach Swift, 24h-stabiler Betrieb ohne Underruns.

**Key Tasks:**
- PI-Regler Port: ±500 ppm Range, EWMA Fill-Level, Pre-Roll (2048 Frames ≈ 43 ms @48 kHz)
- BT-Reconnect-Kaskaden behandeln (Gerät verschwindet/erscheint mehrfach in Sekunden) — Settle-Karenz + idempotenter Graph-Rebuild als Design-Anforderung, nicht als Nachbesserung
- App Nap / Timer-Coalescing des 50ms-Regel-Threads: `ProcessInfo.beginActivity` muss über die gesamte Laufzeit gehalten werden — sonst driftet der Regler im Batteriebetrieb nach Stunden (Fehlerklasse die nur der 24h-Soak zeigt)
- Nicht-ASCII-Geräte-UIDs explizit testen (CJK-Seriennummern — v3.4.4-Bug-Klasse): Swift-Strings eliminieren das Escaping-Problem, aber CoreAudio-CFString-Bridging und UserDefaults-Roundtrips brauchen trotzdem einen Testfall — kostet 10 Minuten, ist in Phase 5 verankert, aber Architektur schon hier berücksichtigen

**Testpunkt:** 24h-Vorab-Soak (USB + Bluetooth gleichzeitig), Underrun-Zähler == 0 nach Einschwingphase, Drift im ±500 ppm-Band.

**Zeitpuffer:** Puffer in Phase 3 einplanen (wie in Phase 6). Der PI-Regler war in v3 bereits ein kritisches Arbeitspaket.

**Dependencies:** Phase 2 Fan-out stabil

**Deliverable:** 24h-stabiler Betrieb mit PI-Regler aktiv

---

#### Phase 4: Menu Bar UI + Uninstaller (Woche 7–8)

**Ziel:** SwiftUI `MenuBarExtra` vollständig, Uninstaller-Helper signiert und notarisiert.

**Key Tasks:**
- SwiftUI `MenuBarExtra`: Geräte-Selektion (Multi-Checkbox), Volume/Mute pro Output, Sample-Rate-Anzeige, Health-Status (Ampel)
- UserDefaults-Persistenz (Login-Item-Toggle bereits aus Phase 2)
- Alle UI-Texte Englisch — Ton-of-Voice-Pass (CASE-001-Lektion: keine Sprachmischung). String-Catalog anlegen.
- App-Icon + Menu-Bar-Icon-Set (Template-Rendering Dark/Light)
- Uninstaller-Helper als eigenes Signing-/Notarisierungs-Artefakt bauen und signieren — explizit HIER (nicht in Phase 6 oder der Launch-Woche). Eigenes Notarisierungs-Verfahren, eigene Wartezeit.
- Tip Jar IAP: Formulierung muss Guideline 3.2.1 sicher bestehen. Wortwahl 'support development' statt 'donation' — vor Phase 5 textuell freigeben.

**Testpunkt:** UX-Parität mit v3.x, Uninstaller-Helper läuft auf sauberem System.

**Dependencies:** Phase 3 Regler stabil

**Deliverable:** Vollständige UI + notarisierter Uninstaller-Helper

---

#### Phase 5: Robustheit, Edge Cases + Beta (Woche 9–10)

**Ziel:** Alle Edge Cases stabil, externe Beta mit 10–30 Nutzern abgeschlossen.

**Key Tasks:**
- Hot-Plug während Wiedergabe (Add/Remove, Default-Device-Wechsel)
- `coreaudiod`-Restart-Recovery (Tap + IOProcs neu aufbauen)
- Nicht-ASCII-Geräte-UIDs Testfall ausführen (CJK, geplant seit Phase 3)
- HDMI-Audio als Output-Klasse: HDMI-Geräte verschwinden bei Display-Sleep — Edge Case in Test-Matrix aufnehmen (verwandt mit BenQ-Dropout-Problemen aus v3)
- IAP-Konfiguration lokal durchtesten mit StoreKit-Config — IAP-Konfigurationsfehler blockieren sonst den Build-Review
- Externe Beta (10–30 Nutzer, u.a. MacRumors-Kontakt bogdanw): strukturiertes Feedback-Formular, Diagnostic-Report-Flow als Support-Kanal
- BT-Sync-Erwartungsmanagement in Beta-Notes: Feedback wird subjektiv streuen (jedes BT-Gerät anders) — Trim-Slider ist das Ventil, das in den Beta-Notes erklären
- Wichtig: Kritische Bugs aus v3 traten nur auf Fremdsystemen auf (CASE-001, CJK-UIDs) → Geräte-Diversität der Beta ist der eigentliche Wert, nicht die Nutzerzahl
- Mindestens 2 Beta-Builds, Crash-/Feedback-Auswertung über TestFlight, externe Beta-Review-Durchlauf einplanen

**Testpunkte:**
- Kein Crash, kein Silent-Failure in allen Edge Cases
- macOS-Versions-Verhalten dokumentiert: TCC-/Tap-Verhalten auf 14.2/14.3 vs. 14.4+ geprüft, Mindestversion final bestätigt oder angehoben

**Dependencies:** Phase 4 UI + Uninstaller abgeschlossen

**Deliverable:** TestFlight-Beta mit externen Nutzern abgeschlossen, Crash-Rate == 0 für bekannte Fälle

---

#### Phase 6: App Store Submission + GitHub Release (Woche 11–13)

**Ziel:** Vollständige Submission für beide Distributions-Kanäle (MAS + Developer ID).

**Key Tasks:**
- Privacy Manifest (`PrivacyInfo.xcprivacy`): Audio Capture Usage
- App Store Screenshots (5 Stück), App Description Englisch
- App-Review-Notes: Begründung des System-Audio-Zugriffs explizit dokumentieren (Review-Risiko minimieren)
- App-Store-Beschreibung: 'route any audio' vermeiden — darf keine DRM-Umgehungs-Assoziation wecken. DRM-Disclaimer ist geplant — gut so.
- Zwei Signing-Identitäten (Apple Distribution vs. Developer ID) in einer CI — sauber getrennte Keychains/Profiles in den Workflows
- Zwei Distributions-Kanäle = doppelte Release-Checkliste → Release-Runbook als expliziten Task schreiben (nicht improvisieren in der Launch-Woche)
- `notarytool` + `spctl`-Verifizierung, TestFlight-Build läuft auf sauberem System
- EU DSA Händlerstatus in App Store Connect ausfüllen (falls noch nicht erledigt)
- Zeitpuffer: Beta-Review-Zyklen bei TestFlight und App-Review-Iterationspuffer einplanen

**Post-Launch (ab Phase 6+):**
- ARN Insights Tracker (Hetzner-Pipeline) um App-Store-Reviews/Ratings als Datenquelle erweitern — Datenmodell früh bedenken, Umsetzung Post-Launch
- v4-GitHub-Issues mit eigenem Issue-Template anlegen (getrennt von v3)
- Rejection-Playbook bereithalten (häufigste Ablehnungsgründe + vorbereitete Antworten)

**Dependencies:** Phase 5 Beta abgeschlossen, Uninstaller notarisiert (Phase 4)

**Deliverable:** v4.0 live im App Store + GitHub Release

---

### Architektur-Entscheidungen

| Topic | Entscheidung | Begründung | Quelle |
|---|---|---|---|
| Audio-Capture | `CATapDescription` System Tap | Apple-offizielle API, keine Admin-Rechte, keine Installation | PLAN.md §3.1 |
| Fan-out | Direkte CoreAudio IOProcs pro Output (Option B) | Port der gehärteten v3-Logik, volle Clock-Kontrolle, Channel-Offsets | PLAN.md §3.2 |
| SR-Konversion | Bypass bei SR-Gleichheit, sonst SRC | Doppel-Konversion (Converter + Resampler) kostet Qualität + CPU | Agent B [37] |
| Drift-Kompensation | PI-Regler Port aus C nach Swift | Produktionserprobt in v3, bekannte Edge Cases | PLAN.md §3.3 |
| Projekt-Struktur | SPM-Package `AudioRouterKit` ab Tag 1 | Engine-Unit-Tests ohne UI-Bootstrap, testbare Isolation | Agent A [28] |
| Uninstaller | Eigenes Signing-Artefakt in Phase 4 | Separates Notarisierungs-Verfahren, nicht in Launch-Woche | Synthese [79] |
| Zeitplan | 11–13 Wochen Teilzeit | Beide Agents konvergent, Puffer in Phase 3+6 | Synthese [78] |
| Mute-Behavior | `mutedWhenTapped` | Kein paralleler Signalweg, konsistentes Fan-out-Modell | PLAN.md §0.1 |
| Monetarisierung | Tip Jar via IAP (Guideline 3.2.1) | 'support development' Formulierung, kein Donation-Framing | PLAN.md §6 |
| Distribution | App Store + Developer ID parallel | Maximale Reichweite, beide Kanäle ab Phase 6 | Synthese [75] |

---

### Go/No-Go-Kriterien

**Phase 1 (einziger echter Go/No-Go):**
- Apple Music Streaming via Process Tap: Audio wird geroutet
- Apple Music Downloads via Process Tap: Audio wird geroutet
- Apple Music Lossless via Process Tap: Audio wird geroutet
- Selbst-Aufnahme-Loop ausgeschlossen (kein Echo durch eigene Outputs)
- SR-/Format-Wechsel des Default-Geräts während laufendem Tap: kein Crash, Property-Listener greift

**Phase 5 (Release-Freigabe):**
- Verifikation: `MenuBarExtra` startet auf sauberem System ohne vorherige v4-Installation
- `codesign -dv` zeigt Sandbox + korrekte Signatur für alle Artefakte (App + Uninstaller-Helper)
- `swift test` läuft ohne UI-Bootstrap, keine Regressions
- macOS-Versionsverhalten dokumentiert: TCC-/Tap-Verhalten auf 14.2 vs. 14.4+ geprüft
- Tip-Jar-Formulierung final freigegeben (Guideline 3.2.1)
- CPU-Baseline: Tap + Passthrough auf 1 Gerät unter 3% auf Apple Silicon (Budget-Anker für 3+ Outputs mit SRC)
- Keine hörbaren Glitches über 1h Dauerlauf auf Referenz-Setup

---

### Offene Fragen

1. **Entitlement-Widerspruch (Pre-Phase-0 klären):** Welche genaue Entitlement-Kombination benötigt `AudioHardwareCreateProcessTap` im MAS-Sandbox-Kontext? Rogue Amoeba und insidegui/AudioCap nutzen teils unterschiedliche Kombinationen. Vor Phase 0 klären.

2. **VM-Testplan:** Wie wird das Verhalten auf sauberem System (ohne Entwickler-Zertifikate, ohne Xcode) getestet? Separates System oder VM-Ansatz definieren.

3. **ARN Insights Tracker:** Soll die Hetzner-Pipeline für v4 um App-Store-Reviews/Ratings als Datenquelle erweitert werden? Zeitpunkt: Post-Launch. Aber Datenmodell früh bedenken (Agent A [25], Synthese [77]).

4. **Mindestversion final:** macOS 14.2 oder 14.4? Tap-APIs wurden nach 14.2 verfeinert. Erst mit laufendem Prototyp beantwortbar.

---

### Unique Insights (aus Agent-Analyse)

- **Uninstaller als eigenes Artefakt (Phase 4, nicht Phase 6/7):** Beide Agents unabhängig. Eigenes Signing + Notarisierungs-Verfahren braucht eigene Vorlaufzeit. Wer das in die Launch-Woche legt, riskiert Verzögerung. [A+B konvergent]

- **Zeitschätzung-Korrektur ist evidenzbasiert:** Der PI-Regler war in v3 bereits ein scheiterndes Arbeitspaket. Latenz-Kompensation MUSS als eigenes Arbeitspaket behandelt werden. 11–13 Wochen, Puffer in Phase 3 und 6. [A+B konvergent]

- **AirPlay früh testen:** AirPlay-Geräte als IOProc-Ziel verhalten sich fundamental anders als physische Devices. Wer das auf Phase 5 verschiebt, riskiert Architektur-Anpassungen zu einem ungünstigen Zeitpunkt. [Agent A]

- **Prototyp-Code-Disziplin:** Prototyp-Code wird schleichend Produktionscode. Bewusst als Wegwerf-Code deklarieren und nicht in Phase 1 Strukturen aufbauen, die Phase 2+ bereuen werden. [Agent B]

- **Geräte-Diversität der Beta ist der Wert:** CASE-001 und die CJK-UID-Bug-Klasse wurden nie auf dem Entwickler-System reproduziert. Der Wert der Beta liegt in der Hardware-Diversität, nicht in der Nutzerzahl. [Agent B]

- **UTF-8-UID-Bug-Klasse:** Swift-Strings eliminieren das Escaping-Problem nicht überall. CoreAudio-CFString-Bridging und UserDefaults-Roundtrips brauchen einen expliziten Nicht-ASCII-Testfall — 10 Minuten, aber vergessen führt zu v3.4.4-Klasse-Bugs. [Agent A]

- **`ProcessInfo.beginActivity` über gesamte Laufzeit:** App Nap / Timer-Coalescing des 50ms-Regel-Threads ist ein Restrisiko, das nur der 24h-Soak zeigt. Muss als Laufzeit-Invariante behandelt werden, nicht als einmaliger Setup-Schritt. [Audit]

---

## Audit-Ergebnis

**Verdict:** UMSETZUNGSBEREIT nach Auflösung von zwei Punkten: Entitlement-Widerspruch (Pre-Phase-0) und VM-Testplan-Definition (Phase 5). Der Plan ist mit Abstand der reifste Stand des Projekts — Architektur tragfähig, keine technische Sackgasse identifiziert, Phasenreihenfolge und Dependencies konsistent.

---

### Starken

- Phasenreihenfolge ist technisch korrekt und risk-first: Go/No-Go in Phase 1 verhindert Wochen verlorener Arbeit bei negativem Tap-Ergebnis
- PI-Regler wird nicht neu erfunden, sondern portiert — bekannte Fehlerklassen und bekannte Testmethodik
- Dual-Distribution-Lane ist explizit eingeplant statt am Ende improvisiert
- Uninstaller ist als eigenes Artefakt mit eigener Vorlaufzeit eingeplant
- Zeitschätzung basiert auf zwei unabhängig konvergierten Schätzungen (starkes Signal)
- Beta-Strategie mit Geräte-Diversität als primärem Wert ist korrekt priorisiert

---

### Lucken / Findings

| Area | Issue | Severity | Suggestion |
|---|---|---|---|
| Entitlement | Welche Kombination genau für MAS-Sandbox + Process Tap? Widerspruch zwischen verschiedenen Referenzimplementierungen. | Hoch | Vor Phase 0 mit Apple Developer Docs und insidegui/AudioCap-Entitlements abgleichen. PoC auf frischem MAS-Profil testen. |
| VM-Testplan | Kein expliziter Plan für Tests auf sauberem System ohne Entwickler-Setup. | Mittel | Separates Test-Nutzerkonto auf Hauptrechner oder VM-Ansatz definieren, bevor Phase 5 endet. |
| HDMI-Audio | HDMI-Geräte verschwinden bei Display-Sleep — nicht in der Edge-Case-Matrix. | Mittel | Testfall in Phase 5 ergänzen: Display-Sleep während Wiedergabe auf HDMI-Output. Verwandt mit BenQ-Dropout-Historie aus v3. |

---

### App Store Risiken

- **DRM-Formulierung:** App-Beschreibung darf keine DRM-Umgehungs-Assoziation wecken. 'route any audio' vermeiden. DRM-Disclaimer ist geplant — Wording vor Submission final prüfen.
- **Tip Jar Guideline 3.2.1:** Formulierung 'support development' ist etabliert für Privatpersonen via IAP. Formulierung muss vor Phase 5 final freigegeben sein — IAP-Text-Änderungen nach Submission sind aufwändig.
- **Audio-Capture Review-Begründung:** Review-Notes müssen klar erklären warum `NSAudioCaptureUsageDescription` legitim ist (kein Recording, nur Routing). Fehlerhafte oder fehlende Begründung ist der häufigste Ablehnungsgrund für Audio-Apps.

---

### Technische Risiken

- **App Nap / Timer-Coalescing:** `ProcessInfo.beginActivity` muss als Laufzeit-Invariante über die gesamte App-Laufzeit gehalten werden. Fehler hier driftet der PI-Regler im Batteriebetrieb nach Stunden — Fehlerklasse die nur der 24h-Soak zeigt.
- **HDMI-Display-Sleep:** HDMI-Geräte verschwinden bei Display-Sleep und sind damit eine eigene Output-Klasse mit eigenem Reconnect-Verhalten, verwandt mit BenQ-Dropout-Problemen aus v3.
- **AirPlay IOProc:** AirPlay-Geräte als IOProc-Ziel haben andere Latenz-Eigenschaften und Reconnect-Verhalten als physische Devices. Früh testen (Phase 1), nicht erst in Phase 5.

---

### Fehlende Uberlegungen

- **HDMI-Audio als Output-Klasse** ist in der bestehenden PLAN.md-Edge-Case-Matrix nicht explizit adressiert, obwohl HDMI-Geräte bei Display-Sleep verschwinden — identische Fehlerklasse wie BenQ-Dropout aus v3.
- **VM-Testplan** für Phase 5 ist nicht definiert. Sauberes System ohne Entwickler-Zertifikate = kritisch für Submission-Verifikation.
- **Entitlement-Validierung auf echtem MAS-Profil** (nicht Developer-ID-Profil) fehlt als expliziter Schritt in Phase 0.

---

### Finale Empfehlungen

1. **Vor Phase 0:** Entitlement-Widerspruch auflösen — insidegui/AudioCap-Entitlements mit eigenem MAS-Sandbox-PoC abgleichen.
2. **Phase 0:** SPM-Package-Struktur erzwingen, nicht als Option behandeln. Falsche Struktur macht Engine-Tests für alle folgenden Phasen mühsamer.
3. **Phase 1:** AirPlay-Geräte als IOProc-Ziel hier testen, nicht auf Phase 5 verschieben.
4. **Phase 3:** Zeitpuffer einplanen. PI-Regler war in v3 ein scheiterndes Arbeitspaket. `ProcessInfo.beginActivity` als Laufzeit-Invariante implementieren, nicht als einmaligen Setup.
5. **Phase 4:** Uninstaller-Helper Signing + Notarisierung hier abschliessen. Launch-Woche ist der falsche Zeitpunkt.
6. **Phase 5:** HDMI-Display-Sleep-Testfall in Edge-Case-Matrix ergänzen. VM-Testplan definieren.
7. **Phase 6:** Release-Runbook schreiben bevor die Phase beginnt. Zwei Channels = doppelte Checkliste, die nicht improvisiert werden kann.
8. **Zeitplanung:** 11–13 Wochen ist die evidenzbasierte Schätzung. Puffer in Phase 3 und 6, nicht als Float am Ende.

---

## Issue-Resolutions (06.07.2026)

*Analysiert via 3 parallele Fable-Agenten + Synthese*

### Issue 1: Entitlement-Widerspruch — Confidence: hoch

**Status:** Aufgelöst. PLAN.md Zeile 332 ist korrekt — die geplante Entitlement-Kombination ist durch Apples eigenes sandboxtes Sample-Projekt 1:1 belegt. Offener Punkt Zeile 467 ("spezielle Entitlements nötig?") kann abgehakt werden: Nein.

**Root Cause:** Der scheinbare Widerspruch entsteht durch zwei getrennte, nirgends zusammenhängend dokumentierte Ebenen:
1. **Sandbox-Ebene:** `com.apple.security.device.audio-input` gated JEDEN Audio-Capture-Pfad in der Sandbox — auch das Lesen vom Aggregate-Device mit Tap, nicht nur das Mikrofon.
2. **TCC-Ebene:** Process Taps haben eine eigene, vom Mikrofon getrennte TCC-Kategorie ("System Audio Recording Only"); der Prompt-Text kommt aus `NSAudioCaptureUsageDescription` (Key fehlt im Xcode-Dropdown, manuell eintragen).

Referenzen wie Rogue Amoeba/DGR Labs verwirren, weil deren Apps nicht sandboxed/MAS sind. Definitiver Beweis: Apples offizielles Sample `CapturingSystemAudioWithCoreAudioTaps` (Entitlements direkt geprüft) ist sandboxed mit exakt `app-sandbox=true` + `device.audio-input=true` + `NSAudioCaptureUsageDescription` — identisch mit insidegui/AudioCap. Es gibt kein spezifischeres Tap-Entitlement, kein Antragsverfahren, kein DriverKit.

**Lösung:** Geplante Kombination beibehalten und präzisieren — minimale, maximal genehmigungsfähige Konfiguration:

```xml
<!-- AudioRouterNow.entitlements (vollständig — mehr ist NICHT nötig) -->
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.device.audio-input</key><true/>

<!-- Info.plist (manuell eintragen, nicht im Xcode-Dropdown!) -->
<key>NSAudioCaptureUsageDescription</key>
<string>AudioRouterNow benötigt Zugriff auf Systemaudio, um es an mehrere
Ausgabegeräte weiterzuleiten. Es wird nichts aufgenommen oder gespeichert.</string>
```

Kritische MAS-Randbedingung (bisher nicht im Plan): Es gibt **keine public API** zum Abfragen/Anfordern der System-Audio-Permission. AudioCaps privater TCC-SPI-Pfad darf NICHT portiert werden (Guideline 2.5.1 → Rejection). Stattdessen: Prompt feuert automatisch beim ersten IO-Start auf dem Aggregate-Device mit Tap; Verweigert-Fall heuristisch erkennen (Tap liefert nur Silence) + Deep-Link `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`.

**Konkrete Schritte (Phase 0/1):**
- **0.1** — Entitlements-Datei mit exakt zwei Keys anlegen (keine Temporary Exceptions, kein DriverKit)
- **0.2** — `NSAudioCaptureUsageDescription` manuell in Info.plist; Text betont Routing-only, keine Aufnahme
- **0.3** — PLAN.md Zeile 264 korrigieren: Deployment-Target **14.4 statt 14.2** (vor 14.4 andere TCC-Kategorie, divergentes Prompt-Verhalten)
- **0.4** — PLAN.md Zeile 369 korrigieren: Es existiert **keine** "Audio Capture"-Kategorie im Privacy Manifest. PrivacyInfo.xcprivacy wird wegen Required-Reason-APIs gebraucht (UserDefaults → Reason CA92.1); `NSPrivacyCollectedDataTypes` leer deklarieren
- **0.5** — Signing von Anfang an mit stabiler Team-Identity (TCC-Record ist an Signing-Identity gekoppelt; unsignierte Builds → Silent Failure, Prompt feuert nie). Dev-Reset: `tccutil reset SystemAudioCaptureRequests <bundle-id>`
- **Phase 1** — Permission-Flow ohne private TCC-API implementieren; Silence-Heuristik + Deep-Link (deckt Phase-5-"graceful degradation" ab)
- **Phase 6** — Review-Notes: erklären, dass `device.audio-input` nur für den Tap-Pfad genutzt wird, kein Mikrofonzugriff, keine Aufzeichnung; Demo-Video beilegen

**Swift-Sketch:**
```swift
// KEIN privater TCC-Check im MAS-Build (AudioCap-SPI-Pfad NICHT portieren):
func startRouting() throws {
    let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    tapDesc.isPrivate = true; tapDesc.muteBehavior = .unmuted
    var tapID = AudioObjectID(kAudioObjectUnknown)
    try check(AudioHardwareCreateProcessTap(tapDesc, &tapID)) // TCC-Prompt feuert beim ersten IO-Start
    // Aggregate mit kAudioAggregateDeviceTapListKey + kAudioAggregateDeviceIsPrivateKey=true
    // Verweigert-Erkennung: N Callbacks lang nur Silence -> Hinweis + Deep-Link:
    // x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture
}
```

**Phase-Integration:** Schritte 0.1–0.5 ersetzen/präzisieren PLAN.md Zeilen 330–335 (Phase 0, Woche 1). Permission-Flow → Phase 1 (Zeile 340) und Phase 5 (Zeile 364). Privacy-Manifest-Korrektur → Phase 6 (Zeile 369).

**Verbleibende Risiken:**
- audio-input-Entitlement ohne sichtbare Mikrofonnutzung kann Reviewer-Rückfragen auslösen — via Review-Notes + Demo-Video mitigierbar; Restrisiko einer ersten Rejection bleibt
- Silence-Heuristik nicht 100% deterministisch (echtes Silence vs. verweigerte Permission) — UX muss beide Fälle kommunizieren
- DGR Labs meldet "CATap unter Sandbox fragil" — Phase-1-PoC muss Sandbox-Edge-Cases testen (Aggregate-Lifecycle, coreaudiod-Restart), bevor Phase 2 startet
- tccutil-Service-Name `SystemAudioCaptureRequests` stammt aus Sekundärquelle — in Phase 0/1 lokal verifizieren
- Wenig MAS-Precedent für reine Tap-Routing-Apps; künftiges TCC-Verhalten nicht garantiert

**Quellen:**
- [Apple: Capturing System Audio with Core Audio Taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [Apple Sample (Entitlements direkt verifiziert)](https://docs-assets.developer.apple.com/published/02fe64305fe7/CapturingSystemAudioWithCoreAudioTaps.zip)
- [NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription) · [device.audio-input Entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.device.audio-input)
- [insidegui/AudioCap](https://github.com/insidegui/AudioCap) + [Entitlements-Datei](https://raw.githubusercontent.com/insidegui/AudioCap/main/AudioCap/AudioCap.entitlements)
- [DGR Labs: Capturing System Audio on macOS in 2026](https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html)
- `v4-appstore/PLAN.md` Zeilen 264, 269, 330–335, 369, 467

---

### Issue 2: VM-Testplan — Confidence: hoch

**Root Cause:** Kein einzelnes Setup deckt beide Distributionskanäle UND Audio-Hardware ab: App-Store/TestFlight-Login ist in VMs unmöglich, USB-/Bluetooth-Passthrough existiert für macOS-Guests auf Apple Silicon nicht, und Gatekeeper-Caches sind auf einer einmal benutzten Maschine nicht resetbar.

**Lösung:** 4-Schichten-Kombination:
1. **UTM-VM** (gratis, Apple-Virtualization-Backend) als primäres Clean-System für den Developer-ID-DMG-Kanal — Gatekeeper/Notarisierung/TCC/Onboarding/Locale zu 100% testbar; Golden-Image pro Testlauf klonen (Apple-DTS-Empfehlung). Zweite VM mit macOS 14.4 für die TCC-Versions-Matrix.
2. **TestFlight auf Fremdgeräten** (bogdanw + 10–30 Beta-User) als einziger MAS-Kanal-Cleantest + Geräte-Diversität (CJK-UIDs/CASE-001).
3. **Ein physischer Clean-Mac** (Kandidat: alter MacBook Pro mit frischem macOS >= 14.4) für die Audio-Hardware-Matrix (USB, BT, HDMI/Display-Sleep — geht in der VM nicht).
4. **GitHub Actions** als automatisiertes Signatur-Gate pro Release-Build.

**Verworfen:** Zweit-Nutzerkonto auf dem Dev-Mac — Gatekeeper-Caches und Dev-Zertifikate sind systemweit; taugt nur für Per-User-State-Regression, nicht als Clean-Test.

**Konkrete Schritte (Phase 5/6):**
- **Setup (1x, ~2h):** UTM + macOS-15-IPSW-VM, Locale Deutsch oder Japanisch (CASE-001), keine Dev-Tools, als `golden-clean-15.utm` archivieren; zweite Golden-VM mit 14.4. Pro Testlauf Golden-Image **kopieren**, nie das Original booten.
- **CI-Gate (Phase 6, pro Release-Build):** `codesign --verify --deep --strict`, `spctl -a -t exec -vv` (erwarte: 'source=Notarized Developer ID'), `xcrun stapler validate` auf App UND Uninstaller-Helper.
- **VM-Checkliste (pro Release Candidate):** [1] DMG via Safari von echter Release-URL laden (Quarantäne-Flag, nicht per Shared Folder) → [2] `xattr -p com.apple.quarantine` prüfen → [3] Install nach /Applications → [4] Erststart: Gatekeeper zeigt "Apple hat … geprüft", kein "beschädigt" → [5] TCC-Prompt genau einmal, Text korrekt → [6] Onboarding komplett Englisch trotz DE/JP-Locale (CASE-001) → [7] Routing aktiv, Ton hörbar → [8] Login-Item + Reboot: Persistenz intakt, kein zweiter TCC-Prompt → [9] TCC entziehen → saubere Degradation → [10] Uninstaller: eigener Gatekeeper-Check, rückstandsfreie Entfernung → [11] Gleiche Liste auf der 14.4-VM, Unterschiede dokumentieren → Mindestversion final bestätigen.
- **Physischer Clean-Test (1x vor Submission):** Checkliste [1]–[10] plus Hardware-Matrix: USB-Hot-Plug während Wiedergabe, BT-Connect/Disconnect/Reconnect-Kaskade, USB+BT gleichzeitig (Drift/PI-Regler), HDMI + Display-Sleep (BenQ-Klasse), Default-Device-Wechsel.
- **TestFlight-Beta (Phase 5):** Feedback-Formular fragt explizit macOS-Version, Geräteliste (`system_profiler SPAudioDataType`), Non-ASCII-Gerätenamen ja/nein; bogdanw gezielt um Erstinstallations-Flow-Beschreibung bitten.
- **Runbook:** Checkliste als `v4-appstore/CLEAN_SYSTEM_TEST.md` ins Repo; VM-Checkliste grün = Blocker für notarytool-Submit, physischer Test grün = Blocker für App-Store-Submission.

**Swift-Sketch:**
```bash
# Golden-Image-Workflow (UTM, Apple-Silicon-Host)
cp -R ~/VMs/golden-clean-15.utm ~/VMs/testrun-$(date +%Y%m%d).utm  # nie das Original booten

# CI-Signatur-Gate (GitHub Actions Schritt)
codesign --verify --deep --strict --verbose=2 AudioRouterNow.app
spctl -a -t exec -vv AudioRouterNow.app        # erwarte: 'source=Notarized Developer ID'
xcrun stapler validate AudioRouterNow.app
xcrun stapler validate Uninstaller.app          # eigenes Artefakt (Phase 4)!

# In der VM: Quarantäne verifizieren (Safari-Download vorausgesetzt)
xattr -p com.apple.quarantine ~/Downloads/AudioRouterNow.dmg
```

**Phase-Integration:** Kern in Phase 5 (Woche 9–10): VM-Setup + Checkliste + Versions-Matrix ergänzen den bestehenden Testpunkt "TCC-/Tap-Verhalten 14.2/14.3 vs. 14.4+". Physischer Clean-Test und CI-Signatur-Gate als Gate an den Anfang von Phase 6. Uninstaller-Clean-Test validiert rückwirkend den Phase-4-Punkt.

**Verbleibende Risiken:**
- Echter App-Store-Kauf-Install ist vor Live-Gang nirgends 1:1 testbar — TestFlight ist die beste Näherung; Restrisiko via Review-Notes + Rejection-Playbook (Phase 6)
- Alter MacBook Pro unterstützt evtl. kein 14.4+ (Modell prüfen!) — Fallback: Bekannten-Mac oder frisches APFS-Volume auf dem Dev-Mac
- CATapDescription gegen VirtIO-Audio kann von echter Hardware abweichen — VM validiert Signing/TCC/UX, **nicht** Audio-Korrektheit
- Intel-Macs in der Beta-Population berücksichtigen, falls v4 Intel unterstützt (Apple-Silicon-VMs testen nur arm64)

**Quellen:**
- [Apple DTS/Quinn: Testing a Notarised Product](https://developer.apple.com/forums/thread/130560) · [Notarizing macOS Software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [macOS-VMs auf Apple Silicon](https://developer.apple.com/documentation/Virtualization/running-macos-in-a-virtual-machine-on-apple-silicon) · [Eclectic Light: Apple-ID in VMs, kein App Store](https://eclecticlight.co/2024/07/12/sequoia-virtualisation-and-apple-id/)
- [Parallels KB 128867](https://kb.parallels.com/en/128867) · [UTM #3778: kein USB-Passthrough](https://github.com/utmapp/UTM/issues/3778) · [VMware/Broadcom: BT-Sharing-Limits](https://knowledge.broadcom.com/external/article/311216/)
- `v4-appstore/IMPLEMENTATION_PLAN.md` (Phase 4–6)

---

### Issue 3: HDMI-Display-Sleep — Confidence: hoch

**Root Cause:** HDMI/DP-Audio ist eine Funktion des Grafiktreibers (AppleGFXHDA bzw. DCP auf Apple Silicon). Bei Display-Sleep schaltet macOS die Audio-Funktion des Ports stromlos, coreaudiod unpublisht das Device vollständig (anders als USB). Der laufende IOProc erhält **keinen** Error-Callback — Silent Drop. `AudioDeviceStop`/`DestroyIOProcID` auf der toten ID liefern `kAudioHardwareBadDeviceError` ('!dev' = 560227702), sind aber gefahrlos. Beim Wake erscheint das Device mit **neuer** AudioDeviceID (nur die UID ist stabil), gefolgt von EDID-Renegotiation mit SR-/Format-Flaps in den ersten Sekunden. Bekannter macOS-Bug: nach mehreren Sleep-Zyklen kommt das Device teils bis Reboot gar nicht zurück. Die BenQ-Dropouts aus v3 sind dieselbe Fehlerklasse.

**Lösung:** UID-keyed **Desired-State-Reconciliation** mit per-Output-Zustandsmaschine — dieselbe Maschinerie wie für BT-Reconnect-Kaskaden (Phase 3), nur mit transportspezifischen Settle-Parametern (~90% Code-Identität):
- v3-Teardown-Muster portieren (`helper/AudioRouterNowHelper.c:1735–1797`) + den in v3 fehlenden Auto-Re-Attach ergänzen
- Idempotenter Diff Desired-vs-Live: jedes Event (Device-Liste, IsAlive, Watchdog, coreaudiod-Restart) triggert denselben `reconcile()`-Durchlauf auf serieller Queue
- Fan-out-Isolation: pro Output eigener SPSC-Ring + eigener IOProc; Tap-Callback überspringt lost/settling-Branches non-blocking
- Settle-Karenz quiescence-basiert: HDMI/DP T=3s, BT 2s, sonst 1s — Parameter via `kAudioDevicePropertyTransportType`

Zustandsmaschine: `active → lost(since) → settling(deadline) → active` bzw. `failed(retryAt, attempts)` mit Backoff 1/2/4/8s. `tryAttach` löst die neue AudioDeviceID immer via `kAudioHardwarePropertyTranslateUIDToDevice` auf, liest SR/StreamFormat frisch.

**Konkrete Schritte (Phase 2/3/4/5):**
- **Phase 2:** OutputUnit-API idempotent/fehlertolerant — '!dev' (560227702) als erwarteten Pfad tolerieren; pro Output eigener SPSC-Ring, Tap-Callback überspringt inaktive Branches non-blocking
- **Phase 3:** DeviceLifecycleManager mit UID-keyed Desired-State + `reconcile()` auf serieller Queue; Listener für `kAudioHardwarePropertyDevices`, `DeviceIsAlive` und `ServiceRestarted`; Callbacks enqueuen NUR (v3-Lektion H3, kein Re-Entry-Deadlock)
- **Phase 3:** Quiescence-Settle statt fixem Timer (HDMI/DP 3s, BT 2s, sonst 1s)
- **Phase 3:** Watchdog im 50ms-Regel-Thread — IOProc-Timestamp älter 1s bei nominell aktivem Output → lost → `reconcile()`; fängt Silent-Drop ohne Notification
- **Phase 3:** `tryAttach` löst DeviceID neu auf, liest SR/Format frisch, entscheidet SRC-Bypass neu (EDID-Renegotiation nach Wake)
- **Phase 4:** UI-Zustand "waiting for device" (Ampel gelb) für dauerhaft wegbleibendes HDMI; User-Selektion bleibt als Desired-State erhalten
- **Phase 5:** Edge-Case-Testfall — Display-Sleep während Wiedergabe auf HDMI + 2 weiteren Outputs: andere Outputs glitch-frei (Underrun-Zähler == 0), HDMI spielt nach Wake innerhalb Settle+2s; plus 5x Sleep/Wake-Kaskade (BenQ-Muster)
- **Phase 5 (optional):** opt-in NoDisplaySleep-IOPMAssertion während HDMI-Output aktiv, Default aus; als Beta-Feedback-Frage mitnehmen

**Swift-Sketch:**
```swift
// AudioRouterKit: DeviceLifecycleManager (serielle Queue, KEINE Arbeit im CoreAudio-Callback)
enum OutputState {
  case active(OutputUnit)
  case lost(since: Date)           // Device weg, DesiredOutput bleibt erhalten
  case settling(deadline: Date)    // wieder da, Quiescence-Fenster läuft
  case failed(retryAt: Date, attempts: Int)
}

final class DeviceLifecycleManager {
  private let q = DispatchQueue(label: "arn.lifecycle")
  private var desired: [DeviceUID: OutputConfig]  // User-Intent, persistiert
  private var states:  [DeviceUID: OutputState]

  func install() {
    // v3-Lektion H3: Callback enqueued NUR, kein CoreAudio-Call, kein Lock
    AudioObjectAddPropertyListenerBlock(systemObj, &devicesAddr, q) { _,_ in self.reconcile() }
    AudioObjectAddPropertyListenerBlock(systemObj, &serviceRestartedAddr, q) { _,_ in self.rebuildAll() }
  }

  private func reconcile() {  // idempotent, von JEDEM Event getriggert
    let live = Set(currentDeviceUIDs())
    for (uid, cfg) in desired {
      switch (states[uid], live.contains(uid)) {
      case (.active(let unit), false):
        teardown(unit); states[uid] = .lost(since: .now)
      case (.lost, true), (.failed, true):
        armSettle(uid, cfg)
      case (.settling, false):
        states[uid] = .lost(since: .now)
      default: break
      }
    }
  }

  private func armSettle(_ uid: DeviceUID, _ cfg: OutputConfig) {
    let t = settleInterval(uid)  // TransportType: HDMI/DP 3s, BT 2s, sonst 1s
    states[uid] = .settling(deadline: .now + t)
    q.asyncAfter(deadline: .now() + t) { self.tryAttach(uid, cfg) }
  }

  private func tryAttach(_ uid: DeviceUID, _ cfg: OutputConfig) {
    guard case .settling(let dl) = states[uid], Date.now >= dl else { return }
    guard let devID = translateUIDToDevice(uid), isAlive(devID) else {
      states[uid] = .lost(since: .now); return
    }
    // NEUE AudioDeviceID! SR/Format frisch lesen, SRC-Bypass neu entscheiden
    do {
      let unit = try OutputUnit(devID, cfg, tapFormat)
      unit.addIsAliveListener(q) { self.reconcile() }
      try unit.start()
      states[uid] = .active(unit)
    } catch {
      states[uid] = .failed(retryAt: .now + backoff, attempts: n+1)
    }
  }
}
// Watchdog (50ms-Regel-Thread): IOProc-Timestamp älter 1s bei aktivem Output -> reconcile()
// Tap-Callback: schreibt non-blocking nur in Ringe von .active-Outputs
```

**Phase-Integration:** Kern in Phase 3 — "Settle-Karenz + idempotenter Graph-Rebuild" ist dort für BT bereits verankert (Zeile 106); HDMI wird als zweiter Transport-Parameter derselben Maschinerie mitimplementiert, **nicht** als separates Feature. Vorbereitung in Phase 2, Testfall + UI-Zustand in Phase 5 (Audit-Finding Zeile 281). Der Punkt wandert damit aus "Fehlende Überlegungen" (Zeile 303) in die reguläre Edge-Case-Matrix.

**Verbleibende Risiken:**
- Verhalten variiert pro GPU/Monitor: Device-Removal vs. IsAlive=0 vs. Zero-Buffers — Watchdog als drittes Erkennungsnetz zwingend; final nur über Beta-Geräte-Diversität verifizierbar
- HDMI-UID kann sich bei Port-Wechsel/generischen EDIDs ändern — ggf. Fallback-Matching über Device-Namen als Phase-5-Erweiterung
- macOS-Bug "Device kommt bis Reboot nicht zurück" ist app-seitig nicht heilbar — nur sauberer waiting-Zustand + FAQ-Eintrag
- 3s-Settle ist Erfahrungswert, kein Apple-Wert — im 24h-Soak und Beta validieren, ggf. auf 5s erhöhen
- Verhalten des Process Taps bei Display-Sleep (falls HDMI Default-Device war) ungetestet — im Phase-1-Prototyp explizit prüfen

**Quellen:**
- `helper/AudioRouterNowHelper.c` Zeilen 1735–1829 (devices_changed_listener, process_hotplug_removals, hotplug_register)
- `v4-appstore/IMPLEMENTATION_PLAN.md` Zeilen 106, 148, 281, 296, 303
- [kAudioDevicePropertyDeviceIsAlive](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertydeviceisalive) · [kAudioHardwarePropertyDevices](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertydevices) · [AudioDeviceIOProc](https://developer.apple.com/documentation/coreaudio/audiodeviceioproc)
- [BackgroundMusic #94](https://github.com/kyleneideck/BackgroundMusic/issues/94) (Destroy-Fehler 560227702) · [cubeb_audiounit.cpp](https://searchfox.org/mozilla-central/source/media/libcubeb/src/cubeb_audiounit.cpp) · [JUCE juce_mac_CoreAudio.cpp](https://codesearch.isocpp.org/actcd19/main/j/juce/juce_5.4.1+really5.4.1~repack-2/modules/juce_audio_devices/native/juce_mac_CoreAudio.cpp)
- Apple Discussions [3466260](https://discussions.apple.com/thread/3466260), [8549367](https://discussions.apple.com/thread/8549367) · [MacRumors HDMI/DP-Audio-Fix-Thread](https://forums.macrumors.com/threads/hdmi-displayport-audio-fix.2147525/)
