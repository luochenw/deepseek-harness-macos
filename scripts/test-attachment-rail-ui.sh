#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib-test-library.sh"
SWIFT_TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"
ATTACHMENTS="$ROOT/macos/DSHApp/Composer/DSHAttachments.swift"
PREVIEW="$ROOT/macos/DSHApp/Transcript/NativeAttachmentPreview.swift"
CONVERSATION="$ROOT/macos/DSHApp/Transcript/ConversationView.swift"
EVENTS="$ROOT/macos/DSHApp/Core/DSHSessionEvent.swift"
SNAPSHOT_FIXTURE="$ROOT/scripts/fixtures/attachment-rail-snapshot-check.swift"
SNAPSHOT_BUILD="$(mktemp -d)"
SNAPSHOT_DIR="${ATTACHMENT_RAIL_SNAPSHOT_DIR:-${TMPDIR:-/tmp}/dsh-attachment-rail-snapshots}"
trap 'rm -rf "$SNAPSHOT_BUILD"' EXIT

grep -q 'struct AttachmentRail' "$PREVIEW" || {
  echo "attachment-rail-ui: missing AttachmentRail view" >&2
  exit 1
}
grep -q 'LazyHStack' "$PREVIEW" || {
  echo "attachment-rail-ui: rail must lazily materialize thumbnails" >&2
  exit 1
}
grep -q 'displayedAttachmentRailItems' "$ATTACHMENTS" || {
  echo "attachment-rail-ui: missing displayed attachment projection" >&2
  exit 1
}
grep -q 'displayedAttachmentSessionID' "$ATTACHMENTS" || {
  echo "attachment-rail-ui: missing source-session selection" >&2
  exit 1
}
grep -q 'AttachmentRail(items: harness.displayedAttachmentRailItems' "$CONVERSATION" || {
  echo "attachment-rail-ui: conversation header does not render the rail" >&2
  exit 1
}
grep -q 'DSHAttachmentRef.fromMessage' "$EVENTS" || {
  echo "attachment-rail-ui: live messages do not retain image references" >&2
  exit 1
}
grep -q 'retryImage' "$PREVIEW" || {
  echo "attachment-rail-ui: failed attachment reads need an explicit retry path" >&2
  exit 1
}

rm -rf "$SNAPSHOT_DIR"
dsh_test_library "$SNAPSHOT_BUILD"
swiftc -target "$SWIFT_TARGET" -parse-as-library -I "$DSH_TEST_LIBRARY_DIR" -L "$DSH_TEST_LIBRARY_DIR" -lDSHAppLib \
  -o "$SNAPSHOT_BUILD/attachment-rail-snapshot-check" \
  "$SNAPSHOT_FIXTURE" -framework AppKit -framework SwiftUI -framework WebKit
DYLD_LIBRARY_PATH="$DSH_TEST_LIBRARY_DIR" "$SNAPSHOT_BUILD/attachment-rail-snapshot-check" "$SNAPSHOT_DIR"

echo "attachment-rail-ui: OK"
