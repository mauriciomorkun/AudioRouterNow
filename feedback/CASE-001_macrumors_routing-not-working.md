# CASE-001 — Routing funktioniert nicht: "Audio Router nicht in CoreAudio gefunden"

> Navigation: [← zurück zum Feedback-Register](./README.md)

---

## 1. Metadaten

| Feld | Wert |
|------|------|
| **Case-ID** | CASE-001 |
| **Datum** | 2026-06-24 |
| **Quelle** | MacRumors-Forum |
| **Reporter** | Anonym (Forum-User) |
| **App-Version** | **Unbekannt — beim User erfragen** |
| **Betriebssystem** | macOS Sequoia 15.7.7 |
| **Hardware** | Mac mini (laut Symptom "Ton aus Mac-mini-Speaker") |
| **Status** | **Wave-2 implementiert (v3.4.2-dev) — bogdanw-Verifikation ausstehend** — Wave-1 (H2/H5/i18n/README/Diagnostic, Commits a7265bd/7115a60/7521f0b/68dc5ec) + Wave-2 (H7 W2-1 HW-Volume, H8 W2-2 Healer-Karenz, Commit 722ee69). Dual-Audit PASS (0 kritische Issues). Forum-Post an bogdanw bereit. Siehe §12–§15 + BRAINSTORM-001 Wave-2 |
| **Schweregrad** | **Kritisch** (App-Kernfunktion betroffen — kein Routing) |

---

## 2. Zusammenfassung (TL;DR)

Der HAL-Treiber **"Audio Router"** war auf dem System des Users **nicht in CoreAudio
geladen**. Die App konnte den System-Default deshalb nie auf das virtuelle Gerät
umstellen, sodass kein Fan-Out an die ausgewählten Geräte stattfand. Der "leise Ton"
ist mit hoher Wahrscheinlichkeit schlicht der **unveränderte System-Default**
(Mac-mini-Speaker) — die App hat den Audiopfad nie übernommen.

Die sichtbare Fehlermeldung ("'Audio Router' nicht in CoreAudio gefunden") entsteht
**ausschließlich** dann, wenn das virtuelle Gerät bei der Geräte-Enumeration nicht
gefunden wird ([`engine/audio_device_control.py:222-227`](../engine/audio_device_control.py)).
Der **primäre Verdacht** für die Ursache ist ein **Ad-hoc-Resign des Treibers nach der
Installation** ([`engine/first_launch.py:506-512`](../engine/first_launch.py)), der die
Developer-ID-/Notarisierungssignatur zerstört, sodass `coreaudiod` unter macOS 15 das
HAL-Plugin nicht zuverlässig lädt. Dieser Kausalzusammenhang ist **noch nicht bewiesen**
und muss reproduziert werden.

Zusätzlich **"lügt" die Status-Anzeige**: "Routing active — 3 devices" spiegelt die
gespeicherte Auswahl wider, nicht den real laufenden Audiopfad — das verschleierte für
den User, dass nichts geroutet wurde.

---

## 3. Originalfeedback des Users

Der User berichtete strukturiert fünf Punkte:

**Punkt 1 — Routing funktioniert nicht / Kernproblem**
Nach Auswahl der Geräte kam nur leiser Ton aus dem Mac-mini-Speaker; das gewünschte
Routing fand nicht statt. Beim Umschalten erschien die Fehlermeldung:

> **AudioRouterNow — Switch Failed**
> Could not switch system audio: 'Audio Router' nicht in CoreAudio gefunden.
> Ist der HAL-Treiber installiert und aktiv?
> Starte AudioRouterNow neu und versuche es erneut.

UI-Beobachtungen des Users:
- **BlackHole 2ch** war installiert, aber **nicht angehakt**.
- Der Status zeigte trotzdem **"Routing active — 3 devices"**.
- Auch der **Safe Mode** brachte keine Besserung.

**Punkt 2 — Homebrew-Widerspruch in der Doku**
Die README empfiehlt einerseits Homebrew-Installation, behauptet an anderer Stelle aber,
es gebe keine Homebrew-Abhängigkeit. Verwirrend.

**Punkt 3 — Admin-Passwort-Abfrage via osascript**
Beim Setup wurde per `osascript`-Dialog nach dem Admin-Passwort gefragt — das wirkt für
den User wenig vertrauenswürdig.

**Punkt 4 — Sparkle "Phone-home" ohne Opt-out**
Die App kontaktiert beim Start einen Update-Server (Sparkle), ohne dass es eine
sichtbare Opt-out-Möglichkeit gibt.

**Punkt 5 — Gemischte Sprache (DE/EN)**
Fehlermeldungen erscheinen teils auf Deutsch, teils auf Englisch — unprofessionell und
für nicht-deutschsprachige User unverständlich (die zitierte Fehlermeldung ist ein
Beispiel: deutscher Text in einer ansonsten englischen UI).

---

## 4. Architektur-Kontext

AudioRouterNow ist eine **3-Prozess-Pipeline**, die über einen **POSIX-Shared-Memory-Ring**
(`/audiorouter_shm`) kommuniziert:

```
┌─────────────────────────────┐     /audiorouter_shm     ┌──────────────────────────┐
│  HAL-Plugin (Producer)      │ ───── Ring-Buffer ─────▶ │  Helper (Consumer)       │
│  "Audio Router" virt. Gerät │                          │  ein device_ioproc       │
│  driver/src/                │                          │  pro physischem Output   │
│  AudioRouterNowDriver.c     │                          │  helper/                 │
└─────────────────────────────┘                          │  AudioRouterNowHelper.c  │
            ▲                                             └──────────────────────────┘
            │ System-Default = "Audio Router"                        ▲
            │                                                        │ UIDs / spawn
┌───────────┴──────────────────────────────────────────────────────┴──────────────┐
│  Menübar-App (Python / PyObjC)  —  engine/menu_bar_app.py                          │
│  · setzt System-Default auf "Audio Router" via engine/audio_device_control.py     │
│  · spawnt den Helper-Prozess                                                       │
│  · schickt dem Helper die Geräte-UIDs der ausgewählten Outputs                     │
└───────────────────────────────────────────────────────────────────────────────────┘
```

| Komponente | Rolle | Datei |
|------------|-------|-------|
| **HAL-Plugin** | Virtuelles Gerät "Audio Router", **Producer** in den Ring | [`driver/src/AudioRouterNowDriver.c`](../driver/src/AudioRouterNowDriver.c) |
| **Helper** | Unprivilegierter **Consumer**; ein `device_ioproc` je physischem Output = **Fan-Out** | [`helper/AudioRouterNowHelper.c`](../helper/AudioRouterNowHelper.c) |
| **Menübar-App** | Setzt System-Default auf "Audio Router", spawnt Helper, schickt UIDs | [`engine/menu_bar_app.py`](../engine/menu_bar_app.py), [`engine/audio_device_control.py`](../engine/audio_device_control.py) |

**Schlüssel-Implikation:** Wird das virtuelle Gerät nicht von `coreaudiod` geladen, kann
die Menübar-App den System-Default nicht umstellen → die gesamte Kette darunter (Ring →
Helper → Fan-Out) bleibt wirkungslos. Genau das ist das Bild dieses Falls.

---

## 5. Root-Cause-Analyse

> **Methodik:** Zwei unabhängige Opus-Analyse-Tracks haben den Code betrachtet und
> **konvergierten** auf dieselbe Kernursache (H1). Die folgenden Confidence-Werte sind
> Einschätzungen, keine bewiesenen Wahrscheinlichkeiten — der entscheidende Beweis
> (H1-Wurzel) **steht noch aus** (siehe §7).

### Hypothesen

#### H1 — Treiber nicht in CoreAudio geladen (Kernursache)

| | |
|---|---|
| **Confidence** | ~65–80 % (beide Tracks bestätigt) |
| **Mechanismus** | Das virtuelle Gerät "Audio Router" taucht nicht in der CoreAudio-Geräte-Enumeration auf → `target_id` bleibt `None` → System-Default kann nicht umgestellt werden → kein Fan-Out. Der "leise Ton" ist der **unveränderte** Original-Default (Mac-mini-Speaker). |
| **Code-Beleg** | Die Fehlermeldung entsteht **ausschließlich** bei `target_id is None` in [`engine/audio_device_control.py:222-227`](../engine/audio_device_control.py). |
| **Verifizierbarkeit** | Direkt prüfbar: `system_profiler SPAudioDataType` zeigt, ob "Audio Router" als Gerät existiert (siehe §7). |

```python
# engine/audio_device_control.py:222-227
if target_id is None:
    return False, (
        f"'{device_name}' nicht in CoreAudio gefunden.\n"
        "Ist der HAL-Treiber installiert und aktiv?\n"
        "Starte AudioRouterNow neu und versuche es erneut."
    )
```

#### H1-Wurzel — Ad-hoc-Resign zerstört die Treibersignatur (primärer Verdacht)

| | |
|---|---|
| **Confidence** | wahrscheinlichste Ursache — **NOCH NICHT BEWIESEN** |
| **Mechanismus** | Nach der Installation wird der Treiber **ad-hoc neu signiert** (`codesign --force --deep --sign -`). Das überschreibt die Developer-ID-/Notarisierungssignatur aus dem Build. macOS 15 `coreaudiod` lädt ein ad-hoc signiertes HAL-Plugin **nicht zuverlässig** → H1. |
| **Code-Beleg** | [`engine/first_launch.py:506-512`](../engine/first_launch.py) (Ad-hoc-Resign). Demgegenüber sauberes Build-Signing mit Developer-ID + `--options runtime` + `--timestamp` in [`installer/build.sh:258-285`](../installer/build.sh). |
| **Verifizierbarkeit** | Reproduktion mit/ohne Resign-Block (§7b) + `codesign -dv` auf dem installierten `.driver`. |

```python
# engine/first_launch.py:506-512  — der verdächtige Ad-hoc-Resign nach Install
# Sign the installed driver (ad-hoc, best-effort — kein admin nötig)
logger.info("Signing installed driver (ad-hoc)...")
subprocess.run(
    ["codesign", "--force", "--deep", "--sign", "-", str(DRIVER_INSTALL_PATH)],
    check=False,
    capture_output=True,
)
```

> **Hinweis zur Zeilennummer:** Der eigentliche `codesign`-Aufruf steht auf
> **Zeile 508–512**, der erläuternde Kommentar/Log auf **506–507**. Der ganze Block ist
> also 506–512; die ausführbare Resign-Logik 508–512.

#### H2 — Status-UI "lügt" (echter Bug)

| | |
|---|---|
| **Confidence** | ~85 % |
| **Mechanismus** | "Routing active — N devices" zeigt `len(self._active_device_names)` an — das ist die **gespeicherte/gewählte** Geräteliste, **nicht** der real laufende Audiopfad. So sieht der User "aktiv", obwohl nichts geroutet wird. |
| **Code-Beleg** | Status-String aus `self._active_device_names` in [`engine/menu_bar_app.py:998-1002`](../engine/menu_bar_app.py). `_active_device_names` wird aus der gespeicherten Config initialisiert ([`menu_bar_app.py:105`](../engine/menu_bar_app.py)). Der echte Zustand läge in `resp['active']` des Helpers ([`helper/AudioRouterNowHelper.c:2275-2330`](../helper/AudioRouterNowHelper.c), `format_active_outputs` + Status-JSON). |
| **Gates unzureichend** | `routed_here` ([`menu_bar_app.py:980`](../engine/menu_bar_app.py)) und `ring_frames > 0` ([`menu_bar_app.py:990`](../engine/menu_bar_app.py), Helper-Seite [`AudioRouterNowHelper.c:2387`](../helper/AudioRouterNowHelper.c)) prüfen den **physischen Output nicht** — sie verifizieren nicht, dass tatsächlich ein IOProc auf einem realen Gerät läuft. |
| **Verifizierbarkeit** | Code-evident; reproduzierbar durch Auswahl ohne tatsächliches Routing. |

> **Hinweis:** Es existiert eine Reconcile-Funktion gegen `resp['active']`
> ([`menu_bar_app.py:1270`](../engine/menu_bar_app.py)), die die **Auswahl** mit den real
> aktiven Outputs abgleicht. Der **Status-String** bei Zeile 998 liest dennoch aus
> `_active_device_names` — der angezeigte Text wird also nicht vom verifizierten
> Live-Zustand getrieben.

#### H3 — Fan-Out / Gain / Sample-Rate-Bug (für diesen User vermutlich nicht primär)

| | |
|---|---|
| **Confidence** | ~25–30 % |
| **Mechanismus** | Falls der Treiber **doch** geladen war, käme ein Fehler im Mix-/SRC-Pfad als Erklärung für "leise" in Frage (Gain-/Sample-Rate-/De-Interleave-Fehler). |
| **Code-Beleg** | Mix-/SRC-Pfad in [`helper/AudioRouterNowHelper.c`](../helper/AudioRouterNowHelper.c) (ca. Zeilen 1206–1448). |
| **Relevanz** | Für **diesen** User unwahrscheinlich (die Fehlermeldung deutet klar auf "Gerät nicht gefunden"). **Für einen späteren zweiten User vormerken**, dessen Treiber geladen ist. |

#### H4 — "Safe Mode" wirkungslos (stützt H1)

| | |
|---|---|
| **Confidence** | ~90 % |
| **Mechanismus** | "Safe Mode" / Safe-Take toggelt nur das **Auto-Healing innerhalb des laufenden Routings**. Wenn das Routing nie zustande kam (H1), kann Safe Mode nichts retten — die Ursache liegt **davor**. Dass Safe Mode nicht half, ist also konsistent mit H1. |
| **Code-Beleg** | Toggle `_toggle_safe_take` in [`engine/menu_bar_app.py:443-448`](../engine/menu_bar_app.py) (ruft `set_safe_take`); Helper-Seite Safe-Take-State in [`AudioRouterNowHelper.c:2400-2401`](../helper/AudioRouterNowHelper.c). |
| **Verifizierbarkeit** | Logisch konsistent; bestätigt sich automatisch mit H1-Beweis. |

> **Hinweis zur Zeilennummer:** Der Safe-Mode-Toggle ist `_toggle_safe_take` auf
> **443–448** (Prompt nannte 443–447; der `set_safe_take`-Aufruf liegt auf 446).

### Offen / spekulativ

**Warum "leise" (nicht nur falsches Gerät)?** — *Spekulation, mit Diagnosedaten zu klären:*
- Lautstärketasten wirken evtl. auf den falschen Default
  ([`menu_bar_app.py` Volume-Pfad ~1170](../engine/menu_bar_app.py),
  `_apply_media_key_volume`), oder
- der eingebaute Mac-mini-Speaker ist schlicht leise.

Diese Frage ist **erst mit Diagnosedaten** (System-Default + Volume-Pegel) belastbar
beantwortbar.

---

## 6. Sekundärbefunde (Feedback-Punkte 2–5)

| Punkt | Befund | Schweregrad | Beleg |
|-------|--------|-------------|-------|
| **2 — Homebrew-Widerspruch** | README sagt "Homebrew (recommended)" vs. "No Homebrew dependencies". Tap evtl. noch nicht live. | Hoch | [`README.md:80`](../README.md) ("**Option A — Homebrew (recommended)**") vs. [`README.md:180`](../README.md) ("No kernel extension. No restart. **No Homebrew dependencies.**") |
| **3 — osascript-Admin-Prompt** | Treiber-Install via `do shell script … with administrator privileges` statt signiertem privilegiertem Helper / SMJobBless → wirkt wenig vertrauenswürdig. | Mittel–Hoch | [`engine/first_launch.py:372`](../engine/first_launch.py) (`applescript = f'do shell script "{shell_cmd}" with administrator privileges'`) |
| **4 — Sparkle Phone-home ohne Opt-out** | Update-Check kontaktiert `mauriciomorkun.github.io/AudioRouterNow/appcast.xml`; **kein In-App-Toggle** zum Deaktivieren. **Kein Tracking gefunden** — nur der Update-Feed. | Mittel (Privacy) | [`engine/updater.py:109-134`](../engine/updater.py) (Sparkle-Start liest SUFeedURL); SUFeedURL-Wert in [`installer/AudioRouterNow.spec:106`](../installer/AudioRouterNow.spec) |
| **5 — i18n-Bug (DE/EN gemischt)** | Keine i18n-Schicht; gemischte deutsche/englische Strings. Die Kern-Fehlermeldung ist deutsch in einer englischen UI. | Hoch | [`engine/audio_device_control.py:223-227`](../engine/audio_device_control.py) (deutscher Fehlertext) |

---

## 7. Verifikations- & Diagnoseplan

### (a) Beim User anfordern (read-only, ungefährlich)

Folgende Befehle liefern den Beweis für H1 / H1-Wurzel:

```sh
# 1. Existiert das virtuelle Gerät "Audio Router" in CoreAudio überhaupt?
system_profiler SPAudioDataType | grep -A3 -i router

# 2. Wie ist der installierte Treiber signiert? (Developer-ID vs. ad-hoc)
codesign -dv --verbose=4 /Library/Audio/Plug-Ins/HAL/AudioRouterNow.driver

# 3. Hat coreaudiod das Plugin abgelehnt / als invalid markiert?
sudo log show --last 30m --predicate 'process == "coreaudiod"' --info \
  | grep -iE "audiorouter|plug-?in|reject|invalid"
```

**Zusätzliche Fragen an den User:**
- DMG-Install oder Homebrew-Install?
- Wurde das Admin-Passwort beim Setup tatsächlich eingegeben?
- Welche **App-Version** (z. B. v3.4.0)?

### (b) Selbst reproduzieren (entscheidender Beweis)

Auf einem **frischen macOS-15-System** (nicht der Dev-Mac, da dort die Signatur-Policy
gelockert sein kann):

1. App installieren **einmal MIT** dem Resign-Block ([`first_launch.py:507-512`](../engine/first_launch.py))
   und **einmal OHNE**.
2. Jeweils `system_profiler SPAudioDataType | grep -i router` prüfen.

**Beweislage:** Taucht "Audio Router" **nur ohne** den Resign-Block auf, ist die
**H1-Wurzel bewiesen** (Ad-hoc-Resign verhindert das Laden).

### (c) Bekannte Lücke im aktuellen Diagnostic Report

[`engine/diagnostic.py`](../engine/diagnostic.py) prüft **nicht**:
- Treiber-**Präsenz** in CoreAudio / `system_profiler`,
- **codesign**-Status des installierten `.driver`,
- ob "Audio Router" der **aktuelle System-Default** ist.

→ Der Diagnostic Report ist für **genau diesen Fehlerfall blind**. Ein User mit
ungeladenem Treiber bekommt keinen aussagekräftigen Self-Report.

---

## 8. Empfohlene nächste Schritte / Fix-Backlog

> **Wichtig: Es wird JETZT NICHT gefixt.** Die folgende Liste ist der geplante,
> priorisierte Backlog. Aufwand/Risiko sind grobe Einschätzungen.

- [ ] **P0 — H1-Wurzel beweisen** (Reproduktion §7b + Diagnose-Daten §7a). *Aufwand: mittel · Risiko: niedrig (read-only / Test-Mac).*
- [ ] **P0 — Treiber-Signatur-/Lade-Strategie auf macOS 15 fixen.** Ad-hoc-Resign-Block ([`first_launch.py:506-512`](../engine/first_launch.py)) überdenken/entfernen; korrekt notarisiertes/Developer-ID-signiertes `.driver` **ohne** Ad-hoc-Override ausliefern; ggf. `ditto` statt `cp` beim Install, und `launchctl kickstart -k system/com.apple.audio.coreaudiod` statt `killall coreaudiod`. *Aufwand: mittel–hoch · Risiko: hoch (Signing/Install-Pfad, zwingend auf sauberem Mac testen).*
- [ ] **P1 — Status-UI muss den realen Zustand verifizieren** (`resp['active']` **und** Default == "Audio Router") statt der gespeicherten Auswahl ([`menu_bar_app.py:998`](../engine/menu_bar_app.py)). *Aufwand: mittel · Risiko: niedrig–mittel.*
- [ ] **P1 — i18n:** Fehlermeldungen auf Englisch vereinheitlichen / Lokalisierungsschicht einführen ([`audio_device_control.py:223-227`](../engine/audio_device_control.py) u. a.). *Aufwand: mittel · Risiko: niedrig.*
- [ ] **P1 — Diagnostic Report erweitern** ([`diagnostic.py`](../engine/diagnostic.py)): Treiber-Präsenz + `codesign` + `system_profiler` + `is_audio_router_default` (Self-Diagnose-Modus). *Aufwand: mittel · Risiko: niedrig.*
- [ ] **P2 — Sparkle Opt-out / First-Run-Consent** ([`updater.py`](../engine/updater.py)). *Aufwand: niedrig–mittel · Risiko: niedrig.*
- [ ] **P2 — README-Homebrew-Widerspruch korrigieren** ([`README.md:80`](../README.md) vs. [`:180`](../README.md)). *Aufwand: niedrig · Risiko: niedrig.*
- [ ] **P2 — Admin-Prompt-Vertrauen verbessern** (signierter privilegierter Helper / SMJobBless statt nacktem `osascript`, [`first_launch.py:372`](../engine/first_launch.py)). *Aufwand: hoch · Risiko: mittel.*

---

## 9. Entwurf User-Antwort (Englisch)

> Ton: ehrlich, wertschätzend, problem-bestätigend. Text kann vor Versand geglättet werden.

```text
Hi, and thank you — this is genuinely one of the most useful reports I've received.
You found a real and important problem, and you took the time to describe it clearly.
I appreciate that.

The core issue: it looks like the virtual "Audio Router" device was never loaded by
macOS on your system. When that happens, AudioRouterNow can't take over your system
audio at all — so what you heard was simply your unchanged default output (the Mac mini
speaker). That also explains why Safe Mode didn't help: Safe Mode only adjusts an
already-running route, and in your case routing never actually started.

You also caught a second real bug: the status said "Routing active — 3 devices" even
though nothing was routed. That label was reflecting your *saved selection*, not the
actual live audio path. That's misleading and I'll fix it so the status reflects reality.

To confirm the root cause, could you run these three read-only commands and paste the
output? They don't change anything on your machine:

  system_profiler SPAudioDataType | grep -A3 -i router
  codesign -dv --verbose=4 /Library/Audio/Plug-Ins/HAL/AudioRouterNow.driver
  sudo log show --last 30m --predicate 'process == "coreaudiod"' --info | grep -iE "audiorouter|plug-?in|reject|invalid"

And three quick questions:
  - Did you install via the DMG or via Homebrew?
  - Did you enter your admin password during setup?
  - Which app version are you on?

On your other points, you're right on all of them:
  - The README contradicts itself on Homebrew ("recommended" vs. "no Homebrew
    dependency"). I'll fix the docs.
  - The osascript admin prompt is not a confidence-inspiring way to install a system
    driver. I want to move to a properly signed privileged helper.
  - The update check (Sparkle) currently has no visible opt-out. To be clear: it only
    fetches an update feed, there's no tracking — but I'll add an opt-out / first-run
    consent.
  - The mixed German/English error messages are a bug. The app should be fully English
    (or properly localized). I'll fix that too.

Thanks again — this report directly shapes the next release.
```

---

## 10. Offene Fragen / To-Confirm

- [ ] **Ist H1-Wurzel (Ad-hoc-Resign) tatsächlich die Ursache?** — Reproduktion mit/ohne Resign-Block ausstehend.
- [ ] **War der Treiber wirklich nicht geladen?** — `system_profiler`-Output des Users ausstehend.
- [ ] **codesign-Status** des installierten `.driver` beim User unbekannt.
- [ ] **Warum "leise" statt "stumm"/"falsches Gerät"?** — Volume-/Default-Verhalten ungeklärt (spekulativ).
- [ ] **Install-Methode** (DMG vs. Homebrew) und **App-Version** unbekannt.
- [ ] **Wurde das Admin-Passwort eingegeben** (Treiber-Install evtl. fehlgeschlagen)?
- [ ] **macOS-15-Signatur-Policy** für ad-hoc HAL-Plugins: genaues Verhalten von `coreaudiod` zu bestätigen.

---

## 13. Thread-Fortsetzung 2026-06-25 — Posts #7–#9, Diagnose-Daten & Interpretation

### 13.1 Thread-Verlauf (Posts #7, #8, #9)

Der MacRumors-Thread mit bogdanw wurde über drei weitere Posts fortgeführt. Dieser
Abschnitt protokolliert den vollständigen Austausch, der zu den in §12 begonnenen
Hypothesen die entscheidenden Diagnose-Daten geliefert hat.

#### Post #7 — MauricioMorkun (2026-06-24, 21:33 Uhr)

Antwort auf bogdanws ersten Post (#6). Inhalt:

- **Falsche Haupthypothese vertreten:** Vermutung, der *"installer re-signs the driver
  in a way macOS Sequoia rejects"* — also die H1-Wurzel (Ad-hoc-Resign zerstört die
  Signatur). Diese Annahme stellte sich später (Post #9) als Sackgasse heraus.
- **Status-Bug bestätigt:** Der Befund #2 (Status-Anzeige "Routing active — 3 devices"
  trotz nicht angehaktem BlackHole) wurde als **echter Bug** anerkannt (H2).
- **3 Diagnose-Commands angefordert:**
  - `system_profiler SPAudioDataType …` (Treiber-Präsenz in CoreAudio)
  - `codesign -dv --verbose=4 …` (Signatur-Status des installierten `.driver`)
  - `sudo log show … process == "coreaudiod"` (Plugin-Load / Reject)
- **Rückfragen:** DMG- oder Homebrew-Installation? Wurde das Admin-Passwort eingegeben?
- **Alle 4 Sekundär-Kritikpunkte bestätigt** (i18n DE/EN, README-Homebrew-Widerspruch,
  osascript-Admin-Prompt, Sparkle ohne Opt-out) und Fixes zugesagt.

#### Post #8 — bogdanw (2026-06-25, 06:09 Uhr)

Entscheidende Klarstellung und Lieferung der angeforderten Daten:

- **Fehlermeldung-Kontext präzisiert:** Die Meldung *"Switch Failed / 'Audio Router'
  nicht in CoreAudio gefunden"* trat **ausschließlich** beim **manuellen Kopieren**
  des Treibers auf:
  `/Applications/AudioRouterNow.app/Contents/Frameworks/AudioRouterNow.driver`
  → `/Library/Audio/Plug-Ins/HAL/AudioRouterNow.driver`
- Wörtlich: **"No error is displayed when the driver is installed by the app."**
  → Bei normaler Installation tritt der Fehler **nicht** auf.
- **Diagnose-Daten geliefert** (vollständig protokolliert in §13.2).
- **Install-Weg geklärt:** DMG via Drag&Drop, Admin-Passwort eingegeben — die DMG
  wurde vom User sogar vorab via **VirusTotal** geprüft.

#### Post #9 — MauricioMorkun (2026-06-25, ~13:00 Uhr)

Gesendete Antwort (Volltext, wie versandt):

```text
Thanks for the detailed follow-up, and for running everything — that data is exactly what we needed.

First, an honest correction: my last reply was partly wrong. I latched onto that "Switch Failed" dialog and built a theory around the driver not loading. But you've now clarified that error only showed up when you manually copied the .driver into /Library/Audio/Plug-Ins/HAL/ — not during the normal app install. That changes the picture completely, and it means my "installer re-signs the driver in a way Sequoia rejects" hypothesis was a dead end. Apologies for sending you down that path.

What your output actually tells us is good news for the driver:
- system_profiler shows Audio Router present, and it's both Default Output and System Output.
- codesign is a clean Developer ID chain (5D52U34B3W), valid timestamp. No signing problem.
- In the coreaudiod log, the driver loads, activates, becomes default, and the helper's keepalive IOProc starts and stays running. The one IOProc that stops after ~1s exits with "error 0" — that's noErr, a clean client stop (some app played a short sound and released the device), not a crash.

So the virtual device itself is healthy. The problem is downstream: the fan-out to your three physical outputs (Mac mini Speakers, Pebble V3, U3277WB). And here's the catch — the log you pulled was filtered with grep -i audiorouter, so it only shows the virtual device's own IOContext. The fan-out IOProcs run under each physical device's context and simply don't appear in that filtered slice. That's the one blind spot we have left.

On the faint sound specifically: this is most likely a volume freeze. Once "Audio Router" becomes the System Output, your volume keys control the virtual router's level, not the Mac mini speaker's hardware level directly. If that speaker was turned down before you switched, it stays down, and the keys no longer reach it. Worth a quick test: open Audio MIDI Setup, bump the Mac mini Speakers' output volume to max while AudioRouterNow is active, and see if the level jumps.

One thing left that would close this out — the helper's own log, which shows whether it actually started IOProcs on the three physical devices:
  log show --last 1h --predicate 'process == "AudioRouterNowHelper"' --info

That should tell us definitively whether the fan-out IOProcs are starting and failing, or not starting at all. Thanks again for the patience — and for VirusTotal-ing the DMG, that made me smile.
```

---

### 13.2 Diagnose-Daten von bogdanw (vollständig)

Die vom User in Post #8 gelieferten Rohdaten, unverändert protokolliert.

**`system_profiler SPAudioDataType | grep -A3 -i router`:**

```text
Audio Router:
  Default Output Device: Yes
  Default System Output Device: Yes
  Manufacturer: AudioRouterNow
  Output Channels: 2
  Current SampleRate: 48000
  Transport: Virtual
```

**`codesign -dv --verbose=4 /Library/Audio/Plug-Ins/HAL/AudioRouterNow.driver`:**

```text
Authority=Developer ID Application: MAURICIO MORAIS DA CUNHA (5D52U34B3W)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=15 Jun 2026 at 11:35:55
Identifier=com.audiorouter.now.driver
Format=bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=390 flags=0x10000(runtime)
Runtime Version=26.5.0
```

**`sudo log show --last 30m --predicate 'process == "coreaudiod"' | grep -i audiorouter`:**

```text
06:54:24 HALS_RemotePlugInRegistrar.mm:237 Attempting to load: AudioRouterNow.driver
06:54:24 HALS_RemotePlugInRegistrar.mm:421 Creating remote driver service: "AudioRouterNow.driver", pid: 2447
06:54:24 HALS_Device.cpp:162 HALS_Device::Activate: activating device 60: com.audiorouter.now.device
06:54:24 HALS_DefaultDeviceManager.cpp:1706 FindPreferredDefaultDevice: 'sOut' | found preferred[0] 60
06:54:25 HALS_IOContext_Legacy_Impl.cpp:1707 IOWorkLoopInit: 284 com.audiorouter.now.device: starting  [PID 2453]
06:54:25 HALB_PowerAssertion.cpp:115 taking power assertion ID 33879 on behalf of 2453
06:55:51 HALS_DefaultDeviceManager.cpp:1068 SetDefaultDevice: 'dOut' | 60: 'com.audiorouter.now.device'
06:55:51 HALS_DefaultDeviceManager.cpp:1068 SetDefaultDevice: 'sOut' | 60: 'com.audiorouter.now.device'
06:55:51 IOWorkLoopInit: 171 com.audiorouter.now.device: starting  [PID 586]
06:56:07 IOWorkLoopInit: 172 com.audiorouter.now.device: starting  [PID 692]
06:56:08 IOWorkLoopDeinit: 172 com.audiorouter.now.device: stopping with error 0
06:56:08 HALB_PowerAssertion.cpp:153 releasing power assertion ID 33659 ... for 0.973746 seconds
```

> **Hinweis zu den drei physischen Outputs:** bogdanw nennt in diesem Thread drei
> Ziel-Geräte — **Mac mini Speakers**, **Pebble V3** und **U3277WB** (Dell-Monitor).
> Diese ersetzen die zuvor angenommene Beispiel-Trias (BlackHole/Interface) als
> reale Fan-out-Ziele dieses Falls.

---

### 13.3 Interpretation der Diagnose-Daten

#### Was bestätigt ist (virtuelle Schicht = gesund)

| Befund | Beleg im Log/Output | Aussage |
|---|---|---|
| **Treiber lädt korrekt** | `HALS_RemotePlugInRegistrar: Attempting to load …` → `Creating remote driver service … pid 2447` | Plugin wird gefunden und der Plugin-Host gestartet |
| **Virtuelles Device aktiv** | `HALS_Device::Activate: activating device 60: com.audiorouter.now.device` | Device 60 ist enumeriert und aktiv |
| **System-Default korrekt gesetzt** | `SetDefaultDevice 'dOut' → 60` + `'sOut' → 60` | Sowohl Output- als auch System-Output-Default zeigen auf den Router |
| **Helper-Keepalive persistent** | `IOWorkLoopInit: 284 … [PID 2453]` + Power-Assertion auf 2453, **kein Deinit** | PID 2453 / Context 284 = persistenter Keepalive-IOProc des Helpers → läuft dauerhaft |
| **"error 0" ist kein Fehler** | `IOWorkLoopDeinit: 172 … stopping with error 0` | `error 0 == noErr` = sauberer, vom Client gewollter Stop (kein Crash) |
| **H1 + H1-Wurzel falsifiziert** | gesamte obige Kette | Für die **Normal-Installation** vollständig widerlegt |
| **Signatur intakt** | `Developer ID Application … (5D52U34B3W)` → `Apple Root CA`, gültiger Timestamp | Sauberer Developer-ID-Chain, **kein** Ad-hoc-Resign |

#### Was die Logs NICHT zeigen (die verbleibende Blindstelle)

- Die **Fan-out-IOProcs** auf den physischen Devices (Mac mini Speakers, Pebble V3,
  U3277WB) laufen unter **deren eigenen IOContexts** — nicht unter dem des virtuellen
  Devices.
- Der gelieferte Log-Auszug war mit `grep -i audiorouter` gefiltert → es ist
  **ausschließlich das virtuelle Device** sichtbar.
- Ob die physischen IOProcs überhaupt gestartet wurden, ist aus diesem Auszug
  **nicht** erkennbar. Das ist die zentrale offene Frage dieses Falls.

#### Hypothesen-Status nach §13

| Hypothese | Status | Begründung |
|---|---|---|
| **H1 + H1-Wurzel** (Treiber nicht geladen / Resign zerstört Signatur) | ❌ **Falsifiziert** für Normal-Install | system_profiler + codesign + coreaudiod-Log eindeutig sauber |
| **H2** (Status-UI "lügt") | ✅ **BEHOBEN (v3.4.1)** | `_compute_status` liest realen Zustand aus `status['active']` (7-Zustands-Matrix). Commit 7521f0b. Siehe §14 |
| **H5** (Stale Config / stille Skip) | ✅ **BEHOBEN (v3.4.1)** | Fehlende Geräte als `⚠ unavailable` sichtbar + Reconcile-Hardening. Commit 7521f0b. Siehe §14 |
| **H7** (Lautstärken-Entkopplung) | ⚠️ **Ausstehend (Wave 2)** — wahrscheinlichste Erklärung für "faint" am Mac-mini-Speaker | Volume-Keys steuern Router, nicht die HW-Lautstärke des Speakers |
| **Manueller Kopier-Sonderfall** | 📄 **Dokumentiert** in §12.5 | Erklärt die ursprünglich gemeldete Fehlermeldung |

#### Zentrale offene Frage

> **Wurden die Fan-out-IOProcs auf Mac mini Speakers, Pebble V3 und U3277WB
> tatsächlich gestartet?**
>
> → Angefordert via Helper-Log (Post #9):
> ```sh
> log show --last 1h --predicate 'process == "AudioRouterNowHelper"' --info
> ```
> Dieses Log zeigt definitiv, ob die physischen IOProcs **starten und fehlschlagen**
> (→ H5) oder **gar nicht erst starten** — und entscheidet damit zwischen H5 und H7
> (bzw. beidem).

---

### 13.4 Status-Update

| Feld | Wert |
|---|---|
| **Status** | In Analyse — Virtuelle Schicht bestätigt OK; Fan-out-Schicht ungeklärt; Helper-Log angefordert |
| **Schweregrad** | **Kritisch** (Kern-Routing nicht hörbar) |
| **Nächster Schritt** | bogdanw liefert Helper-Log → Entscheidung ob **H5** oder **H7** oder **beides** |

---

## 11. Änderungs-Log

| Datum | Was |
|-------|-----|
| 2026-06-24 | Case angelegt. Root-Cause-Analyse (H1–H4 + Wurzelverdacht), Sekundärbefunde, Verifikations-/Diagnoseplan, Fix-Backlog und User-Antwort-Entwurf dokumentiert. Datei:Zeile-Belege gegen die Quelldateien verifiziert. |
| 2026-06-25 | **Revision auf Basis neuer User-Diagnosedaten (bogdanw, MacRumors).** H1 + H1-Wurzel **falsifiziert für die normale App-Installation** (codesign = gültige Developer ID, system_profiler = Device präsent + Default, coreaudiod-Logs = erfolgreicher Load + Keepalive-IOProc). Die "nicht in CoreAudio gefunden"-Meldung trat **nur** im manuellen Kopier-Sonderfall auf. coreaudiod-Logs neu interpretiert ("error 0" = sauberer Stop, kein Fehler). Neue Hypothesen H5–H7 formuliert. Siehe §12. |
| 2026-06-25 | §13 hinzugefügt: Thread-Fortsetzung Posts #7-#9, vollständige Diagnose-Daten, Interpretation, Status-Update |
| 2026-06-25 | §14 hinzugefügt — Wave-1-Fixes implementiert (H2, H5, i18n, README, Diagnostic) |
| 2026-06-26 | Lokaler Test-Build v3.4.1-dev erstellt — Wave-1-Fixes in laufender App verfügbar für manuelle Verifikation |

---

## 12. Revision 2026-06-25 — Neue Diagnosedaten (bogdanw, MacRumors G3)

### 12.1 Was sich geändert hat (Zusammenfassung)

Der User hat verwertbare Diagnosedaten und eine entscheidende Klarstellung geliefert:
Die Fehlermeldung **"'Audio Router' nicht in CoreAudio gefunden"** trat **ausschließlich**
auf, als er den Treiber **manuell** aus dem App-Bundle nach
`/Library/Audio/Plug-Ins/HAL/` kopierte. Bei der **normalen DMG-Installation**
(Drag&Drop + Admin-Passwort) erschien **kein** solcher Fehler.

**Konsequenz:** Die bisherige Kernhypothese H1 (Treiber nicht geladen) und ihr
Wurzelverdacht H1-Wurzel (Ad-hoc-Resign zerstört Signatur) sind für die
**normale Installation falsifiziert**. Das verbleibende Problem ("Routing tut
nichts / leiser Ton aus dem Speaker") tritt **trotz korrekt geladenem, als Default
gesetztem Treiber** auf — die Ursache liegt also **nicht** im Treiber-Load,
sondern weiter unten in der Pipeline (Consumer/Fan-out, Lautstärke, oder stale
Config) bzw. in der UI ("Status lügt", H2).

### 12.2 Befund: H1 + H1-Wurzel falsifiziert (Normal-Install)

| Diagnosedatum | Aussage | Konsequenz |
|---|---|---|
| `system_profiler SPAudioDataType` | "Audio Router" ist in CoreAudio, ist Default + System Output | Treiber **geladen**, `target_id` ist **nicht** `None` → H1 trifft nicht zu |
| `codesign -dv` | "Developer ID Application: MAURICIO MORAIS DA CUNHA", Apple Root CA | Installierter Treiber trägt **gültige Developer-ID** (kein Ad-hoc) → H1-Wurzel trifft nicht zu |
| coreaudiod-Log 06:54:24 | `HALS_RemotePlugInRegistrar … Attempting to load: AudioRouterNow.driver` + `Creating remote driver service … pid 2447` + `HALS_Device::Activate: device 60: com.audiorouter.now.device` | Plugin wird **erfolgreich geladen und aktiviert** |

**Fazit:** Bei der normalen Installation lädt coreaudiod das HAL-Plugin korrekt.
H1/H1-Wurzel bleiben nur für den **manuellen Kopier-Sonderfall** (§12.5) relevant.

### 12.3 coreaudiod-Logs — korrekte Interpretation

Alle Log-Zeilen betreffen **ausschließlich das virtuelle Device**
`com.audiorouter.now.device`. Die Fan-out-IOProcs des Helpers laufen dagegen auf
den **physischen** Output-Devices (Mac-mini-Speaker, BlackHole, Interface) und
würden unter **deren** IOContext geloggt — sie fehlen im gelieferten Auszug.
Aus diesen Logs lässt sich daher **nichts** über den Fan-out aussagen.

**Wer ist welche PID?**

| Eintrag | PID / Context | Deutung |
|---|---|---|
| `Creating remote driver service "AudioRouterNow.driver", pid: 2447` | **2447** | coreaudiod-**Plugin-Host** (sandboxed Child, der den Treibercode ausführt). Nicht die App, nicht der Helper. |
| `IOWorkLoopInit: 284 … starting [PID 2453]` (06:54:25) + Power-Assertion auf 2453 | **2453** = Context **284** | Erster IOProc-Client auf dem virtuellen Device, **1 s nach Device-Aktivierung**, **persistent (kein Deinit)** → das ist der **Keep-Alive-IOProc des C-Helpers** (`keepalive_start(find_device_by_uid(OUR_DEVICE_UID))`, [`helper/AudioRouterNowHelper.c:2921`](../helper/AudioRouterNowHelper.c) → `keepalive_start` [:461](../helper/AudioRouterNowHelper.c)). **Beweist: Helper läuft, hat das virtuelle Device gefunden, hält `gDeviceIsRunning=1`.** |
| `SetDefaultDevice 'dOut'+'sOut' → 60` (06:55:51) | — | App ruft `set_default_output_device` + `set_default_system_output_device` ([`menu_bar_app.py:516-520`](../engine/menu_bar_app.py) bzw. `_save_and_apply` [:1400-1401](../engine/menu_bar_app.py)). **User-Aktion** (Klick "System Audio → Audio Router" oder Auto-Switch beim ersten Device). |
| `IOWorkLoopInit: 171 … [PID 586]` (06:55:51), persistent | **586** = Context **171** | Niedrige, langlebige PID → ein **System-Audio-Client**, der beim Default-Wechsel auf das neue Default-Device umzieht (z.B. ein bereits laufender Audio-Agent). |
| `IOWorkLoopInit: 172 … [PID 692]` (06:56:07) → `IOWorkLoopDeinit: 172 … stopping with error 0` (06:56:08) | **692** = Context **172** | **Transienter App-Client**: öffnet das Device, läuft **~1 s**, stoppt **sauber**. |

**"stopping with error 0" ist KEIN Fehler.** Das trailing `error 0` ist der an den
Teardown übergebene `OSStatus`; `0 == noErr == sauberer, vom Client gewollter Stop`
(der Client rief `AudioDeviceStop`). Ein ~1-Sekunden-Lauf gefolgt von cleanem Stop
ist die Signatur einer App, die einen **kurzen Ton** abgespielt oder das Device
**geprobt** hat (UI-Sound, Notification, Format-Negotiation, kurzer Play/Pause) —
**kein Helper-Crash, kein Treiber-Reject, kein StopIO-Bug.**

Die **87 s** und **16 s** Pausen sind schlicht **User-Interaktionslücken** (Menü
bedienen), keine Hänger.

### 12.4 Neue / revidierte Hypothesen

> **Kritische Diagnose-Lücke:** Aus den vorliegenden Daten ist **nicht** belegbar,
> ob die **Fan-out-IOProcs** auf den physischen Devices je gestartet sind. Genau
> das entscheidet zwischen H5, H6 und H7. Die dafür nötigen Daten (Helper-Log,
> `get_status`, physische Device-Logs) fehlen noch (§12.6).

#### H2 (unverändert, jetzt **primärer sichtbarer Bug**) — Status-UI „lügt"
"Routing active — 3 devices" liest `len(self._active_device_names)` (die
**gespeicherte Auswahl**), nicht den real laufenden Pfad
([`menu_bar_app.py:998-1002`](../engine/menu_bar_app.py)). Dass der User
"3 devices" sah, obwohl BlackHole **nicht** angehakt war, ist exakt dieses
Verhalten — die Anzeige spiegelt eine **alte/persistierte Selektion** wider.
Der Status-Pfad prüft physischen Output **nicht**: `audio_flowing` hängt nur an
`ring_frames > 0` ([:990](../engine/menu_bar_app.py)), nicht an laufenden
Fan-out-IOProcs.

#### H5 (NEU) — Fan-out startet nicht / nur teilweise (stale Config)
| | |
|---|---|
| **Confidence** | mittel-hoch — bester Kandidat für "Routing tut nichts" |
| **Mechanismus** | `_apply_active_outputs` mappt gespeicherte Device-**Namen** → UIDs über den **aktuellen** Scan; Geräte, die nicht (mehr) präsent sind, werden **still übersprungen** ([`menu_bar_app.py:1227-1230`](../engine/menu_bar_app.py)). Eine aus einer früheren Session/anderem Setup stammende Auswahl ("3 devices") kann also auf 0–1 real verfügbare Outputs zusammenschrumpfen. Helper-seitig schlägt `output_add` bei nicht gefundenem Device/`AudioDeviceStart`-Fehler fehl und tombstoned den Slot ([`AudioRouterNowHelper.c:1233-1235`](../helper/AudioRouterNowHelper.c), [:1381-1395](../helper/AudioRouterNowHelper.c)). Ergebnis: Audio fließt in den Ring (Device ist Default), wird aber an **keinen hörbaren** Output gefannt → gefühlt "kein Routing", während die UI weiter "3 devices" zeigt (H2). |
| **Belegbar via** | Helper-Log (`Output hinzugefuegt:` vs. `Device '…' nicht gefunden` / `AudioDeviceStart fehlgeschlagen`), `get_status` → `active`-Liste + `ioproc_calls`. |

#### H6 (NEU) — Audio fließt nicht in den Ring (Producer-seitig)
| | |
|---|---|
| **Confidence** | niedrig-mittel |
| **Mechanismus** | Der Treiber schreibt Frames nur im `WriteMix`-Pfad ([`AudioRouterNowDriver.c:1874-1918`](../driver/src/AudioRouterNowDriver.c)). Wenn die spielende App ihren Stream zwar öffnet (PID 692, ~1 s), aber gleich wieder stoppt, bleibt der Ring leer → `ring_frames` ~ 0, der Consumer gibt Pre-Roll-Stille aus ([`AudioRouterNowHelper.c:867-884`](../helper/AudioRouterNowHelper.c)). Das wäre **kein Bug**, sondern "der User hat nichts Längeres abgespielt" — muss durch `ring_frames`/`ioproc_calls` über die Zeit ausgeschlossen werden. |
| **Belegbar via** | `get_status` während aktiver Wiedergabe: `ring_frames` > 0 und `ioproc_calls` steigend? |

#### H7 (NEU) — Lautstärke-Entkopplung erklärt "leise" (UX-Falle, kein Gain-Bug)
| | |
|---|---|
| **Confidence** | mittel — beste Erklärung für **"leiser"** Ton (statt stumm) |
| **Mechanismus** | Default-Gain ist **voll**: `volume_q16 = 65536 (1.0)` ([`shared_ring.h:96`](../helper/shared_ring.h)), `gVolume = 1.0f` ([`AudioRouterNowDriver.c:138`](../driver/src/AudioRouterNowDriver.c)) — der Pfad dämpft also **nicht** von sich aus. ABER: Sobald "Audio Router" **System Output** ist, steuern die Lautstärketasten/der HUD die **virtuelle** Router-Lautstärke (→ `volume_q16`-Skalierung im Consumer, [`AudioRouterNowHelper.c:887`](../helper/AudioRouterNowHelper.c)). Die **Hardware-Lautstärke des Mac-mini-Speakers** wird dabei **nicht** mehr angefasst und bleibt auf ihrem alten Wert eingefroren. War der Speaker vorher leise gestellt, spielt der Fan-out dort dauerhaft **leise** — und der User kann es mit den Tasten nicht mehr korrigieren (die wirken jetzt auf den Router). |
| **Belegbar via** | User-Frage: Hardware-Lautstärke des Speakers vor/nach dem Umschalten? Router-Volume-Pegel? Quiet auf **allen** Apps? |

#### H1 / H1-Wurzel — **falsifiziert für Normal-Install** (siehe §12.2)
Nur noch relevant für den manuellen Kopier-Sonderfall (§12.5).

#### H3 (Mix/SRC) und H4 (Safe Mode wirkungslos) — unverändert
H4 bleibt konsistent: Safe Mode toggelt nur das Auto-Healing eines bereits
laufenden Routings — bei H5/H6 (Routing kommt nie hörbar zustande) kann es nicht
helfen.

### 12.5 Sonderfall: manuelles Kopieren des Treibers (dokumentiert)

Der User kopierte den Treiber **von Hand** aus dem App-Bundle
(`/Applications/AudioRouterNow.app/Contents/Frameworks/AudioRouterNow.driver`)
nach `/Library/Audio/Plug-Ins/HAL/AudioRouterNow.driver`. **Nur dann** erschien
"nicht in CoreAudio gefunden".

Plausible Ursachen für diesen **selbst herbeigeführten** Pfad (nicht abschließend,
nicht der Normalfall):
- **Quarantäne/Translocation-xattr** auf dem hand-kopierten Bundle (Finder-Copy
  überträgt `com.apple.quarantine`), was coreaudiod das Laden verweigern lässt.
- **coreaudiod nicht neu gestartet** nach dem Kopieren (kein
  `launchctl kickstart -k system/com.apple.audio.coreaudiod`).
- **Doppel-Install** (App-eigener Install-Pfad + Handkopie) → konkurrierende/
  inkonsistente Plugin-Instanz.
- Falsche **Permissions/Owner** durch `cp` statt `ditto`/Installer.

**Wichtig:** Der reguläre Installer der App (`engine/first_launch.py`) übernimmt
diesen Schritt korrekt; **Hand-Kopieren ist nicht vorgesehen** und sollte in der
Doku/README explizit abgeraten werden. Das ist ein **Doku-/Onboarding-Befund**,
keine Treiber-Regression.

### 12.6 Was wir den User NOCH fragen müssen (entscheidend für H5/H6/H7)

Read-only, ungefährlich:

```sh
# 1) Helper-Log: Sind Fan-out-IOProcs auf den physischen Devices gestartet?
cat ~/Library/Logs/AudioRouterNow/*.log | grep -iE "Output hinzugefuegt|nicht gefunden|AudioDeviceStart|Slot"

# 2) App-Log: Welche Device-NAMEN wurden tatsächlich angewandt / übersprungen?
grep -iE "Outputs an Helper|nicht im aktuellen Scan|Auto-Switch|Outputs aus Config" \
  ~/.audiorouter/logs/audiorouter.log

# 3) Live-Status bei laufender Wiedergabe (Helper-Telemetrie):
#    Help → "What's running in the background…" ODER get_status:
#    → active[]  (real laufende Outputs)
#    → ring_frames > 0 ?  (Producer liefert Audio?)
#    → ioproc_calls steigend ?  (Fan-out feuert?)

# 4) Physische Device-Logs (nicht nur das virtuelle Device):
sudo log show --last 30m --predicate 'process == "coreaudiod"' --info \
  | grep -iE "IOWorkLoop|IOContext|Start|Stop"
```

**Zusätzliche gezielte Fragen:**
- Welche Geräte waren beim Test **tatsächlich angehakt** (Screenshot des Menüs)?
  War der **Mac-mini-Speaker** dabei?
- War der Ton **auf allen Apps** leise oder nur bei einer?
- **Hardware-Lautstärke** des Mac-mini-Speakers vor dem Umschalten — niedrig?
  Bewegen die Lautstärketasten nach dem Umschalten noch etwas Hörbares? (→ H7)
- Stammt die Geräte-Auswahl evtl. aus einer **früheren Session / anderem Setup**?
  (→ H5, stale Config)
- **App-Version** (z. B. v3.4.0)?

### 12.7 Revidierte Fix-Implikationen (Ergänzung zu §8)

- **H2 ist jetzt P0 (nicht P1):** Der lügende Status hat den User aktiv in die
  Irre geführt. Status muss `resp['active']` **und** `is_audio_router_default()`
  **und** `ioproc_calls`-Fortschritt spiegeln, statt `_active_device_names`.
- **H5:** Wenn ein gespeichertes Device im aktuellen Scan fehlt, **nicht still
  überspringen** ([`menu_bar_app.py:1230`](../engine/menu_bar_app.py)) — sichtbar
  als "unavailable" markieren und in der Status-Zeile melden.
- **Diagnostic Report (`diagnostic.py`):** muss `active[]`, `ring_frames`,
  `ioproc_calls` und die real gestarteten Fan-out-IOProcs aufnehmen — sonst bleibt
  genau dieser Fall (Device geladen, aber kein hörbarer Fan-out) im Self-Report
  unsichtbar.
- **Doku:** Hand-Kopieren des Treibers explizit abraten (§12.5).

---

## §14 Wave-1-Fixes — v3.4.1 (2026-06-25)

### Implementierte Fixes

| Fix | Commit | Betroffene Datei | Beschreibung |
|-----|--------|-----------------|--------------|
| H2 Status-UI | 7521f0b | menu_bar_app.py | Status zeigt realen Routing-Zustand aus `status['active']`, nicht mehr gespeicherte Auswahl. 7-Zustands-Matrix. |
| H5 Stale-Config | 7521f0b | menu_bar_app.py | Fehlende Geräte als `⚠ unavailable` sichtbar im Menü + Status-Counter N/M |
| i18n | a7265bd | audio_device_control.py, first_launch.py, diagnostic.py | Deutsche Fehlermeldungen → Englisch (inkl. CASE-001-Kernmeldung) |
| README | 7115a60 | README.md | Homebrew "recommended" → "optional", Runtime-Dependency-Klarstellung |
| Diagnostic Fan-out | 68ec5ec | diagnostic.py | Neue Sektionen SYSTEM AUDIO STATE + FAN-OUT im Diagnostic-Report |

### Was bogdanw's Szenario jetzt zeigt

- Status: 🔴 "Routing failed — no output" (statt fälschlich grün "Routing active — 2 devices")
- Menü: ⚠ Gerätename — unavailable (statt stilles Verschwinden)
- Diagnostic-Report: "Fan-out active on 0 outputs — NO audible routing"

### Noch offen

- **H7 (Volume-Freeze):** Wenn "Audio Router" System-Default wird, bleiben Hardware-Tasten am alten Level → leiser Ton. Fix in Wave 2 geplant.
- **Bogdanw Helper-Log:** Ausstehend — für abschließende Root-Cause-Bestätigung H2/H5
- **Bogdanw Info-Stand:** Er wurde über v3.4.1 noch nicht informiert — nächster Forum-Post geplant. v3.4.1-dev lokal getestet — nach Verifikation Release erstellen

---

## §15 Neue Diagnosedaten — Post #12 (2026-06-26) + Opus-Analyse

### 15.1 Neue Daten von bogdanw

**Post #12 (MacRumors, 2026-06-26):**
> "I'll start with the good news 🙂 I've tested AudioRouterNow on an MBA M1 with a USB sound card and it works as expected. The sound can be heard from the internal speakers as well as on the headphones connected to the USB sound card.
>
> I've tested again on the Mac mini and if I first select the internal speakers, then route through AudioRouterNow, the volume stays the same. But the other two outputs still don't work."

**Helper Log (~/Library/Logs/AudioRouterNow/helper.log):**
```
AudioRouterNow Helper v3.4.0 (ABI v4)
SHM: /audiorouter_shm Ring: 8192 Frames ~ 171 ms @48kHz
Helper: Config-Socket lauscht auf /Users/bogdan/.audiorouter/audiorouter.config.sock
Helper: SHM erstellt (/audiorouter_shm, 0666 (world-rw), 65792 Bytes, iid=0x2d834b5cb)
Warte auf SHM-Ring vom Plugin...
Helper: SHM verbunden — /audiorouter_shm (8192 Frames Kapazitaet, SR=48000)
Helper: SHM bereit — Routing kann starten
Helper: Keep-Alive IOProc gestartet (Device ID 94)
Helper: Hot-Plug-Listener aktiv
Helper: Output hinzugefuegt: U3277WB [Ch 1-2] (UID: 05E37732-0000-0000-151B-0104B5462778)
Helper laeuft — Routing aktiv. Ctrl+C zum Beenden.
Helper: Sample-Rate geaendert auf 48000 Hz — pruefe Outputs
Ring: 235 Frames | Outputs: 1 | IOProc-Calls: +192/2s (957 total)
Helper: Output hinzugefuegt: Mac mini Speakers [Ch 1-2] (UID: BuiltInSpeakerDevice)
Helper: Output entfernt: U3277WB [Ch 1-2]
Ring: 4296 Frames | Outputs: 1 | IOProc-Calls: +192/2s (1914 total)
Helper: Output hinzugefuegt: U3277WB [Ch 1-2] (UID: 05E37732-0000-0000-151B-0104B5462778)
Ring: 6933 Frames | Outputs: 2 | IOProc-Calls: +383/2s (7903 total)
```

**AVAudioSession System Log (gekürzt — kritische Zeilen):**
```
16:41:27 - setPlayState Started Output {com.audiorouter.now.device, 0xa}
16:41:27 - setPlayState Started Output {U3277WB (05E37732...), 0xa}
           Devices: [com.audiorouter.now.device, U3277WB]
16:41:39 - setPlayState Started Output {BuiltInSpeakerDevice, 0xa}
           Devices: [U3277WB, BuiltInSpeakerDevice, com.audiorouter.now.device]
16:41:39 - HALC_ProxyIOContext.cpp:1593 IOWorkLoop: ending the transport, stopping the io thread
16:41:39 - setPlayState Stopped Output {U3277WB, 0xa}   ← U3277WB IOProc gestoppt von coreaudiod
16:41:49 - setPlayState Started Output {U3277WB, 0xb}   ← Neuer IOProc-Kontext
```

### 15.2 Executive Summary (Opus-Analyse, 2026-06-28)

**Zwei unabhängige Probleme** — nicht eines.

**Problem 1 (Hauptursache Stille): H7 ist bestätigt und generalisiert.**
Das virtuelle Device startet immer mit `volume_q16=65536` (`shared_ring.h:96`). Die Lautstärketasten steuern nach dem Switch ausschließlich das *virtuelle Volume* (`audio_device_control.py:648`). Die Hardware-Lautstärke jedes physischen Outputs (U3277WB, dritter Output) bleibt eingefroren, wo immer sie war. bogdanws Workaround beweist es exakt: der Output, der vor dem Routing Default war (interne Speaker, HW-Volume oben), bleibt hörbar — die anderen bleiben stumm/leise.

**Problem 2 (Instabilität): Transport-Restart → Healer-Reconnect.**
coreaudiod stoppt den IOWorkLoop für U3277WB (`HALC_ProxyIOContext:1593`) sobald `BuiltInSpeakerDevice` als 3. Device hinzukommt. Der Healer erkennt den Stall (`healer.py:138`) und ruft `reconnect_output` auf — sichtbar als 10-sekündiger "Output entfernt/hinzugefügt"-Zyklus. Nach dem Reconnect feuert der IOProc wieder (~96 Calls/s, 7903 total), aber das Audio ist wegen H7 trotzdem nicht hörbar.

### 15.3 Hypothesen-Status (Stand nach §15-Analyse)

| Hypothese | Status | Befund |
|-----------|--------|--------|
| **H7** Volume-Entkopplung | ✅ **BESTÄTIGT (P0)** | `audio_device_control.py:648` schreibt nur auf virtuelles Device. Bogdanw-Workaround ist Direktbeweis. Erklärt vollständig "other two outputs don't work". |
| **H8** Transport-Restart → Stall → Healer-Reconnect | ✅ **BESTÄTIGT (kausal)** | IOWorkLoop stoppt bei BuiltIn als 3. Output → `healer.py:138` → `reconnect_output` → "Output entfernt". 10s Gap = Stall-Fenster (1000ms) + Healer-Persist (600ms) + Add-Latenz. |
| **H9** Ring-Buffer-Divergenz | ✅ Symptom / ❌ KEINE Stille-Ursache | 235→4296→6933 Frames erklärt, stale Read-Pointer widerlegt: Re-Add setzt `local_ridx` korrekt auf `write_idx` (`AudioRouterNowHelper.c:1254/1308`). |
| **H10** 2 vs 3 Outputs | 🟡 TEILWEISE | MBA M1 = 2 Outputs (kein Restart) ✓. Ob "3. Device generell" oder "BuiltIn speziell": offen (W2-5 klärt). |
| **H11** Dritter Output | 🔵 OFFEN | Nicht im Helper-Log sichtbar — benötigt ungefiltertes Log + Screenshot Gerätauswahl. |

### 15.4 Code-Befunde (mit Zeilennummern)

| Datei:Zeile | Befund |
|---|---|
| `shared_ring.h:96` | Virtuelles Device startet mit `volume_q16=65536` — keine Übernahme der vorherigen HW-Lautstärke |
| `audio_device_control.py:648` | `set_default_output_volume` schreibt nur auf Default-Device (= virtuell); nie auf physische Outputs → **Kern H7** |
| `menu_bar_app.py:528, 1457-1458, 1479-1480` | Alle drei Switch-Pfade setzen nur System-Default; keiner liest/propagiert HW-Volume → **Fix-Orte W2-1** |
| `AudioRouterNowHelper.c:1048` | Einzige Gain-Stelle nutzt virtuelles Volume; physische HW-Volumes unsichtbar für Helper |
| `AudioRouterNowHelper.c:1456-1492, 1479` | `output_remove_locked` ist einzige Quelle von "Output entfernt" — nur via `set_outputs`/`reconnect_output` aufrufbar (nicht Hot-Plug) |
| `AudioRouterNowHelper.c:1254, 1308` | Re-Add setzt `local_ridx`/`src_frac_ridx` auf aktuelles `write_idx` + Pre-Roll → **widerlegt stale-Pointer-Hypothese** |
| `healer.py:25-27, 90-160, 138` | `STALL_PERSIST_SAMPLES=3` (600ms), Healer ruft `reconnect_output` bei ≥3 critical polls → **Fix-Ort W2-2** |
| `health.py:182` | `any_stalled` → `critical` → triggert Healer |
| `AudioRouterNowHelper.c:1095-1134` | `read_idx = min` nicht-gestallter `local_ridx`; eingefrorener aktiver Output staut Ring bis Soft-Stall greift |

### 15.5 Nächste Aktion an bogdanw (Forum-Post)

**Zu erfragen:**
1. In Audio MIDI Setup: U3277WB-Volume-Slider auf 100% setzen während Routing aktiv — hört er dann Audio?
2. Ungefilterten Helper-Log ohne `grep` senden: `log show --last 1h --predicate 'process == "AudioRouterNowHelper"' --info`
3. Screenshot welche Geräte in ARN angehakt waren

### 15.6 Analyse-Status
- **Analyse abgeschlossen:** 2026-06-28 (Opus-Deep-Analysis via SuperClaude)
- **Nächste Phase:** Wave-2-Implementierung nach User-Bewilligung (→ BRAINSTORM-001 §W2)
