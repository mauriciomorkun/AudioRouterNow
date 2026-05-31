/*
 * shared_ring.h — Lock-free SPSC Ring-Buffer fuer AudioRouterNow v2.0
 *
 * Producer : AudioRouterNow.driver  (coreaudiod, RT-Thread)
 * Consumer : AudioRouterNowHelper   (User-Prozess, CoreAudio IOProc RT-Thread)
 *
 * POSIX Shared Memory:  shm_open(ARN_SHM_NAME, ...)  → mmap()
 * Synchronisation:      Monoton steigende atomic uint32 write_idx / read_idx.
 *                       Producer: store release.  Consumer: load acquire.
 *                       KEIN Mutex, KEIN Syscall im Hot-Path → RT-safe.
 *
 * Layout-Versioning:    magic + version im Header.  Helper prueft beim
 *                       Attach — weicht die Version ab, wartet er auf ein
 *                       neues Segment (Plugin-Reload).
 *
 * Version 3:
 *   - sample_rate ist jetzt _Atomic uint32_t (schreibbar zur Laufzeit)
 *   - sr_change_gen: atomarer Generationszaehler — wird vom Driver inkrementiert
 *     wenn die Sample-Rate geaendert wird. Helper erkennt aendert SR-Wechsel
 *     ohne Polling der sample_rate selbst.
 */

#pragma once

#include <stdatomic.h>
#include <stdint.h>
#include <string.h>   /* memset */

/* ── Identitaet ─────────────────────────────────────────────────────────── */
#define ARN_RING_MAGIC    0x41524E52u   /* 'A','R','N','R' */
#define ARN_RING_VERSION  4u            /* v4: instance_id Feld in Header   */
#define ARN_SHM_NAME      "/audiorouter_shm"

/* ── Kapazitaet ─────────────────────────────────────────────────────────── */
/*
 * 16384 Samples = 8192 Stereo-Frames = ~170 ms @48 kHz.
 * MUSS Zweierpotenz sein (Masking statt Modulo im Hot-Path).
 */
#define ARN_RING_CAPACITY  16384u
#define ARN_RING_MASK      (ARN_RING_CAPACITY - 1u)

/* ── Header-Layout ──────────────────────────────────────────────────────── */
/*
 * Jede Gruppe liegt auf einer eigenen Cache-Line (64 Bytes), um
 * False-Sharing zwischen Producer- und Consumer-Core zu vermeiden.
 *
 *  Offset   0: Read-Only-Header   (magic, version, format-Info)
 *  Offset  64: Producer-Hot       (write_idx)
 *  Offset 128: Consumer-Hot       (read_idx)
 *  Offset 192: Shared-Control     (volume, muted)
 *  Offset 256: Sample-Buffer      (ARN_RING_CAPACITY × float32)
 */
typedef struct {
    /* --- 0..63: Read-Only nach Initialize (ausser sample_rate + sr_change_gen) --- */
    uint32_t         magic;           /* ARN_RING_MAGIC                         */
    uint32_t         version;         /* ARN_RING_VERSION                       */
    _Atomic uint32_t sample_rate;     /* dynamisch: 44100/48000/88200/96000/... */
    uint32_t         channels;        /* 2 (Stereo)                             */
    uint32_t         capacity;        /* ARN_RING_CAPACITY                      */
    _Atomic uint32_t sr_change_gen;   /* Generationszaehler — inkrementiert bei SR-Wechsel */
    /* K3: Eindeutige Instanz-ID — gesetzt vom Helper bei jeder SHM-Erstellung.
     * Wert: mach_absolute_time() XOR (uint64_t)getpid(). Nie 0.
     * Driver-Watch-Thread vergleicht dieses Feld statt Inodes (Inodes werden
     * von macOS recycelt und sind kein zuverlaessiges Erkennungsmerkmal). */
    _Atomic uint64_t instance_id;     /* 0 = noch nicht initialisiert           */
    uint8_t          _pad0[32];       /* auf 64 Bytes auffuellen                */

    /* --- 64..127: Producer-Hot (nur vom RT-Write-Thread gelesen/geschrieben) --- */
    _Atomic uint32_t write_idx;   /* monoton steigend, uint32 Overflow OK */
    uint8_t          _pad1[60];

    /* --- 128..191: Consumer-Hot (nur vom IOProc gelesen/geschrieben) --- */
    _Atomic uint32_t read_idx;
    uint8_t          _pad2[60];

    /* --- 192..255: Shared-Control (schreibt Python/Helper, liest IOProc) --- */
    _Atomic uint32_t volume_q16; /* Q16: 65536 = 1.0, 0 = Stille          */
    _Atomic uint32_t muted;      /* 0 = aktiv, 1 = muted                  */
    uint8_t          _pad3[56];

    /* --- 256+: Sample-Daten --- */
    float samples[ARN_RING_CAPACITY]; /* interleaved Float32: L,R,L,R,...  */
} ARNSharedRing;

/* Gesamtgroesse des SHM-Segments */
#define ARN_SHM_SIZE  sizeof(ARNSharedRing)

/* ── Initialisierung (aufgerufen vom Plugin nach shm_open + mmap) ────────── */

static inline void
arn_ring_init(ARNSharedRing *ring)
{
    memset(ring, 0, ARN_SHM_SIZE);
    atomic_store_explicit(&ring->write_idx,    0u,     memory_order_relaxed);
    atomic_store_explicit(&ring->read_idx,     0u,     memory_order_relaxed);
    atomic_store_explicit(&ring->volume_q16,  65536u,  memory_order_relaxed);
    atomic_store_explicit(&ring->muted,        0u,     memory_order_relaxed);
    atomic_store_explicit(&ring->sr_change_gen, 0u,    memory_order_relaxed);
    atomic_store_explicit(&ring->instance_id,   0u,    memory_order_relaxed); /* Helper setzt echten Wert nach init */
    ring->magic    = ARN_RING_MAGIC;
    ring->channels = 2u;
    ring->capacity = ARN_RING_CAPACITY;
    atomic_store_explicit(&ring->sample_rate, 48000u,  memory_order_relaxed);
    /* version zuletzt schreiben — Consumer prueft magic+version als Bereit-Signal */
    atomic_thread_fence(memory_order_release);
    ring->version = ARN_RING_VERSION;
}

/* Aendert SR zur Laufzeit: flusht Ring, inkrementiert sr_change_gen */
static inline void
arn_ring_set_sample_rate(ARNSharedRing *ring, uint32_t new_sr) {
    /* GUARD: NO-OP wenn SR bereits uebereinstimmt — verhindert spurious sr_change_gen-Inkremente */
    uint32_t old_sr = atomic_load_explicit(&ring->sample_rate, memory_order_acquire);
    if (old_sr == new_sr) return;
    atomic_store_explicit(&ring->write_idx, 0u, memory_order_seq_cst);
    /* H5: read_idx muss ebenfalls auf 0 gesetzt werden — sonst ist
     * write_idx = 0 < read_idx (alter Wert) → unsigned underflow →
     * space = riesige Zahl → Producer kann nicht schreiben (Ring scheinbar voll). */
    atomic_store_explicit(&ring->read_idx,  0u, memory_order_seq_cst);
    atomic_store_explicit(&ring->sample_rate, new_sr, memory_order_release);
    atomic_fetch_add_explicit(&ring->sr_change_gen, 1u, memory_order_release);
}

/* ── Producer-Seite (RT-safe: kein Lock, kein malloc, kein Syscall) ─────── */

/*
 * arn_ring_write — schreibt `count` interleaved Float32-Samples in den Ring.
 *
 * Gibt geschriebene Sample-Anzahl zurueck.
 * Bei vollem Ring (Overflow): Frame verwerfen, 0 zurueckgeben.
 * Nie blockierend.
 */
static inline uint32_t
arn_ring_write(ARNSharedRing *ring, const float *samples, uint32_t count)
{
    uint32_t widx  = atomic_load_explicit(&ring->write_idx, memory_order_relaxed);
    uint32_t ridx  = atomic_load_explicit(&ring->read_idx,  memory_order_acquire);
    uint32_t space = ring->capacity - (widx - ridx);   /* unsigned sub = korrekt */

    if (space < count) {
        return 0u;  /* Ring voll — Frame verwerfen */
    }

    for (uint32_t i = 0; i < count; i++) {
        ring->samples[widx & ARN_RING_MASK] = samples[i];
        widx++;
    }

    atomic_store_explicit(&ring->write_idx, widx, memory_order_release);
    return count;
}

/* ── Consumer-Seite (RT-safe: kein Lock, kein malloc, kein Syscall) ─────── */

/*
 * arn_ring_read — liest `count` interleaved Float32-Samples aus dem Ring.
 *
 * Gibt gelesene Sample-Anzahl zurueck.
 * Bei leerem Ring (Underrun): schreibt Stille, gibt 0 zurueck.
 * Nie blockierend.
 */
static inline uint32_t
arn_ring_read(ARNSharedRing *ring, float *out, uint32_t count)
{
    uint32_t ridx  = atomic_load_explicit(&ring->read_idx,  memory_order_relaxed);
    uint32_t widx  = atomic_load_explicit(&ring->write_idx, memory_order_acquire);
    uint32_t avail = widx - ridx;   /* unsigned sub = korrekt */

    if (avail < count) {
        memset(out, 0, count * sizeof(float));
        return 0u;  /* Underrun — Stille */
    }

    for (uint32_t i = 0; i < count; i++) {
        out[i] = ring->samples[ridx & ARN_RING_MASK];
        ridx++;
    }

    atomic_store_explicit(&ring->read_idx, ridx, memory_order_release);
    return count;
}

/* ── Hilfsfunktion: Fuellstand in Frames (Consumer-Diagnose) ────────────── */

static inline uint32_t
arn_ring_frames_available(const ARNSharedRing *ring)
{
    if (ring->channels == 0) return 0u;
    uint32_t w = atomic_load_explicit(&ring->write_idx, memory_order_acquire);
    uint32_t r = atomic_load_explicit(&ring->read_idx,  memory_order_relaxed);
    return (w - r) / ring->channels;
}
