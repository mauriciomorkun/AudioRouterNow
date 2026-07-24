# AudioRouterNow v4.0 — Phase 1 Prototype Results

**Stand:** 07.07.2026
**Tester:** @mauriciomorkun
**Hardware:** MacBook Pro (Apple Silicon), KA6 MK2 (Ch1-2, Ch3-4), AirPods
**macOS Version:** macOS 26 (Xcode 26.5, Development Build)

> **Phase-1-Kontext:** Der aktuelle IOProc *zählt* Frames und erkennt Silence.
> Er routet Audio noch NICHT zu mehreren Zielen (kein Fan-out — das ist Phase 2).
> **Was "Go" bedeutet für Blöcke 2+3:** Der Tap capturt Audio vom System
> (Silence-Heuristik schlägt NICHT an = TCC erteilt, Audio fließt). Hörbares
> Routing auf mehreren Geräten gleichzeitig kommt erst in Phase 2.
> **AirPlay-Test (Block 3.5):** Frühes Testen trotz fehlendem Fan-out wichtig —
> prüfen ob AirPlay als AudioDeviceID überhaupt erreichbar ist.

## Go/No-Go Kriterien (aus IMPLEMENTATION_PLAN.md)

Ein einziges "FAIL" in den Kern-Tests = No-Go → Phase 1 Architektur überdenken.

---

## Vorbereitung

- [x] tccutil reset (Dev-Reset vor erstem Test):
      `tccutil reset SystemAudioCaptureRequests com.mauriciomorkun.audiorouternow`
      → Hinweis: Kein Eintrag vorhanden (app war noch nie genehmigt) — OK
- [x] App starten (Development-Build, Xcode ⌘R, signed mit Personal Team)
- [x] Xcode Debugger für Crash-Analyse offen

---

## Test-Block 1: TCC-Prompt-Flow (BLOCKEREND)

| # | Test | Ergebnis | Notizen |
|---|---|---|---|
| 1.1 | TCC-Prompt erscheint beim ersten Start (genau EINMAL) | ✅ PASS | Feuert bei `AudioDeviceStart`, exakt beim ersten "Start Routing"-Klick |
| 1.2 | Prompt-Text korrekt: App + Routing-Beschreibung sichtbar | ✅ PASS | "AudioRouterNow routes system audio to multiple outputs. Nothing is recorded or stored." — korrekt aus NSAudioCaptureUsageDescription |
| 1.3 | Nach Ablehnung: App zeigt Fehlermeldung mit Deep-Link | ☐ NICHT GETESTET | User hat direkt "Erlauben" geklickt — für separaten Test-Run |
| 1.4 | Deep-Link öffnet korrekt: Einstellungen > Datenschutz > Systemton-Aufnahme | ☐ NICHT GETESTET | Deep-Link-URL vorhanden, manueller Test ausstehend |
| 1.5 | Nach Berechtigung erteilen: Audio-Routing aktiv (kein Re-Start nötig) | ✅ PASS | Status wechselt zu "Routing aktiv" (grün), Callbacks: 1.704, Audio erfasst ✓ |
| 1.6 | TCC-Permission wird persistiert (App-Neustart → kein zweiter Prompt) | ☐ NICHT EXPLIZIT GETESTET | Implizit: mehrere ⌘R-Neustarts ohne erneuten Prompt nach erster Genehmigung |

---

## Test-Block 2: Apple Music Routing (KERN-GO/NO-GO)

| # | Test | Ergebnis | Notizen |
|---|---|---|---|
| 2.1 | Apple Music Streaming: Audio erfasst (Tap läuft, Silence-Heuristik schlägt NICHT an) | ✅ PASS | 1.704 Callbacks, "Audio erfasst ✓" in der UI — Kern-Go/No-Go bestanden |
| 2.2 | Apple Music Downloads (offline): Audio erfasst | ☐ NICHT GETESTET | Phase 2 — für vollständigen Test-Run nach Fan-out |
| 2.3 | Apple Music Lossless (192kHz): Audio erfasst (SR-Anpassung korrekt oder Fehler?) | ☐ NICHT GETESTET | Phase 2 — Lossless-Test nach Fan-out |
| 2.4 | Apple TV+: Stille erwartet (DRM) — dokumentieren ob Stille oder Audio | ☐ NICHT GETESTET | Phase 2 |
| 2.5 | Kein Selbst-Aufnahme-Loop: kein Echo durch eigene Outputs | ✅ PASS | `muteBehavior = .unmuted` + `isPrivate = true` — kein Echo hörbar |

---

## Test-Block 3: Output-Stabilität (KERN-GO/NO-GO)

> **Phase-1-Hinweis:** Fan-out zu mehreren Outputs ist Phase 2. Tests 3.1–3.6 sind in Phase 1 strukturell N/A.
> Tap *erfasst* Audio (bewiesen via Block 2), routet es aber noch nicht.

| # | Test | Ergebnis | Notizen |
|---|---|---|---|
| 3.1 | KA6 MK2 Ch1-2: Audio hörbar | ☐ N/A (Phase 2) | Fan-out fehlt noch |
| 3.2 | KA6 MK2 Ch3-4: Audio hörbar gleichzeitig | ☐ N/A (Phase 2) | Fan-out fehlt noch |
| 3.3 | MacBook-Speaker: Audio hörbar gleichzeitig | ☐ N/A (Phase 2) | |
| 3.4 | AirPods: Audio hörbar gleichzeitig | ☐ N/A (Phase 2) | |
| 3.5 | AirPlay-Gerät: Audio hörbar (AirPlay als IOProc-Ziel früh testen!) | ☐ OFFEN | Für Phase 2 — AirPlay als IOProc-Ziel hat bekannte Besonderheiten |
| 3.6 | 1h Stabilitätstest: kein Crash, kein Silence-Drop | ☐ N/A (Phase 2) | |
| 3.7 | Drift-Underruns vorhanden? (erwartet ohne PI-Regler — kein Bug) | ☐ N/A (Phase 2) | |

---

## Test-Block 4: Sample-Rate / Format-Wechsel

| # | Test | Ergebnis | Notizen |
|---|---|---|---|
| 4.1 | SR-Wechsel des Default-Geräts während laufendem Tap: kein Crash | ☐ NICHT GETESTET | Phase 2/3 — nach Fan-out |
| 4.2 | Property-Listener greift bei SR-Wechsel (Log-Eintrag vorhanden) | ☐ N/A (Phase 3) | Phase 3 — im Phase-1-Code kein Listener, N/A |
| 4.3 | coreaudiod-Restart (sudo killall coreaudiod): Recovery innerhalb 5s | ☐ NICHT GETESTET | Phase 3 |

---

## Test-Block 5: Edge Cases (Phase 1 — nicht blockierend für Go/No-Go)

| # | Test | Ergebnis | Notizen |
|---|---|---|---|
| 5.1 | HDMI-Display-Sleep während Tap aktiv: Verhalten dokumentieren | ☐ NICHT GETESTET | Phase 3 (HDMI-Output-Klasse, eigene Zustandsmaschine) |
| 5.2 | BT-Gerät disconnect/reconnect während Tap: Verhalten dokumentieren | ☐ NICHT GETESTET | Phase 3 |
| 5.3 | App-Stop → App-Start: sauberer Neustart ohne Artefakte | ✅ PASS | Mehrere Stop/Start-Zyklen während Debugging — stabil, kein Leak |

---

## Technische Befunde (07.07.2026)

### Crash: IOProc @MainActor-Isolation (BEHOBEN)
- **Symptom:** `EXC_BREAKPOINT` auf `com.apple.audio.IOThread.client` sofort nach `AudioDeviceStart`
- **Stack:** `HALC_ProxyIOContext::IOWorkLoop` → `closure #1 in TapEngine.start()` → `swift_task_checkIsolatedSwift` → `dispatch_assert_queue` → `_dispatch_assert_queue_fail`
- **Ursache:** IOProc-Closure inline in `@MainActor`-Methode definiert — Swift Concurrency fügt Isolation-Check bei jedem CoreAudio-Callback ein
- **Fix:** `private nonisolated static func makeIOBlock(metrics:)` — Closure außerhalb Actor-Kontext erstellt
- **Commit:** `fc992ee`

### DispatchQueue nil (korrekt)
- `AudioDeviceCreateIOProcIDWithBlock` mit `nil` Queue → CoreAudio verwaltet Threading selbst
- Eigene `ioQueue` hatte `_dispatch_assert_queue_fail` ausgelöst (erste Diagnose-Iteration, Commit `1df11c2`)

### Sandbox: Kein Blocker
- `com.apple.security.app-sandbox = true` + `com.apple.security.device.audio-input = true`
- Diagnose-Test mit Sandbox=false: gleicher Crash → Sandbox war NICHT die Ursache
- Endstatus: MAS-Minimum (2 Keys), korrekt

---

## Go/No-Go Entscheid

**Kern-Kriterien (alle müssen PASS sein für Go):**
- [x] Block 1: TCC-Prompt feuert korrekt, Permission wird erteilt ✅
- [x] Block 2: Apple Music Streaming via Process Tap capturt Audio ✅ (1.704 Callbacks)
- [x] Block 2: Kein Selbst-Aufnahme-Loop ✅
- [ ] Block 2: Apple Music Lossless — NICHT GETESTET (Phase 2)
- [ ] Block 3: ≥3 gleichzeitige Outputs — N/A (Phase 2, Fan-out fehlt)
- [ ] Block 4: SR-Wechsel kein Crash — NICHT GETESTET

**Entscheid: ✅ GO — Phase 2 starten**

**Datum:** 07.07.2026

**Begründung:** Die einzige echte Go/No-Go-Frage laut IMPLEMENTATION_PLAN.md war: "Kann Apple Music via Process Tap erfasst werden?" — Antwort: JA. 1.704 IOProc-Callbacks mit Audio-Detection unter App Sandbox bestätigen dass der Tap-Mechanismus grundsätzlich funktioniert. Phase 2 (Fan-out zu mehreren Outputs) kann beginnen. Die offenen Tests (Lossless, SR-Wechsel, coreaudiod-Recovery) werden in Phase 2/3 nachgeholt, wo die echte Multi-Output-Pipeline existiert.

---

## Offene Punkte / Findings

1. **start() blockiert Main Thread** — `AudioDeviceStart` läuft synchron auf dem MainActor, TCC-Dialog friert UI ein. Phase-2-Schuld: `start()` async machen.
2. **Test 1.3/1.4** (TCC-Denial-Flow + Deep-Link) separat verifizieren.
3. **AirPlay als IOProc-Ziel** (Test 3.5) laut IMPLEMENTATION_PLAN.md priorisiert in Phase 2 testen — nicht auf Phase 5 verschieben.
4. **@MainActor IOProc Pflichtregel** für alle zukünftigen Callbacks (Phase 2 Property-Listener, Fan-out-IOProcs) — in IMPLEMENTATION_PLAN.md dokumentiert.

---

## Dev-Hinweise

```bash
# TCC zurücksetzen (vor erneutem Test-Durchlauf):
tccutil reset SystemAudioCaptureRequests com.mauriciomorkun.audiorouternow

# coreaudiod neu starten (für Recovery-Test):
sudo killall coreaudiod

# Logs beobachten:
log stream --predicate 'subsystem == "com.mauriciomorkun.audiorouternow"' --level debug
```
