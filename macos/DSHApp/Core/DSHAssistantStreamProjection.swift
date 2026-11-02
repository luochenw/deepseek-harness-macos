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
  static func decode(eventType: String, data: [String: DSHJSONValue]) -> DSHAssistantStreamDelta? {
    switch eventType {
    case DSHSessionEventName.assistantChunk:
      guard let chunk = data["chunk"]?.object else { return nil }
      switch chunk["type"]?.string {
      case "text-delta":
        return delta(.text, chunk["text"]?.string ?? chunk["textDelta"]?.string, isSnapshot: false)
      case "reasoning-delta":
        return delta(.reasoning, chunk["text"]?.string, isSnapshot: false)
      case "block-end":
        return blockDelta(chunk["block"])
      default:
        return nil
      }
    case DSHSessionEventName.textChunks:
      return delta(.text, DSHToolContentText.text(data["texts"]), isSnapshot: false)
    case DSHSessionEventName.reasoningChunks:
      return delta(.reasoning, DSHToolContentText.text(data["texts"]), isSnapshot: false)
    default:
      return nil
    }
  }

  static func append(_ delta: DSHAssistantStreamDelta, to message: inout DSHMessage) {
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

  static func createMessage(from delta: DSHAssistantStreamDelta, timestamp: Date? = nil) -> DSHMessage {
    var message = DSHMessage(role: .assistant, text: "", timestamp: timestamp ?? Date())
    append(delta, to: &message)
    message.hostMessageId = DSHTranscriptMessageMarker.streamingAssistantHostMessageID
    return message
  }

  private static func blockDelta(_ value: DSHJSONValue?) -> DSHAssistantStreamDelta? {
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
