"""
DeviceManager — Verwaltet CoreAudio Output-Devices ohne sounddevice.

Implementiert via ctypes direkt gegen CoreAudio.framework.
Ersetzt die alte sounddevice-basierte Version (Phase 4: Python-Audio-Deps raus).

Aufgaben:
  - Listet alle Output-faehigen CoreAudio Devices auf (>=2 Output-Kanaele)
  - Filtert das eigene virtuelle "Audio Router" Device heraus
  - Erkennt Hot-plug via Polling
  - Stellt UID (statt Index) bereit — UID ist persistent ueber Reboot/Replug
"""

import ctypes
import logging
import threading
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional

logger = logging.getLogger(__name__)

# CoreAudio FourCC-Konstanten
_kAudioObjectSystemObject              = 1
_kAudioHardwarePropertyDevices         = 0x64657623  # 'dev#'
_kAudioObjectPropertyScopeGlobal       = 0x676C6F62  # 'glob'
_kAudioDevicePropertyScopeOutput       = 0x6F757470  # 'outp'
_kAudioObjectPropertyElementMain       = 0
_kAudioDevicePropertyDeviceUID         = 0x75696420  # 'uid '
_kAudioDevicePropertyDeviceNameCFString = 0x6C6E616D # 'lnam'
_kAudioDevicePropertyStreamConfiguration = 0x736C6179 # 'slay'
_kAudioDevicePropertyNominalSampleRate = 0x6E737274  # 'nsrt'
_kCFStringEncodingUTF8                 = 0x08000100

# Name unseres virtuellen Devices — wird ausgefiltert
VIRTUAL_DEVICE_NAME = "Audio Router"

# Polling-Intervall fuer Hot-plug
HOTPLUG_POLL_INTERVAL = 2.0


class _AudioObjectPropertyAddress(ctypes.Structure):
    _fields_ = [
        ("mSelector", ctypes.c_uint32),
        ("mScope",    ctypes.c_uint32),
        ("mElement",  ctypes.c_uint32),
    ]


class _AudioBuffer(ctypes.Structure):
    _fields_ = [
        ("mNumberChannels", ctypes.c_uint32),
        ("mDataByteSize",   ctypes.c_uint32),
        ("mData",           ctypes.c_void_p),
    ]


class _AudioBufferList(ctypes.Structure):
    # Wir lesen nur mNumberBuffers + ersten Buffer; fuer beliebige Anzahl
    # parsen wir manuell ueber den Rohpuffer.
    _fields_ = [
        ("mNumberBuffers", ctypes.c_uint32),
        ("mBuffers",       _AudioBuffer * 1),  # flex-array, real groesser
    ]


def _load_frameworks():
    CA = ctypes.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
    CF = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    CF.CFStringGetCString.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int64, ctypes.c_uint32
    ]
    CF.CFStringGetCString.restype = ctypes.c_bool
    CF.CFRelease.argtypes = [ctypes.c_void_p]
    CF.CFRelease.restype = None
    return CA, CF


# Frameworks einmal global laden
_CA, _CF = _load_frameworks()


@dataclass(frozen=True)
class AudioDevice:
    """Output-Device aus CoreAudio (Phase 4: ohne Index, mit UID)."""
    uid: str
    name: str
    max_output_channels: int
    default_samplerate: float

    # Backwards-Compat: alte Code-Pfade nutzen .index (jetzt = hash(uid))
    @property
    def index(self) -> int:
        return abs(hash(self.uid)) & 0x7FFFFFFF

    def __str__(self) -> str:
        return f"{self.name} ({self.max_output_channels}ch)"


def _get_string_property(dev_id: int, selector: int, scope: int = _kAudioObjectPropertyScopeGlobal) -> Optional[str]:
    addr = _AudioObjectPropertyAddress(selector, scope, _kAudioObjectPropertyElementMain)
    cf_str = ctypes.c_void_p(0)
    sz = ctypes.c_uint32(ctypes.sizeof(ctypes.c_void_p))
    ret = _CA.AudioObjectGetPropertyData(
        ctypes.c_uint32(dev_id), ctypes.byref(addr),
        ctypes.c_uint32(0), None, ctypes.byref(sz), ctypes.byref(cf_str),
    )
    if ret != 0 or not cf_str.value:
        return None
    buf = ctypes.create_string_buffer(512)
    ok = _CF.CFStringGetCString(cf_str, buf, 512, _kCFStringEncodingUTF8)
    _CF.CFRelease(cf_str)
    if not ok:
        return None
    return buf.value.decode("utf-8", errors="replace")


def _get_output_channels(dev_id: int) -> int:
    addr = _AudioObjectPropertyAddress(
        _kAudioDevicePropertyStreamConfiguration,
        _kAudioDevicePropertyScopeOutput,
        _kAudioObjectPropertyElementMain,
    )
    sz = ctypes.c_uint32(0)
    if _CA.AudioObjectGetPropertyDataSize(
        ctypes.c_uint32(dev_id), ctypes.byref(addr),
        ctypes.c_uint32(0), None, ctypes.byref(sz),
    ) != 0 or sz.value == 0:
        return 0

    raw = (ctypes.c_ubyte * sz.value)()
    if _CA.AudioObjectGetPropertyData(
        ctypes.c_uint32(dev_id), ctypes.byref(addr),
        ctypes.c_uint32(0), None, ctypes.byref(sz), raw,
    ) != 0:
        return 0

    # AudioBufferList: uint32 mNumberBuffers, dann AudioBuffer-Array
    n_bufs = int.from_bytes(bytes(raw[0:4]), "little")
    channels = 0
    # AudioBuffer: uint32 mNumberChannels, uint32 mDataByteSize, void* mData
    # auf 64bit: 4 + 4 + 8 = 16 Bytes pro Eintrag — aber AudioBuffer kann padding haben
    # Konservativ: nutze ctypes.sizeof(_AudioBuffer)
    buf_stride = ctypes.sizeof(_AudioBuffer)
    base = 4  # nach mNumberBuffers
    # mBuffers fängt mit potenziell padding nach mNumberBuffers an (Alignment auf void*)
    # Tatsaechlich: auf 64bit ist mNumberBuffers padded auf 8 Byte
    if ctypes.sizeof(ctypes.c_void_p) == 8:
        base = 8
    for i in range(n_bufs):
        off = base + i * buf_stride
        if off + 4 > sz.value:
            break
        n_ch = int.from_bytes(bytes(raw[off:off + 4]), "little")
        channels += n_ch
    return channels


def _get_sample_rate(dev_id: int) -> float:
    addr = _AudioObjectPropertyAddress(
        _kAudioDevicePropertyNominalSampleRate,
        _kAudioObjectPropertyScopeGlobal,
        _kAudioObjectPropertyElementMain,
    )
    rate = ctypes.c_double(0.0)
    sz = ctypes.c_uint32(8)
    if _CA.AudioObjectGetPropertyData(
        ctypes.c_uint32(dev_id), ctypes.byref(addr),
        ctypes.c_uint32(0), None, ctypes.byref(sz), ctypes.byref(rate),
    ) != 0:
        return 0.0
    return float(rate.value)


def _query_all_output_devices() -> List[AudioDevice]:
    """Liest alle CoreAudio-Devices und filtert Output-faehige (≥2ch) heraus."""
    addr = _AudioObjectPropertyAddress(
        _kAudioHardwarePropertyDevices,
        _kAudioObjectPropertyScopeGlobal,
        _kAudioObjectPropertyElementMain,
    )
    sz = ctypes.c_uint32(0)
    if _CA.AudioObjectGetPropertyDataSize(
        ctypes.c_uint32(_kAudioObjectSystemObject), ctypes.byref(addr),
        ctypes.c_uint32(0), None, ctypes.byref(sz),
    ) != 0:
        return []
    count = sz.value // 4
    if count == 0:
        return []
    ids = (ctypes.c_uint32 * count)()
    if _CA.AudioObjectGetPropertyData(
        ctypes.c_uint32(_kAudioObjectSystemObject), ctypes.byref(addr),
        ctypes.c_uint32(0), None, ctypes.byref(sz), ids,
    ) != 0:
        return []

    result: List[AudioDevice] = []
    for dev_id in ids:
        uid = _get_string_property(dev_id, _kAudioDevicePropertyDeviceUID)
        name = _get_string_property(dev_id, _kAudioDevicePropertyDeviceNameCFString)
        if not uid or not name:
            continue
        if VIRTUAL_DEVICE_NAME.lower() in name.lower():
            continue
        ch = _get_output_channels(dev_id)
        if ch < 2:
            continue
        sr = _get_sample_rate(dev_id)
        result.append(AudioDevice(
            uid=uid, name=name, max_output_channels=ch, default_samplerate=sr,
        ))
    return result


class DeviceManager:
    """
    Verwaltet die Liste der verfuegbaren Output-Devices.
    Phase 4: ctypes statt sounddevice.
    """

    def __init__(self, on_devices_changed: Optional[Callable[[List[AudioDevice]], None]] = None):
        self._on_devices_changed = on_devices_changed
        self._lock = threading.Lock()
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._known: Dict[str, AudioDevice] = {}  # uid -> AudioDevice

    def start(self):
        with self._lock:
            if self._running:
                return
            self._running = True
            self._scan_devices()
            self._thread = threading.Thread(
                target=self._poll_loop, name="audiorouter-device-manager", daemon=True
            )
            self._thread.start()
            logger.info("DeviceManager gestartet (CoreAudio)")

    def stop(self):
        with self._lock:
            if not self._running:
                return
            self._running = False
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=HOTPLUG_POLL_INTERVAL + 1.0)
        self._thread = None
        logger.info("DeviceManager gestoppt")

    def get_output_devices(self) -> List[AudioDevice]:
        with self._lock:
            return list(self._known.values())

    def find_device_by_uid(self, uid: str) -> Optional[AudioDevice]:
        with self._lock:
            return self._known.get(uid)

    def find_device_by_name(self, name: str) -> Optional[AudioDevice]:
        with self._lock:
            nl = name.lower()
            for d in self._known.values():
                if nl in d.name.lower():
                    return d
        return None

    def get_devices_by_names(self, names: List[str]) -> List[AudioDevice]:
        result = []
        for n in names:
            d = self.find_device_by_name(n)
            if d:
                result.append(d)
        return result

    def get_devices_by_uids(self, uids: List[str]) -> List[AudioDevice]:
        result = []
        for u in uids:
            d = self.find_device_by_uid(u)
            if d:
                result.append(d)
        return result

    def refresh(self) -> List[AudioDevice]:
        with self._lock:
            self._scan_devices()
            return list(self._known.values())

    # ------------------------------------------------------------------
    def _scan_devices(self):
        try:
            new_list = _query_all_output_devices()
        except Exception as e:
            logger.error(f"Device-Scan-Fehler: {e}")
            return None
        new_map = {d.uid: d for d in new_list}

        old_uids = set(self._known.keys())
        new_uids = set(new_map.keys())
        added = new_uids - old_uids
        removed = old_uids - new_uids

        if added or removed:
            if added:
                logger.info("Neue Devices: %s", ", ".join(new_map[u].name for u in added))
            if removed:
                logger.info("Devices entfernt: %s", ", ".join(self._known[u].name for u in removed))
            self._known = new_map
            return list(new_map.values())

        self._known = new_map
        return None

    def _poll_loop(self):
        import time as _t
        while self._running:
            _t.sleep(HOTPLUG_POLL_INTERVAL)
            if not self._running:
                break
            with self._lock:
                changed = self._scan_devices()
            if changed is not None and self._on_devices_changed:
                try:
                    self._on_devices_changed(changed)
                except Exception as e:
                    logger.error(f"Fehler im on_devices_changed-Callback: {e}")
