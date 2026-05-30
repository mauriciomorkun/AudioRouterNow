"""
audio_device_control.py — Setzt das macOS Standard-Ausgabegeraet via CoreAudio API.

Verwendet ctypes direkt statt AppleScript (funktioniert auf allen macOS-Versionen
einschliesslich macOS 26+, wo 'sound preferences' nicht mehr unterstuetzt wird).
"""

import ctypes
import logging
import threading
from typing import Optional

logger = logging.getLogger(__name__)

# CoreAudio Konstanten
_kAudioObjectSystemObject               = 1
_kAudioHardwarePropertyDevices          = 0x64657623  # 'dev#'
_kAudioObjectPropertyName               = 0x6C6E616D  # 'lnam'
_kAudioHardwarePropertyDefaultOutputDevice       = 0x644F7574  # 'dOut'
_kAudioHardwarePropertyDefaultSystemOutputDevice = 0x734F7574  # 'sOut'
_kAudioObjectPropertyScopeGlobal        = 0x676C6F62  # 'glob'
_kAudioObjectPropertyScopeOutput        = 0x6F757470  # 'outp'
_kAudioObjectPropertyElementMain        = 0
_kCFStringEncodingUTF8                  = 0x08000100
# Volume / Mute
_kAudioHardwareServiceDeviceProperty_VirtualMainVolume = 0x766D766C  # 'vmvl'
_kAudioDevicePropertyMute               = 0x6D757465  # 'mute'


class _AudioObjectPropertyAddress(ctypes.Structure):
    _fields_ = [
        ("mSelector", ctypes.c_uint32),
        ("mScope",    ctypes.c_uint32),
        ("mElement",  ctypes.c_uint32),
    ]


# --------------------------------------------------------------------------
# Keep-Alive IOProc — hält das virtuelle Device dauerhaft im Running-Zustand
# --------------------------------------------------------------------------

# IOProc-Callback-Typ (AudioDeviceIOProc)
# OSStatus callback(AudioDeviceID, AudioTimeStamp*, AudioBufferList*,
#                   AudioTimeStamp*, AudioBufferList*, AudioTimeStamp*, void*)
_AudioDeviceIOProc_TYPE = ctypes.CFUNCTYPE(
    ctypes.c_int32,   # OSStatus return
    ctypes.c_uint32,  # AudioDeviceID inDevice
    ctypes.c_void_p,  # const AudioTimeStamp *inNow
    ctypes.c_void_p,  # const AudioBufferList *inInputData
    ctypes.c_void_p,  # const AudioTimeStamp *inInputTime
    ctypes.c_void_p,  # AudioBufferList *outOutputData
    ctypes.c_void_p,  # const AudioTimeStamp *inOutputTime
    ctypes.c_void_p,  # void *inClientData
)


def _noop_ioproc(dev_id, now, in_data, in_time, out_data, out_time, client):
    """No-Op IOProc — hält das virtuelle Device im Running-Zustand."""
    return 0  # kAudioHardwareNoError


# WICHTIG: Modulglobal halten — ctypes-Callbacks werden vom GC gesammelt,
# wenn keine Python-Referenz mehr existiert → Crash im RT-Thread des Drivers.
_NOOP_CB = _AudioDeviceIOProc_TYPE(_noop_ioproc)

# Zustand des Keep-Alive IOProc (modulglobal für GC-Schutz und Idempotenz)
_keepalive_lock    = threading.Lock()
_keepalive_proc_id = ctypes.c_void_p(0)
_keepalive_dev_id: Optional[int] = None


def _load_frameworks():
    CA = ctypes.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
    CF = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

    CF.CFStringGetCString.argtypes = [
        ctypes.c_void_p,  # CFStringRef
        ctypes.c_char_p,  # buffer
        ctypes.c_int64,   # bufferSize
        ctypes.c_uint32,  # encoding
    ]
    CF.CFStringGetCString.restype = ctypes.c_bool
    CF.CFRelease.argtypes = [ctypes.c_void_p]
    CF.CFRelease.restype  = None

    return CA, CF


def _get_default_output_device_id() -> int:
    """Gibt die CoreAudio Device-ID des Standard-Ausgabegeraets zurueck, oder 0 bei Fehler."""
    try:
        CA, _ = _load_frameworks()
        addr = _AudioObjectPropertyAddress(
            _kAudioHardwarePropertyDefaultOutputDevice,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        dev_id = ctypes.c_uint32(0)
        sz = ctypes.c_uint32(4)
        CA.AudioObjectGetPropertyData(
            ctypes.c_uint32(_kAudioObjectSystemObject),
            ctypes.byref(addr),
            ctypes.c_uint32(0), None,
            ctypes.byref(sz),
            ctypes.byref(dev_id),
        )
        return int(dev_id.value)
    except Exception:
        return 0


def get_default_output_volume() -> float:
    """
    Liest die aktuelle Systemlautstaerke (0.0–1.0) des Standard-Ausgabegeraets
    via kAudioHardwareServiceDeviceProperty_VirtualMainVolume.

    Gibt 1.0 zurueck bei Fehler (fail-open: kein ungewolltes Muting).
    """
    try:
        CA, _ = _load_frameworks()
        dev_id = _get_default_output_device_id()
        if dev_id == 0:
            return 1.0
        addr = _AudioObjectPropertyAddress(
            _kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            _kAudioObjectPropertyScopeOutput,
            _kAudioObjectPropertyElementMain,
        )
        vol = ctypes.c_float(1.0)
        sz  = ctypes.c_uint32(4)
        ret = CA.AudioObjectGetPropertyData(
            ctypes.c_uint32(dev_id),
            ctypes.byref(addr),
            ctypes.c_uint32(0), None,
            ctypes.byref(sz),
            ctypes.byref(vol),
        )
        if ret != 0:
            return 1.0
        return max(0.0, min(1.0, float(vol.value)))
    except Exception:
        return 1.0


def get_default_output_muted() -> bool:
    """
    Gibt True zurueck wenn das Standard-Ausgabegeraet gemuted ist.
    """
    try:
        CA, _ = _load_frameworks()
        dev_id = _get_default_output_device_id()
        if dev_id == 0:
            return False
        addr = _AudioObjectPropertyAddress(
            _kAudioDevicePropertyMute,
            _kAudioObjectPropertyScopeOutput,
            _kAudioObjectPropertyElementMain,
        )
        muted = ctypes.c_uint32(0)
        sz    = ctypes.c_uint32(4)
        CA.AudioObjectGetPropertyData(
            ctypes.c_uint32(dev_id),
            ctypes.byref(addr),
            ctypes.c_uint32(0), None,
            ctypes.byref(sz),
            ctypes.byref(muted),
        )
        return bool(muted.value)
    except Exception:
        return False


def set_default_output_device(device_name: str) -> tuple[bool, str]:
    """
    Setzt das macOS Standard-Ausgabegeraet via CoreAudio API.

    Args:
        device_name: Name des Ausgabegeraets (z.B. "Audio Router")

    Returns:
        (True, "")           bei Erfolg
        (False, Fehlermeldung) bei Fehler
    """
    try:
        CA, CF = _load_frameworks()

        # Alle Devices holen
        addr = _AudioObjectPropertyAddress(
            _kAudioHardwarePropertyDevices,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        sz = ctypes.c_uint32(0)
        CA.AudioObjectGetPropertyDataSize(
            ctypes.c_uint32(_kAudioObjectSystemObject),
            ctypes.byref(addr),
            ctypes.c_uint32(0), None,
            ctypes.byref(sz),
        )
        count = sz.value // 4
        if count == 0:
            return False, "Keine Audio-Devices in CoreAudio gefunden."

        ids = (ctypes.c_uint32 * count)()
        CA.AudioObjectGetPropertyData(
            ctypes.c_uint32(_kAudioObjectSystemObject),
            ctypes.byref(addr),
            ctypes.c_uint32(0), None,
            ctypes.byref(sz),
            ids,
        )

        # Device nach Name suchen
        name_addr = _AudioObjectPropertyAddress(
            _kAudioObjectPropertyName,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )

        target_id: Optional[int] = None
        for dev_id in ids:
            name_sz = ctypes.c_uint32(ctypes.sizeof(ctypes.c_void_p))
            cf_str  = ctypes.c_void_p(0)
            if CA.AudioObjectGetPropertyData(
                ctypes.c_uint32(dev_id),
                ctypes.byref(name_addr),
                ctypes.c_uint32(0), None,
                ctypes.byref(name_sz),
                ctypes.byref(cf_str),
            ) != 0:
                continue
            if not cf_str.value:
                continue

            buf = ctypes.create_string_buffer(512)
            CF.CFStringGetCString(cf_str, buf, 512, _kCFStringEncodingUTF8)
            CF.CFRelease(cf_str)
            name = buf.value.decode("utf-8", errors="replace")

            if name == device_name:
                target_id = int(dev_id)
                break

        if target_id is None:
            return False, (
                f"'{device_name}' nicht in CoreAudio gefunden.\n"
                "Ist der HAL-Treiber installiert und aktiv?\n"
                "Starte AudioRouterNow neu und versuche es erneut."
            )

        # Als Standard-Ausgabe setzen
        set_addr = _AudioObjectPropertyAddress(
            _kAudioHardwarePropertyDefaultOutputDevice,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        out_id = ctypes.c_uint32(target_id)
        status = CA.AudioObjectSetPropertyData(
            ctypes.c_uint32(_kAudioObjectSystemObject),
            ctypes.byref(set_addr),
            ctypes.c_uint32(0), None,
            ctypes.c_uint32(4),
            ctypes.byref(out_id),
        )

        if status == 0:
            logger.info(f"Standard-Ausgabe auf '{device_name}' (ID {target_id}) gesetzt")
            return True, ""
        else:
            return False, f"CoreAudio OSStatus {status}"

    except Exception as e:
        logger.error(f"set_default_output_device Fehler: {e}")
        return False, str(e)


def set_default_system_output_device(device_name: str) -> tuple[bool, str]:
    """
    Setzt das macOS Default System Output (kAudioHardwarePropertyDefaultSystemOutputDevice).
    Keyboard-Volume-Tasten folgen dem System Output — damit diese auf
    'Audio Router' wirken (und nicht auf das physische Interface), muss
    Audio Router auch als System Output gesetzt sein.
    """
    try:
        CA, CF = _load_frameworks()

        addr = _AudioObjectPropertyAddress(
            _kAudioHardwarePropertyDevices,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        sz = ctypes.c_uint32(0)
        CA.AudioObjectGetPropertyDataSize(
            ctypes.c_uint32(_kAudioObjectSystemObject),
            ctypes.byref(addr), ctypes.c_uint32(0), None, ctypes.byref(sz),
        )
        count = sz.value // 4
        if count == 0:
            return False, "Keine Audio-Devices gefunden."

        ids = (ctypes.c_uint32 * count)()
        CA.AudioObjectGetPropertyData(
            ctypes.c_uint32(_kAudioObjectSystemObject),
            ctypes.byref(addr), ctypes.c_uint32(0), None,
            ctypes.byref(sz), ids,
        )

        name_addr = _AudioObjectPropertyAddress(
            _kAudioObjectPropertyName,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        target_id = None
        for dev_id in ids:
            name_sz = ctypes.c_uint32(ctypes.sizeof(ctypes.c_void_p))
            cf_str  = ctypes.c_void_p(0)
            if CA.AudioObjectGetPropertyData(
                ctypes.c_uint32(dev_id), ctypes.byref(name_addr),
                ctypes.c_uint32(0), None, ctypes.byref(name_sz), ctypes.byref(cf_str),
            ) != 0 or not cf_str.value:
                continue
            buf = ctypes.create_string_buffer(512)
            CF.CFStringGetCString(cf_str, buf, 512, _kCFStringEncodingUTF8)
            CF.CFRelease(cf_str)
            if buf.value.decode("utf-8", errors="replace") == device_name:
                target_id = int(dev_id)
                break

        if target_id is None:
            return False, f"'{device_name}' nicht gefunden."

        set_addr = _AudioObjectPropertyAddress(
            _kAudioHardwarePropertyDefaultSystemOutputDevice,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        out_id = ctypes.c_uint32(target_id)
        status = CA.AudioObjectSetPropertyData(
            ctypes.c_uint32(_kAudioObjectSystemObject),
            ctypes.byref(set_addr), ctypes.c_uint32(0), None,
            ctypes.c_uint32(4), ctypes.byref(out_id),
        )
        if status == 0:
            logger.info(f"System Output auf '{device_name}' (ID {target_id}) gesetzt")
            return True, ""
        return False, f"CoreAudio OSStatus {status}"

    except Exception as e:
        logger.error(f"set_default_system_output_device Fehler: {e}")
        return False, str(e)


# Unterstützte Sample-Raten für Audio Router
SUPPORTED_SAMPLE_RATES = [44100, 48000, 88200, 96000, 176400, 192000]

# CoreAudio Konstanten fuer Sample-Rate-Zugriff
_kAudioDevicePropertyNominalSampleRate          = 0x6E737274  # 'nsrt'
_kAudioDevicePropertyAvailableNominalSampleRates = 0x6E737272  # 'nsrr'
_kAudioDevicePropertyDeviceUID                  = 0x75696420  # 'uid '


def _get_all_device_ids() -> list[int]:
    """Gibt alle CoreAudio Device-IDs zurueck."""
    try:
        CA, _ = _load_frameworks()
        addr = _AudioObjectPropertyAddress(
            _kAudioHardwarePropertyDevices,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        sz = ctypes.c_uint32(0)
        CA.AudioObjectGetPropertyDataSize(
            ctypes.c_uint32(_kAudioObjectSystemObject),
            ctypes.byref(addr),
            ctypes.c_uint32(0), None,
            ctypes.byref(sz),
        )
        count = sz.value // 4
        if count == 0:
            return []
        ids = (ctypes.c_uint32 * count)()
        CA.AudioObjectGetPropertyData(
            ctypes.c_uint32(_kAudioObjectSystemObject),
            ctypes.byref(addr),
            ctypes.c_uint32(0), None,
            ctypes.byref(sz),
            ids,
        )
        return [int(i) for i in ids]
    except Exception:
        return []


def _get_device_name(dev_id: int) -> str | None:
    """Gibt den Namen eines CoreAudio Devices zurueck."""
    try:
        CA, CF = _load_frameworks()
        addr = _AudioObjectPropertyAddress(
            _kAudioObjectPropertyName,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        name_sz = ctypes.c_uint32(ctypes.sizeof(ctypes.c_void_p))
        cf_str = ctypes.c_void_p(0)
        if CA.AudioObjectGetPropertyData(
            ctypes.c_uint32(dev_id),
            ctypes.byref(addr),
            ctypes.c_uint32(0), None,
            ctypes.byref(name_sz),
            ctypes.byref(cf_str),
        ) != 0 or not cf_str.value:
            return None
        buf = ctypes.create_string_buffer(512)
        CF.CFStringGetCString(cf_str, buf, 512, _kCFStringEncodingUTF8)
        CF.CFRelease(cf_str)
        return buf.value.decode("utf-8", errors="replace")
    except Exception:
        return None


def _find_audio_router_device_id() -> int | None:
    """Gibt die CoreAudio Device-ID des 'Audio Router' virtuellen Devices zurueck."""
    for dev_id in _get_all_device_ids():
        name = _get_device_name(dev_id)
        if name and "Audio Router" in name:
            return dev_id
    return None


def get_device_supported_sample_rates(device_uid: str) -> list[int]:
    """
    Gibt die unterstuetzten Sample-Raten eines Devices anhand seiner UID zurueck.
    Gibt nur Raten zurueck die in SUPPORTED_SAMPLE_RATES enthalten sind.
    Fallback: [48000] bei Fehler.
    """
    try:
        CA, _ = _load_frameworks()

        # Device-ID anhand UID suchen
        dev_id_found: int | None = None
        uid_addr = _AudioObjectPropertyAddress(
            _kAudioDevicePropertyDeviceUID,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        for did in _get_all_device_ids():
            uid_sz = ctypes.c_uint32(ctypes.sizeof(ctypes.c_void_p))
            cf_uid = ctypes.c_void_p(0)
            if CA.AudioObjectGetPropertyData(
                ctypes.c_uint32(did),
                ctypes.byref(uid_addr),
                ctypes.c_uint32(0), None,
                ctypes.byref(uid_sz),
                ctypes.byref(cf_uid),
            ) != 0 or not cf_uid.value:
                continue
            CF = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
            CF.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int64, ctypes.c_uint32]
            CF.CFStringGetCString.restype = ctypes.c_bool
            CF.CFRelease.argtypes = [ctypes.c_void_p]
            CF.CFRelease.restype = None
            buf = ctypes.create_string_buffer(512)
            CF.CFStringGetCString(cf_uid, buf, 512, _kCFStringEncodingUTF8)
            CF.CFRelease(cf_uid)
            uid_str = buf.value.decode("utf-8", errors="replace")
            if uid_str == device_uid:
                dev_id_found = int(did)
                break

        if dev_id_found is None:
            return [48000]

        # kAudioDevicePropertyAvailableNominalSampleRates abfragen
        # AudioValueRange = 2x Float64 = 16 Bytes
        sr_addr = _AudioObjectPropertyAddress(
            _kAudioDevicePropertyAvailableNominalSampleRates,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        sz = ctypes.c_uint32(0)
        if CA.AudioObjectGetPropertyDataSize(
            ctypes.c_uint32(dev_id_found),
            ctypes.byref(sr_addr),
            ctypes.c_uint32(0), None,
            ctypes.byref(sz),
        ) != 0 or sz.value == 0:
            return [48000]

        n_ranges = sz.value // 16  # 2 x Float64 = 16 Bytes pro AudioValueRange
        ranges = (ctypes.c_double * (n_ranges * 2))()
        if CA.AudioObjectGetPropertyData(
            ctypes.c_uint32(dev_id_found),
            ctypes.byref(sr_addr),
            ctypes.c_uint32(0), None,
            ctypes.byref(sz),
            ranges,
        ) != 0:
            return [48000]

        rates: list[int] = []
        for i in range(n_ranges):
            lo = int(ranges[i * 2])
            hi = int(ranges[i * 2 + 1])
            for r in SUPPORTED_SAMPLE_RATES:
                if lo <= r <= hi and r not in rates:
                    rates.append(r)

        return sorted(rates) if rates else [48000]

    except Exception as e:
        logger.debug(f"get_device_supported_sample_rates Fehler: {e}")
        return [48000]


def start_audio_router_device() -> bool:
    """
    Ruft AudioDeviceStart() direkt auf dem 'Audio Router' Device auf.

    Das triggert ARN_StartIO im HAL-Driver → gDeviceIsRunning=1 →
    Driver beginnt Frames in den Ring zu schreiben.

    Dies ist nötig auf macOS 26+ wo coreaudiod StartIO nicht mehr
    automatisch aufruft wenn das virtuelle Device als Default gesetzt wird.
    Musik-Apps öffnen ihren Audio-Stream erst wenn StartIO bereits aktiv ist.

    Gibt True bei Erfolg zurück.
    """
    try:
        CA, _ = _load_frameworks()

        device_id = _find_audio_router_device_id()
        if device_id is None:
            logger.warning("start_audio_router_device: Audio Router Device nicht gefunden")
            return False

        # AudioDeviceStart(inDevice, inProcID=NULL)
        # NULL als IOProc-ID startet das Device ohne eigenen IOProc —
        # triggert aber trotzdem ARN_StartIO im HAL-Plugin.
        CA.AudioDeviceStart.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        CA.AudioDeviceStart.restype  = ctypes.c_int32

        status = CA.AudioDeviceStart(ctypes.c_uint32(device_id), None)
        if status == 0:
            logger.info(f"AudioDeviceStart OK — Audio Router (ID {device_id}) gestartet")
            return True
        else:
            logger.warning(f"AudioDeviceStart fehlgeschlagen (OSStatus {status})")
            return False

    except Exception as exc:
        logger.error(f"start_audio_router_device Fehler: {exc}")
        return False


def is_audio_router_default() -> bool:
    """
    Gibt True zurueck, wenn das aktuelle System-Standard-Ausgabegeraet
    das 'Audio Router' virtuelle Device ist.

    Fail-closed: Bei Fehler oder wenn das Device nicht gefunden wird → False.
    """
    try:
        default_id = _get_default_output_device_id()
        if default_id == 0:
            return False
        router_id = _find_audio_router_device_id()
        if router_id is None:
            return False
        return int(default_id) == int(router_id)
    except Exception:
        return False


def get_audio_router_sample_rate() -> int:
    """
    Gibt die aktuelle Sample-Rate des Audio Router Devices zurueck.
    Fallback: 48000 bei Fehler.
    """
    try:
        CA, _ = _load_frameworks()
        dev_id = _find_audio_router_device_id()
        if dev_id is None:
            return 48000
        addr = _AudioObjectPropertyAddress(
            _kAudioDevicePropertyNominalSampleRate,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )
        rate = ctypes.c_double(48000.0)
        sz = ctypes.c_uint32(8)
        if CA.AudioObjectGetPropertyData(
            ctypes.c_uint32(dev_id),
            ctypes.byref(addr),
            ctypes.c_uint32(0), None,
            ctypes.byref(sz),
            ctypes.byref(rate),
        ) != 0:
            return 48000
        return int(rate.value)
    except Exception as e:
        logger.debug(f"get_audio_router_sample_rate Fehler: {e}")
        return 48000


def ensure_router_keepalive() -> bool:
    """
    Erstellt einen persistenten No-Op-IOProc auf dem 'Audio Router' Device
    und startet ihn via AudioDeviceStart(device, procID).

    Dadurch bleibt gDeviceIsRunning=1 dauerhaft — unabhängig davon ob
    Apple Music, Spotify o.ä. gerade einen eigenen IOProc hält.

    Idempotent: Mehrfachaufrufe sind sicher (prüft ob bereits aktiv).
    Gibt True zurück wenn Keep-Alive aktiv oder erfolgreich gestartet.

    WICHTIG: _NOOP_CB muss modulglobal leben (kein GC im RT-Thread).
    """
    global _keepalive_proc_id, _keepalive_dev_id

    with _keepalive_lock:
        # Bereits aktiv und gleiches Device?
        if _keepalive_proc_id.value and _keepalive_proc_id.value != 0:
            return True

        try:
            CA, _ = _load_frameworks()

            device_id = _find_audio_router_device_id()
            if device_id is None:
                logger.warning("ensure_router_keepalive: Audio Router Device nicht gefunden")
                return False

            # AudioDeviceCreateIOProcID(inDevice, inProc, inClientData, outIOProcID)
            CA.AudioDeviceCreateIOProcID.argtypes = [
                ctypes.c_uint32,               # AudioDeviceID
                ctypes.c_void_p,               # AudioDeviceIOProc (Funktionszeiger)
                ctypes.c_void_p,               # void *inClientData
                ctypes.POINTER(ctypes.c_void_p),  # AudioDeviceIOProcID *outIOProcID
            ]
            CA.AudioDeviceCreateIOProcID.restype = ctypes.c_int32

            proc_id = ctypes.c_void_p(0)
            status = CA.AudioDeviceCreateIOProcID(
                ctypes.c_uint32(device_id),
                _NOOP_CB,
                None,
                ctypes.byref(proc_id),
            )
            if status != 0:
                logger.warning(
                    "ensure_router_keepalive: AudioDeviceCreateIOProcID OSStatus %d", status
                )
                return False

            # AudioDeviceStart(inDevice, inProcID) — mit echtem ProcID (nicht NULL)
            CA.AudioDeviceStart.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
            CA.AudioDeviceStart.restype  = ctypes.c_int32

            status = CA.AudioDeviceStart(ctypes.c_uint32(device_id), proc_id)
            if status != 0:
                logger.warning(
                    "ensure_router_keepalive: AudioDeviceStart OSStatus %d", status
                )
                # Proc-ID aufräumen
                CA.AudioDeviceDestroyIOProcID.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
                CA.AudioDeviceDestroyIOProcID.restype  = ctypes.c_int32
                CA.AudioDeviceDestroyIOProcID(ctypes.c_uint32(device_id), proc_id)
                return False

            _keepalive_proc_id = proc_id
            _keepalive_dev_id  = device_id
            logger.info(
                "ensure_router_keepalive: Keep-Alive IOProc gestartet (Device ID %d)",
                device_id,
            )
            return True

        except Exception as exc:
            logger.error("ensure_router_keepalive Fehler: %s", exc)
            return False


def stop_router_keepalive() -> None:
    """
    Stoppt und entfernt den Keep-Alive-IOProc.

    Sollte bei App-Quit aufgerufen werden, damit kein verwaister IOProc
    in coreaudiod übrig bleibt.
    Idempotent: sicher bei Mehrfachaufruf.
    """
    global _keepalive_proc_id, _keepalive_dev_id

    with _keepalive_lock:
        if not _keepalive_proc_id.value or _keepalive_proc_id.value == 0:
            return
        if _keepalive_dev_id is None:
            return

        try:
            CA, _ = _load_frameworks()
            dev  = ctypes.c_uint32(_keepalive_dev_id)
            proc = _keepalive_proc_id

            CA.AudioDeviceStop.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
            CA.AudioDeviceStop.restype  = ctypes.c_int32
            CA.AudioDeviceDestroyIOProcID.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
            CA.AudioDeviceDestroyIOProcID.restype  = ctypes.c_int32

            CA.AudioDeviceStop(dev, proc)
            CA.AudioDeviceDestroyIOProcID(dev, proc)

            _keepalive_proc_id = ctypes.c_void_p(0)
            _keepalive_dev_id  = None
            logger.info("stop_router_keepalive: Keep-Alive IOProc gestoppt")

        except Exception as exc:
            logger.error("stop_router_keepalive Fehler: %s", exc)
