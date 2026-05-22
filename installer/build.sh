#!/bin/bash
# =============================================================================
# AudioRouterNow — Build Script
# Erstellt eine standalone .app und verpackt sie als .dmg
#
# Voraussetzungen:
#   - macOS 11+
#   - Python 3.10+
#   - Xcode Command Line Tools (xcode-select --install)
#   - Fertiger HAL-Treiber in ../driver/build/AudioRouterNow.driver
#
# Ausfuehren:
#   cd installer && chmod +x build.sh && ./build.sh
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
DMG_OUTPUT="$HOME/Desktop/${APP_NAME}.dmg"
STAGING_DIR="/tmp/${APP_NAME}_dmg_staging"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     AudioRouterNow — Build Script    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# --- Voraussetzungen pruefen -------------------------------------------------
log "Pruefe Voraussetzungen..."

[[ -d "$DRIVER_BUILD" ]] || fail "HAL-Treiber nicht gefunden: $DRIVER_BUILD\nFuehre zuerst 'cd driver && make' aus."

PYTHON=$(command -v python3) || fail "python3 nicht gefunden."
PY_VERSION=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
ok "Python $PY_VERSION ($PYTHON)"

command -v clang >/dev/null || fail "Xcode Command Line Tools nicht installiert. Ausfuehren: xcode-select --install"
ok "Xcode CLTools vorhanden"

# --- Python venv -------------------------------------------------------------
log "Richte Python-Umgebung ein..."

if [[ ! -d "$VENV_DIR" ]]; then
    "$PYTHON" -m venv "$VENV_DIR"
    ok "venv erstellt: $VENV_DIR"
else
    ok "venv bereits vorhanden"
fi

VENV_PY="$VENV_DIR/bin/python3"
VENV_PIP="$VENV_DIR/bin/pip"

# Requirements aus engine/ installieren
log "Installiere App-Dependencies..."
"$VENV_PIP" install --quiet --upgrade pip
"$VENV_PIP" install --quiet -r "$ENGINE_DIR/requirements.txt"
ok "App-Dependencies installiert"

# PyInstaller + Pillow (fuer DMG-Hintergrundbild) installieren
log "Installiere PyInstaller + Build-Tools..."
"$VENV_PIP" install --quiet "pyinstaller>=6.0" "Pillow>=10.0"
PYINSTALLER="$VENV_DIR/bin/pyinstaller"
ok "PyInstaller: $($PYINSTALLER --version)"

# --- PyInstaller Build -------------------------------------------------------
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

# --- Code-Signierung (ad-hoc + Entitlements) ---------------------------------
# PyInstaller bündelt Homebrew-Python (andere Team-ID als unsere ad-hoc App).
# macOS Sequoia+ verweigert das Laden bei Team-ID-Konflikt.
# Lösung: Entitlements mit disable-library-validation + manuelles Bottom-Up-Signing.
# Kein --deep (scheitert an dist-info-Verzeichnissen von pip-Paketen).
log "Signiere .app (ad-hoc + Entitlements)..."

ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

# Schritt 1: Extended Attributes entfernen
xattr -cr "$APP_PATH" 2>/dev/null || true

# Schritt 2: Alle .dylib Dateien signieren
find "$APP_PATH" -name "*.dylib" | while read lib; do
    codesign --force --sign - "$lib" 2>/dev/null || true
done

# Schritt 3: Alle .so Dateien signieren
find "$APP_PATH" -name "*.so" | while read lib; do
    codesign --force --sign - "$lib" 2>/dev/null || true
done

# Schritt 4: Python Shared Library signieren (überschreibt Homebrew-Team-ID)
codesign --force --sign - "$APP_PATH/Contents/Frameworks/Python" 2>/dev/null || true

# Schritt 5: App-Executable signieren
codesign \
    --force \
    --sign - \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$APP_PATH/Contents/MacOS/AudioRouterNow" 2>/dev/null || true

# Schritt 6: Gesamten Bundle signieren (KEIN --deep, um dist-info-Fehler zu vermeiden)
codesign \
    --force \
    --sign - \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$APP_PATH" 2>/dev/null || warn "Bundle-Signierung mit Warnung abgeschlossen"

ok "Ad-hoc signiert (Entitlements: library-validation deaktiviert)"

# --- DMG-Hintergrundbild generieren ------------------------------------------
log "Erstelle DMG-Hintergrundbild..."
BACKGROUND_PNG="$SCRIPT_DIR/dmg_background.png"
"$VENV_PY" "$SCRIPT_DIR/create_dmg_background.py" && ok "Hintergrundbild erstellt" || warn "Hintergrundbild fehlgeschlagen — DMG ohne Hintergrund"

# --- DMG erstellen -----------------------------------------------------------
log "Erstelle DMG mit Installer-Hintergrund..."

# Alte Artefakte aufraumen
[[ -f "$DMG_OUTPUT" ]] && rm -f "$DMG_OUTPUT"
RW_DMG="/tmp/${APP_NAME}_rw.dmg"
[[ -f "$RW_DMG"  ]] && rm -f "$RW_DMG"

# Staging: App + Applications-Symlink + versteckter Hintergrundordner
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/.background"
cp -r "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

if [[ -f "$BACKGROUND_PNG" ]]; then
    cp "$BACKGROUND_PNG" "$STAGING_DIR/.background/background.png"
    HAS_BACKGROUND=true
else
    HAS_BACKGROUND=false
fi

# Schritt 1: Read-Write DMG erstellen
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDRW \
    -o "$RW_DMG" \
    > /dev/null

# Schritt 2: Mounten
MOUNT_DIR="/Volumes/$APP_NAME"
[[ -d "$MOUNT_DIR" ]] && hdiutil detach "$MOUNT_DIR" -quiet > /dev/null 2>&1 || true
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -quiet
sleep 2

# Schritt 3: Fenster-Layout + Hintergrund via AppleScript
if [[ "$HAS_BACKGROUND" == true ]]; then
    osascript << 'APPLESCRIPT'
tell application "Finder"
    tell disk "AudioRouterNow"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 820, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 100
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "AudioRouterNow" of container window to {160, 185}
        set position of item "Applications" of container window to {460, 185}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT
    ok "Fenster-Layout gesetzt"
else
    warn "Kein Hintergrundbild — einfaches Layout"
fi

# Schritt 4: Aushaengen + in komprimiertes UDZO konvertieren
sleep 1
hdiutil detach "$MOUNT_DIR" -quiet
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG_OUTPUT" > /dev/null
rm -f "$RW_DMG"

# Aufraumen
rm -rf "$STAGING_DIR"

[[ -f "$DMG_OUTPUT" ]] || fail "DMG wurde nicht erstellt."
DMG_SIZE=$(du -sh "$DMG_OUTPUT" | cut -f1)
ok "DMG erstellt: $DMG_OUTPUT ($DMG_SIZE)"

# --- Fertig ------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║          Build erfolgreich!          ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}DMG:${NC}  $DMG_OUTPUT"
echo ""
echo -e "  ${BOLD}Installation auf einem neuen Mac:${NC}"
echo -e "  1. ${APP_NAME}.dmg oeffnen"
echo -e "  2. ${APP_NAME}.app in Applications ziehen"
echo -e "  3. App starten → macOS fragt einmalig nach Passwort"
echo -e "  4. Fertig — '🎛️' erscheint in der Menueleiste"
echo ""
