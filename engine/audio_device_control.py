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
_kAudioHardwarePropertyDefaultOutputDevice = 0x644F7574  # 'dOut'
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
