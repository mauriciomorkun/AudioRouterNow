"""
audio_device_control.py — Setzt das macOS Standard-Ausgabegeraet via CoreAudio API.

Verwendet ctypes direkt statt AppleScript (funktioniert auf allen macOS-Versionen
einschliesslich macOS 26+, wo 'sound preferences' nicht mehr unterstuetzt wird).
"""

import ctypes
import logging
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
_kAudioDevicePropertyVolumeScalar       = 0x766F6C6D  # 'volm' — Device-Level-Control
_kAudioDevicePropertyMute               = 0x6D757465  # 'mute'


class _AudioObjectPropertyAddress(ctypes.Structure):
    _fields_ = [
        ("mSelector", ctypes.c_uint32),
        ("mScope",    ctypes.c_uint32),
        ("mElement",  ctypes.c_uint32),
    ]


def _load_frameworks():
    """Laedt CoreAudio + CoreFoundation GENAU EINMAL und konfiguriert
    die benoetigten Funktions-Signaturen. Ergebnis wird in _CA/_CF gecacht
    (siehe Modul-Scope unten) — wiederholtes ctypes.CDLL() pro Aufruf
    ist teuer und unnoetig."""
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


# Frameworks GENAU EINMAL beim Import laden (P13). Alle Funktionen
# verwenden die Modul-globalen _CA / _CF statt bei jedem Aufruf neu zu laden.
_CA, _CF = _load_frameworks()


def _get_default_output_device_id() -> int:
    """Gibt die CoreAudio Device-ID des Standard-Ausgabegeraets zurueck, oder 0 bei Fehler."""
    try:
        CA, _ = _CA, _CF
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
    Liest die aktuelle Systemlautstaerke (0.0–1.0) des Standard-Ausgabegeraets.

    Probiert VirtualMainVolume ('vmvl') und faellt auf die Device-Level-Control-
    Scalar-Property ('volm') zurueck — Letztere funktioniert auf dem virtuellen
    Audio-Router-Device, wo 'vmvl' nicht unterstuetzt wird.

    Gibt 1.0 zurueck bei Fehler (fail-open: kein ungewolltes Muting).
    """
    try:
        CA, _ = _CA, _CF
        dev_id = _get_default_output_device_id()
        if dev_id == 0:
            return 1.0
        addr = _AudioObjectPropertyAddress(
            _volume_selector_for(dev_id),
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
        if ret == 0:
            return max(0.0, min(1.0, float(vol.value)))
        return 1.0
    except Exception:
        return 1.0


def get_default_output_muted() -> bool:
    """
    Gibt True zurueck wenn das Standard-Ausgabegeraet gemuted ist.
    """
    try:
        CA, _ = _CA, _CF
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
        CA, CF = _CA, _CF

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
            return False, "No audio devices found in CoreAudio."

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
                f"'{device_name}' not found in CoreAudio.\n"
                "Is the HAL driver installed and active?\n"
                "Please restart AudioRouterNow and try again."
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
        CA, CF = _CA, _CF

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
            return False, "No audio devices found."

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
            return False, f"'{device_name}' not found."

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
        CA, _ = _CA, _CF
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
        CA, CF = _CA, _CF
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
        CA, CF = _CA, _CF

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
        CA, _ = _CA, _CF

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
        CA, _ = _CA, _CF
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


# ──────────────────────────────────────────────────────────────────────────
# P1: Event-driven Volume — Property-Listener statt osascript-Polling.
# ──────────────────────────────────────────────────────────────────────────

# CFUNCTYPE-Signatur des CoreAudio Property-Listeners:
#   OSStatus listener(AudioObjectID, UInt32 nAddresses,
#                     const AudioObjectPropertyAddress*, void* clientData)
_AOPropertyListenerProc = ctypes.CFUNCTYPE(
    ctypes.c_int32,        # OSStatus
    ctypes.c_uint32,       # AudioObjectID
    ctypes.c_uint32,       # inNumberAddresses
    ctypes.c_void_p,       # const AudioObjectPropertyAddress*
    ctypes.c_void_p,       # void* clientData
)

# WICHTIG (GC-Schutz): Der CFUNCTYPE-Callback MUSS modul-global referenziert
# bleiben, sonst sammelt der Python-GC ihn ein, waehrend CoreAudio noch einen
# Funktionspointer haelt → Crash. Ebenso die Adresse, auf der registriert wurde.
_vol_listener = None                 # type: ignore[assignment]
_vol_listener_device_id: int = 0
_vol_listener_selector: int = 0      # Property-Selector, auf dem registriert wurde
_vol_listener_user_cb = None         # vom Aufrufer gesetzter Python-Callback

# _pre_mute_volume: zuletzt bekannte Lautstaerke vor dem Muten — fuer Restore.
_pre_mute_volume: float = 1.0

_CA.AudioObjectSetPropertyData.argtypes = [
    ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p,
    ctypes.c_uint32, ctypes.c_void_p,
]
_CA.AudioObjectSetPropertyData.restype = ctypes.c_int32
_CA.AudioObjectHasProperty.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
_CA.AudioObjectHasProperty.restype = ctypes.c_bool


def _volume_selector_for(dev_id: int) -> int:
    """P1: Liefert den Volume-Property-Selector, den `dev_id` tatsaechlich
    unterstuetzt: 'vmvl' (HW-Geraete) oder 'volm' (virtuelles Audio-Router-
    Device). Per AudioObjectHasProperty bestimmt — verhindert, dass wir auf
    eine vom Device nicht implementierte Property setzen/registrieren."""
    for selector in (_kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                     _kAudioDevicePropertyVolumeScalar):
        addr = _AudioObjectPropertyAddress(
            selector,
            _kAudioObjectPropertyScopeOutput,
            _kAudioObjectPropertyElementMain,
        )
        try:
            if _CA.AudioObjectHasProperty(ctypes.c_uint32(dev_id), ctypes.byref(addr)):
                return selector
        except Exception:
            pass
    # Fallback: VolumeScalar (auf dem virtuellen Device der funktionierende Weg).
    return _kAudioDevicePropertyVolumeScalar
_CA.AudioObjectAddPropertyListener.argtypes = [
    ctypes.c_uint32, ctypes.c_void_p, _AOPropertyListenerProc, ctypes.c_void_p,
]
_CA.AudioObjectAddPropertyListener.restype = ctypes.c_int32
_CA.AudioObjectRemovePropertyListener.argtypes = [
    ctypes.c_uint32, ctypes.c_void_p, _AOPropertyListenerProc, ctypes.c_void_p,
]
_CA.AudioObjectRemovePropertyListener.restype = ctypes.c_int32


def set_default_output_volume(volume: float) -> bool:
    """P1: Setzt die Systemlautstaerke (0.0–1.0) des Standard-Ausgabegeraets
    direkt via CoreAudio (kein osascript-Subprozess mehr).

    Gibt True bei Erfolg zurueck."""
    try:
        dev_id = _get_default_output_device_id()
        if dev_id == 0:
            return False
        v = max(0.0, min(1.0, float(volume)))
        vol = ctypes.c_float(v)
        # Den vom Device tatsaechlich unterstuetzten Selector verwenden
        # ('vmvl' auf HW, 'volm' auf dem virtuellen Audio-Router-Device).
        addr = _AudioObjectPropertyAddress(
            _volume_selector_for(dev_id),
            _kAudioObjectPropertyScopeOutput,
            _kAudioObjectPropertyElementMain,
        )
        status = _CA.AudioObjectSetPropertyData(
            ctypes.c_uint32(dev_id),
            ctypes.byref(addr),
            ctypes.c_uint32(0), None,
            ctypes.c_uint32(4),
            ctypes.byref(vol),
        )
        if status == 0 and v > 0.0:
            # Nicht-Null-Lautstaerke fuer spaeteres Unmute merken.
            global _pre_mute_volume
            _pre_mute_volume = v
        return status == 0
    except Exception as e:
        logger.debug(f"set_default_output_volume Fehler: {e}")
        return False


def set_muted(muted: bool) -> bool:
    """P1: Mutet/Unmutet das Standard-Ausgabegeraet direkt via CoreAudio.

    Bevorzugt die Mute-Property; faellt das Device darauf nicht ein, wird ueber
    die Lautstaerke gemutet (0.0) bzw. die zuvor gemerkte Lautstaerke
    wiederhergestellt (_pre_mute_volume). Gibt True bei Erfolg zurueck."""
    global _pre_mute_volume
    try:
        dev_id = _get_default_output_device_id()
        if dev_id == 0:
            return False

        if muted:
            # aktuelle (Nicht-Null-)Lautstaerke fuer Restore sichern
            cur = get_default_output_volume()
            if cur > 0.0:
                _pre_mute_volume = cur

        addr = _AudioObjectPropertyAddress(
            _kAudioDevicePropertyMute,
            _kAudioObjectPropertyScopeOutput,
            _kAudioObjectPropertyElementMain,
        )
        flag = ctypes.c_uint32(1 if muted else 0)
        status = _CA.AudioObjectSetPropertyData(
            ctypes.c_uint32(dev_id),
            ctypes.byref(addr),
            ctypes.c_uint32(0), None,
            ctypes.c_uint32(4),
            ctypes.byref(flag),
        )
        if status == 0:
            return True

        # Fallback: ueber die Lautstaerke muten/unmuten.
        if muted:
            return set_default_output_volume(0.0)
        return set_default_output_volume(_pre_mute_volume)
    except Exception as e:
        logger.debug(f"set_muted Fehler: {e}")
        return False


def register_volume_listener(callback) -> bool:
    """P1: Registriert einen CoreAudio Property-Listener auf
    kAudioDevicePropertyVirtualMainVolume des aktuellen Standard-Ausgabegeraets.

    `callback` ist ein argumentloses Python-Callable, das bei jeder
    Lautstaerke-Aenderung aufgerufen wird (auf einem CoreAudio-Thread — der
    Aufrufer muss thread-sicher reagieren). Ersetzt den frueheren osascript-
    Poll-Loop. Gibt True bei erfolgreicher Registrierung zurueck."""
    global _vol_listener, _vol_listener_device_id, _vol_listener_user_cb
    global _vol_listener_selector
    try:
        dev_id = _get_default_output_device_id()
        if dev_id == 0:
            return False

        # Vorherigen Listener (falls Device gewechselt) entfernen.
        unregister_volume_listener()

        _vol_listener_user_cb = callback

        def _trampoline(in_object_id, n_addresses, in_addresses, client_data):
            try:
                if _vol_listener_user_cb is not None:
                    _vol_listener_user_cb()
            except Exception:
                pass
            return 0  # noErr

        # GC-Schutz: Callback modul-global halten.
        _vol_listener = _AOPropertyListenerProc(_trampoline)

        # Auf der vom Device unterstuetzten Property registrieren ('vmvl' auf
        # HW, 'volm' auf dem virtuellen Audio-Router-Device).
        selector = _volume_selector_for(dev_id)
        addr = _AudioObjectPropertyAddress(
            selector,
            _kAudioObjectPropertyScopeOutput,
            _kAudioObjectPropertyElementMain,
        )
        status = _CA.AudioObjectAddPropertyListener(
            ctypes.c_uint32(dev_id),
            ctypes.byref(addr),
            _vol_listener,
            None,
        )
        if status == 0:
            _vol_listener_device_id = dev_id
            _vol_listener_selector = selector
            logger.info("Volume-Listener auf Device %d registriert (event-driven, sel=0x%X)",
                        dev_id, selector)
            return True

        # Registrierung fehlgeschlagen → State zuruecksetzen.
        _vol_listener = None
        _vol_listener_user_cb = None
        logger.warning("AudioObjectAddPropertyListener fehlgeschlagen (OSStatus %d)", status)
        return False
    except Exception as e:
        logger.debug(f"register_volume_listener Fehler: {e}")
        _vol_listener = None
        _vol_listener_user_cb = None
        return False


def unregister_volume_listener() -> None:
    """P1: Entfernt den zuvor registrierten Volume-Listener (falls vorhanden)."""
    global _vol_listener, _vol_listener_device_id, _vol_listener_user_cb
    global _vol_listener_selector
    if _vol_listener is None or _vol_listener_device_id == 0:
        return
    try:
        addr = _AudioObjectPropertyAddress(
            _vol_listener_selector or _kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            _kAudioObjectPropertyScopeOutput,
            _kAudioObjectPropertyElementMain,
        )
        _CA.AudioObjectRemovePropertyListener(
            ctypes.c_uint32(_vol_listener_device_id),
            ctypes.byref(addr),
            _vol_listener,
            None,
        )
    except Exception as e:
        logger.debug(f"unregister_volume_listener Fehler: {e}")
    finally:
        _vol_listener = None
        _vol_listener_device_id = 0
        _vol_listener_selector = 0
        _vol_listener_user_cb = None


# Keep-Alive wird ab v2.6 vom C-Helper verwaltet (keepalive_ioproc in AudioRouterNowHelper.c).
# Python-ctypes-Callbacks verursachen Stale-Pointer in coreaudiod nach Prozess-Exit.
# Diese Stubs bleiben für API-Kompatibilität.

def ensure_router_keepalive() -> bool:
    """Stub — Keep-Alive wird vom C-Helper (keepalive_ioproc) verwaltet."""
    logger.debug("ensure_router_keepalive: Stub — Keep-Alive in C-Helper")
    return True


def stop_router_keepalive() -> None:
    """Stub — Keep-Alive wird vom C-Helper beim Shutdown gestoppt."""
    logger.debug("stop_router_keepalive: Stub — Keep-Alive in C-Helper")
