#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"
WINDOW="$ROOT/macos/DSHApp/DSHConversationWindow.swift"
VIEW="$ROOT/macos/DSHApp/ConversationView.swift"
FIXTURE="$ROOT/scripts/fixtures/conversation-window-snapshot-check.swift"
BUILD="$(mktemp -d)"
SNAPSHOT_DIR="${CONVERSATION_WINDOW_SNAPSHOT_DIR:-${TMPDIR:-/tmp}/dsh-conversation-window-snapshots}"
trap 'rm -rf "$BUILD"' EXIT

grep -q 'static let capacity = 240' "$WINDOW" || {
  echo "conversation-window-ui: bounded materialization capacity is missing" >&2
  exit 1
}
grep -q 'harness.displayedWindowMessages' "$VIEW" || {
  echo "conversation-window-ui: ConversationView still renders the full transcript" >&2
  exit 1
}
grep -q 'displayedConversationMessageToken' "$VIEW" || {
  echo "conversation-window-ui: full message-array onChange was not replaced" >&2
  exit 1
}

rm -rf "$SNAPSHOT_DIR"
swiftc -target "$SWIFT_TARGET" -parse-as-library -enable-testing -emit-library -emit-module -module-name DSHAppLib \
  -o "$BUILD/libDSHAppLib.dylib" -module-link-name DSHAppLib \
  "$ROOT"/macos/DSHApp/*.swift -framework AppKit -framework SwiftUI -framework WebKit
swiftc -target "$SWIFT_TARGET" -parse-as-library -I "$BUILD" -L "$BUILD" -lDSHAppLib \
  -o "$BUILD/conversation-window-snapshot-check" \
  "$FIXTURE" -framework AppKit -framework SwiftUI -framework WebKit
DYLD_LIBRARY_PATH="$BUILD" "$BUILD/conversation-window-snapshot-check" "$SNAPSHOT_DIR"

echo "conversation-window-ui: OK"
