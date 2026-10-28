import Foundation
@testable import DSHAppLib

private func messages(_ count: Int) -> [HarnessController.Message] {
  (0..<count).map { HarnessController.Message(role: .assistant, text: "message-\($0)") }
}

private func testConversationTranscript_exposesEveryLoadedMessage() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let root = HarnessController.Session(
      title: "root",
      workspaceName: "workspace",
      updatedAt: Date(),
      messages: messages(1_000),
      hostSessionId: "root-session")
    harness.sessions = [root]
    harness.selectedSessionID = root.id
    harness.hostCurrentSessionID = "root-session"

    try expectEqual(harness.displayedSession?.messages.count, 1_000)
    try expectEqual(harness.displayedConversationMessageToken.count, 1_000)
  }
}

private func testConversationTranscript_keepsRootAndChildContextsIndependent() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let root = HarnessController.Session(
      title: "root",
      workspaceName: "workspace",
      updatedAt: Date(),
      messages: messages(30),
      hostSessionId: "root-session")
    harness.sessions = [root]
    harness.selectedSessionID = root.id
    harness.hostCurrentSessionID = "root-session"
    try expectEqual(harness.displayedConversationMessageToken.count, 30)

    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-session",
      childSessionId: "child-session",
      mode: "continuable")
    harness.subagentTranscript = HarnessController.Session(
      title: "child",
      workspaceName: "workspace",
      updatedAt: Date(),
      messages: messages(7))
    try expectEqual(harness.displayedConversationMessageToken.count, 7)

    harness.activeSubagentAddress = nil
    harness.subagentTranscript = nil
    try expectEqual(harness.displayedConversationMessageToken.count, 30)
  }
}

private func testConversationTailFollowing_ignoresOlderPagePrepends() throws {
  let current = DSHConversationMessageToken(
    contextKey: "root:session",
    count: 500,
    firstID: UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
    lastID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
    lastTextBytes: 120,
    lastReasoningBytes: 40,
    lastAttachmentID: nil)
  let afterPrepend = DSHConversationMessageToken(
    contextKey: "root:session",
    count: 1_000,
    firstID: UUID(uuidString: "00000000-0000-0000-0000-000000000002"),
    lastID: current.lastID,
    lastTextBytes: current.lastTextBytes,
    lastReasoningBytes: current.lastReasoningBytes,
    lastAttachmentID: nil)
  let streaming = DSHConversationMessageToken(
    contextKey: "root:session",
    count: 500,
    firstID: current.firstID,
    lastID: current.lastID,
    lastTextBytes: 160,
    lastReasoningBytes: current.lastReasoningBytes,
    lastAttachmentID: nil)
  let switched = DSHConversationMessageToken(
    contextKey: "root:other",
    count: 500,
    firstID: current.firstID,
    lastID: current.lastID,
    lastTextBytes: current.lastTextBytes,
    lastReasoningBytes: current.lastReasoningBytes,
    lastAttachmentID: nil)

  try expect(!afterPrepend.shouldFollowTail(comparedTo: current))
  try expect(streaming.shouldFollowTail(comparedTo: current))
  try expect(switched.shouldFollowTail(comparedTo: current))
}

private func testHistoryPagination_advancesOnlyTowardOlderSequences() throws {
  try expectEqual(DSHHistoryPagination.pageSize, 500)
  try expect(DSHHistoryPagination.advances(currentOldest: 900, pageOldest: 400))
  try expect(!DSHHistoryPagination.advances(currentOldest: 400, pageOldest: 400))
  try expect(!DSHHistoryPagination.advances(currentOldest: 400, pageOldest: 500))
  try expect(!DSHHistoryPagination.advances(currentOldest: 400, pageOldest: nil))
}

private func testHistoryCache_reusesOnlyUnchangedCompleteSnapshots() throws {
  try expect(!DSHHistoryCachePolicy.canReuse(
    cached: DSHHistoryCacheVersion(sequence: 100, updatedAt: 2_000),
    hostSequence: 100,
    hostUpdatedAt: 2_000,
    hasMessages: false))
  try expect(DSHHistoryCachePolicy.canReuse(
    cached: DSHHistoryCacheVersion(sequence: 100, updatedAt: 1_000),
    hostSequence: 100,
    hostUpdatedAt: 2_000,
    hasMessages: true))
  try expect(!DSHHistoryCachePolicy.canReuse(
    cached: DSHHistoryCacheVersion(sequence: 99, updatedAt: 2_000),
    hostSequence: 100,
    hostUpdatedAt: 2_000,
    hasMessages: true))
  try expect(DSHHistoryCachePolicy.canReuse(
    cached: DSHHistoryCacheVersion(sequence: 101, updatedAt: 1_000),
    hostSequence: 100,
    hostUpdatedAt: 2_000,
    hasMessages: true))
  try expect(DSHHistoryCachePolicy.canReuse(
    cached: DSHHistoryCacheVersion(sequence: nil, updatedAt: 2_000),
    hostSequence: nil,
    hostUpdatedAt: 2_000,
    hasMessages: true))
  try expect(!DSHHistoryCachePolicy.canReuse(
    cached: DSHHistoryCacheVersion(sequence: nil, updatedAt: 1_999),
    hostSequence: nil,
    hostUpdatedAt: 2_000,
    hasMessages: true))
  try expect(!DSHHistoryCachePolicy.canReuse(
    cached: nil,
    hostSequence: nil,
    hostUpdatedAt: 2_000,
    hasMessages: true))
}

private func testConversationHistoryLoading_keepsLoadedMessagesVisible() throws {
  try expectEqual(
    DSHConversationHistoryLoadingPresentation.resolve(
      isLoading: true,
      hasMessages: false),
    .placeholder)
  try expectEqual(
    DSHConversationHistoryLoadingPresentation.resolve(
      isLoading: true,
      hasMessages: true),
    .inline)
  try expectEqual(
    DSHConversationHistoryLoadingPresentation.resolve(
      isLoading: false,
      hasMessages: true),
    nil)
  try expectEqual(
    DSHConversationHistoryLoadingPresentation.resolve(
      isLoading: true,
      hasMessages: true,
      running: true),
    nil)
  try expectEqual(
    DSHConversationHistoryLoadingPresentation.resolve(
      isLoading: true,
      hasMessages: false,
      running: true),
    .placeholder)
}

private func testConversationFollow_reengagesOnlyNearTheBottom() throws {
  try expect(DSHConversationScrollFollow.isNearBottom(-12))
  try expect(DSHConversationScrollFollow.isNearBottom(119))
  try expect(!DSHConversationScrollFollow.isNearBottom(120))
  try expect(!DSHConversationScrollFollow.isNearBottom(400))
}

private func testLiveActivity_followsReasoningTextAndRunningTool() throws {
  var reasoning = HarnessController.Message(role: .assistant, text: "")
  reasoning.reasoning = "first line\nlatest reasoning"
  reasoning.hostMessageId = DSHTranscriptMessageMarker.streamingAssistantHostMessageID
  try expectEqual(
    DSHConversationLiveActivity.text(
      messages: [reasoning],
      tools: [],
      running: true),
    "latest reasoning")

  var answer = HarnessController.Message(role: .assistant, text: "answer line")
  answer.hostMessageId = DSHTranscriptMessageMarker.streamingAssistantHostMessageID
  try expectEqual(
    DSHConversationLiveActivity.text(
      messages: [answer],
      tools: [],
      running: true),
    "answer line")

  let toolMessage = HarnessController.Message(
    role: .tool,
    text: "run_code",
    toolCallId: "call-1")
  let tool = HarnessController.ToolActivity(
    callId: "call-1",
    name: "run_code",
    summary: "inspect the renderer",
    state: .running,
    output: "",
    presentation: nil)
  try expectEqual(
    DSHConversationLiveActivity.text(
      messages: [answer, toolMessage],
      tools: [tool],
      running: true),
    "inspect the renderer")
  try expect(
    DSHConversationLiveActivity.text(
      messages: [answer, toolMessage],
      tools: [tool],
      running: false) == nil)
}

private func testReasoningFold_keepsCurrentTurnStatusLiveAfterBodyAndTools() throws {
  let user = HarnessController.Message(role: .user, text: "go")
  var trace = HarnessController.Message(role: .assistant, text: "answer")
  trace.reasoning = "thinking"
  trace.hostMessageId = DSHTranscriptMessageMarker.streamingAssistantHostMessageID
  let tool = HarnessController.Message(
    role: .tool,
    text: "run_code",
    toolCallId: "call-1")
  let items = ConversationView.foldTranscript(
    [user, trace, tool],
    activeTurnRunning: true)
  let reasoning = items.compactMap { item -> ConversationView.ReasoningTrace? in
    guard case .reasoning(let trace) = item else { return nil }
    return trace
  }
  try expectEqual(reasoning.count, 1)
  try expect(reasoning[0].live)

  let settled = ConversationView.foldTranscript(
    [user, trace, tool],
    activeTurnRunning: false)
  guard let settledReasoning = settled.compactMap({ item -> ConversationView.ReasoningTrace? in
    guard case .reasoning(let trace) = item else { return nil }
    return trace
  }).first else {
    throw TestFailure.message("expected a reasoning row")
  }
  try expect(!settledReasoning.live)
}

private func testReasoningLayout_capsOnlyLongExpandedContent() throws {
  try expectEqual(DSHReasoningLayout.expandedHeight(measured: nil), 44)
  try expectEqual(DSHReasoningLayout.expandedHeight(measured: 32), 32)
  try expectEqual(DSHReasoningLayout.expandedHeight(measured: 160), 160)
  try expectEqual(DSHReasoningLayout.expandedHeight(measured: 480), 240)
}

private func testToolDetailsLayout_capsOnlyLongExpandedContent() throws {
  try expectEqual(DSHToolDetailsLayout.expandedHeight(measured: nil), 56)
  try expectEqual(DSHToolDetailsLayout.expandedHeight(measured: 28), 28)
  try expectEqual(DSHToolDetailsLayout.expandedHeight(measured: 180), 180)
  try expectEqual(DSHToolDetailsLayout.expandedHeight(measured: 960), 320)
}

private func testHistoryPageMerge_prependsOlderMessagesWithoutDuplicates() throws {
  let current = [
    HarnessController.Message(role: .assistant, text: "recent"),
  ]
  let older = [
    HarnessController.Message(role: .user, text: "older"),
    current[0],
  ]
  let merged = DSHHistoryPageMerge.prepend(older, to: current)
  try expectEqual(merged.map(\.text), ["older", "recent"])
  try expectEqual(
    DSHHistoryPageMerge.prepend([], to: current).map(\.text),
    ["recent"])
}

private func testHistorySnapshotMerge_preservesVisibleRowIdentity() throws {
  let user = HarnessController.Message(
    role: .user,
    text: "run",
    hostMessageId: "host-user")
  var assistant = HarnessController.Message(
    role: .assistant,
    text: "partial",
    hostMessageId: DSHTranscriptMessageMarker.streamingAssistantHostMessageID)
  assistant.reasoning = "before"
  let existing = [user, assistant]

  let incomingUser = HarnessController.Message(
    role: .user,
    text: "run",
    timestamp: user.timestamp.addingTimeInterval(1),
    hostMessageId: "host-user")
  let incomingAssistant = HarnessController.Message(
    role: .assistant,
    text: "complete",
    timestamp: assistant.timestamp.addingTimeInterval(1),
    hostMessageId: DSHTranscriptMessageMarker.streamingAssistantHostMessageID)
  let tool = HarnessController.Message(
    role: .tool,
    text: "run_code",
    toolCallId: "tool-1")
  let merged = DSHHistoryPageMerge.mergeTail(
    [incomingUser, incomingAssistant, tool],
    into: existing)

  try expectEqual(merged.count, 3)
  try expectEqual(merged[0].id, user.id)
  try expectEqual(merged[1].id, assistant.id)
  try expectEqual(merged[1].text, "complete")
  try expectEqual(merged[2].toolCallId, "tool-1")
}

private func testHistoryLoadingWatchdog_releasesOnlyCurrentLoad() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "Large",
      workspaceName: "Workspace",
      updatedAt: Date(),
      messages: [],
      isLoadingHistory: true,
      hostSessionId: "large")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "large"
    let generation = harness.beginRootHistoryRequest(
      sessionID: "large",
      localSessionID: session.id)

    try expect(!harness.expireHistoryLoadingIfNeeded(
      sessionID: "large",
      localSessionID: session.id,
      generation: generation - 1))
    try expect(harness.sessions[0].isLoadingHistory)
    try expect(harness.expireHistoryLoadingIfNeeded(
      sessionID: "large",
      localSessionID: session.id,
      generation: generation))
    try expect(!harness.sessions[0].isLoadingHistory)
  }
}

private func testConversationFold_groupsConsecutiveRunCodeCalls() throws {
  let runCodes = [
    HarnessController.Message(role: .tool, text: "run_code", toolCallId: "run-1"),
    HarnessController.Message(role: .tool, text: "run_code", toolCallId: "run-2"),
  ]
  let bash = [
    HarnessController.Message(role: .tool, text: "bash", toolCallId: "bash-1"),
    HarnessController.Message(role: .tool, text: "bash", toolCallId: "bash-2"),
  ]

  let runItems = ConversationView.foldTranscript(runCodes)
  try expectEqual(runItems.count, 1)
  guard case .toolGroup(let runGroup) = runItems[0] else {
    throw TestFailure.message("consecutive run_code calls should be grouped")
  }
  try expectEqual(runGroup.map(\.toolCallId), ["run-1", "run-2"])
  guard case .toolGroup = ConversationView.foldTranscript(bash).first else {
    throw TestFailure.message("other repeated tools should retain grouping")
  }

  let separated = ConversationView.foldTranscript([
    runCodes[0],
    HarnessController.Message(role: .assistant, text: "between"),
    runCodes[1],
  ])
  try expectEqual(separated.count, 3)
  guard case .message = separated[0], case .message = separated[2] else {
    throw TestFailure.message("non-consecutive run_code calls must remain separate")
  }
}

let dshConversationHistoryTests: [NamedTest] = [
  ("Conversation transcript exposes every loaded message", testConversationTranscript_exposesEveryLoadedMessage),
  ("Conversation transcript keeps root and child contexts independent", testConversationTranscript_keepsRootAndChildContextsIndependent),
  ("Conversation tail following ignores older-page prepends", testConversationTailFollowing_ignoresOlderPagePrepends),
  ("History pagination advances toward older sequences", testHistoryPagination_advancesOnlyTowardOlderSequences),
  ("History cache reuses only unchanged complete snapshots", testHistoryCache_reusesOnlyUnchangedCompleteSnapshots),
  ("Conversation history loading keeps loaded messages visible", testConversationHistoryLoading_keepsLoadedMessagesVisible),
  ("Conversation follow re-engages only near the bottom", testConversationFollow_reengagesOnlyNearTheBottom),
  ("Live activity follows reasoning, text, and running tools", testLiveActivity_followsReasoningTextAndRunningTool),
  ("Reasoning fold keeps the current turn status live", testReasoningFold_keepsCurrentTurnStatusLiveAfterBodyAndTools),
  ("Reasoning layout caps only long expanded content", testReasoningLayout_capsOnlyLongExpandedContent),
  ("Tool details layout caps only long expanded content", testToolDetailsLayout_capsOnlyLongExpandedContent),
  ("History page merge prepends older messages without duplicates", testHistoryPageMerge_prependsOlderMessagesWithoutDuplicates),
  ("History snapshot merge preserves visible row identity", testHistorySnapshotMerge_preservesVisibleRowIdentity),
  ("History loading watchdog releases only the current load", testHistoryLoadingWatchdog_releasesOnlyCurrentLoad),
  ("Conversation fold groups consecutive run_code calls", testConversationFold_groupsConsecutiveRunCodeCalls),
]
