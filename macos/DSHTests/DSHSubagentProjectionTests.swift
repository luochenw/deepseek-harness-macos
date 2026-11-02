import AppKit
import Foundation
import Network
import SwiftUI
@testable import DSHAppLib

private func projection(
  asOfSeq: Int,
  todos: [DSHTodoItem]? = nil,
  goal: DSHGoalProjection? = nil
) -> DSHSessionProjections {
  DSHSessionProjections(
    asOfSeq: asOfSeq,
    values: DSHSessionProjectionValues(
      title: nil,
      todos: todos,
      plan: nil,
      goal: goal,
      tokenUsage: nil,
      contextPressure: nil,
      sessionStats: nil))
}

private func goalProjection(_ objective: String) -> DSHGoalProjection {
  DSHGoalProjection(
    goal: DSHGoalProjection.Goal(
      id: "goal-\(objective)",
      revision: 1,
      objective: objective,
      phase: "active",
      maxGoalRounds: 4),
    roundsStarted: 1)
}

private func tool(callId: String, name: String, state: HarnessController.ToolActivity.State = .running) -> HarnessController.ToolActivity {
  HarnessController.ToolActivity(
    callId: callId,
    name: name,
    summary: "正在运行",
    state: state,
    output: "",
    presentation: nil)
}

private func nestedToolResult(callId: String, text: String) -> [String: Any] {
  [
    "turn": 1,
    "step": 1,
    "message": [
      "id": "result-\(callId)",
      "role": "user",
      "source": ["kind": "tool", "callId": callId],
      "content": [[
        "type": "tool-result",
        "toolCallId": callId,
        "isError": false,
        "content": [["type": "text", "text": text]],
      ]],
    ],
  ]
}

private func testSubagentPresentation_selectsChildStateWithoutOverwritingRoot() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.activeTools = [tool(callId: "root-tool", name: "bash")]
    harness.todos = [DSHTodoItem(content: "root todo", status: "pending")]
    harness.goal = goalProjection("root goal")

    harness.seedSubagentPresentation(
      sessionID: "child-1",
      tools: [tool(callId: "child-tool", name: "read")],
      projections: projection(
        asOfSeq: 9,
        todos: [DSHTodoItem(content: "child todo", status: "in_progress")],
        goal: goalProjection("child goal")))
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")

    try expectEqual(harness.displayedTools.map(\.callId), ["child-tool"])
    try expectEqual(harness.displayedTodos.map(\.content), ["child todo"])
    try expectEqual(harness.displayedGoal?.goal?.objective, "child goal")
    try expectEqual(harness.displayedGoalSessionID, "child-1")
    try expect(!harness.canMutateDisplayedGoal)

    harness.activeSubagentAddress = nil
    try expectEqual(harness.displayedTools.map(\.callId), ["root-tool"])
    try expectEqual(harness.displayedTodos.map(\.content), ["root todo"])
    try expectEqual(harness.displayedGoal?.goal?.objective, "root goal")
    try expectEqual(harness.displayedGoalSessionID, nil)
  }
}

private func testSubagentPresentation_rejectsOlderProjectionFrame() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.seedSubagentPresentation(
      sessionID: "child-1",
      tools: [],
      projections: projection(asOfSeq: 9))
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")

    harness.applySubagentProjection(
      sessionID: "child-1",
      key: "todos",
      value: [["content": "new todo", "status": "in_progress"]],
      seq: 11)
    harness.applySubagentProjection(
      sessionID: "child-1",
      key: "todos",
      value: [["content": "old todo", "status": "pending"]],
      seq: 10)

    try expectEqual(harness.displayedTodos.map(\.content), ["new todo"])
  }
}

private func testSubagentPresentation_clearsNullTodoAndGoalProjection() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.seedSubagentPresentation(
      sessionID: "child-1",
      tools: [],
      projections: projection(
        asOfSeq: 1,
        todos: [DSHTodoItem(content: "child todo", status: "pending")],
        goal: goalProjection("child goal")))
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")

    harness.applySubagentProjection(sessionID: "child-1", key: "todos", value: NSNull(), seq: 2)
    harness.applySubagentProjection(sessionID: "child-1", key: "goal", value: NSNull(), seq: 2)

    try expect(harness.displayedTodos.isEmpty)
    try expect(harness.displayedGoal == nil)
  }
}

private func testSubagentHistoryBaseline_clearsRawNullTodoAndGoal() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.seedSubagentPresentation(
      sessionID: "child-1",
      tools: [],
      projections: projection(
        asOfSeq: 1,
        todos: [DSHTodoItem(content: "child todo", status: "pending")],
        goal: goalProjection("child goal")))
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")

    let cleared = DSHSessionProjections(
      asOfSeq: 2,
      values: DSHSessionProjectionValues(
        title: nil,
        todos: nil,
        plan: nil,
        goal: nil,
        tokenUsage: nil,
        contextPressure: nil,
        sessionStats: nil),
      rawValues: ["todos": .null, "goal": .null])
    harness.mergeSubagentPresentation(
      sessionID: "child-1",
      tools: [],
      toolSequences: [:],
      projections: cleared)

    try expect(harness.displayedTodos.isEmpty)
    try expect(harness.displayedGoal == nil)
  }
}

private func testSubagentPresentation_historyBaselineDoesNotReplaceNewerLiveProjection() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.seedSubagentPresentation(sessionID: "child-1", tools: [], projections: nil)
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")
    harness.applySubagentProjection(
      sessionID: "child-1",
      key: "todos",
      value: [["content": "live todo", "status": "in_progress"]],
      seq: 12)
    harness.applySubagentProjection(
      sessionID: "child-1",
      key: "goal",
      value: [
        "goal": [
          "id": "live-goal",
          "revision": 2,
          "objective": "live goal",
          "phase": "active",
          "maxGoalRounds": 5,
        ],
        "roundsStarted": 2,
      ],
      seq: 12)

    harness.seedSubagentPresentation(
      sessionID: "child-1",
      tools: [],
      projections: projection(
        asOfSeq: 9,
        todos: [DSHTodoItem(content: "stale history todo", status: "pending")],
        goal: goalProjection("stale history goal")))

    try expectEqual(harness.displayedTodos.map(\.content), ["live todo"])
    try expectEqual(harness.displayedGoal?.goal?.objective, "live goal")
  }
}

private func testSubagentNavigationGenerationRejectsStaleResponse() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let first = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-a",
      mode: "continuable")
    let second = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-b",
      mode: "continuable")

    let firstGeneration = harness.beginSubagentPresentationLoad(address: first)
    let secondGeneration = harness.beginSubagentPresentationLoad(address: second)

    try expect(!harness.acceptsSubagentPresentationLoad(address: first, generation: firstGeneration))
    try expect(harness.acceptsSubagentPresentationLoad(address: second, generation: secondGeneration))
    harness.invalidateSubagentPresentationLoad()
    try expect(!harness.acceptsSubagentPresentationLoad(address: second, generation: secondGeneration))
  }
}

private func testStaleSubagentHistoryActivationDoesNotReplaceNewerSelection() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let first = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-a",
      mode: "continuable")
    let second = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-b",
      mode: "continuable")
    let firstGeneration = harness.beginSubagentPresentationLoad(address: first)
    let secondGeneration = harness.beginSubagentPresentationLoad(address: second)
    let folded = DSHFoldedHistory(
      messages: [],
      tools: [],
      toolSequences: [:],
      activeTurnStartedAt: nil)

    try expect(!harness.activateLoadedSubagentPresentation(
      address: first,
      label: "A",
      running: false,
      generation: firstGeneration,
      folded: folded,
      projections: nil,
      historySequence: -1))
    try expect(harness.activateLoadedSubagentPresentation(
      address: second,
      label: "B",
      running: false,
      generation: secondGeneration,
      folded: folded,
      projections: nil,
      historySequence: -1))
    try expectEqual(harness.activeSubagentAddress?.childSessionId, "child-b")
    try expectEqual(harness.subagentTranscript?.title, "B")
  }
}

private func testDisplayedRunningStateFollowsOpenChildRatherThanRoot() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.isRunning = true
    harness.subagentTranscript = HarnessController.Session(
      title: "子代理",
      workspaceName: "子代理",
      updatedAt: Date(),
      messages: [],
      isRunning: false,
      hostSessionId: "child-1")
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")

    try expect(!harness.displayedIsRunning)
    harness.subagentTranscript?.isRunning = true
    try expect(harness.displayedIsRunning)
  }
}

private func testDisplayedExecutionTarget_selectsRootAndContinuableChild() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "root-1"
    try expectEqual(
      harness.displayedExecutionTarget,
      .root(sessionID: "root-1"))

    let continuable = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")
    harness.activeSubagentAddress = continuable
    try expectEqual(harness.displayedExecutionTarget, .subagent(continuable))

    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-2",
      mode: "one-shot")
    try expectEqual(harness.displayedExecutionTarget, .none)
  }
}

private func testDisplayedStopTarget_interruptsOneShotChild() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "root-1"
    try expectEqual(harness.displayedStopTarget, .root(sessionID: "root-1"))

    let oneShot = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-2",
      mode: "one-shot")
    harness.activeSubagentAddress = oneShot
    try expectEqual(harness.displayedStopTarget, .subagent(oneShot))

    let continuable = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")
    harness.activeSubagentAddress = continuable
    try expectEqual(harness.displayedStopTarget, .subagent(continuable))
  }
}

private func testChildPlanAndQueueFrames_doNotLeakRootState() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostPlanActive = false
    harness.queueItems = [DSHQueueItem(id: "root-queue", placement: "queued", text: "root queue")]
    harness.seedSubagentPresentation(sessionID: "child-1", tools: [], projections: nil)
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")

    harness.consumeSessionControlFrame([
      "type": "projection",
      "sessionId": "child-1",
      "key": "plan",
      "value": ["active": true, "pending": false],
      "seq": 3,
    ])
    harness.consumeSessionControlFrame([
      "type": "projection",
      "sessionId": "child-1",
      "key": "inbox",
      "value": ["next-turn": [[
        "id": "child-queue",
        "content": [["type": "text", "text": "child queue"]],
      ]]],
      "seq": 4,
    ])

    try expect(harness.displayedPlanActive)
    try expectEqual(harness.displayedQueueItems.map(\.id), ["child-queue"])
    try expect(!harness.canMutateDisplayedPlan)
    try expect(!harness.canMutateDisplayedQueue)

    harness.activeSubagentAddress = nil
    try expect(!harness.displayedPlanActive)
    try expectEqual(harness.displayedQueueItems.map(\.id), ["root-queue"])
  }
}

private func testSubagentCatalogGenerationRejectsOldParent() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let rootGeneration = harness.beginSubagentCatalogLoad(parentSessionID: "root-1")
    let childGeneration = harness.beginSubagentCatalogLoad(parentSessionID: "child-1")

    try expect(!harness.acceptsSubagentCatalogLoad(
      parentSessionID: "root-1",
      generation: rootGeneration))
    try expect(harness.acceptsSubagentCatalogLoad(
      parentSessionID: "child-1",
      generation: childGeneration))
  }
}

private func testOneShotSubagentGoal_isReadOnly() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.seedSubagentPresentation(
      sessionID: "child-1",
      tools: [],
      projections: projection(asOfSeq: 1, goal: goalProjection("archived child goal")))
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "one-shot")

    try expectEqual(harness.displayedGoal?.goal?.objective, "archived child goal")
    try expectEqual(harness.displayedGoalSessionID, "child-1")
    try expect(!harness.canMutateDisplayedGoal)
  }
}

private func testLoadingSubagent_replaysOnlyEventsNewerThanHistoryBaseline() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let address = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")
    let generation = harness.beginSubagentPresentationLoad(address: address)

    harness.deliverFrame([
      "type": "session/event",
      "sessionId": "child-1",
      "event": [
        "type": "tool/call",
        "seq": 12,
        "data": [
          "turn": 1,
          "step": 1,
          "callId": "live-tool",
          "name": "read",
          "arguments": "{}",
        ],
      ],
    ])
    harness.deliverFrame([
      "type": "session/event",
      "sessionId": "child-1",
      "event": [
        "type": "todo/write",
        "seq": 13,
        "data": [
          "todos": [["content": "live todo", "status": "completed"]],
        ],
      ],
    ])
    harness.deliverFrame([
      "type": "session/event",
      "sessionId": "child-1",
      "event": [
        "type": "todo/write",
        "seq": 10,
        "data": [
          "todos": [["content": "stale todo", "status": "pending"]],
        ],
      ],
    ])

    let folded = DSHFoldedHistory(
      messages: [HarnessController.Message(role: .system, text: "history")],
      tools: [tool(callId: "history-tool", name: "bash", state: .succeeded)],
      toolSequences: ["history-tool": 11],
      activeTurnStartedAt: nil)
    try expect(harness.activateLoadedSubagentPresentation(
      address: address,
      label: "Child",
      running: false,
      generation: generation,
      folded: folded,
      projections: projection(
        asOfSeq: 11,
        todos: [DSHTodoItem(content: "history todo", status: "pending")]),
      historySequence: 11))

    try expectEqual(
      harness.displayedTools.map(\.callId).sorted(),
      ["history-tool", "live-tool"])
    try expectEqual(harness.displayedTodos.map(\.content), ["live todo"])
  }
}

private func testSubagentHistoryPage_decodesProjectionBaseline() throws {
  let page = try JSONDecoder().decode(DSHHistoryPage.self, from: Data("""
  {
    "events": [],
    "hasMore": false,
    "projections": {
      "asOfSeq": 18,
      "values": {
        "todos": [{"content":"child todo","status":"completed"}],
        "goal": {
          "goal": {
            "id":"goal-child",
            "revision":3,
            "objective":"child objective",
            "phase":"paused",
            "maxGoalRounds":5
          },
          "roundsStarted":2
        }
      }
    }
  }
  """.utf8))

  try expectEqual(page.projections?.asOfSeq, 18)
  try expectEqual(page.projections?.values.todos?.map(\.content), ["child todo"])
  try expectEqual(page.projections?.values.goal?.goal?.objective, "child objective")
}

private func testChildProjectionTodoAndJobFrames_doNotMutateRootState() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.todos = [DSHTodoItem(content: "root todo", status: "pending")]
    harness.activeTools = [tool(callId: "root-tool", name: "bash")]
    harness.seedSubagentPresentation(
      sessionID: "child-1",
      tools: [],
      projections: projection(asOfSeq: 4))
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")

    harness.consumeSessionControlFrame([
      "type": "projection",
      "sessionId": "child-1",
      "key": "todos",
      "value": [["content": "projected child todo", "status": "in_progress"]],
      "seq": 5,
    ])
    harness.deliverFrame([
      "type": "session/event",
      "sessionId": "child-1",
      "event": [
        "type": "todo/write",
        "seq": 6,
        "data": [
          "todos": [["content": "live child todo", "status": "completed"]],
        ],
      ],
    ])
    harness.deliverFrame([
      "type": "session/event",
      "sessionId": "child-1",
      "event": [
        "type": "todo/write",
        "seq": 4,
        "data": [
          "todos": [["content": "stale child todo", "status": "pending"]],
        ],
      ],
    ])
    harness.deliverFrame([
      "type": "session/jobs",
      "sessionId": "child-1",
      "jobs": [[
        "id": "child-job",
        "label": "child background job",
        "status": "completed",
        "detail": "child job settled",
      ]],
    ])

    try expectEqual(harness.displayedTodos.map(\.content), ["live child todo"])
    try expectEqual(harness.displayedTools.map(\.callId), ["child-job"])
    guard case .succeeded = harness.displayedTools.first?.state else {
      throw TestFailure.message("expected child job to settle")
    }
    try expectEqual(harness.todos.map(\.content), ["root todo"])
    try expectEqual(harness.activeTools.map(\.callId), ["root-tool"])
  }
}

private func testLiveChildToolResult_updatesOnlyChildContext() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let rootSession = HarnessController.Session(
      title: "根会话",
      workspaceName: "测试",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-1")
    harness.sessions = [rootSession]
    harness.selectedSessionID = rootSession.id
    harness.hostCurrentSessionID = "root-1"
    harness.activeTools = [tool(callId: "root-tool", name: "bash")]
    harness.subagentTranscript = HarnessController.Session(
      title: "子代理",
      workspaceName: "子代理",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "child-1")
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")
    harness.seedSubagentPresentation(sessionID: "child-1", tools: [], projections: nil)

    harness.deliverFrame([
      "type": "session/event",
      "sessionId": "child-1",
      "event": [
        "type": "tool/call",
        "data": [
          "turn": 1,
          "step": 1,
          "callId": "child-tool",
          "name": "read",
          "arguments": "{}",
        ],
      ],
      "view": [
        "for": "call",
        "view": [
          "card": "read",
          "title": "读取 Child.swift",
        ],
      ],
    ])
    harness.deliverFrame([
      "type": "session/event",
      "sessionId": "child-1",
      "event": [
        "type": "tool/result",
        "data": nestedToolResult(callId: "child-tool", text: "child output"),
      ],
      "view": [
        "for": "result",
        "view": [
          "card": "generic",
          "content": [["type": "text", "text": "child output"]],
        ],
      ],
    ])

    guard let childTool = harness.displayedTools.first(where: { $0.callId == "child-tool" }) else {
      throw TestFailure.message("expected child tool activity")
    }
    guard case .succeeded = childTool.state else {
      throw TestFailure.message("expected child tool result to settle")
    }
    try expectEqual(childTool.output, "child output")
    guard let rootTool = harness.activeTools.first(where: { $0.callId == "root-tool" }) else {
      throw TestFailure.message("expected root tool activity")
    }
    guard case .running = rootTool.state else {
      throw TestFailure.message("child tool result must not settle root tool")
    }
    try expectEqual(harness.subagentTranscript?.messages.last?.toolCallId, "child-tool")
  }
}

private func testChildTurnEnd_settlesOnlyChildTools() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.activeTools = [tool(callId: "root-tool", name: "bash")]
    harness.subagentTranscript = HarnessController.Session(
      title: "子代理",
      workspaceName: "子代理",
      updatedAt: Date(),
      messages: [],
      isRunning: true,
      hostSessionId: "child-1")
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")
    harness.seedSubagentPresentation(
      sessionID: "child-1",
      tools: [tool(callId: "child-tool", name: "read")],
      projections: nil)

    harness.deliverFrame([
      "type": "session/event",
      "sessionId": "child-1",
      "event": [
        "type": "turn/end",
        "seq": 2,
        "data": ["turn": 1, "reason": ["kind": "stop"]],
      ],
    ])

    guard case .succeeded = harness.displayedTools.first?.state else {
      throw TestFailure.message("expected child tool to settle at child turn end")
    }
    guard case .running = harness.activeTools.first?.state else {
      throw TestFailure.message("child turn end must not settle root tool")
    }
    try expect(!harness.displayedIsRunning)
  }
}

private func testChildContext_hidesRootSlashCatalogAndRootOnlySlashCommands() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    try expect(harness.canUseRootSlashCatalog)
    try expect(!HarnessController.isRootOnlySubagentSlashCommand("/review"))
    try expect(HarnessController.isRootOnlySubagentSlashCommand("/goal ship this"))
    try expect(HarnessController.isRootOnlySubagentSlashCommand("/plan off"))

    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable")

    try expect(!harness.canUseRootSlashCatalog)
  }
}

private func testWorkflowMemberNavigationGenerationRejectsStaleCatalog() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let workflowGeneration = harness.beginWorkflowMemberNavigation()
    try expect(harness.acceptsWorkflowMemberNavigation(generation: workflowGeneration))

    _ = harness.beginSubagentPresentationLoad(address: DSHSubagentAddress(
      parentSessionId: "root-1",
      childSessionId: "child-1",
      mode: "continuable"))

    try expect(!harness.acceptsWorkflowMemberNavigation(generation: workflowGeneration))
  }
}

private func testRootHistoryGenerationRejectsStaleOrHiddenResponses() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let first = HarnessController.Session(
      title: "A",
      workspaceName: "测试",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-a")
    let second = HarnessController.Session(
      title: "B",
      workspaceName: "测试",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-b")
    harness.sessions = [first, second]
    harness.selectedSessionID = first.id
    harness.hostCurrentSessionID = "root-a"

    let firstGeneration = harness.beginRootHistoryRequest(localSessionID: first.id)
    let secondGeneration = harness.beginRootHistoryRequest(localSessionID: first.id)
    try expect(!harness.acceptsRootHistoryRequest(
      sessionID: "root-a",
      localSessionID: first.id,
      generation: firstGeneration))
    try expect(harness.acceptsRootHistoryRequest(
      sessionID: "root-a",
      localSessionID: first.id,
      generation: secondGeneration))

    harness.selectedSessionID = second.id
    harness.hostCurrentSessionID = "root-b"
    try expect(!harness.acceptsRootHistoryRequest(
      sessionID: "root-a",
      localSessionID: first.id,
      generation: secondGeneration))

    harness.selectedSessionID = first.id
    harness.hostCurrentSessionID = "root-a"
    let childGeneration = harness.beginRootHistoryRequest(localSessionID: first.id)
    harness.subagentTranscript = HarnessController.Session(
      title: "Child",
      workspaceName: "子代理",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "child-1")
    try expect(!harness.acceptsRootHistoryRequest(
      sessionID: "root-a",
      localSessionID: first.id,
      generation: childGeneration))
  }
}

// MARK: - 新建子会话（dashboard 委派入口）

private func testNewChild_delegationTemplateKeepsTaskVerbatim() throws {
  let task = """
  改一下 `Config` 的默认值，然后把 "read-only" 换成 'workspace-write'。
    - 这一行有缩进
    - 这一行有\t制表符
  最后一行不带标点
  """
  let text = DSHNewChildDelegation.instruction(task: task, label: "配置修复")
  try expect(text.contains(task), "the task must be spliced in unchanged")
  try expect(text.hasSuffix(task), "the task must end the instruction — nothing appended after it")
  try expectEqual(text.components(separatedBy: task).count, 2)
  try expect(text.contains("一个字都不要改"), "the fixed delegation wording is missing")
  try expect(text.contains("【委派】"), "the instruction must be the fixed 【委派】 form")
}

private func testNewChild_delegationModeFollowsRunningState() throws {
  try expectEqual(DSHNewChildDelegation.mode(running: false), .queue)
  try expectEqual(DSHNewChildDelegation.mode(running: true), .steer)
}

private func testNewChild_labelFallsBackWhenBlank() throws {
  let task = "跑一遍测试"
  let untagged = DSHNewChildDelegation.instruction(task: task, label: "   ")
  try expect(untagged.contains("标签：\(DSHNewChildDelegation.emptyTag)"),
             "a blank label must ask the main session to name the child")
  let tagged = DSHNewChildDelegation.instruction(task: task, label: "  冒烟  ")
  try expect(tagged.contains("标签：冒烟），"), "a filled label goes in verbatim, trimmed")
  try expect(!tagged.contains(DSHNewChildDelegation.emptyTag))
}

private func testNewChild_submitRequiresNonBlankTask() throws {
  try expect(!DSHNewChildDelegation.canSubmit(task: ""))
  try expect(!DSHNewChildDelegation.canSubmit(task: " \n\t "))
  try expect(DSHNewChildDelegation.canSubmit(task: "做事"))
}

private func testNewChild_entryOnlyOfferedAtTopLevelSession() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    try expect(!harness.canCreateChildSession,
               "the blank default page has no Host session, so the card must not offer the entry")
    harness.hostCurrentSessionID = "root-session"
    try expect(harness.canCreateChildSession, "a top-level session shows the entry even with no children")
    harness.subagentPath = [
      HarnessController.SubagentNavigationNode(
        address: DSHSubagentAddress(parentSessionId: "root", childSessionId: "child", mode: "continuable"),
        title: "子会话")
    ]
    try expect(!harness.canCreateChildSession, "drilled into a child, the card must not offer a new child")
    harness.subagentPath = []
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root", childSessionId: "child", mode: "continuable")
    try expect(!harness.canCreateChildSession, "a directly addressed child must hide the entry too")
  }
}

private func testNewChild_delegationReportsWhyItSentNothing() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let local = HarnessController.Session(
      title: "主会话",
      workspaceName: "ds-harness",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-session")
    harness.sessions = [local]
    harness.selectedSessionID = local.id
    harness.hostCurrentSessionID = "root-session"
    // No host client: nothing is sent, the caller is told, and the refusal
    // reaches the transcript the user is actually looking at.
    try expect(!harness.delegateNewChildSession(task: "做事", label: ""))
    try expectEqual(harness.status, "Host 未连接，无法委派子会话")
    try expectEqual(harness.sessions[0].messages.last?.text, "Host 未连接，无法委派子会话")

    harness.hostClient = DSHHostClient(baseURL: URL(string: "http://127.0.0.1:0000")!)
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-session", childSessionId: "child", mode: "continuable")
    try expect(!harness.delegateNewChildSession(task: "做事", label: ""))
    try expectEqual(harness.status, "只能在主会话里新建子会话")
    try expectEqual(harness.sessions[0].messages.last?.text, "只能在主会话里新建子会话")

    // A blank task never reaches the Host either.
    harness.activeSubagentAddress = nil
    try expect(!harness.delegateNewChildSession(task: "  \n ", label: ""))
  }
}

private func testNewChild_cardAndPopoverSnapshots() throws {
  try MainActor.assumeIsolated {
    _ = NSApplication.shared
    let output = newChildSnapshotDirectory()
    let names = ["new-child-card.png", "new-child-card-dark.png",
                 "new-child-popover.png", "new-child-popover-dark.png"]
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    // Only this test's own four files — never the directory, which may hold
    // snapshots written by other checks running against the same path.
    for name in names { try? FileManager.default.removeItem(at: output.appendingPathComponent(name)) }
    defer { NSApp.appearance = NSAppearance(named: .aqua) }

    let harness = HarnessController(startRuntime: false)
    harness.hostClient = DSHHostClient(baseURL: URL(string: "http://127.0.0.1:0000")!)
    harness.hostCurrentSessionID = "root-session"
    harness.hostStatus = "已连接"

    for (suffix, appearance) in [
      ("", NSAppearance.Name.aqua),
      ("-dark", NSAppearance.Name.darkAqua),
    ] {
      NSApp.appearance = NSAppearance(named: appearance)
      try newChildRenderSnapshot(
        name: "new-child-card\(suffix).png",
        appearance: appearance,
        size: CGSize(width: 420, height: 150),
        root: AnyView(NativeDashboard().environmentObject(harness)),
        output: output)
      try newChildRenderSnapshot(
        name: "new-child-popover\(suffix).png",
        appearance: appearance,
        size: CGSize(width: 400, height: 330),
        root: AnyView(
          NewChildSessionPanel {}
            .environmentObject(harness)
            .background(DSHTheme.surface, in: RoundedRectangle(cornerRadius: DSHRadius.lg, style: .continuous))
            .padding(DSHSpace.s5)
            .background(DSHTheme.canvas)),
        output: output)
    }
    print("new-child-snapshot: \(output.path)")
  }
}

private func newChildSnapshotDirectory() -> URL {
  let directory = ProcessInfo.processInfo.environment["DSH_NEW_CHILD_SNAPSHOT_DIR"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? URL(fileURLWithPath: "/tmp/dsh-new-child/out", isDirectory: true)
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func newChildRenderSnapshot(
  name: String,
  appearance: NSAppearance.Name,
  size: CGSize,
  root: AnyView,
  output: URL
) throws {
  let hosting = NSHostingView(rootView: root)
  hosting.appearance = NSAppearance(named: appearance)
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

/// Minimal one-shot Host stub: accepts TCP connections, answers every
/// `api/*` POST with a `server-response` echoing the request's `rpcId`, and
/// records the prompt payloads it saw. Enough to observe what the delegating
/// client actually put on the wire without a real Host.
private final class NewChildPromptStub: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[String: Any]] = []
  private var listener: NWListener?

  var requests: [[String: Any]] {
    lock.lock(); defer { lock.unlock() }
    return recorded
  }

  var baseURL: URL? {
    guard let port = listener?.port else { return nil }
    return URL(string: "http://127.0.0.1:\(port.rawValue)")
  }

  func start() throws {
    let listener = try NWListener(using: .tcp, on: .any)
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in
      connection.start(queue: .global())
      Self.receive(on: connection, accumulator: Data(), owner: self)
    }
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
      if case .failed = state { ready.signal() }
    }
    listener.start(queue: .global())
    _ = ready.wait(timeout: .now() + 5)
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }

  private static func receive(on connection: NWConnection, accumulator: Data, owner: NewChildPromptStub?) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
      var buffer = accumulator
      if let data { buffer.append(data) }
      guard let owner else { connection.cancel(); return }
      if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
        let length = head
          .split(separator: "\r\n")
          .first { $0.lowercased().hasPrefix("content-length:") }
          .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = buffer[range.upperBound...]
        if body.count >= length {
          owner.record(Data(body.prefix(length)))
          let response = Self.response(for: Data(body.prefix(length)))
          connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
          return
        }
      }
      if isComplete || error != nil { connection.cancel(); return }
      receive(on: connection, accumulator: buffer, owner: owner)
    }
  }

  private func record(_ body: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
    lock.lock(); defer { lock.unlock() }
    recorded.append(object)
  }

  private static func response(for body: Data) -> Data {
    let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    let rpcId = object?["rpcId"] as? String ?? ""
    let payload: [String: Any] = [
      "type": "server-response",
      "rpcId": rpcId,
      "result": ["ok": true, "value": ["accepted": true]],
    ]
    let encoded = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
    head += "Content-Length: \(encoded.count)\r\nConnection: close\r\n\r\n"
    return Data(head.utf8) + encoded
  }

  /// `session/prompt` carries the mode/session at the request's top level and
  /// the text inside its single content block.
  private static func args(_ request: [String: Any]) -> [String: Any]? {
    ((request["payload"] as? [String: Any])?["args"] as? [String: Any])?["request"] as? [String: Any]
  }

  static func mode(of request: [String: Any]) -> String? { args(request)?["mode"] as? String }
  static func sessionID(of request: [String: Any]) -> String? { args(request)?["sessionId"] as? String }

  static func text(of request: [String: Any]) -> String? {
    let content = args(request)?["content"] as? [[String: Any]]
    return content?.first?["text"] as? String
  }
}

private func testNewChild_idleSessionSendsQueueAndRunningOneSendsSteer() throws {
  try MainActor.assumeIsolated {
    let stub = NewChildPromptStub()
    try stub.start()
    defer { stub.stop() }
    guard let baseURL = stub.baseURL else { throw TestFailure.message("stub never opened a port") }

    let harness = HarnessController(startRuntime: false)
    let local = HarnessController.Session(
      title: "主会话",
      workspaceName: "ds-harness",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-session")
    harness.sessions = [local]
    harness.selectedSessionID = local.id
    harness.hostCurrentSessionID = "root-session"
    harness.hostClient = DSHHostClient(baseURL: baseURL)

    try expect(harness.delegateNewChildSession(task: "空闲时委派", label: ""))
    try newChildWait { stub.requests.count == 1 }
    try expectEqual(stub.requests.first.map { NewChildPromptStub.mode(of: $0) }, "queue")

    harness.isRunning = true
    try expect(harness.delegateNewChildSession(task: "运行中委派", label: ""))
    try newChildWait { stub.requests.count == 2 }
    try expectEqual(stub.requests.last.map { NewChildPromptStub.mode(of: $0) }, "steer")

    // The instruction really is what the template builds, not a rewording.
    try expectEqual(
      stub.requests.last.flatMap { NewChildPromptStub.text(of: $0) },
      DSHNewChildDelegation.instruction(task: "运行中委派", label: ""))
    try expectEqual(stub.requests.last.flatMap { NewChildPromptStub.sessionID(of: $0) }, "root-session")
  }
}

private func newChildWait(timeout: TimeInterval = 5, until ready: () -> Bool) throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !ready() {
    guard Date() < deadline else { throw TestFailure.message("the stub never received the prompt") }
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }
}

let dshSubagentProjectionTests: [NamedTest] = [
  ("Subagent presentation selects child state without overwriting root", testSubagentPresentation_selectsChildStateWithoutOverwritingRoot),
  ("Subagent presentation rejects older projection frame", testSubagentPresentation_rejectsOlderProjectionFrame),
  ("Subagent presentation clears null Todo and Goal projection", testSubagentPresentation_clearsNullTodoAndGoalProjection),
  ("Subagent history baseline clears raw null Todo and Goal", testSubagentHistoryBaseline_clearsRawNullTodoAndGoal),
  ("Subagent history baseline does not replace newer live projection", testSubagentPresentation_historyBaselineDoesNotReplaceNewerLiveProjection),
  ("Subagent navigation generation rejects stale response", testSubagentNavigationGenerationRejectsStaleResponse),
  ("Stale subagent history activation does not replace newer selection", testStaleSubagentHistoryActivationDoesNotReplaceNewerSelection),
  ("Displayed running state follows open child rather than root", testDisplayedRunningStateFollowsOpenChildRatherThanRoot),
  ("Displayed execution target selects root and continuable child", testDisplayedExecutionTarget_selectsRootAndContinuableChild),
  ("Stop interrupts a one-shot child through its parent", testDisplayedStopTarget_interruptsOneShotChild),
  ("Child plan and queue frames do not leak root state", testChildPlanAndQueueFrames_doNotLeakRootState),
  ("Subagent catalog generation rejects old parent", testSubagentCatalogGenerationRejectsOldParent),
  ("One-shot subagent goal is read-only", testOneShotSubagentGoal_isReadOnly),
  ("Loading subagent replays only events newer than history baseline", testLoadingSubagent_replaysOnlyEventsNewerThanHistoryBaseline),
  ("Subagent history page decodes projection baseline", testSubagentHistoryPage_decodesProjectionBaseline),
  ("Child projection Todo and job frames do not mutate root state", testChildProjectionTodoAndJobFrames_doNotMutateRootState),
  ("Live child tool result updates only child context", testLiveChildToolResult_updatesOnlyChildContext),
  ("Child turn end settles only child tools", testChildTurnEnd_settlesOnlyChildTools),
  ("Child context hides root slash catalog and root-only slash commands", testChildContext_hidesRootSlashCatalogAndRootOnlySlashCommands),
  ("Workflow member navigation generation rejects stale catalog", testWorkflowMemberNavigationGenerationRejectsStaleCatalog),
  ("Root history generation rejects stale or hidden responses", testRootHistoryGenerationRejectsStaleOrHiddenResponses),
  ("New child: delegation template keeps the task verbatim", testNewChild_delegationTemplateKeepsTaskVerbatim),
  ("New child: delegation mode follows the running state", testNewChild_delegationModeFollowsRunningState),
  ("New child: blank label asks the main session to name it", testNewChild_labelFallsBackWhenBlank),
  ("New child: submit requires a non-blank task", testNewChild_submitRequiresNonBlankTask),
  ("New child: entry is offered only at a top-level session", testNewChild_entryOnlyOfferedAtTopLevelSession),
  ("New child: a rejected delegation reports why and sends nothing", testNewChild_delegationReportsWhyItSentNothing),
  ("New child: idle session sends queue, running session sends steer", testNewChild_idleSessionSendsQueueAndRunningOneSendsSteer),
  ("New child: card and popover snapshots", testNewChild_cardAndPopoverSnapshots),
]
