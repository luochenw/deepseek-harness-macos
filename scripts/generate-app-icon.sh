#!/bin/bash
# Regenerate macos/DSHApp/AppIcon.icns from scripts/generate-app-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift "$ROOT/scripts/generate-app-icon.swift" "$TMP/icon-1024.png"

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$TMP/icon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$TMP/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o "$ROOT/macos/DSHApp/AppIcon.icns"
echo "wrote macos/DSHApp/AppIcon.icns"
