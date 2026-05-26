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

# PyInstaller + Pillow + dmgbuild installieren
log "Installiere PyInstaller + Build-Tools..."
"$VENV_PIP" install --quiet "pyinstaller>=6.0" "Pillow>=10.0" "dmgbuild>=1.6"
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

# --- DMG-Grafiken generieren -------------------------------------------------
# Hintergrundbild enthaelt den weissen Pfeil direkt eingezeichnet.
# Keine separate Pfeil-Datei im DMG-Fenster — nur App + Applications.
log "Erstelle DMG-Grafiken..."
BACKGROUND_PNG="$SCRIPT_DIR/dmg_background.png"
"$VENV_PY" "$SCRIPT_DIR/create_dmg_background.py" && ok "Hintergrundbild erstellt (mit Pfeil)" || warn "Grafik-Generierung fehlgeschlagen"

# --- DMG erstellen -----------------------------------------------------------
log "Erstelle DMG mit dmgbuild..."

# Alte Artefakte aufraumen
[[ -f "$DMG_OUTPUT" ]] && rm -f "$DMG_OUTPUT"

"$VENV_DIR/bin/dmgbuild" \
    -s "$SCRIPT_DIR/dmg_settings.py" \
    -D "app_path=$APP_PATH" \
    -D "icon_path=$SCRIPT_DIR/AudioRouterNow.icns" \
    -D "bg_path=$BACKGROUND_PNG" \
    "$APP_NAME" \
    "$DMG_OUTPUT"

[[ -f "$DMG_OUTPUT" ]] || fail "DMG wurde nicht erstellt."
DMG_SIZE=$(du -sh "$DMG_OUTPUT" | cut -f1)
ok "DMG erstellt: $DMG_OUTPUT ($DMG_SIZE)"

# --- Hintergrund via Finder-AppleScript setzen (macOS Sequoia/Tahoe fix) ------
# Problem: dmgbuild schreibt einen Legacy-HFS+-Alias in .DS_Store (mit dem
#   temporaeren Build-Pfad). macOS Sequoia/Tahoe loest diesen Alias in Finder
#   nicht mehr auf — der Hintergrund bleibt unsichtbar.
# Problem 2: -nobrowse versteckt das Volume vor Finder, daher schlaegt
#   AppleScript mit Fehler -10006 fehl.
# Loesung: UDRW mounten OHNE -nobrowse → Finder sieht das Volume → AppleScript
#   setzt Background direkt → Finder schreibt DS_Store im aktuellen Format
#   (NSURL-Bookmark statt Legacy-Alias).
log "Setze DMG-Hintergrund via Finder AppleScript..."

DMG_RW="/tmp/${APP_NAME}_rw.dmg"
# Mounten unter /Volumes/<Name>: Finder zeigt exakt diesen Namen als Volume-Label.
# Der erzeugte DS_Store-Alias referenziert dann "AudioRouterNow" — identisch mit
# dem HFS-Volume-Namen der finalen UDZO-DMG. Beim User loest sich der Alias auf.
DMG_MOUNT="/Volumes/${APP_NAME}"
rm -f "$DMG_RW"

# Alle vorhandenen AudioRouterNow-Volumes auswerfen (kein Namenskonflikt).
for _vol in \
    "/Volumes/${APP_NAME}" \
    "/Volumes/${APP_NAME} 1" \
    "/Volumes/${APP_NAME} 2" \
    "/Volumes/${APP_NAME} 3"; do
    [[ -d "$_vol" ]] && { hdiutil detach "$_vol" -quiet 2>/dev/null \
        || diskutil unmount force "$_vol" 2>/dev/null || true; }
done
sleep 1

hdiutil convert "$DMG_OUTPUT" -format UDRW -o "$DMG_RW" -quiet

# Ohne -nobrowse: Finder muss das Volume kennen fuer AppleScript-Zugriff
hdiutil attach "$DMG_RW" -mountpoint "$DMG_MOUNT" -quiet
sleep 3

ok "Volume gemountet als: '$DMG_MOUNT'"

# Hintergrundbild in .background/ Ordner kopieren.
# Finder kann auf dot-DATEIEN nicht per AppleScript als Background zugreifen,
# aber auf Dateien INNERHALB eines dot-ORDNERS schon (HFS-Pfad: ".background:background.png").
if [[ -f "$DMG_MOUNT/.background.png" ]]; then
    mkdir -p "$DMG_MOUNT/.background"
    cp "$DMG_MOUNT/.background.png" "$DMG_MOUNT/.background/background.png"
    ok ".background/background.png erstellt"

    ASCRIPT_OUT=$(osascript 2>&1 << ASEOF
tell application "Finder"
    set theVol to disk "$APP_NAME"
    open theVol
    delay 2
    set w to container window of theVol
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set bounds of w to {200, 120, 880, 560}
    set vo to icon view options of w
    set arrangement of vo to not arranged
    set icon size of vo to 100
    try
        set text size of vo to 1
    end try
    -- HFS-Pfad-Notation: Ordner ".background", Datei "background.png"
    -- Erzeugt volume-relativen Alias → loest sich bei jedem User auf
    set background picture of vo to file ".background:background.png" of theVol
    -- KEINE set position hier: dmgbuild schreibt korrekte Positionen in DS_Store.
    -- AppleScript-Positions ueberschreiben diese auf Retina-Displays mit falschen
    -- physischen Pixel-Koordinaten (2x-Skalierung), was Icons in die falsche Ecke setzt.
    update theVol without registering applications
    delay 3
    try
        close w
    end try
end tell
ASEOF
    )
    ASCRIPT_EXIT=$?

    if [[ $ASCRIPT_EXIT -eq 0 ]]; then
        ok "Hintergrund via Finder AppleScript gesetzt"
    else
        warn "Finder AppleScript fehlgeschlagen (Exit $ASCRIPT_EXIT): $ASCRIPT_OUT"
    fi
else
    warn ".background.png nicht in DMG — Hintergrund-Schritt uebersprungen"
fi

sleep 2

# Finder-Fenster sicherheitshalber schliessen
osascript -e "tell application \"Finder\"" \
          -e "try" \
          -e "close container window of disk \"$APP_NAME\"" \
          -e "end try" \
          -e "end tell" 2>/dev/null || true
sleep 1

hdiutil detach "$DMG_MOUNT" -quiet 2>/dev/null || true

# UDRW → UDZO
rm -f "$DMG_OUTPUT"
hdiutil convert "$DMG_RW" -format UDZO -o "$DMG_OUTPUT" -quiet
rm -f "$DMG_RW"
ok "Hintergrund-Fix abgeschlossen"

# --- DMG-Datei-Icon setzen (Finder-Icon der .dmg-Datei selbst) ---------------
DMG_ICON="$SCRIPT_DIR/AudioRouterNow_dmg.icns"
if [[ -f "$DMG_ICON" ]]; then
    log "Setze DMG-Datei-Icon..."
    # Als eigenstaendiges Script (nicht Heredoc) damit AppKit korrekt initialisiert
    # KEIN "tell Finder to update" danach — das loescht den kHasCustomIcon-Flag!
    "$VENV_PY" "$SCRIPT_DIR/set_dmg_icon.py" "$DMG_OUTPUT" "$DMG_ICON"
    ok "DMG-Datei-Icon gesetzt"
else
    warn "AudioRouterNow_dmg.icns nicht gefunden — Standard-Icon bleibt"
fi

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
