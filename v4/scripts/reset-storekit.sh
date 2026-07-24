#!/bin/bash
# reset-storekit.sh — Behebt "Product.products(for:) liefert [] ohne Fehler".
#
# ROOT CAUSE (2026-07-16, Opus-Audit):
# Der macOS-StoreKit-Agent (~/Library/Caches/com.apple.storekitagent) cached
# Katalog-Antworten pro Request-URL. Frühere Runs mit noch FALSCHER Bundle-ID
# (com.mauriciomorkun.audiorouternow OHNE "4") haben leere Katalog-Antworten
# eingebrannt (96 Cache-Einträge). Selbst nach Korrektur der Bundle-ID auf
# com.mauriciomorkun.audiorouternow4 und korrektem Scheme/Sandbox/Pfad servierte
# der Agent weiter die stale leere Antwort → Product.products(for:) == [].
#
# Dieses Skript leert den Agent-Cache und beendet den laufenden Agent, sodass
# er beim nächsten Run frisch aus der lokalen .storekit-Config (bzw. dem
# App-Store-Sandbox) auflöst.
#
# Gefahrlos: betrifft ausschliesslich den lokalen StoreKit-Test-Cache, keine
# echten Käufe, keine App-Store-Connect-Daten.
set -euo pipefail

echo "→ StoreKit-Agent beenden (falls laufend)..."
pkill -x storekitagent 2>/dev/null && echo "  storekitagent beendet." || echo "  kein storekitagent aktiv."

CACHE="$HOME/Library/Caches/com.apple.storekitagent"
if [[ -d "$CACHE" ]]; then
  echo "→ StoreKit-Agent-Cache leeren: $CACHE"
  rm -f "$CACHE"/Cache.db "$CACHE"/Cache.db-shm "$CACHE"/Cache.db-wal 2>/dev/null || true
  rm -rf "$CACHE"/fsCachedData 2>/dev/null || true
  echo "  Cache geleert."
else
  echo "  Kein StoreKit-Agent-Cache vorhanden (nichts zu tun)."
fi

# Optional: DerivedData für sauberen Rebuild (nur unser Projekt).
DD=$(ls -d "$HOME/Library/Developer/Xcode/DerivedData/AudioRouterNow4-"* 2>/dev/null | head -1 || true)
if [[ -n "${DD:-}" ]]; then
  echo "→ DerivedData gefunden: $DD"
  echo "  (Für einen komplett sauberen Test in Xcode zusätzlich: Product ▸ Clean Build Folder ⌘⇧K)"
fi

echo ""
echo "✅ StoreKit-Cache zurückgesetzt."
echo "   Nächster Schritt in Xcode: Clean Build Folder (⌘⇧K) → Run (⌘R)."
echo "   Erwartete Konsole: [TipJar] Loaded 2 products: [...coffee, ...beer]"
