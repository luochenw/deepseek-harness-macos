import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

// MARK: - Golden regression over real Host sessions
//
// Four fixtures captured from the running Host through `session/page` (see
// `macos/DSHTests/Fixtures/README.md` for how they are produced and what was
// stripped). They are local-only and git-ignored, so a test whose fixture is
// absent reports SKIP instead of passing or failing. They exist because two
// transcript bugs shipped while every synthetic test passed:
//
//   * a folded command row that reserved `rowHeight × commandCount` as its
//     `minHeight` (103 commands ⇒ ~2 470pt of blank under one 25pt line), and
//   * an `Equatable` row whose version hash ignored everything the row renders
//     from `harness.displayedTools` (title, running state), so a live command
//     row could stay frozen at its first, empty frame.
//
// The assertions below are deliberately about what a reader can SEE: a row has
// to occupy a sane amount of space, carry ink on screen, and the live sequence
// has to track the events instead of a stale snapshot.

// MARK: Fixture loading

private struct DSHGoldenFixture: Decodable {
  struct Meta: Decodable { let session: String?; let title: String? }
  let meta: Meta?
  let records: [DSHHistoryEntry]
}

private func goldenFixture(_ name: String) throws -> DSHGoldenFixture {
  // Tests run from the repo root (scripts/test-macos-native.sh) and from a
  // scratch build directory (the heavy-gate wrapper copies this file
  // elsewhere), so look for the fixtures relative to the source file first and
  // fall back to the process cwd. DSH_GOLDEN_FIXTURES overrides both.
  var candidates: [URL] = []
  if let override = ProcessInfo.processInfo.environment["DSH_GOLDEN_FIXTURES"] {
    candidates.append(URL(fileURLWithPath: override, isDirectory: true))
  }
  var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  for _ in 0..<6 {
    candidates.append(directory.appendingPathComponent("Fixtures", isDirectory: true))
    candidates.append(directory.appendingPathComponent("macos/DSHTests/Fixtures", isDirectory: true))
    directory = directory.deletingLastPathComponent()
  }
  candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("macos/DSHTests/Fixtures", isDirectory: true))
  let tried = candidates.map { $0.appendingPathComponent("\(name).json") }
  // The fixtures are local-only (git-ignored), so a checkout without them skips
  // this test instead of failing it. A fixture that IS on disk but does not
  // decode still throws below — that is the regression the golden run exists for.
  guard let url = tried.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
    throw TestSkip.message("fixture \(name).json is not on this machine"
      + " (looked in \(candidates.count) directories); see macos/DSHTests/Fixtures/README.md")
  }
  return try JSONDecoder().decode(DSHGoldenFixture.self, from: Data(contentsOf: url))
}

// MARK: Offscreen render

private struct DSHGoldenProbe: View {
  let onFrames: ([String: CGRect]) -> Void
  let onHeight: (CGFloat) -> Void
  var body: some View {
    ConversationView()
      .onPreferenceChange(DSHTranscriptRowFrameKey.self) { onFrames($0) }
      .onPreferenceChange(DSHTranscriptLayoutMetricsKey.self) { onHeight($0.contentHeight) }
  }
}

/// A rendered transcript plus everything the assertions need to look at.
private struct DSHGoldenRender {
  let frames: [String: CGRect]
  let documentHeight: CGFloat
  let items: [ConversationView.TranscriptItem]
  let image: NSBitmapImageRep
}

@MainActor private func goldenHarness(
  _ records: [DSHHistoryEntry],
  running: Bool = false
) -> (HarnessController, DSHFoldedHistory) {
  let harness = HarnessController(startRuntime: false)
  let folded = harness.foldHistoryContent(records)
  var session = HarnessController.Session(
    title: "golden",
    workspaceName: "ds-harness",
    updatedAt: Date(),
    messages: folded.messages,
    hostSessionId: "session-golden")
  session.isRunning = running
  harness.sessions = [session]
  harness.selectedSessionID = session.id
  harness.hostCurrentSessionID = session.hostSessionId
  harness.activeTools = folded.tools
  return (harness, folded)
}

/// Lays the transcript out at `width × height` and rasterises it. The window
/// sits far off-screen so nothing is ever shown to the user.
@MainActor private func goldenRender(
  _ harness: HarnessController,
  width: CGFloat = 900,
  height: CGFloat = 5_200
) -> DSHGoldenRender {
  _ = NSApplication.shared
  NSApp.appearance = NSAppearance(named: .aqua)
  DSHTranscriptPerf.forceRowFrames = true
  defer { DSHTranscriptPerf.forceRowFrames = false }

  var frames: [String: CGRect] = [:]
  var documentHeight: CGFloat = 0
  let root = AnyView(
    DSHGoldenProbe(onFrames: { frames = $0 }, onHeight: { documentHeight = $0 })
      .frame(width: width, height: height)
      .background(DSHTheme.canvas)
      .environmentObject(harness))
  let hosting = NSHostingView(rootView: root)
  hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
  let window = NSWindow(
    contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
    styleMask: .borderless,
    backing: .buffered,
    defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = hosting
  window.orderFrontRegardless()
  runLoopFor(1.8)
  hosting.layoutSubtreeIfNeeded()
  hosting.displayIfNeeded()
  let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
  hosting.cacheDisplay(in: hosting.bounds, to: image)
  window.orderOut(nil)
  window.close()
  let items = ConversationView.foldTranscript(
    harness.displayedSession?.messages ?? [],
    activeTurnRunning: harness.displayedIsRunning)
  return DSHGoldenRender(
    frames: frames, documentHeight: documentHeight, items: items, image: image)
}

private func runLoopFor(_ seconds: TimeInterval) {
  RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// Counts dark pixels inside a rect. A row that reserved space but painted
/// nothing is exactly the "整行看不见" symptom, so this is the check that has
/// teeth; a height comparison alone would pass a blank row.
@MainActor private func goldenInk(_ render: DSHGoldenRender, _ rect: CGRect) -> Int {
  let image = render.image
  let scale = CGFloat(image.pixelsWide) / max(1, render.image.size.width)
  let x0 = max(0, Int(rect.minX * scale)), x1 = min(image.pixelsWide, Int(rect.maxX * scale))
  let y0 = max(0, Int(rect.minY * scale)), y1 = min(image.pixelsHigh, Int(rect.maxY * scale))
  guard x1 > x0, y1 > y0 else { return 0 }
  var ink = 0
  for y in stride(from: y0, to: y1, by: 2) {
    for x in stride(from: x0, to: x1, by: 2) {
      guard let colour = image.colorAt(x: x, y: y) else { continue }
      if colour.alphaComponent > 0.1, colour.brightnessComponent < 0.9 { ink += 1 }
    }
  }
  return ink
}

/// The collapsed line a group renders, computed the same way `ToolGroupRow`
/// does. Used to assert that the count and the newest command title track the
/// events instead of a stale digest.
@MainActor private func goldenDigest(
  _ group: [HarnessController.Message],
  tools: [HarnessController.ToolActivity]
) -> DSHToolGroupDigest? {
  let calls = group.map { message -> DSHToolGroupDigestBuilder.Call in
    let activity = message.toolCallId.flatMap { id in
      tools.last { $0.callId == id }
    }
    let title = activity.flatMap { DSHToolGroupStatus.instructionTitle(for: $0) }
      ?? message.text
    let kind = activity?.callKind
      ?? DSHToolCallClassifier.kind(name: message.text, arguments: String?.none)
    return DSHToolGroupDigestBuilder.Call(
      title: title, kind: kind, running: activity?.state == .running)
  }
  return DSHToolGroupDigestBuilder.digest(for: calls)
}

// MARK: Visible-geometry measurement
//
// Row FRAMES say nothing about what a reader sees: a row can be 76pt tall with
// its text in the top 40pt, and a full-width `opacity(0)` strip can sit under
// it contributing height without contributing a single pixel. Both bugs found
// on 2026-10-28 hid exactly there. These helpers measure ink instead.

/// One horizontal run of rows that contain visible pixels.
private struct DSHInkBands {
  /// Top/bottom of every ink run, in points, plus the y of each row that
  /// painted something.
  let runs: [(top: CGFloat, bottom: CGFloat)]
  let lastBottom: CGFloat
  let imageHeight: CGFloat

  /// Gaps between consecutive runs of ink — the distance a reader actually
  /// perceives between two pieces of content.
  var gaps: [CGFloat] {
    zip(runs, runs.dropFirst()).map { $1.top - $0.bottom }
  }

  var largestGap: CGFloat { gaps.max() ?? 0 }
}

/// Scans the rendered image row by row and groups the rows that carry content.
///
/// "Content" is anything that differs from the canvas colour, not just dark
/// text: a user bubble's tinted card, an attachment thumbnail and a hairline
/// divider are all things a reader sees, and leaving them out would report the
/// card's own padding as blank space.
@MainActor private func goldenInkBands(_ render: DSHGoldenRender) -> DSHInkBands {
  let image = render.image
  let scale = CGFloat(image.pixelsWide) / max(1, image.size.width)
  guard let background = image.colorAt(x: 1, y: 1) else {
    return DSHInkBands(runs: [], lastBottom: 0, imageHeight: 0)
  }
  func isContent(_ colour: NSColor) -> Bool {
    abs(colour.redComponent - background.redComponent) > 0.012
      || abs(colour.greenComponent - background.greenComponent) > 0.012
      || abs(colour.blueComponent - background.blueComponent) > 0.012
      || abs(colour.alphaComponent - background.alphaComponent) > 0.012
  }
  var runs: [(CGFloat, CGFloat)] = []
  var start = -1
  var last = -1
  func close() {
    if start >= 0 { runs.append((CGFloat(start) / scale, CGFloat(last) / scale)) }
    start = -1
  }
  for y in 0..<image.pixelsHigh {
    var count = 0
    for x in stride(from: 0, to: image.pixelsWide, by: 3) {
      guard let colour = image.colorAt(x: x, y: y) else { continue }
      if isContent(colour) { count += 1 }
    }
    // A couple of stray antialiased pixels are not a visible line.
    if count > 4 {
      if start < 0 { start = y }
      last = y
    } else {
      close()
    }
  }
  close()
  return DSHInkBands(
    runs: runs,
    lastBottom: CGFloat(last) / scale,
    imageHeight: CGFloat(image.pixelsHigh) / scale)
}

// MARK: Tests

/// ① A command-heavy real turn: 103 calls folded into one collapsed line, and
/// the whole transcript has to stay compact (it used to be padded to 4 698pt).
private func testGolden_commandHeavyTurnIsCompact() throws {
  try MainActor.assumeIsolated {
    let fixture = try goldenFixture("session-84f7c0cb-turn1")
    let (harness, folded) = goldenHarness(fixture.records)
    let toolCalls = folded.messages.filter { $0.role == .tool }.count
    try expectEqual(toolCalls, 103)

    let render = goldenRender(harness)
    var grouped = 0
    for item in render.items {
      guard case .toolGroup(let group) = item, let frame = render.frames[item.id] else { continue }
      grouped += group.count
      let digest = goldenDigest(group, tools: harness.displayedTools)
      try expect(digest != nil, "the 103-command group must produce a digest")
      try expect(!(digest?.headline.isEmpty ?? true), "the group headline must not be empty")
      try expectEqual(digest?.commandCount, group.count)
      // The regression this fixture exists for: the row reserved
      // `24pt × 103` of `minHeight` and the line itself sat 2 447pt above the
      // next row.
      try expect(frame.height < DSHSpace.s7 * 2,
                 "the collapsed 103-command row must stay one line, got \(frame.height)pt")
      try expect(goldenInk(render, frame) > 40, "the command line painted nothing")
    }
    try expectEqual(grouped, toolCalls)

    // Perceived spacing, not row-frame spacing: two rows can be 16pt apart and
    // still show 50pt of blank if one of them reserves invisible height (a
    // full-width `opacity(0)` feedback strip does exactly that). Measure the
    // distance between consecutive runs of INK.
    let bands = goldenInkBands(render)
    try expect(bands.largestGap <= 24,
               "\(bands.largestGap)pt of visible blank between two runs of content"
                 + " (normal row spacing is \(DSHSpace.s4)); gaps: \(bands.gaps)")
    try expect(render.documentHeight < 2_600,
               "the whole turn must stay under 2 600pt, got \(render.documentHeight)pt")
    // The document must END at its content: the snapshot canvas is deliberately
    // taller than the transcript, so the trailing distance is only correct if
    // the last ink sits within the design's bottom inset of the document.
    try expect(render.documentHeight - bands.lastBottom <= DSHSpace.s6 + 8,
               "\(render.documentHeight - bands.lastBottom)pt of blank under the last row"
                 + " (bottom inset is \(DSHSpace.s6))")
    try writeGoldenSnapshot(render, name: "turn1-command-heavy")
    try writeGoldenCrop(render, name: "turn1-middle", top: 1_450, height: 560)
  }
}

/// ⑤ The rating strip: one anchor, never on a running turn, never reflowing,
/// never on top of the text.
///
/// Three bugs lived here. `opacity(0)` reserved ~34pt under EVERY answer (the
/// 2026-10-28 50pt blank); mounting the bar on hover made each row grow and
/// shrink as the pointer swept across it during a trackpad scroll; and painting
/// it as a floating overlay parked it on top of the hovered line's own text.
/// The rule now: a real strip row, on the last assistant reply of a FINISHED
/// turn only, plus the history case (a middle row the reader already rated).
private func testGolden_feedbackStripHasOneStableAnchor() throws {
  try MainActor.assumeIsolated {
    let fixture = try goldenFixture("session-84f7c0cb-turn1")
    let (harness, _) = goldenHarness(fixture.records)
    let render = goldenRender(harness)

    // ⑴ A finished turn anchors exactly one row: its last assistant reply.
    let lastAssistant = render.items.last { item in
      if case .message(let message) = item { return message.role == .assistant }
      return false
    }
    guard let lastAssistant,
          case .message(let anchorMessage) = lastAssistant,
          let anchorID = anchorMessage.hostMessageId else {
      throw TestFailure.message("the fixture must end with an assistant reply")
    }
    try expectEqual(
      ConversationView.feedbackAnchorID(render.items, running: false),
      lastAssistant.id)
    try expect(!anchorID.isEmpty)

    // ⑵ A running turn anchors NOTHING — otherwise the strip hops from row to
    // row as steps land, moving two rows' heights per step.
    try expectEqual(ConversationView.feedbackAnchorID(render.items, running: true), nil)

    // ⑶ The strip sits BELOW the anchor's text, not on top of it. If it shared
    // a scan line with a glyph, the reader would see the capsule covering the
    // last words of the reply (the reported "…shell:" bug).
    let bands = goldenRowBands(render, rowID: lastAssistant.id)
    try expect(bands.count >= 2,
               "the anchor row must render text plus a strip, got \(bands.count) ink runs")
    let textBand = bands[bands.count - 2]
    let stripBand = bands[bands.count - 1]
    try expect(stripBand.top - textBand.bottom >= 2,
               "the rating strip overlaps the reply text: text ends at \(textBand.bottom),"
                 + " strip starts at \(stripBand.top)")
    // The strip is a compact line, not a block.
    try expect(stripBand.bottom - stripBand.top <= 24,
               "the strip must stay one line, got \(stripBand.bottom - stripBand.top)pt")

    // ⑷ Only the anchor carries it. Asked of the view's own rule
    // (`MessageBubble.feedbackMessageID`) rather than guessed from pixels: a
    // text line and a strip are the same height, so shape cannot tell them
    // apart. `rows(...)` here is the model-side mirror, kept next to the rule.
    try expectEqual(
      goldenStripRows(render.items, running: false, ratings: [:]),
      [lastAssistant.id])
    try expectEqual(
      goldenStripRows(render.items, running: true, ratings: [:]),
      [])
    // A rated middle row keeps its strip even though it is not the anchor.
    let middle = render.items.compactMap { item -> (String, String)? in
      guard case .message(let message) = item, message.role == .assistant,
            let id = message.hostMessageId, item.id != lastAssistant.id else { return nil }
      return (item.id, id)
    }.dropFirst().first
    if let (middleRow, middleMessageID) = middle {
      try expectEqual(
        goldenStripRows(
          render.items, running: false, ratings: [middleMessageID: "positive"]),
        [lastAssistant.id, middleRow])
      // …and a running turn still hides the anchor even when something is rated.
      try expectEqual(
        goldenStripRows(
          render.items, running: true, ratings: [middleMessageID: "positive"]),
        [middleRow])
    }

    // ⑸ Rating a message must not reflow anything: the anchor already shows the
    // strip, so filling a thumb only repaints two glyphs. (Hover has no layout
    // input at all any more — there is no hover state left to vary.)
    harness.messageFeedback[anchorID] = DSHMessageFeedbackItem(
      messageId: anchorID, rating: "positive", note: nil,
      version: "v1", createdAt: 0, updatedAt: 0)
    let rated = goldenRender(harness)
    try expect(abs(rated.documentHeight - render.documentHeight) < 0.5,
               "rating a message moved the document by"
                 + " \(rated.documentHeight - render.documentHeight)pt")
    for item in render.items {
      guard let old = render.frames[item.id], let new = rated.frames[item.id] else {
        throw TestFailure.message("row \(item.id) lost its frame after rating")
      }
      try expect(abs(new.minY - old.minY) < 0.5 && abs(new.height - old.height) < 0.5,
                 "rating reflowed \(item.id): y \(old.minY)→\(new.minY),"
                   + " h \(old.height)→\(new.height)")
    }
    try expect(goldenChangedPixels(render, rated) > 20,
               "the thumb did not repaint: the rating was not visible")

    // Snapshots: the finished tail with its strip, and turn1's middle again.
    try writeGoldenSnapshot(render, name: "turn1-command-heavy")
    try writeGoldenCrop(render, name: "turn1-middle", top: 1_450, height: 560)
    let tailTop = max(0, (render.frames[lastAssistant.id]?.minY ?? 0) - 60)
    try writeGoldenCrop(render, name: "turn1-tail-feedback", top: tailTop, height: 200)
  }
}

/// Which rows render a rating strip, computed through the SAME rule the view
/// uses (`MessageBubble.feedbackMessageID`) — the anchor of a finished turn,
/// plus anything already rated. Nothing here duplicates that predicate.
@MainActor private func goldenStripRows(
  _ items: [ConversationView.TranscriptItem],
  running: Bool,
  ratings: [String: String]
) -> Set<String> {
  let anchor = ConversationView.feedbackAnchorID(items, running: running)
  var rows: Set<String> = []
  for item in items {
    guard case .message(let message) = item, message.role == .assistant else { continue }
    let id = MessageBubble.stripMessageID(
      hostMessageID: message.hostMessageId,
      isAnchor: item.id == anchor,
      rated: message.hostMessageId.flatMap { ratings[$0] } != nil)
    if id != nil { rows.insert(item.id) }
  }
  return rows
}

/// Ink runs inside one row, in points. Used to prove the strip sits under the
/// text instead of on top of it.
@MainActor private func goldenRowBands(
  _ render: DSHGoldenRender,
  rowID: String
) -> [(top: CGFloat, bottom: CGFloat)] {
  guard let frame = render.frames[rowID] else { return [] }
  let image = render.image
  let scale = CGFloat(image.pixelsWide) / max(1, image.size.width)
  guard let background = image.colorAt(x: 1, y: 1) else { return [] }
  func isContent(_ colour: NSColor) -> Bool {
    abs(colour.redComponent - background.redComponent) > 0.012
      || abs(colour.greenComponent - background.greenComponent) > 0.012
      || abs(colour.blueComponent - background.blueComponent) > 0.012
  }
  var runs: [(CGFloat, CGFloat)] = []
  var start = -1
  var last = -1
  func close() {
    if start >= 0 { runs.append((CGFloat(start) / scale, CGFloat(last) / scale)) }
    start = -1
  }
  let y0 = max(0, Int(frame.minY * scale))
  let y1 = min(image.pixelsHigh, Int(frame.maxY * scale))
  guard y1 > y0 else { return [] }
  for y in y0..<y1 {
    var count = 0
    for x in stride(from: 0, to: image.pixelsWide, by: 3) {
      guard let colour = image.colorAt(x: x, y: y) else { continue }
      if isContent(colour) { count += 1 }
    }
    if count > 3 {
      if start < 0 { start = y }
      last = y
    } else {
      close()
    }
  }
  close()
  return runs
}

/// Counts pixels that changed between two renders of the same transcript.
/// Used to prove the hover overlay actually painted while no row moved.
@MainActor private func goldenChangedPixels(
  _ plain: DSHGoldenRender,
  _ hovered: DSHGoldenRender
) -> Int {
  let a = plain.image, b = hovered.image
  guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return -1 }
  var changed = 0
  for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
    for x in stride(from: 0, to: a.pixelsWide, by: 3) {
      guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
      if abs(p.brightnessComponent - q.brightnessComponent) > 0.02 { changed += 1 }
    }
  }
  return changed
}

/// ② The interrupted turn from the previous fix: the command group sits
/// directly above 「本轮已中断」 with one row spacing between them.
private func testGolden_interruptedTurnStaysTight() throws {
  try MainActor.assumeIsolated {
    let fixture = try goldenFixture("session-c19df847-turn19")
    let (harness, folded) = goldenHarness(fixture.records)
    let toolCalls = folded.messages.filter { $0.role == .tool }.count
    let render = goldenRender(harness, height: 1_500)
    try expectEqual(toolCalls, 6)

    guard let groupIndex = render.items.firstIndex(where: {
      if case .toolGroup = $0 { return true }
      return false
    }), let noteIndex = render.items.firstIndex(where: {
      if case .message(let message) = $0 { return message.text == "本轮已中断" }
      return false
    }) else {
      throw TestFailure.message("the fixture must fold into a group plus 本轮已中断")
    }
    try expectEqual(noteIndex, groupIndex + 1)
    guard let groupFrame = render.frames[render.items[groupIndex].id],
          let noteFrame = render.frames[render.items[noteIndex].id] else {
      throw TestFailure.message("missing frames for the group or 本轮已中断")
    }
    let gap = noteFrame.minY - groupFrame.maxY
    try expect(abs(gap - DSHSpace.s4) < 0.5,
               "gap under the command group must be one row spacing, got \(gap)pt")
    try expectEqual(render.items.count, 5)
    try writeGoldenSnapshot(render, name: "turn19-interrupted")
  }
}

/// ③ A turn with 139k characters of reasoning: the collapsed trace row is one
/// line, and the rows under it keep normal spacing.
private func testGolden_longReasoningRowCollapses() throws {
  try MainActor.assumeIsolated {
    let fixture = try goldenFixture("session-c19df847-turn15-long-reasoning")
    let (harness, _) = goldenHarness(fixture.records)
    let render = goldenRender(harness, height: 2_400)
    guard let trace = render.items.first(where: {
      if case .reasoning = $0 { return true }
      return false
    }) else {
      throw TestFailure.message("the fixture must fold into a reasoning row")
    }
    guard let frame = render.frames[trace.id] else {
      throw TestFailure.message("the reasoning row produced no frame")
    }
    try expect(frame.height <= 30,
               "a collapsed 139k-char trace must stay one line, got \(frame.height)pt")
    try expect(goldenInk(render, frame) > 40, "the collapsed trace row painted nothing")
    try writeGoldenSnapshot(render, name: "turn15-long-reasoning")
  }
}

/// ④ Live growth. Every event of a real turn is delivered through
/// `consumeMuxFrame`, and after each one the folded group count and the newest
/// command title must match the events delivered so far — never an older frame.
private func testGolden_liveGrowthTracksEveryEvent() throws {
  try MainActor.assumeIsolated {
    let fixture = try goldenFixture("session-84f7c0cb-turn2-live")
    let (harness, _) = goldenHarness([], running: true)

    var frames: [String: CGRect] = [:]
    var documentHeight: CGFloat = 0
    let root = AnyView(
      DSHGoldenProbe(onFrames: { frames = $0 }, onHeight: { documentHeight = $0 })
        .frame(width: 900, height: 1_000)
        .background(DSHTheme.canvas)
        .environmentObject(harness))
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 1_000)
    let window = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 1_000),
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
    runLoopFor(0.4)
    DSHTranscriptPerf.forceRowFrames = true
    defer { DSHTranscriptPerf.forceRowFrames = false }

    var midSnapshot: DSHGoldenRender?
    var seenCounts: [Int] = []
    for (index, entry) in fixture.records.enumerated() {
      harness.consumeMuxFrame([
        "type": "session/event",
        "sessionId": "session-golden",
        "event": goldenEventDictionary(entry.event),
      ])
      DSHTranscriptPerf.renderedGroupTitle = nil
      runLoopFor(0.12)
      hosting.layoutSubtreeIfNeeded()
      let renderedGroupTitle = DSHTranscriptPerf.renderedGroupTitle

      let messages = harness.displayedSession?.messages ?? []
      let items = ConversationView.foldTranscript(messages, activeTurnRunning: true)
      guard let groupItem = items.last(where: {
        if case .toolGroup = $0 { return true }
        return false
      }) else { continue }
      guard case .toolGroup(let group) = groupItem else { continue }
      guard let digest = goldenDigest(group, tools: harness.displayedTools) else {
        throw TestFailure.message("live step \(index): group has no digest")
      }
      // The fold is the source of truth; the rendered line must agree with it
      // on this very frame, not on an earlier one.
      try expectEqual(digest.commandCount, group.count)
      // The evidence must come from the RENDERED side. `digest.runningTitle`
      // is computed from the same model the fold is, so comparing it with
      // itself proves nothing about whether the view repainted. The old form
      // here also ended in `|| digest.headline.contains(count)`, which is
      // always true — the assertion could not fail, even with `==` frozen.
      let expectedTitle = group.last.flatMap { message in
        message.toolCallId.flatMap { id in harness.displayedTools.last { $0.callId == id } }
      }.flatMap { DSHToolGroupStatus.instructionTitle(for: $0) }
      // Only a RUNNING group prints a command title (the settled line is just
      // 「执行了 N 条命令」), so assert exactly while the digest says it is live.
      if digest.isRunning, let expectedTitle {
        guard let rendered = renderedGroupTitle else {
          throw TestFailure.message("live step \(index): the group row never composed a title")
        }
        try expect(rendered.contains(expectedTitle),
                   "live step \(index): the row still shows \"\(rendered)\""
                     + " but the newest command is \"\(expectedTitle)\"")
      }
      if let frame = frames[groupItem.id] {
        try expect(frame.height > 0, "live step \(index): the command row has no height")
        try expect(frame.height < DSHSpace.s7 * 2,
                   "live step \(index): the command row grew to \(frame.height)pt")
      }
      seenCounts.append(digest.commandCount)
      if index == fixture.records.count / 2 {
        let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        midSnapshot = DSHGoldenRender(
          frames: frames, documentHeight: documentHeight,
          items: items, image: image)
      }
    }

    // The counts must be monotone non-decreasing and end at the number of
    // commands the fixture actually delivered.
    let commands = fixture.records.filter { $0.event.type == "tool/call" }.count
    try expectEqual(seenCounts.last, commands)
    for (previous, next) in zip(seenCounts, seenCounts.dropFirst()) {
      try expect(next >= previous, "the live command count went backwards")
    }
    if let midSnapshot {
      try writeGoldenSnapshot(midSnapshot, name: "turn2-live-mid")
    }
    guard let finalItem = ConversationView
      .foldTranscript(harness.displayedSession?.messages ?? [], activeTurnRunning: true)
      .last(where: { if case .toolGroup = $0 { return true }; return false }),
      let finalFrame = frames[finalItem.id] else {
      throw TestFailure.message("the live sequence produced no command row")
    }
    try expect(finalFrame.maxY > 0, "the live command row ended up above the viewport")
  }
}

/// `DSHJSONValue` → the `[String: Any]` a mux frame carries.
private func goldenEventDictionary(_ event: DSHRawEvent) -> [String: Any] {
  var dictionary: [String: Any] = ["type": event.type, "seq": event.seq, "time": event.time]
  dictionary["data"] = goldenPlainValue(event.data)
  return dictionary
}

private func goldenPlainValue(_ value: DSHJSONValue) -> Any {
  switch value {
  case .string(let text): return text
  case .number(let number): return number
  case .bool(let flag): return flag
  case .null: return NSNull()
  case .array(let values): return values.map(goldenPlainValue)
  case .object(let values): return values.mapValues(goldenPlainValue)
  }
}

/// Writes the PNG an operator is expected to look at. `DSH_GOLDEN_OUT` points
/// somewhere writable; without it the snapshots land in the temp directory.
@MainActor private func writeGoldenSnapshot(_ render: DSHGoldenRender, name: String) throws {
  let directory = goldenOutputDirectory()
  // Crop to the DOCUMENT height. The canvas is deliberately taller than the
  // content (it stands in for a scroll viewport), so writing it whole adds
  // thousands of points of empty canvas that read as "空白 at the bottom of the
  // transcript". The trailing-blank assertion covers the document itself.
  let image = render.image
  let scale = CGFloat(image.pixelsWide) / max(1, image.size.width)
  let contentHeight = min(CGFloat(image.pixelsHigh), max(1, render.documentHeight) * scale)
  let output: NSBitmapImageRep
  if contentHeight + 1 < CGFloat(image.pixelsHigh), let full = image.cgImage,
     let slice = full.cropping(to: CGRect(
       x: 0, y: 0, width: image.pixelsWide, height: Int(contentHeight))) {
    output = NSBitmapImageRep(cgImage: slice)
  } else {
    output = image
  }
  guard let data = output.representation(using: .png, properties: [:]) else {
    throw TestFailure.message("could not encode the \(name) snapshot")
  }
  try data.write(to: directory.appendingPathComponent("\(name).png"))
  print(String(format: "  golden %@ → %@ (doc %.0fpt, canvas cropped to content)",
               name, directory.path, render.documentHeight))
}

/// Writes a vertical slice of the render, in points, so one region can be
/// reviewed without scrolling a 5 200pt canvas.
@MainActor private func writeGoldenCrop(
  _ render: DSHGoldenRender,
  name: String,
  top: CGFloat,
  height: CGFloat
) throws {
  let image = render.image
  let scale = CGFloat(image.pixelsWide) / max(1, image.size.width)
  let y0 = max(0, Int(top * scale))
  let y1 = min(image.pixelsHigh, Int((top + height) * scale))
  guard y1 > y0, let full = image.cgImage,
        let crop = full.cropping(to: CGRect(
          x: 0, y: y0, width: image.pixelsWide, height: y1 - y0)) else {
    throw TestFailure.message("could not crop \(name)")
  }
  let rep = NSBitmapImageRep(cgImage: crop)
  guard let data = rep.representation(using: .png, properties: [:]) else {
    throw TestFailure.message("could not encode the \(name) crop")
  }
  try data.write(to: goldenOutputDirectory().appendingPathComponent("\(name).png"))
  print(String(format: "  golden %@ → crop y=%.0f..%.0f", name, top, top + height))
}

private func goldenOutputDirectory() -> URL {
  let directory = ProcessInfo.processInfo.environment["DSH_GOLDEN_OUT"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("dsh-golden", isDirectory: true)
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

let dshTranscriptGoldenTests: [NamedTest] = [
  ("Golden: command-heavy real turn stays compact",
   testGolden_commandHeavyTurnIsCompact),
  ("Golden: interrupted turn keeps one row spacing",
   testGolden_interruptedTurnStaysTight),
  ("Golden: long reasoning row collapses",
   testGolden_longReasoningRowCollapses),
  ("Golden: live growth tracks every event",
   testGolden_liveGrowthTracksEveryEvent),
  ("Golden: rating strip has one stable anchor",
   testGolden_feedbackStripHasOneStableAnchor),
]
