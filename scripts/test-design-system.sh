#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/macos/DSHApp"
THEME="$APP/Design/DSHTheme.swift"
SIDEBAR="$APP/Sidebar/SidebarView.swift"

grep -q 'enum DSHType' "$THEME" || {
  echo "design-system: shared typography roles are missing" >&2
  exit 1
}
grep -q 'struct DSHIconButtonStyle' "$THEME" || {
  echo "design-system: shared icon button style is missing" >&2
  exit 1
}
grep -q 'enum DSHBrandPalette' "$THEME" \
  && grep -q 'Color(red: 0.22, green: 0.82, blue: 0.78)' "$APP/Design/NativeSeaArt.swift" || {
  echo "design-system: the original logo artwork must remain unchanged" >&2
  exit 1
}
grep -q '0xA2 / 255, 0xE4 / 255, 0xE0 / 255' "$THEME" || {
  echo "design-system: the original logo background color is missing" >&2
  exit 1
}
grep -q 'sessionSelectedBackground' "$THEME" \
  && grep -q 'withAlpha(DSHBrandPalette.logoPrimaryRGBA' "$THEME" \
  && grep -q 'isActive' "$SIDEBAR" \
  && grep -q 'DSHActivityLine' "$SIDEBAR" \
  && grep -q 'accessibilityReduceMotion' "$SIDEBAR" || {
  echo "design-system: selected and running sessions need distinct lightweight treatments" >&2
  exit 1
}
grep -q 'struct DSHActivityLine' "$THEME" \
  && grep -q 'repeatForever(autoreverses: true)' "$THEME" || {
  echo "design-system: running sessions need a moving activity line" >&2
  exit 1
}
grep -q 'static let accentBright = DSHBrandPalette.logoPrimary' "$THEME" || {
  echo "design-system: running states must use the same primary color as sessions" >&2
  exit 1
}
grep -q 'static let accentSolid = DSHBrandPalette.logoPrimary' "$THEME" || {
  echo "design-system: the rendered logo blue must remain the primary accent" >&2
  exit 1
}
grep -q 'static let accentSolid = DSHBrandPalette.logoPrimary' "$THEME" \
  && grep -q 'static let onAccent = Color.white' "$THEME" || {
  echo "design-system: primary actions must use logo blue with white labels" >&2
  exit 1
}
if grep -q 'accentSolid.opacity(hovering' "$THEME"; then
  echo "design-system: primary-action fills must not change color on hover" >&2
  exit 1
fi
[[ "$(grep -c 'action: harness.newSession' "$SIDEBAR")" -eq 1 ]] \
  && grep -q 'Button(action: harness.newSession).*dshPrimary' "$SIDEBAR" || {
  echo "design-system: the sidebar must expose exactly one primary New Session action" >&2
  exit 1
}
grep -q 'Bundle.main.url(forResource: "AppIcon", withExtension: "icns")' "$SIDEBAR" || {
  echo "design-system: the in-app logo must load the current bundle icon directly" >&2
  exit 1
}

if rg -n 'tracking\(|design: \.rounded|canvasGradient' "$APP" --glob '*.swift'; then
  echo "design-system: rounded core type, manual tracking, or the legacy app gradient returned" >&2
  exit 1
fi

echo "design-system: OK"
