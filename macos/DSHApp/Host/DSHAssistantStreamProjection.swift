import Foundation

enum DSHAssistantStreamDeltaKind: Equatable {
  case text
  case reasoning
}

struct DSHAssistantStreamDelta: Equatable {
  let kind: DSHAssistantStreamDeltaKind
  let text: String
  let isSnapshot: Bool
}

enum DSHAssistantStreamProjection {
  static func live(eventType: String, data: [String: Any]) -> DSHAssistantStreamDelta? {
    switch eventType {
    case "assistant/chunk":
      guard let chunk = data["chunk"] as? [String: Any] else { return nil }
      switch chunk["type"] as? String {
      case "text-delta":
        return delta(
          .text,
          (chunk["text"] as? String) ?? (chunk["textDelta"] as? String),
          isSnapshot: false)
      case "reasoning-delta":
        return delta(.reasoning, chunk["text"] as? String, isSnapshot: false)
      case "block-end":
        return liveBlockDelta(chunk["block"])
      default:
        return nil
      }
    case "text-chunks":
      return delta(.text, DSHToolContentText.live(data["texts"]), isSnapshot: false)
    case "reasoning-chunks":
      return delta(.reasoning, DSHToolContentText.live(data["texts"]), isSnapshot: false)
    default:
      return nil
    }
  }

  static func history(eventType: String, data: [String: DSHJSONValue]) -> DSHAssistantStreamDelta? {
    switch eventType {
    case "assistant/chunk":
      guard let chunk = data["chunk"]?.object else { return nil }
      switch chunk["type"]?.string {
      case "text-delta":
        return delta(.text, chunk["text"]?.string ?? chunk["textDelta"]?.string, isSnapshot: false)
      case "reasoning-delta":
        return delta(.reasoning, chunk["text"]?.string, isSnapshot: false)
      case "block-end":
        return historyBlockDelta(chunk["block"])
      default:
        return nil
      }
    case "text-chunks":
      return delta(.text, DSHToolContentText.history(data["texts"]), isSnapshot: false)
    case "reasoning-chunks":
      return delta(.reasoning, DSHToolContentText.history(data["texts"]), isSnapshot: false)
    default:
      return nil
    }
  }

  static func append(_ delta: DSHAssistantStreamDelta, to message: inout HarnessController.Message) {
    switch delta.kind {
    case .text:
      guard !delta.text.isEmpty else { return }
      if message.text.isEmpty {
        message.text = delta.text
      } else if delta.isSnapshot, delta.text.hasPrefix(message.text) {
        message.text = delta.text
      } else if !message.text.hasSuffix(delta.text) {
        message.text += delta.text
      }
    case .reasoning:
      guard !delta.text.isEmpty else { return }
      let current = message.reasoning ?? ""
      if current.isEmpty {
        message.reasoning = delta.text
      } else if delta.isSnapshot, delta.text.hasPrefix(current) {
        message.reasoning = delta.text
      } else if !current.hasSuffix(delta.text) {
        message.reasoning = current + delta.text
      }
    }
  }

  static func createMessage(from delta: DSHAssistantStreamDelta, timestamp: Date? = nil) -> HarnessController.Message {
    var message = HarnessController.Message(role: .assistant, text: "", timestamp: timestamp ?? Date())
    append(delta, to: &message)
    message.hostMessageId = DSHTranscriptMessageMarker.streamingAssistantHostMessageID
    return message
  }

  private static func liveBlockDelta(_ value: Any?) -> DSHAssistantStreamDelta? {
    guard let block = value as? [String: Any] else { return nil }
    switch block["type"] as? String {
    case "text": return delta(.text, block["text"] as? String, isSnapshot: true)
    case "reasoning": return delta(.reasoning, block["text"] as? String, isSnapshot: true)
    default: return nil
    }
  }

  private static func historyBlockDelta(_ value: DSHJSONValue?) -> DSHAssistantStreamDelta? {
    guard let block = value?.object else { return nil }
    switch block["type"]?.string {
    case "text": return delta(.text, block["text"]?.string, isSnapshot: true)
    case "reasoning": return delta(.reasoning, block["text"]?.string, isSnapshot: true)
    default: return nil
    }
  }

  private static func delta(
    _ kind: DSHAssistantStreamDeltaKind,
    _ text: String?,
    isSnapshot: Bool
  ) -> DSHAssistantStreamDelta? {
    guard let text, !text.isEmpty else { return nil }
    return DSHAssistantStreamDelta(kind: kind, text: text, isSnapshot: isSnapshot)
  }
}
