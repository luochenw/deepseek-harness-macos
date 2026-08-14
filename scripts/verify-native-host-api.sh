#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/DeepSeek Harness.app}"
NODE="$APP/Contents/MacOS/node"
DSH="$APP/Contents/Resources/Runtime/dsh/lib/bin.js"
HOME_DIR="$(mktemp -d)"
LOG="$HOME_DIR/host.log"

cleanup() {
  [[ -n "${PID:-}" ]] && kill "$PID" 2>/dev/null || true
  wait "${PID:-}" 2>/dev/null || true
  rm -rf "$HOME_DIR"
}
trap cleanup EXIT

DSH_HOME="$HOME_DIR" "$NODE" "$DSH" web --host 127.0.0.1 --port 0 >"$LOG" 2>&1 &
PID=$!

for _ in $(seq 1 50); do
  URL="$(sed -n "s/^dsh web: //p" "$LOG" | head -1 || true)"
  [[ -n "$URL" ]] && break
  sleep 0.1
done
[[ -n "${URL:-}" ]] || { cat "$LOG" >&2; exit 1; }
PORT="${URL##*:}"

call() {
  local method="$1" payload="$2" body
  printf -v body '{"type":"client-request","rpcId":"native-smoke-%s","method":"%s","payload":%s}' "$method" "$method" "$payload"
  curl -fsS -H "Host: 127.0.0.1:$PORT" -H "Content-Type: application/json" --data "$body" "$URL/api/$method"
}

assert_rpc() {
  local method="$1" payload="$2" check="$3" response
  response="$(call "$method" "$payload")"
  RESPONSE="$response" "$NODE" -e "$check"
}

assert_rpc host.describe '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.type!=="server-response"||d.result?.ok!==true||typeof d.result.value?.version!=="string"||typeof d.result.value?.cwd!=="string") process.exit(1)'
assert_rpc session.list '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.items)) process.exit(1)'
assert_rpc workspace.list '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.items)||!Array.isArray(d.result.value?.archivedSessionIds)) process.exit(1)'
assert_rpc settings.describe '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||typeof d.result.value?.writable!=="boolean"||!Array.isArray(d.result.value?.namespaces)) process.exit(1)'
assert_rpc llm.models '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.groups)) process.exit(1)'
assert_rpc agentPreset.list '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.presets)) process.exit(1)'
echo "native-host-api-smoke: OK ($URL)"
