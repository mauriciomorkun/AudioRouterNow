# Investigation: CASE-007 + CASE-008

> Durchgefuehrt: 2026-10-05, zwei unabhaengige KI-Investigationen (Fable und Claude Opus)
> parallel, ohne gegenseitige Kenntnisnahme der Ergebnisse.
> Beide Cases wurden am 2026-10-05 durch den User im laufenden Betrieb entdeckt.

---

## Untersuchte Dateien

| Datei | Gelesen von |
|---|---|
| `v4/AudioRouterKit/Sources/AudioRouterKit/FanOutEngine.swift` (1583 Zeilen) | Fable (vollstaendig), Opus (vollstaendig) |
| `v4/AudioRouterKit/Sources/AudioRouterKit/VolumeTracker.swift` | Fable, Opus |
| `v4/AudioRouterKit/Sources/AudioRouterKit/DeviceLifecycleManager.swift` | Fable, Opus |
| `v4/AudioRouterNow4/EngineController.swift` | Fable, Opus |
| `v4/AudioRouterKit/Sources/AudioRouterKit/OutputConfig.swift` | Fable |
| `docs/v4.0.1/06-volume-report.md` | Opus |
| `feedback/CASE-004_macrumors_doppelte-lautstaerke.md` | Opus |

---

## Architektur-Grundlage (beide Modelle bestaetigt)

Zwei Fakten sind fuer beide Cases zentral und wurden von Fable und Opus
unabhaengig bestaetigt:

**Fakt 1: Der Default-Output wird immer als Schreib-Slot angehaengt**

`FanOutEngine.swift:428-439` fuegt `defaultOutputUID` bedingungslos als Slot
ein, unabhaengig von der User-Auswahl. Der Header-Kommentar (`FanOutEngine.swift:
13-17`) beschreibt dieses Design explizit.

**Fakt 2: `.mutedWhenTapped` mutet den nativen Signalweg**

`FanOutEngine.swift:359-361` setzt `muteBehavior = .mutedWhenTapped`. CoreAudio
unterbricht den nativen Signalweg vom Source-Prozess zum Default-Output.
ARNs eigener IOProc schreibt den Stream aktiv zurueck in alle Slots.
Das Audio aus den Lautsprechern stammt aus diesem aktiven Zurueckschreiben,
nicht aus einem durchrutschenden Original-Stream.

---

## CASE-007: Lautstaerke-Sprung beim Kopfhoerer-Anschluss

### Befund (Konsens beider Modelle)

**Kernursache:** `VolumeTracker` und `DeviceLifecycleManager` reagieren auf
den Default-Device-Wechsel (Kopfhoerer einstecken) mit unterschiedlicher
Verzoegerung. Das Settle-Fenster zwischen beiden ist die Fehlerquelle.

| Mechanismus | Verzoegerung | Zeile |
|---|---|---|
| `VolumeTracker.onDefaultDeviceChanged()` aktualisiert `volumeScale` | sofort (~1 ms) | `VolumeTracker.swift:75-89` |
| `DeviceLifecycleManager.scheduleRestart()` loest Engine-Rebuild aus | ~2 s (btSettleDelay) | `DeviceLifecycleManager.swift:249-251` |
| IOProc-Rebuild, `slotAppliesVol` neu berechnet | nach Rebuild | `FanOutEngine.swift:505-514` |

**Ablauf bei Kopfhoerer-Anschluss:**

1. macOS wechselt System-Default auf Kopfhoerer.
2. `VolumeTracker` liest sofort den gespeicherten `kAudioDevicePropertyVolumeScalar`
   der Kopfhoerer (oft hoeher als Lautsprecher-Pegel).
3. IOProc wendet `vol` (neuer, hoeherer Wert) jede ~10 ms auf alle Slots an,
   waehrend `slotAppliesVol` noch fuer das alte Slot-Layout gilt.
4. Erst nach ~2 s Rebuild: `slotAppliesVol` wird neu berechnet, Fehlpaarung endet.

**Wechselwirkung mit CASE-004:**

Vor CASE-004 bekamen alle Slots `vol`, der Fehler war stationaer. Nach dem
Fix bekommt der Default-Slot Faktor 1.0 (Hardware regelt). Beim Geraetewechsel
wechselt die "wer-bekommt-1.0"-Zuordnung, im Uebergangsfenster laufen Slots
kurzzeitig mit vollem Pegel. CASE-007 ist die transiente Entsprechung von
CASE-004 beim Geraetewechsel.

### Hypothesen-Ranking (Konsens Fable/Opus)

| Rang | Hypothese | Wahrscheinlichkeit |
|---|---|---|
| 1 | Transientes Settle-Fenster: `volumeScale` neu, `slotAppliesVol` alt | ~85 % |
| 2 | Stable Output Lock Flip-Flop (verspaetete HAL-Notification) | ~40 % (Verstaerker) |
| 3 | Cold-Start-Snap beim IOProc-Rebuild (erster Callback ohne Fade-in) | ~15 % (Nebeneffekt) |

### Zusaetzlicher Befund von Opus (nicht in Fable)

`docs/v4.0.1/06-volume-report.md:88-95` behandelt den Einwand "Sprung beim
Geraetewechsel" fuer den stationaeren Zustand und weist ihn korrekt zurueck.
Das Argument gilt aber nur fuer stationaere Zustaende, nicht fuer das transiente
Settle-Fenster. Die Doku hat diese Luecke nicht abgedeckt. CASE-007 schliesst
genau diese Luecke.

---

## CASE-008: Eingebaute Lautsprecher spielen trotz exklusivem Routing

### Befund (Konsens beider Modelle, Wahrscheinlichkeit ~100 %)

**Das ist kein Bug im klassischen Sinn, sondern ein fehlendes Feature.**
"Exklusives Routing" ist im Code nie implementiert worden.

**Beweiskette:**

1. User waehlt nur externe Soundkarte: `outputConfigs` enthaelt nur externe UIDs.
2. `FanOutEngine.buildAndStartAggregate` haengt Default-Output (`defaultOutputUID`)
   bedingungslos als Schreib-Slot an (`FanOutEngine.swift:436`).
3. IOProc bespielt alle Slots aktiv, einschliesslich Lautsprecher.
4. Default-Slot hat Gain 1.0 (Fallback `?? 1.0`, `FanOutEngine.swift:196`).
5. Kein Code setzt `kAudioDevicePropertyMute` schreibend.
6. `lockOutputDevice` (Default ON) fixiert Lautsprecher als System-Default
   (`DeviceLifecycleManager.swift:237-246`). Selbst wenn macOS den Default
   wechseln will, setzt ARN ihn zurueck.

**Warum das Design so ist:** Das Tap-Modell (`mutedWhenTapped`) macht ARN zum
einzigen Schreiber. Ohne Default-Slot waere der Default-Output vollstaendig stumm.
Das war fuer alle bisherigen Use-Cases korrekt (User will immer Default + Extra).
Der Use-Case "nur externes Geraet, Default-Output stumm" wurde nicht modelliert.

### Unterschied Fable/Opus in der Analyse

Beide Modelle sind sich in der Ursache einig. Opus hat zusaetzlich den genauen
Mechanismus bestaetigt, warum das Audio NICHT aus dem Original-Stream stammt
(dieser wird durch `.mutedWhenTapped` unterdrueckt), sondern aus ARNs eigenem
Zurueckschreiben. Das ist fuer das Fix-Design relevant: der Fix liegt nicht beim
Tap-Mute-Verhalten, sondern beim Slot-Anheften und Gain-Management.

### Bekannte Einschraenkung (Audit Runde 1): Rang-4-Fallback-Master

Im Exklusiv-Modus mit ausschliesslich BT-/AirPlay-Outputs (alle Transport-Rang 4)
faellt `electMasterUID` auf `firstResolvableUserUID` zurueck. Dann wird ein
BT-/AirPlay-Geraet Clock-Master, entgegen der L1-Regel (BT/AirPlay niemals
Master). Das ist unvermeidbar, weil der Default in dieser Konfiguration kein
Sub-Device mehr ist, es also keinen Kandidaten mit Rang 0 bis 3 gibt. Die
Clock-Stabilitaet des Aggregates ist in diesem Fall schlechter als sonst
(adaptiver Buffer, keine eigene stabile Clock).

Behandlung im Code: Kommentar bei `electionFallback` plus eine Diagnose-Warnung
nach der Elektion (`L1: rank-4 device elected master via fallback, clock
stability degraded`). Reiner Log, kein Verhaltenswechsel. Ein Unit-Test
(`testElectMasterAllRankFourReturnsFallback`) pinnt den Fallback-Pfad.

### Produktentscheidung

Die Behebung beruehrt grundlegendes Verhalten und wurde noch nicht entschieden.
Optionen und Empfehlung in `feedback/CASE-008_selbstfund_lautsprecher-spielen-trotz-routing.md`,
Abschnitt 5.

---

## Vergleich der Modell-Ergebnisse

| Aspekt | Fable | Opus |
|---|---|---|
| CASE-007 Hauptursache | Transientes Settle-Fenster | Identisch |
| CASE-007 Hypothesen-Ranking | 85 % / 40 % / 15 % | Identisch |
| CASE-007 CASE-004-Wechselwirkung | Erkannt | Erkannt, tiefer ausgefuehrt mit Verweis auf `06-volume-report.md` |
| CASE-008 Ursache | Default-Slot immer angehaengt, kein Mute | Identisch |
| CASE-008 Audio-Quelle | ARN-IOProc (nicht Original-Stream) | Bestaetigt mit haerterem Beweis |
| Fix-Richtungen | Vorlaeufige Richtungen benannt | Identisch, zusaetzlich Optionen-Abwaegung |
| Produktentscheidung CASE-008 | Erwaehnt | Als explizite Anforderung hervorgehoben (CLAUDE.md-Verweis) |

**Fazit:** Beide Modelle kommen vollstaendig unabhaengig zu denselben Kernbefunden.
Die Unterstuetzung durch zwei Modelle erhoht die Konfidenz der Root-Cause-Analyse
auf ein Mass, das direkt als Grundlage fuer das Fix-Design dienen kann.

---

## Naechste Schritte

| Schritt | Wer | Status |
|---|---|---|
| Case-Dateien anlegen (CASE-007, CASE-008) | Claude | ✅ 2026-10-06 |
| Investigation in `docs/v4.0.1/09-investigation-case007-008.md` | Claude | ✅ 2026-10-06 |
| Fix-Design fuer beide Cases | Fable | In Arbeit (2026-10-06) |
| Plan-Praesentation vor Implementierung | Opus | Ausstehend |
| Produktentscheidung CASE-008 (Option A/B/C) | User | Ausstehend |
| Implementierung | nach User-Bewilligung | Ausstehend |

_Stand: 2026-10-06_
