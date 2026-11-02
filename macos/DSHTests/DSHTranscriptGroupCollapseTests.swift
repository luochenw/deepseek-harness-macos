import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

// MARK: - An opened command group must stay open while the reader scrolls
//
// 2026-10-30 report: 「鼠标滚动到最底部的时候，展开的指令也会被折叠」. Scrolling to
// the bottom takes a `ToolGroupRow` out of `LazyVStack`'s window and back; the
// row is MOUNTED AGAIN, and its `@State private var expanded` starts over at
// `initiallyExpanded` (false). Measured on `session-84f7c0cb-turn1`: 99
// `ToolGroupRow.init` calls during one scroll-to-bottom-and-back pass.
// `DSHToolGroupExpansionStore` keeps the choice per transcript row id.

@MainActor
private func fixtureConversation(
  groupCommands: Int,
  tailParagraphs: Int
) -> (HarnessController, String) {
  let harness = HarnessController(startRuntime: false)
  var messages: [HarnessController.Message] = []
  var tools: [HarnessController.ToolActivity] = []
  messages.append(HarnessController.Message(role: .user, text: "请检查这个项目"))
  for index in 0..<groupCommands {
    var message = HarnessController.Message(role: .tool, text: "bash")
    message.toolCallId = "call-\(index)"
    messages.append(message)
    tools.append(HarnessController.ToolActivity(
      callId: "call-\(index)",
      name: "bash",
      summary: "工具调用",
      state: .succeeded,
      output: "ok",
      arguments: #"{"command":"cd project && ls"}"#,
      presentation: nil))
  }
  // Enough prose after the group that it can leave the viewport.
  for index in 0..<tailParagraphs {
    messages.append(HarnessController.Message(
      role: .assistant,
      text: (0..<6).map {
        "后续第 \(index) 段第 \($0) 行说明文字，用来把文档撑高，让命令组滚出视口。"
      }.joined(separator: "\n\n")))
  }
  let session = HarnessController.Session(
    title: "collapse", workspaceName: "w", updatedAt: Date(),
    messages: messages, hostSessionId: "s")
  harness.sessions = [session]
  harness.selectedSessionID = session.id
  harness.hostCurrentSessionID = "s"
  harness.activeTools = tools
  let items = ConversationView.foldTranscript(messages, activeTurnRunning: false)
  return (harness, items.first { if case .toolGroup = $0 { return true }; return false }?.id ?? "?")
}

private func scrollViews(_ view: NSView) -> [NSScrollView] {
  var found: [NSScrollView] = []
  func walk(_ node: NSView) {
    if let scroll = node as? NSScrollView { found.append(scroll) }
    node.subviews.forEach(walk)
  }
  walk(view)
  return found
}

@MainActor
private func pump(_ hosting: NSView, _ turns: Int = 3) {
  for _ in 0..<turns {
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    hosting.layoutSubtreeIfNeeded()
  }
}

@MainActor
private func scrollTo(_ scroll: NSScrollView, _ hosting: NSView, _ y: CGFloat) {
  scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
  scroll.reflectScrolledClipView(scroll.contentView)
  pump(hosting, 2)
}

/// ②b The click path itself: pressing the header opens the group and records the
/// choice, so a remount can resume it.
private func testGroupExpansion_toggleFromTheHeader() throws {
  try MainActor.assumeIsolated {
    let (harness, groupID) = fixtureConversation(groupCommands: 8, tailParagraphs: 0)
    let messages = ConversationView.foldTranscript(
      harness.displayedSession?.messages ?? [], activeTurnRunning: false)
      .compactMap { item -> [HarnessController.Message]? in
        guard case .toolGroup(let group) = item else { return nil }
        return group
      }.first ?? []
    let digest = ConversationView.toolGroupDigest(messages, tools: harness.activeTools)
    let width: CGFloat = 700, height: CGFloat = 700
    var frames: [String: CGRect] = [:]
    let root = AnyView(
      ConversationView()
        .onPreferenceChange(DSHTranscriptRowFrameKey.self) { frames = $0 }
        .frame(width: width, height: height)
        .environmentObject(harness))
    DSHTranscriptPerf.forceRowFrames = true
    defer { DSHTranscriptPerf.forceRowFrames = false }
    DSHToolGroupExpansionStore.setExpanded(false, rowID: groupID)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.close() }
    pump(hosting, 10)
    _ = digest

    guard let scroll = scrollViews(hosting).max(by: {
      ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
    }) else { throw TestFailure.message("no transcript scroll view") }
    scrollTo(scroll, hosting, 0)
    guard let frame = frames[groupID] else {
      throw TestFailure.message("the group row was not laid out (\(frames.count) rows)")
    }
    let collapsed = frame.height
    DSHTranscriptPerf.isEnabled = true
    defer { DSHTranscriptPerf.isEnabled = false }
    DSHTranscriptPerf.groupToggleFlips = 0
    let offset = scroll.contentView.bounds.origin.y
    let point = NSPoint(x: 200, y: height - (frame.minY + frame.height / 2 - offset))
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      if let event = NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1) {
        window.sendEvent(event)
      }
    }
    pump(hosting, 10)
    try expectEqual(DSHTranscriptPerf.groupToggleFlips, 1)
    let opened = frames[groupID]?.height ?? -1
    try expect(opened > collapsed + 100,
               "the header press did not open the group: \(collapsed)pt → \(opened)pt")
    try expectEqual(DSHToolGroupExpansionStore.isExpanded(groupID, default: false), true)
  }
}

/// Two groups in one transcript: opening the second must work while the first
/// stays open (2026-11-01 report: 「只能展开一组指令，再展开第二组就展不开了」).
private func testGroupExpansion_twoGroupsBothOpen() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    var messages: [HarnessController.Message] = [
      HarnessController.Message(role: .user, text: "请检查这个项目"),
    ]
    var tools: [HarnessController.ToolActivity] = []
    for group in 0..<2 {
      for index in 0..<8 {
        var message = HarnessController.Message(role: .tool, text: "bash")
        message.toolCallId = "g\(group)-\(index)"
        messages.append(message)
        tools.append(HarnessController.ToolActivity(
          callId: "g\(group)-\(index)", name: "bash", summary: "工具调用", state: .succeeded,
          output: "ok", arguments: #"{"command":"cd project && ls"}"#, presentation: nil))
      }
      messages.append(HarnessController.Message(role: .assistant, text: "第 \(group) 组结束。"))
      messages.append(HarnessController.Message(role: .user, text: "接着做第 \(group + 1) 件事"))
    }
    let session = HarnessController.Session(
      title: "two", workspaceName: "w", updatedAt: Date(), messages: messages, hostSessionId: "s")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "s"
    harness.activeTools = tools
    let ids = ConversationView.foldTranscript(messages, activeTurnRunning: false).compactMap {
      item -> String? in if case .toolGroup = item { return item.id }; return nil
    }
    try expectEqual(ids.count, 2)
    let width: CGFloat = 700, height: CGFloat = 900
    var frames: [String: CGRect] = [:]
    let hosting = NSHostingView(rootView: AnyView(
      ConversationView()
        .onPreferenceChange(DSHTranscriptRowFrameKey.self) { frames = $0 }
        .frame(width: width, height: height)
        .environmentObject(harness)))
    DSHTranscriptPerf.forceRowFrames = true
    defer { DSHTranscriptPerf.forceRowFrames = false }
    ids.forEach { DSHToolGroupExpansionStore.setExpanded(false, rowID: $0) }
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.close() }
    pump(hosting, 10)
    guard let scroll = scrollViews(hosting).max(by: {
      ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
    }) else { throw TestFailure.message("no transcript scroll view") }
    DSHTranscriptPerf.isEnabled = true
    defer { DSHTranscriptPerf.isEnabled = false }
    for (order, id) in ids.enumerated() {
      guard let frame = frames[id] else { throw TestFailure.message("group \(order) not laid out") }
      let collapsed = frame.height
      let offset = scroll.contentView.bounds.origin.y
      let point = NSPoint(x: 200, y: height - (frame.minY + 14 - offset))
      DSHTranscriptPerf.groupToggleFlips = 0
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil,
          eventNumber: 0, clickCount: 1, pressure: 1) {
          window.sendEvent(event)
        }
      }
      pump(hosting, 10)
      let opened = frames[id]?.height ?? -1
      print("  two-groups: group \(order) flips=\(DSHTranscriptPerf.groupToggleFlips) \(collapsed)pt→\(opened)pt stored=\(DSHToolGroupExpansionStore.isExpanded(id, default: false)) offset=\(offset)")
      try expect(opened > collapsed + 60, "group \(order) did not open: \(collapsed)→\(opened)")
    }
  }
}

/// ② The mechanism, isolated: mounting the row again (what `LazyVStack` does
/// when a row leaves the window) must resume the reader's choice.
private func testGroupExpansion_survivesRemount() throws {
  try MainActor.assumeIsolated {
    let (harness, groupID) = fixtureConversation(groupCommands: 8, tailParagraphs: 0)
    let messages = ConversationView.foldTranscript(
      harness.displayedSession?.messages ?? [], activeTurnRunning: false)
      .compactMap { item -> [HarnessController.Message]? in
        guard case .toolGroup(let group) = item else { return nil }
        return group
      }.first ?? []
    let digest = ConversationView.toolGroupDigest(messages, tools: harness.activeTools)
    let width: CGFloat = 700

    // The reader opens it (this is what the toggle closure records).
    DSHToolGroupExpansionStore.setExpanded(true, rowID: groupID)

    func mountHeight() -> CGFloat {
      let row = AnyView(ToolGroupRow(messages: messages, rowID: groupID, digest: digest)
        .frame(width: width)
        .environmentObject(harness))
      let hosting = NSHostingView(rootView: row)
      hosting.frame = NSRect(x: 0, y: 0, width: width, height: 900)
      let window = NSWindow(
        contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 900),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = hosting
      window.orderFrontRegardless()
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      hosting.layoutSubtreeIfNeeded()
      let height = hosting.fittingSize.height
      window.orderOut(nil)
      window.close()
      return height
    }

    let first = mountHeight()
    let second = mountHeight()
    DSHToolGroupExpansionStore.setExpanded(false, rowID: groupID)
    let closed = mountHeight()
    try expect(first > closed + 100, "the opened row did not render open (\(first)pt)")
    try expectEqual(first, second)
    try expect(second > closed + 100,
               "a remounted row came back collapsed (\(second)pt) even though the reader"
                 + " had opened it (\(closed)pt is the closed height)")
  }
}

let dshTranscriptGroupCollapseTests: [NamedTest] = [
  ("Group expansion opens a second group", testGroupExpansion_twoGroupsBothOpen),
  ("Group expansion toggles from the header and is recorded",
   testGroupExpansion_toggleFromTheHeader),
  ("Group expansion survives a LazyVStack remount",
   testGroupExpansion_survivesRemount),
]
