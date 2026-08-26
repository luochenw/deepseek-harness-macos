# Windowed Conversation Trajectory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound the number of conversation messages materialized by
`ConversationView` while preserving streaming, history pagination, and scroll
anchors.

**Architecture:** A pure range planner chooses a contiguous message window.
A feature-local per-controller registry stores one range and optional restore
anchor per root or child context, forwarding mutation through the existing
controller observation channel. The view renders only that slice and requests
adjacent pages with edge sentinels.

**Tech Stack:** SwiftUI `ScrollViewReader`, direct `swiftc` unit harness,
existing `HarnessController.Session` message store and Host history paging.

---

### Task 1: Specify the Pure Window Planner

**Files:**
- Create: `macos/DSHApp/DSHConversationWindow.swift`
- Create: `macos/DSHTests/DSHConversationWindowTests.swift`
- Modify: `macos/DSHTests/DSHTestsMain.swift`

- [ ] **Step 1: Write failing initial and tail-follow tests**

```swift
let initial = DSHConversationWindowPlanner.initialRange(count: 1_000)
try expectEqual(initial, 760..<1_000)

let tail = DSHConversationWindowPlanner.updatedRange(
  current: 760..<1_000,
  count: 1_008,
  pinnedToBottom: true)
try expectEqual(tail, 768..<1_008)
```

- [ ] **Step 2: Write failing edge expansion and prepend tests**

```swift
try expectEqual(
  DSHConversationWindowPlanner.expandEarlier(current: 760..<1_000, count: 1_000),
  640..<1_000)
try expectEqual(
  DSHConversationWindowPlanner.expandLater(current: 240..<480, count: 1_000),
  240..<600)
try expectEqual(
  DSHConversationWindowPlanner.prepended(
    current: 760..<1_000,
    insertedCount: 120,
    countAfterInsert: 1_120),
  640..<1_120)
```

- [ ] **Step 3: Run the unit command and verify RED**

Run:

```bash
./scripts/test-macos-native.sh --unit
```

Expected: compile failure because the planner is absent.

- [ ] **Step 4: Implement the pure planner**

Use constants:

```swift
static let capacity = 240
static let expansion = 120
```

Clamp every returned range to `0..<count`. An empty input returns `0..<0`.

- [ ] **Step 5: Run the unit command and verify GREEN**

Run:

```bash
./scripts/test-macos-native.sh --unit
```

Expected: all existing tests plus window planner tests pass.

### Task 2: Add Per-Context Window State

**Files:**
- Modify: `macos/DSHApp/DSHConversationWindow.swift`
- Modify: `macos/DSHApp/DSHHistory.swift`
- Modify: `macos/DSHApp/DSHSessionLifecycle.swift`

- [ ] **Step 1: Add context keys and state**

Expose:

```swift
var displayedConversationContextKey: String?
var displayedMessageWindow: Range<Int>
var displayedWindowMessages: [Message]
var conversationWindowDebugSnapshot: DSHConversationWindowDebugSnapshot?
```

Top-level keys use local `Session.id`; child keys use
`activeSubagentAddress.childSessionId`. The feature-local registry weakly
owns its controller and forwards `objectWillChange`.

- [ ] **Step 2: Wire message-count updates**

Add:

```swift
func updateDisplayedConversationWindow(
  messageCount: Int,
  pinnedToBottom: Bool)
```

When pinned, it slides the current context to the tail. Otherwise it keeps
the existing valid range. Session/subagent switching initializes the new
context at the tail.

- [ ] **Step 3: Preserve prepend position**

Change `loadOlderHistory()` to capture the currently materialized leading
message UUID before prepending. After insertion, call a window method that
expands earlier and stores the UUID as a one-shot restore anchor.

- [ ] **Step 4: Add state-isolation tests**

Test independent root/child keys and a prepend anchor:

```swift
try expectEqual(rootRange, 760..<1_000)
try expectEqual(childRange, 0..<30)
try expectEqual(harness.conversationWindowRestoreAnchor, anchor.id)
```

### Task 3: Render the Slice and Edge Sentinels

**Files:**
- Modify: `macos/DSHApp/ConversationView.swift`

- [ ] **Step 1: Render `displayedWindowMessages`**

Replace:

```swift
let messages = harness.displayedSession?.messages ?? []
```

with a slice from the new selector. Keep `foldTranscript` unchanged except
for retaining each group/message's leading message UUID as its row anchor.

- [ ] **Step 2: Add edge sentinels**

Above and below the transcript rows add clear, fixed-height views that call:

```swift
harness.expandDisplayedConversationEarlier(
  anchorMessageID: messages.first?.id)
harness.expandDisplayedConversationLater()
```

only when the current range has more content in that direction.

- [ ] **Step 3: Restore prepended anchor**

Observe the one-shot anchor token. On the next layout turn:

```swift
proxy.scrollTo(anchorID, anchor: .top)
harness.consumeConversationWindowRestoreAnchor(anchorID)
```

This runs only after `displayedWindowMessages` contains the anchor.

- [ ] **Step 4: Preserve tail following**

Use full-message count for window updates, but continue scrolling to
`"transcript-tail"` only when `pinnedToBottom`. A user message still forces
the pin, while a remote append does not.

### Task 4: Add Contracts and Verify

**Files:**
- Create: `scripts/test-conversation-window-ui.sh`
- Modify: `scripts/test-macos-native.sh`
- Modify: `macos/WEB_PARITY.md`
- Move: `.agents/notes/proposed/feature/2026-08-25-windowed-conversation-trajectory.md`
- To: `.agents/notes/implemented/feature/2026-08-25-windowed-conversation-trajectory.md`

- [ ] **Step 1: Add source contract checks**

Require the view to use:

```bash
grep -q 'displayedWindowMessages' macos/DSHApp/ConversationView.swift
grep -q 'expandDisplayedConversationEarlier' macos/DSHApp/ConversationView.swift
grep -q 'expandDisplayedConversationLater' macos/DSHApp/ConversationView.swift
grep -q 'conversationWindowRestoreAnchor' macos/DSHApp/ConversationView.swift
```

- [ ] **Step 2: Run all gates**

```bash
./scripts/test-macos-native.sh
./scripts/test-macos-native.sh --unit
./scripts/test-agent-platform-runtime-script.sh
./scripts/test-agent-platform-runtime.sh
./scripts/build-macos-app.sh
./scripts/test-macos-native.sh --smoke
git diff --check
```

- [ ] **Step 3: Record completion**

Update `macos/WEB_PARITY.md` to mark trajectory virtualization implemented.
Move the Agent Note to `implemented`, change `## Proposal` to `## Decision`,
and list the actual verification results.
