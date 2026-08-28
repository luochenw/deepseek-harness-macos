import Foundation
@testable import DSHAppLib

private func messages(_ count: Int) -> [HarnessController.Message] {
  (0..<count).map { HarnessController.Message(role: .assistant, text: "message-\($0)") }
}

private func testConversationWindow_initialAndTailFollowStayBounded() throws {
  try expectEqual(DSHConversationWindowPlanner.initialRange(count: 1_000), 760..<1_000)
  try expectEqual(
    DSHConversationWindowPlanner.updatedRange(
      current: 760..<1_000,
      count: 1_008,
      pinnedToBottom: true),
    768..<1_008)
}

private func testConversationWindow_expandsAtEdgesAndPreservesPrependContext() throws {
  try expectEqual(
    DSHConversationWindowPlanner.expandEarlier(current: 760..<1_000, count: 1_000),
    640..<880)
  try expectEqual(
    DSHConversationWindowPlanner.expandLater(current: 240..<480, count: 1_000),
    360..<600)
  try expectEqual(
    DSHConversationWindowPlanner.prepended(
      current: 760..<1_000,
      insertedCount: 120,
      countAfterInsert: 1_120),
    760..<1_000)
}

private func testConversationWindow_keepsRootAndChildContextsIndependent() throws {
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
    harness.updateDisplayedConversationWindow(messageCount: 1_000, pinnedToBottom: true)
    try expectEqual(harness.displayedMessageWindow, 760..<1_000)

    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-session",
      childSessionId: "child-session",
      mode: "continuable")
    harness.subagentTranscript = HarnessController.Session(
      title: "child",
      workspaceName: "workspace",
      updatedAt: Date(),
      messages: messages(30))
    harness.updateDisplayedConversationWindow(messageCount: 30, pinnedToBottom: true)
    try expectEqual(harness.displayedMessageWindow, 0..<30)

    harness.activeSubagentAddress = nil
    harness.subagentTranscript = nil
    try expectEqual(harness.displayedMessageWindow, 760..<1_000)
  }
}

private func testConversationWindow_recordsOneShotAnchorForPrependedHistory() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    var rootMessages = messages(1_000)
    let root = HarnessController.Session(
      title: "root",
      workspaceName: "workspace",
      updatedAt: Date(),
      messages: rootMessages,
      hostSessionId: "root-session")
    harness.sessions = [root]
    harness.selectedSessionID = root.id
    harness.hostCurrentSessionID = "root-session"
    harness.updateDisplayedConversationWindow(messageCount: 1_000, pinnedToBottom: true)
    let anchor = harness.displayedWindowMessages[0].id

    rootMessages.insert(contentsOf: messages(120), at: 0)
    harness.sessions[0].messages = rootMessages
    harness.prepareDisplayedConversationForPrepend(
      insertedCount: 120,
      anchorMessageID: anchor)

    try expectEqual(harness.displayedMessageWindow, 760..<1_000)
    try expectEqual(harness.conversationWindowRestoreRequest?.messageID, anchor)
    try expectEqual(harness.conversationWindowRestoreRequest?.alignment, .top)
    harness.consumeConversationWindowRestoreAnchor(anchor)
    try expect(harness.conversationWindowRestoreRequest == nil)
  }
}

let dshConversationWindowTests: [NamedTest] = [
  ("Conversation window initial and tail follow stay bounded", testConversationWindow_initialAndTailFollowStayBounded),
  ("Conversation window expands at edges and preserves prepend context", testConversationWindow_expandsAtEdgesAndPreservesPrependContext),
  ("Conversation window keeps root and child contexts independent", testConversationWindow_keepsRootAndChildContextsIndependent),
  ("Conversation window records a one-shot prepend anchor", testConversationWindow_recordsOneShotAnchorForPrependedHistory),
]
