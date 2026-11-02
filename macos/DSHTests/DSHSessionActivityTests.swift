import Foundation
@testable import DSHAppLib

private func summary(_ id: String, running: Bool, parent: String? = nil) -> DSHSessionSummary {
  DSHSessionSummary(
    sessionId: id,
    updatedAt: 0,
    running: running,
    blank: false,
    cwd: nil,
    agentPreset: nil,
    parentSessionId: parent,
    origin: nil,
    projections: nil)
}

private func testVoiceTask_finishesFromHostStatusWithoutBeingOpen() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.voiceTaskSessions["voice"] = "整理文档"
    // The idle status a new session reports before its prompt starts is not a finish.
    harness.applyRemoteSessionStatus(sessionID: "voice", running: false)
    try expectEqual(harness.voiceTaskSessions["voice"], "整理文档")
    harness.applyRemoteSessionStatus(sessionID: "voice", running: true)
    try expect(harness.hasBackgroundRunningWork)
    harness.applyRemoteSessionStatus(sessionID: "voice", running: false)
    try expect(harness.voiceTaskSessions.isEmpty)
    try expect(!harness.hasBackgroundRunningWork, "the Dock must not stay on running")
  }
}

private func testVoiceTask_recoversFromAMissedStatusThroughTheSessionList() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.voiceTaskSessions["voice"] = "整理文档"
    harness.reconcileSessionActivity(with: [summary("voice", running: true)], request: harness.beginSessionListRequest())
    try expectEqual(harness.voiceTaskSessions["voice"], "整理文档")
    // The status event that ended it was lost during a reconnect.
    harness.reconcileSessionActivity(with: [summary("voice", running: false)], request: harness.beginSessionListRequest())
    try expect(harness.voiceTaskSessions.isEmpty)
  }
}

private func testSessionList_keepsTrackingASessionItDoesNotMention() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.voiceTaskSessions["voice"] = "整理文档"
    harness.applyRemoteSessionStatus(sessionID: "voice", running: true)
    harness.reconcileSessionActivity(with: [summary("other", running: false)], request: harness.beginSessionListRequest())
    try expectEqual(harness.voiceTaskSessions["voice"], "整理文档")
  }
}

private func testStaleList_cannotFinishASessionThatStartedAfterItsRequest() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.voiceTaskSessions["voice"] = "整理文档"
    let request = harness.beginSessionListRequest()
    harness.applyRemoteSessionStatus(sessionID: "voice", running: true)
    harness.reconcileSessionActivity(with: [summary("voice", running: false)], request: request)
    try expectEqual(harness.voiceTaskSessions["voice"], "整理文档")
  }
}

private func testStaleList_cannotRearmASessionThatAlreadyFinished() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.applyRemoteSessionStatus(sessionID: "s", running: true)
    let request = harness.beginSessionListRequest()
    harness.applyRemoteSessionStatus(sessionID: "s", running: false)
    harness.voiceTaskSessions["s"] = "late"
    harness.reconcileSessionActivity(with: [summary("s", running: true)], request: request)
    harness.reconcileSessionActivity(with: [summary("s", running: false)], request: harness.beginSessionListRequest())
    try expectEqual(harness.voiceTaskSessions["s"], "late")
  }
}

private func testListResponses_applyOnlyInRequestOrder() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let older = harness.beginSessionListRequest()
    let newer = harness.beginSessionListRequest()
    try expect(harness.acceptSessionList(newer))
    try expect(!harness.acceptSessionList(older), "an older list must not rearm or announce anything")
    let beforeReconnect = harness.beginSessionListRequest()
    harness.noteHostStreamsRestarted()
    try expect(!harness.acceptSessionList(beforeReconnect), "a list from before a reconnect describes the old streams")
  }
}

private func testStaleList_keepsANewerStatusOnTheSidebarAndDock() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let request = harness.beginSessionListRequest()
    harness.applyRemoteSessionStatus(sessionID: "s", running: true)
    let shown = harness.applyingNewerStatus(to: [summary("s", running: false)], since: request)
    try expect(shown[0].running)
  }
}

private func testVoiceTask_finishesEvenIfEveryStatusWasMissed() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.voiceTaskSessions["voice"] = "整理文档"
    harness.noteSessionStarted("voice")
    // Accepted but still queued: an idle list right after the prompt is not a finish.
    harness.reconcileSessionActivity(with: [summary("voice", running: false)], request: harness.beginSessionListRequest())
    try expectEqual(harness.voiceTaskSessions["voice"], "整理文档")
    // Streams dropped and came back; the whole run may have happened in the gap.
    harness.noteHostStreamsRestarted()
    harness.reconcileSessionActivity(with: [summary("voice", running: false)], request: harness.beginSessionListRequest())
    try expect(harness.voiceTaskSessions.isEmpty)
  }
}

private func testHostError_forAnUnopenedSessionWaitsUntilItOpens() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostSessions = [summary("later", running: false)]
    harness.reportSessionError(sessionID: "later", message: "boom")
    let row = HarnessController.Session(title: "later", workspaceName: "w", updatedAt: Date(), messages: [], hostSessionId: "later")
    harness.sessions = [row]
    harness.deliverPendingSessionErrors(sessionID: "later", localSessionID: row.id)
    try expectEqual(harness.sessions[0].messages.map(\.text), ["DSH Host 错误：boom"])
  }
}

private func testHostError_forAChildWaitsUntilItsTranscriptOpens() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.reportSessionError(sessionID: "child", message: "boom")
    harness.subagentTranscript = HarnessController.Session(title: "child", workspaceName: "子代理", updatedAt: Date(), messages: [])
    harness.deliverPendingSubagentErrors(sessionID: "child")
    try expectEqual(harness.subagentTranscript?.messages.map(\.text), ["DSH Host 错误：boom"])
  }
}

private func testPermission_acceptsALowerSequenceAfterReconnect() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "s"
    let options = [
      DSHPermissionOption(value: "read-only", name: "read-only", description: nil),
      DSHPermissionOption(value: "workspace-write", name: "workspace-write", description: nil),
    ]
    harness.rememberPermissionSelection(DSHPermissionSelection(options: options, currentValue: "workspace-write"), sessionID: "s", seq: 180)
    harness.rememberPermissionSelection(DSHPermissionSelection(options: options, currentValue: "read-only"), sessionID: "s", seq: 20)
    try expectEqual(harness.currentPermissionSelection?.currentValue, "workspace-write")
    harness.noteHostStreamsRestarted()
    harness.rememberPermissionSelection(DSHPermissionSelection(options: options, currentValue: "read-only"), sessionID: "s", seq: 20)
    try expectEqual(harness.currentPermissionSelection?.currentValue, "read-only")
  }
}

private func testDockBadge_coversAnyRunningSession() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    try expect(!harness.hasBackgroundRunningWork)
    harness.hostSessions = [summary("background", running: true)]
    try expect(harness.hasBackgroundRunningWork)
  }
}

private func testHostError_landsInTheSessionThatRaisedIt() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let open = HarnessController.Session(title: "打开的", workspaceName: "w", updatedAt: Date(), messages: [], hostSessionId: "open")
    let other = HarnessController.Session(title: "后台的", workspaceName: "w", updatedAt: Date(), messages: [], hostSessionId: "other")
    harness.sessions = [open, other]
    harness.selectedSessionID = open.id
    harness.hostCurrentSessionID = "open"
    harness.reportSessionError(sessionID: "other", message: "boom")
    try expect(harness.sessions[0].messages.isEmpty, "the open session must not receive another session's error")
    // The other session is not on screen, so its rows will be replaced when it opens.
    try expect(harness.sessions[1].messages.isEmpty)
    harness.deliverPendingSessionErrors(sessionID: "other", localSessionID: other.id)
    try expectEqual(harness.sessions[1].messages.map(\.text), ["DSH Host 错误：boom"])
  }
}

private func testHostError_withoutARowReachesTheStatusLine() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostSessions = [summary("unopened", running: false)]
    harness.reportSessionError(sessionID: "unopened", message: "boom")
    try expect(harness.status.contains("boom"))
  }
}

private func testRequestSource_namesTheSessionBehindARequest() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let open = HarnessController.Session(title: "当前任务", workspaceName: "w", updatedAt: Date(), messages: [], hostSessionId: "open")
    let other = HarnessController.Session(title: "后台任务", workspaceName: "w", updatedAt: Date(), messages: [], hostSessionId: "other")
    harness.sessions = [open, other]
    harness.hostCurrentSessionID = "open"
    try expectEqual(harness.requestSourceDescription(sessionID: "open"), "来自当前会话：当前任务")
    try expectEqual(harness.requestSourceDescription(sessionID: "other"), "来自其他会话：后台任务")
    try expectEqual(harness.requestSourceDescription(sessionID: "unknown"), "来自后台任务")
  }
}

private func testSwitchingSessions_clearsEverythingInTheRootScope() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.todos = [DSHTodoItem(content: "a", status: "pending")]
    harness.runNotice = "notice"
    harness.rootScope.workflowLog.record(
      [(1, .workflowRunStarted(id: "w", name: "flow"))],
      parentSessionID: "s")
    try expectEqual(harness.workflows.count, 1)
    harness.resetRootSessionPresentationState()
    try expect(harness.todos.isEmpty && harness.runNotice == nil && harness.workflows.isEmpty)
  }
}

private func testSubagentBaseline_restoresAQueueThatExistedBeforeOpening() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let inbox: DSHJSONValue = .object(decodedObject([
      "next-turn": [["id": "waiting", "content": [["type": "text", "text": "排队中"]]]],
    ]))
    harness.seedSubagentPresentation(
      sessionID: "child",
      tools: [],
      projections: DSHSessionProjections(
        asOfSeq: 4,
        values: try JSONDecoder().decode(DSHSessionProjectionValues.self, from: Data("{}".utf8)),
        rawValues: ["inbox": inbox]))
    harness.activeSubagentAddress = DSHSubagentAddress(parentSessionId: "root", childSessionId: "child", mode: "continuable")
    try expectEqual(harness.displayedQueueItems.map(\.id), ["waiting"])
  }
}

let dshSessionActivityTests: [NamedTest] = [
  ("Voice task finishes from Host status without being open", testVoiceTask_finishesFromHostStatusWithoutBeingOpen),
  ("Voice task recovers a missed status through the session list", testVoiceTask_recoversFromAMissedStatusThroughTheSessionList),
  ("Session list keeps tracking a session it does not mention", testSessionList_keepsTrackingASessionItDoesNotMention),
  ("A stale list cannot finish a session that started after its request", testStaleList_cannotFinishASessionThatStartedAfterItsRequest),
  ("A stale list cannot rearm a session that already finished", testStaleList_cannotRearmASessionThatAlreadyFinished),
  ("Dock badge covers any running session", testDockBadge_coversAnyRunningSession),
  ("List responses apply only in request order", testListResponses_applyOnlyInRequestOrder),
  ("A stale list keeps a newer status on the sidebar and Dock", testStaleList_keepsANewerStatusOnTheSidebarAndDock),
  ("A voice task finishes even if every status was missed", testVoiceTask_finishesEvenIfEveryStatusWasMissed),
  ("A Host error for an unopened session waits until it opens", testHostError_forAnUnopenedSessionWaitsUntilItOpens),
  ("Permission accepts a lower sequence after reconnect", testPermission_acceptsALowerSequenceAfterReconnect),
  ("A Host error for a child waits until its transcript opens", testHostError_forAChildWaitsUntilItsTranscriptOpens),
  ("Host error lands in the session that raised it", testHostError_landsInTheSessionThatRaisedIt),
  ("Host error without a row reaches the status line", testHostError_withoutARowReachesTheStatusLine),
  ("Request source names the session behind a request", testRequestSource_namesTheSessionBehindARequest),
  ("Switching sessions clears everything in the root scope", testSwitchingSessions_clearsEverythingInTheRootScope),
  ("Subagent baseline restores a queue that existed before opening", testSubagentBaseline_restoresAQueueThatExistedBeforeOpening),
]
