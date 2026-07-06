# AudioRouterNow v4.0 — Implementierungsplan (Synthese)

**Stand:** 2026-07-06 | **Methode:** Dual-Agent (Fable) + Synthese + Audit | **Status:** Planung

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
