#!/bin/sh
# preflight.sh: Prueft vor dem Archivieren, was beim Einreichen schiefgehen kann.
#
# Warum dieses Skript existiert: Am 01.10.2026 entstand beim ersten Archivlauf
# fuer 4.0.1 ein Archiv mit 4.0.0 (7). Ursache war, dass zwei Xcode-Projekte
# denselben Namen tragen und ueber die Liste zuletzt geoeffneter Projekte das
# falsche erreichbar war. Der Fehler haette Validierung und Upload ueberstanden
# und waere erst bei Apple aufgeschlagen.
#
# Aus v3.4.6 stammt die Lehre: eine Notiz in einem Dokument ist kein Tor.
# Deshalb steht das hier als Skript und nicht als Satz im Ablaufplan.
#
# Nutzung:  v4/scripts/preflight.sh
# Exit 0 = alles gut, Exit 1 = mindestens ein Abbruchgrund.

set -u

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
V4_DIR="${REPO_DIR}/v4"
XCCONFIG="${V4_DIR}/Configs/AudioRouterNow4.xcconfig"

FAIL=0
WARN=0

say()  { printf '%s\n' "$1"; }
ok()   { printf '  OK      %s\n' "$1"; }
bad()  { printf '  ABBRUCH %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  WARNUNG %s\n' "$1"; WARN=$((WARN + 1)); }

say ""
say "Preflight fuer die App-Store-Einreichung"
say "========================================"
say ""

# ── 1. Der doppelte Projektbaum ──────────────────────────────────────────
say "1. Projektbaum"
if [ -d "${REPO_DIR}/v4-appstore" ]; then
    warn "v4-appstore/ existiert noch. Es enthaelt ein zweites Xcode-Projekt"
    printf '          mit identischem Namen und der Version 4.0.0 (7).\n'
    printf '          In Xcode heissen beide nur "AudioRouterNow4".\n'
    printf '          Richtig ist: %s\n' "${V4_DIR}/AudioRouterNow4.xcodeproj"
else
    ok "Kein zweiter Projektbaum vorhanden"
fi

# ── 2. Version und Build, einzige Quelle ─────────────────────────────────
say ""
say "2. Version"
if [ ! -f "$XCCONFIG" ]; then
    bad "xcconfig nicht gefunden: $XCCONFIG"
else
    MV=$(awk -F'= *' '/^MARKETING_VERSION/{print $2}' "$XCCONFIG" | tr -d ' ')
    CV=$(awk -F'= *' '/^CURRENT_PROJECT_VERSION/{print $2}' "$XCCONFIG" | tr -d ' ')
    if [ -z "$MV" ] || [ -z "$CV" ]; then
        bad "MARKETING_VERSION oder CURRENT_PROJECT_VERSION fehlt in der xcconfig"
    else
        ok "xcconfig sagt ${MV} (${CV})"
    fi

    # Dieselben Werte duerfen NICHT zusaetzlich im Projekt stehen, sonst
    # gewinnt die Target-Ebene und die xcconfig wird still wirkungslos.
    if grep -q "MARKETING_VERSION" "${V4_DIR}/AudioRouterNow4.xcodeproj/project.pbxproj" 2>/dev/null; then
        bad "MARKETING_VERSION steht AUCH im project.pbxproj und ueberschreibt die xcconfig"
    else
        ok "Keine zweite Versionsquelle im Projekt"
    fi
fi

# ── 3. Wurde dieser Build schon einmal eingereicht? ──────────────────────
say ""
say "3. Build-Nummer gegen vorhandene Tags"
if [ -n "${MV:-}" ]; then
    if git -C "$REPO_DIR" rev-parse "v${MV}" >/dev/null 2>&1; then
        bad "Tag v${MV} existiert bereits. Diese Version wurde schon ausgeliefert."
    else
        ok "Tag v${MV} existiert noch nicht"
    fi
fi

# ── 4. Arbeitsbaum ───────────────────────────────────────────────────────
say ""
say "4. Arbeitsbaum"
if [ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]; then
    warn "Nicht committete Aenderungen. Der eingereichte Stand waere nicht"
    printf '          eindeutig einem Commit zuzuordnen.\n'
else
    ok "Sauber"
fi
if [ -n "$(git -C "$REPO_DIR" log origin/main..HEAD --oneline 2>/dev/null)" ]; then
    warn "Commits sind noch nicht gepusht"
else
    ok "Alles gepusht"
fi

# ── 5. Berechtigungen ────────────────────────────────────────────────────
say ""
say "5. Berechtigungen (Release)"
ENT="${V4_DIR}/AudioRouterNow4/AudioRouterNow4.entitlements"
if [ -f "$ENT" ]; then
    if /usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$ENT" 2>/dev/null | grep -q true; then
        ok "App Sandbox aktiv"
    else
        bad "App Sandbox NICHT aktiv. Der App Store verlangt sie."
    fi
    if /usr/libexec/PlistBuddy -c "Print :com.apple.security.device.audio-input" "$ENT" 2>/dev/null | grep -q true; then
        ok "Audio Input vorhanden"
    else
        bad "Audio Input fehlt. Ohne sie kann der Tap nichts lesen."
    fi
else
    bad "Entitlements-Datei nicht gefunden"
fi

# ── 6. Nach dem Archivieren: kam es aus dem richtigen Baum? ──────────────
say ""
say "6. Letztes Archiv (falls vorhanden)"
ARCHIVE=$(ls -dt "$HOME/Library/Developer/Xcode/Archives"/*/*.xcarchive 2>/dev/null | head -1)
if [ -z "$ARCHIVE" ]; then
    ok "Noch kein Archiv vorhanden, pruefbar nach dem Archivieren"
else
    A_VER=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" "$ARCHIVE/Info.plist" 2>/dev/null)
    A_BUILD=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" "$ARCHIVE/Info.plist" 2>/dev/null)
    printf '  Archiv: %s\n' "$(basename "$ARCHIVE")"

    if [ "${A_VER}" = "${MV:-}" ] && [ "${A_BUILD}" = "${CV:-}" ]; then
        ok "Archiv ist ${A_VER} (${A_BUILD}), passt zur xcconfig"
    else
        bad "Archiv ist ${A_VER} (${A_BUILD}), erwartet war ${MV:-?} (${CV:-?})"
    fi

    # Der eigentliche Nachweis: aus welchem Verzeichnis stammt der Code?
    WRONG=$(strings "$ARCHIVE/dSYMs/"*.dSYM/Contents/Resources/DWARF/* 2>/dev/null \
            | grep -cE "/AudioRouterNow/v4-appstore/" || true)
    RIGHT=$(strings "$ARCHIVE/dSYMs/"*.dSYM/Contents/Resources/DWARF/* 2>/dev/null \
            | grep -cE "/AudioRouterNow/v4/" || true)
    if [ "${WRONG:-0}" -gt 0 ]; then
        bad "Archiv stammt aus v4-appstore/ (${WRONG} Pfadverweise). Falscher Baum."
    elif [ "${RIGHT:-0}" -gt 0 ]; then
        ok "Archiv stammt aus v4/ (${RIGHT} Pfadverweise)"
    else
        warn "Herkunft nicht feststellbar, keine Debugsymbole gefunden"
    fi
fi

# ── Ergebnis ─────────────────────────────────────────────────────────────
say ""
say "========================================"
if [ "$FAIL" -gt 0 ]; then
    say "ERGEBNIS: ${FAIL} Abbruchgrund/Abbruchgruende, ${WARN} Warnung(en)."
    say "Nicht einreichen, bevor die Abbruchgruende behoben sind."
    say ""
    exit 1
fi
if [ "$WARN" -gt 0 ]; then
    say "ERGEBNIS: keine Abbruchgruende, ${WARN} Warnung(en)."
    say "Warnungen pruefen, dann ist der Weg frei."
    say ""
    exit 0
fi
say "ERGEBNIS: alles in Ordnung."
say ""
exit 0
