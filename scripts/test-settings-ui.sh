#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEW="$ROOT/macos/DSHApp/DSHSettingsView.swift"
MAIN="$ROOT/macos/DSHApp/main.swift"
THEME="$ROOT/macos/DSHApp/DSHTheme.swift"

[[ -f "$VIEW" ]] || { echo "settings-ui: missing dedicated Settings view" >&2; exit 1; }
rg -q 'ScrollView' "$VIEW" || { echo "settings-ui: settings content must scroll" >&2; exit 1; }
rg -q '自定义配置' "$VIEW" || { echo "settings-ui: custom configuration entry is missing" >&2; exit 1; }
rg -q 'strokeBorder' "$THEME" || { echo "settings-ui: fields need a visible boundary" >&2; exit 1; }
! rg -q 'Relay（本机）|provider == "relay" \? "RELAY_API_KEY"' "$MAIN" || {
  echo "settings-ui: Relay-specific model entry remains" >&2
  exit 1
}

echo "settings-ui: OK"
