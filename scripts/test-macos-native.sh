#!/bin/bash
# Native macOS checks without an invented Xcode or SwiftPM project.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib-test-library.sh"
APP="${APP_PATH:-$ROOT/dist/DeepSeek Harness.app}"
MODE="contract"
MINIMUM_MACOS_VERSION="14.0"
SWIFT_TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos${MINIMUM_MACOS_VERSION}}"
export SWIFT_TARGET

usage() {
  cat <<'EOF'
Usage: ./scripts/test-macos-native.sh [--smoke [APP_PATH] | --unit | --quick]

Without arguments, typechecks all production Swift sources and checks that the
native Settings surface stays scrollable, uses visible field chrome, and does
not restore the legacy Relay-only model entry. This includes the compile-time
fixtures in macos/DSHApp/App/NativeContractCheck.swift, which exercise native RPC
envelope, prompt, settings-patch, queue, and attachment wire types. It also
runs Agent-platform, workbench, permission/composer, and long-conversation
layout snapshots plus a loopback WKWebView smoke, and enforces the main.swift
freeze (see CLAUDE.md/AGENTS.md): main.swift may only shrink, never grow past
its recorded baseline. It also enforces the feature-directory layout: no Swift
sources directly under macos/DSHApp/, and an AGENTS.md (<= 60 lines) plus a
CLAUDE.md in every domain directory that holds sources.

--smoke [APP_PATH] additionally starts the packaged DSH Host and verifies
token authentication, session/workspace/control streams, settings writes and
Agent Profile CRUD. Build the app first, or pass its path.

--unit additionally builds the macos/DSHApp domain directories as a library
(-enable-testing) and runs macos/DSHTests/*.swift against it via @testable
import — no Xcode/XCTest, matching the project's no-project-file build
philosophy.

--quick is the inner-loop check while developing: the gates, the design-system
check and the --unit build and tests, without the UI snapshot scripts that each
recompile every source. Run the full suite once before reporting done.
EOF
}

case "${1:-}" in
  "") ;;
  --smoke)
    MODE="smoke"
    [[ $# -le 2 ]] || { usage >&2; exit 64; }
    APP="${2:-$APP}"
    ;;
  --unit)
    MODE="unit"
    [[ $# -le 1 ]] || { usage >&2; exit 64; }
    ;;
  --quick)
    MODE="quick"
    [[ $# -le 1 ]] || { usage >&2; exit 64; }
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac

command -v swiftc >/dev/null || { echo "swiftc is required (install Xcode Command Line Tools)." >&2; exit 1; }
command -v plutil >/dev/null || { echo "plutil is required (macOS only)." >&2; exit 1; }

# main.swift is frozen: new @Published state, controller methods, and
# top-level Views go in DSH<Feature>.swift extensions / <Feature>View.swift
# instead (see CLAUDE.md "质量规范" / AGENTS.md). This gate is what makes that
# a rule instead of a suggestion — it only ever ratchets down.
MAIN_SWIFT="$ROOT/macos/DSHApp/App/main.swift"
MAIN_SWIFT_LINE_LIMIT=349
MAIN_SWIFT_PUBLISHED_LIMIT=50
[[ -f "$MAIN_SWIFT" ]] || { echo "Expected main.swift at $MAIN_SWIFT — did it move or get removed (e.g. finished the Phase 2 split)? Update MAIN_SWIFT and MAIN_SWIFT_LINE_LIMIT here, and the freeze rule in AGENTS.md/CLAUDE.md, to match." >&2; exit 1; }
# awk, not `wc -l`: wc -l counts newline bytes, so a final line with no
# trailing newline would silently undercount by one right at the limit.
main_swift_lines="$(awk 'END { print NR }' "$MAIN_SWIFT")"
if (( main_swift_lines > MAIN_SWIFT_LINE_LIMIT )); then
  echo "main.swift is $main_swift_lines lines, over the $MAIN_SWIFT_LINE_LIMIT-line freeze limit." >&2
  echo "New @Published state / controller methods belong in an extension HarnessController in DSH<Feature>.swift; new views belong in their own <Feature>View.swift. See AGENTS.md's 'State management pattern' and CLAUDE.md's '质量规范'." >&2
  exit 1
fi
echo "main.swift size check: OK ($main_swift_lines/$MAIN_SWIFT_LINE_LIMIT lines)"
main_swift_published="$(grep -c '@Published' "$MAIN_SWIFT")"
if (( main_swift_published > MAIN_SWIFT_PUBLISHED_LIMIT )); then
  echo "main.swift declares $main_swift_published @Published properties, over the limit of $MAIN_SWIFT_PUBLISHED_LIMIT." >&2
  echo "Session-scoped state belongs in DSHRootSessionScope; domain state belongs in a class held by stateBag." >&2
  exit 1
fi

# Session timeline gates (see the session-timeline Agent Note). Line counts did
# not stop state and event handling from spreading, so these check the coupling
# directly: one reader of event shapes, one owner of controller state, one
# writer of running state.
DSHAPP_SOURCES="$ROOT/macos/DSHApp"
SESSION_EVENT_FILE="$DSHAPP_SOURCES/Core/DSHSessionEvent.swift"
timeline_issues=0
report_timeline_issue() {
  echo "$1" >&2
  echo "$2" | sed "s|$ROOT/||" >&2
  timeline_issues=$((timeline_issues + 1))
}
SESSION_EVENT_TESTS="$ROOT/macos/DSHTests/DSHCoreTimelineTests.swift"
while IFS= read -r event_name; do
  stray="$(grep -rnF --include='*.swift' "\"$event_name\"" "$DSHAPP_SOURCES" | grep -v 'Core/DSHSessionEvent.swift:' || true)"
  [[ -z "$stray" ]] || report_timeline_issue "Event name $event_name must stay in DSHSessionEvent.swift:" "$stray"
  grep -qF "\"$event_name\"" "$SESSION_EVENT_TESTS" \
    || report_timeline_issue "Event $event_name has no case in DSHCoreTimelineTests:" "$SESSION_EVENT_TESTS"
done < <(sed -nE 's/^  static let [A-Za-z]+ = "(.+)"$/\1/p' "$SESSION_EVENT_FILE")
stray="$(grep -rnF --include='*.swift' 'DSHSessionEventName.' "$DSHAPP_SOURCES" \
  | grep -vE 'Core/DSHSessionEvent\.swift:|Core/DSHAssistantStreamProjection\.swift:' || true)"
[[ -z "$stray" ]] || report_timeline_issue "Read session events through DSHSessionEvent, not by event name:" "$stray"
stray="$(grep -rnE --include='*.swift' '\.live\(|fromLive(Message|Content)|func live[A-Z]' "$DSHAPP_SOURCES" || true)"
[[ -z "$stray" ]] || report_timeline_issue "Live/history decoder twins are gone; decode through DSHSessionEvent:" "$stray"
stray="$(grep -rnE --include='*.swift' 'ObjectIdentifier\((controller|harness|self)\)|Registry\.shared' "$DSHAPP_SOURCES" || true)"
[[ -z "$stray" ]] || report_timeline_issue "Controller state belongs in stateBag, not a singleton keyed by controller:" "$stray"
# Five writes in the lifecycle file (the reconcile pair, clear, select, open) and
# the subagent overlay's own flag. A new write needs a reason, not a new copy.
RUNNING_WRITER_LIMIT=6
running_writers="$(grep -rnE --include='*.swift' '(^|[^A-Za-z_])isRunning = ' "$DSHAPP_SOURCES" \
  | grep -vE 'System/NativeAlerts\.swift:|var isRunning' || true)"
stray="$(echo "$running_writers" | grep -vE 'Sessions/DSHSessionLifecycle\.swift:|Subagents/DSHSubagentProjection\.swift:' || true)"
[[ -z "$stray" ]] || report_timeline_issue "Running state changes only through reconcileRootSessionRunningState:" "$stray"
if (( "$(echo "$running_writers" | grep -c .)" > RUNNING_WRITER_LIMIT )); then
  report_timeline_issue "More than $RUNNING_WRITER_LIMIT running-state writes:" "$running_writers"
fi
if (( timeline_issues > 0 )); then
  echo "session timeline gates: $timeline_issues check(s) failed (see above)" >&2
  exit 1
fi
echo "session timeline gates: OK (one event reader, one state owner, one running writer)"
"$ROOT/scripts/test-core.sh"

# Feature-directory layout (see the feature-directories Agent Note): sources
# live one level down under macos/DSHApp/<Domain>/, and every domain directory
# carries the rules an agent reads on its way to the file. The build glob is
# exactly one level deep, so a root-level .swift would be silently left out of
# the app — this gate is what turns that into a failure.
DSHAPP_ROOT="$ROOT/macos/DSHApp"
AGENTS_MD_LINE_LIMIT=60
layout_issues=0
for stray in "$DSHAPP_ROOT"/*.swift; do
  [[ -e "$stray" ]] || continue
  echo "  ${stray#"$ROOT"/}: Swift sources belong in a domain subdirectory" >&2
  layout_issues=$((layout_issues + 1))
done
for domain_dir in "$DSHAPP_ROOT"/*/; do
  domain_swift=("$domain_dir"*.swift)
  [[ -e "${domain_swift[0]}" ]] || continue
  domain="$(basename "$domain_dir")"
  for rule_file in AGENTS.md CLAUDE.md; do
    [[ -f "$domain_dir$rule_file" ]] || {
      echo "  macos/DSHApp/$domain/$rule_file is missing" >&2
      layout_issues=$((layout_issues + 1))
    }
  done
  if [[ -f "$domain_dir/AGENTS.md" ]]; then
    agents_lines="$(awk 'END { print NR }' "$domain_dir/AGENTS.md")"
    if (( agents_lines > AGENTS_MD_LINE_LIMIT )); then
      echo "  macos/DSHApp/$domain/AGENTS.md: $agents_lines lines, over the $AGENTS_MD_LINE_LIMIT-line limit" >&2
      layout_issues=$((layout_issues + 1))
    fi
  fi
done
if (( layout_issues > 0 )); then
  echo "layout gates: $layout_issues check(s) failed (see above)" >&2
  exit 1
fi
echo "layout gates: OK (no root-level sources; every domain keeps AGENTS.md + CLAUDE.md)"

# AGENTS.md "Rules for code changes" gates: sanitized home paths only, no new
# `print(` in production sources, and no parallel `Foo2` types. The account is
# read from $USER/$HOME so this script never hardcodes a real user name.
HOME_PREFIX="/Users"
HOME_USER_PATTERN="$HOME_PREFIX/([A-Za-z0-9._-]+)"
PRINT_BASELINE=0

check_home_paths() {
  local bad=0 entry file line rest text name account
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    file="${entry%%:*}"; rest="${entry#*:}"
    line="${rest%%:*}"; text="${rest#*:}"
    while [[ "$text" =~ $HOME_USER_PATTERN ]]; do
      name="${BASH_REMATCH[1]}"
      text="${text#*"$HOME_PREFIX/$name"}"
      [[ "$name" == "developer" ]] && continue
      account=""
      [[ "$name" == "${USER:-}" || "$name" == "${HOME##*/}" ]] && account=" (local account)"
      echo "  ${file#"$ROOT"/}:$line: $HOME_PREFIX/$name$account"
      bad=1
    done
  done < <(grep -rInE --include='*.swift' --include='*.sh' --include='*.md' --include='*.mjs' --include='*.py' \
             -- "$HOME_PREFIX/" "$ROOT/macos" "$ROOT/scripts" "$ROOT/docs" \
             "$ROOT/AGENTS.md" "$ROOT/CLAUDE.md" 2>/dev/null || true)
  (( bad == 0 ))
}

check_prints() {
  local count
  count="$(grep -ho 'print(' "$ROOT"/macos/DSHApp/*/*.swift 2>/dev/null | wc -l | tr -d ' ')"
  (( count > PRINT_BASELINE )) || return 0
  echo "  macos/DSHApp/*/*.swift: $count print( call(s), baseline $PRINT_BASELINE"
  grep -Hn 'print(' "$ROOT"/macos/DSHApp/*/*.swift | sed "s|$ROOT/|  |"
  return 1
}

check_parallel_types() {
  local hits
  hits="$(grep -rnE '(^|[^A-Za-z0-9_])(enum|struct|class|actor|protocol|typealias)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*2([^A-Za-z0-9_]|$)' \
    "$ROOT/macos" "$ROOT/scripts" "$ROOT/docs" 2>/dev/null || true)"
  [[ -z "$hits" ]] && return 0
  printf '%s\n' "$hits" | sed "s|$ROOT/|  |"
  return 1
}

style_issues=0
check_home_paths || style_issues=$((style_issues + 1))
check_prints || style_issues=$((style_issues + 1))
check_parallel_types || style_issues=$((style_issues + 1))
if (( style_issues > 0 )); then
  echo "style gates: $style_issues check(s) failed (see 文件:行 above); see AGENTS.md 'Rules for code changes'." >&2
  exit 1
fi
echo "style gates: OK (0 issues)"

# The production build compiles this exact glob; keeping the command here avoids
# a second source list or a synthetic test project that could drift from builds.
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
unset DSH_TEST_LIBRARY_DIR
# The typecheck covers the shipping configuration; the library is built with
# -D DEBUG. Running them together keeps this step as long as the slower one.
typecheck_pid=""
if [[ "$MODE" != "quick" ]]; then
  swiftc -target "$SWIFT_TARGET" -typecheck -parse-as-library -wmo "$ROOT"/macos/DSHApp/*/*.swift \
    -framework AppKit -framework SwiftUI -framework WebKit &
  typecheck_pid=$!
fi
dsh_test_library "$BUILD_DIR"
[[ -z "$typecheck_pid" ]] || wait "$typecheck_pid"
plutil -lint "$ROOT/macos/DSHApp/Info.plist" >/dev/null
"$ROOT/scripts/test-design-system.sh"
if [[ "$MODE" != "quick" ]]; then
  "$ROOT/scripts/test-settings-ui.sh"
  bash "$ROOT/scripts/test-agent-platform-ui.sh"
  bash "$ROOT/scripts/test-attachment-rail-ui.sh"
  bash "$ROOT/scripts/test-tool-presentation-ui.sh"
  bash "$ROOT/scripts/test-subagent-context-ui.sh"
  bash "$ROOT/scripts/test-workbench-ui.sh"
  bash "$ROOT/scripts/test-permission-composer-ui.sh"
  bash "$ROOT/scripts/test-conversation-history-ui.sh"
  bash "$ROOT/scripts/test-reasoning-ui.sh"
  echo "native-contract: OK"
fi

if [[ "$MODE" == "smoke" ]]; then
  [[ -x "$APP/Contents/MacOS/node" ]] || { echo "Packaged Node runtime is missing: $APP" >&2; exit 1; }
  [[ -f "$APP/Contents/Resources/Runtime/dsh/lib/bin.js" ]] || { echo "Packaged DSH runtime is missing: $APP" >&2; exit 1; }
  [[ -f "$APP/Contents/Resources/Licenses/DeepSeek-Harness-LICENSE" ]] || { echo "Project license is missing from the app bundle: $APP" >&2; exit 1; }
  [[ -f "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md" ]] || { echo "Third-party notices are missing from the app bundle: $APP" >&2; exit 1; }
  [[ -f "$APP/Contents/Resources/Licenses/Node.js-LICENSE" ]] || { echo "Node.js license is missing from the app bundle: $APP" >&2; exit 1; }
  [[ -f "$APP/Contents/Resources/Licenses/sharp-libvips-LICENSE" ]] || { echo "sharp-libvips license is missing from the app bundle: $APP" >&2; exit 1; }
  [[ -f "$APP/Contents/Resources/Licenses/sharp-libvips-THIRD-PARTY-NOTICES.md" ]] || { echo "sharp-libvips notices are missing from the app bundle: $APP" >&2; exit 1; }
  [[ -f "$APP/Contents/Resources/Licenses/LGPL-3.0.txt" ]] || { echo "GNU LGPLv3 text is missing from the app bundle: $APP" >&2; exit 1; }
  [[ -f "$APP/Contents/Resources/Licenses/GPL-3.0.txt" ]] || { echo "GNU GPLv3 text is missing from the app bundle: $APP" >&2; exit 1; }
  [[ -f "$APP/Contents/Resources/Runtime/dsh/LICENSE" ]] || { echo "DSH license is missing from the app bundle: $APP" >&2; exit 1; }
  app_minos="$(xcrun vtool -show-build "$APP/Contents/MacOS/DSH" | awk '/minos / { print $2; exit }')"
  [[ "$app_minos" == "$MINIMUM_MACOS_VERSION" ]] || {
    echo "Packaged app minimum macOS version is $app_minos, expected $MINIMUM_MACOS_VERSION." >&2
    exit 1
  }
  "$ROOT/scripts/verify-native-host-api.sh" "$APP"
fi

if [[ "$MODE" == "unit" || "$MODE" == "quick" ]]; then
  # main.swift's own @main entry point is never linked into an executable here,
  # so it can't collide with the test runner's @main.
  swiftc -target "$SWIFT_TARGET" -parse-as-library -wmo -num-threads 8 \
    -I "$DSH_TEST_LIBRARY_DIR" -L "$DSH_TEST_LIBRARY_DIR" -lDSHAppLib \
    -o "$BUILD_DIR/dsh-unit-tests" \
    "$ROOT"/macos/DSHTests/*.swift -framework AppKit -framework SwiftUI -framework WebKit
  DYLD_LIBRARY_PATH="$DSH_TEST_LIBRARY_DIR" "$BUILD_DIR/dsh-unit-tests"
fi
