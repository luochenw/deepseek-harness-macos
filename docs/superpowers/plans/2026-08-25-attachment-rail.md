# Attachment Rail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native horizontal rail for all images in the currently
displayed root or subagent transcript.

**Architecture:** Derive rail entries from message attachments at render time,
including the session ID that can authorize the image. Reuse the current
attachment cache and lightbox. Parse references from both history and live
settled messages so the derived list stays current without a second
Host-derived store.

**Tech Stack:** SwiftUI, AppKit `NSImage`, existing DSH loopback attachment
RPC, direct `swiftc` unit harness.

---

### Task 1: Define and Test the Derived Rail Model

**Files:**
- Create: `macos/DSHTests/DSHAttachmentTests.swift`
- Modify: `macos/DSHTests/DSHTestsMain.swift`
- Modify: `macos/DSHApp/DSHAttachments.swift`

- [x] **Step 1: Write failing rail-model tests**

Test `DSHAttachmentRail.items(messages:sessionID:)` with three messages:

```swift
let first = HarnessController.Message(
  role: .user,
  text: "first",
  attachment: DSHAttachmentRef(
    attachmentId: "a",
    mediaType: "image/png",
    bytes: 1,
    width: 10,
    height: 10,
    name: "a.png"))
let second = HarnessController.Message(role: .assistant, text: "no image")
let third = HarnessController.Message(
  role: .assistant,
  text: "repeat",
  attachment: first.attachment)
let items = DSHAttachmentRail.items(messages: [first, second, third], sessionID: "child-1")
try expectEqual(items.map(\.ref.attachmentId), ["a", "a"])
try expectEqual(items.map(\.sessionID), ["child-1", "child-1"])
try expectEqual(items.map(\.messageID), [first.id, third.id])
try expect(DSHAttachmentRail.items(messages: [first], sessionID: nil).isEmpty)
```

- [x] **Step 2: Run the unit command and observe failure**

Run:

```bash
./scripts/test-macos-native.sh --unit
```

Expected: compiler failure because `DSHAttachmentRail` and its tests are not
defined yet.

- [x] **Step 3: Implement the pure rail model**

Create `DSHAttachmentRailItem` with `messageID`, `ref`, and `sessionID`, then
implement an order-preserving `DSHAttachmentRail.items` projection that
returns no values when the authorization session is absent or blank.

- [x] **Step 4: Run the unit command**

Run:

```bash
./scripts/test-macos-native.sh --unit
```

Expected: the new attachment tests and all pre-existing tests pass.

### Task 2: Preserve Attachment References Across History and Live Events

**Files:**
- Modify: `macos/DSHApp/DSHAttachments.swift`
- Modify: `macos/DSHApp/DSHHistory.swift`
- Modify: `macos/DSHApp/DSHEventSocket.swift`

- [x] **Step 1: Add failing live-decoder assertions**

Extend `DSHAttachmentTests.swift` with a live payload:

```swift
let attachment = DSHAttachmentRef.fromLiveMessage([
  "content": [[
    "type": "image",
    "attachment": [
      "attachmentId": "live",
      "mediaType": "image/jpeg",
      "bytes": 42,
      "width": 120,
      "height": 80,
      "name": "live.jpg",
    ],
  ]],
])
try expectEqual(attachment?.attachmentId, "live")
try expectEqual(attachment?.width, 120)
```

- [x] **Step 2: Run the unit command and observe failure**

Run:

```bash
./scripts/test-macos-native.sh --unit
```

Expected: compiler failure because the live decoder is absent.

- [x] **Step 3: Implement shared history and live decoders**

Move history attachment parsing behind `DSHAttachmentRef.fromHistoryMessage`.
Add `fromLiveMessage(_:)` for the `[String: Any]` event shape. Call these
helpers in root and subagent user/assistant settled-event paths. When a
root user event matches the local user echo, assign the attachment to that
existing message rather than append a duplicate.

- [x] **Step 4: Run the unit command**

Run:

```bash
./scripts/test-macos-native.sh --unit
```

Expected: attachment-decoder tests and all existing tests pass.

### Task 3: Render the Rail and Reuse the Lightbox

**Files:**
- Modify: `macos/DSHApp/DSHAttachments.swift`
- Modify: `macos/DSHApp/NativeAttachmentPreview.swift`
- Modify: `macos/DSHApp/ConversationView.swift`

- [x] **Step 1: Add controller-derived attachment context**

Add:

```swift
var displayedAttachmentSessionID: String? {
  activeSubagentAddress?.childSessionId ?? hostCurrentSessionID
}

var displayedAttachmentRailItems: [DSHAttachmentRailItem] {
  DSHAttachmentRail.items(
    messages: displayedSession?.messages ?? [],
    sessionID: displayedAttachmentSessionID)
}
```

Both are computed properties in `DSHAttachments.swift`; no new
`@Published` state is permitted.

- [x] **Step 2: Update inline preview ownership**

Pass each message’s UUID and `displayedAttachmentSessionID` to
`AttachmentPreview`. The image-rendering child observes
`DSHAttachmentStore` directly, requests the image with that session ID, and
opens a lightbox initialized with the same reference/session pair.

- [x] **Step 3: Add the horizontal rail**

Add `AttachmentRail` under the existing header HStack. It uses:

```swift
ScrollView(.horizontal, showsIndicators: false) {
  LazyHStack(spacing: DSHSpace.s2) { ... }
}
```

Each stable 52×52 thumbnail has a `photo` fallback, accessible help text,
and opens the existing lightbox. It uses the same store and per-item
authorization session.

- [x] **Step 4: Add source-contract checks**

Extend `scripts/test-agent-platform-ui.sh` or create a focused attachment
contract script to require `AttachmentRail`, `LazyHStack`, and
`displayedAttachmentSessionID` wiring. Do not use screenshot assertions as a
substitute for the pure data tests.

### Task 4: Verify and Record

**Files:**
- Modify: `macos/WEB_PARITY.md`
- Move: `.agents/notes/proposed/feature/2026-08-25-attachment-rail.md`
- To: `.agents/notes/implemented/feature/2026-08-25-attachment-rail.md`

- [x] **Step 1: Run focused and full checks**

Run:

```bash
./scripts/test-macos-native.sh
./scripts/test-macos-native.sh --unit
./scripts/test-agent-platform-runtime-script.sh
./scripts/test-agent-platform-runtime.sh
./scripts/build-macos-app.sh
./scripts/test-macos-native.sh --smoke
git diff --check
```

Expected: all commands exit zero.

- [x] **Step 2: Update parity and the Agent Note**

Replace the rail’s open status in `macos/WEB_PARITY.md`. Move the Agent Note
to `implemented`, convert `## Proposal` to `## Decision`, and record the
verification outcomes.
