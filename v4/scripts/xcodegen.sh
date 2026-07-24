#!/bin/bash
# Run this instead of bare 'xcodegen generate'.
# Mit schemePathPrefix "../../" generiert xcodegen den KORREKTEN Pfad
# "../../AudioRouterNow4/AudioRouterNow.storekit" — identisch mit dem was
# Xcode 26 selbst in Edit Scheme schreibt. Kein nachträglicher Patch nötig.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "→ Running xcodegen generate..."
xcodegen generate

echo "✅ Done. Open AudioRouterNow4.xcodeproj in Xcode, Clean Build (⌘⇧K), Run (⌘R)."
