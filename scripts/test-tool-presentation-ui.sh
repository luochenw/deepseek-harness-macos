#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"
VIEW="$ROOT/macos/DSHApp/Transcript/NativeToolPresentationView.swift"
CONVERSATION="$ROOT/macos/DSHApp/Transcript/ConversationView.swift"
SUPPORT="$ROOT/macos/DSHApp/Transcript/DSHToolPresentationSupport.swift"
THEME="$ROOT/macos/DSHApp/Design/DSHTheme.swift"
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
grep -q 'struct AdaptiveToolDetails' "$CONVERSATION" || {
  echo "tool-presentation-ui: adaptive expanded tool container is missing" >&2
  exit 1
}
grep -q 'DSHToolDetailsLayout.expandedHeight(measured: contentHeight)' "$CONVERSATION" || {
  echo "tool-presentation-ui: expanded tool content must size to content with a cap" >&2
  exit 1
}
grep -q 'struct ToolStatusHeader' "$CONVERSATION" || {
  echo "tool-presentation-ui: shared execution status header is missing" >&2
  exit 1
}
grep -q 'Text("执行中")' "$CONVERSATION" \
  && grep -q 'DSHRunningBars' "$CONVERSATION" \
  && grep -q 'DSHActivityLine' "$CONVERSATION" \
  && grep -q 'accessibilityReduceMotion' "$THEME" || {
  echo "tool-presentation-ui: live tool state feedback or reduced-motion handling is missing" >&2
  exit 1
}
if grep -q 'Text("有失败")' "$CONVERSATION"; then
  echo "tool-presentation-ui: instruction status must not surface failure labels" >&2
  exit 1
fi
grep -q 'title: instruction.title' "$CONVERSATION" || {
  echo "tool-presentation-ui: collapsed status must show the concrete instruction directly" >&2
  exit 1
}
if grep -Eq 'Text\("(工具执行|执行记录|已完成|执行代码|终端命令|修改文件|读取文件|搜索文件|执行指令)"\)' "$CONVERSATION"; then
  echo "tool-presentation-ui: instruction rows must not add generic execution or fallback labels" >&2
  exit 1
fi
grep -q 'struct ToolInstructionRow' "$CONVERSATION" || {
  echo "tool-presentation-ui: per-instruction disclosure is missing" >&2
  exit 1
}
grep -q 'DSHToolInstructionFlatten.instructions(from: activities)' "$CONVERSATION" \
  && grep -q 'ForEach(instructions)' "$CONVERSATION" \
  && grep -q 'ToolInstructionRow(' "$CONVERSATION" || {
  echo "tool-presentation-ui: expanded groups must flatten real tool calls into instruction rows" >&2
  exit 1
}
grep -q 'AdaptiveToolDetails {' "$CONVERSATION" || {
  echo "tool-presentation-ui: instruction results must remain behind a disclosure" >&2
  exit 1
}
grep -Fq 'private var expanded: Bool { userToggled ?? initiallyExpanded ?? false }' "$CONVERSATION" || {
  echo "tool-presentation-ui: every tool call must default to collapsed" >&2
  exit 1
}
if grep -Eq 'ToolStateDot|isDiffCard|⎿' "$CONVERSATION"; then
  echo "tool-presentation-ui: legacy tool dots, diff auto-expansion, or output summaries remain" >&2
  exit 1
fi
if grep -Eq 'Image\(systemName: "(doc\.text|magnifyingglass|globe|wrench\.and\.screwdriver)"' "$CONVERSATION"; then
  echo "tool-presentation-ui: inline execution status must use one stable terminal glyph" >&2
  exit 1
fi
grep -q 'ToolCallRow(' "$SNAPSHOT_FIXTURE" || {
  echo "tool-presentation-ui: snapshot must render real expanded transcript tool rows" >&2
  exit 1
}
grep -q 'tool-inline-' "$SNAPSHOT_FIXTURE" || {
  echo "tool-presentation-ui: snapshot must render each inline card kind independently" >&2
  exit 1
}
grep -q 'tool-inline-collapsed-stack' "$SNAPSHOT_FIXTURE" || {
  echo "tool-presentation-ui: snapshot must render the default collapsed tool stack" >&2
  exit 1
}
grep -q 'tool-inline-group-stack' "$SNAPSHOT_FIXTURE" || {
  echo "tool-presentation-ui: snapshot must verify that expanded groups show instructions, not results" >&2
  exit 1
}
grep -q 'running-terminal' "$SNAPSHOT_FIXTURE" || {
  echo "tool-presentation-ui: snapshot must cover the live running instruction state" >&2
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
grep -q 'case "image"' "$VIEW" \
  && grep -q 'AttachmentPreview(' "$VIEW" || {
  echo "tool-presentation-ui: read_image results are not rendered as clickable images" >&2
  exit 1
}
grep -q 'case "read_image"' "$SUPPORT" || {
  echo "tool-presentation-ui: read_image arguments are not represented" >&2
  exit 1
}
grep -q 'id: "image"' "$SNAPSHOT_FIXTURE" || {
  echo "tool-presentation-ui: image card snapshot fixture is missing" >&2
  exit 1
}
grep -q 'struct DSHDisclosureWindow' "$SUPPORT" || {
  echo "tool-presentation-ui: missing pure disclosure support" >&2
  exit 1
}

rm -rf "$SNAPSHOT_DIR"
swiftc -target "$SWIFT_TARGET" -parse-as-library -enable-testing -emit-library -emit-module -module-name DSHAppLib \
  -o "$SNAPSHOT_BUILD/libDSHAppLib.dylib" -module-link-name DSHAppLib \
  "$ROOT"/macos/DSHApp/*/*.swift -framework AppKit -framework SwiftUI -framework WebKit
swiftc -target "$SWIFT_TARGET" -parse-as-library -I "$SNAPSHOT_BUILD" -L "$SNAPSHOT_BUILD" -lDSHAppLib \
  -o "$SNAPSHOT_BUILD/tool-presentation-snapshot-check" \
  "$SNAPSHOT_FIXTURE" -framework AppKit -framework SwiftUI -framework WebKit
DYLD_LIBRARY_PATH="$SNAPSHOT_BUILD" "$SNAPSHOT_BUILD/tool-presentation-snapshot-check" "$SNAPSHOT_DIR"

echo "tool-presentation-ui: OK"
