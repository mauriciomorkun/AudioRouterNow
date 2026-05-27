/*
 * AudioRouterNowHelper.c — Phase 5 (Multi-Device + Config-Socket + Volume-Polling + launchd-ready)
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
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <pthread.h>
#include <stdbool.h>
#include <errno.h>

/* ── Konfiguration ──────────────────────────────────────────────────────── */

#define OUR_DEVICE_UID         "com.audiorouter.now.device"   /* virtuelles Device ausschliessen */
#define SHM_RETRY_INTERVAL_US  500000                          /* 500ms zwischen shm_open-Versuchen */
#define CONFIG_SOCKET_PATH     "/tmp/audiorouter.config.sock"
#define VOLUME_POLL_INTERVAL_US 50000                          /* 50ms Volume-Polling */

#define MAX_OUTPUTS            8

/* ── Datenstrukturen ────────────────────────────────────────────────────── */

typedef struct DeviceOutput {
    AudioDeviceID        dev_id;
    AudioDeviceIOProcID  proc_id;
    uint32_t             local_ridx;     /* Eigene Leseposition (nicht in SHM) */
    uint32_t             ch_offset;      /* 0=Ch1-2, 2=Ch3-4, ...                */
    char                 uid[512];
    char                 name[256];
    bool                 active;
    _Atomic uint32_t     underruns;      /* Diagnostic: Underrun-Zaehler         */
    /* Phase 6 — Adaptive SRC fuer Clock-Drift-Kompensation */
    double               src_frac_ridx;    /* fraktionaler Leseindex (ersetzt local_ridx im IOProc) */
    _Atomic uint32_t     src_ratio_q20;    /* Q20-Ratio: 1.0 = 1<<20. Volume-Thread schreibt, IOProc liest */
    uint32_t             src_ring_target;  /* Ziel-Fuellstand in Samples (= ARN_RING_CAPACITY/2) */
    /* Pre-allokierter Temp-Buffer fuer De-Interleaving im IOProc (RT-safe). */
    float                temp_buf[ARN_RING_CAPACITY];
} DeviceOutput;

/* ── Globaler Zustand ───────────────────────────────────────────────────── */

static volatile int            g_running        = 1;
static ARNSharedRing          *g_ring           = NULL;
static int                     g_shm_fd         = -1;

static DeviceOutput            g_outputs[MAX_OUTPUTS];
static int                     g_n_outputs      = 0;
static pthread_mutex_t         g_outputs_lock   = PTHREAD_MUTEX_INITIALIZER;

/* Diagnostic: wie oft wurde IRGENDEIN IOProc aufgerufen? */
static _Atomic uint32_t        g_ioproc_calls   = 0;

/* Config-Socket Thread */
static pthread_t               g_config_thread;
static int                     g_config_listen_fd = -1;
static volatile int            g_config_running   = 0;

/* Volume-Polling Thread */
static pthread_t               g_volume_thread;
static volatile int            g_volume_running   = 0;

/* Hot-Plug-Listener flag */
static volatile int            g_hotplug_registered = 0;

/* ── Forward Declarations ───────────────────────────────────────────────── */

static int   output_add_locked(const char *uid, uint32_t ch_offset);
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
    g_running = 0;
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

    g_shm_fd = fd;
    fprintf(stdout, "Helper: SHM verbunden — %s (%u Frames Kapazitaet, SR=%u)\n",
            ARN_SHM_NAME, ring->capacity / ring->channels, ring->sample_rate);
    return ring;
}

static void shm_disconnect(void)
{
    if (g_ring != NULL) {
        munmap(g_ring, ARN_SHM_SIZE);
        g_ring = NULL;
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
    UInt32 size = sizeof(uid_ref);
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
    UInt32 size = sizeof(name_ref);
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
        UInt32 out_ch = device_output_channels(devices[i]);
        if (dev_uid && strcmp(dev_uid, uid) == 0 && out_ch >= 2) {
            result = devices[i];
            free(dev_uid);
            break;
        }
        free(dev_uid);
    }
    free(devices);
    return result;
}

/*
 * Auto-Auswahl: erstes 48kHz-Device das nicht das eigene virtuelle ist.
 * Wird verwendet wenn kein UID-Hint vorhanden ist.
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

    AudioDeviceID fallback = kAudioDeviceUnknown;
    AudioDeviceID result   = kAudioDeviceUnknown;

    for (UInt32 i = 0; i < count; i++) {
        char *uid = device_get_uid(devices[i]);
        UInt32 out_ch = device_output_channels(devices[i]);
        if (out_ch >= 2 && uid && strcmp(uid, OUR_DEVICE_UID) != 0) {
            if (fallback == kAudioDeviceUnknown) fallback = devices[i];

            AudioObjectPropertyAddress sr_addr = {
                .mSelector = kAudioDevicePropertyNominalSampleRate,
                .mScope    = kAudioObjectPropertyScopeGlobal,
                .mElement  = kAudioObjectPropertyElementMain
            };
            Float64 rate = 0.0;
            UInt32 sz = sizeof(rate);
            AudioObjectGetPropertyData(devices[i], &sr_addr, 0, NULL, &sz, &rate);
            if ((UInt32)rate == 48000u) {
                result = devices[i];
                free(uid);
                break;
            }
        }
        free(uid);
    }
    free(devices);
    return (result != kAudioDeviceUnknown) ? result : fallback;
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

    DeviceOutput  *dev  = (DeviceOutput *)inClientData;
    ARNSharedRing *ring = g_ring;

    if (!dev || !ring || !outOutputData) return noErr;

    /* Volume + Mute aus Shared-Control lesen (atomic, low-cost) */
    uint32_t vol_q16 = atomic_load_explicit(&ring->volume_q16, memory_order_relaxed);
    uint32_t muted   = atomic_load_explicit(&ring->muted,      memory_order_relaxed);

    UInt32 nBufs = outOutputData->mNumberBuffers;
    if (nBufs == 0) return noErr;

    /* nFrames bestimmen — bei non-interleaved nehmen wir Buffer 0 als Referenz */
    UInt32 nFrames;
    if (nBufs >= 2) {
        nFrames = outOutputData->mBuffers[0].mDataByteSize / sizeof(float);
    } else {
        UInt32 nCh = outOutputData->mBuffers[0].mNumberChannels;
        if (nCh == 0) return noErr;
        nFrames = outOutputData->mBuffers[0].mDataByteSize / sizeof(float) / nCh;
    }

    uint32_t nSamplesStereo = nFrames * 2u;
    if (nSamplesStereo > ARN_RING_CAPACITY) nSamplesStereo = ARN_RING_CAPACITY;

    /* ── Fraktionaler Ring-Read mit linearer Interpolation (Phase 6 SRC) ── */
    uint32_t ratio_q20 = atomic_load_explicit(&dev->src_ratio_q20, memory_order_relaxed);
    double   ratio     = (double)ratio_q20 / (double)(1u << 20);

    /* Pruefe ob genug Frames verfuegbar (mit ratio-Headroom).
     * src_frac_ridx ist Frame-Index → *2 fuer Sample-Vergleich mit widx (Sample-Index). */
    uint32_t widx  = atomic_load_explicit(&ring->write_idx, memory_order_acquire);
    uint32_t needed_samples = (uint32_t)(nFrames * ratio * 2.0 + 4.0); /* +4 fuer Interpolations-Lookahead */
    uint32_t avail = widx - (uint32_t)(dev->src_frac_ridx * 2.0);

    int underrun = 0;
    if (avail < needed_samples) {
        memset(dev->temp_buf, 0, nSamplesStereo * sizeof(float));
        underrun = 1;
        atomic_fetch_add_explicit(&dev->underruns, 1u, memory_order_relaxed);
        /* Frac-Ridx auf write_idx/2 setzen (Frame-Index!) */
        dev->src_frac_ridx = (double)widx / 2.0;
    } else {
        for (uint32_t f = 0; f < nFrames; f++) {
            uint32_t idx0 = (uint32_t)dev->src_frac_ridx;
            float    frac  = (float)(dev->src_frac_ridx - (double)idx0);
            float    inv   = 1.0f - frac;

            uint32_t si0 = (idx0 * 2u    ) & ARN_RING_MASK;  /* L sample bei idx0   */
            uint32_t si1 = (idx0 * 2u + 1) & ARN_RING_MASK;  /* R sample bei idx0   */
            uint32_t si2 = ((idx0 + 1u) * 2u    ) & ARN_RING_MASK; /* L bei idx0+1 */
            uint32_t si3 = ((idx0 + 1u) * 2u + 1) & ARN_RING_MASK; /* R bei idx0+1 */

            dev->temp_buf[f * 2    ] = ring->samples[si0] * inv + ring->samples[si2] * frac;
            dev->temp_buf[f * 2 + 1] = ring->samples[si1] * inv + ring->samples[si3] * frac;

            dev->src_frac_ridx += ratio;
        }
        /* local_ridx (Sample-Index!) aus Frame-Index ableiten: *2 */
        dev->local_ridx = (uint32_t)(dev->src_frac_ridx * 2.0);
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
    if (!g_ring) return;

    pthread_mutex_lock(&g_outputs_lock);

    if (g_n_outputs == 0) {
        uint32_t w = atomic_load_explicit(&g_ring->write_idx, memory_order_acquire);
        atomic_store_explicit(&g_ring->read_idx, w, memory_order_release);
        pthread_mutex_unlock(&g_outputs_lock);
        return;
    }

    /* Finde Minimum aller local_ridx (mit unsigned Distanz zum write_idx) */
    uint32_t w   = atomic_load_explicit(&g_ring->write_idx, memory_order_acquire);
    uint32_t max_dist = 0;
    uint32_t min_ridx = w;
    bool     have_active = false;
    for (int i = 0; i < g_n_outputs; i++) {
        if (!g_outputs[i].active) continue;
        uint32_t dist = w - g_outputs[i].local_ridx;
        if (!have_active || dist > max_dist) {
            max_dist = dist;
            min_ridx = g_outputs[i].local_ridx;
            have_active = true;
        }
    }

    if (have_active) {
        atomic_store_explicit(&g_ring->read_idx, min_ridx, memory_order_release);
    } else {
        atomic_store_explicit(&g_ring->read_idx, w, memory_order_release);
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
 * Fuegt Output-Device hinzu (idempotent).
 * Rueckgabe: 0=OK, -1=Fehler.
 * MUSS unter g_outputs_lock aufgerufen werden.
 */
static int output_add_locked(const char *uid, uint32_t ch_offset)
{
    /* Idempotent: schon vorhanden? */
    if (find_output_slot_locked(uid, ch_offset) >= 0) {
        return 0;
    }

    if (g_n_outputs >= MAX_OUTPUTS) {
        fprintf(stderr, "Helper: MAX_OUTPUTS (%d) erreicht, kann '%s' nicht hinzufuegen\n",
                MAX_OUTPUTS, uid);
        return -1;
    }

    AudioDeviceID dev_id = find_device_by_uid(uid);
    if (dev_id == kAudioDeviceUnknown) {
        fprintf(stderr, "Helper: Device '%s' nicht gefunden\n", uid);
        return -1;
    }

    DeviceOutput *dev = &g_outputs[g_n_outputs];
    memset(dev, 0, sizeof(*dev));
    dev->dev_id    = dev_id;
    dev->ch_offset = ch_offset;
    strncpy(dev->uid, uid, sizeof(dev->uid) - 1);

    char *nm = device_get_name(dev_id);
    if (nm) {
        strncpy(dev->name, nm, sizeof(dev->name) - 1);
        free(nm);
    }

    /* Start-Position: aktueller write_idx — neue Outputs hoeren ab JETZT */
    if (g_ring) {
        dev->local_ridx = atomic_load_explicit(&g_ring->write_idx, memory_order_acquire);
    }
    atomic_store_explicit(&dev->underruns, 0u, memory_order_relaxed);

    /* Phase 6: Adaptive SRC initialisieren.
     * src_frac_ridx ist ein FRAME-Index (nicht Sample-Index):
     *   frame i → ring samples [i*2] (L) und [i*2+1] (R)
     * local_ridx ist ein Sample-Index → /2 fuer Konvertierung. */
    dev->src_frac_ridx   = (double)dev->local_ridx / 2.0;
    atomic_store_explicit(&dev->src_ratio_q20, 1u << 20, memory_order_relaxed);
    dev->src_ring_target = ARN_RING_CAPACITY / 2;  /* 50% Fuellstand als Ziel (in Samples) */

    OSStatus err = AudioDeviceCreateIOProcID(dev_id, device_ioproc, dev, &dev->proc_id);
    if (err != noErr) {
        fprintf(stderr, "Helper: AudioDeviceCreateIOProcID fuer '%s' fehlgeschlagen (err=%d)\n",
                uid, (int)err);
        return -1;
    }

    err = AudioDeviceStart(dev_id, dev->proc_id);
    if (err != noErr) {
        fprintf(stderr, "Helper: AudioDeviceStart fuer '%s' fehlgeschlagen (err=%d)\n",
                uid, (int)err);
        AudioDeviceDestroyIOProcID(dev_id, dev->proc_id);
        return -1;
    }

    dev->active = true;
    g_n_outputs++;

    fprintf(stdout, "Helper: Output hinzugefuegt: %s [Ch %u-%u] (UID: %s)\n",
            dev->name, ch_offset + 1, ch_offset + 2, uid);
    return 0;
}

/*
 * Entfernt Output-Device (uid + ch_offset).
 * MUSS unter g_outputs_lock aufgerufen werden.
 */
static void output_remove_locked(const char *uid, uint32_t ch_offset)
{
    int slot = find_output_slot_locked(uid, ch_offset);
    if (slot < 0) return;

    DeviceOutput *dev = &g_outputs[slot];

    if (dev->proc_id) {
        AudioDeviceStop(dev->dev_id, dev->proc_id);
        AudioDeviceDestroyIOProcID(dev->dev_id, dev->proc_id);
    }

    fprintf(stdout, "Helper: Output entfernt: %s [Ch %u-%u]\n",
            dev->name, ch_offset + 1, ch_offset + 2);

    /* Slot durch letzten ersetzen (kein Hole) */
    if (slot != g_n_outputs - 1) {
        g_outputs[slot] = g_outputs[g_n_outputs - 1];
    }
    memset(&g_outputs[g_n_outputs - 1], 0, sizeof(DeviceOutput));
    g_n_outputs--;
}

/*
 * Stoppt alle Outputs (z.B. beim Shutdown).
 */
static void outputs_stop_all(void)
{
    pthread_mutex_lock(&g_outputs_lock);
    while (g_n_outputs > 0) {
        DeviceOutput *dev = &g_outputs[g_n_outputs - 1];
        if (dev->proc_id) {
            AudioDeviceStop(dev->dev_id, dev->proc_id);
            AudioDeviceDestroyIOProcID(dev->dev_id, dev->proc_id);
        }
        memset(dev, 0, sizeof(DeviceOutput));
        g_n_outputs--;
    }
    pthread_mutex_unlock(&g_outputs_lock);
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

    pthread_mutex_lock(&g_outputs_lock);

    int i = 0;
    while (i < g_n_outputs) {
        AudioDeviceID found = find_device_by_uid(g_outputs[i].uid);
        if (found == kAudioDeviceUnknown) {
            /* Device verschwunden — stoppen und entfernen */
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
    return noErr;
}

static void hotplug_register(void)
{
    if (g_hotplug_registered) return;
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };
    OSStatus err = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &addr,
                                                   devices_changed_listener, NULL);
    if (err == noErr) {
        g_hotplug_registered = 1;
        fprintf(stdout, "Helper: Hot-Plug-Listener aktiv\n");
    } else {
        fprintf(stderr, "Helper: Hot-Plug-Listener konnte nicht registriert werden (err=%d)\n",
                (int)err);
    }
}

static void hotplug_unregister(void)
{
    if (!g_hotplug_registered) return;
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &addr,
                                       devices_changed_listener, NULL);
    g_hotplug_registered = 0;
}

/* ── Volume-Polling Thread (Phase 4) ────────────────────────────────────── */

static Float32 get_default_output_volume_c(void)
{
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID dev = kAudioDeviceUnknown;
    UInt32 sz = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &sz, &dev) != noErr
        || dev == kAudioDeviceUnknown) {
        return 1.0f;
    }

    /* VirtualMainVolume == 'vmvl' (modern), Fallback auf 'vmvl' (deprecated symbol).
     * Wir nutzen den Selector direkt um Macro-Inkompatibilitaeten zu vermeiden. */
    AudioObjectPropertyAddress vaddr = {
        .mSelector = 0x766D766Cu, /* 'vmvl' = kAudioHardwareServiceDeviceProperty_VirtualMainVolume */
        .mScope    = kAudioDevicePropertyScopeOutput,
        .mElement  = kAudioObjectPropertyElementMain
    };
    Float32 vol = 1.0f;
    sz = sizeof(vol);
    if (AudioObjectGetPropertyData(dev, &vaddr, 0, NULL, &sz, &vol) != noErr) {
        return 1.0f;
    }
    if (vol < 0.0f) vol = 0.0f;
    if (vol > 1.0f) vol = 1.0f;
    return vol;
}

static uint32_t get_default_output_muted_c(void)
{
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID dev = kAudioDeviceUnknown;
    UInt32 sz = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &sz, &dev) != noErr
        || dev == kAudioDeviceUnknown) {
        return 0u;
    }

    AudioObjectPropertyAddress maddr = {
        .mSelector = kAudioDevicePropertyMute,
        .mScope    = kAudioDevicePropertyScopeOutput,
        .mElement  = kAudioObjectPropertyElementMain
    };
    UInt32 muted = 0;
    sz = sizeof(muted);
    if (AudioObjectGetPropertyData(dev, &maddr, 0, NULL, &sz, &muted) != noErr) {
        return 0u;
    }
    return muted ? 1u : 0u;
}

static void *volume_poll_thread(void *arg)
{
    (void)arg;
    while (g_volume_running && g_running) {
        if (g_ring) {
            /* Robustheit: Driver wurde evtl. neu geladen — magic/version pruefen.
             * Bei Mismatch (z.B. coreaudiod restart): SHM neu verbinden. */
            if (g_ring->magic != ARN_RING_MAGIC || g_ring->version != ARN_RING_VERSION) {
                fprintf(stderr, "Helper: SHM-Header invalid — Driver wurde neu geladen, reconnect...\n");
                shm_disconnect();
                /* Reconnect — bis es klappt oder shutdown */
                while (g_running && g_volume_running) {
                    g_ring = shm_connect();
                    if (g_ring) break;
                    usleep(SHM_RETRY_INTERVAL_US);
                }
                /* Local-Read-Indices der Outputs auf aktuelles write_idx setzen */
                if (g_ring) {
                    uint32_t w = atomic_load_explicit(&g_ring->write_idx, memory_order_acquire);
                    pthread_mutex_lock(&g_outputs_lock);
                    for (int i = 0; i < g_n_outputs; i++) {
                        g_outputs[i].local_ridx    = w;
                        g_outputs[i].src_frac_ridx = (double)w / 2.0; /* Frame-Index! */
                    }
                    pthread_mutex_unlock(&g_outputs_lock);
                }
                continue;
            }

            Float32  vol   = get_default_output_volume_c();
            uint32_t muted = get_default_output_muted_c();

            uint32_t vol_q16 = (uint32_t)(vol * 65536.0f);
            if (vol_q16 > 65536u) vol_q16 = 65536u;

            atomic_store_explicit(&g_ring->volume_q16, vol_q16, memory_order_release);
            atomic_store_explicit(&g_ring->muted,      muted,   memory_order_release);

            /* ── Phase 6: Adaptive SRC-Ratio pro Output-Device aktualisieren ── */
            #define SRC_P_GAIN       0.01f    /* P-Verstaerkung — stabil bei +/-500ppm Headroom */
            #define SRC_MAX_PPM      500.0f   /* Maximale Korrektur +/-500ppm                   */
            #define SRC_RATIO_CLAMP  (SRC_MAX_PPM / 1000000.0f)

            pthread_mutex_lock(&g_outputs_lock);
            uint32_t w_now = atomic_load_explicit(&g_ring->write_idx, memory_order_acquire);

            for (int i = 0; i < g_n_outputs; i++) {
                DeviceOutput *dev = &g_outputs[i];
                if (!dev->active) continue;

                uint32_t fill_samples  = w_now - dev->local_ridx;
                uint32_t fill_frames   = fill_samples / 2u;   /* Stereo -> /2 */
                uint32_t target_frames = dev->src_ring_target / 2u;

                /* P-Regler: positiver Fehler = Ring laeuft voll -> schneller abspielen */
                float error_norm = (float)((int32_t)fill_frames - (int32_t)target_frames)
                                   / (float)(ARN_RING_CAPACITY / 2u);
                float correction = error_norm * SRC_P_GAIN;

                /* Clamp auf +/-500ppm */
                if (correction >  SRC_RATIO_CLAMP) correction =  SRC_RATIO_CLAMP;
                if (correction < -SRC_RATIO_CLAMP) correction = -SRC_RATIO_CLAMP;

                float ratio_f = 1.0f + correction;
                uint32_t ratio_q20 = (uint32_t)(ratio_f * (float)(1u << 20));

                atomic_store_explicit(&dev->src_ratio_q20, ratio_q20, memory_order_release);
            }
            pthread_mutex_unlock(&g_outputs_lock);

            /* Auch globalen read_idx aktualisieren — Producer kann sonst voll laufen. */
            update_global_read_idx();
        }
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
                off = (uint32_t)atoi(col2);
            }
        }
        out_offsets[n] = off;
        n++;

        if (!brace_close) break;
        p = brace_close + 1;
    }

    return n;
}

/* Schreibt eine vollstaendige Antwort (Newline-terminiert) auf fd. */
static void send_line(int fd, const char *s)
{
    size_t len = strlen(s);
    ssize_t w = write(fd, s, len);
    (void)w;
    if (len == 0 || s[len - 1] != '\n') {
        ssize_t w2 = write(fd, "\n", 1);
        (void)w2;
    }
}

/* Baut "active":[{...},{...}] JSON-Fragment in buf. */
static void format_active_outputs(char *buf, size_t bufsz)
{
    pthread_mutex_lock(&g_outputs_lock);
    size_t pos = 0;
    int written = snprintf(buf + pos, bufsz - pos, "[");
    if (written < 0) { pthread_mutex_unlock(&g_outputs_lock); return; }
    pos += (size_t)written;

    for (int i = 0; i < g_n_outputs && pos < bufsz; i++) {
        const char *sep = (i == 0) ? "" : ",";
        /* Name muss JSON-escapt sein — wir ersetzen " durch ' und steuern nichts weiteres. */
        char safe_name[256];
        size_t j = 0;
        for (size_t k = 0; g_outputs[i].name[k] && j < sizeof(safe_name) - 1; k++) {
            char c = g_outputs[i].name[k];
            if (c == '"' || c == '\\') c = '\'';
            if ((unsigned char)c < 0x20) c = ' ';
            safe_name[j++] = c;
        }
        safe_name[j] = '\0';

        /* Phase 6: src_ratio (Q20 -> float) und underruns mit ausgeben */
        uint32_t ratio_q20 = atomic_load_explicit(&g_outputs[i].src_ratio_q20,
                                                  memory_order_relaxed);
        double   src_ratio = (double)ratio_q20 / (double)(1u << 20);
        uint32_t underruns = atomic_load_explicit(&g_outputs[i].underruns,
                                                  memory_order_relaxed);

        written = snprintf(buf + pos, bufsz - pos,
                           "%s{\"uid\":\"%s\",\"name\":\"%s\",\"ch_offset\":%u,"
                           "\"src_ratio\":%.6f,\"underruns\":%u}",
                           sep, g_outputs[i].uid, safe_name, g_outputs[i].ch_offset,
                           src_ratio, underruns);
        if (written < 0) break;
        pos += (size_t)written;
    }
    if (pos < bufsz) {
        snprintf(buf + pos, bufsz - pos, "]");
    }
    pthread_mutex_unlock(&g_outputs_lock);
}

/*
 * parse_and_execute — verarbeitet eine JSON-Zeile, schreibt Antwort auf fd.
 * Rueckgabe: 0=continue, 1=shutdown angefordert.
 */
static int parse_and_execute(int fd, const char *line)
{
    char resp[8192];

    if (json_has_cmd(line, "ping")) {
        snprintf(resp, sizeof(resp), "{\"ok\":true,\"pong\":true}");
        send_line(fd, resp);
        return 0;
    }

    if (json_has_cmd(line, "shutdown")) {
        snprintf(resp, sizeof(resp), "{\"ok\":true,\"shutting_down\":true}");
        send_line(fd, resp);
        g_running = 0;
        return 1;
    }

    if (json_has_cmd(line, "get_status")) {
        char active_buf[4096];
        format_active_outputs(active_buf, sizeof(active_buf));
        uint32_t frames = g_ring ? arn_ring_frames_available(g_ring) : 0u;
        uint32_t calls  = atomic_load_explicit(&g_ioproc_calls, memory_order_relaxed);
        snprintf(resp, sizeof(resp),
                 "{\"ok\":true,\"active\":%s,\"ring_frames\":%u,\"ioproc_calls\":%u}",
                 active_buf, frames, calls);
        send_line(fd, resp);
        return 0;
    }

    if (json_has_cmd(line, "set_outputs")) {
        char     new_uids[MAX_OUTPUTS][512];
        uint32_t new_offs[MAX_OUTPUTS];
        memset(new_uids, 0, sizeof(new_uids));
        memset(new_offs, 0, sizeof(new_offs));
        int n_new = parse_outputs(line, new_uids, new_offs);

        pthread_mutex_lock(&g_outputs_lock);

        /* 1) Entferne alle aktuellen Outputs, die NICHT in der neuen Liste sind */
        int i = 0;
        while (i < g_n_outputs) {
            bool keep = false;
            for (int k = 0; k < n_new; k++) {
                if (strcmp(g_outputs[i].uid, new_uids[k]) == 0 &&
                    g_outputs[i].ch_offset == new_offs[k]) {
                    keep = true;
                    break;
                }
            }
            if (!keep) {
                output_remove_locked(g_outputs[i].uid, g_outputs[i].ch_offset);
                /* nicht inkrementieren */
            } else {
                i++;
            }
        }

        /* 2) Fuege neue Outputs hinzu (idempotent) */
        int failures = 0;
        for (int k = 0; k < n_new; k++) {
            if (output_add_locked(new_uids[k], new_offs[k]) != 0) {
                failures++;
            }
        }

        char active_buf[4096];
        pthread_mutex_unlock(&g_outputs_lock);
        format_active_outputs(active_buf, sizeof(active_buf));

        if (failures == 0) {
            snprintf(resp, sizeof(resp),
                     "{\"ok\":true,\"active\":%s}", active_buf);
        } else {
            snprintf(resp, sizeof(resp),
                     "{\"ok\":false,\"error\":\"%d output(s) failed\",\"active\":%s}",
                     failures, active_buf);
        }
        send_line(fd, resp);
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

    while (g_config_running && g_running) {
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
    strncpy(addr.sun_path, CONFIG_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    unlink(CONFIG_SOCKET_PATH);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "Helper: bind('%s') fehlgeschlagen (errno=%d)\n",
                CONFIG_SOCKET_PATH, errno);
        close(fd);
        return -1;
    }

    if (chmod(CONFIG_SOCKET_PATH, 0666) != 0) {
        /* nicht fatal */
    }

    if (listen(fd, 4) < 0) {
        fprintf(stderr, "Helper: listen() fehlgeschlagen (errno=%d)\n", errno);
        close(fd);
        unlink(CONFIG_SOCKET_PATH);
        return -1;
    }

    /* Non-blocking, damit der Accept-Loop g_running pollen kann */
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    fprintf(stdout, "Helper: Config-Socket lauscht auf %s\n", CONFIG_SOCKET_PATH);
    return fd;
}

static void *config_thread_main(void *arg)
{
    (void)arg;
    while (g_config_running && g_running) {
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

/* ── RT-Thread-Prioritaet setzen ────────────────────────────────────────── */

static void set_rt_priority(void)
{
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    double nanos_per_tick = (double)tb.numer / (double)tb.denom;

    uint32_t period_ticks  = (uint32_t)(10000000.0 / nanos_per_tick);
    uint32_t compute_ticks = (uint32_t)(2000000.0  / nanos_per_tick);

    thread_time_constraint_policy_data_t policy = {
        .period      = period_ticks,
        .computation = compute_ticks,
        .constraint  = period_ticks,
        .preemptible = 1
    };

    thread_policy_set(mach_thread_self(),
                      THREAD_TIME_CONSTRAINT_POLICY,
                      (thread_policy_t)&policy,
                      THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

/* ── Main ───────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    signal(SIGINT,  handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGPIPE, SIG_IGN);

    fprintf(stdout, "AudioRouterNow Helper v2.0 (Phase 5)\n");
    fprintf(stdout, "SHM: %s  Ring: %u Frames ~ %.0f ms @48kHz\n",
            ARN_SHM_NAME,
            ARN_RING_CAPACITY / 2u,
            (ARN_RING_CAPACITY / 2.0) / 48000.0 * 1000.0);

    /* 1. SHM-Ring verbinden (Retry bis Plugin bereit ist) */
    fprintf(stdout, "Warte auf SHM-Ring vom Plugin...\n");
    while (g_running && g_ring == NULL) {
        g_ring = shm_connect();
        if (g_ring == NULL) {
            usleep(SHM_RETRY_INTERVAL_US);
        }
    }
    if (!g_running) return 0;

    /* 2. Hot-Plug-Listener registrieren */
    hotplug_register();

    /* 3. Outputs hinzufuegen — entweder aus CLI-Args oder Auto-Default */
    pthread_mutex_lock(&g_outputs_lock);
    if (argc >= 2) {
        for (int a = 1; a < argc && g_n_outputs < MAX_OUTPUTS; a++) {
            output_add_locked(argv[a], 0);
        }
    } else {
        AudioDeviceID auto_dev = find_default_output_device();
        if (auto_dev != kAudioDeviceUnknown) {
            char *uid = device_get_uid(auto_dev);
            if (uid) {
                output_add_locked(uid, 0);
                free(uid);
            }
        }
    }
    int n_initial = g_n_outputs;
    pthread_mutex_unlock(&g_outputs_lock);

    if (n_initial == 0) {
        fprintf(stderr, "Helper: Kein initiales Output-Device — warte auf Config-Socket\n");
    }

    /* 4. Config-Socket starten */
    g_config_listen_fd = config_socket_create();
    if (g_config_listen_fd >= 0) {
        g_config_running = 1;
        if (pthread_create(&g_config_thread, NULL, config_thread_main, NULL) != 0) {
            fprintf(stderr, "Helper: Config-Thread konnte nicht gestartet werden\n");
            g_config_running = 0;
            close(g_config_listen_fd);
            unlink(CONFIG_SOCKET_PATH);
            g_config_listen_fd = -1;
        }
    }

    /* 5. Volume-Polling Thread starten */
    g_volume_running = 1;
    if (pthread_create(&g_volume_thread, NULL, volume_poll_thread, NULL) != 0) {
        fprintf(stderr, "Helper: Volume-Thread konnte nicht gestartet werden\n");
        g_volume_running = 0;
    }

    /* RT-Priorität für den main-Thread (kosmetisch — IOProcs sind eh RT) */
    set_rt_priority();

    fprintf(stdout, "Helper laeuft — Routing aktiv. Ctrl+C zum Beenden.\n");
    fflush(stdout);

    /* 6. Hauptschleife: Diagnostics alle 2s */
    int tick = 0;
    uint32_t prev_calls = 0;
    while (g_running) {
        usleep(200000); /* 200ms */
        tick++;
        if (tick % 10 == 0) {
            uint32_t frames = g_ring ? arn_ring_frames_available(g_ring) : 0u;
            uint32_t calls  = atomic_load_explicit(&g_ioproc_calls, memory_order_relaxed);
            uint32_t delta  = calls - prev_calls;
            prev_calls = calls;
            pthread_mutex_lock(&g_outputs_lock);
            int n = g_n_outputs;
            pthread_mutex_unlock(&g_outputs_lock);
            fprintf(stdout, "\rRing: %4u Frames | Outputs: %d | IOProc-Calls: +%u/2s (%u total)      ",
                    frames, n, delta, calls);
            fflush(stdout);
        }
    }

    /* 7. Cleanup */
    fprintf(stdout, "\nHelper: wird beendet...\n");

    g_config_running = 0;
    g_volume_running = 0;

    if (g_volume_thread) {
        pthread_join(g_volume_thread, NULL);
    }
    if (g_config_listen_fd >= 0) {
        close(g_config_listen_fd);
        g_config_listen_fd = -1;
        pthread_join(g_config_thread, NULL);
        unlink(CONFIG_SOCKET_PATH);
    }

    hotplug_unregister();
    outputs_stop_all();
    shm_disconnect();

    fprintf(stdout, "Helper: beendet.\n");
    return 0;
}
