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
_kAudioObjectSystemObject    = 1
_kAudioHardwarePropertyDevices          = 0x64657623  # 'dev#'
_kAudioObjectPropertyName               = 0x6C6E616D  # 'lnam'
_kAudioHardwarePropertyDefaultOutputDevice = 0x644F7574  # 'dOut'
_kAudioObjectPropertyScopeGlobal        = 0x676C6F62  # 'glob'
_kAudioObjectPropertyElementMain        = 0
_kCFStringEncodingUTF8                  = 0x08000100


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


def get_all_coreaudio_output_devices() -> list[dict]:
    """
    Gibt alle CoreAudio Output-Devices zurueck.
    Jeder Eintrag: {'id': int, 'name': str}
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

        name_addr = _AudioObjectPropertyAddress(
            _kAudioObjectPropertyName,
            _kAudioObjectPropertyScopeGlobal,
            _kAudioObjectPropertyElementMain,
        )

        # Output-Channels pruefen: kAudioDevicePropertyStreamConfiguration scope output
        out_scope_addr = _AudioObjectPropertyAddress(
            0x73636F70,  # 'scop' — kAudioDevicePropertyScopeOutput placeholder; we use output channels
            0x6F757470,  # 'outp' — kAudioObjectPropertyScopeOutput
            _kAudioObjectPropertyElementMain,
        )

        devices = []
        for dev_id in ids:
            name_sz = ctypes.c_uint32(ctypes.sizeof(ctypes.c_void_p))
            cf_str = ctypes.c_void_p(0)
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
            devices.append({"id": int(dev_id), "name": name})

        return devices

    except Exception as e:
        logger.error(f"get_all_coreaudio_output_devices Fehler: {e}")
        return []


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
