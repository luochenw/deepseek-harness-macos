#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEW="$ROOT/macos/DSHApp/AgentPlatformView.swift"
WIRE="$ROOT/macos/DSHApp/DSHAgentPlatform.swift"
COMPOSER="$ROOT/macos/DSHApp/ComposerView.swift"
CONVERSATION="$ROOT/macos/DSHApp/ConversationView.swift"
SIDEBAR="$ROOT/macos/DSHApp/SidebarView.swift"
POLICY="$ROOT/macos/DSHApp/DSHAgentPlatformPolicy.swift"
POLICY_FIXTURE="$ROOT/scripts/fixtures/agent-platform-policy-check.swift"
SNAPSHOT_FIXTURE="$ROOT/scripts/fixtures/agent-platform-snapshot-check.swift"
POLICY_BIN="${TMPDIR:-/tmp}/dsh-agent-platform-policy-$$"
SNAPSHOT_BUILD="$(mktemp -d)"
SNAPSHOT_DIR="${AGENT_PLATFORM_SNAPSHOT_DIR:-${TMPDIR:-/tmp}/dsh-agent-platform-ui-snapshots}"
trap 'rm -f "$POLICY_BIN"; rm -rf "$SNAPSHOT_BUILD"' EXIT

[[ -f "$VIEW" ]] || { echo "agent-platform-ui: missing AgentPlatformView.swift" >&2; exit 1; }
grep -q 'AgentPlatformExecutionView' "$VIEW" || { echo "agent-platform-ui: execution view is missing" >&2; exit 1; }
grep -q 'AgentPlatformProfilesView' "$VIEW" || { echo "agent-platform-ui: profile view is missing" >&2; exit 1; }
grep -q 'AgentProfileEditorSheet' "$VIEW" || { echo "agent-platform-ui: profile editor sheet is missing" >&2; exit 1; }
grep -q 'AgentManualRunSheet' "$VIEW" || { echo "agent-platform-ui: manual run sheet is missing" >&2; exit 1; }
grep -q 'AgentProfilePalette' "$VIEW" || { echo "agent-platform-ui: composer @ palette is missing" >&2; exit 1; }
grep -q 'showAgentManagement' "$SIDEBAR" || { echo "agent-platform-ui: sidebar Agent entry is missing" >&2; exit 1; }
grep -q 'harness.submitComposer' "$COMPOSER" || { echo "agent-platform-ui: composer send path is not connected" >&2; exit 1; }
grep -q 'harness.toolDetail(activity)' "$CONVERSATION" || { echo "agent-platform-ui: transcript tool details are not reachable from the right panel" >&2; exit 1; }
grep -q 'agent-platform/batches' "$ROOT/macos/DSHApp/DSHProjections.swift" || { echo "agent-platform-ui: batch projection is missing" >&2; exit 1; }
grep -q 'ns: "agentProfiles", method: "list"' "$WIRE" || { echo "agent-platform-ui: profile gateway call is missing" >&2; exit 1; }
grep -q 'ns: "agentProfiles", method: "runtimeStatus"' "$WIRE" || { echo "agent-platform-ui: runtime status gateway call is missing" >&2; exit 1; }
grep -q 'profileSnapshot' "$WIRE" || { echo "agent-platform-ui: historical profile snapshot is missing" >&2; exit 1; }
grep -q 'integrationSummary' "$WIRE" || { echo "agent-platform-ui: integration evidence is missing" >&2; exit 1; }
swiftc "$POLICY" "$POLICY_FIXTURE" -o "$POLICY_BIN"
"$POLICY_BIN"
rm -rf "$SNAPSHOT_DIR"
swiftc -parse-as-library -enable-testing -emit-library -emit-module -module-name DSHAppLib \
  -o "$SNAPSHOT_BUILD/libDSHAppLib.dylib" -module-link-name DSHAppLib \
  "$ROOT"/macos/DSHApp/*.swift -framework AppKit -framework SwiftUI
swiftc -parse-as-library -I "$SNAPSHOT_BUILD" -L "$SNAPSHOT_BUILD" -lDSHAppLib \
  -o "$SNAPSHOT_BUILD/agent-platform-snapshot-check" \
  "$SNAPSHOT_FIXTURE" -framework AppKit -framework SwiftUI
DYLD_LIBRARY_PATH="$SNAPSHOT_BUILD" "$SNAPSHOT_BUILD/agent-platform-snapshot-check" "$SNAPSHOT_DIR"

echo "agent-platform-ui: OK"
