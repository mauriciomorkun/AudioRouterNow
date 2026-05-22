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

#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>

#include <errno.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
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

/* IPC -------------------------------------------------------------------- */
#define kSocketPath                 "/tmp/audiorouter.sock"

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
static Float32                          gVolume             = 1.0f;  /* 0..1   */
static bool                             gMute               = false;

/* Zeitbasis fuer GetZeroTimeStamp --------------------------------------- */
static UInt64                           gAnchorHostTime     = 0;
static atomic_ullong                    gNumberTimeStamps   = 0;
static Float64                          gHostTicksPerFrame  = 0.0;

#pragma mark - Unix Socket IPC

/*
 * Der Socket-Zustand ist von zwei Welten erreichbar:
 *   - RT-IO-Thread: liest gSocketFD atomar, sendet non-blocking.
 *   - Connector-Thread: oeffnet/verbindet den Socket (blockierend erlaubt).
 * gSocketFD == -1 bedeutet "kein Peer". Der Send-Pfad fasst niemals
 * blockierende Aufrufe an.
 */
static atomic_int                       gSocketFD           = -1;
static atomic_bool                      gConnectorRun       = false;
static pthread_t                        gConnectorThread;
static bool                             gConnectorStarted   = false;

/* Verbindet (blockierend) einmalig. Gibt FD oder -1 zurueck. */
static int ipc_try_connect(void)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, kSocketPath, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, (socklen_t)SUN_LEN(&addr)) != 0) {
        close(fd);
        return -1;
    }

    /* Send-Buffer klein halten und SIGPIPE unterdruecken. */
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    int sndbuf = (int)(kRingBufferFrames * kBytesPerFrame * 8);
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

    /* Non-blocking, damit der RT-Send niemals blockiert. */
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }

    return fd;
}

/*
 * Connector-Thread: haelt im Hintergrund die Verbindung zur Python Engine.
 * Versucht alle 500 ms zu verbinden, solange kein Peer vorhanden ist.
 * Laeuft ausserhalb des RT-Pfades — blockierende Aufrufe sind hier erlaubt.
 */
static void *ipc_connector_main(void *unused)
{
    (void)unused;
    pthread_setname_np("com.audiorouter.now.connector");

    while (atomic_load(&gConnectorRun)) {
        if (atomic_load(&gSocketFD) < 0) {
            int fd = ipc_try_connect();
            if (fd >= 0) {
                int expected = -1;
                if (atomic_compare_exchange_strong(&gSocketFD, &expected, fd)) {
                    os_log(gLog, "IPC: mit Python Engine verbunden (%s)",
                           kSocketPath);
                } else {
                    close(fd); /* RT-Pfad war schneller — sollte nicht passieren */
                }
            }
        }
        usleep(500 * 1000); /* 500 ms */
    }
    return NULL;
}

static void ipc_start(void)
{
    pthread_mutex_lock(&gStateMutex);
    if (!gConnectorStarted) {
        atomic_store(&gConnectorRun, true);
        if (pthread_create(&gConnectorThread, NULL,
                           ipc_connector_main, NULL) == 0) {
            gConnectorStarted = true;
            os_log(gLog, "IPC: Connector-Thread gestartet");
        } else {
            atomic_store(&gConnectorRun, false);
            os_log_error(gLog, "IPC: Connector-Thread konnte nicht starten");
        }
    }
    pthread_mutex_unlock(&gStateMutex);
}

static void ipc_stop(void)
{
    pthread_t thread_to_join = 0;
    bool should_join = false;

    pthread_mutex_lock(&gStateMutex);
    if (gConnectorStarted) {
        atomic_store(&gConnectorRun, false);
        thread_to_join = gConnectorThread;
        should_join = true;
        gConnectorStarted = false;
    }
    pthread_mutex_unlock(&gStateMutex);

    if (should_join) {
        pthread_join(thread_to_join, NULL);
    }

    int fd = atomic_exchange(&gSocketFD, -1);
    if (fd >= 0) {
        close(fd);
    }
}

/*
 * RT-sicherer Send: wird aus dem IO-Callback aufgerufen.
 * Sendet non-blocking. Bei vollem Puffer / fehlendem Peer wird verworfen.
 * Bei einem echten Verbindungsfehler wird der FD geschlossen; der
 * Connector-Thread baut die Verbindung dann neu auf.
 */
static void ipc_send_rt(const void *data, size_t length)
{
    int fd = atomic_load(&gSocketFD);
    if (fd < 0 || length == 0) {
        return; /* Kein Peer — Audio einfach droppen. */
    }

    ssize_t n = send(fd, data, length, MSG_DONTWAIT);
    if (n >= 0) {
        return; /* Erfolg (oder Teil-Send; Drops sind tolerierbar). */
    }

    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        return; /* Puffer voll — Frame verwerfen, kein Fehler. */
    }

    /* Echter Fehler (EPIPE, ECONNRESET, ...): Verbindung fallen lassen. */
    int expected = fd;
    if (atomic_compare_exchange_strong(&gSocketFD, &expected, -1)) {
        close(fd);
        os_log(gLog, "IPC: Peer verloren (errno=%d) — reconnect folgt", errno);
    }
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
    pthread_mutex_lock(&gStateMutex);
    if (gPlugInRefCount > 0) {
        gPlugInRefCount -= 1;
    }
    ULONG result = gPlugInRefCount;
    pthread_mutex_unlock(&gStateMutex);
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
    gHostTicksPerFrame   = (1.0e9 / gSampleRate) / nanosPerTick;

    /* IPC-Connector starten — Verbindung wird im Hintergrund gehalten. */
    ipc_start();

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
    if (newRate == 44100.0 || newRate == 48000.0 || newRate == 96000.0) {
        pthread_mutex_lock(&gStateMutex);
        gSampleRate = newRate;
        struct mach_timebase_info tb;
        mach_timebase_info(&tb);
        Float64 nanosPerTick = (Float64)tb.numer / (Float64)tb.denom;
        gHostTicksPerFrame   = (1.0e9 / gSampleRate) / nanosPerTick;
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
            size = 3 * sizeof(AudioValueRange);
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
        case kAudioDevicePropertyIcon:
            size = sizeof(CFURLRef);
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
            size = 3 * sizeof(AudioStreamRangedDescription);
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

        /* 'ltnc' — gemeinsam fuer Device und Stream (gleicher FourCC). */
        case kAudioDevicePropertyLatency:
            WRITE_SCALAR(UInt32, 0);
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
            if (inDataSize < 3 * sizeof(AudioValueRange))
                return kAudioHardwareBadPropertySizeError;
            AudioValueRange *ranges = (AudioValueRange *)outData;
            ranges[0].mMinimum = 44100.0; ranges[0].mMaximum = 44100.0;
            ranges[1].mMinimum = 48000.0; ranges[1].mMaximum = 48000.0;
            ranges[2].mMinimum = 96000.0; ranges[2].mMaximum = 96000.0;
            written = 3 * sizeof(AudioValueRange);
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
            if (inDataSize < 3 * sizeof(AudioStreamRangedDescription))
                return kAudioHardwareBadPropertySizeError;
            AudioStreamRangedDescription *d =
                (AudioStreamRangedDescription *)outData;
            const Float64 rates[3] = { 44100.0, 48000.0, 96000.0 };
            for (int i = 0; i < 3; i++) {
                FillASBD(&d[i].mFormat, rates[i]);
                d[i].mSampleRateRange.mMinimum = rates[i];
                d[i].mSampleRateRange.mMaximum = rates[i];
            }
            written = 3 * sizeof(AudioStreamRangedDescription);
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
            pthread_mutex_lock(&gStateMutex);
            WRITE_SCALAR(Float32, gVolume);
            pthread_mutex_unlock(&gStateMutex);
            break;

        case kAudioLevelControlPropertyDecibelValue: {
            if (inObjectID != kObjectID_Volume_Output) return kAudioHardwareUnknownPropertyError;
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            Float32 v = gVolume;
            pthread_mutex_unlock(&gStateMutex);
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
            pthread_mutex_lock(&gStateMutex);
            WRITE_SCALAR(UInt32, gMute ? 1u : 0u);
            pthread_mutex_unlock(&gStateMutex);
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
            Float64 req = *((const Float64 *)inData);
            if (req != 44100.0 && req != 48000.0 && req != 96000.0) {
                return kAudioHardwareIllegalOperationError;
            }
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
            /* Nur Float32-Stereo wird akzeptiert; Rate per Config-Change. */
            if (fmt->mFormatID != kAudioFormatLinearPCM ||
                fmt->mChannelsPerFrame != kChannelsPerFrame ||
                fmt->mBitsPerChannel != kBitsPerChannel) {
                return kAudioHardwareIllegalOperationError;
            }
            if (fmt->mSampleRate != 44100.0 &&
                fmt->mSampleRate != 48000.0 &&
                fmt->mSampleRate != 96000.0) {
                return kAudioHardwareIllegalOperationError;
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
            pthread_mutex_lock(&gStateMutex);
            gVolume = v;
            pthread_mutex_unlock(&gStateMutex);
            return kAudioHardwareNoError;
        }

        case kAudioLevelControlPropertyDecibelValue: {
            if (inObjectID != kObjectID_Volume_Output)
                return kAudioHardwareUnknownPropertyError;
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 db = *((const Float32 *)inData);
            if (db < -96.0f) db = -96.0f;
            if (db >  0.0f)  db =  0.0f;
            pthread_mutex_lock(&gStateMutex);
            gVolume = (db / 96.0f) + 1.0f;
            pthread_mutex_unlock(&gStateMutex);
            return kAudioHardwareNoError;
        }

        case kAudioBooleanControlPropertyValue: {
            if (inObjectID != kObjectID_Mute_Output)
                return kAudioHardwareUnknownPropertyError;
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex);
            gMute = (*((const UInt32 *)inData) != 0);
            pthread_mutex_unlock(&gStateMutex);
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
        /* Erster Client startet die Uhr. */
        gAnchorHostTime = mach_absolute_time();
        atomic_store(&gNumberTimeStamps, 0);
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
     * Modell einer freilaufenden Uhr: alle kZeroTimeStampPeriod Frames
     * ein neuer Anker. Da das Device virtuell ist, leiten wir die
     * verstrichene Zeit aus der Host-Clock ab.
     */
    UInt64 now      = mach_absolute_time();
    UInt64 anchor   = gAnchorHostTime;
    Float64 ticksPerFrame;

    pthread_mutex_lock(&gStateMutex);
    ticksPerFrame = gHostTicksPerFrame;
    pthread_mutex_unlock(&gStateMutex);

    if (ticksPerFrame <= 0.0) {
        ticksPerFrame = 1.0;
    }

    Float64 elapsedFrames = (Float64)(now - anchor) / ticksPerFrame;
    UInt64  period        = kZeroTimeStampPeriod;
    UInt64  completed     = (UInt64)(elapsedFrames / (Float64)period);

    *outSampleTime = (Float64)(completed * period);
    *outHostTime   = anchor + (UInt64)((Float64)(completed * period) * ticksPerFrame);
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

        /* Mute beruecksichtigen: stilles Signal trotzdem als Frame senden,
         * damit die Python-Engine ihren Takt behaelt. Volume wird in der
         * Engine angewandt, hier nur Mute-Gate. */
        if (atomic_load_explicit(&gDeviceIsRunning, memory_order_relaxed)) {
            /* gMute wird ohne Lock gelesen — ein bool, Tearing unkritisch. */
            if (gMute) {
                /* In-Place: Puffer ist ohnehin "unser"; Stille rausschicken
                 * wuerde einen Scratch-Buffer brauchen -> wir senden den
                 * Originalpuffer trotzdem, Mute betrifft nur lokale Wiedergabe.
                 * Da dieses Device virtuell ist, gibt es keine lokale
                 * Wiedergabe; Mute wird daher in der Engine ausgewertet. */
            }
            ipc_send_rt(ioMainBuffer, byteCount);
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
    ipc_stop();
}
