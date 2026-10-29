#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"
PRESENTATION="$ROOT/macos/DSHApp/Transcript/DSHConversationPresentation.swift"
VIEW="$ROOT/macos/DSHApp/Transcript/ConversationView.swift"
HISTORY="$ROOT/macos/DSHApp/Host/DSHHistory.swift"
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
grep -q 'DSHHistoryCachePolicy' "$HISTORY" \
  && grep -q 'preservingCachedHistory' "$ROOT/macos/DSHApp/Host/DSHHostSessionFollow.swift" \
  && grep -q 'retainingVisibleHistory' "$ROOT/macos/DSHApp/Host/DSHHostSessionFollow.swift" \
  && grep -q 'replaceVisibleOnCompletion' "$HISTORY" || {
  echo "conversation-history-ui: unchanged complete sessions must reuse cached history" >&2
  exit 1
}
grep -q 'displayedConversationMessageToken' "$PRESENTATION" || {
  echo "conversation-history-ui: transcript presentation token is missing" >&2
  exit 1
}
grep -q 'DSHConversationFoldRegistry' "$VIEW" || {
  echo "conversation-history-ui: transcript folding must be cached across unrelated updates" >&2
  exit 1
}
# ① the bottom anchor may only apply to the FIRST layout pass; a size-change
# anchor is exactly the bug this gate now guards against. ② the restore must be
# generation-gated (a ROW layout, never a replayed snapshot), the entry clamp
# needs more than one trigger, and the bridge must validate the scroll view it
# picks instead of trusting source order.
grep -q 'dshInitialBottomScrollAnchor()' "$VIEW" \
  && grep -q 'defaultScrollAnchor(.bottom, for: .initialOffset)' "$ROOT/macos/DSHApp/Transcript/DSHConversationScrollStability.swift" \
  && grep -q 'DSHConversationScrollPolicy.shouldFollowTail' "$VIEW" \
  && grep -q 'beginPrependRestore' "$VIEW" \
  && grep -q 'measurements.takePendingRestore()' "$VIEW" \
  && grep -q 'measurements.cancelRestore()' "$VIEW" \
  && grep -q 'capturePrependAnchorIfReading' "$VIEW" \
  && grep -q 'scrollViewBox.clampOnEntry()' "$VIEW" \
  && grep -q 'dshLocateEnclosingScrollView(from: self' "$ROOT/macos/DSHApp/Transcript/DSHConversationScrollStability.swift" \
  && grep -q 'viewDidMoveToWindow' "$ROOT/macos/DSHApp/Transcript/DSHConversationScrollStability.swift" \
  && grep -q 'documentView is NSTextView' "$ROOT/macos/DSHApp/Transcript/DSHConversationScrollStability.swift" \
  && grep -q 'didClampEntry' "$ROOT/macos/DSHApp/Transcript/DSHConversationScrollStability.swift" \
  && grep -q 'id(harness.displayedConversationContextKey' "$VIEW" \
  && grep -q 'scrollRequestGeneration' "$VIEW" \
  && grep -q 'shouldFollowTail(comparedTo:' "$VIEW" \
  && grep -q 'overlay(alignment: .top)' "$VIEW" || {
  echo "conversation-history-ui: transcript entry and incremental history need one stable bottom-follow policy" >&2
  exit 1
}
# The document coordinate space must live INSIDE the ScrollView. Attaching the
# same name to the ScrollView resolves against the clip view, which silently
# turns every row frame viewport-relative (the regression that broke ②).
grep -q '\.dshTranscriptDocumentSpace()' "$VIEW" || {
  echo "conversation-history-ui: row frames must be measured in the transcript's document space" >&2
  exit 1
}
grep -q 'coordinateSpace(name: "dshConversationContent")' "$VIEW" && {
  echo "conversation-history-ui: the document space must not be attached to the ScrollView" >&2
  exit 1
}
grep -q 'ScrollView(.vertical, showsIndicators: false)' "$VIEW" || {
  echo "conversation-history-ui: transcript must start gutterless before applying overlay scrollers" >&2
  exit 1
}

rm -rf "$SNAPSHOT_DIR"
swiftc -target "$SWIFT_TARGET" -parse-as-library -enable-testing -emit-library -emit-module -module-name DSHAppLib \
  -o "$BUILD/libDSHAppLib.dylib" -module-link-name DSHAppLib \
  "$ROOT"/macos/DSHApp/*/*.swift -framework AppKit -framework SwiftUI -framework WebKit
swiftc -target "$SWIFT_TARGET" -parse-as-library -I "$BUILD" -L "$BUILD" -lDSHAppLib \
  -o "$BUILD/conversation-history-snapshot-check" \
  "$FIXTURE" -framework AppKit -framework SwiftUI -framework WebKit
DYLD_LIBRARY_PATH="$BUILD" "$BUILD/conversation-history-snapshot-check" "$SNAPSHOT_DIR"

echo "conversation-history-ui: OK"
