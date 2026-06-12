# PLAN.md — Stability Hardening: System-Freeze & Deadlock Remediation

| Feld | Wert |
|------|------|
| **Projekt** | AudioRouterNow (macOS CoreAudio HAL-Plugin + Helper-Daemon + Python-Engine) |
| **Datum** | 2026-06-03 (erstellt) · 2026-06-12 (abgeschlossen) |
| **Version** | Plan v1.0 → **v1.1 (Abschluss-Update)** |
| **Status** | ✅ **ABGESCHLOSSEN** — alle P0/P1/P2-Fixes implementiert, v3.4.0 live und per Runtime-Audit verifiziert |
| **Kritikalität** | ~~P0 — Hard Reboot / System Freeze~~ → behoben seit v3.4.0 |
| **Betroffene Plattform** | macOS Sequoia (15.x) / macOS 26, Apple Silicon + Intel (Universal Binary) |
| **Scope** | `driver/src/AudioRouterNowDriver.c`, `helper/AudioRouterNowHelper.c`, `engine/helper_client.py` |
| **Verbindlich** | Fix-Reihenfolge ist FIXIERT. Nicht umsortieren. Checkpoint nach Fix-04 ist Pflicht. |

> **Abschluss-Hinweis (12.06.2026):** Fix-08 (coreaudiod CPU-Watchdog) wurde **gestrichen** —
> siehe §3 Fix-08 für Begründung. Alle anderen Fixes sind implementiert und durch einen
> Fable-Agent Runtime-Audit auf dem Live-System bestätigt (0 Zombies, 0 Underruns, SHM 0666,
> IOProc-Clock stabil, version=3.4.0). PLAN.md dient ab jetzt als historisches Referenzdokument.

---

## 1. Executive Summary

Ein Deep Audit hat eine zusammenhängende Kette von Stabilitätsfehlern aufgedeckt, die in
einem **kompletten System-Freeze mit erzwungenem Hard Reboot** kulminieren. Der Defektpfad
ist kausal verkettet, nicht zufällig:

1. **Root Cause (P0-C):** Der HAL-Treiber liefert in `ARN_GetZeroTimeStamp()` einen
   katastrophal falschen `ticksPerFrame`-Fallback (`1.0`), wenn `coreaudiod` die Methode
   **vor** `ARN_Initialize()` aufruft (Race beim Plugin-Laden unter Sequoia). Ein Mach-Tick
   ist ≈ 41,6 ns, der korrekte Wert bei 48 kHz ist ≈ 20.833.333 ns/Frame — also Faktor
   **~500.000 daneben**. `coreaudiod` interpretiert das als sofort fällige Anker und geht in
   einen **busy-wait Spin → 100 % CPU dauerhaft**.

2. **Amplifikation (P0-B, P0-A, P2-A):** Sobald `coreaudiod` spinnt, blockieren alle
   Mach-IPC-Calls an `coreaudiod`. Der Helper hält jedoch `g_outputs_lock` **während**
   `AudioDeviceCreateIOProcID()`, `AudioDeviceStart()` und `usleep()`-Schleifen. Diese
   Calls kehren nie zurück → der Lock wird **ewig** gehalten → jeder andere Thread, der
   `g_outputs_lock` braucht (Volume-Poll, Config-Socket, Hotplug, SR-Reinit), hängt.

3. **UI-Tod (P1-B, P1-C):** Die Python-Engine pollt `get_status()` vom Main-Thread mit
   10 s Read-Timeout und hält `self._lock` in `ensure_running()` bis zu 25 s. Wenn der
   Helper hängt, friert die UI ebenfalls ein — der Nutzer kann nicht einmal sauber beenden.

4. **Kein Rettungsanker (P0-D):** Es existiert **kein Watchdog**, der den CPU-Spin von
   `coreaudiod` erkennt und den Treiber entlädt. Die einzige bisher bekannte Lösung war
   der Hard Reboot.

**Strategie:** Zuerst die Root Cause beseitigen (Fix-01), dann jeden Lock-unter-Mach-IPC-
Pfad auflösen (Fix-02 bis Fix-05), dann die Python-Seite entkoppeln (Fix-06, Fix-07), und
schließlich ein Safety-Net (Watchdog, Fix-08) einziehen, das selbst bei Restdefekten einen
Hard Reboot verhindert.

> **Update 12.06.2026:** Fix-08 wurde **nicht implementiert und gestrichen** (siehe §3
> Fix-08). P0-D ist stattdessen durch I-2 (frei laufende `mach_absolute_time()`-Clock in
> `GetZeroTimeStamp`) strukturell gelöst — der CPU-Spin kann nicht mehr entstehen.

---

## 2. Dependency-Graph

```
                          ┌─────────────────────────────────────────┐
                          │  Fix-01  P0-C  (ROOT CAUSE)              │
                          │  ARN_GetZeroTimeStamp ticksPerFrame      │
                          │  driver/src/AudioRouterNowDriver.c       │
                          └───────────────┬─────────────────────────┘
                                          │ beseitigt den CPU-Spin,
                                          │ der alle Mach-IPC-Calls blockiert
                                          ▼
        ┌─────────────────────────────────────────────────────────────────┐
        │  Lock-unter-Mach-IPC Auflösung (jeder Pfad einzeln)               │
        │                                                                   │
        │   Fix-02  P0-B   output_add() Phase 3                             │
        │   Fix-03  P0-A.1 sr_reinit caller (volume_poll_thread)            │
        │   Fix-04  P0-A.2 sr_reinit_all_outputs Inneres                    │
        │                                                                   │
        │   Fix-03 MUSS vor Fix-04: erst Lock vom Caller lösen,             │
        │   dann darf das Innere lockfrei CoreAudio aufrufen.               │
        └───────────────────────────────┬─────────────────────────────────┘
                                         ▼
                       ╔═══════════════════════════════╗
                       ║   CHECKPOINT  (Pflicht)       ║
                       ║   Build + Smoke Test          ║
                       ║   → P0-Kette muss tot sein    ║
                       ╚═══════════════┬═══════════════╝
                                       ▼
        ┌─────────────────────────────────────────────────────────────────┐
        │   Fix-05  P2-A  process_hotplug_removals() Lock-Scope             │
        │            (gleiches Muster wie Fix-02, niedrigere Frequenz)      │
        └───────────────────────────────┬─────────────────────────────────┘
                                         ▼
        ┌─────────────────────────────────────────────────────────────────┐
        │   Python-Entkopplung (unabhängig von C-Fixes, aber nach P0)      │
        │   Fix-06  P1-B  READ_TIMEOUT + Main-Thread-safe get_status       │
        │   Fix-07  P1-C  ensure_running() Lock-Scope                       │
        └───────────────────────────────┬─────────────────────────────────┘
                                         ▼
        ┌─────────────────────────────────────────────────────────────────┐
        │   Fix-08  P0-D  coreaudiod CPU-Watchdog im Helper                │
        │   ✗ GESTRICHEN — superseded durch I-2 (Clock-Fix)               │
        │   proc_pid_rusage selbst blockiert bei degradiertem coreaudiod   │
        └───────────────────────────────────────────────────────────────────┘
```

**Abhängigkeits-Regeln:**

- **Fix-01 zuerst, immer.** Ohne diesen Fix sind alle anderen nur Symptombehandlung.
- **Fix-03 vor Fix-04.** Der Caller muss den Lock loslassen, bevor das Innere lockfrei
  CoreAudio aufrufen darf. Würde man Fix-04 zuerst machen, liefe `sr_reinit_all_outputs()`
  ohne Lock, während der Caller ihn noch hält → Doppellogik, Data-Race auf `g_outputs[]`.
- **Fix-05, Fix-06, Fix-07, Fix-08** sind voneinander unabhängig, MÜSSEN aber nach dem
  Checkpoint kommen.

---

## 3. Fix-Sequenz

> **Konvention für alle Code-Blöcke:** „Aktueller Code" = exakt der Stand im Repo (Zeilen
> verifiziert am 2026-06-03). „Neuer Code" = vollständiger Ersatz, **kein Pseudocode**.
> Zeilennummern können nach vorhergehenden Fixes leicht driften — immer am umgebenden
> Kontext (Kommentar-Anker) orientieren, nicht blind an der Zeilennummer.

---

### Fix-01 — P0-C: `ARN_GetZeroTimeStamp` ticksPerFrame-Fallback

**Priorität:** P0 (höchste — Root Cause)
**Datei:** `driver/src/AudioRouterNowDriver.c`
**Zeilen:** 1746–1751

**Problem:**
Wenn `gHostTicksPerFrameBits == 0` (gesetzt erst in `ARN_Initialize`, das `coreaudiod`
unter Sequoia teilweise NACH dem ersten `GetZeroTimeStamp`-Aufruf ruft), fällt der Code auf
`ticksPerFrame = 1.0` zurück. Damit wird `*outHostTime` um Faktor ~500.000 zu klein
berechnet, alle Timestamps liegen quasi „in der Vergangenheit" → `coreaudiod` busy-wait
Spin → 100 % CPU → Freeze. Der Fallback muss stattdessen den **physikalisch korrekten** Wert
aus der Mach-Timebase und der bekannten Default-Sample-Rate (`kDefaultSampleRate = 48000.0`,
Zeile 63) rekonstruieren — exakt wie `ARN_Initialize` ihn berechnet (Zeile 609–613).

**Betroffener Kontext (umgebende Symbole):**
- `kDefaultSampleRate` = `48000.0` (Zeile 63)
- Initialisierung: `_f64_to_u64((1.0e9 / gSampleRate) / nanosPerTick)` (Zeile 612–613)

**Aktueller Code (1745–1751):**
```c
    /* Kein Mutex im RT-Pfad — atomic_load verhindert Priority-Inversion. */
    Float64 ticksPerFrame = _u64_to_f64(
        atomic_load_explicit(&gHostTicksPerFrameBits, memory_order_relaxed)
    );
    if (ticksPerFrame <= 0.0) {
        ticksPerFrame = 1.0;
    }
```

**Neuer Code (1745–1762):**
```c
    /* Kein Mutex im RT-Pfad — atomic_load verhindert Priority-Inversion. */
    Float64 ticksPerFrame = _u64_to_f64(
        atomic_load_explicit(&gHostTicksPerFrameBits, memory_order_relaxed)
    );
    if (!(ticksPerFrame > 0.0) || !isfinite(ticksPerFrame)) {
        /* P0-C FIX: gHostTicksPerFrameBits ist 0 (oder NaN/Inf), weil coreaudiod
         * GetZeroTimeStamp VOR ARN_Initialize aufgerufen hat (Race beim Plugin-Laden
         * unter macOS Sequoia/26). Der frühere Fallback 1.0 ergab Host-Timestamps um
         * Faktor ~500.000 zu klein → coreaudiod busy-wait Spin → 100% CPU → Freeze.
         *
         * Statt 1.0 rekonstruieren wir den physikalisch korrekten Wert aus der
         * Mach-Timebase und der Default-Sample-Rate (identisch zur Berechnung in
         * ARN_Initialize). mach_timebase_info ist im RT-Pfad sicher: konstant,
         * sperrfrei, ohne Mach-IPC. */
        struct mach_timebase_info tb;
        mach_timebase_info(&tb);
        Float64 nanosPerTick = (Float64)tb.numer / (Float64)tb.denom;
        if (nanosPerTick <= 0.0) nanosPerTick = 1.0;  /* Defensive: nie /0 */
        ticksPerFrame = (1.0e9 / kDefaultSampleRate) / nanosPerTick;

        /* Den korrigierten Wert publizieren, damit nachfolgende Calls (und ein evtl.
         * verspätetes ARN_Initialize, das ihn überschreibt) konsistent bleiben. Nur
         * setzen wenn weiterhin 0 — kein Überschreiben eines bereits gültigen Werts. */
        UInt64 expected = 0;
        atomic_compare_exchange_strong_explicit(
            &gHostTicksPerFrameBits, &expected, _f64_to_u64(ticksPerFrame),
            memory_order_relaxed, memory_order_relaxed);
    }
```

**Voraussetzung / Include-Check:**
`isfinite()` benötigt `<math.h>`. Prüfen ob bereits inkludiert; falls nicht, oben im Datei-
Header ergänzen:
```c
#include <math.h>
```
`mach_timebase_info` und `struct mach_timebase_info` kommen aus `<mach/mach_time.h>` — im
Treiber bereits genutzt (siehe Zeile 609), daher vorhanden.

**Test-Kriterium:**
1. Treiber bauen, installieren, `coreaudiod` neu laden.
2. AudioRouterNow als Output wählen, Audio abspielen.
3. **Erfolgskriterium:** `coreaudiod`-CPU bleibt im einstelligen Prozentbereich (Activity
   Monitor / `top -pid $(pgrep coreaudiod)`). Vor dem Fix: 100 %+ und dauerhaft.
4. Race gezielt provozieren: Helper stoppen, `sudo killall coreaudiod` (lädt Plugin neu,
   GetZeroTimeStamp läuft vor Initialize). CPU muss niedrig bleiben.
5. Audio läuft ohne Pitch-Shift / Drift (falsche ticksPerFrame würde sich als Tonhöhen-
   Fehler äußern).

**Risiken / Nebenwirkungen:**
- `mach_timebase_info` im RT-Pfad: unkritisch, da rein rechnerisch, sperrfrei, kein IPC.
  Auf Apple Silicon ist `tb.numer/tb.denom` meist 125/3 → konstant.
- Der Fallback nimmt 48 kHz an. Läuft das Gerät real auf einer anderen Rate BEVOR
  `ARN_Initialize` lief, ist der Wert minimal daneben — aber um Größenordnungen näher als
  `1.0` und nur für die kurze Race-Phase aktiv, bis `ARN_Initialize` den exakten Wert
  schreibt. Akzeptabel und ungefährlich.
- `compare_exchange` mit `expected=0`: schreibt nur wenn noch ungesetzt → kein Überschreiben
  eines bereits korrekten Werts durch einen späten Initialize.

**Commit-Message Template:**
```
fix(driver): P0-C — korrekter ticksPerFrame-Fallback in GetZeroTimeStamp

coreaudiod ruft GetZeroTimeStamp unter Sequoia teils VOR ARN_Initialize auf.
Der Fallback ticksPerFrame=1.0 ergab Host-Timestamps Faktor ~500.000 zu klein
→ coreaudiod busy-wait Spin → 100% CPU → System-Freeze.

Fallback rekonstruiert jetzt den physikalisch korrekten Wert aus Mach-Timebase
und kDefaultSampleRate (identisch zu ARN_Initialize) und publiziert ihn per CAS.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

---

### Fix-02 — P0-B: `output_add()` Phase 3 Lock-Scope

**Priorität:** P0
**Datei:** `helper/AudioRouterNowHelper.c`
**Zeilen:** 1139–1192 (Phase-3-Block in `output_add`)

**Problem:**
`g_outputs_lock` wird während `AudioDeviceCreateIOProcID()`, der `usleep(100ms)`-Retry-
Schleife **und** `AudioDeviceStart()` gehalten. Alle drei sind Mach-IPC-Calls an
`coreaudiod`. Wenn `coreaudiod` blockiert/spinnt, kehren sie nie zurück → Lock ewig
gehalten → Volume-Thread, Config-Socket und Hotplug hängen. Das ist der Deadlock, der beim
Device-Auswählen triggert.

**Lösung:**
Slot wird unter Lock committet (stabile Heap-Adresse), aber `proc_id`/`active` werden NICHT
unter Lock erzeugt. Der Slot wird sofort als „pending" markiert (`active=false`), der Lock
freigegeben, dann die CoreAudio-Calls lockfrei mit der stabilen Slot-Adresse ausgeführt.
Erst ganz am Ende wird `active` unter einem **kurzen** Lock gesetzt (oder bei Fehler der
Slot zurückgerollt). Da der Slot bereits committet ist und `active=false` hat, überspringt
der Volume-Thread ihn korrekt (siehe Kommentar Zeile 1300: „active noch false → Volume-Thread
überspringt").

> **Wichtig zur Slot-Stabilität:** `g_outputs` ist ein statisches Array; die Slot-Adresse
> `&g_outputs[idx]` bleibt stabil, solange kein anderer Thread `g_n_outputs` verschiebt
> oder den Slot per Swap-Remove (Zeile 1552–1556) verlagert. Da das Slot bereits committet
> ist (`g_n_outputs++` erfolgte unter Lock) und `output_add` nicht reentrant für dieselbe
> UID ist, ist die Adresse für die lockfreie Phase stabil. Beim Re-Lock am Ende wird die
> Slot-Identität über die UID re-validiert.

**Aktueller Code (1139–1192):**
```c
    /* ── Phase 3: Commit unter Lock, dann IOProc-Create mit stabiler Adresse ── */
    pthread_mutex_lock(&g_outputs_lock);

    /* Race-Re-Check: kam in Phase 2 ein Duplikat rein oder ist Kapazitaet voll? */
    if (find_output_slot_locked(uid, ch_offset) >= 0) {
        pthread_mutex_unlock(&g_outputs_lock);
        fprintf(stdout, "Helper: '%s' wurde in Phase 2 bereits hinzugefuegt\n", uid);
        return 0;
    }
    if (g_n_outputs >= MAX_OUTPUTS) {
        pthread_mutex_unlock(&g_outputs_lock);
        fprintf(stderr, "Helper: MAX_OUTPUTS voll nach Race in Phase 2\n");
        return -1;
    }

    /* Slot committen (stabile Heap-Adresse) */
    DeviceOutput *slot = &g_outputs[g_n_outputs];
    *slot = tmp;
    slot->active  = false;  /* noch nicht aktiv bis IOProc gestartet */
    g_n_outputs++;

    /* AudioDeviceCreateIOProcID + Start MIT stabiler slot-Adresse, unter Lock.
     * Lock-Hold hier kurz (<20ms wenn Device bereit nach Settle in Phase 2). */
    OSStatus err = kAudioHardwareNotRunningError;
    for (int attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) usleep(100000);  /* 100ms Retry-Pause (kuerzer als vorher) */
        err = AudioDeviceCreateIOProcID(dev_id, device_ioproc, slot, &slot->proc_id);
        if (err == noErr) break;
        fprintf(stderr, "Helper: AudioDeviceCreateIOProcID Versuch %d/3 (OSStatus %d) fuer '%s'\n",
                attempt + 1, (int)err, uid);
        slot->proc_id = NULL;
    }
    if (err != noErr) {
        fprintf(stderr, "Helper: AudioDeviceCreateIOProcID endgueltig fehlgeschlagen fuer '%s'\n", uid);
        /* Slot zurückrollen */
        g_n_outputs--;
        memset(slot, 0, sizeof(DeviceOutput));
        pthread_mutex_unlock(&g_outputs_lock);
        return -1;
    }

    err = AudioDeviceStart(dev_id, slot->proc_id);
    if (err != noErr) {
        fprintf(stderr, "Helper: AudioDeviceStart fehlgeschlagen (OSStatus %d) fuer '%s'\n",
                (int)err, uid);
        AudioDeviceDestroyIOProcID(dev_id, slot->proc_id);
        g_n_outputs--;
        memset(slot, 0, sizeof(DeviceOutput));
        pthread_mutex_unlock(&g_outputs_lock);
        return -1;
    }

    slot->active = true;
    pthread_mutex_unlock(&g_outputs_lock);
```

**Neuer Code (1139–1192 Ersatz):**
```c
    /* ── Phase 3a: Slot unter Lock committen (KURZ), kein CoreAudio-Call ── */
    pthread_mutex_lock(&g_outputs_lock);

    /* Race-Re-Check: kam in Phase 2 ein Duplikat rein oder ist Kapazitaet voll? */
    if (find_output_slot_locked(uid, ch_offset) >= 0) {
        pthread_mutex_unlock(&g_outputs_lock);
        fprintf(stdout, "Helper: '%s' wurde in Phase 2 bereits hinzugefuegt\n", uid);
        return 0;
    }
    if (g_n_outputs >= MAX_OUTPUTS) {
        pthread_mutex_unlock(&g_outputs_lock);
        fprintf(stderr, "Helper: MAX_OUTPUTS voll nach Race in Phase 2\n");
        return -1;
    }

    /* Slot committen (stabile Array-Adresse). active=false → der Volume-Thread
     * ueberspringt diesen Slot, bis wir ihn nach erfolgreichem Start aktivieren. */
    int slot_idx = g_n_outputs;
    DeviceOutput *slot = &g_outputs[slot_idx];
    *slot = tmp;
    slot->active  = false;
    slot->proc_id = NULL;
    g_n_outputs++;

    /* P0-B FIX: Lock VOR den CoreAudio-Mach-IPC-Calls freigeben. Frueher liefen
     * AudioDeviceCreateIOProcID + usleep-Retry + AudioDeviceStart UNTER g_outputs_lock.
     * Bei blockierendem/spinnendem coreaudiod kehrten diese nie zurueck → Lock ewig
     * gehalten → Volume-Thread + Config-Socket + Hotplug haengen (Deadlock). */
    pthread_mutex_unlock(&g_outputs_lock);

    /* ── Phase 3b: CoreAudio OHNE Lock — slot-Adresse ist stabil (committet) ── */
    AudioDeviceIOProcID local_proc = NULL;
    OSStatus err = kAudioHardwareNotRunningError;
    for (int attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) usleep(100000);  /* 100ms Retry-Pause — jetzt OHNE Lock */
        err = AudioDeviceCreateIOProcID(dev_id, device_ioproc, slot, &local_proc);
        if (err == noErr) break;
        fprintf(stderr, "Helper: AudioDeviceCreateIOProcID Versuch %d/3 (OSStatus %d) fuer '%s'\n",
                attempt + 1, (int)err, uid);
        local_proc = NULL;
    }
    if (err == noErr) {
        err = AudioDeviceStart(dev_id, local_proc);
        if (err != noErr) {
            fprintf(stderr, "Helper: AudioDeviceStart fehlgeschlagen (OSStatus %d) fuer '%s'\n",
                    (int)err, uid);
            AudioDeviceDestroyIOProcID(dev_id, local_proc);
            local_proc = NULL;
        }
    } else {
        fprintf(stderr, "Helper: AudioDeviceCreateIOProcID endgueltig fehlgeschlagen fuer '%s'\n", uid);
    }

    /* ── Phase 3c: Ergebnis unter KURZEM Lock committen oder Slot zurueckrollen ── */
    pthread_mutex_lock(&g_outputs_lock);
    /* Slot per UID re-validieren — ein paralleler Swap-Remove (Hotplug) koennte den
     * Index verschoben haben, waehrend wir lockfrei in CoreAudio waren. */
    int idx = find_output_slot_locked(uid, ch_offset);
    if (idx < 0) {
        /* Slot wurde waehrenddessen entfernt (z.B. Device verschwunden). IOProc,
         * den wir evtl. erzeugt haben, sauber abbauen — OHNE Lock zu halten. */
        pthread_mutex_unlock(&g_outputs_lock);
        if (local_proc) {
            AudioDeviceStop(dev_id, local_proc);
            AudioDeviceDestroyIOProcID(dev_id, local_proc);
        }
        fprintf(stdout, "Helper: Slot '%s' verschwand waehrend IOProc-Start — verworfen\n", uid);
        return (err == noErr) ? 0 : -1;
    }
    slot = &g_outputs[idx];  /* re-validierte Adresse */
    if (err != noErr) {
        /* Start fehlgeschlagen → Slot zurueckrollen (Swap-Remove-konform). */
        if (idx != g_n_outputs - 1) {
            g_outputs[idx] = g_outputs[g_n_outputs - 1];
        }
        memset(&g_outputs[g_n_outputs - 1], 0, sizeof(DeviceOutput));
        g_n_outputs--;
        pthread_mutex_unlock(&g_outputs_lock);
        return -1;
    }
    slot->proc_id = local_proc;
    slot->active  = true;
    pthread_mutex_unlock(&g_outputs_lock);
```

**Test-Kriterium:**
1. Helper bauen, starten. Output-Gerät auswählen (`set_outputs`).
2. Während der Auswahl `coreaudiod` künstlich verlangsamen ist schwer — stattdessen:
   ein USB-Interface mit langsamem SR-Settle nehmen und prüfen, dass parallele
   `get_status`-Polls **nicht** blockieren (UI bleibt responsiv).
3. `pthread`-Trace / Logs: `g_outputs_lock` darf nie länger als wenige ms gehalten werden
   (kein `usleep`/CoreAudio mehr unter Lock).
4. Funktional: Audio kommt am gewählten Gerät an, korrekter Kanal-Offset.
5. Stress: 10× schnelles Hinzufügen/Entfernen desselben Geräts → kein Crash, kein Leak
   (Activity Monitor IOProc-Count stabil).

**Risiken / Nebenwirkungen:**
- **Slot-Verschiebung durch Swap-Remove:** Adressiert durch UID-Re-Validierung in Phase 3c.
- **IOProc auf entferntem Slot:** Sauber abgebaut, kein Leak.
- Sehr kurzes Fenster, in dem ein committeter Slot `active=false, proc_id=NULL` hat — der
  Volume-Thread überspringt ihn (durch `active==false`), kein RT-Risiko.

**Commit-Message Template:**
```
fix(helper): P0-B — output_add CoreAudio-Calls ausserhalb g_outputs_lock

AudioDeviceCreateIOProcID + usleep-Retry + AudioDeviceStart liefen unter
g_outputs_lock. Bei blockierendem coreaudiod (P0-C) → Lock ewig → Deadlock.

3-Phasen-Refactor: Slot committen (kurz, Lock), CoreAudio lockfrei, Ergebnis
unter kurzem Lock per UID re-validiert committen oder zurueckrollen.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

---

### Fix-03 — P0-A Teil 1: SR-Reinit Caller Lock-Scope im `volume_poll_thread`

**Priorität:** P0
**Datei:** `helper/AudioRouterNowHelper.c`
**Zeilen:** 1841–1844 (Caller in `volume_poll_thread`)

**Problem:**
Der Caller hält `g_outputs_lock` über den **kompletten** Aufruf von
`sr_reinit_all_outputs()`, der intern bis zu 1,4 s `usleep` plus Mach-IPC enthält. Identisches
Deadlock-Muster wie P0-B, getriggert durch SR-Wechsel.

**Reihenfolge-Hinweis:** Dieser Fix entfernt **nur** den Lock am Caller. Solange Fix-04 noch
nicht angewandt ist, läuft `sr_reinit_all_outputs()` danach **ohne** Lock — das ist nur
sicher, weil es ausschließlich vom Volume-Thread aufgerufen wird (Single-Writer auf
`g_outputs[]` während Reinit). Fix-04 macht das Innere dann explizit selbst-synchronisiert.
**Fix-03 und Fix-04 zusammen committen** (oder Fix-04 unmittelbar danach), um nie einen
Zustand zu haben, in dem das Innere unsynchronisiert auf shared State zugreift, während ein
anderer Pfad ihn modifiziert.

**Aktueller Code (1839–1845, im `if (cur_gen != last_sr_gen)`-Zweig):**
```c
                } else if (cur_gen != last_sr_gen) {
                    last_sr_gen = cur_gen;
                    pthread_mutex_lock(&g_outputs_lock);
                    sr_reinit_all_outputs();
                    pthread_mutex_unlock(&g_outputs_lock);
                }
```

**Neuer Code (1839–1843 Ersatz):**
```c
                } else if (cur_gen != last_sr_gen) {
                    last_sr_gen = cur_gen;
                    /* P0-A FIX (Teil 1): KEIN g_outputs_lock mehr um den kompletten
                     * sr_reinit_all_outputs()-Aufruf. Der enthielt bis zu 1,4s usleep +
                     * Mach-IPC an coreaudiod → Lock ewig gehalten bei spinnendem
                     * coreaudiod (P0-C) → Deadlock. sr_reinit_all_outputs() managt seine
                     * Lock-Granularitaet ab Fix-04 selbst (kurze Locks um Slot-Mutationen,
                     * CoreAudio-Calls lockfrei). */
                    sr_reinit_all_outputs();
                }
```

**Doc-Kommentar über `sr_reinit_all_outputs` anpassen (Zeile 1350):**
```c
 * sr_reinit_all_outputs — wird aufgerufen wenn der SHM-Ring eine neue
 * Sample-Rate meldet (sr_change_gen hat sich geaendert).
 * Caller darf g_outputs_lock NICHT halten (P0-A Fix). Die Funktion nimmt den
 * Lock selbst nur kurzzeitig um Slot-Mutationen; CoreAudio-Calls laufen lockfrei.
 * Aufruf ausschliesslich aus volume_poll_thread (Single-Writer-Garantie).
```
(ersetzt die alte Zeile `MUSS unter g_outputs_lock aufgerufen werden.`)

**Test-Kriterium:**
1. Quelle mit wechselnder Sample-Rate abspielen (z.B. 44.1 kHz → 48 kHz Track-Wechsel) bei
   aktivem USB-Output.
2. Während des SR-Wechsels parallel `get_status` pollen → darf nicht blockieren.
3. Audio läuft nach SR-Wechsel ohne Dauer-Glitch weiter.

**Risiken / Nebenwirkungen:**
- Zwischen Fix-03 und Fix-04 läuft das Innere lockfrei — nur sicher wegen Single-Writer.
  Daher **mit Fix-04 zusammen ausliefern**. Kein Release zwischen den beiden.

**Commit-Message Template:**
```
fix(helper): P0-A.1 — sr_reinit_all_outputs Caller ohne g_outputs_lock

volume_poll_thread hielt g_outputs_lock ueber den kompletten Reinit (bis 1,4s
usleep + Mach-IPC). Bei spinnendem coreaudiod → Deadlock. Lock am Caller entfernt;
Lock-Granularitaet wandert in die Funktion (Fix-04).

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

---

### Fix-04 — P0-A Teil 2: `sr_reinit_all_outputs()` Inneres — CoreAudio ohne Lock

**Priorität:** P0
**Datei:** `helper/AudioRouterNowHelper.c`
**Zeilen:** 1354–1497 (Funktionskörper)

**Problem:**
Nach Fix-03 läuft die Funktion ganz ohne Lock. Das ist für reine Atomic-Updates ok, aber
die Slot-Mutationen (`dev->active`, `dev->proc_id` setzen/nullen, Slot-Felder) und vor allem
die `usleep(200ms)`-Schleifen + CoreAudio-Calls müssen sauber strukturiert werden: CoreAudio
lockfrei, Slot-Sichtbarkeits-Übergänge (`active`) atomar bzw. unter kurzem Lock.

**Lösungsansatz:**
Pro Output: lockfrei stoppen/neu-erzeugen/starten (CoreAudio + `usleep`), die kritischen
Sichtbarkeits-Flags (`active`) über die bereits vorhandenen Atomics bzw. ein kurzes
Lock/Unlock um die Slot-Feld-Mutation. Da `sr_changing` bereits als Stille-Gate existiert
(Zeile 1404, atomar), nutzen wir es als Schutz: Solange `sr_changing==1`, gibt der IOProc
Stille aus — der Slot darf in dieser Phase lockfrei umgebaut werden. Die `active`-Flag-
Übergänge werden mit einem kurzen `g_outputs_lock` um genau die Schreibzeile gekapselt, damit
Volume-Thread-interne Slot-Reads (die unter Lock laufen) konsistent bleiben.

> **Begründung Single-Writer:** `sr_reinit_all_outputs` läuft ausschließlich im
> Volume-Thread. Andere Slot-Mutatoren (`output_add` Phase 3c, `process_hotplug_removals`,
> `output_remove`) laufen ebenfalls im Volume-Thread bzw. unter Lock. Wir müssen daher den
> Lock **nur** nehmen, wenn wir Felder schreiben, die ein anderer Lock-Halter lesen könnte —
> nicht für die langlaufenden CoreAudio-Calls.

**Aktueller Code (relevanter Mutations-Block, 1406–1495 — Stop + Reinit pro Output):**
```c
        /* Schritt 1: IOProc stoppen */
        if (dev->active && dev->proc_id) {
            AudioDeviceStop(dev->dev_id, dev->proc_id);
            AudioDeviceDestroyIOProcID(dev->dev_id, dev->proc_id);
            dev->proc_id = NULL;
            dev->active  = false;
        }
```
… (Schritt 2/3 SR-Set unverändert) …
```c
        /* Schritt 4: IOProc neu erzeugen — mit Retry nach SR-Wechsel. */
        OSStatus err = kAudioHardwareNotRunningError;
        for (int attempt = 0; attempt < 5; attempt++) {
            if (attempt > 0) {
                usleep(200000); /* 200ms — USB-Device Rekonfigurierungszeit */
            }
            err = AudioDeviceCreateIOProcID(dev->dev_id, device_ioproc, dev, &dev->proc_id);
            if (err == noErr) break;
            ...
            dev->proc_id = NULL;
        }
        if (err != noErr) {
            ...
            dev->active = false;
            atomic_store_explicit(&dev->sr_changing, 0u, memory_order_release);
            continue;
        }
        for (int retry = 0; retry < 3; retry++) {
            err = AudioDeviceStart(dev->dev_id, dev->proc_id);
            if (err == noErr) break;
            if (retry < 2) usleep(100000);  /* 100ms */
        }
        if (err != noErr) {
            ...
            AudioDeviceDestroyIOProcID(dev->dev_id, dev->proc_id);
            dev->proc_id = NULL;
            dev->active  = false;
            atomic_store_explicit(&dev->sr_changing, 0u, memory_order_release);
        } else {
            dev->active = true;
            ...
        }
```

**Neuer Code (Schritt 1 Ersatz, 1406–1412):**
```c
        /* Schritt 1: IOProc stoppen — sr_changing-Gate ist bereits gesetzt (Stille).
         * P0-A FIX (Teil 2): KEIN g_outputs_lock um Stop/Destroy. Diese Mach-IPC-Calls
         * laufen lockfrei. active=false wird unter kurzem Lock gesetzt, damit
         * Lock-haltende Reader (Volume-Thread innere Sektionen) den Slot ueberspringen. */
        if (dev->active && dev->proc_id) {
            AudioDeviceIOProcID old_proc = dev->proc_id;
            AudioDeviceID       old_dev  = dev->dev_id;
            pthread_mutex_lock(&g_outputs_lock);
            dev->active  = false;     /* Slot ab jetzt fuer Reader inaktiv */
            dev->proc_id = NULL;
            pthread_mutex_unlock(&g_outputs_lock);
            AudioDeviceStop(old_dev, old_proc);             /* lockfrei */
            AudioDeviceDestroyIOProcID(old_dev, old_proc);  /* lockfrei */
        }
```

**Neuer Code (Schritt 4 Ersatz, 1442–1495):**
```c
        /* Schritt 4: IOProc neu erzeugen — Retry, CoreAudio + usleep LOCKFREI.
         * P0-A FIX (Teil 2): keine dieser Mach-IPC/usleep-Operationen unter Lock. */
        AudioDeviceIOProcID new_proc = NULL;
        OSStatus err = kAudioHardwareNotRunningError;
        for (int attempt = 0; attempt < 5; attempt++) {
            if (attempt > 0) {
                usleep(200000); /* 200ms — USB-Rekonfigurierungszeit, lockfrei */
            }
            err = AudioDeviceCreateIOProcID(dev->dev_id, device_ioproc, dev, &new_proc);
            if (err == noErr) break;
            fprintf(stderr, "Helper: AudioDeviceCreateIOProcID Versuch %d/5 fehlgeschlagen "
                            "(OSStatus %d) fuer %s\n", attempt + 1, (int)err, dev->name);
            new_proc = NULL;
        }
        if (err != noErr) {
            fprintf(stderr, "Helper: AudioDeviceCreateIOProcID endgueltig fehlgeschlagen "
                            "fuer %s — Output bleibt inaktiv\n", dev->name);
            pthread_mutex_lock(&g_outputs_lock);
            dev->active  = false;
            dev->proc_id = NULL;
            pthread_mutex_unlock(&g_outputs_lock);
            atomic_store_explicit(&dev->sr_changing, 0u, memory_order_release);
            continue;
        }

        /* AudioDeviceStart mit Retry — lockfrei. */
        for (int retry = 0; retry < 3; retry++) {
            err = AudioDeviceStart(dev->dev_id, new_proc);
            if (err == noErr) break;
            if (retry < 2) usleep(100000);  /* 100ms, lockfrei */
        }
        if (err != noErr) {
            fprintf(stderr, "Helper: AudioDeviceStart fehlgeschlagen nach 3 Versuchen "
                            "(OSStatus %d) fuer %s — Output bleibt inaktiv\n",
                    (int)err, dev->name);
            AudioDeviceDestroyIOProcID(dev->dev_id, new_proc);  /* lockfrei */
            pthread_mutex_lock(&g_outputs_lock);
            dev->active  = false;
            dev->proc_id = NULL;
            pthread_mutex_unlock(&g_outputs_lock);
            atomic_store_explicit(&dev->sr_changing, 0u, memory_order_release);
        } else {
            /* Erfolg: proc_id + active unter kurzem Lock publizieren, dann Gate oeffnen. */
            atomic_store_explicit(&dev->preroll_target_frames, ARN_RING_CAPACITY / 4u,
                                  memory_order_relaxed);
            atomic_store_explicit(&dev->preroll_armed, 1u, memory_order_release);
            pthread_mutex_lock(&g_outputs_lock);
            dev->proc_id = new_proc;
            dev->active  = true;
            pthread_mutex_unlock(&g_outputs_lock);
            /* Gate ZULETZT oeffnen: ab hier gibt der IOProc wieder Audio aus. */
            atomic_store_explicit(&dev->sr_changing, 0u, memory_order_release);
            fprintf(stdout, "Helper: Output neu gestartet nach SR-Wechsel: %s [Ch %u-%u]\n",
                    dev->name, dev->ch_offset + 1, dev->ch_offset + 2);
        }
```

**Test-Kriterium:**
1. SR-Wechsel mit USB-Output (s. Fix-03), zusätzlich parallel `set_outputs` über Socket
   feuern → kein Deadlock, kein Crash.
2. Reinit-Dauer (bis zu ~1,4 s pro Output) blockiert keine Locks > wenige ms.
3. ThreadSanitizer-Build (optional, siehe Build-Anleitung) → keine Data-Races auf
   `g_outputs[].active`/`.proc_id`.
4. Audio nach Reinit korrekt, kein Pitch-Fehler (base_ratio korrekt).

**Risiken / Nebenwirkungen:**
- `dev`-Adresse: `sr_reinit_all_outputs` iteriert über `g_outputs[i]` ohne Swap-Removes
  während der eigenen Schleife → Adresse stabil. Da nur der Volume-Thread Slots entfernt
  und er gerade hier blockiert, kann während dieser Funktion kein paralleler Swap erfolgen.
- `sr_changing`-Gate verhindert, dass der IOProc während des lockfreien Umbaus echte Samples
  ausgibt. Reihenfolge (Gate zuletzt öffnen) ist kritisch — eingehalten.

**Commit-Message Template:**
```
fix(helper): P0-A.2 — sr_reinit_all_outputs CoreAudio-Calls lockfrei

Stop/Destroy/Create/Start + usleep-Retries (bis 1,4s) laufen nicht mehr unter
g_outputs_lock. active/proc_id-Uebergaenge unter kurzem Lock; sr_changing-Gate
schuetzt den IOProc waehrend des Umbaus. Beseitigt SR-Wechsel-Deadlock.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

---

## 4. CHECKPOINT — Build + Smoke Test (nach Fix-01..04, PFLICHT)

> **Erst weiter zu Fix-05, wenn dieser Checkpoint grün ist.** Die P0-Kette muss hier
> nachweislich tot sein.

**Build (siehe §6 für Details):**
```bash
cd /Users/mauriciomorkun/AudioRouterNow/helper && make clean && make
cd /Users/mauriciomorkun/AudioRouterNow/driver && make clean && make
cd /Users/mauriciomorkun/AudioRouterNow/driver && sudo make install && sudo make reload
```

**Smoke-Test-Checkliste:**

| # | Test | Erwartung | Pass? |
|---|------|-----------|-------|
| 1 | `coreaudiod` neu geladen, AudioRouterNow als Output, Audio abspielen | `top -pid $(pgrep coreaudiod)` < 15 % CPU, stabil | ☐ |
| 2 | Race provozieren: `sudo killall coreaudiod`, sofort Audio starten | CPU bleibt niedrig, kein Spin | ☐ |
| 3 | Output-Gerät wechseln (USB-Interface) während Audio läuft | Wechsel < 2 s, UI responsiv, kein Hänger | ☐ |
| 4 | SR-Wechsel erzwingen (44.1↔48 kHz) bei aktivem USB-Output | Audio läuft weiter, kein Dauer-Glitch | ☐ |
| 5 | Parallel-Stress: in Schleife `get_status` pollen während Test 3+4 | Polls kehren < 1 s zurück, nie blockiert | ☐ |
| 6 | 5 Minuten Dauerbetrieb, mehrere Quellwechsel | Kein Freeze, CPU stabil, kein Crash | ☐ |
| 7 | Helper-Log `~/Library/Logs/AudioRouterNow/helper.log` prüfen | Keine endlosen Retry-Spam-Loops, keine Lock-Warnungen | ☐ |
| 8 | `g_outputs_lock`-Hold messen (dtrace/Log) | Nie > ~20 ms gehalten | ☐ |

**Abbruchkriterium:** Friert das System bei einem Test ein oder spinnt `coreaudiod` →
NICHT weitermachen. Zuerst Fix-01..04 erneut prüfen (häufigster Fehler: `gHostTicksPerFrameBits`-
Pfad oder ein vergessener `unlock`).

---

### Fix-05 — P2-A: `process_hotplug_removals()` Lock-Scope

**Priorität:** P2 (Prevention — gleiches Muster, niedrigere Frequenz)
**Datei:** `helper/AudioRouterNowHelper.c`
**Zeilen:** 1539–1563

**Problem:**
`AudioDeviceStop()` + `AudioDeviceDestroyIOProcID()` laufen unter `g_outputs_lock`. Beim
Entfernen eines verschwundenen Geräts kann ein hängendes CoreAudio den Lock halten →
Deadlock-Risiko wie P0-B, nur seltener getriggert (Hotplug).

**Lösung:**
Pro verschwundenem Gerät: unter kurzem Lock die Slot-Identität (dev_id, proc_id) extrahieren
und den Slot per Swap-Remove aus dem Array nehmen (`active=false`, sofort unsichtbar), dann
**ohne Lock** `AudioDeviceStop`/`Destroy` auf den extrahierten Werten ausführen.

**Aktueller Code (1539–1563):**
```c
static void process_hotplug_removals(void)
{
    pthread_mutex_lock(&g_outputs_lock);
    int i = 0;
    while (i < g_n_outputs) {
        AudioDeviceID found = find_device_by_uid(g_outputs[i].uid);
        if (found == kAudioDeviceUnknown) {
            fprintf(stdout, "Helper: Device verschwunden — entferne %s\n", g_outputs[i].name);
            DeviceOutput *dev = &g_outputs[i];
            if (dev->proc_id) {
                AudioDeviceStop(dev->dev_id, dev->proc_id);
                AudioDeviceDestroyIOProcID(dev->dev_id, dev->proc_id);
            }
            if (i != g_n_outputs - 1) {
                g_outputs[i] = g_outputs[g_n_outputs - 1];
            }
            memset(&g_outputs[g_n_outputs - 1], 0, sizeof(DeviceOutput));
            g_n_outputs--;
            /* i NICHT erhoehen — neuer Slot-Inhalt muss auch geprueft werden */
        } else {
            i++;
        }
    }
    pthread_mutex_unlock(&g_outputs_lock);
}
```

**Neuer Code (1539–1563 Ersatz):**
```c
static void process_hotplug_removals(void)
{
    for (;;) {
        /* Phase A (kurzer Lock): einen verschwundenen Slot finden, Teardown-Daten
         * extrahieren, Slot per Swap-Remove aus dem Array nehmen. */
        AudioDeviceID       dead_dev  = kAudioDeviceUnknown;
        AudioDeviceIOProcID dead_proc = NULL;
        char                dead_name[256];
        dead_name[0] = '\0';
        bool found_dead = false;

        pthread_mutex_lock(&g_outputs_lock);
        for (int i = 0; i < g_n_outputs; i++) {
            if (find_device_by_uid(g_outputs[i].uid) == kAudioDeviceUnknown) {
                DeviceOutput *dev = &g_outputs[i];
                dead_dev  = dev->dev_id;
                dead_proc = dev->proc_id;
                strncpy(dead_name, dev->name, sizeof(dead_name) - 1);
                dead_name[sizeof(dead_name) - 1] = '\0';
                /* Slot sofort unsichtbar machen + Swap-Remove. */
                if (i != g_n_outputs - 1) {
                    g_outputs[i] = g_outputs[g_n_outputs - 1];
                }
                memset(&g_outputs[g_n_outputs - 1], 0, sizeof(DeviceOutput));
                g_n_outputs--;
                found_dead = true;
                break;  /* je Durchlauf ein Slot — danach lockfrei abbauen */
            }
        }
        pthread_mutex_unlock(&g_outputs_lock);

        if (!found_dead) break;  /* keine weiteren verschwundenen Geraete */

        /* Phase B (OHNE Lock): CoreAudio-Teardown der extrahierten IOProc-ID.
         * P2-A FIX: AudioDeviceStop/DestroyIOProcID nicht mehr unter g_outputs_lock —
         * ein haengendes CoreAudio kann den Lock nicht mehr blockieren. */
        fprintf(stdout, "Helper: Device verschwunden — entferne %s\n", dead_name);
        if (dead_proc) {
            AudioDeviceStop(dead_dev, dead_proc);
            AudioDeviceDestroyIOProcID(dead_dev, dead_proc);
        }
    }
}
```

**Test-Kriterium:**
1. USB-Output aktiv, Audio läuft → USB-Gerät physisch abziehen.
2. Helper entfernt Slot, Log zeigt „Device verschwunden". UI bleibt responsiv.
3. Parallel `get_status` pollen während Abziehen → nicht blockiert.
4. Mehrere Geräte gleichzeitig abziehen → alle korrekt entfernt, keine Doppel-Teardowns.

**Risiken / Nebenwirkungen:**
- `find_device_by_uid` unter Lock: ruft CoreAudio (`AudioObjectGetPropertyData` zum
  Enumerieren) auf. Das ist ein Read und schnell, aber im Worst-Case ebenfalls IPC. Für
  diesen Fix akzeptiert (Read-Property, kein Start/Stop); eine vollständige Auslagerung
  wäre P2-B (Architektur, separat). Hier dokumentiert als bekannte Restkante.
- Swap-Remove + sofortiger `break`: O(n²) bei vielen toten Slots, aber n ≤ MAX_OUTPUTS und
  Hotplug ist selten — vernachlässigbar.

**Commit-Message Template:**
```
fix(helper): P2-A — process_hotplug_removals CoreAudio-Teardown lockfrei

AudioDeviceStop/DestroyIOProcID liefen unter g_outputs_lock. Slot wird jetzt
unter kurzem Lock per Swap-Remove extrahiert, der CoreAudio-Teardown laeuft
lockfrei. Verhindert Hotplug-Deadlock bei haengendem coreaudiod.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

---

### Fix-06 — P1-B: `READ_TIMEOUT` + Main-Thread-safe `get_status`

**Priorität:** P1
**Datei:** `engine/helper_client.py`
**Zeilen:** 29 (`READ_TIMEOUT`), 233–246 (`get_status`)

**Problem:**
`READ_TIMEOUT = 10.0`. `get_status()` wird vom Main-Thread (UI) gepollt und blockiert bei
hängendem Helper bis zu 10 s → UI eingefroren. Für UI-Polls muss ein **kurzer** Default-
Timeout gelten, der die UI nie länger als ~1 s blockiert.

**Lösung:**
Separater, kurzer `STATUS_POLL_TIMEOUT` für `get_status` (Default 1,0 s) — überschreibbar.
Der generelle `READ_TIMEOUT` für längere Operationen bleibt, wird aber von 10 s auf 5 s
gesenkt (kein legitimer Helper-Call dauert real > 5 s, da nach den C-Fixes nichts mehr unter
Lock blockiert).

**Aktueller Code (28–29):**
```python
CONNECT_TIMEOUT = 2.0
READ_TIMEOUT = 10.0
```

**Neuer Code (28–31):**
```python
CONNECT_TIMEOUT = 2.0
# P1-B FIX: 10s war zu lang — ein haengender Helper fror die UI 10s ein.
# Nach den C-Fixes (P0-A/B, P2-A) blockiert kein legitimer Call mehr unter Lock,
# daher reicht 5s fuer regulaere Kommandos.
READ_TIMEOUT = 5.0
# P1-B FIX: Eigener kurzer Timeout fuer Main-Thread UI-Polls (get_status).
# Haelt die UI auch bei haengendem Helper nie laenger als ~1s blockiert.
STATUS_POLL_TIMEOUT = 1.0
```

**Aktueller Code (233–246):**
```python
    def get_status(self, timeout: Optional[float] = None) -> Optional[dict]:
        """
        Fragt den Helper-Status ab.

        Args:
            timeout: Optionaler Override fuer Connect- und Read-Timeout (Sekunden).
                     Nuetzlich fuer haeufige UI-Polls, damit ein haengender Helper
                     den Main-Thread nicht blockiert. None = Standard-Timeouts.
        """
        try:
            return self._send({"cmd": "get_status"}, timeout=timeout)
        except Exception as e:
            logger.warning(f"get_status fehlgeschlagen: {e}")
            return None
```

**Neuer Code (233–250 Ersatz):**
```python
    def get_status(self, timeout: Optional[float] = None) -> Optional[dict]:
        """
        Fragt den Helper-Status ab.

        P1-B FIX: Standardmaessig kurzer STATUS_POLL_TIMEOUT (1s) statt READ_TIMEOUT
        (5s), damit ein haengender Helper den Main-Thread/UI nie lange blockiert.
        Ein expliziter timeout-Parameter ueberschreibt das weiterhin.

        Args:
            timeout: Optionaler Override fuer Connect- und Read-Timeout (Sekunden).
                     None = kurzer STATUS_POLL_TIMEOUT (UI-sicher).
        """
        effective = timeout if timeout is not None else STATUS_POLL_TIMEOUT
        try:
            return self._send({"cmd": "get_status"}, timeout=effective)
        except Exception as e:
            logger.warning(f"get_status fehlgeschlagen: {e}")
            return None
```

**Test-Kriterium:**
1. Helper künstlich anhalten: `kill -STOP $(pgrep AudioRouterNowHelper)`.
2. `get_status()` vom Main-Thread aufrufen → kehrt nach ~1 s mit `None` zurück (nicht 10 s).
3. UI bleibt während Helper-STOP klickbar/responsiv.
4. `kill -CONT` → `get_status` liefert wieder normalen Status.

**Risiken / Nebenwirkungen:**
- Bei realer kurzer Helper-Latenz (Helper gerade busy) könnte ein 1-s-Poll mal `None`
  liefern. UI muss `None` als „kurz nicht erreichbar" tolerieren (Retry beim nächsten
  Poll). Prüfen, dass der Aufrufer `None` nicht als „Helper tot" fehlinterpretiert.
- `READ_TIMEOUT` von 10→5 s: betrifft `_send_no_lock`-Default und `_is_socket_alive`. Da
  nach den C-Fixes nichts > 5 s blockiert, unkritisch.

**Commit-Message Template:**
```
fix(engine): P1-B — UI-sicherer get_status-Timeout (1s) + READ_TIMEOUT 10→5s

get_status nutzt vom Main-Thread jetzt STATUS_POLL_TIMEOUT=1s statt 10s — ein
haengender Helper friert die UI nicht mehr ein. READ_TIMEOUT auf 5s gesenkt.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

---

### Fix-07 — P1-C: `ensure_running()` Lock-Scope

**Priorität:** P1
**Datei:** `engine/helper_client.py`
**Zeilen:** 108–168

**Problem:**
`ensure_running()` hält `self._lock` über den gesamten Body: bis zu 15 s Socket-Wait + bis
zu 10 s SHM-Wait = bis zu 25 s. Während dieser Zeit blockiert jeder andere Thread, der
`self._lock` braucht (jedes `_send`, jedes `get_status`).

**Lösung:**
Den Lock **nur** um die kurzen kritischen Mutationen (`self._proc`, `self._spawned_by_us`
setzen/lesen) halten. Die langen Wartephasen (`_is_socket_alive`-Polling, `_wait_for_ready`)
laufen **ohne** `self._lock`. `_wait_for_ready` ruft `_send_no_lock` — das nimmt den Lock
ohnehin nicht; bisher war es nur durch den umschließenden `with self._lock` geschützt. Wir
nutzen einen separaten, nicht-reentranten **Spawn-Guard** (`self._spawn_lock`), der nur das
Spawnen serialisiert, statt den allgemeinen `self._lock` über 25 s zu halten.

**Voraussetzung — neuer Lock im `__init__` (Zeile 80–87):**

Aktuell:
```python
    def __init__(self):
        self._proc: Optional[subprocess.Popen] = None
        self._lock = threading.Lock()
        self._spawned_by_us = False
```
Ergänzen:
```python
    def __init__(self):
        self._proc: Optional[subprocess.Popen] = None
        self._lock = threading.Lock()
        # P1-C FIX: separater Guard nur fuer ensure_running/Spawn — serialisiert das
        # Spawnen, OHNE den allgemeinen _lock ueber bis zu 25s Wartezeit zu halten.
        self._spawn_lock = threading.Lock()
        self._spawned_by_us = False
```

**Wichtig:** `_wait_for_ready` ist dokumentiert als „Darf NUR unter self._lock aufgerufen
werden" (Zeile 174). Diese Invariante entfällt, da `_send_no_lock` selbst keinen Lock nimmt.
Doc-Kommentar in `_wait_for_ready` entsprechend anpassen (siehe unten).

**Aktueller Code (108–168):**
```python
    def ensure_running(self) -> bool:
        """..."""
        with self._lock:
            if self._is_socket_alive():
                logger.info("Helper Socket erreichbar — warte auf SHM-Bereitschaft")
                if self._wait_for_ready():
                    return True
                logger.warning("Helper Socket erreichbar, SHM-Timeout — App retries via Timer")
                return True

            binary = _find_helper_binary()
            if binary is None:
                logger.error("Helper-Binary nicht gefunden")
                return False

            logger.info(f"Helper wird gespawnt: {binary}")
            try:
                log_dir = Path.home() / "Library" / "Logs" / "AudioRouterNow"
                log_dir.mkdir(parents=True, exist_ok=True)
                log_out = open(log_dir / "helper.log", "ab", buffering=0)
                log_err = open(log_dir / "helper.err", "ab", buffering=0)
                self._proc = subprocess.Popen(
                    [str(binary)],
                    stdout=log_out,
                    stderr=log_err,
                    stdin=subprocess.DEVNULL,
                    start_new_session=True,
                )
                self._spawned_by_us = True
            except OSError as e:
                logger.error(f"Helper konnte nicht gestartet werden: {e}")
                return False

            deadline = time.monotonic() + 15.0
            while time.monotonic() < deadline:
                if self._is_socket_alive():
                    logger.info("Helper-Socket erreichbar")
                    break
                time.sleep(0.1)
            else:
                logger.error("Helper gestartet, aber Socket nicht erreichbar")
                return False

            if self._wait_for_ready():
                logger.info("Helper vollständig bereit (Socket + SHM)")
                return True

            logger.warning("Helper Socket OK, SHM-Timeout — App retries via Timer")
            return True
```

**Neuer Code (108–168 Ersatz):**
```python
    def ensure_running(self) -> bool:
        """
        Stellt sicher, dass der Helper läuft UND routing-bereit ist.

        P1-C FIX: Der allgemeine self._lock wird NICHT mehr ueber die bis zu 25s
        Wartephasen (Socket-Wait + SHM-Wait) gehalten. Nur das Spawnen wird ueber
        self._spawn_lock serialisiert; die langen Polls laufen lockfrei. Damit
        blockiert ensure_running keinen parallelen _send/get_status mehr.
        """
        # Schneller, lockfreier Vorab-Check: laeuft der Helper bereits?
        if self._is_socket_alive():
            logger.info("Helper Socket erreichbar — warte auf SHM-Bereitschaft")
            self._wait_for_ready()  # lockfrei; Ergebnis egal (App-Retry als Fallback)
            return True

        # Spawnen serialisieren: nur EIN Thread spawnt, andere warten kurz und
        # profitieren vom Socket-Check danach. self._lock bleibt hier frei.
        with self._spawn_lock:
            # Re-Check: hat ein anderer Thread in der Zwischenzeit gespawnt?
            if self._is_socket_alive():
                self._wait_for_ready()
                return True

            binary = _find_helper_binary()
            if binary is None:
                logger.error("Helper-Binary nicht gefunden")
                return False

            logger.info(f"Helper wird gespawnt: {binary}")
            try:
                log_dir = Path.home() / "Library" / "Logs" / "AudioRouterNow"
                log_dir.mkdir(parents=True, exist_ok=True)
                log_out = open(log_dir / "helper.log", "ab", buffering=0)
                log_err = open(log_dir / "helper.err", "ab", buffering=0)
                proc = subprocess.Popen(
                    [str(binary)],
                    stdout=log_out,
                    stderr=log_err,
                    stdin=subprocess.DEVNULL,
                    start_new_session=True,
                )
                # self._proc/_spawned_by_us unter KURZEM self._lock publizieren.
                with self._lock:
                    self._proc = proc
                    self._spawned_by_us = True
            except OSError as e:
                logger.error(f"Helper konnte nicht gestartet werden: {e}")
                return False

            # Phase 1: Warte bis Socket erreichbar (max 15s) — LOCKFREI.
            deadline = time.monotonic() + 15.0
            while time.monotonic() < deadline:
                if self._is_socket_alive():
                    logger.info("Helper-Socket erreichbar")
                    break
                time.sleep(0.1)
            else:
                logger.error("Helper gestartet, aber Socket nicht erreichbar")
                return False

            # Phase 2: Warte bis SHM-Ring bereit (max 10s) — LOCKFREI.
            if self._wait_for_ready():
                logger.info("Helper vollständig bereit (Socket + SHM)")
                return True

            logger.warning("Helper Socket OK, SHM-Timeout — App retries via Timer")
            return True
```

**Doc-Kommentar `_wait_for_ready` anpassen (Zeile 170–175):**
```python
    def _wait_for_ready(self, timeout: float = 10.0) -> bool:
        """
        Wartet bis get_status() → ready:true meldet (SHM verbunden).
        Gibt True zurück wenn bereit, False bei Timeout.

        P1-C FIX: Darf OHNE self._lock aufgerufen werden — nutzt _send_no_lock,
        das selbst keinen Lock nimmt. (Frueher: 'NUR unter self._lock'.)
        """
```

**Test-Kriterium:**
1. Helper nicht laufend → `ensure_running()` in Thread A starten.
2. Parallel in Thread B `get_status()` aufrufen → kehrt < 1 s zurück (nicht erst nach 25 s).
3. Zwei Threads rufen gleichzeitig `ensure_running()` → nur ein Spawn (kein doppelter
   Helper-Prozess), beide kehren `True` zurück.
4. `shutdown()` danach beendet den gespawnten Prozess sauber (`self._proc` korrekt gesetzt).

**Risiken / Nebenwirkungen:**
- **Double-Spawn-Race:** Verhindert durch `_spawn_lock` + Re-Check `_is_socket_alive` nach
  Lock-Erwerb. Worst Case: zwei Threads sehen kurz keinen Socket, der zweite Re-Check fängt
  es ab.
- `self._proc` wird unter `self._lock` gesetzt — konsistent mit `shutdown()`, das ebenfalls
  unter `self._lock` liest/schreibt. Kein Race auf `_proc`.
- `_is_socket_alive` macht eigene Socket-Verbindung mit `CONNECT_TIMEOUT`/`READ_TIMEOUT` —
  lockfrei, unkritisch.

**Commit-Message Template:**
```
fix(engine): P1-C — ensure_running haelt self._lock nicht mehr 25s

Socket-Wait (15s) + SHM-Wait (10s) liefen unter self._lock → blockierte jeden
parallelen _send/get_status. Spawnen jetzt ueber separaten _spawn_lock serialisiert,
Wartephasen lockfrei; _proc unter kurzem _lock publiziert.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

---

### Fix-08 — P0-D: `coreaudiod` CPU-Watchdog im Helper — ✗ GESTRICHEN

> **Status: Gestrichen (12.06.2026) — nie implementiert, nicht mehr erforderlich.**

**Warum gestrichen:**

Fix-08 wurde in zwei Schritten aufgegeben:

1. **v3.3.0 / F6:** Der `proc_pid_rusage()`-Call-Site im `volume_poll_thread` wurde entfernt,
   bevor Fix-08 überhaupt fertiggestellt war. Begründung (`AudioRouterNowHelper.c`, Kommentar
   bei der Entfernungsstelle): `proc_pid_rusage`/Mach-IPC kann bei degradiertem `coreaudiod`
   selbst blockieren und damit den `volume_poll_thread` hängen — Fix-08 hätte exakt den Bug
   reproduziert, den es heilen sollte.

2. **v3.3.1 / H-1:** Die daraus resultierenden Dead-Code-Funktionen (`coreaudiod_watchdog_tick`,
   `find_coreaudiod_pid`, `read_proc_cpu_ns`, `outputs_stop_all_thread`) wurden vollständig
   aus dem Source entfernt.

**Warum P0-D trotzdem gelöst ist:**

P0-D (kein Watchdog gegen CPU-Spin) war ein Symptom des eigentlichen Root Cause P0-C
(`GetZeroTimeStamp` lieferte falschen `ticksPerFrame`). Dieser wurde durch **I-2** (v3.4.0)
strukturell behoben: Die Clock läuft jetzt frei via `mach_absolute_time()` — der Deadlock
zwischen HAL-Takt und `WriteMix` kann nicht mehr entstehen. Damit ist auch P0-D strukturell
gelöst; ein externer Watchdog ist überflüssig.

**Ursprüngliche Problembeschreibung (historisch):**
Es gab keinen Mechanismus, der einen `coreaudiod`-CPU-Spin erkennt und reagiert. Die geplante
Lösung war ein periodisches `proc_pid_rusage`-Sampling im `volume_poll_thread` mit defensivem
IOProc-Stop und Flag-Datei für die Python-Engine. Diese Lösung war konzeptuell korrekt, aber
auf macOS nicht sicher implementierbar ohne das identische Block-Risiko einzugehen.

**Neuer Include (oben, bei den anderen `#include`):**
```c
#include <libproc.h>      /* P0-D: proc_pid_rusage fuer coreaudiod-CPU-Watchdog */
#include <sys/proc_info.h>
```

**Neue globale State-Variablen (bei den anderen `static atomic_*`-Globals, ~Zeile 301):**
```c
/* P0-D: coreaudiod CPU-Watchdog State (nur vom volume_poll_thread genutzt). */
static atomic_int  g_watchdog_tripped = 0;   /* 1 = Spin erkannt + reagiert */
```

**Neue Funktion (vor `volume_poll_thread`, z.B. nahe Zeile 1600):**
```c
/* P0-D: Findet die PID von coreaudiod via sysctl-Prozessliste.
 * Gibt 0 zurueck wenn nicht gefunden. */
static pid_t find_coreaudiod_pid(void)
{
    int    mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len    = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return 0;

    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (!procs) return 0;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) { free(procs); return 0; }

    pid_t  result = 0;
    size_t n = len / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < n; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, "coreaudiod") == 0) {
            result = procs[i].kp_proc.p_pid;
            break;
        }
    }
    free(procs);
    return result;
}

/* P0-D: Liest die kumulierte CPU-Zeit (User+System, ns) von pid via libproc.
 * Gibt true bei Erfolg. */
static bool read_proc_cpu_ns(pid_t pid, uint64_t *out_cpu_ns)
{
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return false;
    *out_cpu_ns = ri.ri_user_time + ri.ri_system_time;  /* bereits in ns */
    return true;
}

/* P0-D: Watchdog-Tick — alle ~2s vom volume_poll_thread aufgerufen.
 * Erkennt anhaltenden coreaudiod-CPU-Spin (>90% ueber >5s) und reagiert defensiv,
 * OHNE coreaudiod destruktiv zu killen. */
static void coreaudiod_watchdog_tick(void)
{
    static pid_t    s_pid          = 0;
    static uint64_t s_last_cpu_ns  = 0;
    static uint64_t s_last_wall_ns = 0;
    static int      s_high_streak  = 0;   /* aufeinanderfolgende High-CPU-Samples */

    if (atomic_load_explicit(&g_watchdog_tripped, memory_order_relaxed)) return;

    if (s_pid == 0 || find_device_by_uid_is_pid_alive(s_pid) == false) {
        s_pid = find_coreaudiod_pid();
        s_last_cpu_ns = 0; s_last_wall_ns = 0; s_high_streak = 0;
        if (s_pid == 0) return;
    }

    uint64_t cpu_ns = 0;
    uint64_t now_ns = get_time_ns();
    if (!read_proc_cpu_ns(s_pid, &cpu_ns)) { s_pid = 0; return; }

    if (s_last_wall_ns != 0 && now_ns > s_last_wall_ns) {
        uint64_t d_cpu  = (cpu_ns > s_last_cpu_ns) ? (cpu_ns - s_last_cpu_ns) : 0;
        uint64_t d_wall = now_ns - s_last_wall_ns;
        /* CPU-Anteil in Prozent (kann >100 bei Multi-Core, daher Cap egal). */
        double pct = (d_wall > 0) ? (100.0 * (double)d_cpu / (double)d_wall) : 0.0;

        if (pct > 90.0) {
            s_high_streak++;
        } else {
            s_high_streak = 0;
        }

        /* Tick alle ~2s → 3 Streaks ≈ >5s anhaltend. */
        if (s_high_streak >= 3) {
            fprintf(stderr,
                "Helper: WATCHDOG — coreaudiod (pid %d) bei %.0f%% CPU ueber >5s. "
                "Stoppe eigene IOProcs und signalisiere UI.\n", (int)s_pid, pct);

            /* 1. Eigene IOProcs stoppen — entzieht dem Spin die Nahrung. */
            outputs_stop_all();   /* nimmt g_outputs_lock kurz; CoreAudio-Stop drin */

            /* 2. Flag-Datei fuer die Python-Engine schreiben (nicht-destruktiv). */
            char path[512];
            const char *home = getenv("HOME");
            if (home) {
                snprintf(path, sizeof(path), "%s/.audiorouter/coreaudiod_spin.flag", home);
                FILE *f = fopen(path, "w");
                if (f) {
                    fprintf(f, "coreaudiod_pid=%d cpu_pct=%.0f ts_ns=%llu\n",
                            (int)s_pid, pct, (unsigned long long)now_ns);
                    fclose(f);
                }
            }
            atomic_store_explicit(&g_watchdog_tripped, 1, memory_order_release);
        }
    }

    s_last_cpu_ns  = cpu_ns;
    s_last_wall_ns = now_ns;
}
```

> **Hinweis:** `find_device_by_uid_is_pid_alive` oben ist ein Platzhalter für eine triviale
> Liveness-Prüfung. Implementiere stattdessen `kill(s_pid, 0) == 0` (prüft Existenz ohne
> Signal):
> ```c
>     if (s_pid == 0 || kill(s_pid, 0) != 0) {
> ```
> (`#include <signal.h>` ist bereits vorhanden, Zeile 52.)

**Integration in `volume_poll_thread` (nach dem Hotplug-Block, ~Zeile 1851, vor `usleep`):**

Aktueller Kontext (1848–1853):
```c
        /* H3: Hot-Plug-Reaktion ausserhalb des CoreAudio-Callbacks verarbeiten. */
        if (atomic_exchange_explicit(&g_hotplug_pending, 0, memory_order_acq_rel)) {
            process_hotplug_removals();
        }

        usleep(VOLUME_POLL_INTERVAL_US);
```

Neu:
```c
        /* H3: Hot-Plug-Reaktion ausserhalb des CoreAudio-Callbacks verarbeiten. */
        if (atomic_exchange_explicit(&g_hotplug_pending, 0, memory_order_acq_rel)) {
            process_hotplug_removals();
        }

        /* P0-D: coreaudiod CPU-Watchdog — alle ~2s (40 Ticks à 50ms) abtasten. */
        {
            static int s_wd_counter = 0;
            if (++s_wd_counter >= 40) {
                s_wd_counter = 0;
                coreaudiod_watchdog_tick();
            }
        }

        usleep(VOLUME_POLL_INTERVAL_US);
```

**Python-Seite (Engine soll Flag lesen — Hinweis, separate kleine Ergänzung):**
Die Engine sollte beim Status-Poll prüfen, ob `~/.audiorouter/coreaudiod_spin.flag`
existiert, und dem Nutzer dann einen Dialog „Audio-System hängt — Treiber neu laden?"
anbieten (führt nach Bestätigung `sudo launchctl kickstart -k system/com.apple.audio.coreaudiod`
o.ä. aus). Diese UI-Anbindung ist **nicht Teil von Fix-08** (kein Auto-Kill), aber als
Folge-Task vermerkt.

**Test-Kriterium:**
1. `coreaudiod`-Spin künstlich erzeugen ist riskant. Stattdessen Watchdog-Logik isoliert
   testen: Schwellwert temporär auf > 5 % senken, normalen `coreaudiod`-Load erzeugen
   (Audio + SR-Wechsel), prüfen dass `coreaudiod_watchdog_tick` korrekt Prozent berechnet
   (Debug-Log einbauen).
2. Verifizieren: `find_coreaudiod_pid()` findet die korrekte PID (`pgrep coreaudiod`).
3. `read_proc_cpu_ns` liefert monoton steigende Werte.
4. Bei simuliertem Trip (Schwellwert niedrig): Flag-Datei wird geschrieben, `outputs_stop_all`
   läuft, `g_watchdog_tripped` wird gesetzt, kein erneutes Triggern (Einmal-Reaktion).
5. **Nach dem Test Schwellwert wieder auf 90 % / 3 Streaks zurücksetzen.**

**Risiken / Nebenwirkungen:**
- `proc_pid_rusage` / `RUSAGE_INFO_V4`: verfügbar ab macOS 10.9+, unkritisch für Min-Target
  11.0. Struct `rusage_info_v4` in `<libproc.h>`/`<sys/resource.h>`.
- **False Positives:** Legitimes hohes `coreaudiod`-CPU bei vielen Streams ist denkbar. Der
  90 %-über-5 s-Filter ist konservativ. `outputs_stop_all` ist reversibel (Nutzer kann Output
  neu wählen). Kein Datenverlust.
- `outputs_stop_all` nimmt `g_outputs_lock` und ruft `AudioDeviceStop` darunter (Zeile 1502–
  1514). Das ist ein bekanntes Restmuster — bei getripptem coreaudiod könnte auch dieser
  Stop hängen. **Mitigation:** Den `outputs_stop_all`-Aufruf im Watchdog NICHT unter dem
  Volume-Thread blockieren lassen; alternativ nur die IOProcs lockfrei stoppen (analog
  Fix-05). Für die erste Version akzeptiert; als P2-B-Folgearbeit vermerkt, falls
  `outputs_stop_all` selbst noch gehärtet werden muss.
- `sysctl(KERN_PROC_ALL)`: O(Prozessanzahl) alle 2 s — vernachlässigbar.

**Commit-Message Template:**
```
feat(helper): P0-D — coreaudiod CPU-Watchdog (Safety-Net gegen Hard Reboot)

Volume-Thread tastet alle ~2s coreaudiod-CPU via libproc ab. Bei >90% ueber >5s:
eigene IOProcs stoppen (entzieht Spin die Nahrung), Flag-Datei fuer UI schreiben,
g_watchdog_tripped setzen. KEIN destruktives killall — UI bietet bestaetigte Aktion.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

---

## 5. Zusammenfassung Fix-Tabelle

| Fix | Bug | Datei | Zeilen (Ausgang) | Art | Prio |
|-----|-----|-------|------------------|-----|------|
| Fix-01 | P0-C | driver/src/AudioRouterNowDriver.c | 1746–1751 | RT-Pfad-Korrektur | P0 | ✅ v3.4.0 |
| Fix-02 | P0-B | helper/AudioRouterNowHelper.c | 1139–1192 | Lock-Scope | P0 | ✅ v3.4.0 |
| Fix-03 | P0-A.1 | helper/AudioRouterNowHelper.c | 1841–1844 | Lock-Scope (Caller) | P0 | ✅ v3.4.0 |
| Fix-04 | P0-A.2 | helper/AudioRouterNowHelper.c | 1354–1497 | Lock-Scope (Inneres) | P0 | ✅ v3.4.0 |
| — | CHECKPOINT | — | — | Build + Smoke | — | ✅ |
| Fix-05 | P2-A | helper/AudioRouterNowHelper.c | 1539–1563 | Lock-Scope | P2 | ✅ v3.4.0 |
| Fix-06 | P1-B | engine/helper_client.py | 29, 233–246 | Timeout | P1 | ✅ v3.4.0 |
| Fix-07 | P1-C | engine/helper_client.py | 80–87, 108–168 | Lock-Scope | P1 | ✅ v3.4.0 |
| Fix-08 | P0-D | helper/AudioRouterNowHelper.c | — | Watchdog | P0 | ✗ GESTRICHEN (superseded durch I-2) |

---

## 6. Build-Anleitung

**Helper allein bauen (für Fix-02..05, Fix-08):**
```bash
cd /Users/mauriciomorkun/AudioRouterNow/helper
make clean
make
# Ergebnis: build/AudioRouterNowHelper (Universal arm64 + x86_64, ad-hoc signiert)
# Symlink ./AudioRouterNowHelper zeigt darauf.
```

**Driver-Bundle bauen (für Fix-01; bündelt auch das Helper-Binary):**
```bash
cd /Users/mauriciomorkun/AudioRouterNow/driver
make clean
make
# Ergebnis: build/AudioRouterNow.driver/  (inkl. eingebettetem Helper)
```

**Installieren + coreaudiod neu laden (benötigt sudo):**
```bash
cd /Users/mauriciomorkun/AudioRouterNow/driver
sudo make install     # → /Library/Audio/Plug-Ins/HAL/AudioRouterNow.driver
sudo make reload      # startet coreaudiod neu → Treiber wird geladen
```

**Optional — ThreadSanitizer-Build des Helpers (für Fix-02/04/05 Race-Verifikation):**
```bash
cd /Users/mauriciomorkun/AudioRouterNow/helper
clang -arch arm64 -mmacosx-version-min=11.0 -O1 -g -fsanitize=thread \
      -std=c11 -I. -Wall -Wextra \
      -framework CoreAudio -framework AudioToolbox -framework CoreFoundation \
      -o build/AudioRouterNowHelper_tsan AudioRouterNowHelper.c
# Nur arm64 (TSan unterstuetzt kein Universal-Linking direkt).
# Mit diesem Binary die Smoke-Tests fahren → TSan-Reports pruefen.
```

**Python-Engine (Fix-06, Fix-07) — kein Build, nur Syntax-Check:**
```bash
cd /Users/mauriciomorkun/AudioRouterNow/engine
python3 -m py_compile helper_client.py && echo "helper_client.py OK"
```

**Reihenfolge-Hinweis:**
- Fix-01 erfordert **Driver-Rebuild + install + reload** (Treiber-Code).
- Fix-02..05, Fix-08 erfordern **Helper-Rebuild**. Wenn der Helper als eingebettetes Binary
  im Driver-Bundle läuft, ebenfalls Driver-Bundle neu bauen + installieren. Läuft der Helper
  standalone (Dev-Pfad `helper/build/`), reicht Helper-Rebuild + Helper-Neustart.
- Fix-06/07 erfordern nur Engine-Neustart (Python).

---

## 7. Abschluss-Audit Checkliste

**A. Code-Korrektheit (statisch):**
- ☐ Fix-01: `<math.h>` inkludiert, `kDefaultSampleRate` verwendet, CAS auf `expected=0`.
- ☐ Fix-02: Kein `usleep`/`AudioDevice*` mehr unter `g_outputs_lock`; UID-Re-Validierung in
  Phase 3c vorhanden; IOProc-Cleanup auf verschwundenem Slot ohne Lock.
- ☐ Fix-03: Kein `pthread_mutex_lock(&g_outputs_lock)` mehr um `sr_reinit_all_outputs()`.
- ☐ Fix-04: Alle `AudioDeviceStop/Destroy/Create/Start` + `usleep` lockfrei; `active`/`proc_id`
  nur unter kurzem Lock; `sr_changing`-Gate zuletzt geöffnet.
- ☐ Fix-05: Swap-Remove unter kurzem Lock, Teardown lockfrei.
- ☐ Fix-06: `STATUS_POLL_TIMEOUT=1.0`, `READ_TIMEOUT=5.0`, `get_status` nutzt `effective`.
- ☐ Fix-07: `_spawn_lock` eingeführt, `self._proc` unter kurzem `self._lock` gesetzt,
  Wartephasen lockfrei, Double-Spawn-Re-Check vorhanden.
- ~~☐ Fix-08: `find_coreaudiod_pid` via sysctl, `proc_pid_rusage`-Sampling, 90%/5s-Filter,
  `kill(pid,0)`-Liveness, kein `killall`, Flag-Datei nicht-destruktiv.~~ **GESTRICHEN.**
- ☐ Jeder geänderte Lock-Pfad hat auf **jedem** Return-Pfad ein passendes `unlock`
  (kein Lock-Leak). Manuell pro Funktion durchzählen.

**B. Build:**
- ☐ `make` (helper) ohne Warnungen (`-Wall -Wextra`).
- ☐ `make` (driver) ohne Warnungen.
- ☐ `python3 -m py_compile helper_client.py` grün.
- ☐ Universal-Binary verifiziert: `lipo -archs build/AudioRouterNowHelper` → `arm64 x86_64`.

**C. Funktional (nach Install):**
- ☐ Checkpoint-Smoke-Test (§4) komplett grün.
- ☐ Fix-05: USB-Gerät abziehen während Audio → sauber entfernt, UI responsiv.
- ☐ Fix-06: Helper `kill -STOP` → `get_status` < 1 s, UI klickbar.
- ☐ Fix-07: paralleles `ensure_running` + `get_status` → kein 25-s-Hänger, kein Doppel-Spawn.
- ~~☐ Fix-08: Watchdog-Logik mit gesenktem Schwellwert verifiziert, danach zurückgesetzt.~~ **GESTRICHEN.**

**D. Regression / Stabilität:**
- ☐ 30 Min Dauerbetrieb mit Quell-/SR-/Geräte-Wechseln → kein Freeze, kein Crash, `coreaudiod`
  CPU stabil niedrig.
- ☐ TSan-Build (optional) ohne Data-Race-Reports auf `g_outputs[]`.
- ☐ Kein verwaister IOProc nach Add/Remove-Stress (Activity Monitor / Audio-MIDI-Setup).
- ☐ Helper-Log frei von Endlos-Retry-Spam.

**E. Doku / Abschluss:**
- ☐ `DOKUMENTATION.md` / `RELEASE_NOTES.md` um die 8 Fixes ergänzt.
- ☐ Alle 8 Commits einzeln, mit den Templates aus diesem Plan.
- ☐ Folge-Tasks vermerkt: P2-B (dedizierter CoreAudio-Ops-Thread), UI-Anbindung der
  `coreaudiod_spin.flag` (kontrollierter Treiber-Reload-Dialog), evtl. `outputs_stop_all`
  lockfrei härten.

---

*Ende PLAN.md*
