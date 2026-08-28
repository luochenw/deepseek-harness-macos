#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"
STATE="$ROOT/macos/DSHApp/DSHWorkbench.swift"
VIEW="$ROOT/macos/DSHApp/WorkbenchView.swift"
BROWSER="$ROOT/macos/DSHApp/NativeBrowserView.swift"
MARKDOWN="$ROOT/macos/DSHApp/NativeMarkdownDocumentView.swift"
EVENTS="$ROOT/macos/DSHApp/DSHEventSocket.swift"
RUNTIME_TOOL="$ROOT/macos/Runtime-extras/dsh-tool-workbench/lib/index.js"
RUNTIME_PATCH="$ROOT/scripts/patch-agent-platform-runtime.mjs"
SNAPSHOT_FIXTURE="$ROOT/scripts/fixtures/workbench-snapshot-check.swift"
BROWSER_SMOKE_FIXTURE="$ROOT/scripts/fixtures/workbench-browser-smoke.swift"
SNAPSHOT_BUILD="$(mktemp -d)"
SNAPSHOT_DIR="${WORKBENCH_SNAPSHOT_DIR:-${TMPDIR:-/tmp}/dsh-workbench-snapshots}"
WEB_ROOT="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$SNAPSHOT_BUILD" "$WEB_ROOT"
}
trap cleanup EXIT

grep -q 'DSHWorkbenchContext' "$STATE" || { echo "workbench-ui: missing session-scoped state" >&2; exit 1; }
grep -q 'DSHRadius.lg' "$VIEW" || { echo "workbench-ui: outer dock must use the shared radius scale" >&2; exit 1; }
grep -q 'DSHRadius.sm' "$VIEW" || { echo "workbench-ui: tabs must use the shared radius scale" >&2; exit 1; }
grep -q 'let webView: WKWebView' "$BROWSER" || { echo "workbench-ui: browser runtime must own a stable WKWebView" >&2; exit 1; }
grep -q 'DispatchSource.makeFileSystemObjectSource' "$MARKDOWN" || { echo "workbench-ui: Markdown must monitor external writes" >&2; exit 1; }
grep -q 'NSAllowsLocalNetworking' "$ROOT/macos/DSHApp/Info.plist" || { echo "workbench-ui: local HTTP navigation is not allowed by Info.plist" >&2; exit 1; }
grep -q 'consumeModelWorkbenchEvent' "$EVENTS" || { echo "workbench-ui: live tool results do not reach the native workbench" >&2; exit 1; }
grep -q 'case "tool/code-dispatch"' "$STATE" || { echo "workbench-ui: Code Mode workbench calls are not handled" >&2; exit 1; }
grep -Rq 'open_workbench_browser' "$(dirname "$RUNTIME_TOOL")" || { echo "workbench-ui: browser tool is not model-callable" >&2; exit 1; }
grep -Rq 'open_workbench_markdown' "$(dirname "$RUNTIME_TOOL")" || { echo "workbench-ui: Markdown tool is not model-callable" >&2; exit 1; }
grep -q '@dsh-app/dsh-tool-workbench' "$RUNTIME_PATCH" || { echo "workbench-ui: workbench tool package is not mounted" >&2; exit 1; }
if grep -Eq 'RoundedRectangle\(cornerRadius: *[0-9]' "$VIEW" "$BROWSER" "$MARKDOWN"; then
  echo "workbench-ui: workbench chrome must reuse DSHRadius tokens" >&2
  exit 1
fi

rm -rf "$SNAPSHOT_DIR"
swiftc -target "$SWIFT_TARGET" -parse-as-library -enable-testing -emit-library -emit-module -module-name DSHAppLib \
  -o "$SNAPSHOT_BUILD/libDSHAppLib.dylib" -module-link-name DSHAppLib \
  "$ROOT"/macos/DSHApp/*.swift -framework AppKit -framework SwiftUI -framework WebKit
swiftc -target "$SWIFT_TARGET" -parse-as-library -I "$SNAPSHOT_BUILD" -L "$SNAPSHOT_BUILD" -lDSHAppLib \
  -o "$SNAPSHOT_BUILD/workbench-snapshot-check" \
  "$SNAPSHOT_FIXTURE" -framework AppKit -framework SwiftUI -framework WebKit
DYLD_LIBRARY_PATH="$SNAPSHOT_BUILD" "$SNAPSHOT_BUILD/workbench-snapshot-check" "$SNAPSHOT_DIR"

swiftc -target "$SWIFT_TARGET" -parse-as-library -I "$SNAPSHOT_BUILD" -L "$SNAPSHOT_BUILD" -lDSHAppLib \
  -o "$SNAPSHOT_BUILD/workbench-browser-smoke" \
  "$BROWSER_SMOKE_FIXTURE" -framework AppKit -framework SwiftUI -framework WebKit
printf '%s\n' '<!doctype html><title>DSH Workbench Smoke</title><p>workbench-browser-ok</p>' > "$WEB_ROOT/index.html"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WEB_ROOT" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in {1..50}; do
  if curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$PORT/" >/dev/null
DYLD_LIBRARY_PATH="$SNAPSHOT_BUILD" "$SNAPSHOT_BUILD/workbench-browser-smoke" "http://127.0.0.1:$PORT/"

echo "workbench-ui: OK"
