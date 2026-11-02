#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib-test-library.sh"
SWIFT_TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"
PERMISSIONS="$ROOT/macos/DSHApp/Sessions/DSHPermissions.swift"
SUBMISSION="$ROOT/macos/DSHApp/Composer/DSHComposerSubmission.swift"
COMPOSER="$ROOT/macos/DSHApp/Composer/ComposerView.swift"
SETTINGS="$ROOT/macos/DSHApp/Settings/DSHSettingsView.swift"
FOLLOW="$ROOT/macos/DSHApp/Host/DSHHostSessionFollow.swift"
FIXTURE="$ROOT/scripts/fixtures/permission-composer-snapshot-check.swift"
BUILD="$(mktemp -d)"
SNAPSHOT_DIR="${PERMISSION_COMPOSER_SNAPSHOT_DIR:-${TMPDIR:-/tmp}/dsh-permission-composer-snapshots}"
trap 'rm -rf "$BUILD"' EXIT

grep -q 'struct PermissionMenu' "$ROOT/macos/DSHApp/Sessions/PermissionViews.swift" || {
  echo "permission-composer-ui: missing native permission menu" >&2
  exit 1
}
grep -q 'PermissionMenu()' "$COMPOSER" || {
  echo "permission-composer-ui: composer does not render the permission menu" >&2
  exit 1
}
grep -q 'Button(action: harness.steerDraft)' "$COMPOSER" || {
  echo "permission-composer-ui: running composer has no steer action" >&2
  exit 1
}
grep -q 'Button(action: harness.queueDraft)' "$COMPOSER" || {
  echo "permission-composer-ui: running composer has no queue action" >&2
  exit 1
}
grep -q 'harness.activeSubagentAddress != nil || !visibleQueuedItems.isEmpty' "$COMPOSER" || {
  echo "permission-composer-ui: root queue action is not gated by existing queued messages" >&2
  exit 1
}
grep -q 'QueueDockView(items: visibleQueuedItems)' "$COMPOSER" \
  && grep -q 'DSHQueueChrome.settleDelayMilliseconds' "$COMPOSER" || {
  echo "permission-composer-ui: queue chrome is not stabilized against transient snapshots" >&2
  exit 1
}
grep -q 'DraftImageStrip(' "$COMPOSER" || {
  echo "permission-composer-ui: composer does not render draft image thumbnails" >&2
  exit 1
}
grep -q 'DraftImagePasteMonitor(isEnabled: editorFocused)' "$COMPOSER" || {
  echo "permission-composer-ui: composer does not intercept image paste while focused" >&2
  exit 1
}
grep -q 'onPasteCommand(of: \[.image, .fileURL\])' "$COMPOSER" || {
  echo "permission-composer-ui: composer does not route image paste" >&2
  exit 1
}
grep -q 'harness.showModelPicker.toggle()' "$COMPOSER" || {
  echo "permission-composer-ui: model label does not open the stable picker panel" >&2
  exit 1
}
if grep -q 'Menu("推理强度")' "$COMPOSER"; then
  echo "permission-composer-ui: reasoning effort still uses a transient nested menu" >&2
  exit 1
fi
grep -q 'DraftImageLightbox(image:' "$COMPOSER" || {
  echo "permission-composer-ui: draft images have no enlarged preview" >&2
  exit 1
}
grep -q 'struct ComposerMetricChip' "$COMPOSER" \
  && grep -q 'contentTransition(reduceMotion ? .opacity : .numericText())' "$COMPOSER" \
  && grep -q 'DSHRunningBars(color: foreground, height: 8)' "$COMPOSER" || {
  echo "permission-composer-ui: usage projections lack styled animated metrics" >&2
  exit 1
}
grep -q 'BusyEnterSettingsRow()' "$SETTINGS" || {
  echo "permission-composer-ui: busy Enter setting is missing" >&2
  exit 1
}
grep -q 'PermissionDefaultSettingsRow()' "$SETTINGS" || {
  echo "permission-composer-ui: default permission setting is missing" >&2
  exit 1
}
grep -q 'key == "permissions"' "$FOLLOW" || {
  echo "permission-composer-ui: permission projection is not consumed" >&2
  exit 1
}
grep -q 'rememberPermissionSelection(selection, sessionID: sessionID, seq: seq)' "$FOLLOW" || {
  echo "permission-composer-ui: permission projection lacks sequence-aware routing" >&2
  exit 1
}
grep -q 'preferredBusyMode' "$SUBMISSION" || {
  echo "permission-composer-ui: busy submission policy is missing" >&2
  exit 1
}
grep -q 'submitSubagentComposerDraft' "$ROOT/macos/DSHApp/Composer/DSHQueue.swift" || {
  echo "permission-composer-ui: continuable subagent still bypasses the safe busy submission path" >&2
  exit 1
}
grep -q 'promptSubagent' "$SUBMISSION" || {
  echo "permission-composer-ui: shared subagent submission does not call the Host" >&2
  exit 1
}
grep -q 'executeCommand' "$ROOT/macos/DSHApp/Composer/DSHQueue.swift" || {
  echo "permission-composer-ui: running slash commands bypass the command plane" >&2
  exit 1
}
grep -q 'if displayedIsRunning { submitRunningDraft(mode: busyEnterMode) }' "$ROOT/macos/DSHApp/Composer/NativeCommandPalette.swift" || {
  echo "permission-composer-ui: running command-palette picks bypass busy command submission" >&2
  exit 1
}
grep -q 'danger-full-access' "$PERMISSIONS" || {
  echo "permission-composer-ui: full-access risk path is missing" >&2
  exit 1
}
grep -q 'confirmationDialog' "$ROOT/macos/DSHApp/Sessions/PermissionViews.swift" || {
  echo "permission-composer-ui: full-access confirmation is missing" >&2
  exit 1
}

rm -rf "$SNAPSHOT_DIR"
dsh_test_library "$BUILD"
swiftc -target "$SWIFT_TARGET" -parse-as-library -I "$DSH_TEST_LIBRARY_DIR" -L "$DSH_TEST_LIBRARY_DIR" -lDSHAppLib \
  -o "$BUILD/permission-composer-snapshot-check" \
  "$FIXTURE" -framework AppKit -framework SwiftUI -framework WebKit
DYLD_LIBRARY_PATH="$DSH_TEST_LIBRARY_DIR" "$BUILD/permission-composer-snapshot-check" "$SNAPSHOT_DIR"

echo "permission-composer-ui: OK"
