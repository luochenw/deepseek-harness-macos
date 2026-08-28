#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERMISSIONS="$ROOT/macos/DSHApp/DSHPermissions.swift"
SUBMISSION="$ROOT/macos/DSHApp/DSHComposerSubmission.swift"
COMPOSER="$ROOT/macos/DSHApp/ComposerView.swift"
SETTINGS="$ROOT/macos/DSHApp/DSHSettingsView.swift"
EVENTS="$ROOT/macos/DSHApp/DSHEventSocket.swift"
FIXTURE="$ROOT/scripts/fixtures/permission-composer-snapshot-check.swift"
BUILD="$(mktemp -d)"
SNAPSHOT_DIR="${PERMISSION_COMPOSER_SNAPSHOT_DIR:-${TMPDIR:-/tmp}/dsh-permission-composer-snapshots}"
trap 'rm -rf "$BUILD"' EXIT

grep -q 'struct PermissionMenu' "$ROOT/macos/DSHApp/PermissionViews.swift" || {
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
grep -q 'BusyEnterSettingsRow()' "$SETTINGS" || {
  echo "permission-composer-ui: busy Enter setting is missing" >&2
  exit 1
}
grep -q 'PermissionDefaultSettingsRow()' "$SETTINGS" || {
  echo "permission-composer-ui: default permission setting is missing" >&2
  exit 1
}
grep -q 'key == "permissions"' "$EVENTS" || {
  echo "permission-composer-ui: permission projection is not consumed" >&2
  exit 1
}
grep -q 'rememberPermissionSelection(selection, sessionID: sessionId, seq: seq)' "$EVENTS" || {
  echo "permission-composer-ui: permission projection lacks sequence-aware routing" >&2
  exit 1
}
grep -q 'preferredBusyMode' "$SUBMISSION" || {
  echo "permission-composer-ui: busy submission policy is missing" >&2
  exit 1
}
grep -q 'submitSubagentComposerDraft' "$ROOT/macos/DSHApp/DSHQueue.swift" || {
  echo "permission-composer-ui: continuable subagent still bypasses the safe busy submission path" >&2
  exit 1
}
grep -q 'promptSubagent' "$SUBMISSION" || {
  echo "permission-composer-ui: shared subagent submission does not call the Host" >&2
  exit 1
}
grep -q 'executeCommand' "$ROOT/macos/DSHApp/DSHQueue.swift" || {
  echo "permission-composer-ui: running slash commands bypass the command plane" >&2
  exit 1
}
grep -q 'if displayedIsRunning { submitRunningDraft(mode: busyEnterMode) }' "$ROOT/macos/DSHApp/NativeCommandPalette.swift" || {
  echo "permission-composer-ui: running command-palette picks bypass busy command submission" >&2
  exit 1
}
grep -q 'danger-full-access' "$PERMISSIONS" || {
  echo "permission-composer-ui: full-access risk path is missing" >&2
  exit 1
}
grep -q 'confirmationDialog' "$ROOT/macos/DSHApp/PermissionViews.swift" || {
  echo "permission-composer-ui: full-access confirmation is missing" >&2
  exit 1
}

rm -rf "$SNAPSHOT_DIR"
swiftc -parse-as-library -enable-testing -emit-library -emit-module -module-name DSHAppLib \
  -o "$BUILD/libDSHAppLib.dylib" -module-link-name DSHAppLib \
  "$ROOT"/macos/DSHApp/*.swift -framework AppKit -framework SwiftUI
swiftc -parse-as-library -I "$BUILD" -L "$BUILD" -lDSHAppLib \
  -o "$BUILD/permission-composer-snapshot-check" \
  "$FIXTURE" -framework AppKit -framework SwiftUI
DYLD_LIBRARY_PATH="$BUILD" "$BUILD/permission-composer-snapshot-check" "$SNAPSHOT_DIR"

echo "permission-composer-ui: OK"
