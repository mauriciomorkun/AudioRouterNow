# BRAINSTORM-001 — Fix-Planung AudioRouterNow

> Basis: [CASE-001](./CASE-001_macrumors_routing-not-working.md) (inkl. §12 Revision 2026-06-25)
> Zweck: Erschöpfendes Brainstorming als Grundlage für den Fix-Plan. **Kein** finaler
> Plan — bewusst mehr Alternativen als nötig. Code-Belege gegen die Quelldateien
> verifiziert (Stand 2026-06-25).
> Modell: Opus. App-Version: v3.4.0, macOS 15+, ARM64 (+ Intel via Source-Build).

---

## 0. Leitende Erkenntnis aus dem Code-Studium

Der wichtigste Befund vorweg, weil er fast alle Fixes vereinfacht:

**Der Helper liefert bereits den vollständigen Live-Wahrheitszustand — die App ignoriert
ihn nur für die Anzeige.**

`get_status` ([`AudioRouterNowHelper.c:2372-2411`](../helper/AudioRouterNowHelper.c)) gibt
zurück:

```jsonc
{
  "ok": true,
  "active": [ {"uid","name","ch_offset","src_ratio","fill_ewma","underruns","stalled","recovery_count"}, ... ],
  "ring_frames": <uint>,        // Producer liefert Audio?
  "ioproc_calls": <uint>,       // Fan-out feuert? (monoton steigend)
  "reconnect_count": <uint>,
  "ioproc_age_ms": <uint>,      // wann feuerte zuletzt ein IOProc?
  "safe_take": 0|1,
  "ready": true,
  "version": "..."
}
```

Ein Eintrag in `active[]` entsteht **ausschließlich** wenn `output_add()` erfolgreich war:
`AudioDeviceCreateIOProcID` **und** `AudioDeviceStart` haben `noErr` zurückgegeben und der
Slot wurde unter Lock auf `active=true` committet
([`AudioRouterNowHelper.c:1397-1410`](../helper/AudioRouterNowHelper.c)). Damit ist
`active[]` der **stärkste mögliche Beweis**, dass ein IOProc auf einem echten physischen
Gerät läuft — genau das Signal, das CASE-001 §12.4 als "fehlend" markiert hat. Es fehlt
nicht; es wird nur nicht für die Status-Zeile gelesen.

Die App pollt diesen Status bereits alle 200 ms in `self._status_cache`
([`menu_bar_app.py:849-887`](../engine/menu_bar_app.py)). Der Status-String bei
[`menu_bar_app.py:998`](../engine/menu_bar_app.py) liest jedoch
`sorted(self._active_device_names)` — die **gespeicherte Auswahl**. **Das ist der ganze
H2-Bug.** Die Datenleitung existiert, sie ist nur am falschen Ende angeschlossen.

Konsequenz für die Priorisierung: H2 und H5 sind **derselbe Fix-Cluster** (Status +
Reconcile + Stale-Config-Sichtbarkeit), low-risk, und liefern den größten Vertrauensgewinn.

---

## 1. P0-Bugs aus CASE-001 §5/§6/§12

### H2 — Status-UI „lügt" (P0)

#### Soll-Verhalten: Was müsste der Status-String korrekt sein?

Der Status muss eine **Funktion des verifizierten Live-Zustands** sein, nicht der
gespeicherten Auswahl. Eingangssignale, alle bereits verfügbar:

| Signal | Quelle | Bedeutung |
|--------|--------|-----------|
| `helper_alive` | `_cached_status() is not None` | Helper-Prozess antwortet |
| `router_is_default` | `is_audio_router_default()` (gecacht, [:892](../engine/menu_bar_app.py)) | System-Default == "Audio Router" |
| `active[]` | `status['active']` | **real laufende** Fan-out-IOProcs |
| `ring_frames` | `status['ring_frames']` | Producer schreibt Audio in den Ring |
| `ioproc_calls` Δ | `status['ioproc_calls']` über Zeit | Fan-out feuert tatsächlich |
| `selected` | `self._active_device_names` | gewünschte Auswahl (nur für „teilweise"-Vergleich) |

#### Zustandsmatrix (Vorschlag für den Status-Text)

| Bedingung | Anzeige | Icon | Klick-Aktion |
|-----------|---------|------|--------------|
| Helper tot | „Helper not responding — click to restart" | 🔴 | restart_helper |
| Helper ok, keine Auswahl | „No output selected — pick a device below" | 🔴 | — |
| Auswahl da, Router ≠ Default | „System audio not routed here — click to fix" | 🟡 | switch_audio |
| Router = Default, `active[]` leer | „No output is receiving audio — check your devices" | 🟡 | open background-info |
| `active[]` < selected (teilweise) | „Routing to N of M — ‚X' unavailable" | 🟡 | — |
| `active[]` == selected, `ring_frames`==0 | „Ready — play something to start" | 🟢/🟡 | — |
| `active[]` == selected, Audio fließt | „Routing active — <names from active[]>" | 🟢 | — |

Kernregel: Die in der Zeile genannten Geräte-Namen kommen **aus `active[]`**, nie aus
`_active_device_names`.

#### Lösungsansätze

**Ansatz A — Minimal-invasiv: `_compute_status` umverdrahten** *(empfohlen)*
- `_compute_status` ([:949-1019](../engine/menu_bar_app.py)) liest zusätzlich
  `status['active']` und leitet `n_active`, die Namensliste und „teilweise"-Zustand daraus
  ab. `self._active_device_names` wird nur noch für den Soll/Ist-Vergleich (M vs. N)
  herangezogen.
- Vorteil: ein Funktionskörper, keine neuen Threads, nutzt vorhandenen Cache.
- Nachteil: `_compute_status` wird länger; saubere Trennung „berechne Zustand" /
  „rendere Text" empfehlenswert (Refactor in ein `RoutingState`-Dataclass).
- Aufwand: **S–M** · Risiko: **niedrig** · Impact: **sehr hoch**

**Ansatz B — `RoutingState`-Wahrheitsobjekt einführen**
- Eine kleine Dataclass `RoutingState(helper_alive, router_default, active_outputs,
  selected, ring_frames, ioproc_progress, health_level)` wird vom health-poll-Thread
  befüllt; `_compute_status` rendert nur noch.
- Vorteil: testbar (Unit-Tests ohne CoreAudio), klare Verantwortung, künftige Status-
  Konsumenten (Diagnostic, background-info, Onboarding) teilen dieselbe Quelle.
- Nachteil: mehr Code, leichte Migration.
- Aufwand: **M** · Risiko: **niedrig** · Impact: **sehr hoch** (zahlt auf Diagnostic +
  Onboarding mit ein)

**Ansatz C — `ioproc_calls`-Fortschritt statt nur `ring_frames`**
- „Audio fließt" sollte nicht an `ring_frames > 0` allein hängen (das ist Producer-
  seitig), sondern an einem **steigenden** `ioproc_calls` zwischen zwei Polls (Fan-out
  feuert wirklich). `ring_frames` kann kurz 0 sein, obwohl alles läuft (Consumer hat
  gerade geleert).
- Empfehlung: kombiniere — „active": (`active[]` nicht leer) UND (`ioproc_calls` stieg ODER
  `ring_frames > 0`). Hysterese gegen Flackern (z.B. erst nach 2 stabilen Polls „grün").
- Aufwand: **S** · Risiko: **niedrig** · Impact: **hoch**

#### Refresh-Strategie: Polling vs. Notification?

- **Status-Daten:** bereits Polling (200 ms health-poll-Thread → Cache). Beibehalten.
  CoreAudio-`get_status` ist Socket-IPC; 200 ms ist ein guter Kompromiss (CPU vernachläs-
  sigbar, gefühlt sofort). Kein Wechsel nötig.
- **`router_is_default`:** aktuell Poll im health-Thread ([:892](../engine/menu_bar_app.py)).
  **Verbesserung:** zusätzlich CoreAudio-Property-Listener auf
  `kAudioHardwarePropertyDefaultOutputDevice` registrieren (analog zum bestehenden
  Volume-Listener, [`audio_device_control.py:720`](../engine/audio_device_control.py)) →
  reagiert sofort wenn der User extern umstellt. Poll als Fallback behalten.
- **UI-Render:** `_update_status_ui` ([:1195](../engine/menu_bar_app.py)) läuft auf dem
  0.5 s UI-Timer mit Flacker-Schutz (`_last_status_cache`). Beibehalten.
- Welcher Thread? Lesen im health-poll-Thread (200 ms), **Rendern nur auf dem Main-Thread**
  (rumps/AppKit). Das ist bereits die Architektur — nicht brechen.

#### Edge Cases

| Fall | Soll-Verhalten |
|------|----------------|
| Kein Gerät verfügbar (`active[]` leer, Auswahl leer) | „No output selected" |
| Helper-Crash mitten im Routing | `_cached_status()` wird `None` → „Helper not responding"; Auto-Respawn ([:777-785](../engine/menu_bar_app.py)) läuft bereits |
| Ring voll, aber kein Consumer | `active[]` leer + `ring_frames` hoch → „No output is receiving audio" (nicht „active") |
| `active[]` teilweise (1 von 3) | „Routing to 1 of 3 — ‚X', ‚Y' unavailable" |
| `truncated:true` im Status | Anzeige „N+ devices" statt exakter Liste; loggen |
| Gerät verschwindet während Wiedergabe | Healer tombstoned → `active[]` schrumpft → Status folgt automatisch |
| `ioproc_age_ms` hoch trotz `active[]` | „Routing stalled — reconnecting" (🟡); Healer greift |

---

### H5 — Stale Config (primärer Kandidat für „kein Routing", P0)

#### Problemkern (verifiziert)

`_apply_active_outputs` ([:1227-1231](../engine/menu_bar_app.py)) mappt gespeicherte
Namen → UIDs über den **aktuellen** Scan und **überspringt still** (`logger.debug`) jedes
Gerät, das nicht (mehr) da ist. Helper-seitig liefert `output_add` `-1` bei „Device nicht
gefunden" ([`AudioRouterNowHelper.c:1233-1235`](../helper/AudioRouterNowHelper.c)). Ergebnis:
Auswahl „3 devices" schrumpft real auf 0–1 — der User sieht trotzdem „3 devices" (H2).
Das `_reconcile_active_outputs` ([:1269](../engine/menu_bar_app.py)) korrigiert den internen
Zustand, aber erst nach **3 Drift-Polls** und ohne den User zu informieren **warum**.

#### Erkennung beim Start: Gespeicherte UIDs nicht mehr gültig?

`_restore_saved_outputs` ([:1411](../engine/menu_bar_app.py)) ruft bereits
`get_devices_by_names` und reduziert auf real vorhandene Geräte — die Information „welche
gespeicherten Geräte fehlen" ist also genau hier verfügbar, wird aber verworfen.

**Lösungsansätze für die Erkennung:**

**Ansatz A — Diff in `_restore_saved_outputs` berechnen und merken** *(empfohlen)*
- `missing = set(config.output_device_names) - {d.name for d in restored}` berechnen, in
  `self._unavailable_devices` ablegen.
- Status-Zeile + background-info nutzen diese Menge für die „‚X' unavailable"-Anzeige.
- Aufwand: **S** · Risiko: **niedrig** · Impact: **hoch**

**Ansatz B — Helper als Autorität (Reconcile sofort statt nach 3 Polls beim Start)**
- Die 3-Poll-Grace ([:1316](../engine/menu_bar_app.py)) ist sinnvoll gegen transiente Zustände
  *während des Betriebs*, aber **beim allerersten Auto-Start** schadet sie: der User sieht
  3 Polls lang einen falschen Zustand. Vorschlag: erste Reconcile nach `_auto_start` sofort
  anwenden (Grace nur für spätere Drifts).
- Aufwand: **S** · Risiko: **niedrig–mittel** (Grace-Logik nicht für Betriebsfall brechen)

#### Kommunikation an den User: „Gerät ‚X' nicht mehr verfügbar"

**Ansatz A — Passiv in der UI** *(empfohlen als Basis)*
- Im Geräte-Menü fehlende-aber-gespeicherte Geräte als ausgegraute Zeile
  „⚠ ‚X' — unavailable" zeigen (statt komplett zu verschwinden). Macht sichtbar, dass die
  App das Gerät kennt, es aber gerade weg ist.
- Status-Zeile: „Routing to N of M".
- `_make_device_menu_item` ([:362](../engine/menu_bar_app.py)) erweitern.

**Ansatz B — Aktive Notification beim Start**
- Einmalige rumps.notification: „‚X' is no longer available — routing continues to your
  other devices." Nur wenn beim Start tatsächlich Geräte fehlen.
- Risiko: Notification-Spam bei häufigem Umstecken → an „nur beim Start, nur wenn nicht
  schon gemeldet" koppeln.

**Ansatz C — Modaler Dialog**
- Abzulehnen: zu invasiv für einen Normalfall (Laptop ohne Dock gestartet).

#### Auto-Fallback oder User fragen?

| Strategie | Vor | Nachteil |
|-----------|-----|----------|
| **Stilles Weiterrouten an verbleibende Geräte** (Status quo + Sichtbarkeit) | Kein Unterbruch, einfach | User muss selbst merken, dass eins fehlt → durch Ansatz A/B gelöst |
| **Auto-Fallback auf Mac-Speaker wenn ALLE weg** | Nie totale Stille | „Magie" kann verwirren; ggf. ungewollt laute interne Speaker |
| **User fragen (Dialog)** | Explizit | Nervig, oft beim Login wenn Dock noch nicht da |

**Empfehlung:** Weiterrouten an Verbleibende + sichtbar machen (A). Für den Totalausfall
(siehe unten) ein **opt-in** Fallback in den Settings (Default: aus), kein automatischer.

#### Was wenn ALLE gespeicherten Geräte weg sind?

- `active[]` leer, Auswahl nicht leer, Router evtl. Default → **gefährlichster Fall**:
  System-Audio zeigt auf „Audio Router", aber nichts hört zu → **totale Stille**, der User
  denkt „App kaputt".
- Status: 🔴 „No output available — connect a device or switch back" mit Klick-Aktion
  „Restore system default" (setzt Default zurück auf ein echtes Hardware-Gerät, z.B. den
  internen Speaker).
- Optionaler opt-in Auto-Fallback (s.o.): nach X Sekunden ohne `active[]` automatisch auf
  internen Speaker zurück.
- Aufwand: **M** · Risiko: **mittel** (Default-Umschalten ist Seiteneffekt) · Impact: **hoch**

---

### H7 — Lautstärketasten entkoppelt (UX-Falle, P0/P1)

#### Problemkern (verifiziert)

Sobald „Audio Router" System-Output ist, wirken die Volume-Tasten auf das **virtuelle**
Router-Volume (`volume_q16`, Skalierung im Consumer
[`AudioRouterNowHelper.c:887`](../helper/AudioRouterNowHelper.c)). Die **Hardware-Lautstärke
des physischen Geräts** (z.B. Mac-mini-Speaker) wird **nicht** angefasst und bleibt auf
ihrem alten Wert eingefroren. Default-Gain ist voll (`volume_q16=65536`,
[`shared_ring.h:96`](../helper/shared_ring.h)). War der Speaker vorher leise → dauerhaft
leise, und die Tasten „reparieren" es nicht (sie regeln den Router, nicht das Endgerät).

#### Lösungsansätze

**Ansatz A — Hardware-Volume durchreichen (Master → alle physischen Outputs)**
- Wenn der User das Router-Volume ändert, schreibt der Helper den skalaren Volume-Wert
  zusätzlich auf jedes physische Output-Device (`kAudioDevicePropertyVolumeScalar`).
- Vorteil: Tasten „funktionieren wieder" wie erwartet (regeln, was man hört).
- Nachteil: viele Geräte unterstützen kein Scalar-Volume (Interfaces mit Hardware-Poti
  ignorieren es); bei Multi-Output ändern sich alle gleichzeitig (gewollt?). Race mit dem
  Property-Listener.
- Aufwand: **M** · Risiko: **mittel** · Impact: **hoch**

**Ansatz B — Beim Umschalten Hardware-Volume als Startwert übernehmen** *(empfohlen als Sofortmaßnahme)*
- Im Moment des `_switch_system_audio` / Auto-Switch ([:515-520](../engine/menu_bar_app.py),
  [:1399-1402](../engine/menu_bar_app.py)): die **aktuelle** Hardware-Lautstärke des
  bisherigen Default-Geräts lesen und als Router-`volume_q16` setzen **und** zusätzlich
  jedes physische Zielgerät auf „komfortabel" (z.B. ≥ vorheriger Wert) anheben, falls es
  bei ~0 stand.
- Verhindert exakt das CASE-001-Symptom (vorher leise → bleibt leise).
- Aufwand: **S–M** · Risiko: **niedrig** · Impact: **hoch**

**Ansatz C — Pro-Gerät-Lautstärke im Menü**
- Submenu pro aktivem Output mit eigenem Volume-Slider; Helper bekommt per-Output-Gain
  (neuer SHM-Slot oder Helper-State pro Slot — Driver/ABI-Änderung!).
- Vorteil: maximale Kontrolle (z.B. Speaker leiser als Interface).
- Nachteil: **ABI-Bruch** (`shared_ring.h` hat nur ein globales `volume_q16`); großer
  Aufwand; verschiebt v4.
- Aufwand: **XL** · Risiko: **hoch** · Impact: **mittel** (nice-to-have) → **Backlog v4**

**Ansatz D — Warnhinweis statt Mechanik**
- Beim ersten Umschalten ein kurzer Hinweis: „Volume keys now control the Router. If a
  device sounds quiet, check its hardware volume in System Settings."
- Billiger Stopgap, löst aber das Problem nicht — nur als Begleitung zu B.
- Aufwand: **S** · Risiko: **niedrig** · Impact: **niedrig–mittel**

**Empfehlung:** B sofort (verhindert das Symptom), A als Folge-Ausbau, C als v4-Feature,
D als Begleittext im Onboarding.

#### Belegfragen an den User (zur Bestätigung von H7, aus §12.6)

Hardware-Volume des Speakers vor/nach Umschalten? Bewegen die Tasten nach dem Umschalten
noch etwas Hörbares? Quiet auf allen Apps?

---

### Status-Verifikation: IOProcs feuern wirklich?

Bereits beantwortbar über `active[]` (Slot ist nur `active=true` wenn `AudioDeviceStart`
== `noErr`) **plus** `ioproc_calls` (global, [:2388](../helper/AudioRouterNowHelper.c)) und
per-Output `underruns`/`stalled`/`src_ratio`/`fill_ewma`
([:2315-2320](../helper/AudioRouterNowHelper.c)).

- **Polling reicht** für die Statusanzeige (200 ms).
- Für „in <5 s nach Start bestätigen, dass Audio fließt": siehe §3 Routing-Verifikationsloop.
- Eine echte „feuert IOProc?"-Verifikation = `ioproc_calls` zwischen zwei Polls gestiegen
  **oder** `ioproc_age_ms` klein. Beides vorhanden, ungenutzt für UI.

---

## 2. Sekundärbefunde (§6)

### P1 — i18n: gemischte DE/EN-Strings

#### Umfang (betroffene user-sichtbare Strings)

| Datei | Art | Beispiel |
|-------|-----|----------|
| [`audio_device_control.py:223-227`](../engine/audio_device_control.py) | **user-sichtbarer Fehler** (kritisch — die zitierte Meldung) | „‚X' nicht in CoreAudio gefunden…" |
| [`audio_device_control.py:308`](../engine/audio_device_control.py) | user-sichtbar (System-Output) | „‚X' nicht gefunden." |
| [`audio_device_control.py:180,277`](../engine/audio_device_control.py) | user-sichtbar | „Keine Audio-Devices gefunden." |
| [`first_launch.py:76-82`](../engine/first_launch.py) `_STEPS` | Installations-Progress-Fenster | „Kopiere Treiber…", „Starte Audio-Dienst neu…" |
| [`first_launch.py:164`](../engine/first_launch.py) | Fenstertitel | „AudioRouterNow — Treiber-Installation" |
| Helper `fprintf(...)` | **nur Logs** (helper.log) — nicht user-sichtbar, aber im Diagnostic Report | „Output hinzugefuegt", „Device nicht gefunden" |

Der Großteil der **harten** UI ist bereits Englisch (menu_bar_app.py-Alerts,
README). Die schmerzhaften Stellen sind `audio_device_control.py` (genau die zitierte
Fehlermeldung) und die Installations-Progress-Strings.

#### Lösungsansätze

**Ansatz A — Sofort: Strings auf Englisch vereinheitlichen (kein i18n-Framework)** *(empfohlen)*
- Alle user-sichtbaren deutschen Strings → Englisch. Helper-Logs **können deutsch bleiben**
  (intern), sollten aber für die Konsistenz im Diagnostic Report idealerweise auch
  englisch sein (zweite Tranche).
- Prioritär: `audio_device_control.py:223-227` (das ist *die* gemeldete Meldung) +
  `first_launch.py` `_STEPS`.
- Aufwand: **S** · Risiko: **niedrig** · Impact: **hoch** (Außenwirkung, Professionalität)

**Ansatz B — Echte i18n-Schicht (gettext / dict-basiert)**
- `engine/i18n.py` mit `_( )`-Wrapper, Locale-Erkennung via `NSLocale`. DE + EN als erste
  Sprachen (der Entwickler ist deutschsprachig, Zielgruppe international).
- Vorteil: zukunftssicher, App-Store-tauglich (v4), echte Lokalisierung.
- Nachteil: Overkill für jetzt; jeder String muss umgeschlossen werden; Pluralregeln.
- Aufwand: **M–L** · Risiko: **niedrig** · Impact: **mittel** (langfristig) → **v3.5/v4**

**Empfehlung:** A jetzt (Launch-Blocker für Außenwirkung), B als v4-Vorbereitung.

---

### P1 — Diagnostic.py erweitern

#### Was fehlt aktuell (verifiziert gegen [`diagnostic.py`](../engine/diagnostic.py))

`diagnostic.py` sammelt: System-Info (`mac_ver`, `hw.model`, arch), helper.err-Tail,
helper.log-Events, und **den vollen `get_status`-Dump** (inkl. `active[]`, `ring_frames`,
`ioproc_calls` — die sind also schon drin, nur nicht hervorgehoben). **Es fehlt komplett:**

| Fehlend | Befehl / API | Deckt CASE-001 |
|---------|--------------|----------------|
| Treiber-Präsenz in CoreAudio | `system_profiler SPAudioDataType` / `_find_audio_router_device_id()` | H1 |
| codesign-Status des `.driver` | `codesign -dv --verbose=4 <path>` | H1-Wurzel |
| Ist „Audio Router" der Default? | `is_audio_router_default()` (existiert!) | §12 Default-Frage |
| Default-Output-Name + Volume | `_get_default_output_device_id()` + `get_default_output_volume()` | H7 |
| coreaudiod-Reject-Logs | `log show --predicate process==coreaudiod` | H1 |
| Doppel-Install-Check | Bundle-Pfad vs. HAL-Pfad (siehe §2 letzter Punkt) | §12.5 |
| Treiber-ABI-Version | `get_installed_driver_abi_version()` (existiert!) | P10 |
| Stale-Config (Auswahl vs. active[]) | `_active_device_names` vs. `status['active']` | H5 |

#### Lösungsansätze

**Ansatz A — `diagnostic.py` um eine „SYSTEM AUDIO STATE"-Sektion erweitern** *(empfohlen)*
- Neue Funktionen `_codesign_status()`, `_driver_presence()`, `_default_output_state()`,
  `_audio_router_state()`. Read-only, alle non-blocking mit Timeout (Muster vorhanden:
  `subprocess.check_output(..., timeout=3)`).
- `system_profiler SPAudioDataType` kann langsam sein (mehrere Sekunden) → Timeout 8 s,
  läuft ohnehin im Background-Thread ([`menu_bar_app.py:642-675`](../engine/menu_bar_app.py)).
- Aufwand: **M** · Risiko: **niedrig** · Impact: **hoch** (macht genau diesen Fall sichtbar)

**Ansatz B — Strukturierte Selbst-Diagnose mit Pass/Fail-Ampel**
- Statt rohem Dump: eine Checkliste „✓ Driver loaded / ✓ Router is default / ✗ No active
  outputs (your 3 saved devices are unavailable)". Quasi ein „arn doctor".
- Vorteil: der User (und der Entwickler im Report) sieht sofort, was kaputt ist.
- Aufwand: **M–L** · Risiko: **niedrig** · Impact: **sehr hoch** → starke Empfehlung,
  baut auf dem `RoutingState`-Objekt aus H2/Ansatz B auf.

#### Wie ausführen? (1 Klick / Terminal / automatisch?)

| Variante | Beschreibung | Bewertung |
|----------|--------------|-----------|
| **Menüpunkt „Save Diagnostic Report…"** (existiert, [:135](../engine/menu_bar_app.py)) | Öffnet Mail mit Report | beibehalten, um die neuen Felder erweitern |
| **Terminal-Einzeiler** | `/Applications/AudioRouterNow.app/.../arn-doctor` oder ein dokumentierter `curl`-freier Befehl | gut für Support-Threads (Forum), copy-paste-bar |
| **Auto-Trigger bei Fehler** | Wenn Status X s lang 🔴/„no active outputs" → Banner „Run diagnostics?" | **empfohlen** als opt-in, nicht automatisch versenden (Privacy!) |

**Empfehlung:** Menüpunkt erweitern (A) + strukturierte Ampel (B) + **bei wiederholtem
Fehlerzustand** ein dezenter Hinweis „Run diagnostics" (nicht automatisch senden — die App
wirbt mit „no telemetry", README:247).

---

### P2 — Sparkle Opt-out

#### Verifiziert

`SparkleUpdater().start()` wird in `__init__` **unbedingt** aufgerufen
([`menu_bar_app.py:239-243`](../engine/menu_bar_app.py)). Kein In-App-Toggle. Feed:
`appcast.xml` (Info.plist `SUFeedURL`). README:247 verspricht „No network connections of
any kind" — das ist mit aktivem Sparkle **streng genommen widersprüchlich** (Sparkle holt
den Feed). Das ist ein **Vertrauens-/Konsistenzproblem**, nicht nur ein Feature.

#### Erste-Start-Consent-Dialog: Inhalt

> „AudioRouterNow can check for updates automatically. It contacts GitHub once to read a
> version file — no personal data, no tracking. You can change this any time in the menu.
> [Enable automatic updates] [Not now]"

#### Update-Check deaktivieren — wie?

**Ansatz A — `config.json`-Flag + Menü-Toggle** *(empfohlen)*
- `AppConfig.auto_update_check: bool` (Default: per Consent gesetzt). `__init__` startet
  Sparkle nur wenn `True`. Menüpunkt „Check for updates automatically" mit `[x]`.
- Sparkle hat zusätzlich `SUEnableAutomaticChecks` (UserDefaults) — App-Flag sollte das
  spiegeln/setzen, damit Sparkle nicht selbst pollt.
- Aufwand: **S–M** · Risiko: **niedrig** · Impact: **mittel (Privacy/Vertrauen, hoch
  für die Außenwirkung)**

**Ansatz B — Nur UserDefaults (`SUEnableAutomaticChecks=false`)**
- Sparkle-nativ, kein eigener Toggle. Manuelles „Check for Updates…" bleibt.
- Nachteil: kein sichtbarer In-App-Schalter → der gemeldete Kritikpunkt bleibt halb offen.

#### Begleitend: README:247 korrigieren

„No network connections" → präzisieren: „No telemetry or analytics. The only optional
network call is the update check (GitHub appcast), which you can disable." (sonst
unwahre Aussage — relevant für GPL/OSS-Glaubwürdigkeit).

---

### P2 — README Homebrew-Widerspruch

#### Verifiziert

[`README.md:80`](../README.md) „**Option A — Homebrew (recommended)**" vs.
[`README.md:180`](../README.md) „No kernel extension. No restart. **No Homebrew
dependencies.**" — beide Aussagen sind eigentlich *nicht* widersprüchlich (das eine ist
Installations*methode*, das andere Laufzeit-*Abhängigkeit*), aber für den Leser klingt es so.

#### Lösungsansätze

**Ansatz A — Beide Stellen entkoppeln + umformulieren** *(empfohlen)*
- Zeile 180: „No kernel extension. No restart. **No runtime dependencies on Homebrew,
  SwitchAudioSource, or any external tool.**"
- Zeile 80: „**Option A — Homebrew Cask (optional convenience)**" statt „recommended", bis
  der Tap live ist. Solange der Tap **nicht** existiert (CLAUDE.md: „Tap evtl. noch nicht
  live") → Option B (Direct download) als primäre Methode ausweisen, Homebrew als „coming
  soon" markieren oder ganz entfernen, um tote Befehle zu vermeiden.
- Aufwand: **S** · Risiko: **niedrig** · Impact: **mittel**

**Ansatz B — Homebrew-Sektion erst mit Live-Tap einblenden**
- README-Homebrew-Block auskommentieren bis `homebrew-tap` live + verifiziert (CLAUDE.md
  Schritt 5: „brew install --cask auf sauberem Mac"). Verhindert „command not found" beim
  Erstkontakt.

---

### Mittel — osascript Admin-Prompt

#### Verifiziert

[`first_launch.py:372`](../engine/first_launch.py): `do shell script "<cp + killall>" with
administrator privileges`. Der User sieht einen generischen macOS-Passwort-Dialog ohne
klare Herkunft → „wenig vertrauenswürdig". Zusätzlich problematisch:
`killall coreaudiod` (hart) statt `launchctl kickstart -k system/com.apple.audio.coreaudiod`
(sauber), und `cp -rf` statt `ditto` (Permissions/xattr-Treue).

#### Lösungsansätze

**Ansatz A — Kurzfristig: besserer Kontext + sauberere Befehle** *(empfohlen sofort)*
- Der `_show_install_dialog` ([:876](../engine/first_launch.py)) erklärt bereits *vorher*,
  warum das Passwort kommt — gut. Verbessern: Hinweis „macOS shows a generic password
  dialog; it is AudioRouterNow installing its audio driver to /Library/Audio/Plug-Ins/HAL."
- `killall coreaudiod` → `launchctl kickstart -k system/com.apple.audio.coreaudiod`
  (sauberer Neustart, kein hartes Kill).
- `cp -rf` → `ditto` (überträgt Permissions/ACLs korrekt, vermeidet Teile des §12.5-
  Handkopie-Problems auch im Installer).
- Aufwand: **S** · Risiko: **niedrig–mittel** (Install-Pfad — auf sauberem Mac testen!)

**Ansatz B — Langfristig: SMJobBless / signierter privilegierter Helper**
- Ein einmalig per SMAppService (macOS 13+) registrierter, **Developer-ID-signierter**
  Privileged Helper installiert den Treiber. Kein nackter osascript-Shell-Prompt mehr;
  macOS zeigt einen vertrauenswürdigen System-Dialog.
- Vorteil: maximale Vertrauenswürdigkeit, App-Store-näher, kein Shell-Injection-Risiko.
- Nachteil: erheblicher Aufwand (eigenes Helper-Target, Code-Signing-Kette, Lifecycle),
  Wartung, Notarisierung.
- Kosten-Nutzen: **SMJobBless lohnt sich erst, wenn (a) die Install-Base wächst UND (b) der
  v4-Swift-Rewrite ohnehin ansteht.** Für v3.4.0 ist Ansatz A das richtige Maß.
- Aufwand: **XL** · Risiko: **hoch** · Impact: **mittel** → **v4-Kandidat**

**Wann SMJobBless angehen?** Trigger: erste echte Trust-Beschwerden in Reviews/Issues
*oder* App-Store-Vorbereitung (v4). Bis dahin A.

---

### Sonderfall — Manuelles Kopieren des Treibers abraten (§12.5)

#### Wo in der Doku warnen?

- **README** „What gets installed" ([:97-108](../README.md)): expliziter Hinweis-Block:
  „⚠️ Do **not** copy AudioRouterNow.driver manually into /Library/Audio/Plug-Ins/HAL.
  The app installs and signs it correctly; a manual Finder copy adds a quarantine flag and
  wrong permissions, and Core Audio will refuse to load it."
- **Troubleshooting**-Sektion ([:122](../README.md)): „If you previously copied the driver
  by hand, run Uninstall, then relaunch the app to reinstall cleanly."

#### Soll die App das erkennen und warnen? (Doppel-Install-Check)

**Ansatz A — Quarantäne-/Signatur-Check des installierten Treibers** *(empfohlen)*
- Beim Start prüfen: hat der installierte `.driver` ein `com.apple.quarantine`-xattr
  (`xattr -p com.apple.quarantine <path>`) **oder** scheitert `codesign --verify`? → Banner
  „Your driver install looks broken (manual copy?). Click to reinstall cleanly."
- Nutzt vorhandene Infrastruktur (`install_driver`, ABI-Reinstall-Pfad [:1034](../engine/menu_bar_app.py)).
- Aufwand: **M** · Risiko: **niedrig** · Impact: **mittel** (deckt genau den §12.5-Fall)

**Ansatz B — Doppel-Install-Erkennung**
- Prüfen, ob sowohl der Bundle-interne Treiber als auch eine *abweichende* HAL-Kopie
  existieren (mtime/Hash-Vergleich). Bei Divergenz warnen.
- Aufwand: **M** · Risiko: **niedrig** · Impact: **niedrig–mittel** (seltener Fall)

---

## 3. Architektur-Verbesserungen aus dem Case

### 3.1 Routing-Verifikationsloop (Bestätigung in < 5 s)

**Ziel:** Nach `_auto_start_if_configured` ([:1355](../engine/menu_bar_app.py)) /
`_switch_system_audio` innerhalb von 5 s belastbar sagen: „Audio fließt" oder „etwas stimmt
nicht".

**Ansatz A — Aktiver Verify-Tick nach Start** *(empfohlen)*
- Nach Auto-Start einen kurzen Verifikations-Timer (z.B. 5×1 s) starten, der prüft:
  `router_is_default` ∧ `active[]` == erwartete Auswahl ∧ (`ioproc_calls` steigt ∨ Pre-Roll
  läuft). Bei Erfolg: nichts (Status zeigt grün). Bei Misserfolg nach 5 s: konkreter
  Status/Notification mit Grund (kein Default / keine active outputs / Producer liefert
  nichts).
- Nutzt nur vorhandene Signale. Kein Audio-Inject nötig.
- Aufwand: **M** · Risiko: **niedrig** · Impact: **hoch**

**Ansatz B — Aktiver Test-Ton**
- Helper spielt kurz (z.B. 200 ms) einen leisen Test-Ton/Klick in den Ring, App verifiziert
  `ioproc_calls`-Anstieg. „Self-test"-Menüpunkt.
- Vorteil: beweist die *gesamte* Kette inkl. hörbarer Ausgabe.
- Nachteil: hörbar (nervig), neuer Helper-Command, Timing.
- Aufwand: **L** · Risiko: **mittel** · Impact: **mittel** → optionaler „Test output"-Button

### 3.2 Self-Healing bei Helper-Crash

**Bereits vorhanden:** Auto-Respawn ([`menu_bar_app.py:777-785`](../engine/menu_bar_app.py)),
Healer + Circuit-Breaker ([:216-220](../engine/menu_bar_app.py), `healer.py`),
coreaudiod-Spin-Watchdog ([:1069](../engine/menu_bar_app.py)).

**Lücken / Verbesserungen:**
- **Respawn-Backoff:** aktueller Respawn ist einmalig pro Tot→Lebendig-Übergang. Ein
  Crash-Loop (Helper stirbt sofort wieder) → Status sollte das nach N Versuchen als 🔴
  „Helper keeps crashing — see diagnostics" zeigen statt still weiter zu respawnen.
  Aufwand: **S** · Risiko: niedrig.
- **Auto-Restart vs. User-Notification:** Auto-Restart beibehalten (UX!), aber bei
  wiederholtem Scheitern eskalieren (Notification + Status). Keine stillen Endlosschleifen.

### 3.3 Diagnostic-Mode: 1 Befehl/Menüpunkt, der ALLES findet

Konsolidierter „arn doctor" (siehe §2 Diagnostic Ansatz B), der ausgibt:
driver presence, codesign + quarantine, ABI, is_default, default-output + volume, helper
alive + version, `active[]` vs. selected (stale config), `ring_frames`/`ioproc_calls`,
reconnect/stall counts, coreaudiod-Reject-Logs, Doppel-Install-Check. Als Menüpunkt **und**
als dokumentierter Terminal-Befehl (copy-paste in Foren). Privacy: nur lokal speichern,
nur auf User-Aktion senden.

### 3.4 Onboarding-Flow: in 30 s sehen, ob's läuft

**Bereits vorhanden:** First-Run-Wizard ([`menu_bar_app.py:279-282`](../engine/menu_bar_app.py)).

**Verbesserungen:**
- Wizard-Abschluss mit einem **Live-Status-Schritt**: „Pick an output → play any sound →
  the indicator turns green." (nutzt H2-Fix + Verify-Loop).
- Der menü-Status muss nach dem H2-Fix selbsterklärend sein (Ampel + Klartext + Klick-
  Aktion). Das ist der eigentliche „30-Sekunden-Check".
- Sparkle-Consent (§2) in den Wizard integrieren.
- Volume-Hinweis aus H7/Ansatz D in den Wizard.

---

## 4. Fix-Priorisierungs-Framework

Bewertung: **Aufwand** (S/M/L/XL) × **Risiko** (niedrig/mittel/hoch) × **User-Impact**.
Risiko bezieht sich v.a. auf Audio-Pfad-/Install-/Signing-Regressionen.

| # | Fix | Aufwand | Risiko | Impact | Hypothese |
|---|-----|---------|--------|--------|-----------|
| 1 | **H2** Status spiegelt `active[]`/`ioproc_calls`/`router_default` statt Auswahl | S–M | niedrig | **sehr hoch** | H2 |
| 2 | **H5** Stale-Config sichtbar machen (missing devices, „N of M", Reconcile beim Start sofort) | S–M | niedrig–mittel | **hoch** | H5 |
| 3 | **H5** Totalausfall-Handling (alle Geräte weg → 🔴 + „restore default") | M | mittel | hoch | H5 |
| 4 | **i18n** user-sichtbare DE-Strings → EN (`audio_device_control.py`, `first_launch._STEPS`) | S | niedrig | hoch | P1 |
| 5 | **Diagnostic** „arn doctor": driver presence + codesign + quarantine + is_default + active vs selected | M | niedrig | hoch | P1/§12 |
| 6 | **H7** Hardware-Volume beim Umschalten übernehmen + Onboarding-Hinweis | S–M | niedrig | hoch | H7 |
| 7 | **README** Homebrew entkoppeln/umformulieren; „No network" präzisieren | S | niedrig | mittel | P2 |
| 8 | **Sparkle** Consent + Opt-out-Toggle (`config.auto_update_check`) | S–M | niedrig | mittel | P2 |
| 9 | **Install** `ditto` statt `cp`, `launchctl kickstart` statt `killall`, besserer Prompt-Kontext | S | niedrig–mittel | mittel | §6/§12.5 |
| 10 | **Doku+App** Handkopie abraten + Quarantäne/codesign-Selbstcheck | M | niedrig | mittel | §12.5 |
| 11 | **Verify-Loop** Routing-Bestätigung < 5 s nach Start | M | niedrig | hoch | H2/H5 |
| 12 | **Self-Healing** Respawn-Backoff + Crash-Loop-Eskalation | S | niedrig | mittel | §3.2 |
| 13 | **H7** Per-Output-Volume (ABI-Änderung) | XL | hoch | mittel | H7 → v4 |
| 14 | **SMJobBless** privilegierter signierter Installer | XL | hoch | mittel | §6 → v4 |
| 15 | **i18n** echtes Framework (gettext/NSLocale) | M–L | niedrig | mittel | P1 → v4 |

---

## 5. Empfohlene Fix-Reihenfolge (Roadmap-Entwurf)

### Welle 1 — „Die App sagt die Wahrheit" (v3.4.1, Bugfix-Release) — ✅ ABGESCHLOSSEN (2026-06-25)
**Ziel:** Der gemeldete Kern (Status lügt, Routing tut scheinbar nichts) ist behoben.
Geringes Risiko, kein Audio-Pfad-Eingriff, keine Signing-Änderung.
Dual-auditiert (2 Iterationen), alle Befunde behoben, 4 Commits.

1. ✅ **ERLEDIGT — #1 H2** — Status-Cluster: `_compute_status` liest realen Zustand aus
   `status['active']` (7-Zustands-Matrix), nicht mehr `_active_device_names`. Commit `7521f0b`.
2. ✅ **ERLEDIGT — #2 H5** — Stale-Config sichtbar: `_unavailable_devices`-Set, fehlende
   Geräte als „⚠ unavailable" im Menü, Status-Counter „N of M", Hot-Plug-Recompute,
   Reconcile-Hardening. Commit `7521f0b`.
3. ✅ **ERLEDIGT — #4 i18n** — user-sichtbare deutsche Strings → Englisch
   (`audio_device_control.py`, `first_launch.py`, `diagnostic.py`). Commit `a7265bd`.
4. ✅ **ERLEDIGT — #7 README** — Homebrew „recommended" → „optional",
   Runtime-Dependency-Klarstellung. Commit `7115a60`.
5. ✅ **ERLEDIGT (vorgezogen aus Welle 2) — #5 Diagnostic Fan-out** — neue Sektionen
   SYSTEM AUDIO STATE + FAN-OUT im Diagnostic-Report. Commit `68ec5ec`.

→ **Validator-Prüfung Welle 1:** siehe §6.

#### Audit-Erkenntnisse (Dual-Audit, 2 Iterationen)

Die zwei unabhängigen Opus-Audit-Durchläufe haben drei Befunde aufgedeckt, die vor
Release behoben wurden:

- **Import-Pfad-Bug:** Ein Import im neuen Status-/Diagnose-Pfad zeigte auf den falschen
  Modulpfad → bei isoliertem Aufruf `ImportError`. Korrigiert.
- **Reconcile-Inkonsistenz:** `_reconcile_active_outputs` konnte gespeicherte Namen auf
  Geräte anwenden, die nicht im aktuellen Scan waren → reconciled Set jetzt auf
  `new_names & scanned` eingeschränkt (keine stale UIDs mehr).
- **max_age-Drift:** Der Status-Cache-`max_age` driftete gegen das Health-Poll-Intervall
  (200 ms) → angeglichen, damit „active"-Übergänge nicht durch veralteten Cache flackern.

### Welle 2 — „Selbstdiagnose + Vertrauen" (v3.4.2 / v3.5)
5. **#5 Diagnostic** „arn doctor" mit Pass/Fail-Ampel (deckt H1-Fall, der für Normal-
   Install zwar falsifiziert ist, aber für Support/Handkopie-Fälle blind bleibt).
6. **#6 H7** — Hardware-Volume beim Umschalten übernehmen + Onboarding-Hinweis.
7. **#8 Sparkle** — Consent-Dialog + Opt-out-Toggle.
8. **#3 H5** — Totalausfall-Handling.
9. **#11 Verify-Loop** — Routing-Bestätigung < 5 s + Onboarding-Live-Schritt.
10. **#12 Self-Healing** — Backoff + Crash-Loop-Eskalation.

### Welle 3 — „Install-Härtung" (v3.5, sorgfältig auf sauberem Mac testen)
11. **#9 Install** — `ditto`/`launchctl kickstart`/Prompt-Kontext. **Risiko: Install-Pfad
    → zwingend auf frischem macOS-15 testen** (vgl. CASE-001 §7b Methodik).
12. **#10** — Handkopie-Doku + Quarantäne/codesign-Selbstcheck.

### Welle 4 — v4 / Swift-Rewrite (Backlog)
13. **#13** Per-Output-Volume (ABI-Bruch), **#14** SMJobBless, **#15** echtes i18n-Framework.

### Offene Punkte nach Wave 1

Nach Abschluss von Welle 1 bleibt als wichtigster ungelöster User-sichtbarer Befund:

| # | Punkt | Priorität | Hypothese | Status |
|---|-------|-----------|-----------|--------|
| 1 | **Volume-Freeze beim Routing-Start** — Wenn „Audio Router" System-Default wird, steuern die Lautstärketasten das virtuelle Router-Volume; die Hardware-Lautstärke des physischen Geräts (Mac-mini-Speaker) bleibt eingefroren → dauerhaft leiser Ton. Wahrscheinlichste Erklärung für bogdanws „faint sound". | **P1** | H7 | Offen → Wave 2 |
| 2 | **Bogdanw Helper-Log** — `log show … process == AudioRouterNowHelper` ausstehend; abschließende Bestätigung dass Fan-out-IOProcs starten (oder nicht). | P1 | H5/H7 | Ausstehend |
| 3 | **Bogdanw Info-Stand** — Über v3.4.1 noch nicht informiert; nächster Forum-Post geplant. | P2 | — | Ausstehend |

**Empfohlener Wave-2-Einstieg:** H7-Ansatz B (Hardware-Volume beim Umschalten als
Startwert übernehmen, §1 H7 Ansatz B) — Sofortmaßnahme, niedriges Risiko, verhindert
exakt das CASE-001-Symptom.

---

## 6. Was der Validator nach Welle 1 prüfen soll

- **H2:** Status-Zeile leitet Namen/Anzahl aus `status['active']` ab, nicht aus
  `_active_device_names`. Reproduktion: Gerät auswählen, dann physisch trennen → Status muss
  von „Routing active" auf „Routing to N of M" / „no active outputs" wechseln, ohne dass die
  Auswahl im Config geändert wird.
- **H2 Edge:** Helper killen (`pkill AudioRouterNowHelper`) → „Helper not responding".
  Router als Default, aber keine Geräte → „no active outputs", nicht „active".
- **H5:** Config mit nicht vorhandenem Gerätenamen vorbereiten → beim Start erscheint
  „unavailable"-Markierung + „N of M", kein stilles Verschwinden, keine falsche „N devices".
- **i18n:** `grep` über `engine/` nach den bekannten deutschen user-sichtbaren Strings
  (`nicht in CoreAudio gefunden`, `Keine Audio-Devices`, `Kopiere Treiber`) → in
  user-sichtbaren Pfaden keine Treffer mehr (Helper-Logs ausgenommen, falls Tranche 2).
- **Regression:** Normaler Happy-Path (1–3 echte Geräte) zeigt weiterhin „Routing active —
  <namen>" grün; Auto-Switch beim ersten Gerät funktioniert; Sample-Rate-Menü unverändert.
- **Keine Audio-Pfad-Änderung** in Welle 1 (Helper-C, shared_ring.h, Driver bleiben
  unangetastet) — reiner Python-UI/Config-Layer.
- **Threading:** Status-Lesen bleibt im health-poll-Thread, Rendern/Alerts/Notifications nur
  auf Main-Thread (kein `rumps.notification` aus Background — Muster `_enqueue_notification`
  beibehalten).
- **CLAUDE.md-Konformität:** Auto-Commit + `LAUNCH_EXECUTION.md`-Eintrag pro Schritt;
  Opus-Modell; keine Secrets; README-Änderungen frei von Marketing-Inhalten.

---

## 7. Offene technische Fragen (zur Klärung vor Implementierung)

- **`ioproc_calls`-Granularität:** Reicht der globale Zähler, oder brauchen wir pro-Output-
  Progress für „N of M"-Genauigkeit? (Pro-Output gibt es bereits `underruns`/`stalled`, aber
  keinen pro-Output-Call-Counter.) Für Welle 1: globaler Zähler + `active[]`-Länge genügt.
- **`router_is_default`-Listener:** CoreAudio-Property-Listener auf Default-Output zusätzlich
  zum Poll — Aufwand/Nutzen für Welle 1 oder erst Welle 2?
- **Hysterese-Schwellen** für „grün": wie viele stabile Polls, bevor „Routing active"? (gegen
  Flackern beim Start/Pre-Roll, ARN_PREROLL ≈ 43 ms).
- **i18n-Scope Helper-Logs:** Deutsche `fprintf` im Helper — für Diagnostic-Konsistenz auf
  Englisch? (Tranche 2, ABI-irrelevant, aber viele Stellen.)
- **Sparkle-Default:** Updates per Default an (opt-out) oder aus (opt-in)? OSS-Erwartung
  tendiert zu opt-out mit klarer Consent-Anzeige; Privacy-Marketing („no network") tendiert
  zu opt-in. **User-Entscheidung nötig** (Lock-in-nah, vgl. CLAUDE.md §„keine Lock-in-
  Entscheidungen allein").

---

## Update 2026-06-25 — Neue Erkenntnisse aus bogdanw-Thread (Posts #7–#9)

### Revidierte Analyse-Grundlage

Nach vollständiger Diagnose-Auswertung (system_profiler, codesign, coreaudiod-Logs):

**Falsifiziert:**
- H1 (Treiber nicht geladen): Treiber lädt korrekt via normaler App-Installation
- H1-Wurzel (Ad-hoc-Resign): Signatur ist Developer ID (5D52U34B3W), nicht Ad-hoc
- "error 0" im IOWorkLoopDeinit = noErr = sauberer Client-Stop, kein Crash

**Bestätigt / verschärft:**
- H2 (Status-UI lügt): P0 — Ist der sichtbarste Bug. Fix: `_active_device_names` → `status['active']`
- H7 (Lautstärken-Entkopplung): Wahrscheinlichste Erklärung für "faint". Konkret: Hardware-Volume des Mac-mini-Speakers bleibt beim Routing-Start eingefroren. Test: Audio MIDI Setup → Mac mini Speakers Volume auf Max während Routing aktiv.
- H5 (Stale Config): Kandidat für Pebble V3 + U3277WB komplett stumm

**Neue Erkenntnis — Fan-out-Blind-Spot:**
Die coreaudiod-Logs zeigen NUR das virtuelle Device (com.audiorouter.now.device) weil mit `grep -i audiorouter` gefiltert. Fan-out-IOProcs auf physischen Devices erscheinen unter deren eigenen Contexts. Wir haben KEINE Sichtbarkeit darauf ohne:
a) Ungefilterte coreaudiod-Logs ODER
b) Helper-eigene Logs

**Ausstehend:**
- Helper-Log von bogdanw angefordert: `log show --last 1h --predicate 'process == "AudioRouterNowHelper"' --info`

### Brainstorming-Ergänzungen

#### H7-Fix — Volume-Freeze beim Routing-Start (Konkretisierung)

**Problem:** Wenn "Audio Router" System-Default wird, steuern Lautstärketasten die virtuelle Router-Lautstärke (volume_q16 in shared_ring.h:96). Hardware-Volume des physischen Speakers bleibt auf altem Wert.

**Ansatz A (Sofortmaßnahme, v3.4.1):**
Beim Routing-Start die aktuelle Hardware-Lautstärke des bisherigen System-Defaults auslesen und als Ausgangspunkt für die virtuelle Lautstärke setzen. Code: `AudioObjectGetPropertyData(kAudioHardwarePropertyDefaultOutputDevice, kAudioDevicePropertyVolumeScalar)` → Wert in Shared Memory schreiben.

**Ansatz B (UX-Hinweis, minimal-invasiv):**
Beim ersten Routing-Start einen einmaligen Hinweis zeigen: "Volume keys now control the router, not your speakers directly." Mit Link zur Erklärung.

**Ansatz C (v4, bidirektional):**
Pro-Output-Volume mit Hardware-Passthrough. ABI-Breaking Change → v4.

**Empfehlung:** A für v3.4.1 (verhindert genau das "faint"-Symptom), B als Fallback wenn A komplex ist.

#### Diagnostic.py — Fan-out-Sichtbarkeit (neue P1-Anforderung)

**Problem:** Der aktuelle Diagnostic-Report ist blind für Fan-out-Failures. Er prüft nicht:
- Ob physische Device-IOProcs gestartet wurden
- Welche Devices der Helper tatsächlich bedient
- ring_frames-Fortschritt (fließt Audio?)

**Konkrete Ergänzungen:**
1. `get_status` aus Helper auswerten → `active[]`, `ring_frames`, `ioproc_calls`
2. Für jedes aktive Device: `AudioDeviceStart` Status-Check
3. Ausgabe: "Fan-out zu N/M Devices aktiv: [Device-Liste]"
4. Helper-Log-Pfad ausgeben und letzten Fehler anzeigen

**Warum jetzt P1 (war P1, bleibt P1 aber mit mehr Klarheit):**
Ohne diese Sichtbarkeit können weder wir noch der User einen Fan-out-Bug ohne Terminal-Expertise diagnostizieren. bogdanw musste 3 manuelle Commands ausführen, um uns die Infos zu geben, die die App automatisch melden sollte.

#### Manueller-Kopier-Sonderfall — UX-Warning (neue P2-Anforderung)

**Problem:** bogdanw hat den Treiber manuell kopiert (vermutlich experimentell), bekam dabei die "nicht gefunden"-Fehlermeldung, und wir haben 24 Stunden auf die falsche Hypothese gesetzt.

**Fix:** Beim App-Start prüfen ob /Library/Audio/Plug-Ins/HAL/AudioRouterNow.driver existiert aber NICHT dem erwarteten Install-Pfad / Bundle entspricht (z.B. andere Signatur-Timestamp als eigene Build-Timestamp). Wenn ja: Warnung "The driver seems to have been installed outside of the app. Please reinstall via the app to ensure correct operation."

**Alternativ:** In README und FAQ explizit: "Do not manually copy the driver bundle. Only the app installer correctly handles permissions, coreaudiod restart, and setup."

---

## Wave-2-Fix-Plan — v3.4.2 (2026-06-28, nach §15-Opus-Analyse)

> Basis: CASE-001 §15 (2026-06-28). Neue Erkenntnisse aus bogdanw Post #12.
> Root-Cause identifiziert: H7 (HW-Volume-Entkopplung) = Hauptursache Stille.
> H8 (Transport-Restart → Healer-Reconnect) = Instabilität bei 3+ Outputs.

---

### W2-1: HW-Volume beim Routing-Start auf physische Outputs übernehmen (P0)

**Problem:**
Wenn das virtuelle Audio-Router-Device zum System-Default wird, reagieren Lautstärketasten nur auf das *virtuelle* Volume (`shared_ring.h:96`, `audio_device_control.py:648`). Die HW-Lautstärke aller physischen Outputs (U3277WB, Pebble, etc.) bleibt eingefroren auf ihrem bisherigen Pegel — oft 0% oder ein alter niedrigen Wert. Ergebnis: kein hörbares Audio aus physischen Outputs. Dies ist H7, jetzt vollständig verstanden.

**Code-Belege:**
- `audio_device_control.py:648`: `set_default_output_volume` schreibt nur auf Default-Device (virtuell)
- `menu_bar_app.py:528` (`_switch_system_audio`): setzt Default, kein HW-Volume-Transfer
- `menu_bar_app.py:1457-1458` (`_auto_start_if_configured`): kein HW-Volume-Transfer
- `menu_bar_app.py:1479-1480` (`_save_and_apply`): kein HW-Volume-Transfer
- `audio_device_control.py:613`: `_volume_selector_for` — Selector für per-Device-Volume vorhanden

**Lösung:**
Im Moment des Switch: HW-Lautstärke des bisherigen Default-Geräts lesen (via `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`) → als virtuelles `volume_q16` setzen + jeden physischen Ziel-Output, der unter 20% steht, auf einen komfortablen Referenzpegel (z.B. 80%) anheben.

**Implementierung:**
1. `audio_device_control.py`: neue Funktion `get_device_volume_scalar(device_id)` + `set_device_volume_scalar(device_id, scalar)`
2. `menu_bar_app.py:528/1457/1479`: vor/nach `_set_default_output` → HW-Volume lesen → auf physische Outputs propagieren

**Risiken:**
- Geräte mit Hardware-Poti ignorieren Scalar-Volume → dokumentieren
- Ungewollt laute Built-In-Speaker → konservativ anheben, nur wenn aktuell <20%
- Property-Listener-Races → Volume-Set außerhalb des Audio-Callbacks

**Priorität:** **P0** — adressiert direkt bogdanws Hauptsymptom ("the other two outputs don't work")

---

### W2-2: Healer-Karenz gegen coreaudiod-Transport-Restart (P0)

**Problem:**
Wenn BuiltInSpeakerDevice als 3. Device zur AVAudioSession hinzukommt, erzwingt coreaudiod einen IOWorkLoop-Stopp für U3277WB (H8). Der Healer erkennt dies als Stall (1000ms Soft-Stall + 600ms Persist = 1600ms) und ruft `reconnect_output` auf — unnötigerweise, da coreaudiod den Transport selbst wiederherstellt. Das Ergebnis: 10s-Ausfall + Ring-Stau + Instabilität, obwohl der IOProc nach Reconnect korrekt feuert.

**Code-Belege:**
- `healer.py:25-27`: `STALL_PERSIST_SAMPLES = 3` (600ms bei 200ms Poll-Intervall)
- `healer.py:90-160` (`_process_output`): Stall → `reconnect_output` call
- `health.py:182`: `any_stalled` → `critical` → triggert Healer
- `AudioRouterNowHelper.c:1971-2011`: Soft-Stall-Detektor (1000ms), ruft KEIN Remove auf

**Lösung:**
(a) Nach dem Hinzufügen eines weiteren Devices 1500-2000ms Karenz-Fenster im Healer setzen (Reconnect erst starten wenn Fenster abgelaufen und Stall noch besteht).
(b) Vor `reconnect_output` prüfen: steigt `ioproc_calls` **global** noch? (Anderes Output-Device konsumiert weiter → wahrscheinlicher Transport-Restart, kein echter Stall)
(c) Backoff-Eskalation: wenn Reconnect 3x hintereinander keinen Erfolg bringt → log warning, nicht unbegrenzt wiederholen.

**Implementierung:**
- `healer.py`: neues `_transport_reconfig_window` State, `STALL_PERSIST_SAMPLES` adaptiv oder erhöht für Multi-Output-Szenarien
- `health.py`: neues Signal `transport_reconfig_suspected` (basierend auf `n_active_outputs`-Änderung im Status)

**Risiken:**
- Zu lange Karenz verzögert echte Recoveries (Gerät physisch entfernt)
- Sorgfältig gegen normalen Stall-Fall (Device wirklich weg) abgrenzen via Hot-Plug-Counter

**Priorität:** **P0** — behebt den 10s-Ausfall auf Multi-Output-Macs (Mac mini, alle mit BuiltIn als einem von mehreren Outputs)

---

### W2-3: Diagnostic: HW-Volume + Reconnect-State pro Output (P1)

**Problem:**
Der Diagnostic-Report zeigt `active[]`, `ring_frames`, `ioproc_calls` — aber NICHT die HW-Lautstärke der physischen Outputs. bogdanws Problem wäre mit einem einzigen "Output X: HW-Volume = 0%" sofort klar geworden.

**Lösung:**
Pro aktivem Output im Diagnostic-Report ausgeben: HW-Volume-Scalar, `stalled`, `recovery_count`, `underruns`-Delta, `src_ratio`-ppm, `reconnect_count`. Plus Hinweis: "Output X is at 0% hardware volume — raise it in Audio MIDI Setup."

**Implementierung:**
- `diagnostic.py`: neue Sektion `PER-OUTPUT STATE`, nutzt `get_status` `active[]` + `_volume_selector_for` + `get_device_volume_scalar` (aus W2-1)

**Risiken:** gering (read-only).

**Priorität:** **P1** — entscheidend für Support-Qualität

---

### W2-4: Add-Fehler und "failed to start" sichtbar machen (P1)

**Problem:**
Ein selektierter Output, der nie hinzugefügt wird (z.B. Pebble V3, H11), verschwindet still. Im Menü wird nur "⚠ unavailable" angezeigt (H5-Fix aus Wave 1), aber kein Unterschied zwischen "Gerät nicht im System" und "Gerät vorhanden, aber Start fehlgeschlagen".

**Lösung:**
`_reconcile_active_outputs` (menu_bar_app.py:1344) nutzt bereits `resp['active']`; zusätzlich die Differenz selected−active als "failed to start" im Status und Menü melden, differenziert von "unavailable/not found".

**Implementierung:**
- `menu_bar_app.py:1344-1432` + `_compute_status`: neue Kategorie "⚠ failed" vs "⚠ unavailable"

**Risiken:** gering.

**Priorität:** **P1**

---

### W2-5: Reproduktions-Test "Built-In vs. 3. Device" (Diagnose vor Release) (P1)

**Problem:**
H10 ist noch unvollständig: Trigger des Transport-Restarts ist unklar — "3. Device generell" oder "BuiltIn als Clock-Master speziell"?

**Testplan:**
Mac mini, test A: virtuell + U3277WB + Pebble (kein BuiltIn) → Transport-Restart? 
Mac mini, test B: virtuell + U3277WB + BuiltIn → Transport-Restart?
Wenn nur B → BuiltIn speziell → W2-2 Sonderpfad für BuiltIn-Add; wenn beide → "3. Device generell" → W2-2 reicht.

**Benötigt von bogdanw:** ungefilterten System-Log für beide Szenarien.

**Priorität:** **P1** — klärt ob W2-2 genügt oder zusätzliche Maßnahmen nötig sind

---

### W2-6: Pre-Roll/Lag-Eviction nach Re-Add optimieren (P2)

**Problem:**
Re-added Output U3277WB bringt Ring-Fill auf ~6933 Frames (~144ms), knapp unter Eviction-Schwelle (7372 = 90%). Die ~144ms Latenz ist hörbar (leichter Echo-Effekt bei simultaner Wiedergabe). Pre-Roll hält `local_ridx` als Minimum zurück und staut den Ring.

**Lösung:**
Pre-Roll-HWM für **Re-Adds** niedriger ansetzen, oder `read_idx`-Aggregat einen frisch armed Pre-Roll-Output erst nach HWM-Erreichen einbeziehen.

**Implementierung:**
- `AudioRouterNowHelper.c:1095-1134` (Aggregat), `:1263-1265` (Pre-Roll)

**Risiken:** Audio-Hot-Path, sorgfältige Underrun/Knack-Regressionstests nötig.

**Priorität:** **P2** — Latenz-Politur, keine Stille-Ursache. Zurückstellen auf v3.5.

---

### Release-Planung Wave 2

| Version | Inhalt | Risiko |
|---------|--------|--------|
| **v3.4.2** | W2-1 (HW-Volume), W2-2 (Healer-Karenz), W2-3 (Diagnostic), W2-4 (Add-Fehler) | Low (Python/Healer only, kein Audio-Pfad-Eingriff) |
| **v3.5** | W2-6 (Pre-Roll-Tuning) | Medium (C-Hot-Path, Regression-Tests nötig) |

**Voraussetzung vor v3.4.2:** W2-5 (Reproduktions-Test) mit bogdanws ungefiltertem Log durchführen.
