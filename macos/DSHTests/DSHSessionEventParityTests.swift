import Foundation
@testable import DSHAppLib

private let rootID = "session-parity"
private let childID = "child-parity"

@MainActor
private func runRoot() -> (harness: HarnessController, trace: [String]) {
  let harness = HarnessController(startRuntime: false)
  let session = HarnessController.Session(
    title: "parity",
    workspaceName: "test",
    updatedAt: Date(),
    messages: [],
    hostSessionId: rootID)
  harness.sessions = [session]
  harness.selectedSessionID = session.id
  harness.hostCurrentSessionID = rootID
  var trace: [String] = []
  var previous: String?
  for item in dshParitySteps {
    harness.deliverFrame(dshFrame(item, sessionID: rootID))
    let state = "running=\(harness.isRunning)/\(harness.sessions[0].isRunning) notice=\(harness.runNotice ?? "-") retry=\(harness.retryNotice ?? "-")"
    if state != previous { trace.append("\(item.event["seq"] as? Int ?? -1) \(state)") }
    previous = state
  }
  return (harness, trace)
}

/// When `displayed` is false another child is on screen, so its transcript
/// shows whether the hidden child's events leaked into it.
@MainActor
private func runSubagent(displayed: Bool) -> HarnessController {
  let harness = HarnessController(startRuntime: false)
  harness.seedSubagentPresentation(sessionID: childID, tools: [], projections: nil)
  let address = DSHSubagentAddress(parentSessionId: rootID, childSessionId: childID, mode: "continuable")
  harness.activeSubagentAddress = displayed
    ? address
    : DSHSubagentAddress(parentSessionId: rootID, childSessionId: "other-child", mode: "continuable")
  harness.subagentTranscript = HarnessController.Session(
    title: "child",
    workspaceName: "子代理",
    updatedAt: Date(),
    messages: displayed ? [] : [DSHMessage(role: .system, text: "other child")])
  for item in dshParitySteps {
    harness.deliverFrame(dshFrame(item, sessionID: childID))
  }
  harness.activeSubagentAddress = address
  return harness
}

private func testRootSurface_rendersWhatTheTimelineProduces() throws {
  try MainActor.assumeIsolated {
    let core = try dshRunCoreLive()
    let (harness, trace) = runRoot()
    try expectEqual(dshRows(harness.sessions[0].messages), dshRows(core.messages))
    try expectEqual(dshToolRows(harness.activeTools), dshToolRows(core.tools))
    try expectEqual(trace, [
      "1 running=true/true notice=- retry=-",
      "17 running=true/true notice=正在压缩历史上下文… retry=-",
      "18 running=true/true notice=上下文摘要：condensed retry=-",
      "19 running=true/true notice=历史上下文压缩完成 retry=-",
      "28 running=true/true notice=历史上下文压缩完成 retry=relay 请求失败，正在第 2 次重试（等待 500ms）",
      "29 running=true/true notice=历史上下文压缩完成 retry=-",
      "34 running=false/false notice=本轮执行失败 retry=-",
      "35 running=true/true notice=- retry=-",
      "37 running=false/false notice=本轮已中断 retry=-",
      "38 running=true/true notice=- retry=-",
      "39 running=false/false notice=本轮达到最大输出 token 限制 retry=-",
      "40 running=true/true notice=- retry=-",
    ])
    try expectEqual(harness.todos.map(\.content), ["one", "two"])
    try expect(harness.hostPlanActive)
    try expectEqual(harness.workflows.map { "\($0.id) \($0.status)" }, ["w1 completed"])
    try expect(harness.sessions[0].turnStartedAt != nil)
  }
}

private func testDisplayedSubagent_rendersTheSameRowsAsRoot() throws {
  try MainActor.assumeIsolated {
    let core = try dshRunCoreLive()
    let harness = runSubagent(displayed: true)
    try expectEqual(dshRows(harness.subagentTranscript?.messages ?? []), dshRows(core.messages))
    try expectEqual(dshToolRows(harness.displayedTools), dshToolRows(core.tools))
    try expectEqual(harness.displayedTodos.map(\.content), ["one", "two"])
    try expect(harness.subagentTranscript?.isRunning == true)
    try expect(!harness.isRunning, "a child's turn must not touch the root flag")
  }
}

private func testHiddenSubagent_tracksToolsWithoutTouchingTheOpenChild() throws {
  try MainActor.assumeIsolated {
    let core = try dshRunCoreLive()
    let harness = runSubagent(displayed: false)
    try expectEqual(harness.subagentTranscript?.messages.map(\.text) ?? [], ["other child"])
    try expectEqual(dshToolRows(harness.displayedTools), dshToolRows(core.tools))
    try expect(harness.subagentTranscript?.isRunning == false)
  }
}

private func testChildFollowFrame_keepsToolCards() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.seedSubagentPresentation(sessionID: childID, tools: [], projections: nil)
    harness.activeSubagentAddress = DSHSubagentAddress(parentSessionId: rootID, childSessionId: childID, mode: "continuable")
    harness.consumeSubagentFollowFrame([
      "type": "event",
      "event": ["type": "tool/call", "seq": 1, "time": 1, "data": ["callId": "c", "name": "read"]],
      "view": ["view": ["card": "read", "title": "a"]],
    ], sessionID: childID)
    try expectEqual(harness.displayedTools.first?.presentation?.card, "read")
  }
}

/// Numbers in a real frame decode to `Double`. The old live path handed them to
/// `as? Int`, so workflow members and retry counts vanished in production while
/// tests that wrote Swift `Int` literals still passed.
private func testLiveEvents_readNumbersDecodedFromJSON() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "numbers",
      workspaceName: "test",
      updatedAt: Date(),
      messages: [],
      hostSessionId: rootID)
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = rootID

    let wire = """
    {"type":"event","event":{"type":"%@","seq":%d,"time":1000,"data":%@}}
    """
    @MainActor func deliver(_ type: String, _ seq: Int, _ data: String) throws {
      let body = String(format: wire, type, seq, data)
      let frame = try JSONDecoder().decode(DSHSessionWireEventFrame.self, from: Data(body.utf8))
      harness.consumeSessionEvent(frame.event, view: frame.view, sessionID: rootID)
    }
    try deliver("tool-workflow/run-start", 1, #"{"runId":"w1","name":"flow"}"#)
    try deliver("tool-workflow/agent-start", 2, #"{"runId":"w1","seq":7,"label":"first","childId":"c"}"#)
    try deliver("tool-workflow/agent-end", 3, #"{"runId":"w1","seq":7,"outcome":"completed"}"#)
    try deliver("llm/retry", 4, #"{"retry":3,"delayMs":250,"provider":"relay"}"#)

    try expectEqual(harness.workflows.first?.members.map(\.id), [7])
    try expectEqual(harness.workflows.first?.members.first?.outcome, "completed")
    try expectEqual(harness.retryNotice, "relay 请求失败，正在第 3 次重试（等待 250ms）")
  }
}

private func testLiveToolCalls_withoutIDsStayDistinct() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "ids",
      workspaceName: "test",
      updatedAt: Date(),
      messages: [],
      hostSessionId: rootID)
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = rootID
    for seq in [12, 12] {
      harness.deliverFrame(dshFrame(dshStep("tool/call", seq, ["name": "bash"]), sessionID: rootID))
    }
    try expectEqual(Set(harness.activeTools.map(\.callId)).count, 2)
  }
}

let dshSessionEventParityTests: [NamedTest] = [
  ("Root surface renders what the timeline produces", testRootSurface_rendersWhatTheTimelineProduces),
  ("Displayed subagent renders the same rows as root", testDisplayedSubagent_rendersTheSameRowsAsRoot),
  ("Hidden subagent tracks tools without touching the open child", testHiddenSubagent_tracksToolsWithoutTouchingTheOpenChild),
  ("Child follow frames keep tool cards", testChildFollowFrame_keepsToolCards),
  ("Live events read numbers decoded from JSON", testLiveEvents_readNumbersDecodedFromJSON),
  ("Live tool calls without ids stay distinct", testLiveToolCalls_withoutIDsStayDistinct),
]
