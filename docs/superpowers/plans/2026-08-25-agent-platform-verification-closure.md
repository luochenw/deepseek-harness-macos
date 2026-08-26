# Agent Platform Verification Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the bundled Agent Platform plugin and DSH runtime patch an
explicit, repeatable local and CI verification stage.

**Architecture:** Add one runtime script that validates the configured Node
binary, syntax-checks plugin modules, runs the plugin's Node tests, and runs
the existing runtime-patch fixture. Add a shell contract that verifies the
runtime script rejects a non-Node executable and an empty plugin directory.
CI runs both scripts as an independent stage before the packaged app build;
the existing app build and Host smoke remain the integration check for the
actual embedded Runtime.

**Tech Stack:** Bash, Node.js built-in test runner, DSH runtime patch fixture,
GitHub Actions, SwiftUI/macOS build scripts.

---

### Task 1: Specify the Runtime Verification Command

**Files:**
- Create: `scripts/test-agent-platform-runtime.sh`
- Test: shell command against the absent script

- [x] **Step 1: Verify the dedicated command is absent**

Run:

```bash
test -x scripts/test-agent-platform-runtime.sh
```

Expected: exits nonzero because the command does not exist yet.

- [x] **Step 2: Create the command**

```bash
#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="${NODE_SOURCE:-$(command -v node || true)}"
PLUGIN="${AGENT_PLATFORM_PLUGIN_PATH:-$ROOT/macos/Runtime-extras/dsh-agent-platform}"

[[ -n "$NODE" && -x "$NODE" ]] || {
  echo "agent-platform-runtime: Node runtime not found." >&2
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
"$NODE" "$ROOT/scripts/test-agent-platform-runtime-patch.mjs"
echo "agent-platform-runtime: OK"
```

- [x] **Step 3: Run the new command**

Run:

```bash
./scripts/test-agent-platform-runtime.sh
```

Expected: all plugin tests pass, the patch fixture prints
`agent-platform-runtime-patch: OK`, and the script prints
`agent-platform-runtime: OK`.

### Task 1a: Protect the Runtime Gate Itself

**Files:**
- Create: `scripts/test-agent-platform-runtime-script.sh`
- Modify: `scripts/test-agent-platform-runtime.sh`

- [x] **Step 1: Write the failing shell contract**

The contract runs:

```bash
NODE_SOURCE=/usr/bin/true ./scripts/test-agent-platform-runtime.sh
```

and expects a nonzero status plus `not a Node.js executable`. It also supplies
an empty temporary `AGENT_PLATFORM_PLUGIN_PATH` and expects
`no plugin modules found`.

- [x] **Step 2: Verify the contract fails against the initial script**

Run:

```bash
./scripts/test-agent-platform-runtime-script.sh
```

Expected: FAIL because an arbitrary executable can ignore Node flags and a
literal unmatched glob does not make the count check fail.

- [x] **Step 3: Implement Node and glob validation**

Require `process.versions.node` to match a three-part Node version and enable
`nullglob` while collecting module and test arrays.

- [x] **Step 4: Verify the shell contract passes**

Run:

```bash
./scripts/test-agent-platform-runtime-script.sh
```

Expected: `agent-platform-runtime-script: OK`.

### Task 2: Make CI Report the Runtime Boundary Separately

**Files:**
- Modify: `.github/workflows/ci.yml`
- Test: grep for a named Agent Platform stage

- [x] **Step 1: Verify CI lacks the dedicated stage**

Run:

```bash
grep -F 'Agent Platform runtime contracts' .github/workflows/ci.yml
```

Expected: exits nonzero because the stage is not present yet.

- [x] **Step 2: Add the CI stage after native unit checks**

```yaml
      - name: Agent Platform runtime contracts
        run: ./scripts/test-agent-platform-runtime-script.sh && ./scripts/test-agent-platform-runtime.sh
```

The step goes after `Unit tests (macos/DSHTests)` and before installing the
DSH runtime. It checks plugin source and the patch fixture without relying on
global DSH installation. The following installation step pins the DSH version
that the runtime patch supports:

```yaml
      - name: Install DSH runtime (bundled into the build)
        run: npm install -g @deepseek-ai/dsh@0.1.0-rc.7
```

- [x] **Step 3: Verify the CI declaration**

Run:

```bash
grep -F 'Agent Platform runtime contracts' .github/workflows/ci.yml
```

Expected: prints the new stage name and exits zero.

### Task 3: Document the Verification Contract

**Files:**
- Create: `.agents/notes/proposed/process/2026-08-25-agent-platform-verification-closure.md`
- Modify: `docs/superpowers/specs/2026-08-25-completion-roadmap-design.md`

- [x] **Step 1: Record the decision before shipping**

The Agent Note must state that:

```markdown
- the standalone runtime script covers plugin syntax, Node behavior, and
  patch-shape idempotence;
- packaged build plus Host smoke covers the injected Runtime integration;
- the script must use `NODE_SOURCE` when supplied so local verification and
  build use the same Node binary.
```

- [x] **Step 2: Check the Note has required sections**

Run:

```bash
grep -F '## Problem' .agents/notes/proposed/process/2026-08-25-agent-platform-verification-closure.md
grep -F '## Proposal' .agents/notes/proposed/process/2026-08-25-agent-platform-verification-closure.md
grep -F '## Alternatives considered' .agents/notes/proposed/process/2026-08-25-agent-platform-verification-closure.md
grep -F '## Acceptance criteria' .agents/notes/proposed/process/2026-08-25-agent-platform-verification-closure.md
```

Expected: all four commands print their matching heading.

### Task 4: Run the Full Delivery Gate

**Files:**
- Verify: `scripts/test-macos-native.sh`
- Verify: `scripts/test-agent-platform-runtime.sh`
- Verify: `scripts/build-macos-app.sh`
- Verify: `scripts/verify-native-host-api.sh`

- [x] **Step 1: Run native typecheck and UI contracts**

Run:

```bash
./scripts/test-macos-native.sh
```

Expected: `native-contract: OK`.

- [x] **Step 2: Run Swift unit tests**

Run:

```bash
./scripts/test-macos-native.sh --unit
```

Expected: `Ran 20 test(s): 20 passed, 0 failed`.

- [x] **Step 3: Run the plugin and patch verification**

Run:

```bash
./scripts/test-agent-platform-runtime.sh
```

Expected: 91 Node tests pass and both runtime success markers print.

- [x] **Step 4: Build the app**

Run:

```bash
./scripts/build-macos-app.sh
```

Expected: `Built self-contained app:` followed by the app path.

- [x] **Step 5: Smoke-test the packaged Host**

Run:

```bash
./scripts/test-macos-native.sh --smoke
```

Expected: `native-host-api-smoke: OK` and no failure from Agent Profile or
Batch failure-isolation assertions.

- [x] **Step 6: Review changed files**

Run:

```bash
git diff --check
git diff -- scripts/test-agent-platform-runtime.sh .github/workflows/ci.yml
```

Expected: no whitespace errors and only the intended verification changes.

### Task 5: Mark the Decision Implemented

**Files:**
- Move: `.agents/notes/proposed/process/2026-08-25-agent-platform-verification-closure.md`
- To: `.agents/notes/implemented/process/2026-08-25-agent-platform-verification-closure.md`

- [x] **Step 1: Move and rewrite the Agent Note**

Update the header and section names:

```markdown
Status: implemented — standalone runtime checks and CI stage pass locally

## Decision
```

Replace `## Acceptance criteria` with `## Consequences`, listing the exact
commands and outcomes from Task 4.

- [x] **Step 2: Verify no proposed Note remains**

Run:

```bash
test ! -e .agents/notes/proposed/process/2026-08-25-agent-platform-verification-closure.md
test -f .agents/notes/implemented/process/2026-08-25-agent-platform-verification-closure.md
```

Expected: both commands exit zero.

## Self-Review

The plan covers the Phase 1 acceptance criteria in the design:

- Task 1 creates the repeatable local command.
- Task 2 exposes the command in CI.
- Task 4 runs native, unit, plugin, build, and packaged Host integration
  checks against one worktree.
- Task 5 preserves the repository's Agent Note lifecycle.

The scope intentionally excludes tool-card UI work, trajectory virtualization,
subagent projection changes, App automation, `dynamicCordisRunner`, and
`HarnessController` state decomposition. Those are separately bounded phases
in `docs/superpowers/specs/2026-08-25-completion-roadmap-design.md`.
