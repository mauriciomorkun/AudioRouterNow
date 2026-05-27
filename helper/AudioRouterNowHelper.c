/*
 * AudioRouterNowHelper.c — Phase 0 Spike
 *
 * Liest Audio-Frames aus dem POSIX-SHM-Ring (geschrieben vom HAL-Plugin)
 * und gibt sie via CoreAudio AudioDeviceIOProc an ein physisches Output-Device aus.
 *
 * Phase 0: Ein einziges Output-Device (UID via Argument oder Default).
 *          Kein Config-Socket, kein launchd — manuell im Terminal starten.
 *
 * Aufruf:
 *   AudioRouterNowHelper                    # Default-Output (kein Audio Router)
 *   AudioRouterNowHelper <device-uid>       # Bestimmtes Device per UID
 *
 * Build:
 *   cd helper && make
 *
 * Voraussetzung:
 *   AudioRouterNow.driver muss installiert und geladen sein (SHM-Produzent).
 *
 * (c) 2026 AudioRouterNow
 */

#include "shared_ring.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_act.h>
#include <mach/thread_policy.h>

#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

/* ── Konfiguration ──────────────────────────────────────────────────────── */

#define OUR_DEVICE_UID     "com.audiorouter.now.device"   /* virtuelles Device ausschliessen */
#define SHM_RETRY_INTERVAL 500000   /* 500ms zwischen shm_open-Versuchen */

/* ── Globaler Zustand ───────────────────────────────────────────────────── */

static volatile int          g_running     = 1;
static ARNSharedRing        *g_ring        = NULL;
static int                   g_shm_fd      = -1;
static AudioDeviceID         g_device_id   = kAudioDeviceUnknown;
static AudioDeviceIOProcID   g_ioproc_id   = NULL;

/* Pre-allokierter Temp-Buffer fuer De-Interleaving im IOProc (RT-safe). */
static float g_temp_buf[ARN_RING_CAPACITY];

/* Diagnostic: wie oft wurde der IOProc aufgerufen? */
static _Atomic uint32_t g_ioproc_calls = 0;

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

/* ── CoreAudio Device-Suche ─────────────────────────────────────────────── */

/*
 * Gibt den UID-String eines AudioDeviceID als allokierten C-String zurueck.
 * Caller muss free() aufrufen.
 */
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

    char *buf = malloc(256);
    if (buf) {
        CFStringGetCString(uid_ref, buf, 256, kCFStringEncodingUTF8);
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

    char *buf = malloc(256);
    if (buf) {
        CFStringGetCString(name_ref, buf, 256, kCFStringEncodingUTF8);
    }
    CFRelease(name_ref);
    return buf;
}

static Float64 device_sample_rate(AudioDeviceID dev_id)
{
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyNominalSampleRate,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };
    Float64 rate = 0.0;
    UInt32 size = sizeof(rate);
    AudioObjectGetPropertyData(dev_id, &addr, 0, NULL, &size, &rate);
    return rate;
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
 * Sucht ein physisches Output-Device:
 * - Falls uid_hint gesetzt: Device mit dieser UID
 * - Sonst: erstes Device mit >=2 Output-Kanälen das NICHT unser virtuelles ist
 */
static AudioDeviceID find_output_device(const char *uid_hint)
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
        char *uid  = device_get_uid(devices[i]);
        char *name = device_get_name(devices[i]);
        UInt32 out_ch = device_output_channels(devices[i]);

        if (uid_hint) {
            /* Exakte UID-Suche */
            if (uid && strcmp(uid, uid_hint) == 0 && out_ch >= 2) {
                fprintf(stdout, "Helper: Device gefunden via UID: %s (%s)\n", name, uid);
                result = devices[i];
                free(uid); free(name);
                break;
            }
        } else {
            /* Automatik: bevorzuge physisches 48kHz-Output-Device, kein Audio Router.
             * Ersten Kandidaten merken (Fallback), 48kHz-Match sofort nehmen. */
            if (out_ch >= 2 && uid && strcmp(uid, OUR_DEVICE_UID) != 0) {
                Float64 rate = device_sample_rate(devices[i]);
                if (result == kAudioDeviceUnknown) {
                    /* Erster Kandidat als Fallback sichern */
                    result = devices[i];
                }
                if ((UInt32)rate == 48000u) {
                    /* 48kHz-Match gefunden — nehmen und abbrechen */
                    fprintf(stdout, "Helper: Auto-Device gewaehlt: %s (%.0f Hz, %u ch, UID: %s)\n",
                            name, rate, out_ch, uid);
                    result = devices[i];
                    free(uid); free(name);
                    break;
                }
            }
        }

        free(uid);
        free(name);
    }

    free(devices);
    return result;
}

/* ── CoreAudio IOProc ───────────────────────────────────────────────────── */

/*
 * ioproc — CoreAudio ruft diese Funktion auf dem RT-Thread auf.
 *
 * Liest Frames aus dem SHM-Ring und kopiert sie in den Output-Buffer.
 * Unterstuetzt sowohl interleaved (1 Buffer, 2ch) als auch non-interleaved
 * (2 Buffer je 1ch) Layout — CoreAudio-Hardware nutzt meist non-interleaved.
 */
static OSStatus ioproc(AudioDeviceID           inDevice,
                        const AudioTimeStamp   *inNow,
                        const AudioBufferList  *inInputData,
                        const AudioTimeStamp   *inInputTime,
                        AudioBufferList        *outOutputData,
                        const AudioTimeStamp   *inOutputTime,
                        void                   *inClientData)
{
    (void)inDevice; (void)inNow;
    (void)inInputData; (void)inInputTime; (void)inOutputTime;

    /* Diagnostic: IOProc-Aufruf zaehlen */
    atomic_fetch_add_explicit(&g_ioproc_calls, 1u, memory_order_relaxed);

    ARNSharedRing *ring = (ARNSharedRing *)inClientData;
    if (!ring || !outOutputData) return noErr;

    /* Volume + Mute aus Shared-Control lesen (atomic, low-cost) */
    uint32_t vol_q16 = atomic_load_explicit(&ring->volume_q16, memory_order_relaxed);
    uint32_t muted   = atomic_load_explicit(&ring->muted,      memory_order_relaxed);

    UInt32 nBufs = outOutputData->mNumberBuffers;

    if (nBufs >= 2) {
        /*
         * Non-interleaved Layout: je ein Buffer pro Kanal.
         * Komplete Audio 6 MK2 hat 6 Kanaele → nBufs = 6.
         * Stereo-Signal auf ALLE Buffer-Paare schreiben (L=even, R=odd),
         * damit Main-Out (Ch1-2), Headphone (Ch3-4) etc. alle Ton bekommen.
         */
        UInt32 nFrames = outOutputData->mBuffers[0].mDataByteSize / sizeof(float);
        uint32_t nSamples = nFrames * 2u;

        if (muted || vol_q16 == 0) {
            for (UInt32 b = 0; b < nBufs; b++) {
                memset(outOutputData->mBuffers[b].mData, 0,
                       outOutputData->mBuffers[b].mDataByteSize);
            }
            arn_ring_read(ring, g_temp_buf, nSamples);
            return noErr;
        }

        uint32_t got = arn_ring_read(ring, g_temp_buf, nSamples);

        if (got == 0) {
            /* Underrun — alle Kanaele stumm */
            for (UInt32 b = 0; b < nBufs; b++) {
                memset(outOutputData->mBuffers[b].mData, 0,
                       outOutputData->mBuffers[b].mDataByteSize);
            }
            return noErr;
        }

        float scale = (vol_q16 >= 65536u) ? 1.0f : (float)vol_q16 / 65536.0f;

        /* Alle Kanaele mit dem Stereo-Signal befuellen:
         * gerade Buffer-Indices → L-Kanal, ungerade → R-Kanal */
        for (UInt32 b = 0; b < nBufs; b++) {
            float *ch = (float *)outOutputData->mBuffers[b].mData;
            UInt32 src_ch = b % 2;  /* 0=L, 1=R */
            for (UInt32 f = 0; f < nFrames; f++) {
                ch[f] = g_temp_buf[f * 2 + src_ch] * scale;
            }
        }
    } else if (nBufs == 1) {
        /* Interleaved Layout */
        UInt32 nCh     = outOutputData->mBuffers[0].mNumberChannels;
        UInt32 nFrames = outOutputData->mBuffers[0].mDataByteSize / sizeof(float) / nCh;
        float *out     = (float *)outOutputData->mBuffers[0].mData;
        uint32_t nSamples = nFrames * 2u;

        if (muted || vol_q16 == 0) {
            memset(out, 0, outOutputData->mBuffers[0].mDataByteSize);
            arn_ring_read(ring, g_temp_buf, nSamples);
            return noErr;
        }

        if (nCh == 2) {
            uint32_t got = arn_ring_read(ring, out, nSamples);
            if (got == 0) {
                memset(out, 0, outOutputData->mBuffers[0].mDataByteSize);
                return noErr;
            }
            if (vol_q16 < 65536u) {
                float scale = (float)vol_q16 / 65536.0f;
                for (uint32_t i = 0; i < nSamples; i++) out[i] *= scale;
            }
        } else {
            /* Mehr oder weniger als 2 Kanaele — ignorieren, Stille */
            memset(out, 0, outOutputData->mBuffers[0].mDataByteSize);
        }
    }

    return noErr;
}

/* ── RT-Thread-Prioritaet setzen ────────────────────────────────────────── */

/*
 * Setzt THREAD_TIME_CONSTRAINT_POLICY fuer den aktuellen Thread.
 * Wird vom CoreAudio IOProc-Thread NICHT benoetigt (CoreAudio setzt das selbst).
 * Hier nur fuer den Fall dass wir spaeter einen eigenen Ring-Poll-Thread einfuehren.
 */
static void set_rt_priority(void)
{
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    double nanos_per_tick = (double)tb.numer / (double)tb.denom;

    /* Ziel: 10ms Periode (512 Frames @ 48kHz), 2ms Compute-Buget */
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

    const char *uid_hint = (argc >= 2) ? argv[1] : NULL;

    fprintf(stdout, "AudioRouterNow Helper v2.0 (Phase 0 Spike)\n");
    fprintf(stdout, "SHM: %s  Ring: %u Frames ≈ %.0f ms @48kHz\n",
            ARN_SHM_NAME,
            ARN_RING_CAPACITY / 2u,
            (ARN_RING_CAPACITY / 2.0) / 48000.0 * 1000.0);

    /* 1. SHM-Ring verbinden (Retry bis Plugin bereit ist) */
    fprintf(stdout, "Warte auf SHM-Ring vom Plugin...\n");
    while (g_running && g_ring == NULL) {
        g_ring = shm_connect();
        if (g_ring == NULL) {
            usleep(SHM_RETRY_INTERVAL);
        }
    }
    if (!g_running) return 0;

    /* 2. Output-Device finden */
    g_device_id = find_output_device(uid_hint);
    if (g_device_id == kAudioDeviceUnknown) {
        fprintf(stderr, "Helper: Kein passendes Output-Device gefunden!\n");
        fprintf(stderr, "Tipp: AudioRouterNowHelper <device-uid>\n");
        shm_disconnect();
        return 1;
    }

    /* 3. IOProc registrieren und Device starten */
    OSStatus err = AudioDeviceCreateIOProcID(g_device_id, ioproc, g_ring, &g_ioproc_id);
    if (err != noErr) {
        fprintf(stderr, "Helper: AudioDeviceCreateIOProcID fehlgeschlagen (err=%d)\n", err);
        shm_disconnect();
        return 1;
    }

    err = AudioDeviceStart(g_device_id, g_ioproc_id);
    if (err != noErr) {
        fprintf(stderr, "Helper: AudioDeviceStart fehlgeschlagen (err=%d)\n", err);
        AudioDeviceDestroyIOProcID(g_device_id, g_ioproc_id);
        shm_disconnect();
        return 1;
    }

    /* RT-Priorität für den main-Thread setzen (IOProc läuft auf CoreAudio-Thread,
     * aber main-Thread-Priorität hilft bei Scheduling-Entscheidungen) */
    set_rt_priority();

    fprintf(stdout, "Helper laeuft — Routing aktiv. Ctrl+C zum Beenden.\n");
    fprintf(stdout, "Ring-Fuellstand (Frames): ");
    fflush(stdout);

    /* 4. Hauptschleife: Diagnostics alle 2s ausgeben */
    int tick = 0;
    uint32_t prev_calls = 0;
    while (g_running) {
        usleep(200000); /* 200ms */
        tick++;
        if (tick % 10 == 0) {
            uint32_t frames = arn_ring_frames_available(g_ring);
            uint32_t calls  = atomic_load_explicit(&g_ioproc_calls, memory_order_relaxed);
            uint32_t delta  = calls - prev_calls;
            prev_calls = calls;
            fprintf(stdout, "\rRing: %4u Frames | IOProc-Calls: %u total, +%u/2s   ",
                    frames, calls, delta);
            fflush(stdout);
        }
    }

    /* 5. Cleanup */
    fprintf(stdout, "\nHelper: wird beendet...\n");
    AudioDeviceStop(g_device_id, g_ioproc_id);
    AudioDeviceDestroyIOProcID(g_device_id, g_ioproc_id);
    shm_disconnect();

    fprintf(stdout, "Helper: beendet.\n");
    return 0;
}
