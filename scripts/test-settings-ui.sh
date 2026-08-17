#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEW="$ROOT/macos/DSHApp/DSHSettingsView.swift"
MAIN="$ROOT/macos/DSHApp/main.swift"
THEME="$ROOT/macos/DSHApp/DSHTheme.swift"
EDITOR="$ROOT/macos/DSHApp/DSHSettingsEditor.swift"
AUTHORING="$ROOT/macos/DSHApp/DSHProviderAuthoring.swift"
ACTIONS="$ROOT/macos/DSHApp/DSHProviderActions.swift"

# grep, not rg: ripgrep is not installed on every dev machine (here `rg` is
# only an interactive-shell alias), and a gate that can't run reads as a
# permanent failure.
[[ -f "$VIEW" ]] || { echo "settings-ui: missing dedicated Settings view" >&2; exit 1; }
grep -q 'ScrollView' "$VIEW" || { echo "settings-ui: settings content must scroll" >&2; exit 1; }
grep -Fq '.scrollIndicators(.visible' "$VIEW" || { echo "settings-ui: vertical scroll indicator must stay visible" >&2; exit 1; }
grep -q '自定义配置' "$VIEW" || { echo "settings-ui: custom configuration entry is missing" >&2; exit 1; }
grep -q 'strokeBorder' "$THEME" || { echo "settings-ui: fields need a visible boundary" >&2; exit 1; }
grep -q 'ScrollView' "$EDITOR" || { echo "settings-ui: JSON settings editor must scroll" >&2; exit 1; }
grep -Fq 'references.count == 1' "$EDITOR" || { echo "settings-ui: editor must not preselect an arbitrary credential" >&2; exit 1; }
grep -Fq 'profileOperations(path: path)' "$AUTHORING" || { echo "settings-ui: existing custom profiles need field-level operations" >&2; exit 1; }
grep -Fq 'ops: [DSHSettingsPathOperation]' "$ACTIONS" || { echo "settings-ui: profile save must accept path operations" >&2; exit 1; }
! grep -Eq 'Relay（本机）|provider == "relay" \? "RELAY_API_KEY"' "$MAIN" || {
  echo "settings-ui: Relay-specific model entry remains" >&2
  exit 1
}

echo "settings-ui: OK"
