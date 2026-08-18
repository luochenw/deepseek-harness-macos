#!/bin/bash
# Native macOS checks without an invented Xcode or SwiftPM project.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP_PATH:-$ROOT/dist/DeepSeek Harness.app}"
MODE="contract"

usage() {
  cat <<'EOF'
Usage: ./scripts/test-macos-native.sh [--smoke [APP_PATH] | --unit]

Without arguments, typechecks all production Swift sources and checks that the
native Settings surface stays scrollable, uses visible field chrome, and does
not restore the legacy Relay-only model entry. This includes the compile-time
fixtures in macos/DSHApp/NativeContractCheck.swift, which exercise native RPC
envelope, prompt, settings-patch, queue, and attachment wire types. It also
enforces the main.swift freeze (see CLAUDE.md/AGENTS.md): main.swift may only
shrink, never grow past its recorded baseline.

--smoke [APP_PATH] additionally starts the packaged DSH Host and verifies a
small read-only Host API surface. Build the app first, or pass its path.

--unit additionally builds macos/DSHApp as a library (-enable-testing) and
runs macos/DSHTests/*.swift against it via @testable import — no Xcode/
XCTest, matching the project's no-project-file build philosophy.
EOF
}

case "${1:-}" in
  "") ;;
  --smoke)
    MODE="smoke"
    [[ $# -le 2 ]] || { usage >&2; exit 64; }
    APP="${2:-$APP}"
    ;;
  --unit)
    MODE="unit"
    [[ $# -le 1 ]] || { usage >&2; exit 64; }
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac

command -v swiftc >/dev/null || { echo "swiftc is required (install Xcode Command Line Tools)." >&2; exit 1; }
command -v plutil >/dev/null || { echo "plutil is required (macOS only)." >&2; exit 1; }

# main.swift is frozen: new @Published state, controller methods, and
# top-level Views go in DSH<Feature>.swift extensions / <Feature>View.swift
# instead (see CLAUDE.md "质量规范" / AGENTS.md). This gate is what makes that
# a rule instead of a suggestion — it only ever ratchets down.
MAIN_SWIFT="$ROOT/macos/DSHApp/main.swift"
MAIN_SWIFT_LINE_LIMIT=1752
[[ -f "$MAIN_SWIFT" ]] || { echo "Expected main.swift at $MAIN_SWIFT — did it move or get removed (e.g. finished the Phase 2 split)? Update MAIN_SWIFT and MAIN_SWIFT_LINE_LIMIT here, and the freeze rule in AGENTS.md/CLAUDE.md, to match." >&2; exit 1; }
# awk, not `wc -l`: wc -l counts newline bytes, so a final line with no
# trailing newline would silently undercount by one right at the limit.
main_swift_lines="$(awk 'END { print NR }' "$MAIN_SWIFT")"
if (( main_swift_lines > MAIN_SWIFT_LINE_LIMIT )); then
  echo "main.swift is $main_swift_lines lines, over the $MAIN_SWIFT_LINE_LIMIT-line freeze limit." >&2
  echo "New @Published state / controller methods belong in an extension HarnessController in DSH<Feature>.swift; new views belong in their own <Feature>View.swift. See AGENTS.md's 'State management pattern' and CLAUDE.md's '质量规范'." >&2
  exit 1
fi
echo "main.swift size check: OK ($main_swift_lines/$MAIN_SWIFT_LINE_LIMIT lines)"

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

if [[ "$MODE" == "unit" ]]; then
  UNIT_DIR="$(mktemp -d)"
  trap 'rm -rf "$UNIT_DIR"' EXIT
  # Same production source glob as the real build, compiled as a library
  # (-enable-testing exposes `internal` declarations to @testable import)
  # instead of an app executable — main.swift's own @main entry point never
  # gets linked into an executable here, so it can't collide with the test
  # runner's @main below.
  swiftc -parse-as-library -enable-testing -emit-library -emit-module -module-name DSHAppLib \
    -o "$UNIT_DIR/libDSHAppLib.dylib" -module-link-name DSHAppLib \
    "$ROOT"/macos/DSHApp/*.swift -framework AppKit -framework SwiftUI
  swiftc -parse-as-library -I "$UNIT_DIR" -L "$UNIT_DIR" -lDSHAppLib \
    -o "$UNIT_DIR/dsh-unit-tests" \
    "$ROOT"/macos/DSHTests/*.swift -framework AppKit -framework SwiftUI
  DYLD_LIBRARY_PATH="$UNIT_DIR" "$UNIT_DIR/dsh-unit-tests"
fi
