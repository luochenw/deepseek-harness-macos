#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEW="$ROOT/macos/DSHApp/NativeToolPresentationView.swift"
CONVERSATION="$ROOT/macos/DSHApp/ConversationView.swift"
SUPPORT="$ROOT/macos/DSHApp/DSHToolPresentationSupport.swift"
SNAPSHOT_FIXTURE="$ROOT/scripts/fixtures/tool-presentation-snapshot-check.swift"
SNAPSHOT_BUILD="$(mktemp -d)"
SNAPSHOT_DIR="${TOOL_PRESENTATION_SNAPSHOT_DIR:-${TMPDIR:-/tmp}/dsh-tool-presentation-snapshots}"
trap 'rm -rf "$SNAPSHOT_BUILD"' EXIT

grep -q 'struct ToolPresentationContent' "$VIEW" || {
  echo "tool-presentation-ui: missing shared structured content view" >&2
  exit 1
}
grep -q 'ToolPresentationContent(tool: activity, compact: true)' "$CONVERSATION" || {
  echo "tool-presentation-ui: transcript does not reuse structured tool content" >&2
  exit 1
}
grep -q 'ToolCallRow(' "$SNAPSHOT_FIXTURE" || {
  echo "tool-presentation-ui: snapshot must render real expanded transcript tool rows" >&2
  exit 1
}
grep -q 'tool-inline-' "$SNAPSHOT_FIXTURE" || {
  echo "tool-presentation-ui: snapshot must render each inline card kind independently" >&2
  exit 1
}
grep -q 'DSHDisclosureWindow' "$VIEW" || {
  echo "tool-presentation-ui: structured cards must use the shared disclosure window" >&2
  exit 1
}
grep -q 'DSHSourceTokenizer' "$VIEW" || {
  echo "tool-presentation-ui: read cards must use source tokenization" >&2
  exit 1
}
grep -q 'ToolPathView(path: path, compact: compact)' "$VIEW" || {
  echo "tool-presentation-ui: details search matches must keep file actions" >&2
  exit 1
}
grep -q 'case "terminal"' "$VIEW" || {
  echo "tool-presentation-ui: terminal card branch is missing" >&2
  exit 1
}
grep -q 'case "web"' "$VIEW" || {
  echo "tool-presentation-ui: web card branch is missing" >&2
  exit 1
}
grep -q 'struct DSHDisclosureWindow' "$SUPPORT" || {
  echo "tool-presentation-ui: missing pure disclosure support" >&2
  exit 1
}

rm -rf "$SNAPSHOT_DIR"
swiftc -parse-as-library -enable-testing -emit-library -emit-module -module-name DSHAppLib \
  -o "$SNAPSHOT_BUILD/libDSHAppLib.dylib" -module-link-name DSHAppLib \
  "$ROOT"/macos/DSHApp/*.swift -framework AppKit -framework SwiftUI
swiftc -parse-as-library -I "$SNAPSHOT_BUILD" -L "$SNAPSHOT_BUILD" -lDSHAppLib \
  -o "$SNAPSHOT_BUILD/tool-presentation-snapshot-check" \
  "$SNAPSHOT_FIXTURE" -framework AppKit -framework SwiftUI
DYLD_LIBRARY_PATH="$SNAPSHOT_BUILD" "$SNAPSHOT_BUILD/tool-presentation-snapshot-check" "$SNAPSHOT_DIR"

echo "tool-presentation-ui: OK"
