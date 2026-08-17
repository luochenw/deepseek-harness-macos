#!/bin/bash
# Native macOS checks without an invented Xcode or SwiftPM project.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP_PATH:-$ROOT/dist/DeepSeek Harness.app}"
MODE="contract"

usage() {
  cat <<'EOF'
Usage: ./scripts/test-macos-native.sh [--smoke [APP_PATH]]

Without arguments, typechecks all production Swift sources and checks that the
native Settings surface stays scrollable, uses visible field chrome, and does
not restore the legacy Relay-only model entry. This includes the compile-time
fixtures in macos/DSHApp/NativeContractCheck.swift, which exercise native RPC
envelope, prompt, settings-patch, queue, and attachment wire types.

--smoke [APP_PATH] additionally starts the packaged DSH Host and verifies a
small read-only Host API surface. Build the app first, or pass its path.
EOF
}

case "${1:-}" in
  "") ;;
  --smoke)
    MODE="smoke"
    [[ $# -le 2 ]] || { usage >&2; exit 64; }
    APP="${2:-$APP}"
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac

command -v swiftc >/dev/null || { echo "swiftc is required (install Xcode Command Line Tools)." >&2; exit 1; }
command -v plutil >/dev/null || { echo "plutil is required (macOS only)." >&2; exit 1; }

# The production build compiles this exact glob; keeping the command here avoids
# a second source list or a synthetic test project that could drift from builds.
swiftc -typecheck -parse-as-library "$ROOT"/macos/DSHApp/*.swift -framework AppKit -framework SwiftUI
plutil -lint "$ROOT/macos/DSHApp/Info.plist" >/dev/null
"$ROOT/scripts/test-settings-ui.sh"
echo "native-contract: OK"

if [[ "$MODE" == "smoke" ]]; then
  [[ -x "$APP/Contents/MacOS/node" ]] || { echo "Packaged Node runtime is missing: $APP" >&2; exit 1; }
  [[ -f "$APP/Contents/Resources/Runtime/dsh/lib/bin.js" ]] || { echo "Packaged DSH runtime is missing: $APP" >&2; exit 1; }
  "$ROOT/scripts/verify-native-host-api.sh" "$APP"
fi
