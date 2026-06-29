# -*- mode: python ; coding: utf-8 -*-
#
# PyInstaller Spec-Datei fuer AudioRouterNow (Phase 4+: ohne sounddevice/numpy)
# Build: cd installer && .venv/bin/pyinstaller AudioRouterNow.spec
#

import sys
from pathlib import Path

# Projektpfade
PROJECT_ROOT = Path(SPECPATH).parent
ENGINE_DIR   = PROJECT_ROOT / "engine"
DRIVER_BUILD = PROJECT_ROOT / "driver" / "build" / "AudioRouterNow.driver"

# Single Source of Truth fuer die Versionsnummer: engine/version.py
# Kein Hardcoding mehr — CFBundleVersion / CFBundleShortVersionString werden
# direkt aus APP_VERSION abgeleitet, um Versions-Divergenz dauerhaft zu eliminieren.
_version_ns = {}
exec((ENGINE_DIR / "version.py").read_text(encoding="utf-8"), _version_ns)
APP_VERSION = _version_ns["APP_VERSION"]

# launchd plist (wird vom first_launch ggf. nach ~/Library/LaunchAgents/ kopiert)
HELPER_PLIST = PROJECT_ROOT / "helper" / "com.audiorouter.now.helper.plist"

a = Analysis(
    [str(ENGINE_DIR / "menu_bar_app.py")],
    pathex=[str(ENGINE_DIR)],
    binaries=[],
    datas=[
        # HAL-Treiber Bundle einbetten (enthaelt auch Helper-Binary + launchd plist).
        # Zugriff zur Laufzeit: os.path.join(sys._MEIPASS, "AudioRouterNow.driver")
        # launchd plist ist im Treiber-Bundle: AudioRouterNow.driver/Contents/Resources/
        (str(DRIVER_BUILD), "AudioRouterNow.driver"),
    ],
    hiddenimports=[
        "rumps",
        "AppKit",
        "Foundation",
        "objc",
        "config",
        "version",
        "device_manager",
        "helper_client",
        "first_launch",
        "audio_device_control",
        "onboarding",
        "diagnostic",
        "health",
        "healer",
        "updater",
        "popover_menu",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        "matplotlib", "PIL",
        # Phase 4: alte Audio-Deps explizit ausschliessen
        "sounddevice", "numpy", "_sounddevice_data",
        "cffi", "_cffi_backend",
        # alte Module die jetzt entfernt sind
        "socket_receiver", "routing_engine",
    ],
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
    console=False,
    disable_windowed_traceback=False,
    target_arch=None,
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
    icon=str(Path(SPECPATH) / "AudioRouterNow.icns"),
    bundle_identifier="com.audiorouter.now",
    version=APP_VERSION,
    info_plist={
        "CFBundleName":               "AudioRouterNow",
        "CFBundleDisplayName":        "AudioRouterNow",
        "CFBundleIdentifier":         "com.audiorouter.now",
        "CFBundleVersion":            APP_VERSION,
        "CFBundleShortVersionString": APP_VERSION,
        "NSHighResolutionCapable":    True,
        "LSUIElement":                True,
        "NSHumanReadableCopyright":   "AudioRouterNow",
        "LSMinimumSystemVersion":     "11.0",
        # Sparkle 2.9.3 Auto-Updates
        "SUFeedURL":               "https://mauriciomorkun.github.io/AudioRouterNow/appcast.xml",
        "SUPublicEDKey":           "uvHAgZWxrdMVo0ASrFMrWsRhOciUEUU301MZ1gQH/Jk=",
        "SUEnableAutomaticChecks": True,
        "SUScheduledCheckInterval": 86400,
        "SUAutomaticallyUpdate":   False,
    },
)
