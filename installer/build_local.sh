#!/bin/bash
# =============================================================================
# AudioRouterNow — Local Test Build Script
# Erstellt NUR die standalone .app fuer lokales Testen auf dem Entwickler-Mac.
#
# Unterschiede zu build.sh:
#   - KEIN make (Driver + Helper sind bereits gebaut)
#   - KEIN pip install (venv ist bereits eingerichtet)
#   - PyInstaller laeuft IMMER (aktualisierte Python-Dateien)
#   - Symlink-Aufloesung, Storage-Bundle-Entfernung, Sparkle-Einbettung,
#     vollstaendiges Bottom-Up-Signing + Signing-Gate: identisch zu build.sh
#   - KEIN DMG, KEINE Notarisierung, KEIN Stapling, KEINE DMG-Signierung
#   - Am Ende: App wird direkt gestartet (open)
#
# Ausfuehren:
#   cd installer && chmod +x build_local.sh && ./build_local.sh
# =============================================================================

set -euo pipefail

# --- Farben & Symbole --------------------------------------------------------
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
RED='\033[0;31m';   BOLD='\033[1m';    NC='\033[0m'
OK="${GREEN}✓${NC}"; STEP="${BLUE}▶${NC}"; WARN="${YELLOW}⚠${NC}"

log()  { echo -e "${STEP} ${BOLD}$*${NC}"; }
ok()   { echo -e "${OK} $*"; }
warn() { echo -e "${WARN} $*"; }
fail() { echo -e "${RED}✗ FEHLER:${NC} $*" >&2; exit 1; }

# --- Pfade -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE_DIR="$PROJECT_ROOT/engine"
DRIVER_BUILD="$PROJECT_ROOT/driver/build/AudioRouterNow.driver"
VENV_DIR="$SCRIPT_DIR/.venv"
BUILD_OUTPUT="$SCRIPT_DIR/build_output"
DIST_DIR="$SCRIPT_DIR/dist"
APP_NAME="AudioRouterNow"
SIGN_IDENTITY="Developer ID Application: MAURICIO MORAIS DA CUNHA (5D52U34B3W)"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   AudioRouterNow — Local Test Build  ║${NC}"
echo -e "${BOLD}║   v3.4.1-dev · Keine Notarisierung   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# --- Voraussetzungen pruefen -------------------------------------------------
log "Pruefe Voraussetzungen..."

PYTHON=$(command -v python3) || fail "python3 nicht gefunden."
PY_VERSION=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
ok "Python $PY_VERSION ($PYTHON)"

command -v clang >/dev/null || fail "Xcode Command Line Tools nicht installiert. Ausfuehren: xcode-select --install"
ok "Xcode CLTools vorhanden"

# --- Driver + Helper pruefen (KEIN make — bereits gebaut) --------------------
log "Pruefe vorhandenen HAL-Treiber + Helper-Binary..."
[[ -f "$DRIVER_BUILD/Contents/MacOS/AudioRouterNowDriver" ]] || fail "Driver-Binary fehlt: $DRIVER_BUILD/Contents/MacOS/AudioRouterNowDriver"
[[ -f "$DRIVER_BUILD/Contents/MacOS/AudioRouterNowHelper" ]] || fail "Helper-Binary fehlt: $DRIVER_BUILD/Contents/MacOS/AudioRouterNowHelper"
ok "Driver + Helper vorhanden (werden in App-Bundle neu signiert)"

# --- Python venv pruefen (KEIN pip install — bereits eingerichtet) -----------
log "Pruefe Python-Umgebung..."
[[ -d "$VENV_DIR" ]] || fail "venv nicht vorhanden: $VENV_DIR — erst build.sh ausfuehren."
VENV_PY="$VENV_DIR/bin/python3"
PYINSTALLER="$VENV_DIR/bin/pyinstaller"
[[ -x "$VENV_PY" ]] || fail "venv-Python nicht ausfuehrbar: $VENV_PY"
[[ -x "$PYINSTALLER" ]] || fail "PyInstaller nicht im venv gefunden: $PYINSTALLER — erst build.sh ausfuehren."
ok "venv vorhanden — PyInstaller: $($PYINSTALLER --version)"

# --- PyInstaller Build (IMMER — aktualisierte Python-Dateien) ----------------
log "Baue ${APP_NAME}.app mit PyInstaller..."

rm -rf "$DIST_DIR" "$BUILD_OUTPUT"

cd "$SCRIPT_DIR"
"$PYINSTALLER" \
    --distpath "$DIST_DIR" \
    --workpath "$BUILD_OUTPUT" \
    --noconfirm \
    AudioRouterNow.spec

APP_PATH="$DIST_DIR/${APP_NAME}.app"
[[ -d "$APP_PATH" ]] || fail ".app wurde nicht erstellt. Siehe PyInstaller-Ausgabe oben."
ok "${APP_NAME}.app gebaut: $APP_PATH"

# --- Frameworks/-Level: PyInstaller-Symlinks auflösen & Bundle umbenennen ----
# PyInstaller 6.x erstellt in Frameworks/ u.a. diese Symlinks:
#
#   AudioRouterNow.driver → AudioRouterNow__dot__driver/
#     KRITISCH: codesign erkennt .driver-Erweiterung, behandelt den Symlink
#     als unsignierten nested bundle → "code object is not signed at all"
#
#   com.audiorouter.now.helper.plist → ../Resources/com.audiorouter.now.helper.plist
#     KRITISCH: plist-Symlink in Frameworks/ führt zu "code object is not signed" Fehler
#
# Fix:
#   (a) plist-Symlink durch echte Datei ersetzen
#   (b) driver-Symlink entfernen, __dot__driver → AudioRouterNow.driver umbenennen
#       → codesign sieht echtes .driver-Verzeichnis, erkennt es als pre-signiertes
#         nested bundle und versiegelt es korrekt
#   (c) sys._MEIPASS + "/AudioRouterNow.driver" der Python-App funktioniert weiterhin

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

# Echtes __dot__driver-Verzeichnis finden (real dir, kein Symlink)
DOTDRIVER_BUNDLE="$(find "$FRAMEWORKS_DIR" -maxdepth 1 -type d -name "*__dot__driver" 2>/dev/null | head -1)"

# (a) com.audiorouter.now.helper.plist Symlink → echte Datei
PLIST_SYMLINK="$FRAMEWORKS_DIR/com.audiorouter.now.helper.plist"
if [[ -L "$PLIST_SYMLINK" ]]; then
    PLIST_REAL="$("$VENV_PY" -c "import os; print(os.path.realpath('$PLIST_SYMLINK'))")"
    rm "$PLIST_SYMLINK"
    cp -f "$PLIST_REAL" "$PLIST_SYMLINK"
    ok "Plist-Symlink in Frameworks/ aufgelöst: com.audiorouter.now.helper.plist"
fi

# (b) AudioRouterNow.driver Symlink entfernen + __dot__driver umbenennen
DRIVER_SYMLINK="$FRAMEWORKS_DIR/AudioRouterNow.driver"
if [[ -L "$DRIVER_SYMLINK" ]]; then
    rm "$DRIVER_SYMLINK"
    ok "AudioRouterNow.driver-Symlink aus Frameworks/ entfernt"
fi

if [[ -n "$DOTDRIVER_BUNDLE" ]] && [[ -d "$DOTDRIVER_BUNDLE" ]]; then
    NEW_BUNDLE_PATH="$FRAMEWORKS_DIR/AudioRouterNow.driver"
    mv "$DOTDRIVER_BUNDLE" "$NEW_BUNDLE_PATH"
    DOTDRIVER_BUNDLE="$NEW_BUNDLE_PATH"
    ok "__dot__driver → AudioRouterNow.driver umbenannt (echtes Verzeichnis)"
fi

# H6: Helper-Binary im (nun umbenannten) Bundle-Pfad finden
HELPER_DST=""
if [[ -n "$DOTDRIVER_BUNDLE" ]] && [[ -d "$DOTDRIVER_BUNDLE" ]]; then
    HELPER_DST="$DOTDRIVER_BUNDLE/Contents/MacOS/AudioRouterNowHelper"
fi
if [[ -z "$HELPER_DST" ]] || [[ ! -f "$HELPER_DST" ]]; then
    # Fallback: Suche im gesamten Bundle (z.B. falls Layout abweicht)
    HELPER_DST="$(find "$APP_PATH" -type f -name "AudioRouterNowHelper" 2>/dev/null | head -1)"
fi
[[ -n "$HELPER_DST" ]] || fail "AudioRouterNowHelper nicht im App-Bundle gefunden — PyInstaller-Layout unerwartet."
ok "Helper-Binary gefunden: $HELPER_DST"

# --- Symlinks IM driver-Bundle (Contents/Info.plist, Contents/Resources) auflösen ---
# PyInstaller erstellt __dot__driver/Contents/Info.plist und Resources/ als Symlinks
# auf das Storage-Bundle in Contents/Resources/AudioRouterNow.driver/.
# Nach Umbenennung zu AudioRouterNow.driver bleiben diese internen Symlinks bestehen.
# codesign verweigert Signieren wenn Info.plist ein Symlink ist.
if [[ -n "$DOTDRIVER_BUNDLE" ]] && [[ -d "$DOTDRIVER_BUNDLE" ]]; then
    log "Löse Symlinks in driver-Bundle auf: $(basename "$DOTDRIVER_BUNDLE")..."
    plist_link="$DOTDRIVER_BUNDLE/Contents/Info.plist"
    res_link="$DOTDRIVER_BUNDLE/Contents/Resources"

    if [[ -L "$plist_link" ]]; then
        real_plist="$("$VENV_PY" -c "import os; print(os.path.realpath('$plist_link'))")"
        cp -f "$real_plist" "${plist_link}.new" && mv "${plist_link}.new" "$plist_link"
        ok "Info.plist-Symlink aufgelöst"
    else
        ok "Info.plist ist bereits eine reguläre Datei"
    fi

    if [[ -L "$res_link" ]]; then
        real_res="$("$VENV_PY" -c "import os; print(os.path.realpath('$res_link'))")"
        rm "$res_link"
        cp -r "$real_res" "$res_link"
        ok "Resources-Symlink aufgelöst"
    else
        ok "Resources ist bereits ein reguläres Verzeichnis"
    fi
else
    warn "driver-Bundle nicht in Frameworks/ gefunden — Symlink-Fix übersprungen"
fi

# --- PyInstaller Driver-Storage aus Resources/ entfernen ---------------------
# PyInstaller lagert Nicht-Binary-Inhalte (Info.plist, Resources/) der .driver-Bundles
# in Contents/Resources/AudioRouterNow.driver/ aus. Nach Symlink-Auflösung ist
# Frameworks/AudioRouterNow.driver/ self-contained. Das Storage-Bundle MUSS weg:
# codesign scannt Contents/Resources/ und findet es als unsigniertes Bundle mit
# Info.plist (CFBundleExecutable=AudioRouterNowDriver) aber leerer MacOS/ → Signing-Fehler.
STORAGE_BUNDLE="$APP_PATH/Contents/Resources/AudioRouterNow.driver"
if [[ -d "$STORAGE_BUNDLE" ]]; then
    rm -rf "$STORAGE_BUNDLE"
    ok "Storage-Bundle entfernt: Contents/Resources/AudioRouterNow.driver"
else
    ok "Storage-Bundle nicht vorhanden (bereits bereinigt)"
fi

# --- Sparkle.framework ins Bundle einbetten ---------------------------------
# cp -R erhält Framework-Symlinks + Nested-Bundles (PyInstaller-datas würde sie zerstören).
SPARKLE_SRC="$PROJECT_ROOT/vendor/Sparkle/Sparkle.framework"
SPARKLE_DST="$FRAMEWORKS_DIR/Sparkle.framework"
[[ -d "$SPARKLE_SRC" ]] || fail "Sparkle.framework nicht gefunden: $SPARKLE_SRC"
rm -rf "$SPARKLE_DST"
cp -R "$SPARKLE_SRC" "$SPARKLE_DST"
xattr -cr "$SPARKLE_DST" 2>/dev/null || true
ok "Sparkle.framework eingebettet → $SPARKLE_DST"

# --- Code-Signierung (Developer ID + Hardened Runtime) -----------------------
# PyInstaller bündelt Homebrew-Python (andere Team-ID als unsere App).
# macOS Sequoia+ verweigert das Laden bei Team-ID-Konflikt.
# Lösung: Entitlements mit disable-library-validation + manuelles Bottom-Up-Signing.
# Kein --deep (scheitert an dist-info-Verzeichnissen von pip-Paketen).
# --timestamp ist Pflicht für Developer ID (Apple RFC 3161 Timestamp Server).
log "Signiere .app (Developer ID + Hardened Runtime)..."

ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

# Schritt 1: Extended Attributes entfernen
xattr -cr "$APP_PATH" 2>/dev/null || true

# Schritt 2: Alle .dylib Dateien signieren (inkl. HAL-Treiber-dylib)
find "$APP_PATH" -name "*.dylib" | while read lib; do
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$lib" 2>/dev/null || true
done

# Schritt 3: Alle .so Dateien signieren (Python-Extensions)
find "$APP_PATH" -name "*.so" | while read lib; do
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$lib" 2>/dev/null || true
done

# Schritt 4: Python Shared Library signieren (überschreibt Homebrew-Team-ID)
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    "$APP_PATH/Contents/Frameworks/Python" 2>/dev/null || true

# Schritt 4b: Helper-Binary signieren — MUSS vor Bundle-Signing (Schritt 4d) erfolgen!
# AudioRouterNowHelper hat KEINE .dylib/.so-Endung → wird von find *.dylib nicht erfasst.
if [[ -n "$HELPER_DST" ]]; then
    codesign \
        --force \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --timestamp \
        "$HELPER_DST" || warn "Helper-Binary Signierung fehlgeschlagen"
fi

# Schritt 4c: Driver-Binary explizit signieren — MUSS vor Bundle-Signing (Schritt 4d) erfolgen!
# AudioRouterNowDriver ist eine dynamiclib OHNE .dylib-Endung → ebenfalls nicht in find *.dylib.
# Wird erst hier separat signiert; sonst hat die __dot__driver-Bundle-Signatur ein unsigned Binary.
DRIVER_BIN="$(find "$APP_PATH" -type f -name "AudioRouterNowDriver" 2>/dev/null | head -1)"
if [[ -n "$DRIVER_BIN" ]]; then
    codesign \
        --force \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --timestamp \
        "$DRIVER_BIN" || warn "Driver-Binary Signierung fehlgeschlagen"
    ok "Driver-Binary signiert: $DRIVER_BIN"
else
    warn "AudioRouterNowDriver nicht gefunden — Bundle-Signierung könnte fehlschlagen"
fi

# Schritt 4d: __dot__driver Bundle signieren (NUR das reale Bundle in Frameworks/)
# Direkte Variable statt find-Schleife — vermeidet das Storage-Bundle in Resources/.
# _CodeSignature ggf. zuerst entfernen (PyInstaller hinterlässt partielle Signaturen).
if [[ -n "$DOTDRIVER_BUNDLE" ]]; then
    rm -rf "$DOTDRIVER_BUNDLE/Contents/_CodeSignature" 2>/dev/null || true
    codesign \
        --force \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --timestamp \
        "$DOTDRIVER_BUNDLE" || fail "Driver-Bundle Signierung fehlgeschlagen: $DOTDRIVER_BUNDLE"
    ok "Driver-Bundle signiert: $(basename "$DOTDRIVER_BUNDLE")"
else
    warn "__dot__driver Bundle nicht gefunden — Schritt 4d übersprungen"
fi

# Schritt 4e: Sparkle.framework Bottom-Up-Signing (5 Komponenten, innen→außen)
if [[ -d "$SPARKLE_DST" ]]; then
    log "Signiere Sparkle.framework (5 Komponenten, Bottom-Up)..."
    SPK_B="$SPARKLE_DST/Versions/B"

    # (1) XPC-Services
    for xpc in "$SPK_B/XPCServices/Downloader.xpc" "$SPK_B/XPCServices/Installer.xpc"; do
        [[ -d "$xpc" ]] && codesign --force --sign "$SIGN_IDENTITY" \
            --options runtime --timestamp "$xpc" \
            || fail "XPC-Signing fehlgeschlagen: $(basename $xpc)"
        ok "Signiert: $(basename $xpc)"
    done

    # (2) Autoupdate-Executable
    [[ -f "$SPK_B/Autoupdate" ]] && codesign --force --sign "$SIGN_IDENTITY" \
        --options runtime --timestamp "$SPK_B/Autoupdate" \
        || fail "Autoupdate-Signing fehlgeschlagen"
    ok "Signiert: Autoupdate"

    # (3) Updater.app (Executable zuerst, dann Bundle)
    if [[ -d "$SPK_B/Updater.app" ]]; then
        UPDATER_EXE="$SPK_B/Updater.app/Contents/MacOS/Updater"
        if [[ -f "$UPDATER_EXE" ]]; then
            codesign --force --sign "$SIGN_IDENTITY" \
                --options runtime --timestamp "$UPDATER_EXE" \
                || fail "Updater.app/MacOS/Updater-Signing fehlgeschlagen"
        fi
        codesign --force --sign "$SIGN_IDENTITY" \
            --options runtime --timestamp "$SPK_B/Updater.app" \
            || fail "Updater.app-Signing fehlgeschlagen"
        ok "Signiert: Updater.app"
    fi

    # (4) Framework-Binary
    [[ -f "$SPK_B/Sparkle" ]] && codesign --force --sign "$SIGN_IDENTITY" \
        --options runtime --timestamp "$SPK_B/Sparkle" \
        || fail "Sparkle-Binary-Signing fehlgeschlagen"
    ok "Signiert: Sparkle (Binary)"

    # (5) Gesamtes Framework versiegeln
    codesign --force --sign "$SIGN_IDENTITY" \
        --options runtime --timestamp "$SPARKLE_DST" \
        || fail "Sparkle.framework-Bundle-Signing fehlgeschlagen"
    ok "Sparkle.framework vollständig signiert (Bottom-Up) ✓"
fi

# Schritt 5: App-Executable signieren
codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    "$APP_PATH/Contents/MacOS/AudioRouterNow" || fail "Executable-Signierung fehlgeschlagen"

# Schritt 6: Gesamten Bundle signieren (KEIN --deep, um dist-info-Fehler zu vermeiden)
codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    "$APP_PATH" || fail "Bundle-Signierung fehlgeschlagen"

ok "Developer ID signiert (Hardened Runtime + Timestamp)"

# --- Signing-Verifikation Gate ----------------------------------------------
log "Signing-Gate: Prüfe alle Bundle-Signaturen..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
    || fail "Bundle-Verifikation fehlgeschlagen — Signing unvollständig"
[[ -d "$SPARKLE_DST" ]] && { codesign --verify --deep --strict "$SPARKLE_DST" \
    || fail "Sparkle.framework-Verifikation fehlgeschlagen — Signing prüfen"; }
ok "Signing-Gate bestanden ✓"

# --- Fertig (KEIN DMG, KEINE Notarisierung, KEIN Stapling) -------------------
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   AudioRouterNow — Local Test Build  ║${NC}"
echo -e "${GREEN}${BOLD}║   v3.4.1-dev · Keine Notarisierung   ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}APP:${NC} installer/dist/AudioRouterNow.app"
echo -e "  Testbereit — App wird gestartet..."
echo ""

open "$APP_PATH"
