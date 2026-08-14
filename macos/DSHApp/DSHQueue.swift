import Foundation
struct DSHQueueItem: Identifiable {
  let id: String
  let placement: String
  let text: String
}
struct DSHQueueActionPayload: Encodable {
  let sessionId: String
  let itemId: String
  let action: DSHQueueAction
}
struct QueueKind: Encodable { let kind: String }
struct QueueText: Encodable { let type: String; let text: String }
struct QueueEdit: Encodable { let kind: String; let content: [QueueText] }

enum DSHQueueAction: Encodable {
  case remove
  case steer
  case edit(String)
  func encode(to encoder: Encoder) throws {
    var box = encoder.singleValueContainer()
    switch self {
    case .remove: try box.encode(QueueKind(kind: "remove"))
    case .steer: try box.encode(QueueKind(kind: "steer"))
    case .edit(let text): try box.encode(QueueEdit(kind: "edit", content: [QueueText(type: "text", text: text)]))
    }
  }
}
struct DSHQueueMutationResult: Decodable { let accepted: Bool }
