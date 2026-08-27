#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="${NODE_SOURCE:-$(command -v node || true)}"
PLUGIN="${AGENT_PLATFORM_PLUGIN_PATH:-$ROOT/macos/Runtime-extras/dsh-agent-platform}"

[[ -n "$NODE" && -x "$NODE" ]] || {
  echo "agent-platform-runtime: Node runtime not found. Install Node.js, or set NODE_SOURCE to a node executable." >&2
  exit 1
}
node_version="$("$NODE" -p 'process.versions.node' 2>/dev/null || true)"
[[ "$node_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "agent-platform-runtime: NODE_SOURCE is not a Node.js executable: $NODE" >&2
  exit 1
}
[[ -d "$PLUGIN" ]] || {
  echo "agent-platform-runtime: missing plugin at $PLUGIN" >&2
  exit 1
}

shopt -s nullglob
modules=("$PLUGIN"/lib/*.js)
tests=("$PLUGIN"/test/*.test.js)
shopt -u nullglob
(( ${#modules[@]} > 0 )) || {
  echo "agent-platform-runtime: no plugin modules found in $PLUGIN/lib" >&2
  exit 1
}
(( ${#tests[@]} > 0 )) || {
  echo "agent-platform-runtime: no plugin tests found in $PLUGIN/test" >&2
  exit 1
}

for module in "${modules[@]}"; do
  "$NODE" --check "$module"
done
"$NODE" --test "${tests[@]}"
DSH_SOURCE="${DSH_SOURCE:-}"
if [[ -z "$DSH_SOURCE" ]] && command -v npm >/dev/null; then
  DSH_SOURCE="$(npm root -g 2>/dev/null || true)/@deepseek-ai/dsh"
fi
if [[ -n "$DSH_SOURCE" && -f "$DSH_SOURCE/package.json" ]]; then
  DSH_SOURCE="$DSH_SOURCE" "$NODE" "$ROOT/scripts/test-agent-platform-runtime-patch.mjs"
else
  "$NODE" "$ROOT/scripts/test-agent-platform-runtime-patch.mjs"
fi
echo "agent-platform-runtime: OK"
