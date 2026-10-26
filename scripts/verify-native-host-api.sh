#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/DeepSeek Harness.app}"
NODE="$APP/Contents/MacOS/node"
DSH="$APP/Contents/Resources/Runtime/dsh/lib/bin.js"
RUNTIME_MODULES="$(cd "$APP/Contents/Resources/Runtime/dsh/node_modules" && pwd)"
HOME_DIR="$(mktemp -d)"
LOG="$HOME_DIR/host.log"
COOKIE_JAR="$HOME_DIR/cookies.txt"

cleanup() {
  [[ -n "${PID:-}" ]] && kill "$PID" 2>/dev/null || true
  wait "${PID:-}" 2>/dev/null || true
  rm -rf "$HOME_DIR"
}
trap cleanup EXIT

DSH_VERSION="$("$NODE" -e 'const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(p.version)' "$APP/Contents/Resources/Runtime/dsh/package.json")"
EXPECTED_DSH_VERSION="$(tr -d '[:space:]' < "$ROOT/scripts/dsh-runtime-version.txt")"
[[ "$DSH_VERSION" == "$EXPECTED_DSH_VERSION" ]] || {
  echo "Packaged DSH runtime is $DSH_VERSION, expected $EXPECTED_DSH_VERSION." >&2
  exit 1
}

DSH_HOME="$HOME_DIR" "$NODE" "$DSH" web --host 127.0.0.1 --port 0 --no-open >"$LOG" 2>&1 &
PID=$!

for _ in $(seq 1 50); do
  LAUNCH_URL="$(sed -n "s/^dsh web: //p" "$LOG" | head -1 || true)"
  [[ -n "$LAUNCH_URL" ]] && break
  sleep 0.1
done
[[ -n "${LAUNCH_URL:-}" ]] || { cat "$LOG" >&2; exit 1; }
read -r BASE_URL PORT COOKIE <<EOF
$(LAUNCH_URL="$LAUNCH_URL" "$NODE" -e '
  const u = new URL(process.env.LAUNCH_URL);
  process.stdout.write(`${u.origin} ${u.port} `);
')
EOF

SWIFT_TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"
xcrun swiftc -target "$SWIFT_TARGET" -parse-as-library \
  "$ROOT/macos/DSHApp/DSHHostGateway.swift" \
  "$ROOT/scripts/fixtures/host-handshake-check.swift" \
  -o "$HOME_DIR/host-handshake-check"
"$HOME_DIR/host-handshake-check" "$LAUNCH_URL"

curl -fsS -D "$HOME_DIR/handshake.headers" -c "$COOKIE_JAR" -o /dev/null "$LAUNCH_URL"
COOKIE="$(awk 'tolower($1)=="set-cookie:" {print $2; exit}' "$HOME_DIR/handshake.headers")"
[[ "$COOKIE" == dsh-auth-* ]] || { echo "Host did not install a dsh-auth cookie." >&2; exit 1; }

call() {
  local method="$1" args="$2" body
  printf -v body '{"type":"client-request","rpcId":"native-smoke-%s","method":"%s","payload":{"args":%s}}' "$method" "$method" "$args"
  curl -fsS -b "$COOKIE_JAR" -H "Host: 127.0.0.1:$PORT" -H "Content-Type: application/json" \
    --data "$body" "$BASE_URL/api/$method"
}

assert_rpc() {
  local method="$1" args="$2" check="$3" response
  response="$(call "$method" "$args")"
  RESPONSE="$response" DSH_VERSION="$DSH_VERSION" "$NODE" -e "$check"
}

assert_stream() {
  local endpoint="$1" args="$2" check="$3" response
  response="$(WS_URL="ws://127.0.0.1:$PORT/api/remote.mux" HOST="127.0.0.1:$PORT" COOKIE="$COOKIE" \
    ENDPOINT="$endpoint" ARGS="$args" RUNTIME_MODULES="$RUNTIME_MODULES" \
    "$NODE" -e '
      const WebSocket = require(process.env.RUNTIME_MODULES + "/ws");
      const ws = new WebSocket(process.env.WS_URL, {
        headers: { Host: process.env.HOST, Cookie: process.env.COOKIE },
      });
      const timer = setTimeout(() => process.exit(1), 5000);
      ws.on("open", () => ws.send(JSON.stringify({
        type: "open",
        streamId: "native-smoke-stream",
        endpoint: process.env.ENDPOINT,
        payload: { args: JSON.parse(process.env.ARGS) },
      })));
      ws.on("message", (bytes) => {
        const frame = JSON.parse(String(bytes));
        if (frame.type === "error") process.exit(1);
        if (frame.type !== "item") return;
        clearTimeout(timer);
        process.stdout.write(JSON.stringify(frame.value));
        ws.close();
        process.exit(0);
      });
    ')"
  STREAM_RESPONSE="$response"
  RESPONSE="$response" "$NODE" -e "$check"
}

assert_rpc session/list '{"_request":{}}' 'const d=JSON.parse(process.env.RESPONSE); if(d.type!=="server-response"||d.result?.ok!==true||!Array.isArray(d.result.value?.items)) process.exit(1)'
assert_rpc settings/describe '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||typeof d.result.value?.writable!=="boolean"||!Array.isArray(d.result.value?.namespaces)) process.exit(1)'
assert_rpc session/modelCatalog '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||d.result.value?.default?.model!=="deepseek-flash"||!Array.isArray(d.result.value?.groups)) process.exit(1)'
assert_rpc agentPresets/list '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.presets)) process.exit(1)'
assert_rpc permissionPresets/catalog '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.options)||typeof d.result.value?.defaultPreset!=="string") process.exit(1)'
assert_stream workspace/follow '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.type!=="baseline"||!Array.isArray(d.value?.items)||!Array.isArray(d.value?.archivedSessionIds)) process.exit(1)'
assert_stream session/control '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.type!=="baseline"||typeof d.value?.projections!=="object") process.exit(1)'

assert_rpc settings/update '{"ns":"ui-theme","patch":{"preference":"dark"},"expectedRevision":0}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||d.result.value?.value?.preference!=="dark"||d.result.value?.revision!==1) process.exit(1)'
assert_rpc settings/describe '{}' 'const d=JSON.parse(process.env.RESPONSE); const ns=(d.result?.value?.namespaces||[]).find(n=>n.ns==="ui-theme"); if(d.result?.ok!==true||ns?.value?.preference!=="dark"||ns?.revision!==1) process.exit(1)'
assert_rpc credentials/set '{"ref":"DSH_NATIVE_SMOKE_KEY","value":"temporary"}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true) process.exit(1)'
assert_rpc credentials/unset '{"ref":"DSH_NATIVE_SMOKE_KEY"}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true) process.exit(1)'

SESSION_RESPONSE="$(call session/create '{"request":{"cwd":"'"$HOME_DIR"'"}}')"
ROOT_SESSION_ID="$(RESPONSE="$SESSION_RESPONSE" "$NODE" -e 'const d=JSON.parse(process.env.RESPONSE); const id=d.result?.value?.sessionId; if(d.result?.ok!==true||typeof id!=="string") process.exit(1); process.stdout.write(id)')"
assert_stream session/follow '{"request":{"address":{"kind":"session","sessionId":"'"$ROOT_SESSION_ID"'"},"maxMessages":100,"turnWindow":{"minMessages":20,"minTurns":2},"assistantStream":true}}' 'const d=JSON.parse(process.env.RESPONSE); if(d.type!=="snapshot"||typeof d.header?.id!=="string"||!Array.isArray(d.records)||typeof d.cursor!=="number") process.exit(1)'
FOLLOW_SNAPSHOT="$STREAM_RESPONSE"
FOLLOW_CURSOR="$(RESPONSE="$FOLLOW_SNAPSHOT" "$NODE" -e 'const d=JSON.parse(process.env.RESPONSE); process.stdout.write(String(d.cursor))')"
FOLLOW_OLDEST="$(RESPONSE="$FOLLOW_SNAPSHOT" "$NODE" -e 'const d=JSON.parse(process.env.RESPONSE); process.stdout.write(String(d.records[0]?.event?.seq ?? 0))')"
assert_rpc session/page '{"request":{"address":{"kind":"session","sessionId":"'"$ROOT_SESSION_ID"'"},"throughSeq":'"$FOLLOW_CURSOR"',"beforeSeq":'"$FOLLOW_OLDEST"',"maxMessages":100,"turnWindow":{"minMessages":20,"minTurns":2}}}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.records)||typeof d.result.value?.hasMore!=="boolean") process.exit(1)'
assert_stream job/list '{"request":{"sessionId":"'"$ROOT_SESSION_ID"'"}}' 'const d=JSON.parse(process.env.RESPONSE); if(d.type!=="rows"||!Array.isArray(d.jobs)) process.exit(1)'

assert_rpc agentProfiles/list '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.items)) process.exit(1)'
PROFILE_RESPONSE="$(call agentProfiles/save '{"profile":{"name":"Smoke Agent","mention":"smoke-agent","defaultMode":"analysis","allowModelDispatch":false,"integrationPolicy":"manual","adapters":[{"id":"dsh","runtime":"dsh","enabled":true}]}}')"
PROFILE_ID="$(RESPONSE="$PROFILE_RESPONSE" "$NODE" -e 'const d=JSON.parse(process.env.RESPONSE); const id=d.result?.value?.id; if(d.result?.ok!==true||typeof id!=="string") process.exit(1); process.stdout.write(id)')"
call agentProfiles/remove '{"profileId":"'"$PROFILE_ID"'"}' >/dev/null

echo "native-host-api-smoke: OK ($BASE_URL)"
