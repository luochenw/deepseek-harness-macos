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

DSH_VERSION="$("$NODE" -e 'const fs=require("node:fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(p.version)' "$APP/Contents/Resources/Runtime/dsh/package.json")"
EXPECTED_DSH_VERSION="$(tr -d '[:space:]' < "$ROOT/scripts/dsh-runtime-version.txt")"
[[ "$DSH_VERSION" == "$EXPECTED_DSH_VERSION" ]] || {
  echo "Packaged DSH runtime is $DSH_VERSION, expected $EXPECTED_DSH_VERSION." >&2
  exit 1
}
HOST_ARGS=(web --host 127.0.0.1 --port 0 --no-open)
DSH_HOME="$HOME_DIR" "$NODE" "$DSH" "${HOST_ARGS[@]}" >"$LOG" 2>&1 &
PID=$!

for _ in $(seq 1 50); do
  URL="$(sed -n "s/^dsh web: //p" "$LOG" | head -1 || true)"
  [[ -n "$URL" ]] && break
  sleep 0.1
done
[[ -n "${URL:-}" ]] || { cat "$LOG" >&2; exit 1; }
if grep -Fq "opening the default browser" "$LOG"; then
  echo "Packaged Host unexpectedly attempted to open the Web UI." >&2
  cat "$LOG" >&2
  exit 1
fi
PORT="${URL##*:}"

call() {
  local method="$1" payload="$2" body
  printf -v body '{"type":"client-request","rpcId":"native-smoke-%s","method":"%s","payload":%s}' "$method" "$method" "$payload"
  curl -fsS -H "Host: 127.0.0.1:$PORT" -H "Content-Type: application/json" --data "$body" "$URL/api/$method"
}

assert_rpc() {
  local method="$1" payload="$2" check="$3" response
  response="$(call "$method" "$payload")"
  RESPONSE="$response" DSH_VERSION="$DSH_VERSION" "$NODE" -e "$check"
}

assert_gateway() {
  local method="$1" args="$2" check="$3"
  assert_rpc "$method" "{\"args\":$args}" "$check"
}

assert_rpc host.describe '{}' 'const d=JSON.parse(process.env.RESPONSE); const v=d.result?.value; if(d.type!=="server-response"||d.result?.ok!==true||typeof v?.version!=="string"||typeof v?.cwd!=="string"||typeof v?.home!=="string") process.exit(1)'
assert_rpc session.list '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.items)) process.exit(1)'
assert_rpc workspace.list '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.items)||!Array.isArray(d.result.value?.archivedSessionIds)) process.exit(1)'
assert_rpc settings.describe '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||typeof d.result.value?.writable!=="boolean"||!Array.isArray(d.result.value?.namespaces)) process.exit(1)'
assert_rpc llm.models '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.groups)) process.exit(1)'
assert_rpc agentPreset.list '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.presets)) process.exit(1)'
assert_gateway pluginInventory/list '{}' 'const d=JSON.parse(process.env.RESPONSE); const p=d.result?.value?.entries?.find((x)=>x.moduleName==="@dsh-app/dsh-tool-workbench"); if(d.result?.ok!==true||p?.enabled!==true||p?.fiberPhase!=="active") process.exit(1)'
[[ -f "$APP/Contents/Resources/Runtime/dsh/node_modules/@dsh-app/dsh-tool-workbench/package.json" ]] || {
  echo "Packaged workbench tool plugin is missing." >&2
  exit 1
}
"$NODE" -e '
  const fs = require("node:fs");
  const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (manifest.dependencies?.["@dsh-app/dsh-tool-workbench"] !== "0.1.0") process.exit(1);
' "$APP/Contents/Resources/Runtime/dsh/package.json"
# The native "无工作区" path omits cwd entirely. Keep that protocol surface
# covered independently from the Agent Platform smoke below, whose root
# session intentionally requires an explicit cwd.
assert_rpc session.create '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||typeof d.result.value?.sessionId!=="string") process.exit(1)'

# Write-path check: the assertions above are read-only. ui-theme is a
# fresh $DSH_HOME's known seed value ({"preference":"system"}, revision 0),
# so this exercises the real settings.update -> persist -> settings.describe
# round trip a Settings UI edit takes, not just that the RPC call is accepted.
assert_rpc settings.update '{"ns":"ui-theme","patch":{"preference":"dark"},"expectedRevision":0}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||d.result.value?.value?.preference!=="dark"||d.result.value?.revision!==1) process.exit(1)'
assert_rpc settings.describe '{}' 'const d=JSON.parse(process.env.RESPONSE); const ns=(d.result?.value?.namespaces||[]).find(n=>n.ns==="ui-theme"); if(d.result?.ok!==true||ns?.value?.preference!=="dark"||ns?.revision!==1) process.exit(1)'

# Permission and busy-composer settings are Host-owned. Verify the native
# selectors' exact write paths, then prove a future session inherits the
# default and a current session can switch through the command registry.
assert_rpc settings.mutate '{"ns":"permission","ops":[{"op":"set","path":["defaultPreset"],"value":"read-only"}],"expectedRevision":0}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||d.result.value?.value?.defaultPreset!=="read-only"||d.result.value?.revision!==1) process.exit(1)'
assert_rpc settings.mutate '{"ns":"ui-conversation","ops":[{"op":"set","path":["busyEnter"],"value":"steer"}],"expectedRevision":0}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||d.result.value?.value?.busyEnter!=="steer"||d.result.value?.revision!==1) process.exit(1)'
PERMISSION_SESSION_RESPONSE="$(call session.create '{}')"
PERMISSION_SESSION_ID="$(RESPONSE="$PERMISSION_SESSION_RESPONSE" "$NODE" -e 'const d=JSON.parse(process.env.RESPONSE); const id=d.result?.value?.sessionId; if(d.result?.ok!==true||typeof id!=="string") process.exit(1); process.stdout.write(id)')"
PERMISSION_LIST="$(call session.list '{}')"
RESPONSE="$PERMISSION_LIST" PERMISSION_SESSION_ID="$PERMISSION_SESSION_ID" "$NODE" -e 'const d=JSON.parse(process.env.RESPONSE); const s=d.result?.value?.items?.find(x=>x.sessionId===process.env.PERMISSION_SESSION_ID); if(d.result?.ok!==true||s?.projections?.values?.permissions?.currentValue!=="read-only") process.exit(1)'
PERMISSION_COMMAND_ARGS="{\"agentId\":\"$PERMISSION_SESSION_ID\",\"line\":\"/permission workspace-write\",\"images\":[]}"
assert_gateway commands/execute "$PERMISSION_COMMAND_ARGS" 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||d.result.value?.result?.kind!=="success") process.exit(1)'
PERMISSION_LIST="$(call session.list '{}')"
RESPONSE="$PERMISSION_LIST" PERMISSION_SESSION_ID="$PERMISSION_SESSION_ID" "$NODE" -e 'const d=JSON.parse(process.env.RESPONSE); const s=d.result?.value?.items?.find(x=>x.sessionId===process.env.PERMISSION_SESSION_ID); if(d.result?.ok!==true||s?.projections?.values?.permissions?.currentValue!=="workspace-write") process.exit(1)'
assert_gateway agentProfiles/list '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.items)) process.exit(1)'
assert_gateway agentProfiles/runtimeStatus '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!Array.isArray(d.result.value?.items)||!d.result.value.items.some((x)=>x.runtime==="dsh"&&x.available===true)) process.exit(1)'
PROFILE_RESPONSE="$(call agentProfiles/save '{"args":{"profile":{"name":"Smoke Agent","mention":"smoke-agent","defaultMode":"analysis","allowModelDispatch":false,"integrationPolicy":"manual","adapters":[{"id":"dsh","runtime":"dsh","enabled":true}]}}}')"
PROFILE_ID="$(RESPONSE="$PROFILE_RESPONSE" "$NODE" -e 'const d=JSON.parse(process.env.RESPONSE); const id=d.result?.value?.id; if(d.result?.ok!==true||typeof id!=="string") process.exit(1); process.stdout.write(id)')"
assert_gateway agentProfiles/list '{}' 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||!d.result.value?.items?.some((x)=>x.mention==="smoke-agent")) process.exit(1)'
assert_gateway agentProfiles/remove "{\"profileId\":\"$PROFILE_ID\"}" 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||d.result.value?.removed!==true) process.exit(1)'

# Scheduler/failure-isolation check without invoking an LLM: an unknown
# external Runtime must fail only its member, settle the Batch, and leave the
# Host responsive. The root Agent exists solely to own the durable Batch.
SESSION_RESPONSE="$(call session.create "{\"cwd\":\"$HOME_DIR\"}")"
ROOT_SESSION_ID="$(RESPONSE="$SESSION_RESPONSE" "$NODE" -e 'const d=JSON.parse(process.env.RESPONSE); const id=d.result?.value?.sessionId; if(d.result?.ok!==true||typeof id!=="string") process.exit(1); process.stdout.write(id)')"
FAIL_PROFILE_RESPONSE="$(call agentProfiles/save '{"args":{"profile":{"name":"Unavailable Runtime","mention":"unavailable-runtime","defaultMode":"analysis","allowModelDispatch":false,"integrationPolicy":"manual","adapters":[{"id":"missing","runtime":"missing-runtime","enabled":true}]}}}')"
FAIL_PROFILE_ID="$(RESPONSE="$FAIL_PROFILE_RESPONSE" "$NODE" -e 'const d=JSON.parse(process.env.RESPONSE); const id=d.result?.value?.id; if(d.result?.ok!==true||typeof id!=="string") process.exit(1); process.stdout.write(id)')"
BATCH_RESPONSE="$(call agentBatches/start "{\"args\":{\"profileId\":\"$FAIL_PROFILE_ID\",\"rootSessionId\":\"$ROOT_SESSION_ID\",\"initiatorSessionId\":\"$ROOT_SESSION_ID\",\"task\":\"smoke failure isolation\",\"mode\":\"analysis\",\"integrationPolicy\":\"manual\",\"source\":\"manual\"}}")"
BATCH_ID="$(RESPONSE="$BATCH_RESPONSE" EXPECTED_CWD="$HOME_DIR" "$NODE" -e 'const d=JSON.parse(process.env.RESPONSE); const b=d.result?.value; const id=b?.id; const tools=b?.sourceToolAllowlist; if(d.result?.ok!==true||typeof id!=="string"||b.capabilitySnapshotVersion!==1||b.sourceCwd!==process.env.EXPECTED_CWD||typeof b.sandboxMode!=="string"||!Array.isArray(tools)||!tools.includes("open_workbench_browser")||!tools.includes("open_workbench_markdown")) process.exit(1); process.stdout.write(id)')"
for _ in $(seq 1 50); do
  BATCH_DETAIL="$(call agentBatches/detail "{\"args\":{\"batchId\":\"$BATCH_ID\"}}")"
  if RESPONSE="$BATCH_DETAIL" "$NODE" -e 'const d=JSON.parse(process.env.RESPONSE); const b=d.result?.value; if(d.result?.ok!==true||b?.status!=="failed"||b.runs?.length!==1||b.runs[0]?.status!=="failed"||!String(b.runs[0]?.error).includes("runtime-unavailable")) process.exit(1)'; then
    break
  fi
  sleep 0.1
done
RESPONSE="$BATCH_DETAIL" "$NODE" -e 'const d=JSON.parse(process.env.RESPONSE); const b=d.result?.value; if(d.result?.ok!==true||b?.status!=="failed"||b.runs?.length!==1||b.runs[0]?.status!=="failed"||!String(b.runs[0]?.error).includes("runtime-unavailable")||typeof b.summary!=="string") process.exit(1)'
assert_gateway agentProfiles/remove "{\"profileId\":\"$FAIL_PROFILE_ID\"}" 'const d=JSON.parse(process.env.RESPONSE); if(d.result?.ok!==true||d.result.value?.removed!==true) process.exit(1)'
echo "native-host-api-smoke: OK ($URL)"
