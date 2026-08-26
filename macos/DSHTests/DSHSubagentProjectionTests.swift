import Foundation
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
    let folded = DSHFoldedHistory(messages: [], tools: [], toolSequences: [:])

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

    harness.consumeMuxFrame([
      "type": "session/projection",
      "sessionId": "child-1",
      "key": "plan",
      "value": ["active": true, "pending": false],
      "seq": 3,
    ])
    harness.consumeMuxFrame([
      "type": "session/queue",
      "sessionId": "child-1",
      "items": [[
        "id": "child-queue",
        "placement": "queued",
        "message": [
          "content": [["type": "text", "text": "child queue"]],
        ],
      ]],
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

    harness.consumeMuxFrame([
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
    harness.consumeMuxFrame([
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
    harness.consumeMuxFrame([
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
      toolSequences: ["history-tool": 11])
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

    harness.consumeMuxFrame([
      "type": "session/projection",
      "sessionId": "child-1",
      "key": "todos",
      "value": [["content": "projected child todo", "status": "in_progress"]],
      "seq": 5,
    ])
    harness.consumeMuxFrame([
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
    harness.consumeMuxFrame([
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
    harness.consumeMuxFrame([
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

    harness.consumeMuxFrame([
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
    harness.consumeMuxFrame([
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

    harness.consumeMuxFrame([
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
]
