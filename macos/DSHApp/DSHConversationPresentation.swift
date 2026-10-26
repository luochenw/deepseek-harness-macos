import Foundation

enum DSHConversationHistoryLoadingPresentation: Equatable {
  case placeholder
  case inline

  static func resolve(isLoading: Bool, hasMessages: Bool) -> Self? {
    guard isLoading else { return nil }
    return hasMessages ? .inline : .placeholder
  }
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
  let lastID: UUID?
  let lastTextBytes: Int
  let lastReasoningBytes: Int
  let lastAttachmentID: String?
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
    let last = messages.last
    return DSHConversationMessageToken(
      contextKey: displayedConversationContextKey,
      count: messages.count,
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
