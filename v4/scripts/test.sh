#!/bin/sh
# AudioRouterNow v4 — Test-Runner für AudioRouterKit (SPM-Pfad).
#
# Warum dieses Skript: swift-testing ist NICHT in den Command Line Tools
# enthalten. Ein nackter `swift test` schlägt fehl, solange xcode-select
# auf die CLT zeigt ("no such module Testing"). Dieses Skript pinnt die
# Toolchain auf das volle Xcode — unabhängig von xcode-select.
#
# Alternative (einmalig, sudo): sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
#
# Nutzung: scripts/test.sh [weitere swift-test-Argumente]
set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

exec swift test --package-path "${REPO_DIR}/AudioRouterKit" "$@"
