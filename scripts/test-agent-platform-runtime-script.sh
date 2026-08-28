#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_TEST="$ROOT/scripts/test-agent-platform-runtime.sh"
CI="$ROOT/.github/workflows/ci.yml"
BUILD="$ROOT/scripts/build-macos-app.sh"
PREPARE="$ROOT/scripts/prepare-dsh-runtime.sh"
VERSION_FILE="$ROOT/scripts/dsh-runtime-version.txt"
NODE="${NODE_SOURCE:-$(command -v node || true)}"

[[ -x "$RUNTIME_TEST" ]] || {
  echo "agent-platform-runtime-script: missing executable runtime test at $RUNTIME_TEST" >&2
  exit 1
}
[[ -x "$BUILD" ]] || {
  echo "agent-platform-runtime-script: missing executable build script at $BUILD" >&2
  exit 1
}
[[ -x "$PREPARE" ]] || {
  echo "agent-platform-runtime-script: missing executable runtime preparer at $PREPARE" >&2
  exit 1
}
[[ -s "$VERSION_FILE" ]] || {
  echo "agent-platform-runtime-script: missing DSH runtime version file at $VERSION_FILE" >&2
  exit 1
}
[[ -n "$NODE" && -x "$NODE" ]] || {
  echo "agent-platform-runtime-script: Node.js is required" >&2
  exit 1
}
EXPECTED_DSH_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

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
old_runtime="$(mktemp -d)"
trap 'rm -rf "$empty_plugin" "$isolated_home" "$old_runtime"' EXIT
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
  DSH_SOURCE="$isolated_home/missing-dsh" \
  "$RUNTIME_TEST" 2>&1
)"
isolated_runtime_status=$?
set -e
if (( isolated_runtime_status != 0 )); then
  echo "agent-platform-runtime-script: runtime contract tests depend on locally installed external CLIs" >&2
  printf '%s\n' "$isolated_runtime_output" >&2
  exit 1
fi

mkdir -p "$old_runtime/lib"
printf '%s\n' '{"version":"0.1.0-rc.7"}' > "$old_runtime/package.json"
touch "$old_runtime/lib/bin.js"
set +e
old_runtime_output="$(
  DSH_RUNTIME_VERIFY_LATEST=0 DSH_SOURCE="$old_runtime" "$PREPARE" 2>&1
)"
old_runtime_status=$?
set -e
if (( old_runtime_status == 0 )); then
  echo "agent-platform-runtime-script: old DSH_SOURCE unexpectedly passed validation" >&2
  exit 1
fi
if [[ "$old_runtime_output" != *"must be $EXPECTED_DSH_VERSION"* ]]; then
  echo "agent-platform-runtime-script: old DSH rejection was not actionable" >&2
  printf '%s\n' "$old_runtime_output" >&2
  exit 1
fi

prepared_runtime="$(DSH_RUNTIME_VERIFY_LATEST=1 "$PREPARE")"
prepared_version="$("$NODE" -e '
  const fs = require("node:fs");
  process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version);
' "$prepared_runtime/package.json")"
[[ "$prepared_version" == "$EXPECTED_DSH_VERSION" ]] || {
  echo "agent-platform-runtime-script: prepared DSH is $prepared_version, expected $EXPECTED_DSH_VERSION" >&2
  exit 1
}

grep -Fq 'NODE_LIB_DIR' "$BUILD" || {
  echo "agent-platform-runtime-script: build must stage Node dynamic libraries when present" >&2
  exit 1
}
grep -Fq 'libnode*.dylib' "$BUILD" || {
  echo "agent-platform-runtime-script: build must detect libnode dynamic libraries" >&2
  exit 1
}
grep -Fq 'cp "$NODE_EXECUTABLE"' "$BUILD" || {
  echo "agent-platform-runtime-script: build must copy the resolved Node executable, not a shim" >&2
  exit 1
}
grep -Fq 'swiftc -target "$SWIFT_TARGET"' "$BUILD" || {
  echo "agent-platform-runtime-script: build must pin the supported macOS deployment target" >&2
  exit 1
}
grep -Fq 'scripts/prepare-dsh-runtime.sh' "$BUILD" || {
  echo "agent-platform-runtime-script: build must prepare the pinned DSH runtime" >&2
  exit 1
}
grep -Fq 'DSH_RUNTIME_VERIFY_LATEST="${DSH_RUNTIME_VERIFY_LATEST:-1}"' "$BUILD" || {
  echo "agent-platform-runtime-script: normal builds must verify the DSH pin is npm latest" >&2
  exit 1
}
if grep -Fq 'npm root -g' "$BUILD"; then
  echo "agent-platform-runtime-script: build must not use a global DSH installation" >&2
  exit 1
fi
grep -Fq '@dsh-app/dsh-tool-workbench' "$ROOT/scripts/patch-agent-platform-runtime.mjs" || {
  echo "agent-platform-runtime-script: native workbench tools are not mounted into the Host runtime" >&2
  exit 1
}

grep -Fq './scripts/prepare-dsh-runtime.sh' "$CI" || {
  echo "agent-platform-runtime-script: CI must use the repository DSH runtime preparer" >&2
  exit 1
}
grep -Fq 'DSH_RUNTIME_VERIFY_LATEST=1' "$CI" || {
  echo "agent-platform-runtime-script: CI must verify the pinned DSH version is npm latest" >&2
  exit 1
}

grep -Fq '"--no-open"' "$ROOT/macos/DSHApp/DSHHostProtocol.swift" || {
  echo "agent-platform-runtime-script: native Host launch must suppress the bundled Web UI" >&2
  exit 1
}
grep -Fq -- '--no-open' "$ROOT/scripts/verify-native-host-api.sh" || {
  echo "agent-platform-runtime-script: smoke Host launch must suppress the bundled Web UI" >&2
  exit 1
}

EXPECTED_DSH_VERSION="$EXPECTED_DSH_VERSION" "$NODE" -e '
  const fs = require("node:fs");
  const manifests = process.argv.slice(1);
  for (const file of manifests) {
    const peers = JSON.parse(fs.readFileSync(file, "utf8")).peerDependencies ?? {};
    for (const [name, range] of Object.entries(peers)) {
      if (name.startsWith("@deepseek-ai/dsh") && range !== process.env.EXPECTED_DSH_VERSION) {
        throw new Error(`${file}: ${name} must equal ${process.env.EXPECTED_DSH_VERSION}, found ${range}`);
      }
    }
  }
' \
  "$ROOT/macos/Runtime-extras/dsh-agent-platform/package.json" \
  "$ROOT/macos/Runtime-extras/dsh-tool-session-relay/package.json" \
  "$ROOT/macos/Runtime-extras/dsh-tool-workbench/package.json"

echo "agent-platform-runtime-script: OK"
