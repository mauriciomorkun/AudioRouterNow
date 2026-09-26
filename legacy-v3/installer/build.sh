#!/bin/bash
# =============================================================================
# AudioRouterNow — Build Script
# Erstellt eine standalone .app und verpackt sie als .dmg
#
# Voraussetzungen:
#   - macOS 11+
#   - Python 3.13 als Framework-Build von python.org (NICHT Homebrew, NICHT
#     das System-Python). Begruendung siehe Abschnitt "Voraussetzungen pruefen".
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

# Die aelteste macOS-Version, die dieses Build unterstuetzen soll. Der Wert wird
# nicht hier festgelegt, sondern aus engine/version.py abgeleitet. Dieselbe Zahl
# steuert die beiden Makefiles, die sie tatsaechlich ins Binary kompilieren, und
# die .spec, die sie in die Info.plist schreibt. Ein Gate, das seinen eigenen
# Schwellwert definiert, wuerde nur sich selbst bestaetigen.
#
# Gelesen wird direkt mit awk, nicht ueber $PYTHON: ENGINE_DIR steht hier schon
# fest, $PYTHON wird erst deutlich weiter unten gesetzt. Das Gate braucht den
# Wert erst danach, die Reihenfolge geht also auf.
MACOS_MIN_VERSION="$(awk -F'"' '
    /^[[:space:]]*MACOS_MIN_VERSION[[:space:]]*=/ { print $2; exit }
' "$ENGINE_DIR/version.py" 2>/dev/null || true)"

[[ -n "$MACOS_MIN_VERSION" ]] || fail "MACOS_MIN_VERSION nicht aus $ENGINE_DIR/version.py lesbar.
   Entweder fehlt die Datei oder die Zeile. Ohne diesen Wert hat das
   minos-Gate weiter unten keinen Schwellwert."

# Formatpruefung, und die ist nicht optional. vgt() im Gate rechnet mit '+ 0';
# ein nicht numerischer Wert wird dort stellenweise zu lauter Nullen, keine
# Version waere je groesser, und das Gate wuerde stillschweigend jedes Bundle
# durchwinken. Genau diese Fehlerklasse soll es aufdecken, also darf es nicht
# selbst daran scheitern.
[[ "$MACOS_MIN_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
    || fail "MACOS_MIN_VERSION hat kein Versionsformat: '$MACOS_MIN_VERSION'
   Erwartet wird etwas wie 11.0. Ein anderer Wert macht das minos-Gate
   wirkungslos, statt es fehlschlagen zu lassen."

# --- Notarisierung als Funktion ----------------------------------------------
# Wird zweimal gebraucht: einmal fuer die .app (vor dem DMG-Bau, damit das
# Ticket mit ins DMG wandert) und einmal fuer das fertige DMG selbst.
# $1 = Pfad zum einzureichenden Artefakt (.zip oder .dmg)
# $2 = Klartextname fuer die Log-Ausgabe
notarize() {
    local artifact="$1" label="$2" out exit_code=0 submission_id

    log "Sende $label zur Apple-Notarisierung (kann 2-5 Minuten dauern)..."
    out=$(xcrun notarytool submit "$artifact" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait \
        2>&1) || exit_code=$?
    echo "$out"

    if echo "$out" | grep -q "status: Accepted"; then
        ok "Notarisierung erfolgreich: $label"
        return 0
    fi

    submission_id=$(echo "$out" | grep -E "^[[:space:]]*id:" | head -1 | awk '{print $2}')

    if echo "$out" | grep -q "status: Invalid"; then
        warn "Notarisierung ABGELEHNT ($label), lade Log..."
        [[ -n "$submission_id" ]] && xcrun notarytool log "$submission_id" \
            --keychain-profile "$NOTARIZE_PROFILE" || true
        fail "Notarisierung fehlgeschlagen ($label). Siehe Log oben."
    fi

    # Frueher wurde hier nur gewarnt und weitergebaut. Das ist gefaehrlich:
    # ohne akzeptierte Notarisierung schlaegt das anschliessende Stapling
    # ohnehin fehl, nur eben spaeter und mit unklarerer Meldung. Ein
    # unklarer Status ist ein Abbruchgrund, kein Hinweis.
    warn "Notarisierungs-Status unklar ($label), notarytool-Exit: $exit_code"
    [[ -n "$submission_id" ]] && xcrun notarytool log "$submission_id" \
        --keychain-profile "$NOTARIZE_PROFILE" || true
    fail "Notarisierung nicht bestaetigt ($label). Abbruch statt Blindflug."
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     AudioRouterNow — Build Script    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# --- Voraussetzungen pruefen -------------------------------------------------
log "Pruefe Voraussetzungen..."

# Der Interpreter wird festgenagelt und nicht mehr in der Umgebung gesucht.
#
# Bis einschliesslich 3.4.5 stand hier `PYTHON=$(command -v python3)`. Das
# lieferte auf diesem Build-Mac das Homebrew-Python. Homebrew uebersetzt seinen
# Interpreter gegen das gerade laufende System, sein Deployment-Target ist also
# die macOS-Version des Build-Macs und nicht die, die wir versprechen.
# PyInstaller kopiert diesen Interpreter unveraendert ins Bundle. Auf jedem
# aelteren System bricht dann der dynamische Linker ab, bevor die erste Zeile
# Anwendungscode laeuft: kein Fenster, kein Icon, keine Fehlermeldung. Der
# Fehler ist vom Build-Mac aus unsichtbar, weil dort alles passt.
#
# Der Framework-Build von python.org hat ein fest eingebautes Target von 11.0
# und ist deshalb die einzige zulaessige Quelle.
PYTHON="/Library/Frameworks/Python.framework/Versions/3.13/bin/python3"
[[ -x "$PYTHON" ]] || fail "Benoetigter Python-Framework-Build fehlt: $PYTHON
   Gebraucht wird genau dieser Interpreter, nicht Homebrew und nicht das
   System-Python. Ein anderer Interpreter erzeugt ein Bundle, das auf
   aelteren macOS-Versionen wortlos nicht startet.
   Download: https://www.python.org/downloads/macos/"
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

# Ein venv gilt nur dann als brauchbar, wenn sein Interpreter auch startet.
# Die alleinige Existenz des Verzeichnisses reicht nicht: venvs schreiben
# absolute Pfade fest (pyvenv.cfg, Shebangs in bin/). Nach einem Verschieben
# oder Umbenennen des Projekts zeigen sie ins Leere, und pip scheitert dann
# mit "bad interpreter: No such file or directory".
# Genau das ist beim 3.4.5-Release passiert: das venv stammte noch aus der
# Zeit vor der Umstrukturierung nach legacy-v3/ und verwies auf
# <repo>/installer/.venv statt <repo>/legacy-v3/installer/.venv.
venv_is_healthy() {
    [[ -x "$VENV_DIR/bin/python3" ]] || return 1
    "$VENV_DIR/bin/python3" -c 'import sys' >/dev/null 2>&1 || return 1
    # pip separat pruefen: es hat eine eigene Shebang-Zeile, die unabhaengig
    # vom Interpreter-Symlink kaputtgehen kann.
    [[ -x "$VENV_DIR/bin/pip" ]] || return 1
    "$VENV_DIR/bin/pip" --version >/dev/null 2>&1 || return 1
    return 0
}

# Gesund heisst noch nicht richtig. Ein venv merkt sich in pyvenv.cfg unter
# 'home' das bin-Verzeichnis des Interpreters, aus dem es erzeugt wurde, und
# benutzt dessen Standardbibliothek und dessen Binaries weiter. Ein venv, das
# frueher einmal aus Homebrew-Python entstanden ist, bleibt also ein
# Homebrew-venv, egal was $PYTHON hier oben sagt. Damit waere die Festlegung
# des Interpreters wirkungslos und der Fehler von 3.4.5 kaeme still zurueck.
venv_matches_interpreter() {
    local cfg="$VENV_DIR/pyvenv.cfg" home
    [[ -f "$cfg" ]] || return 1
    # 'home = /pfad/zum/bin' auslesen. Bewusst am ersten '=' getrennt, damit
    # Pfade mit '=' im Namen nicht zerschnitten werden.
    home="$(awk '/^[[:space:]]*home[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit
    }' "$cfg")"
    [[ -n "$home" ]] || return 1
    [[ "$home" == "$(dirname "$PYTHON")" ]]
}

if [[ -d "$VENV_DIR" ]] && venv_is_healthy && venv_matches_interpreter; then
    ok "venv vorhanden, funktionsfaehig und aus dem richtigen Interpreter"
else
    if [[ -d "$VENV_DIR" ]]; then
        if ! venv_is_healthy; then
            warn "venv vorhanden, aber unbrauchbar (Interpreter oder pip startet nicht)."
            warn "Ursache ist meist ein verschobenes Projektverzeichnis. Wird neu gebaut."
        else
            warn "venv stammt aus einem fremden Interpreter, nicht aus $PYTHON."
            warn "Wird verworfen und neu gebaut, sonst erbt das Bundle dessen Target."
        fi
        rm -rf "$VENV_DIR"
    fi
    "$PYTHON" -m venv "$VENV_DIR" || fail "venv konnte nicht erstellt werden."
    venv_is_healthy || fail "Frisch erstelltes venv ist nicht funktionsfaehig: $VENV_DIR"
    venv_matches_interpreter \
        || fail "Frisch erstelltes venv zeigt nicht auf $PYTHON. pyvenv.cfg pruefen."
    ok "venv erstellt: $VENV_DIR"
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

# --- minos-Gate (nach PyInstaller, vor dem Signieren) ------------------------
# Prueft, dass keine ausgelieferte Mach-O-Datei ein neueres macOS verlangt als
# $MACOS_MIN_VERSION. Das ist der eigentliche Nachweis fuer das Versprechen im
# README, und er wurde bis 3.4.6 nie gefuehrt.
#
# Die Pruefung laeuft bewusst hier: spaet genug, dass Treiber, Helper und
# Sparkle.framework bereits im Bundle liegen und miterfasst werden, aber frueh
# genug, dass ein kaputtes Build in Sekunden auffliegt statt erst nach einer
# Notarisierungsrunde bei Apple.
#
# Zwei Formen muessen gelesen werden, und eine Universal-Datei enthaelt beide,
# je eine pro Slice:
#   LC_BUILD_VERSION       Zeile 'minos'     (arm64-Slice von python.org: 11.0)
#   LC_VERSION_MIN_MACOSX  Zeile 'version'   (x86_64-Slice von python.org: 10.13)
# Im LC_BUILD_VERSION-Block steht ausserdem eine 'version'-Zeile, die zum
# Linker-Werkzeug gehoert und nichts mit dem Zielsystem zu tun hat. Sie darf
# nicht mitgelesen werden, sonst meldet das Gate Unsinn wie macOS 1053.12.
#
# Ein niedrigerer Wert als $MACOS_MIN_VERSION ist nie ein Problem, solche
# Binaries laufen auch auf neueren Systemen. Nur ein hoeherer Wert ist ein
# Verstoss. Es werden alle Verstoesse gesammelt und vollstaendig ausgegeben,
# nicht nur der erste, damit eine Fehlersuche nicht zum Ratespiel wird.
#
# Das Gate prueft die .app und deckt damit auch das DMG ab: das DMG enthaelt
# genau dieses Bundle unveraendert und sonst keine Mach-O-Dateien.
check_minos_gate() {
    local target="$1"
    local list vtool_out violations x86_only count

    log "minos-Gate: pruefe Bundle gegen macOS $MACOS_MIN_VERSION..."

    list="$(mktemp -t arn_macho)"
    vtool_out="$(mktemp -t arn_vtool)"

    # Erst die Mach-O-Dateien einsammeln. 'file' laeuft gebuendelt ueber alle
    # Pfade, das ist deutlich schneller als ein Prozess je Datei. Der eigene
    # Trenner '@@@' macht das Zerlegen unabhaengig davon, ob ein Pfad einen
    # Doppelpunkt enthaelt. Zeilen ohne Trenner sind Fortsetzungszeilen von
    # Universal-Binaries und werden uebersprungen.
    find "$target" -type f -print0 \
        | xargs -0 file -F '@@@' 2>/dev/null \
        | awk -F '@@@' '
            NF > 1 && $2 ~ /Mach-O/ {
                onlyx86 = ($2 ~ /x86_64/ && $2 !~ /arm64/) ? 1 : 0
                print $1 "\t" onlyx86
            }' > "$list" || true

    count=$(wc -l < "$list" | tr -d ' ')
    [[ "$count" -gt 0 ]] \
        || fail "minos-Gate: keine einzige Mach-O-Datei in $target gefunden. Bundle unvollstaendig?"

    # vtool nimmt nur genau eine Datei je Aufruf. Vor jede Ausgabe wird eine
    # Markierung gesetzt, damit die Auswertung danach in einem Durchgang laeuft.
    while IFS=$'\t' read -r f _; do
        printf '===FILE===\t%s\n' "$f"
        vtool -show-build "$f" 2>/dev/null || true
    done < "$list" > "$vtool_out"

    violations="$(awk -v min="$MACOS_MIN_VERSION" '
        # Versionen wie 10.13, 11.0 oder 26.0 stellenweise numerisch vergleichen.
        function vgt(a, b,   x, y, i) {
            split(a, x, "."); split(b, y, ".")
            for (i = 1; i <= 4; i++) {
                if ((x[i] + 0) > (y[i] + 0)) return 1
                if ((x[i] + 0) < (y[i] + 0)) return 0
            }
            return 0
        }
        function check(v) { if (vgt(v, min)) print file "\t" arch "\t" v }

        index($0, "===FILE===\t") == 1 {
            file = substr($0, 12); arch = "thin"; cmdname = ""; platform = ""
            next
        }
        # Kopfzeile je Slice einer Universal-Datei. Thin-Dateien haben keine,
        # dort bleibt die Beschriftung "thin".
        /\(architecture [^)]+\):$/ {
            match($0, /\(architecture [^)]+\):$/)
            arch = substr($0, RSTART + 14, RLENGTH - 16)
            next
        }
        $1 == "cmd"      { cmdname = $2; platform = ""; vmin_taken = 0; next }
        $1 == "platform" { platform = $2; next }
        # Nur MACOS zaehlt. Bei MACCATALYST und iOS bedeuten die Zahlen etwas
        # anderes und duerfen nicht gegen ein macOS-Minimum gehalten werden.
        $1 == "minos" && cmdname == "LC_BUILD_VERSION" && platform == "MACOS" {
            check($2); next
        }
        # LC_VERSION_MIN_MACOSX ist per Definition macOS. Nur der erste
        # version-Eintrag des Blocks ist das Zielsystem.
        $1 == "version" && cmdname == "LC_VERSION_MIN_MACOSX" && vmin_taken == 0 {
            vmin_taken = 1; check($2); next
        }
    ' "$vtool_out")"

    x86_only="$(awk -F '\t' '$2 == 1 { print $1 }' "$list")"

    rm -f "$list" "$vtool_out"

    # Nur-x86_64-Dateien sind kein Abbruchgrund, aber ein Hinweis: das
    # ausgelieferte Binary zielt auf Apple Silicon.
    if [[ -n "$x86_only" ]]; then
        warn "Nur-x86_64-Dateien im Bundle (Zielplattform ist Apple Silicon):"
        echo "$x86_only" | while read -r f; do
            warn "    ${f#"$target"/}"
        done
    fi

    if [[ -n "$violations" ]]; then
        echo -e "${RED}minos-Gate: folgende Slices verlangen mehr als macOS $MACOS_MIN_VERSION:${NC}" >&2
        echo "$violations" | while IFS=$'\t' read -r f a v; do
            echo -e "${RED}    ${f#"$target"/} [${a}] verlangt macOS ${v}${NC}" >&2
        done
        fail "minos-Gate: $(echo "$violations" | wc -l | tr -d ' ') Verstoss/Verstoesse. Das Bundle wuerde auf macOS $MACOS_MIN_VERSION nicht starten. Interpreter und Wheels pruefen."
    fi

    ok "minos-Gate bestanden: $count Mach-O-Dateien, keine ueber macOS $MACOS_MIN_VERSION"
}

check_minos_gate "$APP_PATH"

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
        "$HELPER_DST" || fail "Helper-Binary Signierung fehlgeschlagen"
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
        "$DRIVER_BIN" || fail "Driver-Binary Signierung fehlgeschlagen"
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

# --- Signing-Verifikation Gate (vor Notarisierung) --------------------------
log "Signing-Gate: Prüfe alle Bundle-Signaturen..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
    || fail "Bundle-Verifikation fehlgeschlagen — Signing unvollständig"
[[ -d "$SPARKLE_DST" ]] && { codesign --verify --deep --strict "$SPARKLE_DST" \
    || fail "Sparkle.framework-Verifikation fehlgeschlagen — Signing prüfen"; }
ok "Signing-Gate bestanden ✓"

# --- Notarisierung + Stapling der .app (VOR dem DMG-Bau) ---------------------
# Reihenfolge ist wichtig und war bis 3.4.5 falsch herum: frueher wurde erst
# das DMG gebaut und notarisiert und die .app erst danach gestapelt. Das
# Ticket landete damit nur in der Kopie unter dist/, nie in der Kopie im DMG.
# Wer die App aus dem DMG herauszog, hatte also kein lokales Ticket, und
# Gatekeeper musste beim ersten Start online nachfragen. Ohne Netz konnte das
# den Erststart verzoegern oder scheitern lassen.
#
# Jetzt: .app notarisieren, Ticket stapeln, DANN das DMG aus der bereits
# gestapelten App bauen. Kostet eine zweite Notarisierungsrunde, macht den
# Offline-Erststart aber verlaesslich. Genau das behauptete der alte
# Kommentar an dieser Stelle schon, ohne dass der Code es tat.
#
# ditto statt zip: notarytool braucht ein Archiv, das Symlinks und erweiterte
# Attribute erhaelt. `zip` zerstoert beides in App-Bundles.
APP_NOTARIZE_ZIP="$BUILD_OUTPUT/${APP_NAME}_notarize.zip"
mkdir -p "$BUILD_OUTPUT"
rm -f "$APP_NOTARIZE_ZIP"

log "Packe .app fuer die Notarisierung (ditto)..."
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_NOTARIZE_ZIP" \
    || fail "Konnte .app nicht fuer die Notarisierung packen."
ok "Archiv erstellt: $(basename "$APP_NOTARIZE_ZIP")"

notarize "$APP_NOTARIZE_ZIP" ".app"

log "Staple Notarization Ticket in .app..."
xcrun stapler staple "$APP_PATH" || fail "Stapling der .app fehlgeschlagen"
xcrun stapler validate "$APP_PATH" >/dev/null 2>&1 \
    || fail "Stapling der .app nicht verifizierbar."
ok ".app Ticket gestapelt und verifiziert ✓"

rm -f "$APP_NOTARIZE_ZIP"

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

    ASCRIPT_EXIT=0
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
    ) || ASCRIPT_EXIT=$?

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

# Detach mit Retry — Finder haelt das Volume nach der AppleScript-Phase oft
# noch kurz busy. Das fertige DMG erst ersetzen, wenn der Ersatz existiert.
for _i in 1 2 3 4 5; do
    if hdiutil detach "$DMG_MOUNT" -quiet 2>/dev/null; then break; fi
    sleep 2
done
[[ ! -d "$DMG_MOUNT" ]] || fail "Volume liess sich nicht auswerfen: $DMG_MOUNT"

# UDRW → UDZO: erst in Temp-Datei konvertieren, dann atomar ersetzen
rm -f "${DMG_OUTPUT}.tmp.dmg"
hdiutil convert "$DMG_RW" -format UDZO -o "${DMG_OUTPUT}.tmp.dmg" -quiet
mv -f "${DMG_OUTPUT}.tmp.dmg" "$DMG_OUTPUT"
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

# --- Notarisierung des DMG (Apple Notary Service) ----------------------------
# Die .app ist zu diesem Zeitpunkt bereits notarisiert und gestapelt, das
# Ticket liegt also schon in der Kopie im DMG. Diese zweite Runde gilt dem
# DMG als eigenem Artefakt, damit auch der Download selbst ein Ticket traegt.
notarize "$DMG_OUTPUT" "DMG"

# --- Stapling des DMG --------------------------------------------------------
log "Staple Notarization Ticket in DMG..."
xcrun stapler staple "$DMG_OUTPUT" || fail "Stapling des DMG fehlgeschlagen"
xcrun stapler validate "$DMG_OUTPUT" >/dev/null 2>&1 \
    || fail "Stapling des DMG nicht verifizierbar."
ok "DMG Ticket gestapelt und verifiziert ✓"

# --- Abschluss-Gate: ist die App IM DMG wirklich gestapelt? -------------------
# Der eigentliche Test fuer den Fix. Fruehere Releases haben hier stillschweigend
# eine ungestapelte App ausgeliefert, weil niemand in das fertige DMG geschaut hat.
log "Abschluss-Gate: pruefe die .app im fertigen DMG..."
VERIFY_MOUNT="/tmp/${APP_NAME}_verify_$$"
rm -rf "$VERIFY_MOUNT"
if hdiutil attach "$DMG_OUTPUT" -nobrowse -quiet -mountpoint "$VERIFY_MOUNT" 2>/dev/null; then
    _verify_fail=""
    xcrun stapler validate "$VERIFY_MOUNT/${APP_NAME}.app" >/dev/null 2>&1 \
        || _verify_fail="Die .app im DMG hat KEIN gestapeltes Ticket."
    if [[ -z "$_verify_fail" ]]; then
        spctl --assess --type execute "$VERIFY_MOUNT/${APP_NAME}.app" >/dev/null 2>&1 \
            || _verify_fail="Gatekeeper lehnt die .app im DMG ab."
    fi
    hdiutil detach "$VERIFY_MOUNT" -quiet 2>/dev/null || true
    rm -rf "$VERIFY_MOUNT"
    [[ -n "$_verify_fail" ]] && fail "$_verify_fail"
    ok "App im DMG: Ticket gestapelt, Gatekeeper akzeptiert ✓"
else
    warn "DMG liess sich zur Pruefung nicht mounten, Abschluss-Gate uebersprungen"
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
