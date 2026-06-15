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
SIGN_IDENTITY="Developer ID Application: MAURICIO MORAIS DA CUNHA (5D52U34B3W)"
NOTARIZE_PROFILE="AudioRouterNow-Notarization"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     AudioRouterNow — Build Script    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# --- Voraussetzungen pruefen -------------------------------------------------
log "Pruefe Voraussetzungen..."

PYTHON=$(command -v python3) || fail "python3 nicht gefunden."
PY_VERSION=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
ok "Python $PY_VERSION ($PYTHON)"

command -v clang >/dev/null || fail "Xcode Command Line Tools nicht installiert. Ausfuehren: xcode-select --install"
ok "Xcode CLTools vorhanden"

# --- Driver + Helper bauen ---------------------------------------------------
# Driver-Makefile baut jetzt beides: AudioRouterNowDriver + AudioRouterNowHelper (Phase 7)
log "Baue HAL-Treiber + Helper-Binary (Universal Binary)..."
DRIVER_DIR="$PROJECT_ROOT/driver"
make -C "$DRIVER_DIR" clean 2>/dev/null || true
make -C "$DRIVER_DIR" build || fail "Driver/Helper Build fehlgeschlagen. Siehe Ausgabe oben."
[[ -f "$DRIVER_BUILD/Contents/MacOS/AudioRouterNowDriver" ]] || fail "Driver-Binary fehlt nach Build."
[[ -f "$DRIVER_BUILD/Contents/MacOS/AudioRouterNowHelper" ]] || fail "Helper-Binary fehlt nach Build."
ok "Driver + Helper gebaut (werden in App-Bundle neu signiert)"

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
        [[ -f "$UPDATER_EXE" ]] && codesign --force --sign "$SIGN_IDENTITY" \
            --options runtime --timestamp "$UPDATER_EXE"
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

# --- Signing-Verifikation Gate (vor Notarisierung) --------------------------
log "Signing-Gate: Prüfe alle Bundle-Signaturen..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
    || fail "Bundle-Verifikation fehlgeschlagen — Signing unvollständig"
[[ -d "$SPARKLE_DST" ]] && codesign --verify --deep --strict "$SPARKLE_DST" \
    || true
ok "Signing-Gate bestanden ✓"

# --- DMG-Grafiken generieren -------------------------------------------------
# Hintergrundbild enthaelt den weissen Pfeil direkt eingezeichnet.
# Keine separate Pfeil-Datei im DMG-Fenster — nur App + Applications.
log "Erstelle DMG-Grafiken..."
BACKGROUND_PNG="$SCRIPT_DIR/dmg_background.png"
"$VENV_PY" "$SCRIPT_DIR/create_dmg_background.py" && ok "Hintergrundbild erstellt (mit Pfeil)" || warn "Grafik-Generierung fehlgeschlagen"

# --- DMG erstellen -----------------------------------------------------------
log "Erstelle DMG mit dmgbuild..."

# Alte Artefakte aufraumen
# macOS schützt DMG-Dateien die zuvor gemountet waren mit com.apple.macl.
# rm -f schlägt dann mit "Operation not permitted" fehl → Finder-Fallback.
if [[ -f "$DMG_OUTPUT" ]]; then
    rm -f "$DMG_OUTPUT" 2>/dev/null || \
        osascript -e "tell application \"Finder\" to delete POSIX file \"$DMG_OUTPUT\"" 2>/dev/null || \
        fail "Alte DMG kann nicht gelöscht werden: $DMG_OUTPUT"
fi

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

# --- DMG signieren -----------------------------------------------------------
log "Signiere DMG mit Developer ID..."
codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --timestamp \
    "$DMG_OUTPUT" || fail "DMG-Signierung fehlgeschlagen"
ok "DMG signiert: $DMG_OUTPUT"

# --- Notarisierung (Apple Notary Service) ------------------------------------
log "Sende DMG zur Apple-Notarisierung (kann 2-5 Minuten dauern)..."
NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_OUTPUT" \
    --keychain-profile "$NOTARIZE_PROFILE" \
    --wait \
    2>&1)
echo "$NOTARY_OUTPUT"

if echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
    ok "Notarisierung erfolgreich!"
elif echo "$NOTARY_OUTPUT" | grep -q "status: Invalid"; then
    SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep -E "^\s*id:" | head -1 | awk '{print $2}')
    warn "Notarisierung ABGELEHNT — lade Log..."
    [[ -n "$SUBMISSION_ID" ]] && xcrun notarytool log "$SUBMISSION_ID" \
        --keychain-profile "$NOTARIZE_PROFILE" || true
    fail "Notarisierung fehlgeschlagen. Siehe Log oben."
else
    warn "Notarisierung-Status unklar — prüfe Ausgabe oben"
fi

# --- Stapling ----------------------------------------------------------------
log "Staple Notarization Ticket in DMG..."
xcrun stapler staple "$DMG_OUTPUT" || fail "Stapling fehlgeschlagen"
ok "Notarization Ticket gestapelt ✓"

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
