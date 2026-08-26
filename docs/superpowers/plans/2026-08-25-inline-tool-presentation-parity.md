# Inline Tool Presentation Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render every structured DSH tool intent consistently inline and in
the DetailsPanel, with bounded long output and language-aware source display.

**Architecture:** Extract the semantic body of `NativeToolPresentationView`
from its DetailsPanel card chrome. The transcript reuses that body in compact
mode. A pure disclosure-window helper controls head/tail slices for long
lists, and a pure tokenizer supplies conservative token ranges to the source
renderer.

**Tech Stack:** SwiftUI, AppKit, DSH structured ToolPresentation wire payloads,
direct `swiftc` test harness, offscreen NSHostingView snapshots.

---

### Task 1: Test Pure Disclosure and Tokenization Contracts

**Files:**
- Create: `macos/DSHTests/DSHToolPresentationTests.swift`
- Modify: `macos/DSHTests/DSHTestsMain.swift`
- Create: `macos/DSHApp/DSHToolPresentationSupport.swift`

- [ ] **Step 1: Write failing disclosure tests**

```swift
let window = DSHDisclosureWindow.slice(count: 19, maxVisible: 16, expanded: false)
try expectEqual(window.head, 0..<8)
try expectEqual(window.tail, 11..<19)
try expectEqual(window.hiddenCount, 3)
try expect(DSHDisclosureWindow.slice(count: 16, maxVisible: 16, expanded: false).isCollapsed == false)
```

- [ ] **Step 2: Write failing tokenizer tests**

```swift
let tokens = DSHSourceTokenizer.tokens(in: "let value = 42 // note", language: "swift")
try expect(tokens.contains { $0.kind == .keyword && $0.text == "let" })
try expect(tokens.contains { $0.kind == .number && $0.text == "42" })
try expect(tokens.contains { $0.kind == .comment && $0.text == "// note" })
```

- [ ] **Step 3: Run unit tests and verify RED**

Run:

```bash
./scripts/test-macos-native.sh --unit
```

Expected: compile failures because the disclosure and tokenizer types do not
exist.

- [ ] **Step 4: Implement pure helpers**

Define:

```swift
struct DSHDisclosureWindow: Equatable {
  let head: Range<Int>
  let tail: Range<Int>
  let hiddenCount: Int
  var isCollapsed: Bool
  static func slice(count: Int, maxVisible: Int = 16, expanded: Bool) -> Self
}
```

Define `DSHSourceTokenizer` with tokens for comments, strings, numbers,
keywords, and JSON keys; use a plaintext token for unsupported language hints.

- [ ] **Step 5: Run unit tests and verify GREEN**

Run:

```bash
./scripts/test-macos-native.sh --unit
```

Expected: all pre-existing tests plus the new tool presentation tests pass.

### Task 2: Extract Shared Structured Tool Content

**Files:**
- Modify: `macos/DSHApp/NativeToolPresentationView.swift`
- Modify: `macos/DSHApp/ConversationView.swift`

- [ ] **Step 1: Add the reusable body**

Create an internal `ToolPresentationContent` view that accepts:

```swift
let tool: HarnessController.ToolActivity
let compact: Bool
```

It switches on `terminal`, `diff`, `read`, `search`, `web`, and generic
fallback. `NativeToolPresentationView` retains `Card` chrome and delegates
its body to this view.

- [ ] **Step 2: Use the body from transcript rows**

Replace `ToolCallRow.expandedBody`'s duplicated switch with:

```swift
ToolPresentationContent(tool: activity, compact: true)
```

The transcript continues to own its row header and DetailsPanel button; it
does not embed `Card` chrome.

- [ ] **Step 3: Apply shared disclosure windows**

Use `DSHDisclosureWindow` in terminal code output, numbered read lines,
structured search rows, and `DiffLines`. Each disclosure control names the
number of hidden lines/rows and preserves the first/last halves when
collapsed.

- [ ] **Step 4: Apply tokenizer styling to read lines**

Map `DSHSourceTokenizer.tokens` into `AttributedString` styles using existing
theme colors. Preserve exact source text and line numbers; unsupported
languages use the original plain `Text`.

### Task 3: Add Structured UI Contracts and Snapshot Coverage

**Files:**
- Create: `scripts/fixtures/tool-presentation-snapshot-check.swift`
- Create: `scripts/test-tool-presentation-ui.sh`
- Modify: `scripts/test-macos-native.sh`

- [ ] **Step 1: Create a source contract**

Require:

```bash
grep -q 'ToolPresentationContent' macos/DSHApp/NativeToolPresentationView.swift
grep -q 'ToolPresentationContent(tool: activity, compact: true)' macos/DSHApp/ConversationView.swift
grep -q 'DSHDisclosureWindow' macos/DSHApp/NativeToolPresentationView.swift
grep -q 'DSHSourceTokenizer' macos/DSHApp/NativeToolPresentationView.swift
```

- [ ] **Step 2: Render every inline card kind**

The offscreen fixture creates representative terminal, diff, read, search,
web, and generic `ToolActivity` values, renders a compact `ToolPresentationContent`
stack, and validates a PNG's scale, nonblank pixels, and color diversity.

- [ ] **Step 3: Add the script to native contracts**

Run `scripts/test-tool-presentation-ui.sh` after the existing attachment rail
UI contract in `scripts/test-macos-native.sh`.

### Task 4: Verify, Review, and Close

**Files:**
- Modify: `macos/WEB_PARITY.md`
- Move: `.agents/notes/proposed/feature/2026-08-25-inline-tool-presentation-parity.md`
- To: `.agents/notes/implemented/feature/2026-08-25-inline-tool-presentation-parity.md`

- [ ] **Step 1: Run all gates**

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

Change `macos/WEB_PARITY.md` to record structured inline card parity and
move the Agent Note to `implemented`, including the exact verification
outcomes.
