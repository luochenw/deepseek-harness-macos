#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="${NODE_SOURCE:-$(command -v node || true)}"

[[ -n "$NODE" && -x "$NODE" ]] || {
  echo "llm-runtime: Node runtime not found. Install Node.js, or set NODE_SOURCE to a node executable." >&2
  exit 1
}

# The patch tests run against fixtures, and additionally against the real
# prepared runtime when DSH_SOURCE points at one. Preparing here guarantees the
# runtime the build will bundle is the same one the tests exercised.
DSH_SOURCE="${DSH_SOURCE:-$("$ROOT/scripts/prepare-dsh-runtime.sh")}"
if [[ ! -f "$DSH_SOURCE/package.json" ]]; then
  echo "llm-runtime: prepared runtime is missing at $DSH_SOURCE" >&2
  exit 1
fi

DSH_SOURCE="$DSH_SOURCE" "$NODE" --test "$ROOT/scripts/test-llm-runtime-patch.mjs"
echo "llm-runtime: OK"
