import Foundation
struct DSHQueueItem: Identifiable {
  let id: String
  let placement: String
  let text: String

  static func fromMux(_ values: [[String: Any]]) -> [Self] {
    values.compactMap { item in
      guard let id = item["id"] as? String else { return nil }
      let message = item["message"] as? [String: Any]
      let content = message?["content"] as? [[String: Any]]
      let text = content?.compactMap { $0["text"] as? String }.joined() ?? ""
      return Self(id: id, placement: item["placement"] as? String ?? "queued", text: text)
    }
  }
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

extension HarnessController {
  func mutateQueue(_ item: DSHQueueItem, action: DSHQueueAction) {
    guard canMutateDisplayedQueue,
          let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task {
      do {
        try await hostClient.updateQueue(sessionId: sessionId, itemId: item.id, action: action)
        await MainActor.run { self.status = "队列操作已提交" }
      } catch { await MainActor.run { self.appendSystem("队列操作失败：\(error.localizedDescription)") } }
    }
  }

  /// Submits while a turn is already running, via the same Host RPC `send()`
  /// uses (`session.prompt` defaults to `mode: "queue"`) — previously this
  /// only appended to a local array that nothing ever drained once the
  /// legacy one-shot CLI path was removed, so a message typed while
  /// "运行中" silently vanished. The Host's own `session/queue` push
  /// (already wired into `queueItems`) is what actually reflects the queued
  /// item back into the UI, not local state here.
  func queueDraft() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let image = draftImage
    guard !text.isEmpty || image != nil else { return }
    if isViewingContinuableSubagent {
      send()
      return
    }
    guard let hostClient, let hostSessionID = hostCurrentSessionID else { return }
    draft = ""
    draftImage = nil
    Task {
      do {
        var content: [DSHPromptContent] = text.isEmpty ? [] : [.text(text)]
        if let image, let bytes = try? Data(contentsOf: image.url) { content.append(.image(data: bytes.base64EncodedString(), mediaType: image.mediaType, name: image.url.lastPathComponent)) }
        try await hostClient.prompt(sessionId: hostSessionID, content: content, mode: "queue")
        await MainActor.run { self.status = "已排队" }
      } catch { await MainActor.run { self.appendSystem("排队失败：\(error.localizedDescription)") } }
    }
  }
}
