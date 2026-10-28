#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/scripts/dsh-runtime-version.txt"
LOCK_FILE="${DSH_RUNTIME_LOCK:-$ROOT/scripts/dsh-runtime-lock.json}"
PATCH_SCRIPT="$ROOT/scripts/patch-llm-runtime.mjs"
PACKAGE="@deepseek-ai/dsh"
EXPECTED_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
NODE="${NODE_SOURCE:-$(command -v node || true)}"
NPM="${NPM_SOURCE:-$(command -v npm || true)}"
# An unwritable global npm cache (root-owned entries, CI sandboxes) otherwise
# fails the install with EPERM; let a build point npm at a private cache.
[[ -z "${DSH_NPM_CACHE:-}" ]] || export npm_config_cache="$DSH_NPM_CACHE"

[[ -n "$EXPECTED_VERSION" ]] || {
  echo "DSH runtime version is empty: $VERSION_FILE" >&2
  exit 1
}
[[ -n "$NODE" && -x "$NODE" ]] || {
  echo "Node.js is required to prepare the bundled DSH runtime." >&2
  exit 1
}

lock_field() {
  "$NODE" -e '
    const fs = require("node:fs");
    const lock = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(String(lock[process.argv[2]] ?? ""));
  ' "$LOCK_FILE" "$1"
}

PI_AI_VERSION="$(lock_field piAiVersion)"
PI_TELEMETRY_VERSION="$(lock_field piTelemetryVersion)"
[[ -n "$PI_AI_VERSION" && -n "$PI_TELEMETRY_VERSION" ]] || {
  echo "DSH runtime lock is missing pi-ai/pi-telemetry versions: $LOCK_FILE" >&2
  exit 1
}

runtime_version() {
  "$NODE" -e '
    const fs = require("node:fs");
    const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(String(manifest.version ?? ""));
  ' "$1/package.json"
}

validate_runtime() {
  local source="$1" actual dependency
  [[ -f "$source/package.json" && -f "$source/lib/bin.js" ]] || {
    echo "DSH runtime is incomplete: $source" >&2
    return 1
  }
  actual="$(runtime_version "$source")"
  [[ "$actual" == "$EXPECTED_VERSION" ]] || {
    echo "DSH runtime must be $EXPECTED_VERSION, found ${actual:-unknown}: $source" >&2
    return 1
  }
  for dependency in dsh-subagent dsh-session dsh-web-app; do
    [[ -f "$source/node_modules/@deepseek-ai/$dependency/package.json" ]] || {
      echo "DSH runtime is missing nested @deepseek-ai/$dependency: $source" >&2
      return 1
    }
    actual="$(runtime_version "$source/node_modules/@deepseek-ai/$dependency")"
    [[ "$actual" == "$EXPECTED_VERSION" ]] || {
      echo "@deepseek-ai/$dependency must be $EXPECTED_VERSION, found ${actual:-unknown}: $source" >&2
      return 1
    }
  done
}

# Model-request image placement and context-pressure accounting are only
# correct with the LLM patch below, so every runtime this script prints carries
# it — including a `DSH_SOURCE` pass-through, which is patched on a copy. The
# patch is fail-closed against a pinned version and the lock file below,
# verifies every transformed feature on an already-marked file, and is
# idempotent. It never touches the installed App bundle.
apply_llm_patch() {
  local source="$1"
  "$NODE" "$PATCH_SCRIPT" "$source" >&2
  printf '%s\n' "$source"
}

# Exact marker comparison: `-v20` must never be read as `-v2`. Only files the
# patch actually writes are scanned, plus any stray marker under the patched
# `lib` trees.
PATCH_MARKER="dsh-llm-runtime-patch-v2"
runtime_patch_is_stale() {
  local source="$1" relative hit
  for relative in \
    "node_modules/@earendil-works/pi-ai/dist/api/transform-messages.js" \
    "node_modules/@deepseek-ai/dsh-token-meter/lib/index.js" \
    "node_modules/@deepseek-ai/dsh-token-meter/lib/types/usage-projection.js" \
    "node_modules/@deepseek-ai/dsh-llm/lib/index.js" \
    "node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js"; do
    [[ -f "$source/$relative" ]] || continue
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      [[ "$hit" == "$PATCH_MARKER" ]] || return 0
    done < <(grep -oE 'dsh-llm-runtime-patch(-v[0-9]+)?' "$source/$relative" || true)
  done
  return 1
}

# The lock pins dsh, the two `@earendil-works` releases, and the pristine digest
# of every patched file. Any drift fails with the expected and actual values
# instead of shipping a runtime whose anchors no longer mean what they meant.
runtime_lock_error() {
  local source="$1"
  "$NODE" "$PATCH_SCRIPT" --check-lock "$source" 2>&1 >/dev/null
}

runtime_lock_ok() {
  local source="$1"
  "$NODE" "$PATCH_SCRIPT" --check-lock "$source" >/dev/null 2>&1
}

# `dsh-llm-pi-ai` declares `^1.1.0`, so npm may resolve a newer pi-ai that the
# anchors were never verified against. Pin both `@earendil-works` packages to
# the lock's versions after install and re-validate.
pin_earendil_versions() {
  local source="$1" pin_stage actual
  actual="$(runtime_version "$source/node_modules/@earendil-works/pi-ai" 2>/dev/null || echo missing)"
  [[ "$actual" == "$PI_AI_VERSION" ]] || {
    local telemetry_actual
    telemetry_actual="$(runtime_version "$source/node_modules/@earendil-works/pi-telemetry" 2>/dev/null || echo missing)"
    [[ -n "$NPM" && -x "$NPM" ]] || {
      echo "npm is required to pin @earendil-works/pi-ai@$PI_AI_VERSION." >&2
      exit 1
    }
    echo "Pinning @earendil-works/pi-ai $actual -> $PI_AI_VERSION and pi-telemetry $telemetry_actual -> $PI_TELEMETRY_VERSION" >&2
    pin_stage="$(mktemp -d "${TMPDIR:-/tmp}/dsh-pin-XXXXXX")"
    "$NPM" install --prefix "$pin_stage" --no-audit --no-fund --no-package-lock \
      "@earendil-works/pi-ai@$PI_AI_VERSION" "@earendil-works/pi-telemetry@$PI_TELEMETRY_VERSION" >&2
    rm -rf "$source/node_modules/@earendil-works/pi-ai" \
      "$source/node_modules/@earendil-works/pi-telemetry"
    mkdir -p "$source/node_modules/@earendil-works"
    cp -R "$pin_stage/node_modules/@earendil-works/pi-ai" \
      "$pin_stage/node_modules/@earendil-works/pi-telemetry" \
      "$source/node_modules/@earendil-works/"
    rm -rf "$pin_stage"
    return 0
  }
  [[ "$(runtime_version "$source/node_modules/@earendil-works/pi-telemetry" 2>/dev/null || echo missing)" == "$PI_TELEMETRY_VERSION" ]] || {
    local drift
    drift="$(runtime_version "$source/node_modules/@earendil-works/pi-telemetry" 2>/dev/null || echo missing)"
    [[ -n "$NPM" && -x "$NPM" ]] || {
      echo "npm is required to pin @earendil-works/pi-telemetry@$PI_TELEMETRY_VERSION." >&2
      exit 1
    }
    echo "Pinning @earendil-works/pi-telemetry $drift -> $PI_TELEMETRY_VERSION" >&2
    pin_stage="$(mktemp -d "${TMPDIR:-/tmp}/dsh-pin-XXXXXX")"
    "$NPM" install --prefix "$pin_stage" --no-audit --no-fund --no-package-lock \
      "@earendil-works/pi-telemetry@$PI_TELEMETRY_VERSION" >&2
    rm -rf "$source/node_modules/@earendil-works/pi-telemetry"
    cp -R "$pin_stage/node_modules/@earendil-works/pi-telemetry" "$source/node_modules/@earendil-works/"
    rm -rf "$pin_stage"
  }
}

if [[ "${DSH_RUNTIME_VERIFY_LATEST:-0}" == "1" ]]; then
  [[ -n "$NPM" && -x "$NPM" ]] || {
    echo "npm is required to verify and prepare the latest DSH runtime." >&2
    exit 1
  }
  latest="$("$NPM" view "$PACKAGE" version --silent)"
  [[ "$latest" == "$EXPECTED_VERSION" ]] || {
    echo "npm latest for $PACKAGE is $latest, but $VERSION_FILE pins $EXPECTED_VERSION." >&2
    echo "Update the runtime patch and tests before building with the new release." >&2
    exit 1
  }
fi

CACHE_ROOT="${DSH_RUNTIME_CACHE:-$ROOT/dist/.dsh-runtime-cache}"
PREFIX="$CACHE_ROOT/$EXPECTED_VERSION"
SOURCE="$PREFIX/lib/node_modules/$PACKAGE"
LOCK="$CACHE_ROOT/.prepare.lock"
STAGE=""

# The lock is taken before the first validate+patch pair so two concurrent
# prepares (build + test script) can never observe a half-written file. Patch
# writes are atomic (temp + rename), so readers outside this script are safe
# too.
mkdir -p "$CACHE_ROOT"
while ! mkdir "$LOCK" 2>/dev/null; do sleep 1; done
cleanup() {
  [[ -z "$STAGE" ]] || rm -rf "$STAGE"
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT

# An explicit DSH_SOURCE is never modified. It is copied into the cache under a
# path-derived suffix, pinned to the locked `@earendil-works` releases, patched,
# and the copy is what gets printed and bundled.
if [[ -n "${DSH_SOURCE:-}" ]]; then
  validate_runtime "$DSH_SOURCE"
  SOURCE_HASH="$("$NODE" -e '
    const { createHash } = require("node:crypto");
    process.stdout.write(createHash("sha256").update(process.argv[1]).digest("hex").slice(0, 8));
  ' "$DSH_SOURCE")"
  COPY="$CACHE_ROOT/$EXPECTED_VERSION-src-$SOURCE_HASH"
  if [[ -d "$COPY" ]] && validate_runtime "$COPY" 2>/dev/null && runtime_lock_ok "$COPY"; then
    :
  else
    rm -rf "$COPY"
    mkdir -p "$CACHE_ROOT"
    ditto "$DSH_SOURCE" "$COPY"
    validate_runtime "$COPY"
    pin_earendil_versions "$COPY"
  fi
  lock_error="$(runtime_lock_error "$COPY" || true)"
  [[ -z "$lock_error" ]] || {
    echo "DSH runtime lock mismatch for the DSH_SOURCE copy $COPY:" >&2
    echo "$lock_error" >&2
    exit 1
  }
  apply_llm_patch "$COPY"
  exit 0
fi

if validate_runtime "$SOURCE" 2>/dev/null && { ! runtime_lock_ok "$SOURCE" || runtime_patch_is_stale "$SOURCE"; }; then
  echo "DSH runtime cache does not match $LOCK_FILE; reinstalling $PREFIX" >&2
  runtime_lock_error "$SOURCE" >&2 || true
  rm -rf "$PREFIX"
fi

if validate_runtime "$SOURCE" 2>/dev/null; then
  apply_llm_patch "$SOURCE"
  exit 0
fi

[[ -n "$NPM" && -x "$NPM" ]] || {
  echo "npm is required to install $PACKAGE@$EXPECTED_VERSION." >&2
  exit 1
}

STAGE="$CACHE_ROOT/.stage-$EXPECTED_VERSION-$$"
rm -rf "$STAGE"
"$NPM" install -g --prefix "$STAGE" --no-audit --no-fund "$PACKAGE@$EXPECTED_VERSION" >&2
STAGED_SOURCE="$STAGE/lib/node_modules/$PACKAGE"
validate_runtime "$STAGED_SOURCE"
pin_earendil_versions "$STAGED_SOURCE"
lock_error="$(runtime_lock_error "$STAGED_SOURCE" || true)"
[[ -z "$lock_error" ]] || {
  echo "DSH runtime lock mismatch after installing $PACKAGE@$EXPECTED_VERSION:" >&2
  echo "$lock_error" >&2
  exit 1
}
apply_llm_patch "$STAGED_SOURCE" >/dev/null
rm -rf "$PREFIX"
mv "$STAGE" "$PREFIX"
STAGE=""
apply_llm_patch "$SOURCE"
