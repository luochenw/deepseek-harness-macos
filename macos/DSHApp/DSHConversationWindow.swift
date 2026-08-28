import Combine
import Foundation

enum DSHConversationWindowPlanner {
  static let capacity = 240
  static let expansion = 120

  static func initialRange(count: Int) -> Range<Int> {
    let count = max(0, count)
    return max(0, count - capacity)..<count
  }

  static func updatedRange(
    current: Range<Int>,
    count: Int,
    pinnedToBottom: Bool
  ) -> Range<Int> {
    let count = max(0, count)
    guard count > 0 else { return 0..<0 }
    if pinnedToBottom { return initialRange(count: count) }
    guard current.lowerBound < count else { return initialRange(count: count) }
    let lower = max(0, current.lowerBound)
    let upper = min(count, max(lower, min(current.upperBound, lower + capacity)))
    return lower == upper ? initialRange(count: count) : lower..<upper
  }

  static func expandEarlier(current: Range<Int>, count: Int) -> Range<Int> {
    let current = updatedRange(current: current, count: count, pinnedToBottom: false)
    let lower = max(0, current.lowerBound - expansion)
    return lower..<min(max(0, count), lower + capacity)
  }

  static func expandLater(current: Range<Int>, count: Int) -> Range<Int> {
    let current = updatedRange(current: current, count: count, pinnedToBottom: false)
    let upper = min(max(0, count), current.upperBound + expansion)
    return max(0, upper - capacity)..<upper
  }

  static func prepended(
    current: Range<Int>,
    insertedCount: Int,
    countAfterInsert: Int
  ) -> Range<Int> {
    let insertedCount = max(0, insertedCount)
    let oldCount = max(0, countAfterInsert - insertedCount)
    let current = updatedRange(current: current, count: oldCount, pinnedToBottom: false)
    let shiftedLower = current.lowerBound + insertedCount
    let lower = max(0, shiftedLower - min(insertedCount, expansion))
    let upper = min(max(0, countAfterInsert), lower + capacity)
    return max(0, upper - capacity)..<upper
  }
}

enum DSHConversationWindowRestoreAlignment: Equatable {
  case top
  case bottom
}

struct DSHConversationWindowRestoreRequest: Equatable {
  let messageID: UUID
  let alignment: DSHConversationWindowRestoreAlignment
}

struct DSHConversationMessageToken: Equatable {
  let contextKey: String?
  let count: Int
  let lastID: UUID?
  let lastTextBytes: Int
  let lastReasoningBytes: Int
  let lastAttachmentID: String?
}

struct DSHConversationWindowDebugSnapshot: Equatable {
  let contextKey: String
  let range: Range<Int>
  let totalCount: Int
  var materializedCount: Int { range.count }
}

private struct DSHConversationWindowContext {
  var range: Range<Int>
  var restoreRequest: DSHConversationWindowRestoreRequest?
}

@MainActor
private final class DSHConversationWindowState {
  weak var controller: HarnessController?
  var contexts: [String: DSHConversationWindowContext] = [:]

  init(controller: HarnessController) {
    self.controller = controller
  }

  func update(
    key: String,
    range: Range<Int>,
    restoreRequest: DSHConversationWindowRestoreRequest? = nil,
    replaceAnchor: Bool = false
  ) {
    guard var context = contexts[key] else {
      controller?.objectWillChange.send()
      contexts[key] = DSHConversationWindowContext(
        range: range,
        restoreRequest: replaceAnchor ? restoreRequest : nil)
      return
    }
    let changed = context.range != range
      || (replaceAnchor && context.restoreRequest != restoreRequest)
    guard changed else { return }
    controller?.objectWillChange.send()
    context.range = range
    if replaceAnchor { context.restoreRequest = restoreRequest }
    contexts[key] = context
  }

  func consumeAnchor(key: String, anchor: UUID) {
    guard var context = contexts[key],
          context.restoreRequest?.messageID == anchor else { return }
    controller?.objectWillChange.send()
    context.restoreRequest = nil
    contexts[key] = context
  }
}

@MainActor
private final class DSHConversationWindowRegistry {
  static let shared = DSHConversationWindowRegistry()
  private var states: [ObjectIdentifier: DSHConversationWindowState] = [:]

  func state(for controller: HarnessController) -> DSHConversationWindowState {
    states = states.filter { $0.value.controller != nil }
    let key = ObjectIdentifier(controller)
    if let state = states[key], let owner = state.controller, owner === controller {
      return state
    }
    let state = DSHConversationWindowState(controller: controller)
    states[key] = state
    return state
  }
}

extension HarnessController {
  private var conversationWindowState: DSHConversationWindowState {
    DSHConversationWindowRegistry.shared.state(for: self)
  }

  var displayedConversationContextKey: String? {
    if let childID = activeSubagentAddress?.childSessionId { return "child:\(childID)" }
    if let sessionID = selectedSessionID { return "root:\(sessionID.uuidString)" }
    return nil
  }

  var displayedConversationMessageToken: DSHConversationMessageToken {
    let messages = displayedSession?.messages ?? []
    let last = messages.last
    return DSHConversationMessageToken(
      contextKey: displayedConversationContextKey,
      count: messages.count,
      lastID: last?.id,
      lastTextBytes: last?.text.utf8.count ?? 0,
      lastReasoningBytes: last?.reasoning?.utf8.count ?? 0,
      lastAttachmentID: last?.attachment?.attachmentId)
  }

  var displayedMessageWindow: Range<Int> {
    guard let key = displayedConversationContextKey else { return 0..<0 }
    let count = displayedSession?.messages.count ?? 0
    guard let current = conversationWindowState.contexts[key]?.range else {
      return DSHConversationWindowPlanner.initialRange(count: count)
    }
    return DSHConversationWindowPlanner.updatedRange(
      current: current,
      count: count,
      pinnedToBottom: false)
  }

  var displayedWindowMessages: [Message] {
    guard let messages = displayedSession?.messages else { return [] }
    return Array(messages[displayedMessageWindow])
  }

  var displayedConversationWindowHasEarlier: Bool {
    displayedMessageWindow.lowerBound > 0
  }

  var displayedConversationWindowHasLater: Bool {
    displayedMessageWindow.upperBound < (displayedSession?.messages.count ?? 0)
  }

  var conversationWindowRestoreRequest: DSHConversationWindowRestoreRequest? {
    guard let key = displayedConversationContextKey else { return nil }
    return conversationWindowState.contexts[key]?.restoreRequest
  }

  var conversationWindowDebugSnapshot: DSHConversationWindowDebugSnapshot? {
    guard let key = displayedConversationContextKey else { return nil }
    return DSHConversationWindowDebugSnapshot(
      contextKey: key,
      range: displayedMessageWindow,
      totalCount: displayedSession?.messages.count ?? 0)
  }

  func updateDisplayedConversationWindow(messageCount: Int, pinnedToBottom: Bool) {
    guard let key = displayedConversationContextKey else { return }
    let current = conversationWindowState.contexts[key]?.range
      ?? DSHConversationWindowPlanner.initialRange(count: messageCount)
    conversationWindowState.update(
      key: key,
      range: DSHConversationWindowPlanner.updatedRange(
        current: current,
        count: messageCount,
        pinnedToBottom: pinnedToBottom))
  }

  func expandDisplayedConversationEarlier(anchorMessageID: UUID?) {
    guard let key = displayedConversationContextKey else { return }
    let count = displayedSession?.messages.count ?? 0
    let current = displayedMessageWindow
    let expanded = DSHConversationWindowPlanner.expandEarlier(current: current, count: count)
    guard expanded != current else { return }
    conversationWindowState.update(
      key: key,
      range: expanded,
      restoreRequest: anchorMessageID.map {
        DSHConversationWindowRestoreRequest(messageID: $0, alignment: .top)
      },
      replaceAnchor: true)
  }

  func expandDisplayedConversationLater(anchorMessageID: UUID?) {
    guard let key = displayedConversationContextKey else { return }
    let count = displayedSession?.messages.count ?? 0
    let current = displayedMessageWindow
    let expanded = DSHConversationWindowPlanner.expandLater(current: current, count: count)
    guard expanded != current else { return }
    conversationWindowState.update(
      key: key,
      range: expanded,
      restoreRequest: anchorMessageID.map {
        DSHConversationWindowRestoreRequest(messageID: $0, alignment: .bottom)
      },
      replaceAnchor: true)
  }

  func prepareDisplayedConversationForPrepend(
    insertedCount: Int,
    anchorMessageID: UUID?
  ) {
    guard insertedCount > 0, let key = displayedConversationContextKey else { return }
    let count = displayedSession?.messages.count ?? 0
    let oldCount = max(0, count - insertedCount)
    let current = conversationWindowState.contexts[key]?.range
      ?? DSHConversationWindowPlanner.initialRange(count: oldCount)
    conversationWindowState.update(
      key: key,
      range: DSHConversationWindowPlanner.prepended(
        current: current,
        insertedCount: insertedCount,
        countAfterInsert: count),
      restoreRequest: anchorMessageID.map {
        DSHConversationWindowRestoreRequest(messageID: $0, alignment: .top)
      },
      replaceAnchor: true)
  }

  func consumeConversationWindowRestoreAnchor(_ anchor: UUID) {
    guard let key = displayedConversationContextKey else { return }
    conversationWindowState.consumeAnchor(key: key, anchor: anchor)
  }
}
