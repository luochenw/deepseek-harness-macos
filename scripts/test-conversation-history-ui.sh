#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"
PRESENTATION="$ROOT/macos/DSHApp/DSHConversationPresentation.swift"
VIEW="$ROOT/macos/DSHApp/ConversationView.swift"
HISTORY="$ROOT/macos/DSHApp/DSHHistory.swift"
FIXTURE="$ROOT/scripts/fixtures/conversation-history-snapshot-check.swift"
BUILD="$(mktemp -d)"
SNAPSHOT_DIR="${CONVERSATION_HISTORY_SNAPSHOT_DIR:-${TMPDIR:-/tmp}/dsh-conversation-history-snapshots}"
trap 'rm -rf "$BUILD"' EXIT

grep -q 'harness.displayedSession?.messages' "$VIEW" || {
  echo "conversation-history-ui: ConversationView does not render the complete message array" >&2
  exit 1
}
if grep -q '载入更早消息\|载入上一段\|载入下一段' "$VIEW"; then
  echo "conversation-history-ui: manual history pagination controls are still present" >&2
  exit 1
fi
grep -q 'displayedConversationMessageToken' "$VIEW" || {
  echo "conversation-history-ui: lightweight transcript change token is missing" >&2
  exit 1
}
grep -q 'loadAllOlderHistory' "$HISTORY" || {
  echo "conversation-history-ui: automatic complete-history loading is missing" >&2
  exit 1
}
grep -q 'displayedConversationMessageToken' "$PRESENTATION" || {
  echo "conversation-history-ui: transcript presentation token is missing" >&2
  exit 1
}

rm -rf "$SNAPSHOT_DIR"
swiftc -target "$SWIFT_TARGET" -parse-as-library -enable-testing -emit-library -emit-module -module-name DSHAppLib \
  -o "$BUILD/libDSHAppLib.dylib" -module-link-name DSHAppLib \
  "$ROOT"/macos/DSHApp/*.swift -framework AppKit -framework SwiftUI -framework WebKit
swiftc -target "$SWIFT_TARGET" -parse-as-library -I "$BUILD" -L "$BUILD" -lDSHAppLib \
  -o "$BUILD/conversation-history-snapshot-check" \
  "$FIXTURE" -framework AppKit -framework SwiftUI -framework WebKit
DYLD_LIBRARY_PATH="$BUILD" "$BUILD/conversation-history-snapshot-check" "$SNAPSHOT_DIR"

echo "conversation-history-ui: OK"
