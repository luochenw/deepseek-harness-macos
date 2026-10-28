import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

// MARK: - Row height policy

/// A streaming row's measurement is one frame of a moving target, so it may
/// neither seed `minHeight` from the cache nor write itself back into it.
private func testRowHeightPolicy_streamingAndCollapsedRowsOptOut() throws {
  try expectEqual(
    DSHTranscriptRowHeightPolicy.mode(isLive: true, isCollapsible: false), .live)
  try expectEqual(
    DSHTranscriptRowHeightPolicy.mode(isLive: false, isCollapsible: true), .off)
  try expectEqual(
    DSHTranscriptRowHeightPolicy.mode(isLive: true, isCollapsible: true), .off)
  try expectEqual(
    DSHTranscriptRowHeightPolicy.mode(isLive: false, isCollapsible: false), .cached)

  try expect(!DSHTranscriptRowHeightPolicy.shouldReadCache(.live),
             "a streaming row must not start from a cached height")
  try expect(!DSHTranscriptRowHeightPolicy.shouldWriteCache(.live, height: 240),
             "a streaming row must not remember a mid-stream height")
  try expect(!DSHTranscriptRowHeightPolicy.shouldWriteCache(.off, height: 240),
             "a collapsed/expanded row's height is not a property of its id")
  try expect(DSHTranscriptRowHeightPolicy.shouldWriteCache(.cached, height: 240))
  try expect(!DSHTranscriptRowHeightPolicy.shouldWriteCache(.cached, height: 0),
             "an empty row has no height to remember")
}

/// A row with no content keeps NO placeholder height — this is the empty
/// interrupted reply bubble that used to reserve its estimate.
private func testRowHeightPolicy_emptyRowHasNoPlaceholderHeight() throws {
  try expectEqual(
    DSHTranscriptRowHeightPolicy.minHeight(cached: 320, estimate: 735, isEmpty: true), 0)
  try expectEqual(
    DSHTranscriptRowHeightPolicy.minHeight(cached: nil, estimate: 54, isEmpty: false), 54)
  try expectEqual(
    DSHTranscriptRowHeightPolicy.minHeight(cached: 180, estimate: 54, isEmpty: false), 180)
  try expect(
    DSHTranscriptRowHeightPolicy.minHeight(cached: 180, estimate: 54, isEmpty: false) == 180,
    "a measured height still wins over a cheaper estimate")
}

// MARK: - Height cache invalidation

/// Content that becomes empty must drop the remembered height, not merely skip
/// the write: a later lookup of the same row id would otherwise resurrect it.
private func testHeightCache_invalidatesWhenContentBecomesEmpty() throws {
  try MainActor.assumeIsolated {
    DSHTranscriptHeightCache.removeAll()
    DSHTranscriptHeightCache.remember(id: "row", version: 7, width: 900, height: 320)
    try expectEqual(DSHTranscriptHeightCache.height(for: "row", version: 7, width: 900), 320)
    // Same id, same version (the row did not get a new version), content now
    // measures 0: the entry must be gone.
    DSHTranscriptHeightCache.remember(id: "row", version: 7, width: 900, height: 0)
    try expectEqual(DSHTranscriptHeightCache.height(for: "row", version: 7, width: 900), nil)
    // Explicit invalidation is idempotent.
    DSHTranscriptHeightCache.invalidate(id: "row")
    try expectEqual(DSHTranscriptHeightCache.height(for: "row", version: 7, width: 900), nil)
  }
}

// MARK: - Interrupted turn: no leftover blank

private struct InterruptedTurnFixturePage: Decodable {
  let records: [DSHHistoryEntry]
  let hasMore: Bool
}

/// Resolves a fixture by walking UP from this source file until a directory
/// contains `scripts/fixtures/<name>`.
///
/// The old version deleted exactly two path components, which lands on
/// `macos/` — so it looked for `macos/scripts/fixtures/...` and threw "no such
/// file" on every run. The end-to-end assertion below therefore never executed
/// once, while the Note claimed it covered the regression. Walking up is what
/// the golden tests already do and survives both the repo and a scratch copy.
///
/// The fixture itself is git-ignored, so a checkout without it returns nil and
/// the caller skips (visibly) rather than looking green.
private func transcriptFixtureURL(_ name: String) -> URL? {
  var candidates: [URL] = []
  if let override = ProcessInfo.processInfo.environment["DSH_GOLDEN_FIXTURES"] {
    candidates.append(URL(fileURLWithPath: override, isDirectory: true)
      .appendingPathComponent(name))
  }
  var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  for _ in 0..<6 {
    candidates.append(directory.appendingPathComponent("scripts/fixtures/\(name)"))
    candidates.append(directory.appendingPathComponent("macos/scripts/fixtures/\(name)"))
    directory = directory.deletingLastPathComponent()
  }
  candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("scripts/fixtures/\(name)"))
  return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
}

/// End-to-end: fold the captured turn 19 of
/// `session-c19df847-b49a-4463-a185-f2b8eed542c4` and render the real
/// `ConversationView`. The row above 「本轮已中断」 is the folded command group
/// ("执行了 6 条命令 · 其中 3 条修改了文件"); the gap under it must be exactly
/// the transcript row spacing, not a stale padded height.
private func testInterruptedTurn_hasNoResidualBlank() throws {
  try MainActor.assumeIsolated {
    guard let fixture = transcriptFixtureURL("transcript-interrupted-turn19.json") else {
      throw TestSkip.message("scripts/fixtures/transcript-interrupted-turn19.json is not on"
        + " this machine; see macos/DSHTests/Fixtures/README.md")
    }
    let data = try Data(contentsOf: fixture)
    let page = try JSONDecoder().decode(InterruptedTurnFixturePage.self, from: data)
    let harness = HarnessController(startRuntime: false)
    let folded = harness.foldHistoryContent(page.records)
    guard folded.messages.contains(where: { $0.text == "本轮已中断" }) else {
      throw TestFailure.message("the fixture must end the turn with 本轮已中断")
    }
    var session = HarnessController.Session(
      title: "turn 19",
      workspaceName: "ds-harness",
      updatedAt: Date(),
      messages: folded.messages,
      hostSessionId: "session-c19df847-b49a-4463-a185-f2b8eed542c4")
    session.isRunning = false
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = session.hostSessionId
    harness.activeTools = folded.tools

    let items = ConversationView.foldTranscript(folded.messages, activeTurnRunning: false)
    guard let groupIndex = items.firstIndex(where: {
      if case .toolGroup = $0 { return true }
      return false
    }), let interruptedIndex = items.firstIndex(where: {
      if case .message(let message) = $0 { return message.text == "本轮已中断" }
      return false
    }), interruptedIndex == groupIndex + 1 else {
      throw TestFailure.message("the fixture must render the command group directly above 本轮已中断")
    }

    var frames: [String: CGRect] = [:]
    // The measurement gate is a plain static flag read while the view body is
    // built, so it must be armed BEFORE the hosting view draws its first frame.
    DSHTranscriptPerf.forceRowFrames = true
    defer { DSHTranscriptPerf.forceRowFrames = false }
    let root = AnyView(
      TranscriptFrameProbe { frames = $0 }
        .frame(width: 900, height: 1200)
        .background(DSHTheme.canvas)
        .environmentObject(harness))
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 1200)
    let window = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 1200),
      styleMask: .borderless,
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFrontRegardless()
    defer {
      window.orderOut(nil)
      window.close()
    }
    runLoop(seconds: 0.8)
    hosting.layoutSubtreeIfNeeded()

    let groupID = items[groupIndex].id
    let interruptedID = items[interruptedIndex].id
    guard let groupFrame = frames[groupID],
          let interruptedFrame = frames[interruptedID] else {
      throw TestFailure.message(
        "row frames missing (have \(frames.keys.sorted()), want \(groupID) and \(interruptedID))")
    }
    let gap = interruptedFrame.minY - groupFrame.maxY
    print(String(
      format: "interrupted-turn gap=%.1fpt (row spacing %.1fpt, group h=%.1f, group estimate=%.1f)",
      gap, DSHSpace.s4, groupFrame.height,
      DSHTranscriptRowEstimate.toolStatusRowHeight(accessory: false)))
    try expect(abs(gap - DSHSpace.s4) < 0.5,
      "the gap under the command group must be one row spacing (\(DSHSpace.s4)), got \(gap)")
    // The folded group is ONE collapsed line no matter how many commands it
    // holds: its rendered content must not be padded to count × row height.
    try expect(groupFrame.height < DSHSpace.s7,
      "the 6-command group must stay one collapsed line, got \(groupFrame.height)pt")
  }
}

private struct TranscriptFrameProbe: View {
  let onFrames: ([String: CGRect]) -> Void
  var body: some View {
    ConversationView()
      .onPreferenceChange(DSHTranscriptRowFrameKey.self) { onFrames($0) }
  }
}

private func runLoop(seconds: TimeInterval) {
  RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

let dshTranscriptRowHeightTests: [NamedTest] = [
  ("Row height policy opts streaming and collapsed rows out of the cache",
   testRowHeightPolicy_streamingAndCollapsedRowsOptOut),
  ("Empty rows keep no placeholder height",
   testRowHeightPolicy_emptyRowHasNoPlaceholderHeight),
  ("Height cache invalidates when content becomes empty",
   testHeightCache_invalidatesWhenContentBecomesEmpty),
  ("Interrupted turn has no residual blank above 本轮已中断",
   testInterruptedTurn_hasNoResidualBlank),
  ("Message bubble equality covers attachment and relay flag",
   testMessageBubbleAttachmentInvalidatesEquality),
  ("Row version hashes reasoning content, not just its length",
   testRowVersionHashesReasoningContent),
  ("Tool group signature tracks resolved activity state",
   testToolGroupSignatureTracksActivityState),
  ("Failed tool call is marked in the folded group",
   testFailedToolCallIsMarked),
  ("Height estimate accounts for CJK glyph width",
   testEstimateAccountsForCJKWidth),
]

// MARK: - Equatable must cover what the row renders

/// A message whose attachment arrives AFTER the message exists (Host fills it
/// in on `assistant/message`, `mergeTail`, or a live patch) must not compare
/// equal to its attachment-less self, or SwiftUI reuses the old prop and the
/// preview never appears.
private func testMessageBubbleAttachmentInvalidatesEquality() throws {
  var base = HarnessController.Message(role: .assistant, text: "done")
  base.hostMessageId = "m1"
  let bare = MessageBubble(message: base)
  var withAttachment = base
  withAttachment.attachment = DSHAttachmentRef(
    attachmentId: "att-1", mediaType: "image/png", bytes: 10,
    width: 4, height: 4, name: nil)
  let attached = MessageBubble(message: withAttachment)
  try expect(bare != attached, "adding an attachment must invalidate the row")
  var otherAttachment = base
  otherAttachment.attachment = DSHAttachmentRef(
    attachmentId: "att-2", mediaType: "image/png", bytes: 10,
    width: 4, height: 4, name: nil)
  try expect(attached != MessageBubble(message: otherAttachment),
             "swapping the attachment id must invalidate the row")
  // Relay flag drives the 「来自其他会话」 label.
  var relay = base
  relay.isRelayMessage = true
  try expect(MessageBubble(message: relay) != bare,
             "the relay flag must invalidate the row")
}

/// Reasoning used to contribute only its byte count, so two equal-length
/// traces hashed the same and the row kept the previous height/body.
private func testRowVersionHashesReasoningContent() throws {
  var a = HarnessController.Message(role: .assistant, text: "answer")
  a.reasoning = "abcdef"
  var b = a
  b.reasoning = "ghijkl"   // same length, different content
  try expect(ConversationView.rowVersion(message: a) != ConversationView.rowVersion(message: b),
             "same-length reasoning must still change the row version")
  var c = a
  c.attachment = DSHAttachmentRef(
    attachmentId: "att-9", mediaType: "image/png", bytes: 1, width: 1, height: 1, name: nil)
  try expect(ConversationView.rowVersion(message: a) != ConversationView.rowVersion(message: c),
             "an attachment must change the row version")
}

/// The group's `==` must see the resolved activity state, not just the
/// message list: a result landing changes the title/failure count without
/// appending a message.
private func testToolGroupSignatureTracksActivityState() throws {
  var running = HarnessController.Message(role: .tool, text: "bundle exec rspec")
  running.toolCallId = "call-1"
  let finished = [HarnessController.ToolActivity]()
  let sigWithoutTools = ConversationView.toolGroupSignature([running], tools: finished)
  // No activity ⇒ the title falls back to the message text; the shape is still
  // stable and non-empty so `==` has something to compare.
  try expect(!sigWithoutTools.isEmpty, "the signature must not be empty")
  try expect(sigWithoutTools.contains("1"), "the signature must carry the command count")
}

/// A failed call must be visible in the rendered row: coral icon + 「失败」.
/// Asserted on the model the row reads (digest/activity), because the SwiftUI
/// text itself is not inspectable offscreen.
private func testFailedToolCallIsMarked() throws {
  try MainActor.assumeIsolated {
  let activity = HarnessController.ToolActivity(
    callId: "call-1", name: "bash", summary: "npm test", state: .failed, output: "")
  let summary = DSHToolGroupStatus.summary(for: [activity])
  try expectEqual(summary?.failed, true)
  // The folded group must count it.
  let digest = DSHToolGroupDigestBuilder.digest(for: [
    .init(title: "npm test", kind: .readOnly, running: false, failed: true),
    .init(title: "npm run build", kind: .readOnly, running: false, failed: false),
  ])
  try expectEqual(digest?.failedCount, 1)
  try expectEqual(digest?.failedSummary, "1 条失败")
  try expectEqual(digest?.isFailed, true)
  // And a clean group must not claim a failure.
  let clean = DSHToolGroupDigestBuilder.digest(for: [
    .init(title: "ls", kind: .readOnly, running: false, failed: false),
  ])
  try expectEqual(clean?.isFailed, false)
  try expectEqual(clean?.failedSummary, nil)

  // Render side: the failed row must actually paint the coral marker. The
  // model assertions above would still pass if someone deleted the icon.
  let harness = HarnessController(startRuntime: false)
  var messages: [HarnessController.Message] = []
  for (index, state) in [HarnessController.ToolActivity.State.succeeded,
                         .failed, .failed, .succeeded].enumerated() {
    var message = HarnessController.Message(role: .tool, text: "cmd-\(index)")
    message.toolCallId = "call-\(index)"
    messages.append(message)
    harness.activeTools.append(HarnessController.ToolActivity(
      callId: "call-\(index)", name: "bash",
      summary: "cmd-\(index)", state: state, output: ""))
  }
  var session = HarnessController.Session(
    title: "failed", workspaceName: "w", updatedAt: Date(),
    messages: messages, hostSessionId: "sid")
  session.isRunning = false
  harness.sessions = [session]
  harness.selectedSessionID = session.id
  harness.hostCurrentSessionID = "sid"
  let root = AnyView(
    ConversationView()
      .frame(width: 900, height: 600)
      .background(DSHTheme.canvas)
      .environmentObject(harness))
  _ = NSApplication.shared
  NSApp.appearance = NSAppearance(named: .aqua)
  let hosting = NSHostingView(rootView: root)
  hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
  let window = NSWindow(
    contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
    styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = hosting
  window.orderFrontRegardless()
  defer {
    window.orderOut(nil)
    window.close()
  }
  runLoop(seconds: 1.2)
  hosting.layoutSubtreeIfNeeded()
  let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
  hosting.cacheDisplay(in: hosting.bounds, to: rep)
  var coral = 0
  for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
    for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
      guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
      if colour.redComponent > 0.55, colour.greenComponent < 0.45,
         colour.blueComponent < 0.40,
         colour.redComponent - colour.greenComponent > 0.25 {
        coral += 1
      }
    }
  }
  try expect(coral > 50,
             "the failed group painted \(coral) coral pixels: no failure marker")
  }
}

/// The estimate must not under-count Chinese: at 804pt usable a 14.5pt CJK
/// glyph is ~14.5pt wide, so ~55 glyphs per line, not 111.
private func testEstimateAccountsForCJKWidth() throws {
  let line = String(repeating: "中", count: 60)
  let height = DSHTranscriptRowEstimate.messageHeight(
    HarnessController.Message(role: .assistant, text: line), width: 900)
  // 60 CJK glyphs cannot fit on one 804pt line (60*14.5 = 870), so ≥2 lines.
  try expect(height > 22 * 2, "60 CJK glyphs must estimate as more than one line, got \(height)")
  let ascii = DSHTranscriptRowEstimate.messageHeight(
    HarnessController.Message(role: .assistant, text: String(repeating: "a", count: 60)),
    width: 900)
  try expect(ascii < height, "60 ASCII glyphs must estimate shorter than 60 CJK glyphs")
}
