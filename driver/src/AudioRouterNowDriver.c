/*
 * AudioRouterNowDriver.c
 *
 * AudioRouterNow — virtuelles Audio-Output-Device fuer macOS.
 * Implementiert ein Apple AudioServerPlugin (HAL Plugin), das in
 * /Library/Audio/Plug-Ins/HAL/ installiert und von coreaudiod geladen wird.
 *
 * Funktion:
 *   - Registriert ein Stereo-Output-Device "Audio Router" in Core Audio.
 *   - Im Output-IO-Callback (WriteMix) werden die PCM Float32 Samples
 *     non-blocking ueber einen Unix Domain Socket (/tmp/audiorouter.sock)
 *     an die Python Routing Engine weitergeleitet.
 *
 * Architektur-Hinweise:
 *   - Reines C: AudioServerPlugin ist eine C-COM-API. Kein Swift noetig.
 *   - coreaudiod laedt das Plugin als root, ohne UI/Terminal.
 *   - Logging ausschliesslich ueber os_log.
 *   - IO-Callbacks laufen auf Realtime-Threads: kein malloc, kein blocking IO.
 *   - Der Socket-Send nutzt MSG_DONTWAIT; ein separater Hilfsthread
 *     uebernimmt das (blockierende) connect/reconnect.
 *
 * (c) 2026 AudioRouterNow — proprietaer.
 */

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>      /* kAudioDevicePropertyBufferFrameSize u.a. */
#include <CoreFoundation/CoreFoundation.h>

#include <fcntl.h>
#include <sys/mman.h>   /* shm_open, mmap, munmap, shm_unlink */
#include <sys/stat.h>   /* fchmod */

#include "../../helper/shared_ring.h"

#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>

#include <errno.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include <unistd.h>

#pragma mark - Konstanten & Konfiguration

/* Identitaet des Devices ------------------------------------------------- */
#define kPlugIn_BundleID            "com.audiorouter.now.driver"
#define kDevice_Name                "Audio Router"
#define kDevice_Manufacturer        "AudioRouterNow"
#define kDevice_UID                 "com.audiorouter.now.device"
#define kDevice_ModelUID            "com.audiorouter.now.device.model"
#define kBox_Name                   "Audio Router Box"
#define kBox_UID                    "com.audiorouter.now.box"

/* Audio-Format ----------------------------------------------------------- */
#define kChannelsPerFrame           2u            /* Stereo                 */
#define kBitsPerChannel             32u           /* Float32                */
#define kBytesPerFrame              (kChannelsPerFrame * (kBitsPerChannel / 8))
#define kDefaultSampleRate          48000.0
#define kRingBufferFrames           512u          /* Buffer-Frame-Size      */

/* Alle unterstuetzten Sample-Raten */
static const Float64 kSupportedSampleRates[] = {
    44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0
};
#define kNumSupportedSampleRates (sizeof(kSupportedSampleRates) / sizeof(kSupportedSampleRates[0]))

/* IPC (v2.0: POSIX Shared Memory, kein Unix Socket mehr) ----------------- */
/* ARN_SHM_NAME ist in shared_ring.h definiert: "/audiorouter_shm"         */

/* Objekt-IDs des statischen Objektmodells -------------------------------- */
enum {
    kObjectID_PlugIn            = kAudioObjectPlugInObject,  /* == 1        */
    kObjectID_Box               = 2,
    kObjectID_Device            = 3,
    kObjectID_Stream_Output     = 4,
    kObjectID_Volume_Output     = 5,
    kObjectID_Mute_Output       = 6
};

/* Zeitmodell ------------------------------------------------------------- */
#define kZeroTimeStampPeriod        (kRingBufferFrames * 64u)  /* Frames    */

/* P14: Gemeldete Latenz. Der Helper haelt einen Pre-Roll-Puffer im SHM-Ring
 * vor, bevor er an die physischen Outputs ausgibt. Wir melden ein Viertel der
 * Ring-Kapazitaet als Geraete-Latenz, damit der HAL/Clients den realen
 * Pre-Roll-Versatz beruecksichtigen koennen (statt faelschlich 0). */
#define kReportedLatencyFrames      (ARN_RING_CAPACITY / 4u)   /* Frames    */

static bool ARN_IsValidSampleRate(Float64 sr) {
    for (size_t i = 0; i < kNumSupportedSampleRates; i++) {
        if (kSupportedSampleRates[i] == sr) return true;
    }
    return false;
}

#pragma mark - Globaler Zustand

static os_log_t                         gLog;

/* COM-Plumbing ----------------------------------------------------------- */
static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverInterface *gAudioServerPlugInDriverInterfacePtr =
                                        &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef       gAudioServerPlugInDriverRef =
                                        &gAudioServerPlugInDriverInterfacePtr;
static UInt32                           gPlugInRefCount = 1;

/* Host-Schnittstelle (vom HAL bei Initialize uebergeben) ----------------- */
static AudioServerPlugInHostRef         gPlugInHost = NULL;

/* Geschuetzter Zustand: ein einziger Mutex fuer die nicht-RT-Pfade -------- */
static pthread_mutex_t                  gStateMutex = PTHREAD_MUTEX_INITIALIZER;

/* Device-Zustand --------------------------------------------------------- */
static Float64                          gSampleRate         = kDefaultSampleRate;
static UInt32                           gBufferFrameSize    = kRingBufferFrames;
static UInt32                           gIORunningCount     = 0;     /* StartIO/StopIO Balance */
static atomic_uint                      gDeviceIsRunning    = 0;     /* RT-lesbar  */
static UInt32                           gDeviceClientCount  = 0;

/* Stream / Controls ------------------------------------------------------ */
static bool                             gStreamIsActive     = true;
static _Atomic float                    gVolume             = 1.0f;  /* 0..1, atomar fuer RT-Pfad */
static _Atomic bool                     gMute               = false; /* atomar fuer RT-Pfad */

/* Zeitbasis fuer GetZeroTimeStamp --------------------------------------- */
/* K5: Als atomic_ullong deklariert — wird von StartIO (non-RT, unter gStateMutex)
 * geschrieben und von GetZeroTimeStamp (RT-Thread) gelesen. Verhindert Data Race. */
static atomic_ullong                    gAnchorHostTime     = 0;
static atomic_ullong                    gNumberTimeStamps   = 0;
/* P4: Echte vom RT-Pfad geschriebene Frame-Anzahl. GetZeroTimeStamp leitet
 * die Sample-Zeit aus den TATSAECHLICH geschriebenen Frames ab, statt aus der
 * Host-Clock — so bleibt die Sample-Zeit konsistent mit dem Ring-Fortschritt,
 * auch wenn IOProc-Calls zeitlich driften. RT-sicher: nur atomic_fetch_add. */
static atomic_ullong                    gFramesWritten      = 0;
/*
 * gHostTicksPerFrame: wird nur von nicht-RT-Pfaden geschrieben (Initialize,
 * StartIO). Von GetZeroTimeStamp atomar gelesen — kein Mutex noetig.
 * Double hat auf arm64/x86_64 keine guaranteed atomic load via C11,
 * daher als atomic_ullong (bit-reinterpret). Schreiben nur unter gStateMutex.
 */
static atomic_ullong                    gHostTicksPerFrameBits = 0; /* bits von Float64 */

/* Hilfs-Makros fuer bit-reinterpretierende Konvertierung Float64 ↔ uint64 */
static inline UInt64  _f64_to_u64(Float64 v) { UInt64  u; memcpy(&u, &v, 8); return u; }
static inline Float64 _u64_to_f64(UInt64  u) { Float64 v; memcpy(&v, &u, 8); return v; }

#pragma mark - Shared Memory IPC (v2.0)

/*
 * v2.0: Der Socket-IPC wurde durch POSIX Shared Memory ersetzt.
 * Der Treiber ist reiner PRODUCER: WriteMix schreibt Frames in den Ring.
 * Der Helper-Daemon ist CONSUMER: liest Frames und gibt sie an CoreAudio weiter.
 *
 * RT-Garantien:
 *   - arn_ring_write(): kein Lock, kein malloc, kein Syscall → RT-safe
 *   - shm_open/mmap/shm_unlink: NUR in Initialize/Release (nicht-RT)
 */

/*
 * gSHMRing wird vom RT-Pfad (ARN_DoIOOperation) gelesen und von nicht-RT-Pfaden
 * (Initialize, Watch-Thread) geschrieben. Als atomic_uintptr_t deklariert, damit
 * der Watch-Thread den Pointer atomar austauschen kann, ohne dass der IOProc
 * einen halb geschriebenen Zeiger sieht. Der IOProc laedt den Pointer EINMAL pro
 * Aufruf in eine lokale Variable und arbeitet konsistent darauf.
 */
static _Atomic(ARNSharedRing *) gSHMRing = NULL;  /* mmap-Pointer, NULL = nicht bereit */
static int            gSHMFD     = -1;     /* shm_open file descriptor           */

/* Hintergrund-Thread: wartet bis Helper das SHM anlegt */
static pthread_t      gSHMRetryThread  = 0;
static atomic_int     gSHMRetryRunning = 0;

/* Hintergrund-Thread: erkennt Helper-Neustart (neues SHM-Segment) */
static pthread_t      gSHMWatchThread  = 0;
static atomic_int     gSHMWatchRunning = 0;

/*
 * arn_shm_init — oeffnet/erstellt das SHM-Segment und initialisiert den Ring.
 * Wird in ARN_Initialize aufgerufen (nicht-RT, einmalig).
 *
 * Driver-Reload-Sicherheit (Fix 4):
 *   Beim Reload durch coreaudiod (z.B. sudo killall coreaudiod) kann der
 *   Helper das Segment noch gemapt haben. Blindes shm_unlink + memset
 *   wuerde den Helper-State korrumpieren.
 *
 *   Strategie: Zuerst pruefen ob ein gueltiges Segment mit passendem
 *   magic + version existiert. Falls ja, Ring sanft leeren (write_idx
 *   auf read_idx setzen) und sr_change_gen inkrementieren damit der
 *   Helper neu synchronisiert. Falls nein (Crash-Relikt oder falsche
 *   Version), Segment entfernen und frisch erstellen.
 */
/*
 * arn_shm_init — verbindet sich mit dem vom Helper angelegten SHM-Segment.
 *
 * ARCHITEKTUR v2.1: Der _coreaudiod-Sandbox-Prozess darf shm_open(O_CREAT)
 * NICHT ausfuehren (Sandbox-Restriction). Deshalb erstellt der Helper
 * (nicht-sandboxd, laeuft als mauriciomorkun) das Segment.
 * Der Driver verbindet sich NUR — kein O_CREAT hier.
 *
 * Falls der Helper noch nicht gestartet ist (ENOENT), kehrt diese Funktion
 * sofort zurueck und ein Hintergrund-Thread (arn_shm_retry_thread) versucht
 * es alle 500 ms erneut bis gSHMRing gesetzt ist.
 */
static void arn_shm_init(void)
{
    int fd = shm_open(ARN_SHM_NAME, O_RDWR, 0);
    if (fd < 0) {
        os_log(gLog, "SHM: Noch nicht vorhanden (errno=%d) — warte auf Helper", errno);
        return;
    }

    void *ptr = mmap(NULL, ARN_SHM_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) {
        os_log_error(gLog, "SHM: mmap fehlgeschlagen (errno=%d)", errno);
        close(fd);
        return;
    }

    ARNSharedRing *ring = (ARNSharedRing *)ptr;
    if (ring->magic == ARN_RING_MAGIC && ring->version == ARN_RING_VERSION) {
        /* Gueltiger Ring vom Helper — write_idx zuruecksetzen und
         * sr_change_gen inkrementieren damit Helper neu synchronisiert. */
        uint32_t ridx = atomic_load_explicit(&ring->read_idx, memory_order_acquire);
        atomic_store_explicit(&ring->write_idx, ridx, memory_order_release);
        atomic_fetch_add_explicit(&ring->sr_change_gen, 1u, memory_order_release);
        os_log(gLog, "SHM: Verbunden (Helper-Ring) — %s (%zu Bytes)", ARN_SHM_NAME, ARN_SHM_SIZE);
    } else {
        /* Ring noch nicht initialisiert (Helper in Vorbereitung) — selbst init. */
        arn_ring_init(ring);
        os_log(gLog, "SHM: Verbunden + Ring initialisiert — %s", ARN_SHM_NAME);
    }

    gSHMFD   = fd;
    atomic_store_explicit(&gSHMRing, ring, memory_order_release);
}

/*
 * arn_shm_retry_thread — Hintergrund-Thread der alle 500 ms arn_shm_init()
 * aufruft bis gSHMRing gesetzt ist (Helper hat SHM angelegt).
 */
static void *arn_shm_retry_thread(void *arg)
{
    (void)arg;
    while (atomic_load_explicit(&gSHMRetryRunning, memory_order_acquire)) {
        usleep(500000); /* 500 ms */
        if (atomic_load_explicit(&gSHMRing, memory_order_acquire) != NULL) break;
        arn_shm_init();
        if (atomic_load_explicit(&gSHMRing, memory_order_acquire) != NULL) {
            os_log(gLog, "SHM: Retry erfolgreich — Driver mit Helper-Ring verbunden");
            break;
        }
    }
    return NULL;
}

/*
 * arn_shm_watch_thread — erkennt einen Helper-Neustart.
 *
 * Problem: Wenn der Helper neu startet, ruft er shm_unlink() + shm_open(O_CREAT)
 * auf und erzeugt ein NEUES Segment unter demselben Namen. Der Driver hat aber
 * noch das ALTE (aus dem Namespace entfernte) Segment gemappt. Da gSHMRing != NULL
 * laeuft der Retry-Thread nicht mehr — der Driver schreibt fuer immer ins alte
 * Segment, der Helper liest vom neuen → Stille.
 *
 * Erkennung: Alle 2 s shm_open(ARN_SHM_NAME). Liefert das einen FD, der auf eine
 * ANDERE Inode zeigt als unser aktuelles gSHMFD, existiert ein neues Segment.
 * (Ein per shm_unlink entferntes Segment behaelt zwar seinen FD/seine Inode, der
 *  Name im Namespace zeigt nach Helper-Neustart aber auf eine frische Inode.)
 *
 * Bei Erkennung: neues Segment mappen, gSHMRing atomar darauf umbiegen, write_idx
 * auf read_idx setzen (Ring leer) und sr_change_gen inkrementieren, damit der
 * Helper neu synchronisiert.
 *
 * RT-Sicherheit: Der IOProc laedt gSHMRing atomar in eine lokale Variable und
 * arbeitet darauf. Das alte Segment wird NICHT sofort unmappt, sondern erst im
 * naechsten Watch-Zyklus (2 s spaeter) — bis dahin sind alle in-flight IOProc-
 * Aufrufe (Dauer << 1 ms) auf dem alten Pointer garantiert beendet. So kann der
 * RT-Thread nie auf ein gerade unmapptes Segment zugreifen (kein SIGBUS).
 */
static void *arn_shm_watch_thread(void *arg)
{
    (void)arg;
    /* Verzoegerte Bereinigung: das beim letzten Swap ersetzte Segment. */
    ARNSharedRing *pending_old_ring = NULL;
    int            pending_old_fd   = -1;

    while (atomic_load_explicit(&gSHMWatchRunning, memory_order_acquire)) {
        usleep(2000000); /* 2 Sekunden */
        if (!atomic_load_explicit(&gSHMWatchRunning, memory_order_acquire)) break;

        /* Alten Swap-Rest jetzt sicher freigeben (in-flight IOProcs sind durch). */
        if (pending_old_ring != NULL) {
            munmap(pending_old_ring, ARN_SHM_SIZE);
            pending_old_ring = NULL;
        }
        if (pending_old_fd >= 0) {
            close(pending_old_fd);
            pending_old_fd = -1;
        }

        if (atomic_load_explicit(&gSHMRing, memory_order_acquire) == NULL) continue;

        /* Aktuell sichtbares Segment unter ARN_SHM_NAME oeffnen. */
        int check_fd = shm_open(ARN_SHM_NAME, O_RDWR, 0);
        if (check_fd < 0) continue; /* gerade nicht vorhanden */

        /* K3: instance_id-Vergleich statt Inode-Vergleich.
         * macOS recycelt Inodes (insbesondere fuer POSIX-SHM), was zu
         * False-Negatives fuehrt (neues Segment wird als altes erkannt).
         * Die instance_id wird vom Helper bei jeder SHM-Erstellung auf einen
         * eindeutigen Wert gesetzt (mach_absolute_time XOR pid). */
        bool is_new_segment = false;
        void *chk_ptr = mmap(NULL, ARN_SHM_SIZE, PROT_READ | PROT_WRITE,
                              MAP_SHARED, check_fd, 0);
        if (chk_ptr != MAP_FAILED) {
            ARNSharedRing *chk_ring = (ARNSharedRing *)chk_ptr;
            ARNSharedRing *cur_ring = atomic_load_explicit(&gSHMRing, memory_order_acquire);
            if (cur_ring != NULL) {
                uint64_t cur_iid = (uint64_t)atomic_load_explicit(&cur_ring->instance_id,
                                                                   memory_order_acquire);
                uint64_t chk_iid = (uint64_t)atomic_load_explicit(&chk_ring->instance_id,
                                                                   memory_order_acquire);
                /* Neues Segment: instance_id unterscheidet sich und ist nicht 0 */
                is_new_segment = (chk_iid != 0 && cur_iid != chk_iid);
            }
            munmap(chk_ptr, ARN_SHM_SIZE);
        }
        /* check_fd bleibt offen falls is_new_segment — wird dann als neues gSHMFD gesetzt. */

        if (!is_new_segment) {
            close(check_fd);
            continue;
        }

        /* Neues Segment mappen und validieren. */
        void *new_ptr = mmap(NULL, ARN_SHM_SIZE, PROT_READ | PROT_WRITE,
                             MAP_SHARED, check_fd, 0);
        if (new_ptr == MAP_FAILED) {
            close(check_fd);
            continue;
        }

        ARNSharedRing *new_ring = (ARNSharedRing *)new_ptr;
        if (new_ring->magic != ARN_RING_MAGIC || new_ring->version != ARN_RING_VERSION) {
            /* Helper noch mitten in der Initialisierung — naechster Zyklus erneut. */
            munmap(new_ptr, ARN_SHM_SIZE);
            close(check_fd);
            continue;
        }

        /* Ring leeren (write_idx = read_idx) und Helper zur Resync triggern. */
        uint32_t ridx = atomic_load_explicit(&new_ring->read_idx, memory_order_acquire);
        atomic_store_explicit(&new_ring->write_idx, ridx, memory_order_release);
        atomic_fetch_add_explicit(&new_ring->sr_change_gen, 1u, memory_order_release);

        /* Altes Segment fuer verzoegerte Bereinigung merken (erst naechster Zyklus). */
        pending_old_ring = atomic_load_explicit(&gSHMRing, memory_order_acquire);
        pending_old_fd   = gSHMFD;

        /* Atomarer Swap: ab jetzt sieht der IOProc das neue Segment. */
        gSHMFD = check_fd;
        atomic_store_explicit(&gSHMRing, new_ring, memory_order_release);

        os_log(gLog, "SHM: Watch-Thread — Reconnect nach Helper-Neustart");
    }

    /* Beim Thread-Ende: ausstehenden Swap-Rest noch freigeben. */
    if (pending_old_ring != NULL) {
        munmap(pending_old_ring, ARN_SHM_SIZE);
    }
    if (pending_old_fd >= 0) {
        close(pending_old_fd);
    }
    return NULL;
}

/*
 * arn_shm_cleanup — gibt SHM-Ressourcen frei.
 * Wird in ARN_Release aufgerufen.
 */
static void arn_shm_cleanup(void)
{
    /* Retry-Thread stoppen falls aktiv */
    if (atomic_load_explicit(&gSHMRetryRunning, memory_order_acquire)) {
        atomic_store_explicit(&gSHMRetryRunning, 0, memory_order_release);
        if (gSHMRetryThread) {
            pthread_join(gSHMRetryThread, NULL);
            gSHMRetryThread = 0;
        }
    }
    /* Watch-Thread stoppen falls aktiv */
    if (atomic_load_explicit(&gSHMWatchRunning, memory_order_acquire)) {
        atomic_store_explicit(&gSHMWatchRunning, 0, memory_order_release);
        if (gSHMWatchThread) {
            pthread_join(gSHMWatchThread, NULL);
            gSHMWatchThread = 0;
        }
    }
    ARNSharedRing *ring = atomic_load_explicit(&gSHMRing, memory_order_acquire);
    if (ring != NULL && ring != MAP_FAILED) {
        munmap(ring, ARN_SHM_SIZE);
        atomic_store_explicit(&gSHMRing, NULL, memory_order_release);
    }
    if (gSHMFD >= 0) {
        close(gSHMFD);
        gSHMFD = -1;
    }
    /* SHM NICHT unlinken — Helper hat es erstellt und besitzt es */
    os_log(gLog, "SHM: Driver-Verbindung getrennt");
}

#pragma mark - Format-Helfer

static void FillASBD(AudioStreamBasicDescription *outASBD, Float64 inSampleRate)
{
    memset(outASBD, 0, sizeof(*outASBD));
    outASBD->mSampleRate        = inSampleRate;
    outASBD->mFormatID          = kAudioFormatLinearPCM;
    outASBD->mFormatFlags       = kAudioFormatFlagIsFloat |
                                  kAudioFormatFlagsNativeEndian |
                                  kAudioFormatFlagIsPacked;
    outASBD->mBytesPerPacket    = kBytesPerFrame;
    outASBD->mFramesPerPacket   = 1;
    outASBD->mBytesPerFrame     = kBytesPerFrame;
    outASBD->mChannelsPerFrame  = kChannelsPerFrame;
    outASBD->mBitsPerChannel    = kBitsPerChannel;
}

#pragma mark - Forward Declarations (Interface-Funktionen)

static HRESULT  ARN_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG    ARN_AddRef(void *inDriver);
static ULONG    ARN_Release(void *inDriver);

static OSStatus ARN_Initialize(AudioServerPlugInDriverRef inDriver,
                               AudioServerPlugInHostRef inHost);
static OSStatus ARN_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                 CFDictionaryRef inDescription,
                                 const AudioServerPlugInClientInfo *inClientInfo,
                                 AudioObjectID *outDeviceObjectID);
static OSStatus ARN_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID inDeviceObjectID);
static OSStatus ARN_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inDeviceObjectID,
                                    const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus ARN_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus ARN_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction,
                                                     void *inChangeInfo);
static OSStatus ARN_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                   AudioObjectID inDeviceObjectID,
                                                   UInt64 inChangeAction,
                                                   void *inChangeInfo);

static Boolean  ARN_HasProperty(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inObjectID, pid_t inClientProcessID,
                                const AudioObjectPropertyAddress *inAddress);
static OSStatus ARN_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID, pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress,
                                       Boolean *outIsSettable);
static OSStatus ARN_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inObjectID, pid_t inClientProcessID,
                                        const AudioObjectPropertyAddress *inAddress,
                                        UInt32 inQualifierDataSize,
                                        const void *inQualifierData,
                                        UInt32 *outDataSize);
static OSStatus ARN_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID, pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void *inQualifierData,
                                    UInt32 inDataSize, UInt32 *outDataSize,
                                    void *outData);
static OSStatus ARN_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID, pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void *inQualifierData,
                                    UInt32 inDataSize, const void *inData);

static OSStatus ARN_StartIO(AudioServerPlugInDriverRef inDriver,
                            AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus ARN_StopIO(AudioServerPlugInDriverRef inDriver,
                           AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus ARN_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                     AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     Float64 *outSampleTime, UInt64 *outHostTime,
                                     UInt64 *outSeed);
static OSStatus ARN_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                      UInt32 inOperationID, Boolean *outWillDo,
                                      Boolean *outWillDoInPlace);
static OSStatus ARN_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                     AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus ARN_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                  UInt32 inClientID, UInt32 inOperationID,
                                  UInt32 inIOBufferFrameSize,
                                  const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                  void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus ARN_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                   UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

#pragma mark - COM IUnknown

static HRESULT ARN_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface)
{
    if (inDriver != gAudioServerPlugInDriverRef || outInterface == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    HRESULT result = E_NOINTERFACE;
    /* Die SDK-Makros expandieren bereits zu vollstaendigen
     * CFUUIDGetConstantUUIDWithBytes(...)-Aufrufen — direkt verwenden. */
    CFUUIDRef iunknown    = CFUUIDGetConstantUUIDWithBytes(NULL,
                              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                              0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46);
    CFUUIDRef pluginIface = kAudioServerPlugInDriverInterfaceUUID;

    if (CFEqual(requested, iunknown) || CFEqual(requested, pluginIface)) {
        pthread_mutex_lock(&gStateMutex);
        gPlugInRefCount += 1;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gAudioServerPlugInDriverRef;
        result = S_OK;
    }

    CFRelease(requested);
    return result;
}

static ULONG ARN_AddRef(void *inDriver)
{
    if (inDriver != gAudioServerPlugInDriverRef) {
        return 0;
    }
    pthread_mutex_lock(&gStateMutex);
    if (gPlugInRefCount < UINT32_MAX) {
        gPlugInRefCount += 1;
    }
    ULONG result = gPlugInRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return result;
}

static ULONG ARN_Release(void *inDriver)
{
    if (inDriver != gAudioServerPlugInDriverRef) {
        return 0;
    }
    /* H4: gStateMutex wird NUR fuer den Ref-Count-Decrement gehalten.
     * arn_shm_cleanup() ruft pthread_join() auf — pthread_join unter Mutex
     * ist ein latentes Deadlock wenn der Join-Thread ebenfalls versucht den
     * Mutex zu akquirieren. Cleanup laeuft deshalb nach Mutex-Release. */
    pthread_mutex_lock(&gStateMutex);
    if (gPlugInRefCount > 0) {
        gPlugInRefCount -= 1;
    }
    ULONG result = gPlugInRefCount;
    pthread_mutex_unlock(&gStateMutex);

    if (result == 0) {
        /* Letzter Release — SHM freigeben (pthread_join ausserhalb von Mutex). */
        arn_shm_cleanup();
    }
    return result;
}

#pragma mark - Lifecycle

static OSStatus ARN_Initialize(AudioServerPlugInDriverRef inDriver,
                               AudioServerPlugInHostRef inHost)
{
    if (inDriver != gAudioServerPlugInDriverRef) {
        return kAudioHardwareBadObjectError;
    }

    gPlugInHost = inHost;

    /* Host-Zeitbasis bestimmen (Mach-Ticks pro Audio-Frame). */
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    Float64 nanosPerTick = (Float64)tb.numer / (Float64)tb.denom;
    atomic_store(&gHostTicksPerFrameBits,
                 _f64_to_u64((1.0e9 / gSampleRate) / nanosPerTick));

    /* Shared Memory Ring verbinden — Helper legt SHM an, Driver verbindet sich. */
    arn_shm_init();
    if (atomic_load_explicit(&gSHMRing, memory_order_acquire) == NULL) {
        /* Helper noch nicht bereit — Hintergrund-Thread startet Retry alle 500ms */
        atomic_store_explicit(&gSHMRetryRunning, 1, memory_order_release);
        pthread_create(&gSHMRetryThread, NULL, arn_shm_retry_thread, NULL);
        os_log(gLog, "SHM: Helper noch nicht bereit, Retry-Thread gestartet");
    }

    /* Watch-Thread starten: erkennt spaetere Helper-Neustarts (neues SHM-Segment)
     * und biegt gSHMRing atomar auf das neue Segment um. */
    atomic_store_explicit(&gSHMWatchRunning, 1, memory_order_release);
    pthread_create(&gSHMWatchThread, NULL, arn_shm_watch_thread, NULL);

    os_log(gLog, "AudioRouterNow: Initialize OK (SR=%.0f, Buffer=%u)",
           gSampleRate, gBufferFrameSize);
    return kAudioHardwareNoError;
}

static OSStatus ARN_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                 CFDictionaryRef inDescription,
                                 const AudioServerPlugInClientInfo *inClientInfo,
                                 AudioObjectID *outDeviceObjectID)
{
    /* Statisches Objektmodell: dynamische Devices werden nicht unterstuetzt. */
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus ARN_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus ARN_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inDeviceObjectID,
                                    const AudioServerPlugInClientInfo *inClientInfo)
{
    if (inDriver != gAudioServerPlugInDriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    (void)inClientInfo;

    pthread_mutex_lock(&gStateMutex);
    gDeviceClientCount += 1;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus ARN_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo *inClientInfo)
{
    if (inDriver != gAudioServerPlugInDriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    (void)inClientInfo;

    pthread_mutex_lock(&gStateMutex);
    if (gDeviceClientCount > 0) {
        gDeviceClientCount -= 1;
    }
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus ARN_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction,
                                                     void *inChangeInfo)
{
    if (inDriver != gAudioServerPlugInDriverRef) {
        return kAudioHardwareBadObjectError;
    }
    if (inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    (void)inChangeInfo;

    /* inChangeAction transportiert die neue Sample-Rate (siehe SetPropertyData). */
    Float64 newRate = (Float64)inChangeAction;
    if (ARN_IsValidSampleRate(newRate)) {
        pthread_mutex_lock(&gStateMutex);
        gSampleRate = newRate;
        struct mach_timebase_info tb;
        mach_timebase_info(&tb);
        Float64 nanosPerTick = (Float64)tb.numer / (Float64)tb.denom;
        atomic_store(&gHostTicksPerFrameBits,
                     _f64_to_u64((1.0e9 / gSampleRate) / nanosPerTick));
        /* P4: Frame-Zaehler und Anker beim SR-Wechsel zuruecksetzen, damit die
         * Sample-Zeit-Uhr (frame-basiert) sauber neu startet — sonst mischen
         * sich Frames vor/nach dem Wechsel. */
        atomic_store(&gFramesWritten, 0);
        atomic_store(&gNumberTimeStamps, 0);
        atomic_store_explicit(&gAnchorHostTime, mach_absolute_time(), memory_order_release);
        /* SHM-Ring mit neuer SR neu initialisieren */
        ARNSharedRing *ring = atomic_load_explicit(&gSHMRing, memory_order_acquire);
        if (ring != NULL) {
            arn_ring_set_sample_rate(ring, (uint32_t)newRate);
        }
        pthread_mutex_unlock(&gStateMutex);
        os_log(gLog, "AudioRouterNow: SampleRate -> %.0f", newRate);
        return kAudioHardwareNoError;
    }
    return kAudioHardwareIllegalOperationError;
}

static OSStatus ARN_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                   AudioObjectID inDeviceObjectID,
                                                   UInt64 inChangeAction,
                                                   void *inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

#pragma mark - Property-Helfer

/* Liefert true, wenn das Objekt eine gueltige ID des Modells ist. */
static bool ObjectIsKnown(AudioObjectID inObjectID)
{
    switch (inObjectID) {
        case kObjectID_PlugIn:
        case kObjectID_Box:
        case kObjectID_Device:
        case kObjectID_Stream_Output:
        case kObjectID_Volume_Output:
        case kObjectID_Mute_Output:
            return true;
        default:
            return false;
    }
}

#pragma mark - HasProperty

static Boolean ARN_HasProperty(AudioServerPlugInDriverRef inDriver,
                               AudioObjectID inObjectID, pid_t inClientProcessID,
                               const AudioObjectPropertyAddress *inAddress)
{
    (void)inClientProcessID;
    if (inDriver != gAudioServerPlugInDriverRef || inAddress == NULL) {
        return false;
    }

    /* HasProperty == GetPropertyDataSize ohne Fehler. */
    UInt32 size = 0;
    OSStatus err = ARN_GetPropertyDataSize(inDriver, inObjectID, inClientProcessID,
                                           inAddress, 0, NULL, &size);
    return (err == kAudioHardwareNoError);
}

#pragma mark - IsPropertySettable

static OSStatus ARN_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID, pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress,
                                       Boolean *outIsSettable)
{
    (void)inClientProcessID;
    if (inDriver != gAudioServerPlugInDriverRef ||
        inAddress == NULL || outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!ObjectIsKnown(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }

    Boolean settable = false;

    switch (inAddress->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
            settable = (inObjectID == kObjectID_Device);
            break;
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
            settable = (inObjectID == kObjectID_Volume_Output);
            break;
        case kAudioBooleanControlPropertyValue:
            settable = (inObjectID == kObjectID_Mute_Output);
            break;
        default:
            settable = false;
            break;
    }

    *outIsSettable = settable;
    return kAudioHardwareNoError;
}

#pragma mark - GetPropertyDataSize

static OSStatus ARN_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inObjectID, pid_t inClientProcessID,
                                        const AudioObjectPropertyAddress *inAddress,
                                        UInt32 inQualifierDataSize,
                                        const void *inQualifierData,
                                        UInt32 *outDataSize)
{
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gAudioServerPlugInDriverRef ||
        inAddress == NULL || outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!ObjectIsKnown(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }

    UInt32 size = 0;
    OSStatus err = kAudioHardwareNoError;

    switch (inAddress->mSelector) {
        /* --- gemeinsam fuer alle Objekte ------------------------------- */
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            size = sizeof(AudioClassID);
            break;
        case kAudioObjectPropertyOwner:
            size = sizeof(AudioObjectID);
            break;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
        case kAudioObjectPropertyElementName:
            size = sizeof(CFStringRef);
            break;

        /* --- PlugIn ---------------------------------------------------- */
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyDeviceList:
            size = sizeof(AudioObjectID);
            break;
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            size = sizeof(AudioObjectID);
            break;
        case kAudioPlugInPropertyResourceBundle:
            size = sizeof(CFStringRef);
            break;

        /* --- Box ------------------------------------------------------- */
        case kAudioBoxPropertyBoxUID:
            size = sizeof(CFStringRef);
            break;
        case kAudioBoxPropertyTransportType:
            size = sizeof(UInt32);
            break;
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquired:
            size = sizeof(UInt32);
            break;
        case kAudioBoxPropertyDeviceList:
            size = sizeof(AudioObjectID);
            break;

        /* --- Device ---------------------------------------------------- */
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyConfigurationApplication:
            size = sizeof(CFStringRef);
            break;
        /* kAudioDevicePropertyTransportType teilt den FourCC 'tran' mit
         * kAudioBoxPropertyTransportType -> oben bereits behandelt. */
        case kAudioDevicePropertyRelatedDevices:
            size = sizeof(AudioObjectID);
            break;
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyIsHidden:
            size = sizeof(UInt32);
            break;
        /* kAudioDevicePropertyLatency teilt den FourCC 'ltnc' mit
         * kAudioStreamPropertyLatency -> unten gemeinsam behandelt. */
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyBufferFrameSize:
            size = sizeof(UInt32);
            break;
        case kAudioDevicePropertyNominalSampleRate:
            size = sizeof(Float64);
            break;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            size = (UInt32)(kNumSupportedSampleRates * sizeof(AudioValueRange));
            break;
        case kAudioDevicePropertyBufferFrameSizeRange:
            size = sizeof(AudioValueRange);
            break;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            size = 2 * sizeof(UInt32);
            break;
        case kAudioDevicePropertyPreferredChannelLayout:
            size = offsetof(AudioChannelLayout, mChannelDescriptions) +
                   (kChannelsPerFrame * sizeof(AudioChannelDescription));
            break;
        case kAudioDevicePropertyStreams:
            /* nur Output-Stream, nur wenn Scope passt */
            if (inAddress->mScope == kAudioObjectPropertyScopeGlobal ||
                inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                size = sizeof(AudioObjectID);
            } else {
                size = 0;
            }
            break;
        case kAudioObjectPropertyControlList:
            size = 2 * sizeof(AudioObjectID); /* Volume + Mute */
            break;
        case kAudioDevicePropertyStreamConfiguration:
            size = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
            break;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            size = sizeof(UInt32);
            break;
        /* --- Stream ---------------------------------------------------- */
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
            size = sizeof(UInt32);
            break;
        case kAudioStreamPropertyLatency:
            size = sizeof(UInt32);
            break;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            size = sizeof(AudioStreamBasicDescription);
            break;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            size = (UInt32)(kNumSupportedSampleRates * sizeof(AudioStreamRangedDescription));
            break;

        /* --- Controls (Volume / Mute) ---------------------------------- */
        case kAudioControlPropertyScope:
            size = sizeof(AudioObjectPropertyScope);
            break;
        case kAudioControlPropertyElement:
            size = sizeof(AudioObjectPropertyElement);
            break;
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
            size = sizeof(Float32);
            break;
        case kAudioLevelControlPropertyDecibelRange:
            size = sizeof(AudioValueRange);
            break;
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            size = sizeof(Float32);
            break;
        case kAudioBooleanControlPropertyValue:
            size = sizeof(UInt32);
            break;

        default:
            err = kAudioHardwareUnknownPropertyError;
            break;
    }

    if (err == kAudioHardwareNoError) {
        *outDataSize = size;
    }
    return err;
}

#pragma mark - GetPropertyData

static OSStatus ARN_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID, pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void *inQualifierData,
                                    UInt32 inDataSize, UInt32 *outDataSize,
                                    void *outData)
{
    (void)inClientProcessID;
    if (inDriver != gAudioServerPlugInDriverRef ||
        inAddress == NULL || outDataSize == NULL || outData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!ObjectIsKnown(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }

    OSStatus err = kAudioHardwareNoError;
    UInt32   written = 0;

    /* Komfort-Makros zum sicheren Schreiben skalarer Werte. */
    #define WRITE_SCALAR(TYPE, VALUE)                                       \
        do {                                                                \
            if (inDataSize < sizeof(TYPE)) { return kAudioHardwareBadPropertySizeError; } \
            *((TYPE *)outData) = (VALUE);                                   \
            written = sizeof(TYPE);                                         \
        } while (0)

    switch (inAddress->mSelector) {

        /* ---- kAudioObjectPropertyBaseClass ---------------------------- */
        case kAudioObjectPropertyBaseClass:
            switch (inObjectID) {
                case kObjectID_PlugIn:        WRITE_SCALAR(AudioClassID, kAudioObjectClassID);        break;
                case kObjectID_Box:           WRITE_SCALAR(AudioClassID, kAudioObjectClassID);        break;
                case kObjectID_Device:        WRITE_SCALAR(AudioClassID, kAudioObjectClassID);        break;
                case kObjectID_Stream_Output: WRITE_SCALAR(AudioClassID, kAudioObjectClassID);        break;
                case kObjectID_Volume_Output: WRITE_SCALAR(AudioClassID, kAudioLevelControlClassID);  break;
                case kObjectID_Mute_Output:   WRITE_SCALAR(AudioClassID, kAudioBooleanControlClassID);break;
            }
            break;

        /* ---- kAudioObjectPropertyClass -------------------------------- */
        case kAudioObjectPropertyClass:
            switch (inObjectID) {
                case kObjectID_PlugIn:        WRITE_SCALAR(AudioClassID, kAudioPlugInClassID);        break;
                case kObjectID_Box:           WRITE_SCALAR(AudioClassID, kAudioBoxClassID);           break;
                case kObjectID_Device:        WRITE_SCALAR(AudioClassID, kAudioDeviceClassID);        break;
                case kObjectID_Stream_Output: WRITE_SCALAR(AudioClassID, kAudioStreamClassID);        break;
                case kObjectID_Volume_Output: WRITE_SCALAR(AudioClassID, kAudioVolumeControlClassID); break;
                case kObjectID_Mute_Output:   WRITE_SCALAR(AudioClassID, kAudioMuteControlClassID);   break;
            }
            break;

        /* ---- kAudioObjectPropertyOwner -------------------------------- */
        case kAudioObjectPropertyOwner:
            switch (inObjectID) {
                case kObjectID_PlugIn:        WRITE_SCALAR(AudioObjectID, kAudioObjectUnknown); break;
                case kObjectID_Box:           WRITE_SCALAR(AudioObjectID, kObjectID_PlugIn);    break;
                case kObjectID_Device:        WRITE_SCALAR(AudioObjectID, kObjectID_PlugIn);    break;
                case kObjectID_Stream_Output: WRITE_SCALAR(AudioObjectID, kObjectID_Device);    break;
                case kObjectID_Volume_Output: WRITE_SCALAR(AudioObjectID, kObjectID_Device);    break;
                case kObjectID_Mute_Output:   WRITE_SCALAR(AudioObjectID, kObjectID_Device);    break;
            }
            break;

        /* ---- kAudioObjectPropertyName --------------------------------- */
        case kAudioObjectPropertyName:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            switch (inObjectID) {
                case kObjectID_Box:
                    *((CFStringRef *)outData) =
                        CFStringCreateWithCString(NULL, kBox_Name, kCFStringEncodingUTF8);
                    break;
                case kObjectID_Device:
                    *((CFStringRef *)outData) =
                        CFStringCreateWithCString(NULL, kDevice_Name, kCFStringEncodingUTF8);
                    break;
                case kObjectID_Stream_Output:
                    *((CFStringRef *)outData) =
                        CFStringCreateWithCString(NULL, "Audio Router Output",
                                                  kCFStringEncodingUTF8);
                    break;
                case kObjectID_Volume_Output:
                    *((CFStringRef *)outData) =
                        CFStringCreateWithCString(NULL, "Audio Router Volume",
                                                  kCFStringEncodingUTF8);
                    break;
                case kObjectID_Mute_Output:
                    *((CFStringRef *)outData) =
                        CFStringCreateWithCString(NULL, "Audio Router Mute",
                                                  kCFStringEncodingUTF8);
                    break;
                default:
                    *((CFStringRef *)outData) = NULL;
                    break;
            }
            written = sizeof(CFStringRef);
            break;

        /* ---- kAudioObjectPropertyManufacturer ------------------------- */
        case kAudioObjectPropertyManufacturer:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef *)outData) =
                CFStringCreateWithCString(NULL, kDevice_Manufacturer,
                                          kCFStringEncodingUTF8);
            written = sizeof(CFStringRef);
            break;

        /* ---- kAudioObjectPropertyModelName ---------------------------- */
        case kAudioObjectPropertyModelName:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef *)outData) =
                CFStringCreateWithCString(NULL, "AudioRouterNow Virtual Device",
                                          kCFStringEncodingUTF8);
            written = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertySerialNumber:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef *)outData) =
                CFStringCreateWithCString(NULL, "0001", kCFStringEncodingUTF8);
            written = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyFirmwareVersion:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef *)outData) =
                CFStringCreateWithCString(NULL, "1.0.0", kCFStringEncodingUTF8);
            written = sizeof(CFStringRef);
            break;

        /* ---- kAudioObjectPropertyElementName -------------------------- */
        case kAudioObjectPropertyElementName:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef *)outData) =
                CFStringCreateWithCString(NULL,
                    (inAddress->mElement == 1) ? "Left" : "Right",
                    kCFStringEncodingUTF8);
            written = sizeof(CFStringRef);
            break;

        /* ====================== PlugIn ================================ */
        case kAudioPlugInPropertyBoxList:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID *)outData) = kObjectID_Box;
            written = sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyDeviceList:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID *)outData) = kObjectID_Device;
            written = sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyTranslateUIDToBox: {
            if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL)
                return kAudioHardwareIllegalOperationError;
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *((const CFStringRef *)inQualifierData);
            CFStringRef mine = CFSTR(kBox_UID);
            *((AudioObjectID *)outData) =
                (uid && CFEqual(uid, mine)) ? kObjectID_Box : kAudioObjectUnknown;
            written = sizeof(AudioObjectID);
            break;
        }

        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL)
                return kAudioHardwareIllegalOperationError;
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *((const CFStringRef *)inQualifierData);
            CFStringRef mine = CFSTR(kDevice_UID);
            *((AudioObjectID *)outData) =
                (uid && CFEqual(uid, mine)) ? kObjectID_Device : kAudioObjectUnknown;
            written = sizeof(AudioObjectID);
            break;
        }

        case kAudioPlugInPropertyResourceBundle:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef *)outData) = CFSTR("");  /* Resourcen liegen im Bundle */
            written = sizeof(CFStringRef);
            break;

        /* ====================== Box =================================== */
        case kAudioBoxPropertyBoxUID:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef *)outData) =
                CFStringCreateWithCString(NULL, kBox_UID, kCFStringEncodingUTF8);
            written = sizeof(CFStringRef);
            break;

        /* 'tran' — gemeinsam fuer Box und Device (gleicher FourCC). */
        case kAudioBoxPropertyTransportType:
            WRITE_SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);
            break;

        case kAudioBoxPropertyHasAudio:
            WRITE_SCALAR(UInt32, 1);
            break;
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
            WRITE_SCALAR(UInt32, 0);
            break;
        case kAudioBoxPropertyAcquired:
            WRITE_SCALAR(UInt32, 1);
            break;

        case kAudioBoxPropertyDeviceList:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID *)outData) = kObjectID_Device;
            written = sizeof(AudioObjectID);
            break;

        /* ====================== Device ================================ */
        case kAudioDevicePropertyDeviceUID:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef *)outData) =
                CFStringCreateWithCString(NULL, kDevice_UID, kCFStringEncodingUTF8);
            written = sizeof(CFStringRef);
            break;

        case kAudioDevicePropertyModelUID:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef *)outData) =
                CFStringCreateWithCString(NULL, kDevice_ModelUID, kCFStringEncodingUTF8);
            written = sizeof(CFStringRef);
            break;

        case kAudioDevicePropertyConfigurationApplication:
            if (inDataSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;
            *((CFStringRef *)outData) = CFSTR("com.apple.audio.AudioMIDISetup");
            written = sizeof(CFStringRef);
            break;

        /* kAudioDevicePropertyTransportType == kAudioBoxPropertyTransportType
         * ('tran') -> oben gemeinsam behandelt. */

        case kAudioDevicePropertyRelatedDevices:
            if (inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID *)outData) = kObjectID_Device;
            written = sizeof(AudioObjectID);
            break;

        case kAudioDevicePropertyClockDomain:
            WRITE_SCALAR(UInt32, 0);
            break;

        case kAudioDevicePropertyDeviceIsAlive:
            WRITE_SCALAR(UInt32, 1);
            break;

        case kAudioDevicePropertyDeviceIsRunning:
            WRITE_SCALAR(UInt32, atomic_load(&gDeviceIsRunning) ? 1u : 0u);
            break;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            WRITE_SCALAR(UInt32, 1);
            break;

        case kAudioDevicePropertyIsHidden:
            WRITE_SCALAR(UInt32, 0);
            break;

        /* 'ltnc' — gemeinsam fuer Device und Stream (gleicher FourCC).
         * P14: Realen Pre-Roll-Versatz des Helper-Rings melden statt 0. */
        case kAudioDevicePropertyLatency:
            WRITE_SCALAR(UInt32, kReportedLatencyFrames);
            break;

        case kAudioDevicePropertySafetyOffset:
            WRITE_SCALAR(UInt32, 0);
            break;

        case kAudioDevicePropertyBufferFrameSize:
            pthread_mutex_lock(&gStateMutex);
            WRITE_SCALAR(UInt32, gBufferFrameSize);
            pthread_mutex_unlock(&gStateMutex);
            break;

        case kAudioDevicePropertyBufferFrameSizeRange: {
            if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
            AudioValueRange r;
            r.mMinimum = 64.0;
            r.mMaximum = 4096.0;
            *((AudioValueRange *)outData) = r;
            written = sizeof(AudioValueRange);
            break;
        }

        case kAudioDevicePropertyNominalSampleRate:
            pthread_mutex_lock(&gStateMutex);
            WRITE_SCALAR(Float64, gSampleRate);
            pthread_mutex_unlock(&gStateMutex);
            break;

        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 needed = (UInt32)(kNumSupportedSampleRates * sizeof(AudioValueRange));
            if (inDataSize < needed) return kAudioHardwareBadPropertySizeError;
            AudioValueRange *ranges = (AudioValueRange *)outData;
            for (size_t i = 0; i < kNumSupportedSampleRates; i++) {
                ranges[i].mMinimum = kSupportedSampleRates[i];
                ranges[i].mMaximum = kSupportedSampleRates[i];
            }
            written = needed;
            break;
        }

        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            UInt32 *ch = (UInt32 *)outData;
            ch[0] = 1; ch[1] = 2;
            written = 2 * sizeof(UInt32);
            break;
        }

        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 need = offsetof(AudioChannelLayout, mChannelDescriptions) +
                          (kChannelsPerFrame * sizeof(AudioChannelDescription));
            if (inDataSize < need) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout *layout = (AudioChannelLayout *)outData;
            memset(layout, 0, need);
            layout->mChannelLayoutTag         = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = kChannelsPerFrame;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            written = need;
            break;
        }

        case kAudioDevicePropertyStreams: {
            UInt32 cap = inDataSize / sizeof(AudioObjectID);
            UInt32 n   = 0;
            if ((inAddress->mScope == kAudioObjectPropertyScopeGlobal ||
                 inAddress->mScope == kAudioObjectPropertyScopeOutput) && cap >= 1) {
                ((AudioObjectID *)outData)[0] = kObjectID_Stream_Output;
                n = 1;
            }
            written = n * sizeof(AudioObjectID);
            break;
        }

        case kAudioObjectPropertyControlList: {
            UInt32 cap = inDataSize / sizeof(AudioObjectID);
            UInt32 n   = 0;
            AudioObjectID *list = (AudioObjectID *)outData;
            if (cap >= 1) { list[n++] = kObjectID_Volume_Output; }
            if (cap >= 2) { list[n++] = kObjectID_Mute_Output;   }
            written = n * sizeof(AudioObjectID);
            break;
        }

        case kAudioDevicePropertyStreamConfiguration: {
            UInt32 need = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
            if (inDataSize < need) return kAudioHardwareBadPropertySizeError;
            AudioBufferList *bl = (AudioBufferList *)outData;
            if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                bl->mNumberBuffers = 1;
                bl->mBuffers[0].mNumberChannels = kChannelsPerFrame;
                bl->mBuffers[0].mDataByteSize   =
                    kChannelsPerFrame * (kBitsPerChannel / 8);
                bl->mBuffers[0].mData           = NULL;
            } else {
                bl->mNumberBuffers = 0; /* keine Input-Streams */
            }
            written = need;
            break;
        }

        case kAudioDevicePropertyZeroTimeStampPeriod:
            WRITE_SCALAR(UInt32, kZeroTimeStampPeriod);
            break;

        /* ====================== Stream ================================ */
        case kAudioStreamPropertyIsActive:
            pthread_mutex_lock(&gStateMutex);
            WRITE_SCALAR(UInt32, gStreamIsActive ? 1u : 0u);
            pthread_mutex_unlock(&gStateMutex);
            break;

        case kAudioStreamPropertyDirection:
            WRITE_SCALAR(UInt32, 0); /* 0 == Output */
            break;

        case kAudioStreamPropertyTerminalType:
            WRITE_SCALAR(UInt32, kAudioStreamTerminalTypeSpeaker);
            break;

        case kAudioStreamPropertyStartingChannel:
            WRITE_SCALAR(UInt32, 1);
            break;

        /* kAudioStreamPropertyLatency == kAudioDevicePropertyLatency
         * ('ltnc') -> oben gemeinsam behandelt. */

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (inDataSize < sizeof(AudioStreamBasicDescription))
                return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            Float64 sr = gSampleRate;
            pthread_mutex_unlock(&gStateMutex);
            FillASBD((AudioStreamBasicDescription *)outData, sr);
            written = sizeof(AudioStreamBasicDescription);
            break;
        }

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 needed = (UInt32)(kNumSupportedSampleRates * sizeof(AudioStreamRangedDescription));
            if (inDataSize < needed) return kAudioHardwareBadPropertySizeError;
            AudioStreamRangedDescription *d = (AudioStreamRangedDescription *)outData;
            pthread_mutex_lock(&gStateMutex);
            Float64 sr = gSampleRate;
            pthread_mutex_unlock(&gStateMutex);
            for (size_t i = 0; i < kNumSupportedSampleRates; i++) {
                FillASBD(&d[i].mFormat, kSupportedSampleRates[i]);
                d[i].mSampleRateRange.mMinimum = kSupportedSampleRates[i];
                d[i].mSampleRateRange.mMaximum = kSupportedSampleRates[i];
            }
            (void)sr;
            written = needed;
            break;
        }

        /* ====================== Controls ============================== */
        case kAudioControlPropertyScope:
            WRITE_SCALAR(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
            break;

        case kAudioControlPropertyElement:
            WRITE_SCALAR(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
            break;

        case kAudioLevelControlPropertyScalarValue:
            if (inObjectID != kObjectID_Volume_Output) return kAudioHardwareUnknownPropertyError;
            WRITE_SCALAR(Float32, atomic_load_explicit(&gVolume, memory_order_acquire));
            break;

        case kAudioLevelControlPropertyDecibelValue: {
            if (inObjectID != kObjectID_Volume_Output) return kAudioHardwareUnknownPropertyError;
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 v = atomic_load_explicit(&gVolume, memory_order_acquire);
            /* Scalar (0..1) -> dB (-96..0), einfache Kennlinie. */
            Float32 db = (v <= 0.0f) ? -96.0f : (96.0f * (v - 1.0f));
            *((Float32 *)outData) = db;
            written = sizeof(Float32);
            break;
        }

        case kAudioLevelControlPropertyDecibelRange: {
            if (inDataSize < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
            AudioValueRange r;
            r.mMinimum = -96.0;
            r.mMaximum = 0.0;
            *((AudioValueRange *)outData) = r;
            written = sizeof(AudioValueRange);
            break;
        }

        case kAudioLevelControlPropertyConvertScalarToDecibels: {
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 v  = *((Float32 *)outData);
            if (v < 0.0f) v = 0.0f;
            if (v > 1.0f) v = 1.0f;
            *((Float32 *)outData) = (v <= 0.0f) ? -96.0f : (96.0f * (v - 1.0f));
            written = sizeof(Float32);
            break;
        }

        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 db = *((Float32 *)outData);
            if (db < -96.0f) db = -96.0f;
            if (db >  0.0f)  db =  0.0f;
            *((Float32 *)outData) = (db / 96.0f) + 1.0f;
            written = sizeof(Float32);
            break;
        }

        case kAudioBooleanControlPropertyValue:
            if (inObjectID != kObjectID_Mute_Output) return kAudioHardwareUnknownPropertyError;
            WRITE_SCALAR(UInt32, atomic_load_explicit(&gMute, memory_order_acquire) ? 1u : 0u);
            break;

        default:
            err = kAudioHardwareUnknownPropertyError;
            break;
    }

    #undef WRITE_SCALAR

    if (err == kAudioHardwareNoError) {
        *outDataSize = written;
    }
    return err;
}

#pragma mark - SetPropertyData

static OSStatus ARN_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID, pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void *inQualifierData,
                                    UInt32 inDataSize, const void *inData)
{
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gAudioServerPlugInDriverRef ||
        inAddress == NULL || inData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!ObjectIsKnown(inObjectID)) {
        return kAudioHardwareBadObjectError;
    }

    switch (inAddress->mSelector) {

        case kAudioDevicePropertyNominalSampleRate: {
            if (inObjectID != kObjectID_Device) return kAudioHardwareUnknownPropertyError;
            if (inDataSize < sizeof(Float64))   return kAudioHardwareBadPropertySizeError;
            Float64 requestedRate = *((Float64*)inData);
            if (!ARN_IsValidSampleRate(requestedRate)) {
                return kAudioHardwareUnsupportedOperationError;
            }
            /* Guard: Wenn der Ring aktiv ist und eine andere SR hat als angefordert,
             * handelt es sich um eine externe Anfrage (Spotify, Music.app, etc.).
             * Diese ignorieren wir — SR wird ausschliesslich vom Helper gesteuert. */
            ARNSharedRing *ring = atomic_load_explicit(&gSHMRing, memory_order_acquire);
            if (ring != NULL) {
                uint32_t ring_sr = atomic_load_explicit(&ring->sample_rate, memory_order_acquire);
                if (ring_sr != 0 && ring_sr != (uint32_t)requestedRate) {
                    os_log(gLog, "AudioRouterNow: Externe SR %.0f Hz ignoriert (Ring: %u Hz)",
                           requestedRate, ring_sr);
                    return kAudioHardwareNoError;
                }
            }
            Float64 req = requestedRate;
            pthread_mutex_lock(&gStateMutex);
            bool changed = (req != gSampleRate);
            pthread_mutex_unlock(&gStateMutex);
            if (changed && gPlugInHost != NULL) {
                /* Aenderung asynchron ueber den HAL anstossen.
                 * Die neue Rate reist in inChangeAction mit. */
                gPlugInHost->RequestDeviceConfigurationChange(
                    gPlugInHost, kObjectID_Device, (UInt64)req, NULL);
            }
            return kAudioHardwareNoError;
        }

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (inObjectID != kObjectID_Stream_Output)
                return kAudioHardwareUnknownPropertyError;
            if (inDataSize < sizeof(AudioStreamBasicDescription))
                return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription *fmt =
                (const AudioStreamBasicDescription *)inData;
            /* Nur Float32-Stereo bei 48000 Hz wird akzeptiert. */
            if (fmt->mFormatID != kAudioFormatLinearPCM ||
                fmt->mChannelsPerFrame != kChannelsPerFrame ||
                fmt->mBitsPerChannel != kBitsPerChannel) {
                return kAudioHardwareIllegalOperationError;
            }
            if (!ARN_IsValidSampleRate(fmt->mSampleRate)) {
                return kAudioHardwareUnsupportedOperationError;
            }
            /* Gleicher Guard wie bei kAudioDevicePropertyNominalSampleRate:
             * externe SR-Aenderungen via Stream-Format ignorieren. */
            ARNSharedRing *ring = atomic_load_explicit(&gSHMRing, memory_order_acquire);
            if (ring != NULL) {
                uint32_t ring_sr = atomic_load_explicit(&ring->sample_rate, memory_order_acquire);
                if (ring_sr != 0 && ring_sr != (uint32_t)fmt->mSampleRate) {
                    os_log(gLog, "AudioRouterNow: Externe Stream-SR %.0f Hz ignoriert (Ring: %u Hz)",
                           fmt->mSampleRate, ring_sr);
                    return kAudioHardwareNoError;
                }
            }
            pthread_mutex_lock(&gStateMutex);
            bool changed = (fmt->mSampleRate != gSampleRate);
            pthread_mutex_unlock(&gStateMutex);
            if (changed && gPlugInHost != NULL) {
                gPlugInHost->RequestDeviceConfigurationChange(
                    gPlugInHost, kObjectID_Device,
                    (UInt64)fmt->mSampleRate, NULL);
            }
            return kAudioHardwareNoError;
        }

        case kAudioStreamPropertyIsActive: {
            if (inObjectID != kObjectID_Stream_Output)
                return kAudioHardwareUnknownPropertyError;
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            UInt32 v = *((const UInt32 *)inData);
            pthread_mutex_lock(&gStateMutex);
            gStreamIsActive = (v != 0);
            pthread_mutex_unlock(&gStateMutex);
            return kAudioHardwareNoError;
        }

        case kAudioLevelControlPropertyScalarValue: {
            if (inObjectID != kObjectID_Volume_Output)
                return kAudioHardwareUnknownPropertyError;
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 v = *((const Float32 *)inData);
            if (v < 0.0f) v = 0.0f;
            if (v > 1.0f) v = 1.0f;
            atomic_store_explicit(&gVolume, v, memory_order_release);
            /* SHM volume sync — Fix M3: Driver schreibt volume_q16, Helper skaliert. */
            {
                ARNSharedRing *ring = atomic_load_explicit(&gSHMRing, memory_order_acquire);
                if (ring != NULL) {
                    uint32_t q16_val = (uint32_t)(v * 65536.0f);
                    atomic_store_explicit(&ring->volume_q16, q16_val, memory_order_release);
                }
            }
            /* CoreAudio (HUD) ueber Wertaenderung benachrichtigen */
            if (gPlugInHost != NULL) {
                AudioObjectPropertyAddress volProps[] = {
                    { kAudioLevelControlPropertyScalarValue,  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                    { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                };
                gPlugInHost->PropertiesChanged(gPlugInHost, kObjectID_Volume_Output, 2, volProps);
            }
            return kAudioHardwareNoError;
        }

        case kAudioLevelControlPropertyDecibelValue: {
            if (inObjectID != kObjectID_Volume_Output)
                return kAudioHardwareUnknownPropertyError;
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 db = *((const Float32 *)inData);
            if (db < -96.0f) db = -96.0f;
            if (db >  0.0f)  db =  0.0f;
            Float32 v = (db / 96.0f) + 1.0f;
            atomic_store_explicit(&gVolume, v, memory_order_release);
            /* SHM volume sync — Fix M3: Driver schreibt volume_q16, Helper skaliert. */
            {
                ARNSharedRing *ring = atomic_load_explicit(&gSHMRing, memory_order_acquire);
                if (ring != NULL) {
                    uint32_t q16_val = (uint32_t)(v * 65536.0f);
                    atomic_store_explicit(&ring->volume_q16, q16_val, memory_order_release);
                }
            }
            /* CoreAudio (HUD) ueber Wertaenderung benachrichtigen */
            if (gPlugInHost != NULL) {
                AudioObjectPropertyAddress volProps[] = {
                    { kAudioLevelControlPropertyScalarValue,  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                    { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                };
                gPlugInHost->PropertiesChanged(gPlugInHost, kObjectID_Volume_Output, 2, volProps);
            }
            return kAudioHardwareNoError;
        }

        case kAudioBooleanControlPropertyValue: {
            if (inObjectID != kObjectID_Mute_Output)
                return kAudioHardwareUnknownPropertyError;
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            atomic_store_explicit(&gMute, (*((const UInt32 *)inData) != 0), memory_order_release);
            /* CoreAudio (HUD) ueber Mute-Aenderung benachrichtigen */
            if (gPlugInHost != NULL) {
                AudioObjectPropertyAddress muteProps[] = {
                    { kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                };
                gPlugInHost->PropertiesChanged(gPlugInHost, kObjectID_Mute_Output, 1, muteProps);
            }
            return kAudioHardwareNoError;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - IO Lifecycle

static OSStatus ARN_StartIO(AudioServerPlugInDriverRef inDriver,
                            AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)    return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if (gIORunningCount == 0) {
        /* Erster Client startet die Uhr. K5: atomic store (RT-Thread liest in GetZeroTimeStamp). */
        atomic_store_explicit(&gAnchorHostTime, mach_absolute_time(), memory_order_release);
        atomic_store(&gNumberTimeStamps, 0);
        atomic_store(&gFramesWritten, 0);  /* P4: Frame-Zaehler beim Start zuruecksetzen. */
        atomic_store(&gDeviceIsRunning, 1);
        os_log(gLog, "AudioRouterNow: StartIO — Device laeuft");
    }
    gIORunningCount += 1;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus ARN_StopIO(AudioServerPlugInDriverRef inDriver,
                           AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)    return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if (gIORunningCount > 0) {
        gIORunningCount -= 1;
    }
    if (gIORunningCount == 0) {
        atomic_store(&gDeviceIsRunning, 0);
        os_log(gLog, "AudioRouterNow: StopIO — Device gestoppt");
    }
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}

static OSStatus ARN_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                     AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     Float64 *outSampleTime, UInt64 *outHostTime,
                                     UInt64 *outSeed)
{
    (void)inClientID;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)    return kAudioHardwareBadObjectError;
    if (!outSampleTime || !outHostTime || !outSeed) {
        return kAudioHardwareIllegalOperationError;
    }

    /*
     * P4: Sample-Zeit aus den TATSAECHLICH geschriebenen Frames ableiten.
     * Frueher wurde die verstrichene Zeit aus der Host-Clock geschaetzt, was
     * bei zeitlich driftenden IOProc-Calls zu einer Sample-Zeit fuehren konnte,
     * die nicht zum Ring-Fortschritt passt. Jetzt zaehlt ARN_DoIOOperation die
     * verarbeiteten Frames in gFramesWritten, und wir runden auf die letzte
     * voll abgeschlossene kZeroTimeStampPeriod-Grenze.
     */
    UInt64 anchor   = (UInt64)atomic_load_explicit(&gAnchorHostTime, memory_order_acquire);

    /* Fix macOS 26: Vor dem ersten StartIO ist gAnchorHostTime = 0.
     * Das ergibt einen unsinnigen Host-Timestamp → coreaudiod ruft StartIO
     * nie auf. Lösung: vor StartIO den aktuellen Zeitpunkt als Anker nutzen. */
    if (anchor == 0) {
        anchor = mach_absolute_time();
    }

    /* Kein Mutex im RT-Pfad — atomic_load verhindert Priority-Inversion. */
    Float64 ticksPerFrame = _u64_to_f64(
        atomic_load_explicit(&gHostTicksPerFrameBits, memory_order_relaxed)
    );
    if (ticksPerFrame <= 0.0) {
        ticksPerFrame = 1.0;
    }

    uint64_t frames    = atomic_load_explicit(&gFramesWritten, memory_order_relaxed);
    uint64_t completed = frames / kZeroTimeStampPeriod;

    *outSampleTime = (Float64)(completed * kZeroTimeStampPeriod);
    *outHostTime   = anchor + (UInt64)((Float64)(completed * kZeroTimeStampPeriod) * ticksPerFrame);
    *outSeed       = 1; /* Format aendert sich nie waehrend IO */

    atomic_store(&gNumberTimeStamps, completed);
    return kAudioHardwareNoError;
}

static OSStatus ARN_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                      UInt32 inOperationID, Boolean *outWillDo,
                                      Boolean *outWillDoInPlace)
{
    (void)inClientID;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)    return kAudioHardwareBadObjectError;
    if (!outWillDo || !outWillDoInPlace) {
        return kAudioHardwareIllegalOperationError;
    }

    Boolean willDo        = false;
    Boolean willDoInPlace = true;

    switch (inOperationID) {
        case kAudioServerPlugInIOOperationWriteMix:
            willDo        = true;   /* hier holen wir die Output-Samples ab */
            willDoInPlace = true;
            break;
        case kAudioServerPlugInIOOperationThread:
        case kAudioServerPlugInIOOperationCycle:
            willDo        = false;
            willDoInPlace = true;
            break;
        default:
            willDo        = false;
            willDoInPlace = true;
            break;
    }

    *outWillDo        = willDo;
    *outWillDoInPlace = willDoInPlace;
    return kAudioHardwareNoError;
}

static OSStatus ARN_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                     AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)    return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

/*
 * DoIOOperation — Hot-Path, laeuft auf einem Realtime-Thread.
 * Verbote: kein malloc, kein blocking IO, kein Lock-Contention.
 * Bei WriteMix liefert ioMainBuffer interleaved Float32-Stereo-Samples,
 * die wir non-blocking ueber den Unix Socket an Python schicken.
 */
static OSStatus ARN_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                  UInt32 inClientID, UInt32 inOperationID,
                                  UInt32 inIOBufferFrameSize,
                                  const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                  void *ioMainBuffer, void *ioSecondaryBuffer)
{
    (void)inStreamObjectID; (void)inClientID;
    (void)inIOCycleInfo; (void)ioSecondaryBuffer;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)    return kAudioHardwareBadObjectError;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix &&
        ioMainBuffer != NULL && inIOBufferFrameSize > 0) {

        size_t byteCount = (size_t)inIOBufferFrameSize * kBytesPerFrame;

        /* P4: Tatsaechlich verarbeitete Frames zaehlen — Basis fuer die
         * Sample-Zeit in GetZeroTimeStamp. RT-sicher (nur atomic_fetch_add,
         * kein malloc/lock/printf). Ausserhalb des ring!=NULL-Blocks, damit
         * der Takt auch dann konsistent fortschreitet, wenn der Ring gerade
         * neu gemappt wird. */
        atomic_fetch_add_explicit(&gFramesWritten, inIOBufferFrameSize, memory_order_relaxed);

        /* Mute beruecksichtigen: stilles Signal trotzdem als Frame senden,
         * damit die Python-Engine ihren Takt behaelt. Volume wird in der
         * Engine angewandt, hier nur Mute-Gate. */
        if (atomic_load_explicit(&gDeviceIsRunning, memory_order_relaxed)) {
            /* gVolume und gMute atomar lesen (memory_order_relaxed genuegt im RT-Pfad). */
            float vol  = atomic_load_explicit(&gVolume, memory_order_relaxed);
            bool  mute = atomic_load_explicit(&gMute,   memory_order_relaxed);

            if (mute || vol <= 0.0f) {
                /* Stilles Signal senden — Helper haelt ihren Takt. */
                memset(ioMainBuffer, 0, byteCount);
            }
            // Volume-Scaling wurde in Helper delegiert (via ring->volume_q16).
            // Doppelte Skalierung entfernt — Fix M3.
            //
            // else if (vol < 0.999f) {
            //     /* Volume-Scaling in-place (Float32-Samples). */
            //     float  *samples  = (float *)ioMainBuffer;
            //     size_t  nSamples = byteCount / sizeof(float);
            //     for (size_t i = 0; i < nSamples; i++) {
            //         samples[i] *= vol;
            //     }
            // }
            /* Samples unveraendert an Helper weitergeben — dieser skaliert via volume_q16. */
            /* v2.0: SHM-Ring statt Unix Socket — kein Syscall, RT-safe.
             * gSHMRing EINMAL atomar laden; der Watch-Thread kann den Pointer
             * jederzeit austauschen, das alte Segment bleibt aber bis zum
             * naechsten Watch-Zyklus gemappt (kein use-after-munmap). */
            ARNSharedRing *ring =
                atomic_load_explicit(&gSHMRing, memory_order_acquire);
            if (ring != NULL) {
                uint32_t nSamples = (uint32_t)(byteCount / sizeof(float));
                arn_ring_write(ring,
                               (const float *)ioMainBuffer,
                               nSamples);
            }
        }

        /*
         * Der Puffer ist ein Output-Mix, der "ins Geraet" geschrieben wird.
         * Ein virtuelles Geraet hat keine echte Senke, daher lassen wir den
         * Inhalt unveraendert (in-place). coreaudiod recycelt ihn selbst.
         */
    }

    return kAudioHardwareNoError;
}

static OSStatus ARN_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                   UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gAudioServerPlugInDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device)    return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

#pragma mark - Driver Interface Vtable

static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface = {
    NULL,                                   /* _reserved              */
    ARN_QueryInterface,
    ARN_AddRef,
    ARN_Release,
    ARN_Initialize,
    ARN_CreateDevice,
    ARN_DestroyDevice,
    ARN_AddDeviceClient,
    ARN_RemoveDeviceClient,
    ARN_PerformDeviceConfigurationChange,
    ARN_AbortDeviceConfigurationChange,
    ARN_HasProperty,
    ARN_IsPropertySettable,
    ARN_GetPropertyDataSize,
    ARN_GetPropertyData,
    ARN_SetPropertyData,
    ARN_StartIO,
    ARN_StopIO,
    ARN_GetZeroTimeStamp,
    ARN_WillDoIOOperation,
    ARN_BeginIOOperation,
    ARN_DoIOOperation,
    ARN_EndIOOperation
};

#pragma mark - Bundle Entry Point

/*
 * Einziger exportierter Symbolname. coreaudiod ruft diese Factory mit der
 * UUID aus Info.plist (CFPlugInFactories) auf und erhaelt einen Zeiger auf
 * unsere AudioServerPlugInDriverInterface-Vtable zurueck.
 */
__attribute__((visibility("default")))
void *AudioRouterNowDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

void *AudioRouterNowDriver_Create(CFAllocatorRef inAllocator,
                                  CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;

    if (gLog == NULL) {
        gLog = os_log_create("com.audiorouter.now.driver", "driver");
    }

    /* kAudioServerPlugInTypeUUID expandiert selbst zum CFUUID-Aufruf. */
    CFUUIDRef wanted = kAudioServerPlugInTypeUUID;

    if (inRequestedTypeUUID != NULL &&
        CFEqual(inRequestedTypeUUID, wanted)) {
        os_log(gLog, "AudioRouterNow: Factory liefert Driver-Interface");
        return gAudioServerPlugInDriverRef;
    }

    os_log_error(gLog, "AudioRouterNow: Factory mit unbekannter Type-UUID");
    return NULL;
}

/*
 * Aufraeumen beim Entladen des Bundles. Die AudioServerPlugin-API kennt
 * keinen expliziten Teardown-Aufruf; coreaudiod entlaedt die dylib direkt.
 * Der Destructor stoppt den Connector-Thread und schliesst den Socket.
 */
__attribute__((destructor))
static void AudioRouterNowDriver_Destroy(void)
{
    /* v2.0: SHM-Cleanup statt Socket-Stop */
    arn_shm_cleanup();
}
