import Foundation

enum DSHConversationHistoryLoadingPresentation: Equatable {
  case placeholder
  case inline

  static func resolve(isLoading: Bool, hasMessages: Bool, running: Bool = false) -> Self? {
    guard isLoading else { return nil }
    if running, hasMessages { return nil }
    return hasMessages ? .inline : .placeholder
  }
}

enum DSHConversationScrollFollow {
  /// Estimated-distance threshold, used only when the AppKit bridge is not
  /// attached (no live clip view to measure).
  static let nearBottomThreshold: CGFloat = 120
  /// Real-distance threshold for "the viewport is at the bottom". AppKit's own
  /// values are exact, so this is deliberately tight.
  static let realBottomThreshold: CGFloat = 24

  static func isNearBottom(_ bottomDistance: CGFloat) -> Bool {
    bottomDistance < nearBottomThreshold
  }

  /// AppKit-truth check: how far the viewport bottom is from the content bottom.
  static func distanceFromBottom(
    contentOffset: CGFloat,
    contentHeight: CGFloat,
    viewportHeight: CGFloat
  ) -> CGFloat {
    guard contentHeight > 0, viewportHeight > 0 else { return .greatestFiniteMagnitude }
    return max(0, contentHeight - (contentOffset + viewportHeight))
  }

  static func isAtRealBottom(
    contentOffset: CGFloat,
    contentHeight: CGFloat,
    viewportHeight: CGFloat,
    threshold: CGFloat = realBottomThreshold
  ) -> Bool {
    distanceFromBottom(
      contentOffset: contentOffset,
      contentHeight: contentHeight,
      viewportHeight: viewportHeight) <= threshold
  }

  /// Trackpad/momentum interaction in flight. While true NOTHING may pin the
  /// viewport to the tail: LazyVStack's estimated heights are still being
  /// corrected, so a "near bottom" reading is not trustworthy and every
  /// re-pin would race the user's finger (the "jumps while fast-scrolling"
  /// report).
  static func mayPin(isInteracting: Bool) -> Bool { !isInteracting }

  /// Tail-follow requests (resize, new message, running state, steering) are
  /// deferred during an interaction; they run once it ends if still pinned.
  /// A message the user just sent is the one exception and passes `force`.
  static func mayFollowTail(isInteracting: Bool, force: Bool) -> Bool {
    force || !isInteracting
  }

  /// Pin decision taken at rest, from the real AppKit geometry.
  static func shouldPinAtRest(atRealBottom: Bool) -> Bool { atRealBottom }
}

enum DSHConversationLiveActivity {
  static func text(
    messages: [HarnessController.Message],
    tools: [HarnessController.ToolActivity],
    running: Bool
  ) -> String? {
    guard running else { return nil }
    let assistantIndex = messages.lastIndex {
      $0.role == .assistant
        && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !($0.reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    let toolIndex = messages.lastIndex { $0.role == .tool }

    if let toolIndex, toolIndex > (assistantIndex ?? -1) {
      if let message = messages[safe: toolIndex],
         let callID = message.toolCallId,
         let tool = tools.last(where: { $0.callId == callID && $0.state == .running }) {
        return toolText(tool) ?? "继续处理中…"
      }
      return "继续处理中…"
    }

    if let assistantIndex, let message = messages[safe: assistantIndex] {
      if let line = latestLine(message.text) { return line }
      if let line = latestLine(message.reasoning) { return line }
    }
    if let tool = tools.last(where: { $0.state == .running }) {
      return toolText(tool) ?? "继续处理中…"
    }
    return "继续处理中…"
  }

  private static func toolText(_ tool: HarnessController.ToolActivity) -> String? {
    DSHToolGroupStatus.instructionTitle(for: tool)
  }

  private static func latestLine(_ text: String?) -> String? {
    guard let text else { return nil }
    let line = text.split(whereSeparator: \.isNewline)
      .last
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let line, !line.isEmpty else { return nil }
    return String(line.prefix(180))
  }
}

struct DSHConversationMessageToken: Equatable {
  let contextKey: String?
  let count: Int
  let firstID: UUID?
  let lastID: UUID?
  let lastTextBytes: Int
  let lastReasoningBytes: Int
  let lastAttachmentID: String?

  /// Older history is prepended without changing the transcript tail. Follow
  /// scrolling only when the visible tail itself changed, otherwise every
  /// background page would issue another competing `scrollTo`.
  func shouldFollowTail(comparedTo previous: Self) -> Bool {
    guard contextKey == previous.contextKey else { return true }
    return lastID != previous.lastID
      || lastTextBytes != previous.lastTextBytes
      || lastReasoningBytes != previous.lastReasoningBytes
      || lastAttachmentID != previous.lastAttachmentID
  }
}

extension HarnessController {
  var displayedConversationContextKey: String? {
    if let childID = activeSubagentAddress?.childSessionId { return "child:\(childID)" }
    if let sessionID = selectedSessionID { return "root:\(sessionID.uuidString)" }
    return nil
  }

  /// A lightweight change token for transcript-wide presentation work. Reading
  /// the complete message array in the view body would trigger unnecessary
  /// work on unrelated controller updates.
  var displayedConversationMessageToken: DSHConversationMessageToken {
    let messages = displayedSession?.messages ?? []
    let first = messages.first
    let last = messages.last
    return DSHConversationMessageToken(
      contextKey: displayedConversationContextKey,
      count: messages.count,
      firstID: first?.id,
      lastID: last?.id,
      lastTextBytes: last?.text.utf8.count ?? 0,
      lastReasoningBytes: last?.reasoning?.utf8.count ?? 0,
      lastAttachmentID: last?.attachment?.attachmentId)
  }
}

private extension Array {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
