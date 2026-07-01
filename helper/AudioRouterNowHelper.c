/*
 * AudioRouterNowHelper.c — v3.1.2 (Multi-Device + Config-Socket + Volume-Polling + launchd-ready)
 *
 * Liest Audio-Frames aus dem POSIX-SHM-Ring (geschrieben vom HAL-Plugin)
 * und gibt sie via CoreAudio AudioDeviceIOProc an EIN ODER MEHRERE physische
 * Output-Devices aus.
 *
 * Architektur:
 *   - Producer (Driver) schreibt in den SPSC-Ring.
 *   - Pro Output-Device gibt es eine eigene IOProc + eigenen `local_ridx`
 *     (lokale Leseposition, nicht im SHM-Header).
 *   - Damit der Producer nicht ueberfaehrt: ring->read_idx wird vom Helper
 *     periodisch auf das MINIMUM aller local_ridx gesetzt — so bleibt der
 *     Driver mit dem Original-SPSC-Verhalten ABI-kompatibel.
 *
 * Aufruf (Test im Terminal):
 *   AudioRouterNowHelper                              # Default-Output (Auto)
 *   AudioRouterNowHelper <device-uid-1> [<uid-2> ...] # Bestimmte Devices per UID
 *
 * Config-Socket (Phase 3):
 *   /tmp/audiorouter.config.sock — JSON-Lines Protokoll, von Python steuerbar.
 *
 * Build:
 *   cd helper && make
 *
 * (c) 2026 AudioRouterNow
 */

#include "shared_ring.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_act.h>
#include <mach/thread_policy.h>

#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/file.h>   /* M8: flock() fuer Single-Instance-Lock */
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <pthread.h>
#include <stdbool.h>
#include <errno.h>
#include <stdatomic.h>
#include <limits.h>   /* MC-9: INT_MIN/INT_MAX fuer strtol-Range-Check */
#include <time.h>     /* KC-2: clock_gettime_nsec_np fuer Deferred-Unmap-Epoch */

/* ── Konfiguration ──────────────────────────────────────────────────────── */

/* I-5: Versions-Fallback — sollte NIE greifen, da beide Makefiles
 * (helper/Makefile + driver/Makefile) -DARN_HELPER_VERSION via python3
 * aus engine/version.py injizieren. "UNKNOWN" macht einen Build-Fehler
 * sofort sichtbar statt still die falsche Version zu melden. */
#ifndef ARN_HELPER_VERSION
#define ARN_HELPER_VERSION "UNKNOWN"
#endif
static const char g_helper_version[] = ARN_HELPER_VERSION;

#define OUR_DEVICE_UID         "com.audiorouter.now.device"   /* virtuelles Device ausschliessen */
#define SHM_RETRY_INTERVAL_US  500000                          /* 500ms zwischen shm_open-Versuchen */
/* H7: Socket in user-privatem Verzeichnis statt world-writable /tmp.
 * Pfad wird zur Laufzeit aus $HOME gebildet — kein TOCTOU-Risiko. */
static char g_config_socket_path[512] = {0};
#define VOLUME_POLL_INTERVAL_US 50000                          /* 50ms Volume-Polling */
#define STALL_TIMEOUT_NS  (1000ULL * 1000ULL * 1000ULL)  /* K2: 1000ms ohne Fortschritt = Stall
                                                            * (erhöht von 300ms — SRC-Boundary-
                                                            * Instabilität braucht mehr Settle-Zeit) */
/* P6: Hard-Stall — schnellere Erkennung (~300ms) NUR wenn der IOProc nachweislich
 * laeuft (ioproc_calls steigt) aber NICHT konsumiert (ridx eingefroren) UND der
 * Ring sehr voll ist (>75%). Diese Kombination ist kein normaler Underrun und
 * tritt auch bei 44.1kHz nicht faelschlich auf — daher das kurze Fenster. */
#define HARD_STALL_TIMEOUT_NS  (300ULL * 1000ULL * 1000ULL)  /* 300ms */
#define HARD_STALL_FILL_NUM    3u   /* Ring-Fill-Schwelle: > 75% = 3/4 der Kapazitaet */
#define HARD_STALL_FILL_DEN    4u

#define MAX_OUTPUTS            8

/* ARC-4: Pre-Roll High-Water-Mark. 2048 Frames ≈ 43ms @48kHz.
 * (Vorher ARN_RING_CAPACITY/4 = 4096 Frames ≈ 85ms — der Kommentar "43ms"
 * war korrekt, der Wert falsch.) */
#define ARN_PREROLL_FRAMES (ARN_RING_CAPACITY / 8u)   /* 2048 frames ≈ 43ms @48kHz */

/* P11: Lock-Datei liegt in ~/.audiorouter/ (statt im world-writable /tmp).
 * Pfad zur Laufzeit aus $HOME gebildet, geoeffnet mit O_NOFOLLOW. */
static char g_lock_path[512] = {0};
static int g_lock_fd = -1;

/* P3: Per-Launch Auth-Token (64 Hex-Zeichen + NUL). Beim Start aus
 * /dev/urandom erzeugt und nach ~/.audiorouter/helper.token (0600)
 * geschrieben. Privilegierte Socket-Kommandos muessen dieses Token
 * mitschicken. */
static char g_auth_token[65] = {0};
static char g_token_path[512] = {0};

/* P11/H7: Stellt sicher, dass ~/.audiorouter/ mit 0700 existiert und befuellt
 * g_config_socket_path + g_lock_path. MUSS vor helper_acquire_instance_lock()
 * laufen, damit das Verzeichnis fuer die Lock-Datei bereits existiert.
 * MC-5: Prueft nach mkdir per lstat Owner + Permissions des Verzeichnisses —
 * ein untergeschobenes Verzeichnis (Symlink, fremder Owner, lockere Rechte)
 * fuehrt zum Abbruch. Rueckgabe: true = OK, false = Sicherheitsfehler. */
static bool config_socket_path_init(void)
{
    const char *home = getenv("HOME");
    if (!home || !home[0]) home = "/tmp";
    /* Sicherstellen dass ~/.audiorouter/ mit 0700 existiert */
    char dir[480];
    snprintf(dir, sizeof(dir), "%s/.audiorouter", home);
    mkdir(dir, 0700);  /* Fehler (existiert schon) ignorieren */

    /* MC-5: Ownership/Permission-Pruefung — lstat folgt Symlinks NICHT,
     * ein Symlink anstelle des Verzeichnisses faellt durch S_ISDIR. */
    struct stat st;
    if (lstat(dir, &st) != 0) {
        fprintf(stderr, "[ARN] Sicherheitsfehler: lstat('%s') fehlgeschlagen (errno=%d)\n",
                dir, errno);
        return false;
    }
    if (!S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 0777) != 0700) {
        fprintf(stderr, "[ARN] Sicherheitsfehler: %s hat falsche Owner/Permissions "
                "(uid=%u mode=%04o, erwartet uid=%u mode=0700, dir=%d)\n",
                dir, (unsigned)st.st_uid, (unsigned)(st.st_mode & 0777),
                (unsigned)getuid(), S_ISDIR(st.st_mode) ? 1 : 0);
        return false;
    }

    snprintf(g_config_socket_path, sizeof(g_config_socket_path),
             "%s/.audiorouter/audiorouter.config.sock", home);
    snprintf(g_lock_path, sizeof(g_lock_path),
             "%s/.audiorouter/helper.lock", home);
    snprintf(g_token_path, sizeof(g_token_path),
             "%s/.audiorouter/helper.token", home);
    return true;
}

/* P3: Constant-time Vergleich — verhindert Timing-Seitenkanal beim Token-Check.
 * Vergleicht IMMER alle n Bytes, kein Short-Circuit (im Gegensatz zu memcmp).
 * Rueckgabe: 0 wenn gleich, !=0 sonst. */
static int ct_memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *pa = (const unsigned char *)a;
    const unsigned char *pb = (const unsigned char *)b;
    unsigned char diff = 0;
    for (size_t i = 0; i < n; i++) {
        diff |= (unsigned char)(pa[i] ^ pb[i]);
    }
    return (int)diff;
}

/* P3: Erzeugt 32 Zufallsbytes aus /dev/urandom, formatiert sie als 64 Hex-Zeichen
 * in g_auth_token und schreibt das Token nach ~/.audiorouter/helper.token (0600,
 * O_NOFOLLOW). Rueckgabe: 0 bei Erfolg, -1 bei Fehler. */
static int auth_token_init(void)
{
    unsigned char raw[32];
    int rfd = open("/dev/urandom", O_RDONLY);
    if (rfd < 0) {
        fprintf(stderr, "Helper: /dev/urandom konnte nicht geoeffnet werden (errno=%d)\n", errno);
        return -1;
    }
    size_t got = 0;
    while (got < sizeof(raw)) {
        ssize_t r = read(rfd, raw + got, sizeof(raw) - got);
        if (r <= 0) {
            if (errno == EINTR) continue;
            close(rfd);
            fprintf(stderr, "Helper: Lesen aus /dev/urandom fehlgeschlagen (errno=%d)\n", errno);
            return -1;
        }
        got += (size_t)r;
    }
    close(rfd);

    static const char hexd[] = "0123456789abcdef";
    for (size_t i = 0; i < sizeof(raw); i++) {
        g_auth_token[i * 2]     = hexd[(raw[i] >> 4) & 0xF];
        g_auth_token[i * 2 + 1] = hexd[raw[i] & 0xF];
    }
    g_auth_token[64] = '\0';

    /* O_NOFOLLOW: kein untergeschobener Symlink. O_TRUNC: altes Token ersetzen. */
    unlink(g_token_path); /* alten (evtl. fremden) Eintrag entfernen */
    int tfd = open(g_token_path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (tfd < 0) {
        fprintf(stderr, "Helper: Token-Datei '%s' konnte nicht geschrieben werden (errno=%d)\n",
                g_token_path, errno);
        return -1;
    }
    size_t off = 0;
    while (off < 64) {
        ssize_t w = write(tfd, g_auth_token + off, 64 - off);
        if (w <= 0) {
            if (errno == EINTR) continue;
            close(tfd);
            return -1;
        }
        off += (size_t)w;
    }
    close(tfd);
    return 0;
}

/* P3: Extrahiert den Wert von "token":"..." aus der JSON-Zeile in out (Groesse cap).
 * Rueckgabe: true wenn ein Token gefunden wurde. */
static bool parse_token(const char *line, char *out, size_t cap)
{
    if (cap == 0) return false;
    out[0] = '\0';
    const char *key = strstr(line, "\"token\"");
    if (!key) return false;
    const char *colon = strchr(key, ':');
    if (!colon) return false;
    const char *q1 = strchr(colon, '"');
    if (!q1) return false;
    q1++;
    const char *q2 = strchr(q1, '"');
    if (!q2) return false;
    size_t len = (size_t)(q2 - q1);
    if (len >= cap) len = cap - 1;
    memcpy(out, q1, len);
    out[len] = '\0';
    return true;
}

/* P3: Prueft, ob die Request-Zeile ein gueltiges Auth-Token enthaelt.
 * Constant-time Vergleich. Rueckgabe: true bei gueltigem Token. */
static bool auth_check(const char *line)
{
    char tok[128];
    if (!parse_token(line, tok, sizeof(tok))) {
        return false;
    }
    /* Laengenpruefung VOR ct_memcmp — sonst koennte ein kuerzeres Token
     * out-of-bounds vergleichen. Beide muessen exakt 64 Zeichen sein. */
    if (strlen(tok) != 64 || strlen(g_auth_token) != 64) {
        return false;
    }
    return ct_memcmp(tok, g_auth_token, 64) == 0;
}

/* M8/P11: Single-Instance-Lock — verhindert zwei parallele Helper-Instanzen die
 * sich gegenseitig SHM und Config-Socket ueberschreiben wuerden.
 * O_NOFOLLOW: ein untergeschobener Symlink wird nicht gefolgt (ELOOP) — in dem
 * Fall brechen wir hart ab (potentieller Angriff). */
static int helper_acquire_instance_lock(void)
{
    if (!g_lock_path[0]) {
        /* Defensive: sollte nie passieren, config_socket_path_init() laeuft zuvor. */
        fprintf(stderr, "Helper: Lock-Pfad nicht initialisiert — Abbruch\n");
        return -1;
    }
    g_lock_fd = open(g_lock_path, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (g_lock_fd < 0) {
        if (errno == ELOOP) {
            fprintf(stderr, "Helper: Lock-Datei '%s' ist ein Symlink (O_NOFOLLOW) "
                    "— moeglicher Angriff, Abbruch\n", g_lock_path);
            abort();
        }
        fprintf(stderr, "Helper: Lock-Datei '%s' konnte nicht geoeffnet werden (errno=%d)\n",
                g_lock_path, errno);
        return -1;
    }
    if (flock(g_lock_fd, LOCK_EX | LOCK_NB) != 0) {
        fprintf(stderr, "Helper: Eine andere Helper-Instanz laeuft bereits — Abbruch\n");
        close(g_lock_fd);
        g_lock_fd = -1;
        return -1;
    }
    return 0;
}

/* ── Datenstrukturen ────────────────────────────────────────────────────── */

typedef struct DeviceOutput {
    AudioDeviceID        dev_id;
    AudioDeviceIOProcID  proc_id;
    _Atomic uint32_t     local_ridx;     /* Eigene Leseposition (nicht in SHM) */
    uint32_t             ch_offset;      /* 0=Ch1-2, 2=Ch3-4, ...                */
    char                 uid[512];
    char                 name[256];
    bool                 active;
    _Atomic uint32_t     underruns;      /* Diagnostic: Underrun-Zaehler         */
    /* K2: Stall-Detection — nur vom Volume-Thread gelesen/geschrieben (kein Lock nötig
     * da nur ein Thread diese Felder modifiziert). stalled ist atomic für Diagnose. */
    uint32_t         last_ridx_sample;   /* zuletzt gesehener local_ridx-Wert    */
    uint64_t         last_progress_ns;   /* mach_absolute_time() der letzten Bewegung */
    _Atomic uint32_t stalled;            /* 1 = als gestallt markiert (Diagnose)  */
    /* P6: Hard-Stall-Detection (~300ms). Der IOProc inkrementiert ioproc_calls
     * bei jedem Aufruf (RT-safe, relaxed). Der Health-Check erkennt einen
     * Hard-Stall wenn GLEICHZEITIG: ridx eingefroren, Ring-Fill > 75% UND
     * ioproc_calls steigt (IOProc laeuft, konsumiert aber nicht). 300ms-Fenster
     * vermeidet 44.1kHz-False-Positives des langsameren Soft-Stalls (1000ms). */
    _Atomic uint32_t ioproc_calls;          /* vom IOProc inkrementiert (RT)        */
    uint32_t         last_ioproc_calls_sample; /* letzter im Health-Check gesehener Wert */
    uint64_t         hard_stall_since_ns;   /* Beginn des Hard-Stall-Fensters (0=keins) */
    _Atomic uint32_t recovery_count;     /* Diagnose: wie oft hat sich dieser Output von einem Stall erholt */
    /* Tranche B: Pre-Roll High-Water-Mark.
     * preroll_armed=1 -> IOProc gibt Stille bis Ring >= preroll_target_frames,
     * dann self-clear (release-store auf 0). Re-armed nach SHM-Reconnect. */
    _Atomic uint32_t preroll_target_frames; /* HWM in Frames (0=deaktiviert) */
    _Atomic uint32_t preroll_armed;         /* 1=IOProc gibt Stille bis HWM, dann self-clear */
    /* P9: Sample-Rate-Wechsel-Gate. Waehrend sr_reinit_all_outputs den IOProc
     * stoppt/neu erstellt, gibt der IOProc reine Stille aus (kein Klicken durch
     * inkonsistente Ring-SR / halb-rekonfigurierte Devices). Atomar, RT-gelesen. */
    _Atomic uint32_t sr_changing;           /* 1=IOProc gibt Stille (SR-Wechsel laeuft) */
    /* Tranche C: PI-Regler State — NUR vom volume_poll_thread gelesen/geschrieben.
     * Kein Atomic nötig: ausschließlich non-RT-Zugriff unter g_outputs_lock. */
    double fill_ewma;    /* EWMA des Ring-Füllstands in Frames (Tranche C Glättung) */
    double integ_error;  /* Integrator-Akkumulator für I-Term */
    /* Phase 6 — Adaptive SRC fuer Clock-Drift-Kompensation */
    double               src_frac_ridx;    /* fraktionaler Leseindex — NUR vom IOProc-Thread gelesen/geschrieben */
    _Atomic uint32_t     src_ratio_q20;    /* Q20-Ratio: base_ratio = 1<<20. Volume-Thread schreibt, IOProc liest */
    uint32_t             src_ring_target;  /* Ziel-Fuellstand in Samples (= ARN_RING_CAPACITY/2) */
    double               base_ratio;       /* ring_sr / device_sr: 1.0 bei gleicher Rate, z.B. 1.0884 bei 44100->48000 */
    /* K6/KC-3: RT-sicherer Pending-Reset fuer src_frac_ridx — Generationszaehler.
     * Volume-Thread/sr_reinit darf src_frac_ridx NICHT direkt schreiben
     * (Data Race mit IOProc). Stattdessen: Zielwert setzen (release), dann
     * frac_ridx_reset_gen inkrementieren (acq_rel). Der IOProc vergleicht
     * gegen seine private frac_ridx_applied_gen und wendet den Reset an.
     * Gen-Zaehler statt bool-Flag: das alte Flag hatte ein Lost-Update-Race
     * (zweiter Reset-Request zwischen Flag-Load und Flag-Clear ging verloren). */
    _Atomic uint32_t     frac_ridx_reset_gen;   /* steigt bei jedem Reset-Request    */
    uint32_t             frac_ridx_applied_gen; /* IOProc-privat, kein Atomic noetig */
    _Atomic uint32_t     frac_ridx_reset_widx;  /* Ziel sample-index fuer reset      */
    /* Pre-allokierter Temp-Buffer fuer De-Interleaving im IOProc (RT-safe). */
    float                temp_buf[ARN_RING_CAPACITY];
} DeviceOutput;

/* ── Globaler Zustand ───────────────────────────────────────────────────── */

static atomic_int              g_running        = 1;
/* F1: Signal-Zaehler — zweites SIGTERM/SIGINT erzwingt sofortiges _exit(1). */
static _Atomic int             g_signal_count   = 0;
/* H2: g_ring als atomarer Pointer — IOProc lädt ihn einmal per acquire
 * am Call-Anfang; Reconnect-Code kann ihn sicher per release-Store tauschen
 * ohne SIGBUS-Risiko für laufende IOProcs. */
static _Atomic(ARNSharedRing *) g_ring           = NULL;
static int                     g_shm_fd         = -1;

static DeviceOutput            g_outputs[MAX_OUTPUTS];
/* Tombstoning (Batch 9): g_n_outputs ist eine HIGH-WATER-MARK — "hoechster je
 * belegter Slot-Index + 1". Sie waechst monoton (Reset nur in outputs_stop_all).
 * Ein Slot ist FREI wenn active==false UND uid[0]=='\0' (Tombstone).
 * output_remove markiert Slots nur als Tombstone, verschiebt sie NIE —
 * dadurch bleibt &g_outputs[slot] (inClientData der IOProcs) stabil und
 * uninvolvierte Outputs muessen bei einem Remove nicht neu gestartet werden. */
static int                     g_n_outputs      = 0;
/* Anzahl derzeit AKTIVER Outputs (active==true) — fuer Diagnose/Status.
 * Wird unter g_outputs_lock via recount_active_locked() gepflegt. */
static int                     g_n_active_outputs = 0;
static pthread_mutex_t         g_outputs_lock   = PTHREAD_MUTEX_INITIALIZER;
/* MC-6: Generationszaehler fuer g_outputs[] — wird in outputs_stop_all()
 * inkrementiert. output_add() vergleicht die Generation vor/nach dem
 * lockfreien CoreAudio-Block und bricht ab wenn der Watchdog (oder Shutdown)
 * waehrenddessen alle Outputs gestoppt hat (Race-Schutz). */
static _Atomic uint32_t        g_outputs_generation = 0;

/* Diagnostic: wie oft wurde IRGENDEIN IOProc aufgerufen? */
static _Atomic uint32_t        g_ioproc_calls   = 0;

/* Tranche A: Self-Healing-Telemetrie */
static _Atomic uint32_t        g_reconnect_count    = 0;  /* Wie oft wurde SHM neu verbunden */
static _Atomic uint64_t        g_last_ioproc_call_ns = 0; /* Zeitstempel letzter IOProc-Call */

/* Config-Socket Thread */
static pthread_t               g_config_thread;
static int                     g_config_listen_fd = -1;
static atomic_int              g_config_running   = 0;

/* Volume-Polling Thread */
static pthread_t               g_volume_thread;
static atomic_int              g_volume_running   = 0;
/* NC-1: pthread_t ist ein opaker Typ — darf nicht als Wahrheitswert genutzt
 * werden. Explizites Flag, gesetzt nach erfolgreichem pthread_create. */
static bool                    g_volume_thread_started = false;

/* Hot-Plug-Listener flag */
static atomic_int              g_hotplug_registered = 0;

/* SHM-Bereitschafts-Flag: 0 = noch nicht verbunden, 1 = Ring bereit */
static atomic_int              g_shm_ready          = 0;

/* Tranche B: Safe-Take-Modus — deaktiviert alle Heiler-Aktuatoren,
 * erlaubt nur Telemetrie. Fuer Recording/Live-Situationen. */
static atomic_int              g_safe_take          = 0;

/* P5: Auto-Sample-Rate. 1 = der Ring folgt der nativen SR des ersten Outputs
 * (kein Forcieren von 48kHz). 0 = Manueller Modus (set_sample_rate steuert). */
static atomic_int              g_auto_sample_rate   = 1;

/* H3: Hot-Plug-Flag — Callback setzt nur dieses Flag, Volume-Thread reagiert.
 * Kein CoreAudio-Call im Property-Callback-Kontext (Re-Entry-Deadlock-Risiko). */
static atomic_int              g_hotplug_pending    = 0;

/* Keep-Alive IOProc — hält das virtuelle "Audio Router" Device dauerhaft running.
 * Registriert in C (nicht Python) damit der Funktionszeiger für die gesamte
 * Lebensdauer des Helper-Prozesses stabil bleibt — kein Stale-Pointer-Problem
 * wie bei Python-ctypes-Callbacks nach Prozess-Exit. */
static AudioDeviceID           g_keepalive_dev_id  = kAudioDeviceUnknown;
static AudioDeviceIOProcID     g_keepalive_proc_id = NULL;

/* ── Forward Declarations ───────────────────────────────────────────────── */

static inline uint64_t get_time_ns(void);  /* K2: Stall-Detection Zeitstempel */
static int   output_add(const char *uid, uint32_t ch_offset);
/* output_add_locked: entfernt in v2.8 (H1) — ersetzt durch output_add() */
static void  output_remove_locked(const char *uid, uint32_t ch_offset);
static void  outputs_stop_all(void);
static char *device_get_uid(AudioDeviceID dev_id);
static char *device_get_name(AudioDeviceID dev_id);
static AudioDeviceID find_device_by_uid(const char *uid);
static void  update_global_read_idx(void);

/* ── Signal-Handler ─────────────────────────────────────────────────────── */

static void handle_signal(int sig)
{
    (void)sig;
    if (atomic_fetch_add_explicit(&g_signal_count, 1, memory_order_relaxed) > 0) {
        _exit(1);
    }
    atomic_store_explicit(&g_running, 0, memory_order_release);
}
static void handle_alarm(int sig) { (void)sig; _exit(1); }

/* ── Keep-Alive IOProc ──────────────────────────────────────────────────── */

/*
 * keepalive_ioproc — No-Op-Callback auf dem virtuellen "Audio Router" Device.
 *
 * Hält gDeviceIsRunning=1 im HAL-Driver dauerhaft aufrecht, unabhängig davon
 * ob externe Apps (Apple Music, Spotify) gerade einen IOProc hören.
 *
 * Läuft auf einem CoreAudio-RT-Thread. Darf keine Locks, malloc oder blocking
 * Calls enthalten. Diese Implementierung tut genau nichts — korrekt so.
 */
static OSStatus keepalive_ioproc(AudioDeviceID           inDevice,
                                  const AudioTimeStamp   *inNow,
                                  const AudioBufferList  *inInputData,
                                  const AudioTimeStamp   *inInputTime,
                                  AudioBufferList        *outOutputData,
                                  const AudioTimeStamp   *inOutputTime,
                                  void                   *inClientData)
{
    (void)inDevice; (void)inNow; (void)inInputData; (void)inInputTime;
    (void)outOutputData; (void)inOutputTime; (void)inClientData;
    return noErr;
}

static void keepalive_start(AudioDeviceID dev)
{
    if (dev == kAudioDeviceUnknown) {
        fprintf(stderr, "Helper: Keep-Alive — virtuelles Device nicht gefunden\n");
        return;
    }
    OSStatus err = AudioDeviceCreateIOProcID(dev, keepalive_ioproc, NULL,
                                              &g_keepalive_proc_id);
    if (err != noErr) {
        fprintf(stderr, "Helper: Keep-Alive AudioDeviceCreateIOProcID err=%d\n", err);
        return;
    }
    err = AudioDeviceStart(dev, g_keepalive_proc_id);
    if (err != noErr) {
        fprintf(stderr, "Helper: Keep-Alive AudioDeviceStart err=%d\n", err);
        AudioDeviceDestroyIOProcID(dev, g_keepalive_proc_id);
        g_keepalive_proc_id = NULL;
        return;
    }
    g_keepalive_dev_id = dev;
    fprintf(stdout, "Helper: Keep-Alive IOProc gestartet (Device ID %u)\n", dev);
}

static void keepalive_stop(void)
{
    if (g_keepalive_proc_id == NULL) return;
    AudioDeviceStop(g_keepalive_dev_id, g_keepalive_proc_id);
    AudioDeviceDestroyIOProcID(g_keepalive_dev_id, g_keepalive_proc_id);
    g_keepalive_proc_id = NULL;
    g_keepalive_dev_id  = kAudioDeviceUnknown;
    fprintf(stdout, "Helper: Keep-Alive IOProc gestoppt\n");
}

/* ── SHM-Verbindung ─────────────────────────────────────────────────────── */

static ARNSharedRing *shm_connect(void)
{
    int fd = shm_open(ARN_SHM_NAME, O_RDWR, 0);
    if (fd < 0) {
        return NULL;
    }

    void *ptr = mmap(NULL, ARN_SHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) {
        close(fd);
        return NULL;
    }

    ARNSharedRing *ring = (ARNSharedRing *)ptr;

    /* ABI-Versionscheck — Segment muss vom aktuellen Plugin stammen. */
    if (ring->magic != ARN_RING_MAGIC || ring->version != ARN_RING_VERSION) {
        fprintf(stderr, "Helper: SHM magic/version mismatch "
                "(got magic=0x%08X ver=%u, expected 0x%08X ver=%u) — warte...\n",
                ring->magic, ring->version, ARN_RING_MAGIC, ARN_RING_VERSION);
        munmap(ptr, ARN_SHM_SIZE);
        close(fd);
        return NULL;
    }

    /* NC-6: Layout-Validierung — capacity/channels muessen zur kompilierten
     * Ring-Geometrie passen. Ein abweichendes Segment (fremder/korrupter
     * Writer) wuerde sonst zu Out-of-Bounds-Indexierung im IOProc fuehren. */
    if (ring->capacity != ARN_RING_CAPACITY || ring->channels != 2u) {
        fprintf(stderr, "Helper: SHM layout mismatch "
                "(capacity=%u channels=%u, expected capacity=%u channels=2) — warte...\n",
                ring->capacity, ring->channels, ARN_RING_CAPACITY);
        munmap(ptr, ARN_SHM_SIZE);
        close(fd);
        return NULL;
    }

    g_shm_fd = fd;
    fprintf(stdout, "Helper: SHM verbunden — %s (%u Frames Kapazitaet, SR=%u)\n",
            ARN_SHM_NAME, ring->capacity / ring->channels, ring->sample_rate);
    return ring;
}

/* H2: Deferred-Unmap — beim Live-Reconnect das alte Segment nicht sofort
 * unmappen, sondern erst im naechsten Volume-Zyklus (50ms spaeter).
 * Bis dahin sind alle in-flight IOProc-Calls (<1ms) garantiert durch. */
static ARNSharedRing *g_pending_unmap_ring = NULL;
static int            g_pending_unmap_fd   = -1;
/* KC-2: Epoch des Defer-Zeitpunkts (CLOCK_MONOTONIC, ns). munmap() erfolgt
 * erst wenn seit dem Defer mindestens 150ms vergangen sind — damit ist
 * garantiert, dass auch ein IOProc, der den alten g_ring-Pointer unmittelbar
 * vor dem Swap geladen hat, laengst fertig ist (IOProc-Laufzeit < 1ms;
 * jeder neue Call laedt g_ring per acquire neu und sieht NULL/neu). */
static _Atomic uint64_t g_deferred_unmap_timestamp_ns = 0;
#define ARN_DEFERRED_UNMAP_GRACE_NS 150000000ULL   /* 150ms */

/* Unbedingtes Freigeben des Pending-Rests (interner Helfer). */
static void shm_flush_pending_unmap_force(void)
{
    if (g_pending_unmap_ring != NULL) {
        munmap(g_pending_unmap_ring, ARN_SHM_SIZE);
        g_pending_unmap_ring = NULL;
    }
    if (g_pending_unmap_fd >= 0) {
        close(g_pending_unmap_fd);
        g_pending_unmap_fd = -1;
    }
}

/* Gibt ggf. ausstehenden alten Ring aus dem letzten Reconnect frei.
 * KC-2: Nur wenn die 150ms-Grace-Period seit dem Defer abgelaufen ist. */
static void shm_flush_pending_unmap(void)
{
    if (g_pending_unmap_ring == NULL && g_pending_unmap_fd < 0) return;
    uint64_t ts  = atomic_load(&g_deferred_unmap_timestamp_ns);
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    if (now - ts < ARN_DEFERRED_UNMAP_GRACE_NS) return; /* 150ms nicht abgewartet */
    shm_flush_pending_unmap_force();
}

/* Deferred-Disconnect fuer Live-Reconnect: altes Segment merken, nicht sofort
 * unmappen. Ein spaeterer shm_flush_pending_unmap()-Call (Volume-Zyklus, nach
 * Ablauf der 150ms-Grace-Period) raeumt es auf. Caller muss sicherstellen dass
 * IOProcs vorher atomic-NULL sehen. */
static void shm_disconnect_deferred(void)
{
    /* Erst vorherigen Pending-Rest freigeben — hier unconditional (force):
     * das Segment wurde bereits beim letzten Defer aus g_ring entfernt,
     * in-flight IOProcs (<1ms) sind durch. Mit dem Epoch-Guard wuerde der
     * Pointer sonst ueberschrieben werden → Leak. */
    shm_flush_pending_unmap_force();

    ARNSharedRing *old = atomic_exchange_explicit(&g_ring, NULL, memory_order_acq_rel);
    g_pending_unmap_ring = old;
    g_pending_unmap_fd   = g_shm_fd;
    g_shm_fd = -1;
    /* KC-2: Defer-Epoch setzen — startet die 150ms-Grace-Period. */
    atomic_store(&g_deferred_unmap_timestamp_ns,
                 clock_gettime_nsec_np(CLOCK_MONOTONIC));
}

static void shm_disconnect(void)
{
    /* F5: atomarer Exchange statt load+store — kein Fenster, in dem ein
     * IOProc den alten Pointer nach munmap noch laden koennte. */
    ARNSharedRing *old_ring = atomic_exchange_explicit(&g_ring, NULL, memory_order_acq_rel);
    if (old_ring != NULL) {
        munmap(old_ring, ARN_SHM_SIZE);
    }
    if (g_shm_fd >= 0) {
        close(g_shm_fd);
        g_shm_fd = -1;
    }
}

/* ── CoreAudio Device-Helfer ────────────────────────────────────────────── */

static char *device_get_uid(AudioDeviceID dev_id)
{
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyDeviceUID,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };
    CFStringRef uid_ref = NULL;
    UInt32 size = sizeof(CFStringRef);
    OSStatus err = AudioObjectGetPropertyData(dev_id, &addr, 0, NULL, &size, &uid_ref);
    if (err != noErr || uid_ref == NULL) return NULL;

    char *buf = (char *)malloc(512);
    if (buf) {
        if (!CFStringGetCString(uid_ref, buf, 512, kCFStringEncodingUTF8)) {
            buf[0] = '\0';
        }
    }
    CFRelease(uid_ref);
    return buf;
}

static char *device_get_name(AudioDeviceID dev_id)
{
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyDeviceNameCFString,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };
    CFStringRef name_ref = NULL;
    UInt32 size = sizeof(CFStringRef);
    OSStatus err = AudioObjectGetPropertyData(dev_id, &addr, 0, NULL, &size, &name_ref);
    if (err != noErr || name_ref == NULL) return strdup("(unbekannt)");

    char *buf = (char *)malloc(256);
    if (buf) {
        if (!CFStringGetCString(name_ref, buf, 256, kCFStringEncodingUTF8)) {
            strcpy(buf, "(unbekannt)");
        }
    }
    CFRelease(name_ref);
    return buf;
}

static UInt32 device_output_channels(AudioDeviceID dev_id)
{
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyStreamConfiguration,
        .mScope    = kAudioDevicePropertyScopeOutput,
        .mElement  = kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev_id, &addr, 0, NULL, &size) != noErr || size == 0)
        return 0;

    AudioBufferList *list = (AudioBufferList *)malloc(size);
    if (!list) return 0;
    UInt32 channels = 0;
    if (AudioObjectGetPropertyData(dev_id, &addr, 0, NULL, &size, list) == noErr) {
        for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
            channels += list->mBuffers[i].mNumberChannels;
        }
    }
    free(list);
    return channels;
}

/*
 * Sucht ein Device anhand UID-String. Gibt kAudioDeviceUnknown zurueck wenn
 * nicht gefunden oder kein Output-Geraet (>=2 Channels).
 */
static AudioDeviceID find_device_by_uid(const char *uid)
{
    if (!uid || !*uid) return kAudioDeviceUnknown;

    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr,
                                       0, NULL, &size) != noErr) return kAudioDeviceUnknown;

    UInt32 count = size / sizeof(AudioDeviceID);
    AudioDeviceID *devices = (AudioDeviceID *)malloc(size);
    if (!devices) return kAudioDeviceUnknown;

    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devices);

    AudioDeviceID result = kAudioDeviceUnknown;
    for (UInt32 i = 0; i < count; i++) {
        char *dev_uid = device_get_uid(devices[i]);
        if (!dev_uid) continue;  /* M4: malloc-Fehler — Slot überspringen */
        if (strcmp(dev_uid, uid) == 0 && device_output_channels(devices[i]) >= 2) {
            result = devices[i];
            free(dev_uid);
            break;
        }
        free(dev_uid);
    }
    free(devices);
    return result;
}

/* Gibt die AudioDeviceID des virtuellen "Audio Router" Devices zurueck (oder kAudioDeviceUnknown). */
static AudioDeviceID find_audio_router_device(void) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr)
        return kAudioDeviceUnknown;
    int n = (int)(size / sizeof(AudioDeviceID));
    AudioDeviceID *list = malloc(size);
    if (!list) return kAudioDeviceUnknown;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, list);

    AudioObjectPropertyAddress uid_addr = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID result = kAudioDeviceUnknown;
    for (int i = 0; i < n; i++) {
        CFStringRef uid_ref = NULL;
        UInt32 sz = sizeof(CFStringRef);
        if (AudioObjectGetPropertyData(list[i], &uid_addr, 0, NULL, &sz, &uid_ref) != noErr)
            continue;
        char buf[256] = {0};
        if (uid_ref) {
            CFStringGetCString(uid_ref, buf, sizeof(buf), kCFStringEncodingUTF8);
            CFRelease(uid_ref);
        }
        if (strcmp(buf, OUR_DEVICE_UID) == 0) {
            result = list[i];
            break;
        }
    }
    free(list);
    return result;
}

/*
 * Auto-Auswahl: erstes echtes Output-Device (>=2 Kanaele), das nicht das
 * eigene virtuelle ist. Wird verwendet wenn kein UID-Hint vorhanden ist.
 *
 * P5: KEINE Bevorzugung von 48kHz mehr — der Ring folgt im Auto-Modus der
 * nativen Rate des gewaehlten Devices (siehe output_add / g_auto_sample_rate).
 */
static AudioDeviceID find_default_output_device(void)
{
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr,
                                       0, NULL, &size) != noErr) return kAudioDeviceUnknown;

    UInt32 count = size / sizeof(AudioDeviceID);
    AudioDeviceID *devices = (AudioDeviceID *)malloc(size);
    if (!devices) return kAudioDeviceUnknown;

    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devices);

    AudioDeviceID result = kAudioDeviceUnknown;

    for (UInt32 i = 0; i < count; i++) {
        char *uid = device_get_uid(devices[i]);
        UInt32 out_ch = device_output_channels(devices[i]);
        if (out_ch >= 2 && uid && strcmp(uid, OUR_DEVICE_UID) != 0) {
            /* Erstes geeignetes Device gewinnt — unabhaengig von seiner SR. */
            result = devices[i];
            free(uid);
            break;
        }
        free(uid);
    }
    free(devices);
    return result;
}

/* ── CoreAudio IOProc — pro Device ──────────────────────────────────────── */

/*
 * device_ioproc — pro DeviceOutput aufgerufen vom CoreAudio RT-Thread.
 *
 * Liest aus dem SHM-Ring via lokalem read_idx (NICHT der globale ring->read_idx),
 * sodass mehrere Outputs unabhaengig konsumieren koennen.
 *
 * RT-Safe: kein malloc, kein Lock, kein printf.
 */
static OSStatus device_ioproc(AudioDeviceID           inDevice,
                              const AudioTimeStamp   *inNow,
                              const AudioBufferList  *inInputData,
                              const AudioTimeStamp   *inInputTime,
                              AudioBufferList        *outOutputData,
                              const AudioTimeStamp   *inOutputTime,
                              void                   *inClientData)
{
    (void)inDevice; (void)inNow;
    (void)inInputData; (void)inInputTime; (void)inOutputTime;

    atomic_fetch_add_explicit(&g_ioproc_calls, 1u, memory_order_relaxed);
    /* Tranche A: Zeitstempel des letzten echten Audio-IOProc-Calls (nur device_ioproc,
     * NICHT keepalive_ioproc — keepalive macht kein echtes Audio). RT-safe relaxed store. */
    atomic_store_explicit(&g_last_ioproc_call_ns, get_time_ns(), memory_order_relaxed);

    DeviceOutput  *dev  = (DeviceOutput *)inClientData;
    /* H2: g_ring atomar mit acquire laden — sieht immer entweder das alte
     * oder das neue (nie ein Halb-Pointer) und verhindert SIGBUS nach
     * deferred-munmap im Reconnect-Pfad. */
    ARNSharedRing *ring = atomic_load_explicit(&g_ring, memory_order_acquire);

    if (!dev || !ring || !outOutputData) return noErr;

    /* P6: Pro-Output IOProc-Call-Zaehler — Basis fuer Hard-Stall-Detection.
     * RT-safe: nur relaxed atomic increment. */
    atomic_fetch_add_explicit(&dev->ioproc_calls, 1u, memory_order_relaxed);

    /* K6/KC-3: Pending-Reset fuer src_frac_ridx — RT-safe, kein Lock.
     * Volume-Thread/sr_reinit schreibt erst frac_ridx_reset_widx (release),
     * dann inkrementiert er frac_ridx_reset_gen (acq_rel). Der acquire-Load
     * auf gen macht den widx-Store sichtbar. IOProc wendet den Reset hier an
     * (einziger Schreiber von src_frac_ridx). Gen-Vergleich statt bool-Flag:
     * kein Lost-Update-Race mehr bei back-to-back Reset-Requests. */
    {
        uint32_t req_gen = atomic_load_explicit(&dev->frac_ridx_reset_gen,
                                                memory_order_acquire);
        if (req_gen != dev->frac_ridx_applied_gen) {
            uint32_t target_widx = atomic_load_explicit(&dev->frac_ridx_reset_widx,
                                                        memory_order_acquire);
            dev->src_frac_ridx = (double)target_widx / 2.0;
            dev->frac_ridx_applied_gen = req_gen;
        }
    }

    /* P9: SR-Wechsel-Gate — VOR dem Pre-Roll-Gate pruefen. Waehrend
     * sr_reinit_all_outputs laeuft (Device gestoppt/neu konfiguriert, Ring-SR
     * im Umbruch), gibt der IOProc reine Stille aus statt potentiell falsch
     * geratete Samples → kein Klicken/Knacken. RT-safe: nur ein acquire-load
     * + memset, kein malloc/lock. */
    if (atomic_load_explicit(&dev->sr_changing, memory_order_acquire)) {
        for (UInt32 b = 0; b < outOutputData->mNumberBuffers; b++) {
            memset(outOutputData->mBuffers[b].mData, 0,
                   outOutputData->mBuffers[b].mDataByteSize);
        }
        return noErr;
    }

    /* Tranche B: Pre-Roll Gate — gibt Stille bis Ring ≥ HWM (43ms @48kHz).
     * RT-safe: nur relaxed-atomic loads + ein release-store. Kein malloc, kein lock. */
    if (atomic_load_explicit(&dev->preroll_armed, memory_order_relaxed)) {
        uint32_t hwm    = atomic_load_explicit(&dev->preroll_target_frames, memory_order_relaxed);
        uint32_t widx_p = atomic_load_explicit(&ring->write_idx, memory_order_acquire);
        uint32_t frac_s = (uint32_t)(dev->src_frac_ridx * 2.0);
        uint32_t behind_p = widx_p - frac_s;
        if (behind_p / 2u < hwm) {
            /* Noch nicht genug gepuffert — Stille ausgeben, Position NICHT bewegen */
            for (UInt32 b = 0; b < outOutputData->mNumberBuffers; b++) {
                memset(outOutputData->mBuffers[b].mData, 0,
                       outOutputData->mBuffers[b].mDataByteSize);
            }
            return noErr;
        }
        /* HWM erreicht — Pre-Roll abschalten (einmalig, release) */
        atomic_store_explicit(&dev->preroll_armed, 0u, memory_order_release);
    }

    /* Volume + Mute aus Shared-Control lesen (atomic, low-cost) */
    uint32_t vol_q16 = atomic_load_explicit(&ring->volume_q16, memory_order_relaxed);
    uint32_t muted   = atomic_load_explicit(&ring->muted,      memory_order_relaxed);

    UInt32 nBufs = outOutputData->mNumberBuffers;
    if (nBufs == 0) return noErr;

    /* nFrames bestimmen — bei non-interleaved nehmen wir Buffer 0 als Referenz */
    UInt32 nFrames;
    if (nBufs >= 2) {
        /* MC-3: Non-interleaved Buffer koennen >1 Channel pro Buffer tragen —
         * mNumberChannels beruecksichtigen statt 1 Kanal anzunehmen. */
        UInt32 ch_per_buf = outOutputData->mBuffers[0].mNumberChannels;
        if (ch_per_buf == 0) ch_per_buf = 1;
        nFrames = outOutputData->mBuffers[0].mDataByteSize / (sizeof(float) * ch_per_buf);
    } else {
        UInt32 nCh = outOutputData->mBuffers[0].mNumberChannels;
        if (nCh == 0) return noErr;
        nFrames = outOutputData->mBuffers[0].mDataByteSize / sizeof(float) / nCh;
    }

    /* K7: BSS-Overflow-Guard — nFrames darf temp_buf[ARN_RING_CAPACITY] nie
     * ueberlaufen (max Index = (nFrames-1)*2+1 <= ARN_RING_CAPACITY-1).
     * CoreAudio liefert normalerweise <= 4096, aber ohne Clamp waere ein
     * nFrames > 8192 ein stiller BSS-Overflow. */
    if (nFrames > ARN_RING_CAPACITY / 2u) {
        nFrames = ARN_RING_CAPACITY / 2u;
    }
    uint32_t nSamplesStereo = nFrames * 2u;

    /* ── Fraktionaler Ring-Read mit linearer Interpolation (Phase 6 SRC) ──
     *
     * src_frac_ridx  = Frame-Index (nicht Sample-Index!)
     *   Frame i → L = ring->samples[i*2], R = ring->samples[i*2+1]
     * widx (write_idx) = Sample-Index → Vergleich via src_frac_ridx * 2.0
     *
     * Underrun-Strategie: Position NICHT zurücksetzen — nur Stille ausgeben
     * und beim nächsten IOProc-Call mehr Daten abwarten. Nur bei Ring-Overflow
     * (wir sind weiter als ARN_RING_CAPACITY hinter write_idx) wird
     * src_frac_ridx auf write_idx gesprungen (veraltete Daten überspringen). */
    uint32_t ratio_q20 = atomic_load_explicit(&dev->src_ratio_q20, memory_order_relaxed);
    double   ratio     = (double)ratio_q20 / (double)(1u << 20);

    uint32_t widx          = atomic_load_explicit(&ring->write_idx, memory_order_acquire);
    uint32_t frac_as_samp  = (uint32_t)(dev->src_frac_ridx * 2.0);
    uint32_t behind        = widx - frac_as_samp;   /* unsigned wrap = korrekt */

    /* Overflow-Guard: Ring wurde ueberschrieben → auf write_idx springen */
    if (behind > ARN_RING_CAPACITY) {
        dev->src_frac_ridx = (double)widx / 2.0;
        frac_as_samp       = widx;
        behind             = 0;
    }

    /* Benötigte Samples: floor(nFrames * ratio * 2).
     * Toleranz: 4 Samples (= 2 Stereo-Frames). Verhindert Boundary-Instabilität
     * wenn ratio genau an der Grenze liegt (z.B. 48000/44100 = 1.0884 →
     * needed = 1114, Ring liefert mal 1113 mal 1115 je nach Timing-Jitter).
     * Ohne Toleranz → alternierende Underruns → Stall-Detection feuert.
     * Die 4 fehlenden Samples werden mit Stille aufgefüllt — unhörbar. */
    uint32_t needed_samples = (uint32_t)(nFrames * ratio * 2.0);
    const uint32_t JITTER_TOLERANCE = 4u;  /* 2 Stereo-Frames Toleranz */

    int underrun = 0;
    if (behind + JITTER_TOLERANCE < needed_samples) {
        /* Underrun: Stille — Position NICHT veraendern, naechster Call holt auf */
        memset(dev->temp_buf, 0, nSamplesStereo * sizeof(float));
        underrun = 1;
        atomic_fetch_add_explicit(&dev->underruns, 1u, memory_order_relaxed);
    } else {
        for (uint32_t f = 0; f < nFrames; f++) {
            uint32_t idx0 = (uint32_t)dev->src_frac_ridx;
            float    frac = (float)(dev->src_frac_ridx - (double)idx0);
            float    inv  = 1.0f - frac;

            /* MC-2: Stale-Read-Guard — die JITTER_TOLERANCE erlaubt, dass die
             * letzten 1-2 Frames knapp HINTER write_idx interpolieren wuerden
             * (= alte Ring-Daten vom vorherigen Umlauf). Fuer diese Tail-Frames
             * Stille (0.0f) ausgeben statt stale Daten zu lesen. Die Position
             * wird normal weiterbewegt (Timing-Verhalten unveraendert).
             * Benoetigt: idx0 und idx0+1 vollstaendig geschrieben = 4 Samples. */
            uint32_t samples_ahead = widx - (idx0 * 2u);  /* unsigned wrap = korrekt */
            float l, r;
            if (samples_ahead < 4u) {
                l = 0.0f;
                r = 0.0f;
            } else {

            uint32_t si0 = ( idx0      * 2u    ) & ARN_RING_MASK;  /* L bei idx0   */
            uint32_t si1 = ( idx0      * 2u + 1) & ARN_RING_MASK;  /* R bei idx0   */
            uint32_t si2 = ((idx0 + 1u) * 2u    ) & ARN_RING_MASK; /* L bei idx0+1 */
            uint32_t si3 = ((idx0 + 1u) * 2u + 1) & ARN_RING_MASK; /* R bei idx0+1 */

            l = ring->samples[si0] * inv + ring->samples[si2] * frac;
            r = ring->samples[si1] * inv + ring->samples[si3] * frac;

            /* P15: Bei Downsampling (Ring-SR > Device-SR, ratio > 1.0) ein
             * symmetrischer 5-Tap-FIR (Hann-Fenster) zur Aliasing-Daempfung,
             * zentriert auf idx0. Ersetzt den frueheren 3-Tap-Box-Filter:
             * staerkere Daempfung der Spiegelfrequenzen bei minimal hoeherem
             * RT-Budget (5 statt 3 MACs pro Channel). Upsampling (ratio <= 1.0)
             * bleibt reine Linear-Interpolation — dort kein Aliasing-Problem.
             * Koeffizienten summen-normalisiert (Summe = 1.0): kein Pegelversatz.
             * MC-2: FIR liest bis idx0+2 → braucht 6 gueltige Samples, sonst
             * Fallback auf die Linear-Interpolation oben. */
            if (ratio > 1.005 && samples_ahead >= 6u) {  /* threshold > 1.0 mit kleinem Epsilon fuer FP-Rauschen */
                static const float kFir5[5] = {0.0625f, 0.25f, 0.375f, 0.25f, 0.0625f};
                /* Frame-Indizes idx0-2 .. idx0+2 → Ring-Sample-Indizes (Stereo). */
                uint32_t lL0 = ((idx0 - 2u) * 2u    ) & ARN_RING_MASK;
                uint32_t lL1 = ((idx0 - 1u) * 2u    ) & ARN_RING_MASK;
                uint32_t lL3 = ((idx0 + 1u) * 2u    ) & ARN_RING_MASK;
                uint32_t lL4 = ((idx0 + 2u) * 2u    ) & ARN_RING_MASK;
                uint32_t rR0 = ((idx0 - 2u) * 2u + 1) & ARN_RING_MASK;
                uint32_t rR1 = ((idx0 - 1u) * 2u + 1) & ARN_RING_MASK;
                uint32_t rR3 = ((idx0 + 1u) * 2u + 1) & ARN_RING_MASK;
                uint32_t rR4 = ((idx0 + 2u) * 2u + 1) & ARN_RING_MASK;
                l = kFir5[0] * ring->samples[lL0]
                  + kFir5[1] * ring->samples[lL1]
                  + kFir5[2] * ring->samples[si0]
                  + kFir5[3] * ring->samples[lL3]
                  + kFir5[4] * ring->samples[lL4];
                r = kFir5[0] * ring->samples[rR0]
                  + kFir5[1] * ring->samples[rR1]
                  + kFir5[2] * ring->samples[si1]
                  + kFir5[3] * ring->samples[rR3]
                  + kFir5[4] * ring->samples[rR4];
            }
            }  /* MC-2: Ende Stale-Read-Guard (else-Zweig) */

            dev->temp_buf[f * 2    ] = l;
            dev->temp_buf[f * 2 + 1] = r;

            dev->src_frac_ridx += ratio;

            /* P16: Fold src_frac_ridx um 2^31 nach jedem Advance — verhindert
             * float→uint32_t Cast-UB (Undefined Behavior) nach ~12h Dauerbetrieb.
             * 2^31 ist ein Vielfaches von ARN_RING_CAPACITY (2^13), daher vollstaendig transparent:
             *   • frac_as_samp = (uint32_t)(ridx*2): Fold aendert Wert um 2^32 ≡ 0 (mod 2^32)
             *     → behind = widx - frac_as_samp unveraendert
             *   • Ring-Index (idx0*2) & MASK: (2^31*2) mod (2*8192) = 2^32 mod 16384 = 0
             *     → physikalische Ringposition unveraendert
             *   • Interpolation frac = ridx - idx0: Integer-Fold, Fractional-Teil bleibt in [0,1) */
            if (dev->src_frac_ridx >= (double)(1u << 31)) {
                dev->src_frac_ridx -= (double)(1u << 31);
            }
        }
        /* local_ridx (Sample-Index) aus Frame-Index ableiten */
        atomic_store_explicit(&dev->local_ridx, (uint32_t)(dev->src_frac_ridx * 2.0), memory_order_release);
    }

    /* ── In Output-Buffer schreiben mit Channel-Mapping ── */
    uint32_t ch_off = dev->ch_offset;

    if (muted || vol_q16 == 0 || underrun) {
        /* Alle Output-Buffer auf 0 setzen (Stille) */
        for (UInt32 b = 0; b < nBufs; b++) {
            memset(outOutputData->mBuffers[b].mData, 0,
                   outOutputData->mBuffers[b].mDataByteSize);
        }
        return noErr;
    }

    float scale = (vol_q16 >= 65536u) ? 1.0f : (float)vol_q16 / 65536.0f;

    if (nBufs >= 2) {
        /* Non-interleaved: ein Buffer pro Channel.
         * Zuerst alle auf 0 setzen, dann L→buf[ch_off], R→buf[ch_off+1]. */
        for (UInt32 b = 0; b < nBufs; b++) {
            memset(outOutputData->mBuffers[b].mData, 0,
                   outOutputData->mBuffers[b].mDataByteSize);
        }
        if (ch_off + 1 < nBufs) {
            float *chL = (float *)outOutputData->mBuffers[ch_off    ].mData;
            float *chR = (float *)outOutputData->mBuffers[ch_off + 1].mData;
            for (UInt32 f = 0; f < nFrames; f++) {
                chL[f] = dev->temp_buf[f * 2 + 0] * scale;
                chR[f] = dev->temp_buf[f * 2 + 1] * scale;
            }
        }
    } else {
        /* Interleaved (1 Buffer, nCh Channels) */
        UInt32 nCh = outOutputData->mBuffers[0].mNumberChannels;
        float *out = (float *)outOutputData->mBuffers[0].mData;

        /* Zuerst alles stumm */
        memset(out, 0, outOutputData->mBuffers[0].mDataByteSize);

        if (ch_off + 1 < nCh) {
            for (UInt32 f = 0; f < nFrames; f++) {
                out[f * nCh + ch_off    ] = dev->temp_buf[f * 2 + 0] * scale;
                out[f * nCh + ch_off + 1] = dev->temp_buf[f * 2 + 1] * scale;
            }
        }
    }

    return noErr;
}

/* ── Globaler Read-Idx-Update ───────────────────────────────────────────── */

/*
 * Setzt ring->read_idx auf das MIN aller aktiven local_ridx-Werte.
 * Damit gibt der Producer Ringspeicher frei, wenn ALLE Consumer mindestens
 * so weit gelesen haben. Wird vom Volume-Thread aufgerufen (50ms-Takt).
 *
 * Hinweis: Wenn kein Output aktiv ist, setzen wir read_idx == write_idx
 * (Ring leeren), damit der Producer nicht im Ringbuffer-Voll-Zustand stehen
 * bleibt waehrend keine Konsumenten laufen.
 */
static void update_global_read_idx(void)
{
    ARNSharedRing *ring = atomic_load_explicit(&g_ring, memory_order_acquire);
    if (!ring) return;

    pthread_mutex_lock(&g_outputs_lock);

    /* Tombstoning: kein g_n_outputs==0-Spezialfall mehr noetig — die Schleife
     * unten liefert have_active=false wenn kein aktiver Output existiert
     * (Tombstones werden via active-Check uebersprungen) und setzt dann
     * read_idx == write_idx (Ring leeren). */

    /* Finde Minimum aller local_ridx (mit unsigned Distanz zum write_idx) */
    uint32_t w   = atomic_load_explicit(&ring->write_idx, memory_order_acquire);
    uint32_t max_dist = 0;
    uint32_t min_ridx = w;
    bool     have_active = false;
    for (int i = 0; i < g_n_outputs; i++) {
        if (!g_outputs[i].active) continue;
        /* K2: Gestallte Outputs aus dem Aggregat ausschließen — ein eingefrorener
         * local_ridx darf nicht den globalen read_idx einfrieren und damit alle
         * anderen Outputs in den Underrun treiben. */
        if (atomic_load_explicit(&g_outputs[i].stalled, memory_order_acquire)) continue;
        uint32_t ridx_i = atomic_load_explicit(&g_outputs[i].local_ridx, memory_order_acquire);
        uint32_t dist = w - ridx_i;
        if (!have_active || dist > max_dist) {
            max_dist = dist;
            min_ridx = ridx_i;
            have_active = true;
        }
    }

    if (have_active) {
        atomic_store_explicit(&ring->read_idx, min_ridx, memory_order_release);
    } else {
        atomic_store_explicit(&ring->read_idx, w, memory_order_release);
    }

    pthread_mutex_unlock(&g_outputs_lock);
}

/* ── Output-Management (Add/Remove) ─────────────────────────────────────── */

/*
 * Findet Slot-Index in g_outputs fuer (uid, ch_offset), oder -1 wenn nicht da.
 * MUSS unter g_outputs_lock aufgerufen werden.
 */
static int find_output_slot_locked(const char *uid, uint32_t ch_offset)
{
    for (int i = 0; i < g_n_outputs; i++) {
        if (g_outputs[i].active &&
            strcmp(g_outputs[i].uid, uid) == 0 &&
            g_outputs[i].ch_offset == ch_offset) {
            return i;
        }
    }
    return -1;
}

/*
 * Tombstoning-Helper. Alle MUESSEN unter g_outputs_lock aufgerufen werden.
 */

/* Zaehlt aktive Outputs neu (max. 8 Iterationen — billig und robust gegen
 * vergessene +/-1-Buchhaltung). */
static int recount_active_locked(void)
{
    int n = 0;
    for (int i = 0; i < g_n_outputs; i++) {
        if (g_outputs[i].active) n++;
    }
    return n;
}

/* Findet den ersten FREIEN Slot (Tombstone oder nie benutzt):
 * active==false && uid[0]=='\0'. Rueckgabe: Index oder -1 wenn voll.
 * In-flight output_add-Slots (uid gesetzt, active noch false) und Slots,
 * deren IOProc gerade gestoppt wird (Remove Phase 2, uid noch gesetzt),
 * gelten NICHT als frei. */
static int find_free_slot_locked(void)
{
    for (int i = 0; i < MAX_OUTPUTS; i++) {
        if (!g_outputs[i].active && g_outputs[i].uid[0] == '\0') {
            return i;
        }
    }
    return -1;
}

/* true wenn KEIN Slot belegt ist (weder aktiv noch in-flight) —
 * Tombstones zaehlen nicht als belegt. Ersetzt das alte (g_n_outputs == 0). */
static bool no_occupied_slots_locked(void)
{
    for (int i = 0; i < g_n_outputs; i++) {
        if (g_outputs[i].uid[0] != '\0') return false;
    }
    return true;
}

/*
 * output_add — Fügt Output-Device hinzu ohne langfristige Lock-Hold.
 *
 * H1: Drei-Phasen-Ansatz:
 *   Phase 1 (Lock): Duplikat/Kapazitäts-Check, start_widx lesen.
 *   Phase 2 (kein Lock): SR-Set + USB-Settle-Wartezeit auf Stack-Kopie.
 *   Phase 3 (Lock): Slot committen, DANN AudioDeviceCreateIOProcID/Start
 *                   mit stabiler g_outputs[]-Adresse als clientData.
 *
 * Caller darf g_outputs_lock NICHT halten.
 * Rückgabe: 0=OK, -1=Fehler.
 */
static int output_add(const char *uid, uint32_t ch_offset)
{
    /* ── Phase 1: Prepare unter Lock (schnell) ── */
    pthread_mutex_lock(&g_outputs_lock);
    if (find_output_slot_locked(uid, ch_offset) >= 0) {
        pthread_mutex_unlock(&g_outputs_lock);
        return 0;  /* idempotent */
    }
    /* Tombstoning: Kapazitaet = "gibt es einen freien Slot?" — nicht mehr
     * g_n_outputs (High-Water-Mark, schrumpft nie). */
    if (find_free_slot_locked() < 0) {
        fprintf(stderr, "Helper: MAX_OUTPUTS (%d) erreicht, kann '%s' nicht hinzufuegen\n",
                MAX_OUTPUTS, uid);
        pthread_mutex_unlock(&g_outputs_lock);
        return -1;
    }
    ARNSharedRing *ring_snap = atomic_load_explicit(&g_ring, memory_order_acquire);
    uint32_t start_widx = ring_snap
        ? atomic_load_explicit(&ring_snap->write_idx, memory_order_acquire) : 0u;
    /* P5: Ist das der erste Output? (unter Lock gelesen) — entscheidet, ob der
     * Ring im Auto-Modus die native SR dieses Devices uebernimmt.
     * Tombstoning: "erster Output" = kein belegter Slot (Tombstones zaehlen nicht). */
    bool is_first_output = no_occupied_slots_locked();
    pthread_mutex_unlock(&g_outputs_lock);

    /* ── Phase 2: Schwere Arbeit auf Stack-Kopie, KEIN Lock ── */
    AudioDeviceID dev_id = find_device_by_uid(uid);
    if (dev_id == kAudioDeviceUnknown) {
        fprintf(stderr, "Helper: Device '%s' nicht gefunden\n", uid);
        return -1;
    }

    /* M6-Validierung (vollstaendig) */
    UInt32 max_ch = device_output_channels(dev_id);
    if (max_ch < 2u || ch_offset + 2u > max_ch || (ch_offset & 1u) != 0u) {
        fprintf(stderr, "Helper: ch_offset %u ungueltig fuer '%s' (%u Channels)\n",
                ch_offset, uid, max_ch);
        return -1;
    }

    /* Stack-Kopie fuer SR-Set + SRC-Init */
    DeviceOutput tmp;
    memset(&tmp, 0, sizeof(tmp));
    tmp.dev_id    = dev_id;
    tmp.ch_offset = ch_offset;
    strncpy(tmp.uid, uid, sizeof(tmp.uid) - 1);
    char *nm = device_get_name(dev_id);
    if (nm) { strncpy(tmp.name, nm, sizeof(tmp.name) - 1); free(nm); }
    atomic_store_explicit(&tmp.local_ridx, start_widx, memory_order_relaxed);
    atomic_store_explicit(&tmp.underruns,  0u,          memory_order_relaxed);
    atomic_store_explicit(&tmp.frac_ridx_reset_gen,  0u, memory_order_relaxed);
    atomic_store_explicit(&tmp.frac_ridx_reset_widx, 0u, memory_order_relaxed);
    tmp.frac_ridx_applied_gen = 0u;
    tmp.last_ridx_sample = start_widx;
    tmp.last_progress_ns = get_time_ns();
    atomic_store_explicit(&tmp.stalled, 0u, memory_order_relaxed);
    atomic_store_explicit(&tmp.recovery_count, 0u, memory_order_relaxed);
    /* Tranche B/ARC-4: Pre-Roll — Consumer wartet auf ARN_PREROLL_FRAMES (2048 Frames ≈ 43ms @48kHz) */
    atomic_store_explicit(&tmp.preroll_target_frames, ARN_PREROLL_FRAMES, memory_order_relaxed);
    atomic_store_explicit(&tmp.preroll_armed, 1u, memory_order_relaxed);

    /* Sample-Rate-Abgleich und SRC-Initialisierung (wie in output_add_locked) */
    ARNSharedRing *ring_now = atomic_load_explicit(&g_ring, memory_order_acquire);
    Float64 ring_sr   = (Float64)(ring_now ? atomic_load_explicit(&ring_now->sample_rate, memory_order_acquire) : 48000u);
    Float64 device_sr = ring_sr;
    AudioObjectPropertyAddress sr_prop = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 sr_size = sizeof(Float64);
    AudioObjectGetPropertyData(dev_id, &sr_prop, 0, NULL, &sr_size, &device_sr);

    bool sr_was_changed = false;
    /* P5: Auto-Modus + erster Output → Ring folgt der nativen Device-SR,
     * statt das Device auf eine (evtl. 48kHz-) Ring-SR zu zwingen. Damit laeuft
     * z.B. ein 44.1kHz-Interface ohne Resampling, base_ratio = 1.0. */
    if (atomic_load_explicit(&g_auto_sample_rate, memory_order_acquire) &&
        is_first_output && ring_now &&
        (uint32_t)device_sr != (uint32_t)ring_sr &&
        (uint32_t)device_sr != 0u) {
        arn_ring_set_sample_rate(ring_now, (uint32_t)device_sr);
        fprintf(stdout, "Helper: Auto-SR — Ring folgt nativer Rate von '%s': %.0f Hz\n",
                uid, device_sr);
        ring_sr = device_sr;  /* base_ratio wird damit 1.0 */
    } else if ((uint32_t)device_sr != (uint32_t)ring_sr) {
        /* Manueller Modus oder weiterer Output: Device auf Ring-SR ziehen. */
        if (AudioObjectSetPropertyData(dev_id, &sr_prop, 0, NULL, sizeof(Float64), &ring_sr) == noErr) {
            fprintf(stdout, "Helper: '%s' Sample-Rate auf %.0f Hz gesetzt\n", uid, ring_sr);
            device_sr      = ring_sr;
            sr_was_changed = true;
        } else {
            fprintf(stderr, "Helper: Warnung — '%s' laeuft auf %.0f Hz (Ring: %.0f Hz)\n",
                    uid, device_sr, ring_sr);
        }
    }
    tmp.base_ratio = ring_sr / device_sr;
    if (tmp.base_ratio <= 0.0 || tmp.base_ratio > 10.0) {
        fprintf(stderr, "Helper: Warnung — unplausibler base_ratio %.6f fuer '%s' — setze 1.0\n",
                tmp.base_ratio, uid);
        tmp.base_ratio = 1.0;
    }
    tmp.src_frac_ridx   = (double)start_widx / 2.0;
    tmp.src_ring_target = ARN_RING_CAPACITY / 2;
    uint32_t init_ratio_q20 = (uint32_t)(tmp.base_ratio * (double)(1u << 20));
    atomic_store_explicit(&tmp.src_ratio_q20, init_ratio_q20, memory_order_relaxed);
    /* Tranche C: PI-Regler State initialisieren */
    tmp.fill_ewma   = (double)ARN_RING_CAPACITY / 4.0;   /* = src_ring_target / 2 = target_frames */
    tmp.integ_error = 0.0;

    /* H1: USB-Settle-Wartezeit OHNE Lock — der teure Teil */
    if (sr_was_changed) {
        fprintf(stdout, "Helper: Warte auf USB-Settle nach SR-Wechsel fuer '%s'...\n", uid);
        usleep(400000);  /* 400ms — USB-Devices benoetigen Zeit zum Rekonfigurieren */
    }

    /* ── Phase 3a: Commit unter Lock (schnell) ── */
    pthread_mutex_lock(&g_outputs_lock);

    /* Race-Re-Check: kam in Phase 2 ein Duplikat rein oder ist Kapazitaet voll? */
    if (find_output_slot_locked(uid, ch_offset) >= 0) {
        pthread_mutex_unlock(&g_outputs_lock);
        fprintf(stdout, "Helper: '%s' wurde in Phase 2 bereits hinzugefuegt\n", uid);
        return 0;
    }
    /* Tombstoning: freien Slot suchen (Race-Re-Check nach Phase 2). */
    int slot_idx = find_free_slot_locked();
    if (slot_idx < 0) {
        pthread_mutex_unlock(&g_outputs_lock);
        fprintf(stderr, "Helper: MAX_OUTPUTS voll nach Race in Phase 2\n");
        return -1;
    }

    /* Slot committen — active=false damit Volume-Thread ihn ueberspringt.
     * proc_id wird in Phase 3b (lockfrei) gesetzt. */
    DeviceOutput *slot = &g_outputs[slot_idx];
    *slot = tmp;
    slot->active  = false;
    slot->proc_id = NULL;
    /* High-Water-Mark anheben falls noetig (schrumpft nie). */
    if (slot_idx + 1 > g_n_outputs) g_n_outputs = slot_idx + 1;
    /* MC-6: Generation vor dem lockfreien CoreAudio-Block merken. */
    uint32_t gen_at_commit = atomic_load_explicit(&g_outputs_generation,
                                                  memory_order_acquire);
    pthread_mutex_unlock(&g_outputs_lock);

    /* ── Phase 3b: CoreAudio-Calls OHNE Lock ──
     * AudioDeviceCreateIOProcID und AudioDeviceStart sind Mach-IPC zu coreaudiod.
     * Unter Lock ausgefuehrt koennen sie ewig blockieren wenn coreaudiod spinnt.
     * Die Slot-Adresse ist stabil: g_outputs ist ein statisches Array, active=false
     * verhindert dass der Volume-Thread den Slot beruehrt. */
    AudioDeviceIOProcID new_proc_id = NULL;  /* H1: lokal — erst in Phase 3c unter Lock committen */
    OSStatus err = kAudioHardwareNotRunningError;
    for (int attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) usleep(100000);  /* 100ms Retry-Pause, lockfrei */
        err = AudioDeviceCreateIOProcID(dev_id, device_ioproc, slot, &new_proc_id);
        if (err == noErr) break;
        fprintf(stderr, "Helper: AudioDeviceCreateIOProcID Versuch %d/3 (OSStatus %d) fuer '%s'\n",
                attempt + 1, (int)err, uid);
        new_proc_id = NULL;
    }

    if (err != noErr) {
        fprintf(stderr, "Helper: AudioDeviceCreateIOProcID endgueltig fehlgeschlagen fuer '%s'\n", uid);
        /* Phase 3c (Fehler): Slot als Tombstone freigeben (kein Verschieben). */
        pthread_mutex_lock(&g_outputs_lock);
        /* Re-Validierung: Slot muss noch der sein den wir committet haben. */
        if (slot_idx < g_n_outputs && !g_outputs[slot_idx].active &&
            strcmp(g_outputs[slot_idx].uid, uid) == 0) {
            memset(&g_outputs[slot_idx], 0, sizeof(DeviceOutput));
        }
        pthread_mutex_unlock(&g_outputs_lock);
        return -1;
    }

    err = AudioDeviceStart(dev_id, new_proc_id);
    if (err != noErr) {
        fprintf(stderr, "Helper: AudioDeviceStart fehlgeschlagen (OSStatus %d) fuer '%s'\n",
                (int)err, uid);
        AudioDeviceDestroyIOProcID(dev_id, new_proc_id);
        new_proc_id = NULL;
        /* Phase 3c (Fehler): Slot als Tombstone freigeben (kein Verschieben). */
        pthread_mutex_lock(&g_outputs_lock);
        if (slot_idx < g_n_outputs && !g_outputs[slot_idx].active &&
            strcmp(g_outputs[slot_idx].uid, uid) == 0) {
            memset(&g_outputs[slot_idx], 0, sizeof(DeviceOutput));
        }
        pthread_mutex_unlock(&g_outputs_lock);
        return -1;
    }

    /* ── Phase 3c: active=true unter Lock (kurz) ── */
    pthread_mutex_lock(&g_outputs_lock);
    /* MC-6: Generation vergleichen — hat outputs_stop_all() (Watchdog/Shutdown)
     * waehrend des lockfreien CoreAudio-Blocks alle Outputs weggeraeumt, ist
     * unser committeter Slot ungueltig: IOProc aufraeumen und abbrechen. */
    bool gen_changed = (atomic_load_explicit(&g_outputs_generation,
                                             memory_order_acquire) != gen_at_commit);
    /* Re-Validierung: Slot-Indizes sind durch Tombstoning stabil, aber der Slot
     * koennte zwischenzeitlich per Hot-Unplug getombstoned worden sein. */
    if (!gen_changed && slot_idx < g_n_outputs && !g_outputs[slot_idx].active &&
        strcmp(g_outputs[slot_idx].uid, uid) == 0) {
        g_outputs[slot_idx].proc_id = new_proc_id;  /* H1: erst jetzt, unter Lock, committen */
        g_outputs[slot_idx].active  = true;
        g_n_active_outputs = recount_active_locked();
    } else {
        /* Slot ist nicht mehr vorhanden (getombstoned) oder per Watchdog gestoppt
         * — IOProc sauber stoppen. */
        pthread_mutex_unlock(&g_outputs_lock);
        AudioDeviceStop(dev_id, new_proc_id);
        AudioDeviceDestroyIOProcID(dev_id, new_proc_id);
        fprintf(stderr, "Helper: output_add '%s' — Slot nach CoreAudio-Start nicht mehr gueltig%s\n",
                uid, gen_changed ? " (outputs_stop_all waehrenddessen)" : "");
        return -1;
    }
    pthread_mutex_unlock(&g_outputs_lock);

    /* K1: read_idx sofort aktualisieren — neuer Consumer wird nicht erst nach
     * bis zu 50ms vom naechsten Volume-Poll-Takt beruecksichtigt. */
    update_global_read_idx();

    fprintf(stdout, "Helper: Output hinzugefuegt: %s [Ch %u-%u] (UID: %s)\n",
            slot->name, ch_offset + 1, ch_offset + 2, uid);
    return 0;
}

/*
 * Entfernt Output-Device (uid + ch_offset).
 *
 * Tombstoning (Batch 9): Der Slot wird NICHT mehr kompaktiert (kein Swap-Remove
 * des letzten Slots an die freie Position). Stattdessen wird nur das Ziel-Device
 * gestoppt und der Slot als Tombstone (active=false, uid leer) markiert.
 * Effekt: Alle anderen Outputs behalten ihre Slot-Adresse (inClientData der
 * IOProcs) und laufen UNUNTERBROCHEN weiter — kein IOProc-Neustart, kein
 * Pre-Roll-Re-Arm, keine 85ms+ Stille fuer uninvolvierte Devices mehr.
 *
 * P7 bleibt erhalten: Die schweren CoreAudio-Calls (AudioDeviceStop/Destroy)
 * laufen OHNE g_outputs_lock.
 *
 *   Phase 1 (Lock gehalten): Slot finden, active=false + proc_id=NULL setzen,
 *            Device-Infos in Stack-Kopien sichern. uid bleibt vorerst GESETZT —
 *            der Slot gilt damit noch nicht als frei und kann waehrend des
 *            lockfreien Stop-Fensters nicht von output_add() reklamiert werden.
 *   Phase 2 (KEIN Lock): AudioDeviceStop/DestroyIOProcID fuer das Ziel.
 *   Phase 3 (Lock wieder gehalten): Slot per memset als freien Tombstone
 *            markieren (uid[0]='\0').
 *
 * KONTRAKT: MUSS mit gehaltenem g_outputs_lock aufgerufen werden und gibt mit
 * gehaltenem Lock zurueck (der Lock wird intern nur temporaer freigegeben).
 */
static void output_remove_locked(const char *uid, uint32_t ch_offset)
{
    int slot = find_output_slot_locked(uid, ch_offset);
    if (slot < 0) return;

    /* ── Phase 1 (Lock): deaktivieren + Stack-Kopien ──
     * Hinweis: uid kann auf g_outputs[slot].uid selbst zeigen (Caller-Loops) —
     * daher alle benoetigten Infos VOR dem Tombstonen kopieren. */
    AudioDeviceID       tgt_dev  = g_outputs[slot].dev_id;
    AudioDeviceIOProcID tgt_proc = g_outputs[slot].proc_id;
    char                tgt_name[256];
    snprintf(tgt_name, sizeof(tgt_name), "%s", g_outputs[slot].name);
    g_outputs[slot].active  = false;   /* volume_poll_thread ueberspringt jetzt */
    g_outputs[slot].proc_id = NULL;
    g_n_active_outputs = recount_active_locked();

    pthread_mutex_unlock(&g_outputs_lock);

    /* ── Phase 2 (KEIN Lock): CoreAudio nur fuer das Ziel-Device ── */
    if (tgt_proc) {
        AudioDeviceStop(tgt_dev, tgt_proc);
        AudioDeviceDestroyIOProcID(tgt_dev, tgt_proc);
    }
    fprintf(stdout, "Helper: Output entfernt: %s [Ch %u-%u]\n",
            tgt_name, ch_offset + 1, ch_offset + 2);

    /* ── Phase 3 (Lock wieder): Slot als freien Tombstone markieren ── */
    pthread_mutex_lock(&g_outputs_lock);
    /* Re-Validierung: waehrend des lockfreien Fensters koennte z.B.
     * process_hotplug_removals den Slot bereits getombstoned haben
     * (dev_id waere dann 0) oder outputs_stop_all alles geleert haben. */
    if (slot < g_n_outputs && !g_outputs[slot].active &&
        g_outputs[slot].dev_id == tgt_dev &&
        g_outputs[slot].ch_offset == ch_offset) {
        memset(&g_outputs[slot], 0, sizeof(DeviceOutput));
    }
}

/*
 * sr_reinit_all_outputs — Reagiert auf Sample-Rate-Wechsel (sr_change_gen).
 *
 * P0-A FIX: Nicht mehr vom Caller unter g_outputs_lock aufgerufen.
 * Die Funktion verwaltet den Lock selbst, um CoreAudio-Calls (Mach-IPC)
 * ausserhalb des Locks ausfuehren zu koennen:
 *
 *   Snapshot-Phase (unter Lock): n_outputs + Device-Infos lesen.
 *   CoreAudio-Phase (OHNE Lock): Stop/Create/Start pro Output.
 *   Commit-Phase   (kurzer Lock): State-Updates schreiben.
 */
static void sr_reinit_all_outputs(void) {
    ARNSharedRing *ring = atomic_load_explicit(&g_ring, memory_order_acquire);
    if (!ring) return;
    uint32_t new_sr = atomic_load_explicit(&ring->sample_rate, memory_order_acquire);
    fprintf(stdout, "Helper: Sample-Rate geaendert auf %u Hz — pruefe Outputs\n", new_sr);
    uint32_t w = atomic_load_explicit(&ring->write_idx, memory_order_acquire);

    AudioObjectPropertyAddress sr_prop = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    /* ── Snapshot-Phase: unter Lock Ausgabe-Kopien erstellen ── */
    pthread_mutex_lock(&g_outputs_lock);
    int n = g_n_outputs;
    pthread_mutex_unlock(&g_outputs_lock);

    for (int i = 0; i < n; i++) {

        /* Zustand unter Lock lesen */
        pthread_mutex_lock(&g_outputs_lock);
        if (i >= g_n_outputs || !g_outputs[i].uid[0]) {
            pthread_mutex_unlock(&g_outputs_lock);
            continue;
        }
        if (!g_outputs[i].active) { pthread_mutex_unlock(&g_outputs_lock); continue; } /* H1: in-flight Slot */
        AudioDeviceID   dev_id   = g_outputs[i].dev_id;
        AudioDeviceIOProcID old_proc = g_outputs[i].proc_id;
        bool            was_active  = g_outputs[i].active;
        char            dev_name[256];
        strncpy(dev_name, g_outputs[i].name, sizeof(dev_name) - 1);
        dev_name[sizeof(dev_name)-1] = '\0';

        /* Aktuelle Device-SR lesen (ohne Lock, aber unter diesem Lock-Hold ist ok) */
        Float64 device_sr = (Float64)new_sr;
        UInt32  sz = sizeof(Float64);
        AudioObjectGetPropertyData(dev_id, &sr_prop, 0, NULL, &sz, &device_sr);

        /* Fix 3b: SR stimmt bereits ueberein — kein disruptiver Stop/Start. */
        if ((uint32_t)device_sr == new_sr) {
            g_outputs[i].base_ratio = 1.0;
            uint32_t q20 = (uint32_t)(1.0 * (double)(1u << 20));
            atomic_store_explicit(&g_outputs[i].src_ratio_q20, q20, memory_order_relaxed);
            atomic_store_explicit(&g_outputs[i].local_ridx, w, memory_order_release);
            atomic_store_explicit(&g_outputs[i].frac_ridx_reset_widx, w, memory_order_release);
            atomic_fetch_add_explicit(&g_outputs[i].frac_ridx_reset_gen, 1u, memory_order_acq_rel);
            g_outputs[i].fill_ewma   = (double)g_outputs[i].src_ring_target / 2.0;
            g_outputs[i].integ_error = 0.0;
            pthread_mutex_unlock(&g_outputs_lock);
            continue;
        }

        /* P9: Stille-Gate aktivieren BEVOR IOProc gestoppt wird. */
        atomic_store_explicit(&g_outputs[i].sr_changing, 1u, memory_order_release);
        /* IOProc-Infos fuer Stop/Destroy merken, dann deaktivieren. */
        g_outputs[i].active  = false;
        g_outputs[i].proc_id = NULL;
        g_n_active_outputs = recount_active_locked();
        /* Leseposition zuruecksetzen (IOProc gestoppt gleich). */
        atomic_store_explicit(&g_outputs[i].local_ridx, w, memory_order_release);
        /* HC-4: KEIN Direktschreiben in src_frac_ridx — der IOProc koennte
         * hier noch laufen (Stop erfolgt erst nach Lock-Release). Stattdessen
         * Pending-Mechanismus: der alte ODER der neu erzeugte IOProc wendet
         * den Reset RT-safe an (frac_ridx_applied_gen ueberlebt im Slot). */
        atomic_store_explicit(&g_outputs[i].frac_ridx_reset_widx, w, memory_order_release);
        atomic_fetch_add_explicit(&g_outputs[i].frac_ridx_reset_gen, 1u, memory_order_acq_rel);
        pthread_mutex_unlock(&g_outputs_lock);

        /* ── CoreAudio-Phase: OHNE Lock ── */

        /* Schritt 1: alten IOProc stoppen (lockfrei) */
        if (was_active && old_proc) {
            AudioDeviceStop(dev_id, old_proc);
            AudioDeviceDestroyIOProcID(dev_id, old_proc);
        }

        /* Schritt 2: Device auf neue Ring-SR setzen (lockfrei) */
        Float64 ring_sr_f = (Float64)new_sr;
        if (AudioObjectSetPropertyData(dev_id, &sr_prop, 0, NULL,
                                       sizeof(Float64), &ring_sr_f) != noErr) {
            /* Nicht-fatal: aktuelle Device-SR fuer base_ratio neu lesen */
            sz = sizeof(Float64);
            AudioObjectGetPropertyData(dev_id, &sr_prop, 0, NULL, &sz, &device_sr);
        } else {
            device_sr = ring_sr_f;
        }

        double base_ratio = (double)new_sr / (double)device_sr;
        if (base_ratio <= 0.0 || base_ratio > 10.0) {
            fprintf(stderr, "Helper: Warnung — unplausibler base_ratio %.6f nach SR-Reinit "
                    "fuer '%s' — setze 1.0\n", base_ratio, dev_name);
            base_ratio = 1.0;
        }
        uint32_t init_q20 = (uint32_t)(base_ratio * (double)(1u << 20));

        /* Schritt 3: IOProc neu erzeugen — mit Retry nach SR-Wechsel (lockfrei). */
        AudioDeviceIOProcID new_proc = NULL;
        OSStatus err = kAudioHardwareNotRunningError;

        /* Re-Validierung: Slot noch vorhanden? */
        pthread_mutex_lock(&g_outputs_lock);
        bool slot_valid = (i < g_n_outputs && g_outputs[i].dev_id == dev_id);
        DeviceOutput *slot_ptr = slot_valid ? &g_outputs[i] : NULL;
        pthread_mutex_unlock(&g_outputs_lock);

        if (!slot_valid) {
            fprintf(stderr, "Helper: SR-Reinit: Slot %d nicht mehr gueltig fuer '%s'\n",
                    i, dev_name);
            continue;
        }

        for (int attempt = 0; attempt < 5; attempt++) {
            if (attempt > 0) usleep(200000); /* 200ms, lockfrei */
            err = AudioDeviceCreateIOProcID(dev_id, device_ioproc, slot_ptr, &new_proc);
            if (err == noErr) break;
            fprintf(stderr, "Helper: AudioDeviceCreateIOProcID Versuch %d/5 fehlgeschlagen "
                    "(OSStatus %d) fuer %s\n", attempt + 1, (int)err, dev_name);
            new_proc = NULL;
        }

        if (err != noErr) {
            fprintf(stderr, "Helper: AudioDeviceCreateIOProcID endgueltig fehlgeschlagen "
                    "fuer %s — Output bleibt inaktiv\n", dev_name);
            /* Commit-Phase: sr_changing-Gate freigeben, active bleibt false */
            pthread_mutex_lock(&g_outputs_lock);
            if (i < g_n_outputs && g_outputs[i].dev_id == dev_id) {
                atomic_store_explicit(&g_outputs[i].sr_changing, 0u, memory_order_release);
            }
            pthread_mutex_unlock(&g_outputs_lock);
            continue;
        }

        /* Schritt 4: Start mit Retry (lockfrei) */
        for (int retry = 0; retry < 3; retry++) {
            err = AudioDeviceStart(dev_id, new_proc);
            if (err == noErr) break;
            if (retry < 2) usleep(100000);
        }

        /* ── Commit-Phase: State-Updates unter kurzem Lock ── */
        pthread_mutex_lock(&g_outputs_lock);
        if (i < g_n_outputs && g_outputs[i].dev_id == dev_id) {
            if (err != noErr) {
                fprintf(stderr, "Helper: AudioDeviceStart fehlgeschlagen nach 3 Versuchen "
                        "(OSStatus %d) fuer %s — Output bleibt inaktiv\n",
                        (int)err, dev_name);
                AudioDeviceDestroyIOProcID(dev_id, new_proc);
                g_outputs[i].proc_id = NULL;
                g_outputs[i].active  = false;
                atomic_store_explicit(&g_outputs[i].sr_changing, 0u, memory_order_release);
            } else {
                g_outputs[i].proc_id     = new_proc;
                g_outputs[i].base_ratio  = base_ratio;
                atomic_store_explicit(&g_outputs[i].src_ratio_q20, init_q20, memory_order_relaxed);
                atomic_store_explicit(&g_outputs[i].underruns, 0u, memory_order_relaxed);
                g_outputs[i].fill_ewma   = (double)g_outputs[i].src_ring_target / 2.0;
                g_outputs[i].integ_error = 0.0;
                /* Pre-Roll neu scharf schalten, DANN Gate freigeben. */
                atomic_store_explicit(&g_outputs[i].preroll_target_frames, ARN_PREROLL_FRAMES,
                                      memory_order_relaxed);
                atomic_store_explicit(&g_outputs[i].preroll_armed, 1u, memory_order_release);
                atomic_store_explicit(&g_outputs[i].sr_changing, 0u, memory_order_release);
                g_outputs[i].active      = true;
                g_n_active_outputs = recount_active_locked();
                fprintf(stdout, "Helper: Output neu gestartet nach SR-Wechsel: %s [Ch %u-%u]\n",
                        g_outputs[i].name, g_outputs[i].ch_offset + 1,
                        g_outputs[i].ch_offset + 2);
            }
        } else {
            /* Slot verschwunden (Hot-Unplug waehrend Reinit) — IOProc sauber stoppen */
            pthread_mutex_unlock(&g_outputs_lock);
            if (err == noErr) {
                AudioDeviceStop(dev_id, new_proc);
                AudioDeviceDestroyIOProcID(dev_id, new_proc);
            }
            fprintf(stderr, "Helper: SR-Reinit: Slot nach Start nicht mehr vorhanden fuer '%s'\n",
                    dev_name);
            continue;
        }
        pthread_mutex_unlock(&g_outputs_lock);
    }
}

/*
 * Stoppt alle Outputs (z.B. beim Shutdown).
 */
static void outputs_stop_all(void)
{
    /* P1 FIX: 2-Phasen-Design analog process_hotplug_removals.
     * Phase A (unter Lock): Snapshot {dev_id, proc_id}, proc_id=NULL setzen, g_n_outputs=0.
     * Phase B (OHNE Lock): AudioDeviceStop/DestroyIOProcID lockfrei.
     * Verhindert Blockade im Watchdog-Pfad wenn coreaudiod spinnt oder haengt. */
    typedef struct { AudioDeviceID dev_id; AudioDeviceIOProcID proc_id; } StopEntry;
    StopEntry to_stop[MAX_OUTPUTS];
    int n_stop = 0;

    pthread_mutex_lock(&g_outputs_lock);
    for (int i = 0; i < g_n_outputs; i++) {
        /* Tombstones haben proc_id == NULL und sind bereits genullt — der
         * Check unten ueberspringt sie automatisch. */
        if (g_outputs[i].proc_id) {
            to_stop[n_stop].dev_id  = g_outputs[i].dev_id;
            to_stop[n_stop].proc_id = g_outputs[i].proc_id;
            n_stop++;
        }
        memset(&g_outputs[i], 0, sizeof(DeviceOutput));
    }
    /* Einziger Ort an dem die High-Water-Mark zurueckgesetzt wird. */
    g_n_outputs = 0;
    g_n_active_outputs = 0;
    /* MC-6: Generation inkrementieren — laufende output_add()-Aufrufe erkennen
     * in Phase 3, dass ihr committeter Slot soeben weggeraeumt wurde. */
    atomic_fetch_add_explicit(&g_outputs_generation, 1u, memory_order_release);
    pthread_mutex_unlock(&g_outputs_lock);

    /* Phase B: Mach-IPC OHNE Lock — haengt coreaudiod, blockiert nur diesen Thread. */
    for (int i = 0; i < n_stop; i++) {
        AudioDeviceStop(to_stop[i].dev_id, to_stop[i].proc_id);
        AudioDeviceDestroyIOProcID(to_stop[i].dev_id, to_stop[i].proc_id);
    }
}

/* ── Hot-Plug Listener ──────────────────────────────────────────────────── */

/*
 * Wird aufgerufen wenn sich kAudioHardwarePropertyDevices aendert
 * (Device hinzugefuegt oder entfernt). Prueft ob ein aktuell aktives
 * Output-Device verschwunden ist und stoppt dann den zugehoerigen IOProc.
 */
static OSStatus devices_changed_listener(AudioObjectID inObjectID,
                                         UInt32 inNumberAddresses,
                                         const AudioObjectPropertyAddress *inAddresses,
                                         void *inClientData)
{
    (void)inObjectID; (void)inNumberAddresses; (void)inAddresses; (void)inClientData;
    /* H3: Kein Lock, kein CoreAudio-Call im Property-Callback — nur Flag setzen.
     * Der Volume-Thread fuehrt die eigentliche Reaktion ausserhalb des
     * CoreAudio-Property-Callback-Kontexts aus (kein Re-Entry-Deadlock). */
    atomic_store_explicit(&g_hotplug_pending, 1, memory_order_release);
    return noErr;
}

/* H3: Eigentliche Hot-Plug-Reaktion — laeuft im Volume-Thread (nicht im Callback).
 *
 * P2-A FIX: AudioDeviceStop/DestroyIOProcID sind Mach-IPC zu coreaudiod.
 * Unter g_outputs_lock aufgerufen koennen sie bei coreaudiod-Spin blockieren.
 * Jetzt 2-Phasen-Design:
 *   Phase A (unter Lock): Snapshot der zu entfernenden Slots, Slot als
 *                         Tombstone freigeben (Batch 9: kein Kompaktieren).
 *   Phase B (OHNE Lock):  AudioDeviceStop/DestroyIOProcID.
 */
static void process_hotplug_removals(void)
{
    /* Phase A: Snapshot unter Lock — find_device_by_uid + deaktivieren */
    typedef struct { AudioDeviceID dev_id; AudioDeviceIOProcID proc_id; char name[256]; } RemoveEntry;
    RemoveEntry to_remove[MAX_OUTPUTS];
    int n_remove = 0;

    pthread_mutex_lock(&g_outputs_lock);
    for (int i = 0; i < g_n_outputs; i++) {
        /* Tombstones/freie Slots ueberspringen — find_device_by_uid("") wuerde
         * sonst leere Slots als "verschwunden" melden. */
        if (!g_outputs[i].uid[0]) continue;
        if (!g_outputs[i].active) continue; /* H1: in-flight/removing slot überspringen */
        /* find_device_by_uid ist eine CoreAudio-Abfrage, aber kein Mach-IPC-Blocking-Call
         * (rein property-basiert, kurz). Bleibt hier unter Lock als Phase-A-Operation. */
        AudioDeviceID found = find_device_by_uid(g_outputs[i].uid);
        if (found == kAudioDeviceUnknown) {
            fprintf(stdout, "Helper: Device verschwunden — entferne %s\n", g_outputs[i].name);
            /* Snapshot fuer Phase B */
            to_remove[n_remove].dev_id  = g_outputs[i].dev_id;
            to_remove[n_remove].proc_id = g_outputs[i].proc_id;
            strncpy(to_remove[n_remove].name, g_outputs[i].name,
                    sizeof(to_remove[n_remove].name) - 1);
            to_remove[n_remove].name[sizeof(to_remove[n_remove].name)-1] = '\0';
            n_remove++;
            /* Tombstoning: Slot als freien Tombstone markieren — KEIN Kompaktieren.
             * Alle anderen Outputs behalten ihre Slot-Adresse und laufen weiter. */
            memset(&g_outputs[i], 0, sizeof(DeviceOutput));
        }
    }
    g_n_active_outputs = recount_active_locked();
    pthread_mutex_unlock(&g_outputs_lock);

    /* Phase B: Stop/Destroy OHNE Lock */
    for (int r = 0; r < n_remove; r++) {
        if (to_remove[r].proc_id) {
            AudioDeviceStop(to_remove[r].dev_id, to_remove[r].proc_id);
            AudioDeviceDestroyIOProcID(to_remove[r].dev_id, to_remove[r].proc_id);
        }
    }
}

static void hotplug_register(void)
{
    if (atomic_load_explicit(&g_hotplug_registered, memory_order_acquire)) return;
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };
    OSStatus err = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &addr,
                                                   devices_changed_listener, NULL);
    if (err == noErr) {
        atomic_store_explicit(&g_hotplug_registered, 1, memory_order_release);
        fprintf(stdout, "Helper: Hot-Plug-Listener aktiv\n");
    } else {
        fprintf(stderr, "Helper: Hot-Plug-Listener konnte nicht registriert werden (err=%d)\n",
                (int)err);
    }
}

static void hotplug_unregister(void)
{
    if (!atomic_load_explicit(&g_hotplug_registered, memory_order_acquire)) return;
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &addr,
                                       devices_changed_listener, NULL);
    atomic_store_explicit(&g_hotplug_registered, 0, memory_order_release);
}

/* K2: Mach-Timebase-Faktor (numer/denom) — einmalig initialisiert in main(). */
static double g_mach_ns_per_tick = 1.0;

/* Gibt aktuelle Zeit in Nanosekunden (monoton). */
static inline uint64_t get_time_ns(void)
{
    return (uint64_t)((double)mach_absolute_time() * g_mach_ns_per_tick);
}

/* ── Volume-Polling Thread (Phase 4) ────────────────────────────────────── */

static void *volume_poll_thread(void *arg)
{
    (void)arg;
    while (atomic_load_explicit(&g_volume_running, memory_order_acquire) &&
           atomic_load_explicit(&g_running, memory_order_acquire)) {
        /* H2: Ausstehenden deferred-Unmap aus dem letzten Reconnect abräumen. */
        shm_flush_pending_unmap();

        ARNSharedRing *ring = atomic_load_explicit(&g_ring, memory_order_acquire);
        if (ring) {
            /* Robustheit: Driver wurde evtl. neu geladen — magic/version pruefen.
             * Bei Mismatch (z.B. coreaudiod restart): SHM neu verbinden. */
            if (ring->magic != ARN_RING_MAGIC || ring->version != ARN_RING_VERSION) {
                fprintf(stderr, "Helper: SHM-Header invalid — Driver wurde neu geladen, reconnect...\n");
                /* H2: Deferred-Disconnect — IOProcs sehen sofort NULL (acquire),
                 * altes Segment wird erst im naechsten Zyklus wirklich unmappt. */
                shm_disconnect_deferred();

                /* Reconnect-Loop */
                while (atomic_load_explicit(&g_running, memory_order_acquire) &&
                       atomic_load_explicit(&g_volume_running, memory_order_acquire)) {
                    ARNSharedRing *new_ring = shm_connect();
                    if (new_ring) {
                        atomic_store_explicit(&g_ring, new_ring, memory_order_release);
                        atomic_fetch_add_explicit(&g_reconnect_count, 1u, memory_order_relaxed);
                        break;
                    }
                    usleep(SHM_RETRY_INTERVAL_US);
                }
                /* Local-Read-Indices der Outputs auf aktuelles write_idx setzen */
                {
                    ARNSharedRing *reconnected = atomic_load_explicit(&g_ring, memory_order_acquire);
                    if (reconnected) {
                        uint32_t w = atomic_load_explicit(&reconnected->write_idx, memory_order_acquire);
                        pthread_mutex_lock(&g_outputs_lock);
                        for (int i = 0; i < g_n_outputs; i++) {
                            /* Tombstones ueberspringen (belegte Slots — aktiv
                             * oder in-flight output_add — werden resettet). */
                            if (!g_outputs[i].uid[0]) continue;
                            atomic_store_explicit(&g_outputs[i].local_ridx, w, memory_order_release);
                            /* K6: Pending-Reset — IOProc koennte weiter laufen waehrend
                             * wir reconnecten. Direktschreiben in src_frac_ridx = Data Race. */
                            atomic_store_explicit(&g_outputs[i].frac_ridx_reset_widx, w,
                                                  memory_order_release);
                            atomic_fetch_add_explicit(&g_outputs[i].frac_ridx_reset_gen, 1u,
                                                      memory_order_acq_rel);
                            /* B1-Fix: last_ridx_sample + last_progress_ns synchronisieren —
                             * verhindert false-positive recovery_count-Inkremente nach Reconnect.
                             * Ohne Fix: cur_ridx(=w) != last_ridx_sample(=alter Wert) → sofortiger
                             * recovery++ obwohl kein echter Stall-Recovery stattfand. */
                            g_outputs[i].last_ridx_sample = w;
                            g_outputs[i].last_progress_ns = get_time_ns();
                            atomic_store_explicit(&g_outputs[i].stalled, 0u, memory_order_release);
                            /* Tranche B: Pre-Roll re-arm nach SHM-Reconnect — Ring wurde
                             * neu verbunden, erst wieder HWM aufbauen bevor Audio fliesst. */
                            atomic_store_explicit(&g_outputs[i].preroll_armed, 1u, memory_order_release);
                            /* Tranche C: PI State zurücksetzen */
                            g_outputs[i].fill_ewma   = (double)g_outputs[i].src_ring_target / 2.0;
                            g_outputs[i].integ_error = 0.0;
                        }
                        pthread_mutex_unlock(&g_outputs_lock);
                    }
                }
                continue;
            }

            /* ── Phase 6: Adaptive SRC-Ratio pro Output-Device aktualisieren ── */
            #define SRC_P_GAIN       0.01f    /* P-Verstaerkung — stabil bei +/-500ppm Headroom */
            #define SRC_MAX_PPM      500.0f   /* Maximale Korrektur +/-500ppm                   */
            #define SRC_RATIO_CLAMP  (SRC_MAX_PPM / 1000000.0f)
            /* Tranche C: PI-Regler Parameter */
            #define SRC_EWMA_ALPHA   0.1f   /* EWMA-Glättung: τ ≈ 10 Polls × 50ms = 500ms */
            #define SRC_KI           0.0005f /* I-Verstärkung: sehr klein — Drift ist ein langsamer Prozess */
            #define SRC_DT           0.05f   /* Poll-Intervall in Sekunden */
            /* Anti-Windup: I-Term darf max. ±300ppm beitragen (Gesamt-Clamp bleibt ±500ppm) */
            #define SRC_KI_CLAMP     (300.0f / 1000000.0f)

            pthread_mutex_lock(&g_outputs_lock);
            uint32_t w_now = atomic_load_explicit(&ring->write_idx, memory_order_acquire);

            for (int i = 0; i < g_n_outputs; i++) {
                DeviceOutput *dev = &g_outputs[i];
                if (!dev->active) continue;

                /* K2: Stall-Detection — prüfe ob local_ridx Fortschritt macht. */
                uint32_t cur_ridx = atomic_load_explicit(&dev->local_ridx, memory_order_acquire);
                uint64_t now_ns   = get_time_ns();

                /* P6: Hard-Stall-Detection (~300ms). Drei Bedingungen MUESSEN
                 * gleichzeitig gelten:
                 *   (1) ridx eingefroren (cur_ridx == last_ridx_sample),
                 *   (2) Ring-Fill > 75%,
                 *   (3) ioproc_calls steigt (IOProc laeuft, konsumiert aber nicht).
                 * Solange alle drei seit >300ms gelten → Hard-Stall. */
                uint32_t cur_ioproc_calls = atomic_load_explicit(&dev->ioproc_calls,
                                                                 memory_order_relaxed);
                bool ioproc_running = (cur_ioproc_calls != dev->last_ioproc_calls_sample);
                uint32_t hard_fill  = w_now - cur_ridx;  /* Samples im Ring fuer diesen Output */
                bool ring_very_full = (hard_fill >
                    (ARN_RING_CAPACITY * HARD_STALL_FILL_NUM) / HARD_STALL_FILL_DEN);
                bool ridx_frozen    = (cur_ridx == dev->last_ridx_sample);
                dev->last_ioproc_calls_sample = cur_ioproc_calls;

                if (ridx_frozen && ring_very_full && ioproc_running
                    && !atomic_load_explicit(&dev->stalled, memory_order_acquire)) {
                    if (dev->hard_stall_since_ns == 0) {
                        dev->hard_stall_since_ns = now_ns;  /* Fenster startet */
                    } else if ((now_ns - dev->hard_stall_since_ns) > HARD_STALL_TIMEOUT_NS) {
                        /* Hard-Stall bestaetigt — gleiche Recovery wie Soft-Stall. */
                        atomic_store_explicit(&dev->stalled, 1u, memory_order_release);
                        atomic_store_explicit(&dev->frac_ridx_reset_widx, w_now, memory_order_release);
                        atomic_fetch_add_explicit(&dev->frac_ridx_reset_gen, 1u, memory_order_acq_rel);
                        atomic_store_explicit(&dev->local_ridx, w_now, memory_order_release);
                        dev->last_ridx_sample = w_now;
                        dev->fill_ewma   = (double)dev->src_ring_target / 2.0;
                        dev->integ_error = 0.0;
                        dev->hard_stall_since_ns = 0;
                        fprintf(stderr, "Helper: Output '%s' HARD-STALL — IOProc laeuft, "
                                "ridx eingefroren, Ring >75%% seit >300ms. "
                                "Position auf write_idx zurueckgesetzt.\n", dev->name);
                        /* Stall gesetzt + Position auf w_now korrigiert — Soft-Stall-
                         * Logik und P-Regler fuer diesen Tick ueberspringen. */
                        continue;
                    }
                } else {
                    /* Mindestens eine Bedingung verletzt → Fenster zuruecksetzen. */
                    dev->hard_stall_since_ns = 0;
                }

                if (cur_ridx != dev->last_ridx_sample) {
                    /* Fortschritt — Stall zurücksetzen */
                    dev->last_ridx_sample  = cur_ridx;
                    dev->last_progress_ns  = now_ns;
                    if (atomic_load_explicit(&dev->stalled, memory_order_acquire)) {
                        atomic_store_explicit(&dev->stalled, 0u, memory_order_release);
                        atomic_fetch_add_explicit(&dev->recovery_count, 1u, memory_order_relaxed);
                        /* Tranche C: PI-Regler State bei Stall-Recovery reinitialisieren */
                        dev->fill_ewma   = (double)dev->src_ring_target / 2.0;
                        dev->integ_error = 0.0;
                        fprintf(stdout, "Helper: Output '%s' hat sich von Stall erholt\n",
                                dev->name);
                    }
                } else {
                    /* Kein Fortschritt — nur als Stall werten wenn auch Daten vorhanden
                     * (bei Underrun ist kein Fortschritt normal, kein echter Stall). */
                    uint32_t fill = w_now - cur_ridx;
                    if (fill >= 4u /* mindestens 2 Stereo-Frames verfügbar */
                        && (now_ns - dev->last_progress_ns) > STALL_TIMEOUT_NS) {
                        if (!atomic_load_explicit(&dev->stalled, memory_order_acquire)) {
                            atomic_store_explicit(&dev->stalled, 1u, memory_order_release);
                            /* K2-FIX: Pending-Reset auf write_idx — bricht den Endlos-Underrun-Zyklus.
                             * Ohne Reset: IOProc springt per Overflow-Guard auf widx, hat behind=0
                             * und needed>0 → immer Underrun → local_ridx bewegt sich nie → Stall bleibt.
                             * Mit Reset: IOProc setzt src_frac_ridx=widx/2, naechste Calls recovern
                             * sobald write_idx genug vorgerückt ist. */
                            atomic_store_explicit(&dev->frac_ridx_reset_widx, w_now, memory_order_release);
                            atomic_fetch_add_explicit(&dev->frac_ridx_reset_gen, 1u, memory_order_acq_rel);
                            /* local_ridx auf w_now setzen damit P-Regler nicht irrtümlich
                             * "Ring voll" meldet und Ratio aufpumpt (würde needed > increment machen). */
                            atomic_store_explicit(&dev->local_ridx, w_now, memory_order_release);
                            dev->last_ridx_sample = w_now;
                            /* Tranche C: PI-Regler State bei Stall zurücksetzen */
                            dev->fill_ewma   = (double)dev->src_ring_target / 2.0;
                            dev->integ_error = 0.0;
                            fprintf(stderr, "Helper: Output '%s' gestallt — "
                                    "kein Fortschritt seit >1000ms trotz Daten im Ring. "
                                    "Aus read_idx-Aggregat ausgeschlossen, Position auf write_idx gesetzt.\n",
                                    dev->name);
                        }
                    }
                }

                /* K2-FIX: P-Regler auf gestallten Outputs NICHT anwenden —
                 * fill = w_now - w_now = 0 nach dem Reset oben, ratio bleibt bei base_ratio. */
                if (atomic_load_explicit(&dev->stalled, memory_order_acquire)) {
                    continue;
                }

                /* ARC-5: Lag-Eviction — Output der dauerhaft >90% hinter write_idx
                 * liegt wird force-resynct, bevor er den gesamten Ring-Headroom des
                 * Producers auffrisst (read_idx-Aggregat = min aller Positionen).
                 * src_frac_ridx ist IOProc-privat; der Read hier ist eine Naeherung
                 * (64-bit aligned double-Load, auf arm64 nicht torn).
                 * Obergrenze 2*CAPACITY als Sanity-Check: liegt die Position durch
                 * Sampling-Skew knapp VOR w_now, ergibt die wrapped-uint32-Differenz
                 * einen riesigen Wert — der darf keine False-Positive-Eviction
                 * ausloesen (echter Lag ist durch den Producer auf ~CAPACITY begrenzt). */
                {
                    uint32_t lag_ridx = (uint32_t)(dev->src_frac_ridx * 2.0); /* ungefaehre Position */
                    uint32_t distance = w_now - lag_ridx; /* wrapped uint32 arithmetic */
                    if (distance > (ARN_RING_CAPACITY * 9u) / 10u &&
                        distance <= ARN_RING_CAPACITY * 2u) {
                        /* Output ist mehr als 90% hinter write_idx — force-resync */
                        atomic_store_explicit(&dev->frac_ridx_reset_widx, w_now,
                                              memory_order_release);
                        atomic_fetch_add_explicit(&dev->frac_ridx_reset_gen, 1u,
                                                  memory_order_acq_rel);
                        /* Wie im Stall-Pfad: local_ridx mitziehen, damit der
                         * PI-Regler nicht "Ring voll" sieht und aufpumpt. */
                        atomic_store_explicit(&dev->local_ridx, w_now, memory_order_release);
                        dev->last_ridx_sample = w_now;
                        dev->fill_ewma   = (double)dev->src_ring_target / 2.0;
                        dev->integ_error = 0.0;
                        fprintf(stderr, "Helper: Output '%s' Lag-Eviction — "
                                ">90%% hinter write_idx (distance=%u Samples), "
                                "force-resync auf write_idx.\n", dev->name, distance);
                        continue;
                    }
                }

                uint32_t fill_samples  = w_now - atomic_load_explicit(&dev->local_ridx, memory_order_acquire);
                uint32_t fill_frames   = fill_samples / 2u;   /* Stereo -> /2 */
                uint32_t target_frames = dev->src_ring_target / 2u;

                /* Tranche C: EWMA-Glättung des Füllstands — trennt echten Drift von Jitter.
                 * Zeitkonstante ≈ 10 Polls × 50ms = 500ms.
                 * NUR vom volume_poll_thread: kein Atomic nötig. */
                dev->fill_ewma = SRC_EWMA_ALPHA * (double)fill_frames
                               + (1.0 - SRC_EWMA_ALPHA) * dev->fill_ewma;

                /* Normierter Fehler auf Basis EWMA (nicht nacktem fill_frames) */
                float error_norm = (float)((double)dev->fill_ewma - (double)target_frames)
                                   / ((float)ARN_RING_CAPACITY * 0.5f);

                /* P-Term */
                float p_term = error_norm * SRC_P_GAIN;

                /* I-Term: Akkumuliert langfristigen Clock-Drift.
                 * Anti-Windup: Clamp BEVOR Akkumulation — verhindert Integrator-Explosion. */
                float ki_contrib = error_norm * SRC_KI * SRC_DT;
                dev->integ_error += (double)ki_contrib;
                /* Anti-Windup: I-Term-Beitrag auf ±SRC_KI_CLAMP begrenzen */
                if (dev->integ_error >  (double)SRC_KI_CLAMP) dev->integ_error =  (double)SRC_KI_CLAMP;
                if (dev->integ_error < -(double)SRC_KI_CLAMP) dev->integ_error = -(double)SRC_KI_CLAMP;

                /* PI-Korrektur = P + I */
                float correction = p_term + (float)dev->integ_error;

                /* Gesamt-Clamp auf +/-500ppm (Hardware-Grenze) */
                if (correction >  SRC_RATIO_CLAMP) correction =  SRC_RATIO_CLAMP;
                if (correction < -SRC_RATIO_CLAMP) correction = -SRC_RATIO_CLAMP;

                /* Basisverhaeltnis: ring_sr/device_sr. Gleiche Rate: 1.0. */
                float ratio_f = (float)dev->base_ratio + correction;
                /* Defensiver Clamp: verhindert UB beim float→uint32_t-Cast falls
                 * base_ratio pathologisch klein waere (in der Praxis unmoeglich bei
                 * realen Sample-Raten, aber sicher ist sicher). */
                if (ratio_f < 0.0f) ratio_f = 0.0f;
                uint32_t ratio_q20 = (uint32_t)(ratio_f * (float)(1u << 20));

                atomic_store_explicit(&dev->src_ratio_q20, ratio_q20, memory_order_release);
            }
            pthread_mutex_unlock(&g_outputs_lock);

            /* Auch globalen read_idx aktualisieren — Producer kann sonst voll laufen. */
            update_global_read_idx();
        }

        /* SR-Aenderung erkennen (sr_change_gen wird vom Driver inkrementiert) */
        {
            static uint32_t last_sr_gen = UINT32_MAX; /* UINT32_MAX = noch nicht initialisiert */
            ARNSharedRing *rsr2 = atomic_load_explicit(&g_ring, memory_order_acquire);
            if (rsr2) {
                uint32_t cur_gen = atomic_load_explicit(&rsr2->sr_change_gen, memory_order_acquire);
                if (last_sr_gen == UINT32_MAX) {
                    last_sr_gen = cur_gen; /* Initialisierung: aktuellen Wert merken */
                } else if (cur_gen != last_sr_gen) {
                    last_sr_gen = cur_gen;
                    sr_reinit_all_outputs();
                }
            }
        }

        /* H3: Hot-Plug-Reaktion ausserhalb des CoreAudio-Callbacks verarbeiten. */
        if (atomic_exchange_explicit(&g_hotplug_pending, 0, memory_order_acq_rel)) {
            process_hotplug_removals();
        }

        /* F6: coreaudiod CPU-Poll entfernt — proc_pid_rusage/Mach-IPC kann bei
         * degradiertem coreaudiod blockieren und den Volume-Thread haengen. */

        usleep(VOLUME_POLL_INTERVAL_US);
    }
    return NULL;
}

/* ── Config-Socket (Phase 3) ────────────────────────────────────────────── */

/*
 * Minimal-Parser fuer das JSON-Lines Protokoll.
 * Wir akzeptieren ASCII-JSON, ignorieren Whitespace.
 */

static int json_has_cmd(const char *line, const char *cmd)
{
    /* Sucht "cmd"\s*:\s*"<cmd>" */
    char needle1[64], needle2[64];
    snprintf(needle1, sizeof(needle1), "\"cmd\":\"%s\"",   cmd);
    snprintf(needle2, sizeof(needle2), "\"cmd\": \"%s\"",  cmd);
    return (strstr(line, needle1) != NULL || strstr(line, needle2) != NULL);
}

/* MC-9: Strikte Integer-Konvertierung via strtol — ersetzt atoi, das bei
 * ungueltiger Eingabe stillschweigend 0 liefert und Overflow nicht erkennt.
 * Rueckgabe: true bei Erfolg (*out gesetzt), false bei Parse-/Range-Fehler. */
static bool parse_int_strict(const char *str, int *out)
{
    char *end;
    errno = 0;
    long val_l = strtol(str, &end, 10);
    if (errno != 0 || end == str || val_l < INT_MIN || val_l > INT_MAX) {
        return false;
    }
    *out = (int)val_l;
    return true;
}

/*
 * Parst alle (uid, ch_offset) Tupel aus dem "outputs"-Array.
 * Ein primitiver Parser — sucht "uid":"..." und "ch_offset":N Paare.
 * Erwartetes Format:
 *   "outputs": [{"uid":"...","ch_offset":0}, ...]
 *
 * Schreibt in out_uids[][512] und out_offsets[], gibt Anzahl zurueck.
 */
static int parse_outputs(const char *line,
                          char out_uids[MAX_OUTPUTS][512],
                          uint32_t out_offsets[MAX_OUTPUTS])
{
    int n = 0;
    const char *p = strstr(line, "\"outputs\"");
    if (!p) return 0;
    p = strchr(p, '[');
    if (!p) return 0;
    p++;

    while (n < MAX_OUTPUTS) {
        /* naechstes uid suchen, aber vor dem schliessenden ']' stoppen */
        const char *bracket_close = strchr(p, ']');
        const char *uid_key = strstr(p, "\"uid\"");
        if (!uid_key || (bracket_close && uid_key > bracket_close)) break;

        const char *colon = strchr(uid_key, ':');
        if (!colon) break;
        const char *q1 = strchr(colon, '"');
        if (!q1) break;
        q1++;
        const char *q2 = strchr(q1, '"');
        if (!q2) break;

        size_t len = (size_t)(q2 - q1);
        if (len >= 512) len = 511;
        memcpy(out_uids[n], q1, len);
        out_uids[n][len] = '\0';

        /* ch_offset im selben Objekt suchen (vor dem naechsten } oder ]) */
        const char *brace_close = strchr(q2, '}');
        const char *off_key     = strstr(q2, "\"ch_offset\"");
        uint32_t off = 0;
        if (off_key && (!brace_close || off_key < brace_close)) {
            const char *col2 = strchr(off_key, ':');
            if (col2) {
                col2++;
                while (*col2 == ' ' || *col2 == '\t') col2++;
                int off_i = 0;  /* MC-9: strtol statt atoi */
                if (parse_int_strict(col2, &off_i)) {
                    off = (uint32_t)off_i;
                }
            }
        }
        /* Security Fix 3c: negative oder zu grosse Werte abfangen */
        if ((int32_t)off < 0 || off > 32) {
            off = 0;  /* Clamp */
        }
        out_offsets[n] = off;
        n++;

        if (!brace_close) break;
        p = brace_close + 1;
    }

    return n;
}

/* NC-2: write() mit EINTR-Retry + Behandlung partieller Writes.
 * Rueckgabe: 0 = alles geschrieben, -1 = Fehler. */
static int write_full(int fd, const char *buf, size_t len)
{
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, buf + sent, len - sent);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        sent += (size_t)n;
    }
    return 0;
}

/* Schreibt eine vollstaendige Antwort (Newline-terminiert) auf fd. */
static void send_line(int fd, const char *s)
{
    size_t len = strlen(s);
    if (write_full(fd, s, len) != 0) return;
    if (len == 0 || s[len - 1] != '\n') {
        (void)write_full(fd, "\n", 1);
    }
}

/* H6: JSON-String-Escaping — escaped ", \, \n, \r, \t und Control-Chars.
 * Schreibt immer NUL-terminiert in dst (max dstsz-1 nutzbaren Chars).
 * Verhindert kaputtes JSON wenn Device-UIDs Sonderzeichen enthalten. */
static void json_escape_into(char *dst, size_t dstsz, const char *src)
{
    size_t j = 0;
    for (size_t k = 0; src[k] && j + 7 < dstsz; k++) {
        unsigned char c = (unsigned char)src[k];
        if      (c == '"')  { dst[j++] = '\\'; dst[j++] = '"';  }
        else if (c == '\\') { dst[j++] = '\\'; dst[j++] = '\\'; }
        else if (c == '\n') { dst[j++] = '\\'; dst[j++] = 'n';  }
        else if (c == '\r') { dst[j++] = '\\'; dst[j++] = 'r';  }
        else if (c == '\t') { dst[j++] = '\\'; dst[j++] = 't';  }
        else if (c < 0x20)  { j += (size_t)snprintf(dst + j, dstsz - j, "\\u%04x", c); }
        else                { dst[j++] = (char)c; }
    }
    dst[j] = '\0';
}

/* Baut "active":[{...},{...}] JSON-Fragment in buf.
 * MC-7: Rueckgabe true wenn nicht alle Eintraege in den Buffer passten
 * (truncated). Ein unvollstaendiger Eintrag wird komplett verworfen,
 * das Array bleibt immer gueltiges JSON. */
static bool format_active_outputs(char *buf, size_t bufsz)
{
    bool truncated = false;
    pthread_mutex_lock(&g_outputs_lock);
    size_t pos = 0;
    int written = snprintf(buf + pos, bufsz - pos, "[");
    if (written < 0 || (size_t)written >= bufsz) {
        if (bufsz >= 3) { memcpy(buf, "[]", 3); }
        pthread_mutex_unlock(&g_outputs_lock);
        return true;
    }
    pos += (size_t)written;

    int n_emitted = 0;
    for (int i = 0; i < g_n_outputs && pos < bufsz; i++) {
        /* Tombstoning: nur aktive Outputs ausgeben — freie/in-flight Slots
         * ueberspringen. */
        if (!g_outputs[i].active) continue;
        const char *sep = (n_emitted == 0) ? "" : ",";
        /* H6: UID und Name JSON-korrekt escapen — verhindert kaputtes JSON
         * bei Device-UIDs/Namen mit Anführungszeichen oder Backslashes. */
        char safe_name[512];
        char safe_uid[1024];
        json_escape_into(safe_name, sizeof(safe_name), g_outputs[i].name);
        json_escape_into(safe_uid,  sizeof(safe_uid),  g_outputs[i].uid);

        /* Phase 6: src_ratio (Q20 -> float) und underruns mit ausgeben */
        uint32_t ratio_q20 = atomic_load_explicit(&g_outputs[i].src_ratio_q20,
                                                  memory_order_relaxed);
        double   src_ratio = (double)ratio_q20 / (double)(1u << 20);
        uint32_t underruns = atomic_load_explicit(&g_outputs[i].underruns,
                                                  memory_order_relaxed);

        uint32_t stalled = atomic_load_explicit(&g_outputs[i].stalled, memory_order_relaxed);
        uint32_t recovery_count = atomic_load_explicit(&g_outputs[i].recovery_count,
                                                       memory_order_relaxed);
        /* Tranche C: fill_ewma fuer Drift-Tracking in health.py.
         * Non-atomic — sicher gelesen unter g_outputs_lock (Volume-Thread schreibt
         * ebenfalls nur unter diesem Lock). */
        double fill_ewma = g_outputs[i].fill_ewma;
        written = snprintf(buf + pos, bufsz - pos,
                           "%s{\"uid\":\"%s\",\"name\":\"%s\",\"ch_offset\":%u,"
                           "\"src_ratio\":%.6f,\"fill_ewma\":%.2f,\"underruns\":%u,\"stalled\":%u,"
                           "\"recovery_count\":%u}",
                           sep, safe_uid, safe_name, g_outputs[i].ch_offset,
                           src_ratio, fill_ewma, underruns, stalled, recovery_count);
        /* MC-7: Truncation-Detection — Eintrag passt nicht vollstaendig
         * (inkl. Platz fuer das schliessende ']'): Eintrag verwerfen. */
        if (written < 0 || (size_t)written + 1 >= bufsz - pos) {
            buf[pos] = '\0';
            truncated = true;
            break;
        }
        pos += (size_t)written;
        n_emitted++;
    }
    if (pos + 1 < bufsz) {
        buf[pos]     = ']';
        buf[pos + 1] = '\0';
    }
    pthread_mutex_unlock(&g_outputs_lock);
    return truncated;
}

/*
 * parse_and_execute — verarbeitet eine JSON-Zeile, schreibt Antwort auf fd.
 * Rueckgabe: 0=continue, 1=shutdown angefordert.
 */
static int parse_and_execute(int fd, const char *line)
{
    /* MC-7: 24KB — muss active_buf (16KB) plus Status-Felder fassen. */
    char resp[24576];

    if (json_has_cmd(line, "ping")) {
        snprintf(resp, sizeof(resp), "{\"ok\":true,\"pong\":true}");
        send_line(fd, resp);
        return 0;
    }

    if (json_has_cmd(line, "shutdown")) {
        if (!auth_check(line)) {
            send_line(fd, "{\"ok\":false,\"error\":\"auth\"}");
            return 1;  /* Socket schliessen */
        }
        snprintf(resp, sizeof(resp), "{\"ok\":true,\"shutting_down\":true}");
        send_line(fd, resp);
        atomic_store_explicit(&g_running, 0, memory_order_release);
        return 1;
    }

    /* Commands die SHM benoetigen — noch nicht bereit? */
    if (!atomic_load_explicit(&g_shm_ready, memory_order_acquire) && !json_has_cmd(line, "ping") && !json_has_cmd(line, "shutdown") && !json_has_cmd(line, "get_status")) {
        snprintf(resp, sizeof(resp), "{\"ok\":false,\"error\":\"not_ready\"}");
        send_line(fd, resp);
        return 0;
    }

    if (json_has_cmd(line, "get_status")) {
        /* I-5: version via %s — kein Makro-String-Concat, da ARN_HELPER_VERSION
         * erst spaeter im File als #ifndef-Fallback definiert wird. Wird beim
         * Build ohne -DARN_HELPER_VERSION-Flag (z.B. Driver-Makefile) korrekt
         * aufgeloest, weil g_helper_version[] am Datei-Anfang steht. */
        if (!atomic_load_explicit(&g_shm_ready, memory_order_acquire)) {
            snprintf(resp, sizeof(resp),
                     "{\"ok\":true,\"active\":[],\"ring_frames\":0,\"ioproc_calls\":0,"
                     "\"ready\":false,\"version\":\"%s\"}", g_helper_version);
            send_line(fd, resp);
            return 0;
        }
        char active_buf[16384];  /* MC-7: 16KB statt 4KB */
        bool active_truncated = format_active_outputs(active_buf, sizeof(active_buf));
        ARNSharedRing *rstat = atomic_load_explicit(&g_ring, memory_order_acquire);
        uint32_t frames = rstat ? arn_ring_frames_available(rstat) : 0u;
        uint32_t calls  = atomic_load_explicit(&g_ioproc_calls, memory_order_relaxed);
        /* Tranche A: Self-Healing-Telemetrie */
        uint32_t reconnect_count = atomic_load_explicit(&g_reconnect_count,
                                                        memory_order_relaxed);
        uint64_t last_ioproc_ns  = atomic_load_explicit(&g_last_ioproc_call_ns,
                                                        memory_order_relaxed);
        unsigned long long ioproc_age_ms;
        if (last_ioproc_ns == 0) {
            ioproc_age_ms = 9999ULL;  /* noch kein IOProc-Call seit Start */
        } else {
            ioproc_age_ms = (unsigned long long)((get_time_ns() - last_ioproc_ns) / 1000000ULL);
        }
        /* Tranche B: Safe-Take-State exponieren — Python kann aktuellen Modus lesen. */
        int safe_take = atomic_load_explicit(&g_safe_take, memory_order_acquire);
        /* I-5: version via %s — keine Makro-Concatenation nötig */
        snprintf(resp, sizeof(resp),
                 "{\"ok\":true,\"active\":%s,\"ring_frames\":%u,\"ioproc_calls\":%u,"
                 "\"reconnect_count\":%u,\"ioproc_age_ms\":%llu,\"safe_take\":%d,"
                 "\"truncated\":%s,\"ready\":true,\"version\":\"%s\"}",
                 active_buf, frames, calls, reconnect_count, ioproc_age_ms, safe_take,
                 active_truncated ? "true" : "false", g_helper_version);
        send_line(fd, resp);
        return 0;
    }

    if (json_has_cmd(line, "set_outputs")) {
        if (!auth_check(line)) {
            send_line(fd, "{\"ok\":false,\"error\":\"auth\"}");
            return 1;  /* Socket schliessen */
        }
        char     new_uids[MAX_OUTPUTS][512];
        uint32_t new_offs[MAX_OUTPUTS];
        memset(new_uids, 0, sizeof(new_uids));
        memset(new_offs, 0, sizeof(new_offs));
        int n_new = parse_outputs(line, new_uids, new_offs);

        /* H1: output_add() verwaltet Lock selbst — hier OHNE Lock aufrufen */
        int failures = 0;
        for (int k = 0; k < n_new; k++) {
            pthread_mutex_lock(&g_outputs_lock);
            bool already = (find_output_slot_locked(new_uids[k], new_offs[k]) >= 0);
            pthread_mutex_unlock(&g_outputs_lock);
            if (already) continue;
            if (output_add(new_uids[k], new_offs[k]) != 0) {
                failures++;
            }
        }

        /* Remove-Phase: unter Lock */
        pthread_mutex_lock(&g_outputs_lock);
        int n_added_successfully = 0;
        for (int k = 0; k < n_new; k++) {
            if (find_output_slot_locked(new_uids[k], new_offs[k]) >= 0) n_added_successfully++;
        }
        if (n_new == 0 || n_added_successfully > 0) {
            /* Tombstoning: Slot-Indizes bleiben nach einem Remove stabil —
             * daher einfache for-Schleife. Tombstones/in-flight Slots
             * (active=false) ueberspringen. */
            for (int i = 0; i < g_n_outputs; i++) {
                if (!g_outputs[i].active) continue;
                bool keep = false;
                for (int k = 0; k < n_new; k++) {
                    if (strcmp(g_outputs[i].uid, new_uids[k]) == 0 &&
                        g_outputs[i].ch_offset == new_offs[k]) {
                        keep = true; break;
                    }
                }
                if (!keep) {
                    output_remove_locked(g_outputs[i].uid, g_outputs[i].ch_offset);
                }
            }
        }
        char active_buf[16384];  /* MC-7: 16KB statt 4KB */
        pthread_mutex_unlock(&g_outputs_lock);
        bool active_truncated = format_active_outputs(active_buf, sizeof(active_buf));

        if (failures == 0) {
            snprintf(resp, sizeof(resp),
                     "{\"ok\":true,\"active\":%s,\"truncated\":%s}",
                     active_buf, active_truncated ? "true" : "false");
        } else {
            snprintf(resp, sizeof(resp),
                     "{\"ok\":false,\"error\":\"%d output(s) failed\",\"active\":%s,\"truncated\":%s}",
                     failures, active_buf, active_truncated ? "true" : "false");
        }
        send_line(fd, resp);
        return 0;
    }

    if (json_has_cmd(line, "set_sample_rate")) {
        if (!auth_check(line)) {
            send_line(fd, "{\"ok\":false,\"error\":\"auth\"}");
            return 1;  /* Socket schliessen */
        }
        /* Parse rate: "rate":N */
        uint32_t new_sr = 0;
        const char *rate_key = strstr(line, "\"rate\"");
        if (rate_key) {
            const char *col = strchr(rate_key, ':');
            if (col) {
                col++;
                while (*col == ' ' || *col == '\t') col++;
                int sr_i = 0;  /* MC-9: strtol statt atoi */
                if (parse_int_strict(col, &sr_i) && sr_i > 0) {
                    new_sr = (uint32_t)sr_i;
                }
                /* Bei Parse-Fehler bleibt new_sr=0 → "invalid rate"-Antwort unten */
            }
        }

        /* Validate: muss eine der unterstuetzten Raten sein */
        static const uint32_t valid_rates[] = {44100, 48000, 88200, 96000, 176400, 192000};
        bool valid = false;
        for (size_t vi = 0; vi < sizeof(valid_rates) / sizeof(valid_rates[0]); vi++) {
            if (new_sr == valid_rates[vi]) { valid = true; break; }
        }

        if (!valid || new_sr == 0) {
            snprintf(resp, sizeof(resp), "{\"ok\":false,\"error\":\"invalid rate\"}");
            send_line(fd, resp);
            return 0;
        }

        /* P5: Explizite SR-Wahl deaktiviert den Auto-Modus — ab jetzt steuert
         * der User die Rate, neue Outputs ziehen sich auf diese Ring-SR. */
        atomic_store_explicit(&g_auto_sample_rate, 0, memory_order_release);

        ARNSharedRing *rsr = atomic_load_explicit(&g_ring, memory_order_acquire);
        if (!rsr) {
            snprintf(resp, sizeof(resp), "{\"ok\":false,\"error\":\"ring not ready\"}");
            send_line(fd, resp);
            return 0;
        }

        /* Schritt 1: Ring-SR direkt setzen (loest sr_change_gen aus) */
        arn_ring_set_sample_rate(rsr, new_sr);
        fprintf(stdout, "Helper: set_sample_rate %u Hz (via Config-Socket)\n", new_sr);

        /* Schritt 2: Treiber ueber die neue SR informieren (damit gSampleRate + Timing stimmen).
         * Da der Ring jetzt schon bei new_sr ist, passiert der Driver-Guard und erlaubt die Aenderung.
         * arn_ring_set_sample_rate im Driver ist dann ein NO-OP (gleiche SR). */
        AudioDeviceID arn_dev = find_audio_router_device();
        if (arn_dev != kAudioDeviceUnknown) {
            AudioObjectPropertyAddress sr_prop = {
                kAudioDevicePropertyNominalSampleRate,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            Float64 sr_f = (Float64)new_sr;
            OSStatus st = AudioObjectSetPropertyData(arn_dev, &sr_prop, 0, NULL, sizeof(Float64), &sr_f);
            if (st != noErr) {
                fprintf(stderr, "Helper: Warnung — Driver-SR-Update fehlgeschlagen (OSStatus %d)\n", (int)st);
            }
        }

        snprintf(resp, sizeof(resp), "{\"ok\":true,\"rate\":%u}", new_sr);
        send_line(fd, resp);
        return 0;
    }

    /* Tranche B: reconnect_output — Python-Brain kann gezielt einen Output neu starten */
    if (json_has_cmd(line, "reconnect_output")) {
        if (!auth_check(line)) {
            send_line(fd, "{\"ok\":false,\"error\":\"auth\"}");
            return 1;  /* Socket schliessen */
        }
        /* Safe-Take Guard */
        if (atomic_load_explicit(&g_safe_take, memory_order_acquire)) {
            send_line(fd, "{\"ok\":false,\"error\":\"safe_take\"}");
            return 0;
        }
        /* SHM Guard */
        if (!atomic_load_explicit(&g_shm_ready, memory_order_acquire)) {
            send_line(fd, "{\"ok\":false,\"error\":\"shm_reconnecting\"}");
            return 0;
        }
        /* uid extrahieren ("uid":"...") */
        char uid[512] = {0};
        const char *uid_key = strstr(line, "\"uid\"");
        if (uid_key) {
            const char *colon = strchr(uid_key, ':');
            const char *q1 = colon ? strchr(colon, '"') : NULL;
            const char *q2 = q1 ? strchr(q1 + 1, '"') : NULL;
            if (q1 && q2) {
                size_t len = (size_t)(q2 - (q1 + 1));
                if (len >= sizeof(uid)) len = sizeof(uid) - 1;
                memcpy(uid, q1 + 1, len);
                uid[len] = '\0';
            }
        }
        /* ch_offset extrahieren ("ch_offset":N) */
        uint32_t ch_offset = 0;
        const char *off_key = strstr(line, "\"ch_offset\"");
        if (off_key) {
            const char *col2 = strchr(off_key, ':');
            if (col2) {
                col2++;
                while (*col2 == ' ' || *col2 == '\t') col2++;
                int v = 0;  /* MC-9: strtol statt atoi — Parse-Fehler → 0 */
                if (!parse_int_strict(col2, &v)) v = 0;
                if (v < 0 || v > 32) v = 0;  /* Clamp wie in parse_outputs */
                ch_offset = (uint32_t)v;
            }
        }
        if (!uid[0]) {
            send_line(fd, "{\"ok\":false,\"error\":\"missing_uid\"}");
            return 0;
        }
        /* 3-Phasen-Design: output_remove_locked unter Lock, output_add ohne Lock */
        pthread_mutex_lock(&g_outputs_lock);
        int slot = find_output_slot_locked(uid, ch_offset);
        if (slot < 0) {
            pthread_mutex_unlock(&g_outputs_lock);
            send_line(fd, "{\"ok\":false,\"error\":\"not_found\"}");
            return 0;
        }
        output_remove_locked(uid, ch_offset);
        pthread_mutex_unlock(&g_outputs_lock);
        /* output_add ausserhalb des Locks (3-Phasen-Design) */
        int rc = output_add(uid, ch_offset);
        if (rc == 0) {
            send_line(fd, "{\"ok\":true,\"reconnected\":true}");
        } else {
            send_line(fd, "{\"ok\":false,\"error\":\"output_add_failed\"}");
        }
        return 0;
    }

    /* Tranche B: set_safe_take — deaktiviert/aktiviert alle Heiler-Aktuatoren */
    if (json_has_cmd(line, "set_safe_take")) {
        if (!auth_check(line)) {
            send_line(fd, "{\"ok\":false,\"error\":\"auth\"}");
            return 1;  /* Socket schliessen */
        }
        uint32_t enabled = 0;
        const char *en_key = strstr(line, "\"enabled\"");
        if (en_key) {
            const char *col = strchr(en_key, ':');
            if (col) {
                col++;
                while (*col == ' ' || *col == '\t') col++;
                int en_i = 0;  /* MC-9: strtol statt atoi — Parse-Fehler → disabled */
                if (parse_int_strict(col, &en_i)) {
                    enabled = (uint32_t)(en_i != 0);
                }
            }
        }
        atomic_store_explicit(&g_safe_take, (int)enabled, memory_order_release);
        send_line(fd, "{\"ok\":true}");
        return 0;
    }

    /* Unbekanntes Kommando */
    snprintf(resp, sizeof(resp), "{\"ok\":false,\"error\":\"unknown command\"}");
    send_line(fd, resp);
    return 0;
}

/* Verarbeitet einen Client bis EOF oder shutdown. */
static void handle_config_client(int fd)
{
    char   linebuf[16384];
    size_t pos = 0;

    while (atomic_load_explicit(&g_config_running, memory_order_acquire) &&
           atomic_load_explicit(&g_running, memory_order_acquire)) {
        if (pos >= sizeof(linebuf) - 1) {
            /* Linie zu lang — Verbindung schliessen */
            break;
        }

        /* Non-blocking read mit select-timeout */
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 };
        int sel = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (sel < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (sel == 0) continue; /* Timeout — Loop weiter */

        ssize_t n = read(fd, linebuf + pos, sizeof(linebuf) - 1 - pos);
        if (n <= 0) {
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) continue;
            break;
        }
        pos += (size_t)n;
        linebuf[pos] = '\0';

        /* Verarbeite alle vollstaendigen Zeilen */
        char *line_start = linebuf;
        char *nl;
        while ((nl = memchr(line_start, '\n', pos - (size_t)(line_start - linebuf))) != NULL) {
            *nl = '\0';
            if (*line_start) {
                int sd = parse_and_execute(fd, line_start);
                if (sd) {
                    /* shutdown — Client und Loop beenden */
                    return;
                }
            }
            line_start = nl + 1;
        }
        /* Reste am Anfang behalten */
        size_t remain = pos - (size_t)(line_start - linebuf);
        if (remain > 0 && line_start != linebuf) {
            memmove(linebuf, line_start, remain);
        }
        pos = remain;
    }
}

static int config_socket_create(void)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "Helper: socket() fehlgeschlagen (errno=%d)\n", errno);
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, g_config_socket_path, sizeof(addr.sun_path) - 1);

    unlink(g_config_socket_path);

    /* H7: umask VOR bind setzen — Socket entsteht direkt mit 0600,
     * kein TOCTOU-Fenster zwischen bind und chmod. */
    mode_t old_umask = umask(0177);
    int bind_rc = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
    umask(old_umask);
    if (bind_rc < 0) {
        fprintf(stderr, "Helper: bind('%s') fehlgeschlagen (errno=%d)\n",
                g_config_socket_path, errno);
        close(fd);
        return -1;
    }

    if (chmod(g_config_socket_path, 0600) != 0) {  /* Nur Owner — Security Fix 3a */
        /* nicht fatal */
    }

    /* M3: Backlog auf 16 erhöht — verhindert ECONNREFUSED bei schnellen Reconnects */
    if (listen(fd, 16) < 0) {
        fprintf(stderr, "Helper: listen() fehlgeschlagen (errno=%d)\n", errno);
        close(fd);
        unlink(g_config_socket_path);
        return -1;
    }

    /* Non-blocking, damit der Accept-Loop g_running pollen kann */
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    fprintf(stdout, "Helper: Config-Socket lauscht auf %s\n", g_config_socket_path);
    return fd;
}

static void *config_thread_main(void *arg)
{
    (void)arg;
    while (atomic_load_explicit(&g_config_running, memory_order_acquire) &&
           atomic_load_explicit(&g_running, memory_order_acquire)) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(g_config_listen_fd, &rfds);
        struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 };
        int sel = select(g_config_listen_fd + 1, &rfds, NULL, NULL, &tv);
        if (sel <= 0) {
            if (sel < 0 && errno != EINTR) {
                usleep(100000);
            }
            continue;
        }

        int cfd = accept(g_config_listen_fd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
            fprintf(stderr, "Helper: accept() Fehler (errno=%d)\n", errno);
            continue;
        }
        handle_config_client(cfd);
        close(cfd);
    }
    return NULL;
}

/* RT-Priority-Erhöhung entfernt (F7): mach_thread_self() Mach-IPC kann bei
   degradiertem coreaudiod hängen und pthread_join blockieren. */

/* ── Main ───────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    /* NC-4: sigaction statt signal() — definierte Semantik + SA_RESTART
     * (unterbrochene Syscalls werden automatisch neu gestartet). */
    {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = handle_signal;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_RESTART;
        sigaction(SIGTERM, &sa, NULL);
        sigaction(SIGINT,  &sa, NULL);
    }
    signal(SIGPIPE, SIG_IGN);
    signal(SIGALRM, handle_alarm);  /* F1: SIGALRM-Watchdog — _exit(1) wenn Cleanup haengt */

    /* K2: Mach-Timebase für Stall-Detection initialisieren. */
    {
        struct mach_timebase_info tb;
        mach_timebase_info(&tb);
        g_mach_ns_per_tick = (double)tb.numer / (double)tb.denom;
    }

    /* P11/H7: Verzeichnis ~/.audiorouter/ erstellen und Pfade (Socket + Lock)
     * initialisieren. MUSS vor dem Lock-Acquire laufen, da die Lock-Datei nun
     * in diesem Verzeichnis liegt.
     * MC-5: Bei falschem Owner/Permissions des Verzeichnisses → Abbruch. */
    if (!config_socket_path_init()) {
        return 1;
    }

    /* M8/P11: Single-Instance-Guard — direkt nach der Pfad-Init, vor allem anderen. */
    if (helper_acquire_instance_lock() != 0) {
        return 1;
    }

    /* P3: Per-Launch Auth-Token erzeugen und nach ~/.audiorouter/helper.token
     * schreiben. Muss vor dem Start des Config-Sockets laufen, damit jeder
     * privilegierte Request bereits gegen ein gueltiges Token geprueft wird. */
    if (auth_token_init() != 0) {
        fprintf(stderr, "Helper: Auth-Token konnte nicht initialisiert werden — Abbruch\n");
        return 1;
    }

#ifndef ARN_HELPER_VERSION
#define ARN_HELPER_VERSION "UNKNOWN"
#endif
    fprintf(stdout, "AudioRouterNow Helper v" ARN_HELPER_VERSION " (ABI v4)\n");
    fprintf(stdout, "SHM: %s  Ring: %u Frames ~ %.0f ms @48kHz\n",
            ARN_SHM_NAME,
            ARN_RING_CAPACITY / 2u,
            (ARN_RING_CAPACITY / 2.0) / 48000.0 * 1000.0);

    /* 1. Config-Socket ZUERST starten — damit die App waehrend des SHM-Wartens
     *    bereits verbinden kann (ping beantwortet, andere Commands liefern not_ready). */
    g_config_listen_fd = config_socket_create();
    if (g_config_listen_fd >= 0) {
        atomic_store_explicit(&g_config_running, 1, memory_order_release);
        if (pthread_create(&g_config_thread, NULL, config_thread_main, NULL) != 0) {
            fprintf(stderr, "Helper: Config-Thread konnte nicht gestartet werden\n");
            atomic_store_explicit(&g_config_running, 0, memory_order_release);
            close(g_config_listen_fd);
            unlink(g_config_socket_path);
            g_config_listen_fd = -1;
        }
    }

    /* 2. SHM proaktiv erstellen — der Driver-Sandbox-Prozess (_coreaudiod) kann
     *    shm_open(O_CREAT) nicht ausfuehren. Der Helper laeuft als normaler User
     *    ohne Sandbox-Restriktion und erstellt das Segment.
     *
     *    HINWEIS: fchown()/fchmod() sind auf POSIX-SHM-FDs unter macOS nicht
     *    implementiert und schlagen mit EINVAL fehl — Permissions koennen
     *    ausschliesslich ueber das mode-Argument von shm_open(O_CREAT) gesetzt
     *    werden (gefiltert durch umask). Da _coreaudiod keine gemeinsame Gruppe
     *    mit dem eingeloggten User teilt, ist 0666 zwingend erforderlich.
     *    Integritaet wird durch magic/version/size-Checks (C-1) sichergestellt. */
    {
        shm_unlink(ARN_SHM_NAME); /* Stales Segment entfernen (Fehler ignorieren) */
        mode_t shm_old_umask = umask(0);
        int shm_fd = shm_open(ARN_SHM_NAME, O_CREAT | O_RDWR, 0666);
        umask(shm_old_umask);
        if (shm_fd >= 0) {
            if (ftruncate(shm_fd, (off_t)ARN_SHM_SIZE) == 0) {
                void *ptr = mmap(NULL, ARN_SHM_SIZE, PROT_READ | PROT_WRITE,
                                 MAP_SHARED, shm_fd, 0);
                if (ptr != MAP_FAILED) {
                    ARNSharedRing *init_ring = (ARNSharedRing *)ptr;
                    arn_ring_init(init_ring);
                    /* K3: instance_id setzen — eindeutiger Wert pro SHM-Erstellung.
                     * Driver-Watch-Thread vergleicht dieses Feld statt Inodes. */
                    uint64_t iid = mach_absolute_time() ^ (uint64_t)getpid();
                    if (iid == 0) iid = 1; /* Niemals 0 (= nicht initialisiert) */
                    atomic_store_explicit(&init_ring->instance_id, iid, memory_order_release);
                    munmap(ptr, ARN_SHM_SIZE);
                    fprintf(stdout, "Helper: SHM erstellt (%s, 0666 (world-rw), %zu Bytes, iid=0x%llx)\n",
                            ARN_SHM_NAME, ARN_SHM_SIZE, (unsigned long long)iid);
                } else {
                    fprintf(stderr, "Helper: SHM mmap fehlgeschlagen (errno=%d)\n", errno);
                }
            } else {
                fprintf(stderr, "Helper: SHM ftruncate fehlgeschlagen (errno=%d)\n", errno);
            }
            close(shm_fd);
        } else {
            fprintf(stderr, "Helper: SHM-Erstellung fehlgeschlagen (errno=%d)\n", errno);
        }
    }

    /* 3. SHM-Ring verbinden (direkt — wir haben es gerade selbst angelegt) */
    fprintf(stdout, "Warte auf SHM-Ring vom Plugin...\n");
    while (atomic_load_explicit(&g_running, memory_order_acquire) &&
           atomic_load_explicit(&g_ring, memory_order_acquire) == NULL) {
        ARNSharedRing *connected = shm_connect();
        if (connected != NULL) {
            atomic_store_explicit(&g_ring, connected, memory_order_release);
        } else {
            usleep(SHM_RETRY_INTERVAL_US);
        }
    }
    if (!atomic_load_explicit(&g_running, memory_order_acquire)) {
        atomic_store_explicit(&g_config_running, 0, memory_order_release);
        if (g_config_listen_fd >= 0) {
            close(g_config_listen_fd);
            g_config_listen_fd = -1;
            pthread_join(g_config_thread, NULL);
            unlink(g_config_socket_path);
        }
        return 0;
    }

    /* SHM bereit — ab jetzt sind alle Commands erlaubt */
    atomic_store_explicit(&g_shm_ready, 1, memory_order_release);
    fprintf(stdout, "Helper: SHM bereit — Routing kann starten\n");

    /* Keep-Alive IOProc auf dem virtuellen Device starten.
     * Hält gDeviceIsRunning=1 im HAL-Driver — Musik-Apps finden beim
     * Default-Output-Switch ein bereits laufendes Device vor. */
    keepalive_start(find_device_by_uid(OUR_DEVICE_UID));

    /* 3. Hot-Plug-Listener registrieren */
    hotplug_register();

    /* 4. Outputs hinzufuegen — entweder aus CLI-Args oder Auto-Default */
    /* H1: output_add() verwaltet Lock selbst */
    if (argc >= 2) {
        for (int a = 1; a < argc && g_n_outputs < MAX_OUTPUTS; a++) {
            output_add(argv[a], 0);
        }
    } else {
        AudioDeviceID auto_dev = find_default_output_device();
        if (auto_dev != kAudioDeviceUnknown) {
            char *uid = device_get_uid(auto_dev);
            if (uid) {
                output_add(uid, 0);
                free(uid);
            }
        }
    }
    pthread_mutex_lock(&g_outputs_lock);
    int n_initial = g_n_active_outputs;
    pthread_mutex_unlock(&g_outputs_lock);

    if (n_initial == 0) {
        fprintf(stderr, "Helper: Kein initiales Output-Device — warte auf Config-Socket\n");
    }

    /* 5. Volume-Polling Thread starten */
    atomic_store_explicit(&g_volume_running, 1, memory_order_release);
    if (pthread_create(&g_volume_thread, NULL, volume_poll_thread, NULL) != 0) {
        fprintf(stderr, "Helper: Volume-Thread konnte nicht gestartet werden\n");
        atomic_store_explicit(&g_volume_running, 0, memory_order_release);
    } else {
        g_volume_thread_started = true;  /* NC-1 */
    }

    /* RT-Priority-Erhöhung entfernt (F7): mach_thread_self() Mach-IPC kann bei
       degradiertem coreaudiod hängen und pthread_join blockieren. */

    fprintf(stdout, "Helper laeuft — Routing aktiv. Ctrl+C zum Beenden.\n");
    fflush(stdout);

    /* 6. Hauptschleife: Diagnostics alle 2s */
    int tick = 0;
    uint32_t prev_calls = 0;
    while (atomic_load_explicit(&g_running, memory_order_acquire)) {
        usleep(200000); /* 200ms */
        tick++;
        if (tick % 10 == 0) {
            ARNSharedRing *rmain = atomic_load_explicit(&g_ring, memory_order_acquire);
            uint32_t frames = rmain ? arn_ring_frames_available(rmain) : 0u;
            uint32_t calls  = atomic_load_explicit(&g_ioproc_calls, memory_order_relaxed);
            uint32_t delta  = calls - prev_calls;
            prev_calls = calls;
            pthread_mutex_lock(&g_outputs_lock);
            int n = g_n_active_outputs;
            pthread_mutex_unlock(&g_outputs_lock);
            fprintf(stdout, "\rRing: %4u Frames | Outputs: %d | IOProc-Calls: +%u/2s (%u total)      ",
                    frames, n, delta, calls);
            fflush(stdout);
        }
    }

    /* 7. Cleanup */
    fprintf(stdout, "\nHelper: wird beendet...\n");

    atomic_store_explicit(&g_config_running, 0, memory_order_release);
    atomic_store_explicit(&g_volume_running, 0, memory_order_release);

    alarm(5);  /* F1: haengt ein pthread_join (z.B. Mach-IPC zu degradiertem
                * coreaudiod), erzwingt SIGALRM nach 5s ein _exit(1). */

    if (g_volume_thread_started) {  /* NC-1: explizites Flag statt pthread_t-Truthiness */
        pthread_join(g_volume_thread, NULL);
    }
    if (g_config_listen_fd >= 0) {
        close(g_config_listen_fd);
        g_config_listen_fd = -1;
        pthread_join(g_config_thread, NULL);
        unlink(g_config_socket_path);
    }

    hotplug_unregister();
    keepalive_stop();
    outputs_stop_all();
    shm_disconnect();

    /* M8: Instance-Lock freigeben. */
    if (g_lock_fd >= 0) {
        flock(g_lock_fd, LOCK_UN);
        close(g_lock_fd);
        g_lock_fd = -1;
    }

    shm_flush_pending_unmap();  /* H2: letzten Reconnect-Rest freigeben */

    fprintf(stdout, "Helper: beendet.\n");
    return 0;
}
