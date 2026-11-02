import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

// MARK: - Card state (pure)
//
// The card is the only surface that knows whether a child session exists yet,
// so its state must be derivable from the three things the app has: the
// approval, the tool result, and the catalogue's `running` flag for that child.

private func cardStatus(approvalPending: Bool) -> DSHChildSessionCardStatus {
  DSHChildSessionCard.status(DSHChildSessionCardInputs(approvalPending: approvalPending))
}

private func testChildCard_statusFromApprovalResultAndCatalog() throws {
  // Waiting for the user: nothing else matters yet.
  try expectEqual(cardStatus(approvalPending: true), .confirming)
  try expect(
    DSHChildSessionCard.status(DSHChildSessionCardInputs(
      approvalPending: true, childSessionId: "child-1", childRunning: true)) == .confirming,
    "an unanswered approval outranks a stale result for the same call")

  // Approved, the tool call is still running: no child id yet.
  try expectEqual(cardStatus(approvalPending: false), .running)

  // The result names the child, which is still working.
  try expectEqual(
    DSHChildSessionCard.status(DSHChildSessionCardInputs(
      childSessionId: "child-1", childRunning: true)),
    .running)
  // ... and once it stops, finished.
  try expectEqual(
    DSHChildSessionCard.status(DSHChildSessionCardInputs(
      childSessionId: "child-1", childRunning: false)),
    .finished)
  // A catalogue that has not caught up yet keeps the running row rather than
  // claiming a session that may not be in the list finished.
  try expectEqual(
    DSHChildSessionCard.status(DSHChildSessionCardInputs(childSessionId: "child-1")),
    .running)

  // The user chose to stay here.
  try expectEqual(
    DSHChildSessionCard.status(DSHChildSessionCardInputs(decision: .declined)),
    .declined)
  // A failed call is never a running child.
  try expectEqual(
    DSHChildSessionCard.status(DSHChildSessionCardInputs(
      decision: .allowed, resultFailed: true)),
    .declined)
}

private func testChildCard_readsChildIDAndTitleFromTheCall() throws {
  try expectEqual(
    DSHChildSessionCard.childSessionId(fromResult: "started subagent child-42"),
    "child-42")
  try expectEqual(DSHChildSessionCard.childSessionId(fromResult: "started subagent "), nil)
  try expectEqual(DSHChildSessionCard.childSessionId(fromResult: "Error: boom"), nil)
  try expectEqual(DSHChildSessionCard.childSessionId(fromResult: nil), nil)

  let arguments = #"{"description":"查文档","prompt":"第一行\n第二行"}"#
  try expectEqual(DSHChildSessionCard.description(arguments: arguments), "查文档")
  try expectEqual(DSHChildSessionCard.title("查文档"), "新会话：查文档")
  // No description: the prompt's first line stands in, so no card is titleless.
  try expectEqual(
    DSHChildSessionCard.description(arguments: #"{"prompt":"整理日志\n细节"}"#),
    "整理日志")
  try expectEqual(DSHChildSessionCard.description(arguments: "{}"), "")
  try expectEqual(DSHChildSessionCard.description(arguments: "not json"), "")
  try expectEqual(DSHChildSessionCard.title("  "), "新会话")

  try expect(DSHChildSessionCard.isChildSessionTool("subagent"))
  try expect(DSHChildSessionCard.isChildSessionTool("subagent_fork"))
  try expect(!DSHChildSessionCard.isChildSessionTool("send_message"))
  try expect(!DSHChildSessionCard.isChildSessionTool("bash"))
}

// MARK: - One state per call
//
// Two child sessions in one turn produce two cards; keying by call id is what
// keeps them from answering (or reporting) each other's approval.

private func testChildCard_keepsParallelCardsApart() throws {
  try MainActor.assumeIsolated {
    let state = DSHChildSessionPromptState()
    let first = HarnessController.PendingApproval(
      id: "approval-1", rpcId: "rpc-1", sessionId: "root",
      toolName: "subagent", reason: "第一件事", callId: "call-1")
    let second = HarnessController.PendingApproval(
      id: "approval-2", rpcId: "rpc-2", sessionId: "root",
      toolName: "subagent_fork", reason: "第二件事", callId: "call-2")
    state.add(.init(callId: "call-1", sessionId: "root", toolName: "subagent",
                    description: "第一件事", prompt: "任务一", approval: first))
    state.add(.init(callId: "call-2", sessionId: "root", toolName: "subagent_fork",
                    description: "第二件事", prompt: "任务二", approval: second))

    try expectEqual(state.request("call-1")?.approval.rpcId, "rpc-1")
    try expectEqual(state.request("call-2")?.approval.rpcId, "rpc-2")
    try expectEqual(state.request("call-3")?.approval.rpcId, nil)

    // Answering one leaves the other pending.
    let taken = state.take("call-1")
    try expectEqual(taken?.approval.id, "approval-1")
    state.record(.declined, for: "call-1")
    try expectEqual(state.decision("call-1"), .declined)
    try expectEqual(state.decision("call-2"), nil)
    try expect(state.request("call-2") != nil, "the second card must still be waiting")
  }
}

private func testChildCard_retractsOnlyTheMatchingApproval() throws {
  try MainActor.assumeIsolated {
    let state = DSHChildSessionPromptState()
    for index in 1...2 {
      state.add(.init(
        callId: "call-\(index)",
        sessionId: "root",
        toolName: "subagent",
        description: "",
        prompt: "",
        approval: .init(
          id: "approval-\(index)", rpcId: "rpc-\(index)", sessionId: "root",
          toolName: "subagent", reason: nil, callId: "call-\(index)")))
    }
    // A Host-side timeout / another client answering retracts exactly one card.
    state.retract(approvalId: "approval-2")
    try expect(state.request("call-1") != nil, "the other card must stay")
    try expect(state.request("call-2") == nil, "the retracted card is gone")
  }
}

// MARK: - Delegation already confirmed by the user
//
// The 新建 entry is a confirmation: the model's later `subagent` call for the
// same task must not be asked about again. Text is matched exactly — a
// reworded task is a different task.

private func testChildCard_delegationMatchesExactTaskOnly() throws {
  try MainActor.assumeIsolated {
    let state = DSHChildSessionPromptState()
    try expect(!state.shouldAutoApprove(sessionId: "root", prompt: "整理日志"),
               "nothing delegated yet")
    state.noteDelegation(sessionId: "root", task: "整理日志")
    try expect(state.shouldAutoApprove(sessionId: "root", prompt: "整理日志"))
    try expect(!state.shouldAutoApprove(sessionId: "root", prompt: "整理日志 "),
               "whitespace makes it a different task")
    try expect(!state.shouldAutoApprove(sessionId: "root", prompt: "整理日志\n附带要求"),
               "an extended task is not the confirmed one")
    try expect(!state.shouldAutoApprove(sessionId: "other", prompt: "整理日志"),
               "another session's delegation must not leak")
    try expect(!state.shouldAutoApprove(sessionId: "root", prompt: ""),
               "an empty prompt never matches")

    // One confirmation covers one call.
    state.clearDelegation(sessionId: "root")
    try expect(!state.shouldAutoApprove(sessionId: "root", prompt: "整理日志"))
  }
}

// MARK: - Two cards in one turn
//
// The transcript folds same-name tool rows into a group; a child-session call
// must never join one, or two delegations collapse into a single card that can
// only carry one approval.

private func testChildCard_transcriptKeepsEachDelegationSeparate() throws {
  try MainActor.assumeIsolated {
    let messages = [
      HarnessController.Message(role: .user, text: "两件事"),
      HarnessController.Message(role: .tool, text: "subagent", toolCallId: "call-1"),
      HarnessController.Message(role: .tool, text: "subagent", toolCallId: "call-2"),
      HarnessController.Message(role: .tool, text: "subagent_fork", toolCallId: "call-3"),
    ]
    let items = ConversationView.foldTranscript(messages)
    let toolRows = items.compactMap { item -> String? in
      guard case .message(let message) = item, message.role == .tool else { return nil }
      return message.toolCallId
    }
    try expectEqual(toolRows, ["call-1", "call-2", "call-3"])
    try expect(!items.contains { item in
      if case .toolGroup = item { return true }
      return false
    }, "a delegation must never fold into a command group")
  }
}

// MARK: - Offscreen snapshots: three states × light and dark

private func testChildCard_snapshots() throws {
  try MainActor.assumeIsolated {
    let output = childCardSnapshotDirectory()
    let names = ["confirming", "running", "finished"].flatMap { state in
      ["child-card-\(state).png", "child-card-\(state)-dark.png"]
    }
    for name in names { try? FileManager.default.removeItem(at: output.appendingPathComponent(name)) }
    defer { NSApp.appearance = NSAppearance(named: .aqua) }

    for (suffix, appearance) in [
      ("", NSAppearance.Name.aqua),
      ("-dark", NSAppearance.Name.darkAqua),
    ] {
      NSApp.appearance = NSAppearance(named: appearance)
      for card in [ChildCardFixture.confirming, .running, .finished] {
        try renderChildCard(
          name: "child-card-\(card.name)\(suffix).png",
          appearance: appearance,
          fixture: card,
          output: output)
      }
    }
    print("child-card-snapshot: \(output.path)")
  }
}

private struct ChildCardFixture {
  let name: String
  let approvalPending: Bool
  let decision: DSHChildSessionDecision?
  let childSessionId: String?
  let childRunning: Bool?
  let toolState: HarnessController.ToolActivity.State
  let output: String

  static let confirming = ChildCardFixture(
    name: "confirming",
    approvalPending: true,
    decision: nil,
    childSessionId: nil,
    childRunning: nil,
    toolState: .running,
    output: "")

  static let running = ChildCardFixture(
    name: "running",
    approvalPending: false,
    decision: .allowed,
    childSessionId: "child-running",
    childRunning: true,
    toolState: .succeeded,
    output: "started subagent child-running")

  static let finished = ChildCardFixture(
    name: "finished",
    approvalPending: false,
    decision: .allowed,
    childSessionId: "child-finished",
    childRunning: false,
    toolState: .succeeded,
    output: "started subagent child-finished")
}

private func childCardSnapshotDirectory() -> URL {
  ProcessInfo.processInfo.environment["DSH_CHILD_CARD_SNAPSHOT_DIR"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? URL(fileURLWithPath: "/tmp/dsh-child-card/out", isDirectory: true)
}

@MainActor
private func renderChildCard(
  name: String,
  appearance: NSAppearance.Name,
  fixture: ChildCardFixture,
  output: URL
) throws {
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  let harness = HarnessController(startRuntime: false)
  let callId = "call-\(fixture.name)"
  let arguments = #"{"description":"整理项目里散落的构建脚本","prompt":"整理构建脚本"}"#

  harness.activeTools = [HarnessController.ToolActivity(
    callId: callId,
    name: "subagent",
    summary: "工具调用",
    state: fixture.toolState,
    output: fixture.output,
    arguments: arguments)]
  if let childSessionId = fixture.childSessionId {
    let updatedAt = Date()
    harness.hostSessions.append(DSHSessionSummary(
      sessionId: childSessionId,
      updatedAt: updatedAt.timeIntervalSince1970 * 1000,
      running: fixture.childRunning ?? false,
      blank: false,
      cwd: "/Users/developer/project",
      agentPreset: nil,
      parentSessionId: "root-session",
      origin: "subagent",
      projections: nil))
  }

  let prompts = harness.childSessionPrompts
  if fixture.approvalPending {
    prompts.add(.init(
      callId: callId,
      sessionId: "root-session",
      toolName: "subagent",
      description: "整理项目里散落的构建脚本",
      prompt: "整理构建脚本",
      approval: .init(
        id: "approval-1", rpcId: "rpc-1", sessionId: "root-session",
        toolName: "subagent", reason: nil, callId: callId)))
  }
  if let decision = fixture.decision { prompts.record(decision, for: callId) }

  let message = HarnessController.Message(role: .tool, text: "subagent", toolCallId: callId)
  let hosting = NSHostingView(rootView: AnyView(
    ChildSessionPromptCard(prompts: prompts, message: message)
      .environmentObject(harness)
      .padding(DSHSpace.s4)
      .frame(width: 560, height: 132, alignment: .topLeading)
      .background(DSHTheme.canvas)))
  hosting.appearance = NSAppearance(named: appearance)
  hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 132)
  let window = NSWindow(
    contentRect: NSRect(x: -20_000, y: -20_000, width: 560, height: 132),
    styleMask: .borderless,
    backing: .buffered,
    defer: false)
  window.isReleasedWhenClosed = false
  window.backgroundColor = .clear
  window.contentView = hosting
  window.orderFrontRegardless()
  RunLoop.main.run(until: Date().addingTimeInterval(0.25))
  hosting.layoutSubtreeIfNeeded()
  hosting.displayIfNeeded()
  guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
    window.close()
    throw TestFailure.message("\(name): no bitmap")
  }
  hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
  window.orderOut(nil)
  window.close()
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    throw TestFailure.message("\(name): cannot encode PNG")
  }
  try expect(png.count > 3_000, "\(name): snapshot looks empty")
  try png.write(to: output.appendingPathComponent(name))
}

let dshChildSessionCardTests: [NamedTest] = [
  ("Child card: state follows approval, result and catalog", testChildCard_statusFromApprovalResultAndCatalog),
  ("Child card: reads the child id and title from the call", testChildCard_readsChildIDAndTitleFromTheCall),
  ("Child card: parallel cards stay keyed by call id", testChildCard_keepsParallelCardsApart),
  ("Child card: a resolved approval retracts only its own card", testChildCard_retractsOnlyTheMatchingApproval),
  ("Child card: delegation matches the exact task only", testChildCard_delegationMatchesExactTaskOnly),
  ("Child card: each delegation keeps its own transcript row", testChildCard_transcriptKeepsEachDelegationSeparate),
  ("Child card: three states in light and dark", testChildCard_snapshots),
]
