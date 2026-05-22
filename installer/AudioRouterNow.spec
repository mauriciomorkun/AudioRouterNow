# -*- mode: python ; coding: utf-8 -*-
#
# PyInstaller Spec-Datei fuer AudioRouterNow
# Build: cd installer && .venv/bin/pyinstaller AudioRouterNow.spec
#

import sys
from pathlib import Path

# Projektpfade
PROJECT_ROOT = Path(SPECPATH).parent
ENGINE_DIR   = PROJECT_ROOT / "engine"
DRIVER_BUILD = PROJECT_ROOT / "driver" / "build" / "AudioRouterNow.driver"

# Sounddevice portaudio Library finden
import sounddevice
import os
_sd_data_dir = Path(sounddevice.__file__).parent / "_sounddevice_data"
_portaudio_libs = []
for lib_path in _sd_data_dir.rglob("libportaudio*"):
    _portaudio_libs.append((str(lib_path), "_sounddevice_data"))

a = Analysis(
    [str(ENGINE_DIR / "menu_bar_app.py")],
    pathex=[str(ENGINE_DIR)],
    binaries=_portaudio_libs,
    datas=[
        # HAL-Treiber Bundle einbetten (wird bei Erststart installiert)
        # Zugriff zur Laufzeit: os.path.join(sys._MEIPASS, "AudioRouterNow.driver")
        (str(DRIVER_BUILD), "AudioRouterNow.driver"),
        # HINWEIS: Python-Module (.py) werden von Analysis automatisch gefunden
        # und als kompiliertes .pyc in base_library.zip gebündelt.
        # Explizites Kopieren als .py wuerde rohe Quelldateien in Contents/Frameworks
        # erzeugen, was codesign blockiert (keine signierbaren Mach-O Binaries).
    ],
    hiddenimports=[
        "rumps",
        "sounddevice",
        "_sounddevice_data",
        "numpy",
        "numpy.core",
        "numpy.core._multiarray_umath",
        "cffi",
        "_cffi_backend",
        "AppKit",
        "Foundation",
        "objc",
        "socket_receiver",
        "routing_engine",
        "device_manager",
        "config",
        "first_launch",
        "audio_device_control",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "PIL"],
    noarchive=False,
    optimize=1,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="AudioRouterNow",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,   # Kein Terminal-Fenster
    disable_windowed_traceback=False,
    target_arch="arm64",   # arm64 (Apple Silicon) — universal2 erfordert fat binaries in allen Paketen
    codesign_identity=None,
    entitlements_file=str(Path(SPECPATH) / "entitlements.plist"),
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="AudioRouterNow",
)

app = BUNDLE(
    coll,
    name="AudioRouterNow.app",
    icon=None,
    bundle_identifier="com.audiorouter.now",
    version="1.0.0",
    info_plist={
        "CFBundleName":               "AudioRouterNow",
        "CFBundleDisplayName":        "AudioRouterNow",
        "CFBundleIdentifier":         "com.audiorouter.now",
        "CFBundleVersion":            "1.0.0",
        "CFBundleShortVersionString": "1.0.0",
        "NSHighResolutionCapable":    True,
        "LSUIElement":                True,   # Kein Dock-Icon (Menu-Bar-Only App)
        "NSHumanReadableCopyright":   "AudioRouterNow",
        "LSMinimumSystemVersion":     "11.0",
        "NSMicrophoneUsageDescription": "AudioRouterNow benoetigt Zugriff auf Audio-Geraete.",
    },
)
