# AudioRouterNow v4.0 — Phase 1 Prototype Results

**Stand:** [DATUM LEER LASSEN — wird beim Testen ausgefüllt]
**Tester:** Mauricio Moraïs da Cunha
**Hardware:** [ausfüllen: Mac + angeschlossene Geräte]
**macOS Version:** [ausfüllen]

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

- [ ] tccutil reset (Dev-Reset vor erstem Test):
      `tccutil reset SystemAudioCaptureRequests com.mauriciomorkun.audiorouternow`
- [ ] App starten (Development-Build mit Signing)
- [ ] Terminal offen für Logs

---

## Test-Block 1: TCC-Prompt-Flow (BLOCKEREND)

| # | Test | Ergebnis | Notizen |
|---|---|---|---|
| 1.1 | TCC-Prompt erscheint beim ersten Start (genau EINMAL) | ☐ PASS / ☐ FAIL | |
| 1.2 | Prompt-Text korrekt: "AudioRouterNow" + Routing-Beschreibung sichtbar | ☐ PASS / ☐ FAIL | |
| 1.3 | Nach Ablehnung: App zeigt Fehlermeldung mit Deep-Link in Systemeinstellungen | ☐ PASS / ☐ FAIL | |
| 1.4 | Deep-Link öffnet korrekt: Einstellungen > Datenschutz > Systemton-Aufnahme | ☐ PASS / ☐ FAIL | |
| 1.5 | Nach Berechtigung erteilen: Audio-Routing aktiv (kein Re-Start nötig) | ☐ PASS / ☐ FAIL | |
| 1.6 | TCC-Permission wird persistiert (App-Neustart → kein zweiter Prompt) | ☐ PASS / ☐ FAIL | |

---

## Test-Block 2: Apple Music Routing (KERN-GO/NO-GO)

| # | Test | Ergebnis | Notizen |
|---|---|---|---|
| 2.1 | Apple Music Streaming: Audio hörbar auf Routing-Ziel | ☐ PASS / ☐ FAIL / ☐ N/A | |
| 2.2 | Apple Music Downloads (offline): Audio hörbar auf Routing-Ziel | ☐ PASS / ☐ FAIL / ☐ N/A | |
| 2.3 | Apple Music Lossless (192kHz): Audio hörbar (SR-Anpassung korrekt oder Fehler?) | ☐ PASS / ☐ FAIL / ☐ N/A | |
| 2.4 | Apple TV+: Stille erwartet (DRM) — dokumentieren ob Stille oder Audio | ☐ Stille (erwartet) / ☐ Audio | |
| 2.5 | Kein Selbst-Aufnahme-Loop: kein Echo durch eigene Outputs | ☐ PASS / ☐ FAIL | |

---

## Test-Block 3: Output-Stabilität (KERN-GO/NO-GO)

Mindestens 3 gleichzeitige Outputs testen:

| # | Test | Ergebnis | Notizen |
|---|---|---|---|
| 3.1 | KA6 MK2 Ch1-2: Audio hörbar | ☐ PASS / ☐ FAIL / ☐ N/A | |
| 3.2 | KA6 MK2 Ch3-4: Audio hörbar gleichzeitig | ☐ PASS / ☐ FAIL / ☐ N/A | |
| 3.3 | MacBook-Speaker: Audio hörbar gleichzeitig | ☐ PASS / ☐ FAIL / ☐ N/A | |
| 3.4 | AirPods: Audio hörbar gleichzeitig | ☐ PASS / ☐ FAIL / ☐ N/A | |
| 3.5 | AirPlay-Gerät: Audio hörbar (AirPlay als IOProc-Ziel früh testen!) | ☐ PASS / ☐ FAIL / ☐ N/A | |
| 3.6 | 1h Stabilitätstest: kein Crash, kein Silence-Drop | ☐ PASS / ☐ FAIL | |
| 3.7 | Drift-Underruns vorhanden? (erwartet ohne PI-Regler — kein Bug) | ☐ Ja (erwartet) / ☐ Nein | |

---

## Test-Block 4: Sample-Rate / Format-Wechsel

| # | Test | Ergebnis | Notizen |
|---|---|---|---|
| 4.1 | SR-Wechsel des Default-Geräts während laufendem Tap: kein Crash | ☐ PASS / ☐ FAIL | |
| 4.2 | Property-Listener greift bei SR-Wechsel (Log-Eintrag vorhanden) | ☐ N/A (Phase 3) | Phase 3 — im Phase-1-Code kein Listener, N/A |
| 4.3 | coreaudiod-Restart (sudo killall coreaudiod): Recovery innerhalb 5s | ☐ PASS / ☐ FAIL | |

---

## Test-Block 5: Edge Cases (Phase 1 — nicht blockierend für Go/No-Go)

| # | Test | Ergebnis | Notizen |
|---|---|---|---|
| 5.1 | HDMI-Display-Sleep während Tap aktiv: Verhalten dokumentieren | ☐ PASS / ☐ FAIL / ☐ N/A | |
| 5.2 | BT-Gerät disconnect/reconnect während Tap: Verhalten dokumentieren | ☐ PASS / ☐ FAIL / ☐ N/A | |
| 5.3 | App-Stop → App-Start: sauberer Neustart ohne Artefakte | ☐ PASS / ☐ FAIL | |

---

## Go/No-Go Entscheid

**Kern-Kriterien (alle müssen PASS sein für Go):**
- [ ] Block 2: Apple Music Streaming + Downloads routbar
- [ ] Block 2: Apple Music Lossless (192kHz) routbar (oder SR-Fehler sauber dokumentiert)
- [ ] Block 2: Kein Selbst-Aufnahme-Loop
- [ ] Block 1: TCC-Prompt feuert korrekt, Permission wird persistiert
- [ ] Block 3: ≥3 gleichzeitige Outputs, 1h stabil (Underruns akzeptiert)
- [ ] Block 4: SR-Wechsel kein Crash

**Entscheid:** ☐ GO — Phase 2 starten | ☐ NO-GO — Architektur überdenken

**Datum:** _______________
**Begründung:** _______________

---

## Offene Punkte / Findings

[Hier während Tests ausfüllen]

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
