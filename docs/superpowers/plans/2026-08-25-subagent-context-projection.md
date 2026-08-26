# Subagent Context Projection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render tool activity, Todo items, and Goal state for the currently
displayed child transcript without mutating the root session's state.

**Architecture:** Keep root state in the existing `HarnessController`
properties. Add a feature-local, child-session-keyed presentation registry
that forwards changes through the controller's existing observation channel.
Seed it from `subagent.history.projections`, apply higher-sequence mux
projections, and route child tool/todo events into that context. Views use
computed `displayed*` selectors rather than branch-specific local copies.

**Tech Stack:** SwiftUI, Combine-free `ObservableObject` forwarding through
`HarnessController`, DSH Host `subagent.history` and mux projections, direct
`swiftc` test harness.

---

### Task 1: Add Failing Child-Context Contracts

**Files:**
- Create: `macos/DSHTests/DSHSubagentProjectionTests.swift`
- Modify: `macos/DSHTests/DSHTestsMain.swift`

- [ ] **Step 1: Write root/child selection tests**

```swift
let harness = HarnessController(startRuntime: false)
harness.activeTools = [rootTool]
harness.todos = [rootTodo]
harness.goal = rootGoal
harness.seedSubagentPresentation(
  sessionID: "child-1",
  tools: [childTool],
  projections: childProjections)
harness.activeSubagentAddress = DSHSubagentAddress(
  parentSessionId: "root-1",
  childSessionId: "child-1",
  mode: "continuable")

try expectEqual(harness.displayedTools.map(\.callId), ["child-tool"])
try expectEqual(harness.displayedTodos.map(\.content), ["child todo"])
try expectEqual(harness.displayedGoal?.goal?.objective, "child goal")

harness.activeSubagentAddress = nil
try expectEqual(harness.displayedTools.map(\.callId), ["root-tool"])
try expectEqual(harness.displayedTodos.map(\.content), ["root todo"])
```

- [ ] **Step 2: Write failing sequencing and live-event tests**

```swift
harness.applySubagentProjection(
  sessionID: "child-1",
  key: "todos",
  value: [["content": "new", "status": "in_progress"]],
  seq: 11)
harness.applySubagentProjection(
  sessionID: "child-1",
  key: "todos",
  value: [["content": "old", "status": "pending"]],
  seq: 10)
try expectEqual(harness.displayedTodos.map(\.content), ["new"])

harness.consumeMuxFrame(toolResultFrame(sessionID: "child-1", callID: "child-tool"))
try expectEqual(harness.displayedTools.first?.state, .succeeded)
try expectEqual(harness.activeTools.first?.state, .running)
```

- [ ] **Step 3: Run the unit suite and verify RED**

Run:

```bash
./scripts/test-macos-native.sh --unit
```

Expected: compilation fails because child presentation state and displayed
selectors do not exist.

### Task 2: Define Child Presentation State and History Baseline

**Files:**
- Create: `macos/DSHApp/DSHSubagentProjection.swift`
- Modify: `macos/DSHApp/DSHHistory.swift`
- Modify: `macos/DSHApp/DSHSubagents.swift`

- [ ] **Step 1: Add the feature-local registry**

Create a `DSHSubagentPresentationContext` value holding:

```swift
var tools: [HarnessController.ToolActivity]
var todos: [DSHTodoItem]
var goal: DSHGoalProjection?
var projectionSequences: [String: Int]
```

Create a `DSHSubagentPresentationState` class that holds contexts keyed by
child session ID and sends `harness.objectWillChange` after a state change.
The registry must use a weak controller owner and purge released owners before
creating or returning a state.

- [ ] **Step 2: Add computed display selectors**

Add these controller extension properties:

```swift
var displayedTools: [ToolActivity]
var displayedTodos: [DSHTodoItem]
var displayedGoal: DSHGoalProjection?
var displayedGoalSessionID: String?
```

They read the active child context when `activeSubagentAddress` is present,
otherwise the existing root properties. Root state remains the fallback for
every top-level session.

- [ ] **Step 3: Preserve history tools without root mutation**

Change `foldHistory` so its pure worker returns messages plus tool activities.
The root wrapper preserves its existing assignment to `activeTools`; child
history uses the pure result and seeds the child context instead.

Extend `DSHHistoryPage` with optional `projections`, then have
`loadSubagentTranscript` seed Todo/Goal from that tail-page snapshot and set
each relevant projection key's sequence to `asOfSeq`.

- [ ] **Step 4: Run the unit suite and verify GREEN**

Run:

```bash
./scripts/test-macos-native.sh --unit
```

Expected: root/child selection tests pass and root `activeTools` remains
unchanged after child history is loaded.

### Task 3: Route Live Child Events and Projection Frames

**Files:**
- Modify: `macos/DSHApp/DSHEventSocket.swift`
- Modify: `macos/DSHApp/DSHSubagentProjection.swift`

- [ ] **Step 1: Route mux projection frames by session ID**

Keep the root path:

```swift
if sessionId == hostCurrentSessionID {
  applyProjection(key: key, value: value)
}
```

For a known child context, call:

```swift
applySubagentProjection(sessionID: sessionId, key: key, value: value, seq: seq)
```

The state must ignore a frame whose `seq` is lower than the saved sequence for
the same projection key.

- [ ] **Step 2: Extend child session events**

Pass the mux render intent into `applyLiveSubagentEvent`. Implement child-only
handling for `tool/call`, `tool/result`, `todo/write`, and `turn/end`, using
the same `DSHToolResultDecoder` and `ToolPresentation.merging` code path as
the root. Append a `.tool` transcript message on child calls; update only the
child context on results. `turn/end` settles only that child context's still
running tools.

- [ ] **Step 3: Route child job snapshots**

For a `session/jobs` frame, retain the existing root behavior for
`hostCurrentSessionID`. If the session has a known child context, merge job
state into that context instead of `activeTools`.

- [ ] **Step 4: Run focused and full unit tests**

Run:

```bash
./scripts/test-macos-native.sh --unit
```

Expected: live nested `tool/result` completes the child call only, and
out-of-order projection tests keep the newer Todo value.

### Task 4: Read Displayed Context in Views and Goal Actions

**Files:**
- Modify: `macos/DSHApp/NativeDashboard.swift`
- Modify: `macos/DSHApp/ConversationView.swift`
- Modify: `macos/DSHApp/SkillsGoalView.swift`
- Modify: `macos/DSHApp/DSHGoalActions.swift`

- [ ] **Step 1: Update Dashboard and transcript tool lookup**

Replace direct reads of `harness.todos` / `harness.activeTools` with
`harness.displayedTodos` / `harness.displayedTools` in Dashboard,
`ToolCallRow`, and `ToolGroupRow`.

- [ ] **Step 2: Update GoalBar**

Render `harness.displayedGoal`. Display Goal actions only when the shown
context is not a read-only one-shot child. Keep the visual state available
for one-shot history.

- [ ] **Step 3: Route Goal mutations to the displayed session**

Keep Goal mutations rooted in `hostCurrentSessionID` and `goal`: rc.7 rejects
Goal mutations for every session-backed child, including continuable children.
`GoalBar` may display a child projection but must not expose controls while
any child transcript is active.

- [ ] **Step 4: Run view and unit contracts**

Run:

```bash
./scripts/test-macos-native.sh
./scripts/test-macos-native.sh --unit
```

Expected: native contracts and all unit tests pass.

### Task 5: Verify and Record

**Files:**
- Modify: `macos/WEB_PARITY.md`
- Move: `.agents/notes/proposed/feature/2026-08-25-subagent-context-projection.md`
- To: `.agents/notes/implemented/feature/2026-08-25-subagent-context-projection.md`

- [ ] **Step 1: Run all delivery gates**

```bash
./scripts/test-macos-native.sh
./scripts/test-macos-native.sh --unit
./scripts/test-agent-platform-runtime-script.sh
./scripts/test-agent-platform-runtime.sh
./scripts/build-macos-app.sh
./scripts/test-macos-native.sh --smoke
git diff --check
```

- [ ] **Step 2: Update parity and Agent Note**

Remove the subagent tool/todo/goal context gap from `macos/WEB_PARITY.md`.
Move the Agent Note to `implemented`, replace `## Proposal` with
`## Decision`, and record the actual verification commands and outcomes.
