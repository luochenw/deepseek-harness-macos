import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

enum ReasoningSnapshotFailure: Error, CustomStringConvertible {
  case invalid(String)

  var description: String {
    switch self { case .invalid(let message): message }
  }
}

/// Contract + snapshot coverage for the transcript's thinking rows.
///
/// A turn emits one reasoning block per step, so the raw transcript stacks a
/// trace around every tool call. Folding must collapse each turn's traces into
/// ONE ✻ row (still expandable to every step) instead of replaying an identical
/// one-liner per step, and the aggregate must not steal the answer row's
/// identity — a duplicate ForEach id silently drops the answer body.
@main
struct ReasoningSnapshotCheck {
  @MainActor
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw ReasoningSnapshotFailure.invalid("usage: reasoning-snapshot-check OUTPUT_DIR")
    }
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    guard DSHConversationLayout.contentMaxWidth == 1_040,
          DSHConversationLayout.horizontalInset == DSHSpace.s6 else {
      throw ReasoningSnapshotFailure.invalid("conversation reading measure drifted")
    }

    let messages = Self.sampleTranscript()
    let items = ConversationView.foldTranscript(messages)

    let reasoning = items.compactMap { item -> ConversationView.ReasoningTrace? in
      if case .reasoning(let trace) = item { return trace }
      return nil
    }
    let bodies = items.compactMap { item -> HarnessController.Message? in
      if case .message(let message) = item { return message }
      return nil
    }
    let groups = items.filter { item in
      if case .toolGroup = item { return true }
      return false
    }

    // One ✻ row per turn — not one per step.
    guard reasoning.count == 2 else {
      throw ReasoningSnapshotFailure.invalid("expected 2 aggregated traces (one per turn), got \(reasoning.count)")
    }
    guard reasoning[0].segments == 3, reasoning[1].segments == 1 else {
      throw ReasoningSnapshotFailure.invalid(
        "expected segment counts 3/1, got \(reasoning[0].segments)/\(reasoning[1].segments)")
    }
    guard reasoning[0].text.contains("步骤1") && reasoning[0].text.contains("步骤3") else {
      throw ReasoningSnapshotFailure.invalid("aggregated trace lost a step's text")
    }
    // Trace-only steps contribute no body row.
    guard bodies.count == 6 else {
      throw ReasoningSnapshotFailure.invalid(
        "expected 6 body rows (2 user + 2 answers + 2 durations), got \(bodies.count)")
    }
    guard bodies.filter({ $0.role == .assistant }).allSatisfy({ $0.reasoning != nil || $0.text.isEmpty == false }) else {
      throw ReasoningSnapshotFailure.invalid("assistant body rows must not be trace placeholders")
    }
    guard groups.count == 1,
          case .toolGroup(let runGroup) = groups[0],
          runGroup.count == 2,
          runGroup.allSatisfy({ $0.text == "run_code" }) else {
      throw ReasoningSnapshotFailure.invalid(
        "expected one expandable group with two run_code rows, got \(groups.count) groups")
    }
    let durations = bodies.filter { $0.text.hasPrefix("本轮用时") }
    guard durations.count == 2 else {
      throw ReasoningSnapshotFailure.invalid("expected one duration row per turn, got \(durations.count)")
    }
    // The aggregate and the answer it precedes share a message id; their row
    // identities must still differ or SwiftUI renders only one of them.
    let ids = items.map(\.id)
    guard Set(ids).count == ids.count else {
      throw ReasoningSnapshotFailure.invalid("folded transcript has duplicate row identities")
    }

    try Self.render(name: "reasoning-wide.png", width: 1100, messages: messages, output: output)
    try Self.render(name: "reasoning-narrow.png", width: 560, messages: messages, output: output)
    try Self.render(
      name: "reasoning-live-status.png",
      width: 1100,
      messages: Self.liveStatusTranscript(),
      output: output,
      running: true)
    try Self.render(
      name: "reasoning-tool-status.png",
      width: 1100,
      messages: Self.liveToolTranscript(),
      output: output,
      running: true,
      tools: [Self.liveRunCodeTool()])
    try Self.render(
      name: "conversation-loading.png",
      width: 560,
      messages: [],
      output: output,
      isLoadingHistory: true)
    print("reasoning-ui: \(output.path)")
  }

  private static func sampleTranscript() -> [HarnessController.Message] {
    var messages: [HarnessController.Message] = []
    messages.append(HarnessController.Message(role: .user, text: "先把这条消息渲染出来。"))
    for step in 1...2 {
      var trace = HarnessController.Message(role: .assistant, text: "")
      trace.reasoning = "步骤\(step) 的思考：先看数据层，再看渲染层的分组逻辑。"
      messages.append(trace)
      messages.append(HarnessController.Message(role: .tool, text: "run_code", toolCallId: "call-\(step)"))
    }
    var answer = HarnessController.Message(
      role: .assistant,
      text: "这一轮的答案正文：思考和正文必须各占一行，正文不能被思考行吞掉。")
    answer.reasoning = "步骤3 的思考：确认 fold 的输出顺序。"
    answer.hostMessageId = "host-message-1"
    messages.append(answer)
    messages.append(HarnessController.Message(role: .system, text: "本轮用时 12.4 秒"))

    messages.append(HarnessController.Message(role: .user, text: "第二条消息，单独一轮。"))
    var second = HarnessController.Message(role: .assistant, text: "第二个答案：只有一步思考。")
    second.reasoning = "单步思考。"
    second.hostMessageId = "host-message-2"
    messages.append(second)
    messages.append(HarnessController.Message(role: .system, text: "本轮用时 3.2 秒"))
    return messages
  }

  private static func liveStatusTranscript() -> [HarnessController.Message] {
    var trace = HarnessController.Message(role: .assistant, text: "")
    trace.reasoning = "检查流式状态栏。\n正在把最新动作写进折叠行。"
    trace.hostMessageId = DSHTranscriptMessageMarker.streamingAssistantHostMessageID
    return [
      HarnessController.Message(role: .user, text: "看看现在的动态状态。"),
      trace,
    ]
  }

  private static func liveToolTranscript() -> [HarnessController.Message] {
    var trace = HarnessController.Message(role: .assistant, text: "")
    trace.reasoning = "先检查页面结构，再执行工作流。"
    trace.hostMessageId = DSHTranscriptMessageMarker.streamingAssistantHostMessageID
    return [
      HarnessController.Message(role: .user, text: "更新流式状态栏。"),
      trace,
      HarnessController.Message(role: .tool, text: "run_code", toolCallId: "live-run-code"),
    ]
  }

  private static func liveRunCodeTool() -> HarnessController.ToolActivity {
    HarnessController.ToolActivity(
      callId: "live-run-code",
      name: "run_code",
      summary: "正在运行",
      state: .running,
      output: "",
      presentation: HarnessController.ToolPresentation.fromToolCall(
        name: "run_code",
        arguments: ["code": "await tools.bash({ command: \"swift test\" })", "description": "运行流式状态测试"]))
  }

  @MainActor
  private static func render(
    name: String,
    width: CGFloat,
    messages: [HarnessController.Message],
    output: URL,
    isLoadingHistory: Bool = false,
    running: Bool = false,
    tools: [HarnessController.ToolActivity] = []
  ) throws {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "思考过程渲染",
      workspaceName: "ds-harness",
      updatedAt: Date(),
      messages: messages,
      isRunning: running,
      isLoadingHistory: isLoadingHistory,
      hostSessionId: "reasoning-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "reasoning-session"
    harness.isRunning = running
    harness.activeTools = tools

    let size = CGSize(width: width, height: 720)
    let root = AnyView(
      ConversationView()
        .frame(width: size.width, height: size.height)
        .background(DSHTheme.canvas)
        .environmentObject(harness))
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
      styleMask: .borderless,
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.backgroundColor = .clear
    window.contentView = hosting
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      window.close()
      throw ReasoningSnapshotFailure.invalid("ConversationView produced no bitmap")
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    window.orderOut(nil)
    window.close()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw ReasoningSnapshotFailure.invalid("ConversationView could not encode PNG")
    }
    guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
      throw ReasoningSnapshotFailure.invalid("\(name) has no pixels")
    }
    try png.write(to: output.appendingPathComponent(name))
    print("reasoning-snapshot: \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
  }
}
