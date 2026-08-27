#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_TEST="$ROOT/scripts/test-agent-platform-runtime.sh"
CI="$ROOT/.github/workflows/ci.yml"
BUILD="$ROOT/scripts/build-macos-app.sh"

[[ -x "$RUNTIME_TEST" ]] || {
  echo "agent-platform-runtime-script: missing executable runtime test at $RUNTIME_TEST" >&2
  exit 1
}
[[ -x "$BUILD" ]] || {
  echo "agent-platform-runtime-script: missing executable build script at $BUILD" >&2
  exit 1
}

set +e
non_node_output="$(NODE_SOURCE=/usr/bin/true "$RUNTIME_TEST" 2>&1)"
non_node_status=$?
set -e
if (( non_node_status == 0 )); then
  echo "agent-platform-runtime-script: a non-Node executable passed as NODE_SOURCE" >&2
  exit 1
fi
if [[ "$non_node_output" != *"not a Node.js executable"* ]]; then
  echo "agent-platform-runtime-script: non-Node rejection was not actionable" >&2
  printf '%s\n' "$non_node_output" >&2
  exit 1
fi

empty_plugin="$(mktemp -d)"
isolated_home="$(mktemp -d)"
trap 'rmdir "$empty_plugin" "$isolated_home" 2>/dev/null || true' EXIT
set +e
empty_plugin_output="$(AGENT_PLATFORM_PLUGIN_PATH="$empty_plugin" "$RUNTIME_TEST" 2>&1)"
empty_plugin_status=$?
set -e
if (( empty_plugin_status == 0 )); then
  echo "agent-platform-runtime-script: an empty plugin directory passed runtime validation" >&2
  exit 1
fi
if [[ "$empty_plugin_output" != *"no plugin modules found"* ]]; then
  echo "agent-platform-runtime-script: empty plugin rejection was not actionable" >&2
  printf '%s\n' "$empty_plugin_output" >&2
  exit 1
fi

set +e
isolated_runtime_output="$(
  HOME="$isolated_home" \
  CLAUDE_CODE_PATH="$isolated_home/missing-claude" \
  CODEX_PATH="$isolated_home/missing-codex" \
  ZCODE_PATH="$isolated_home/missing-zcode.cjs" \
  "$RUNTIME_TEST" 2>&1
)"
isolated_runtime_status=$?
set -e
if (( isolated_runtime_status != 0 )); then
  echo "agent-platform-runtime-script: runtime contract tests depend on locally installed external CLIs" >&2
  printf '%s\n' "$isolated_runtime_output" >&2
  exit 1
fi

grep -Fq 'NODE_LIB_DIR' "$BUILD" || {
  echo "agent-platform-runtime-script: build must stage Node dynamic libraries when present" >&2
  exit 1
}
grep -Fq 'libnode*.dylib' "$BUILD" || {
  echo "agent-platform-runtime-script: build must detect libnode dynamic libraries" >&2
  exit 1
}

grep -Fq 'npm install -g @deepseek-ai/dsh@0.1.0-rc.7' "$CI" || {
  echo "agent-platform-runtime-script: CI must pin DSH to the runtime-patch support boundary" >&2
  exit 1
}

echo "agent-platform-runtime-script: OK"
