import Combine
import Foundation

struct DSHQueueItem: Identifiable, Equatable {
  let id: String
  let messageID: String
  let placement: String
  let text: String
  let hasNonTextContent: Bool
  var isQueued: Bool { placement == "queued" }
  var isSteering: Bool { placement == "steering" }
  var isEditable: Bool { !hasNonTextContent }
  var displayText: String { text.isEmpty && hasNonTextContent ? "包含图片或其他内容" : text }

  init(
    id: String,
    messageID: String? = nil,
    placement: String,
    text: String,
    hasNonTextContent: Bool = false
  ) {
    self.id = id
    self.messageID = messageID ?? id
    self.placement = placement
    self.text = text
    self.hasNonTextContent = hasNonTextContent
  }

  static func fromMux(_ values: [[String: Any]]) -> [Self] {
    values.compactMap { item in
      guard let id = item["id"] as? String else { return nil }
      let message = item["message"] as? [String: Any]
      let content = message?["content"] as? [[String: Any]] ?? []
      let text = content.compactMap { $0["text"] as? String }.joined()
      return Self(
        id: id,
        messageID: message?["id"] as? String,
        placement: item["placement"] as? String ?? "queued",
        text: text,
        hasNonTextContent: content.contains { ($0["type"] as? String) != "text" })
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

private enum DSHRunningSubmissionError: LocalizedError {
  case commandRejected(String)

  var errorDescription: String? {
    switch self {
    case .commandRejected(let text): text
    }
  }
}

@MainActor
private final class DSHQueueClientState {
  weak var controller: HarnessController?
  var snapshots: [String: [DSHQueueItem]] = [:]
  var submittingSessions: Set<String> = []
  var composerSubmissionSessionID: String?

  init(controller: HarnessController) {
    self.controller = controller
  }

  func set(_ items: [DSHQueueItem], for sessionID: String) {
    snapshots[sessionID] = items
    if controller?.hostCurrentSessionID == sessionID, controller?.queueItems != items {
      controller?.queueItems = items
    }
  }

  func retireSteering(messageID: String, for sessionID: String) {
    guard var items = snapshots[sessionID],
          let index = items.firstIndex(where: { $0.isSteering && $0.messageID == messageID })
    else { return }
    items.remove(at: index)
    set(items, for: sessionID)
  }

  func beginSubmission(sessionID: String) -> Bool {
    guard !submittingSessions.contains(sessionID) else { return false }
    controller?.objectWillChange.send()
    submittingSessions.insert(sessionID)
    return true
  }

  func endSubmission(sessionID: String) {
    guard submittingSessions.contains(sessionID) else { return }
    controller?.objectWillChange.send()
    submittingSessions.remove(sessionID)
  }

  func beginComposerSubmission(sessionID: String) -> Bool {
    guard composerSubmissionSessionID == nil,
          !submittingSessions.contains(sessionID) else { return false }
    controller?.objectWillChange.send()
    composerSubmissionSessionID = sessionID
    submittingSessions.insert(sessionID)
    return true
  }

  func endComposerSubmission(sessionID: String) {
    guard composerSubmissionSessionID == sessionID else { return }
    controller?.objectWillChange.send()
    composerSubmissionSessionID = nil
    submittingSessions.remove(sessionID)
  }
}

@MainActor
private final class DSHQueueClientRegistry {
  static let shared = DSHQueueClientRegistry()
  private var states: [ObjectIdentifier: DSHQueueClientState] = [:]

  func state(for controller: HarnessController) -> DSHQueueClientState {
    states = states.filter { $0.value.controller != nil }
    let key = ObjectIdentifier(controller)
    if let state = states[key], let owner = state.controller, owner === controller {
      return state
    }
    let state = DSHQueueClientState(controller: controller)
    states[key] = state
    return state
  }
}

extension HarnessController {
  private var queueClientState: DSHQueueClientState {
    DSHQueueClientRegistry.shared.state(for: self)
  }

  func rememberQueueSnapshot(_ items: [DSHQueueItem], sessionID: String) {
    queueClientState.set(items, for: sessionID)
  }

  func restoreRootQueue(sessionID: String) {
    queueItems = queueClientState.snapshots[sessionID] ?? []
  }

  func cachedQueueSnapshot(sessionID: String) -> [DSHQueueItem] {
    queueClientState.snapshots[sessionID] ?? []
  }

  func retireSteeringItem(messageID: String, sessionID: String) {
    queueClientState.retireSteering(messageID: messageID, for: sessionID)
  }

  var runningSubmissionSessionID: String? {
    if let address = activeSubagentAddress, address.mode == "continuable" {
      return address.childSessionId
    }
    return hostCurrentSessionID
  }

  var runningSubmissionInFlight: Bool {
    guard let sessionID = runningSubmissionSessionID else { return false }
    return queueClientState.submittingSessions.contains(sessionID)
  }

  var composerSubmissionInFlight: Bool {
    queueClientState.composerSubmissionSessionID != nil
  }

  func beginRunningSubmission(sessionID: String) -> Bool {
    queueClientState.beginSubmission(sessionID: sessionID)
  }

  func endRunningSubmission(sessionID: String) {
    queueClientState.endSubmission(sessionID: sessionID)
  }

  func beginComposerSubmission(sessionID: String) -> Bool {
    queueClientState.beginComposerSubmission(sessionID: sessionID)
  }

  func endComposerSubmission(sessionID: String) {
    queueClientState.endComposerSubmission(sessionID: sessionID)
  }

  nonisolated static func acceptedRunningDraftRemainder(current: String, submitted: String) -> String? {
    if current == submitted { return "" }
    guard current.hasPrefix(submitted) else { return nil }
    return String(current.dropFirst(submitted.count))
  }

  func mutateQueue(_ item: DSHQueueItem, action: DSHQueueAction) {
    guard canMutateDisplayedQueue,
          let hostClient, let sessionId = hostCurrentSessionID else { return }
    if case .edit = action {
      let current = cachedQueueSnapshot(sessionID: sessionId).first { $0.id == item.id } ?? item
      guard current.isEditable else {
        status = "包含图片或其他内容的排队消息不能直接编辑"
        return
      }
    }
    let localSessionID = selectedSessionID
    Task {
      do {
        try await hostClient.updateQueue(sessionId: sessionId, itemId: item.id, action: action)
        await MainActor.run {
          if self.hostCurrentSessionID == sessionId { self.status = "队列操作已提交" }
        }
      } catch {
        await MainActor.run {
          if let localSessionID {
            self.appendSystem("队列操作失败：\(error.localizedDescription)", to: localSessionID)
          }
        }
      }
    }
  }

  func queueDraft() { submitRunningDraft(mode: .queue) }
  func steerDraft() { submitRunningDraft(mode: .steer) }

  /// Submits while a turn is already running. Queue waits for the next turn;
  /// steer enters the current next-step window and falls back to Queue if that
  /// window closes before Host admission.
  func submitRunningDraft(mode requestedMode: DSHPromptMode) {
    let originalText = draft
    let text = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
    let image = draftImage
    guard !text.isEmpty || image != nil else { return }
    guard composerAgentProfileID == nil, displayedIsRunning, let hostClient else { return }
    if let address = activeSubagentAddress {
      submitSubagentComposerDraft(address: address, successStatus: "已排队发送子代理追问")
      return
    }
    guard let hostSessionID = hostCurrentSessionID else { return }
    if submitNativeComposerCommandIfNeeded(text: text, hasImage: image != nil) { return }
    let mode = requestedMode
    let localSessionID = selectedSessionID
    var content: [DSHPromptContent] = text.isEmpty ? [] : [.text(text)]
    if let image {
      do {
        let bytes = try Data(contentsOf: image.url)
        content.append(.image(
          data: bytes.base64EncodedString(),
          mediaType: image.mediaType,
          name: image.url.lastPathComponent))
      } catch {
        status = "读取图片失败：\(error.localizedDescription)"
        return
      }
    }
    guard beginComposerSubmission(sessionID: hostSessionID) else { return }
    Task {
      do {
        var commandExecution: DSHCommandExecution?
        if DSHComposerSubmissionPolicy.shouldExecuteCommand(
          text: text,
          hasImage: image != nil,
          isRootSession: true
        ), let execution = try await hostClient.executeCommand(sessionId: hostSessionID, line: text) {
          guard execution.succeeded else {
            throw DSHRunningSubmissionError.commandRejected(execution.result.text ?? "命令执行失败")
          }
          commandExecution = execution
        } else {
          try await hostClient.prompt(sessionId: hostSessionID, content: content, mode: mode)
        }
        await MainActor.run {
          self.endComposerSubmission(sessionID: hostSessionID)
          if self.hostCurrentSessionID == hostSessionID {
            self.status = commandExecution == nil
              ? (mode == .steer ? "已追加到当前轮" : "已排队，将在本轮结束后发送")
              : "命令已执行"
          }
          if let output = commandExecution?.result.text, !output.isEmpty, let localSessionID {
            self.appendSystem(output, to: localSessionID)
          }
          self.clearAcceptedComposerDraft(
            originalText: originalText,
            originalImageID: image?.id)
        }
      } catch {
        await MainActor.run {
          self.endComposerSubmission(sessionID: hostSessionID)
          if let localSessionID {
            self.appendSystem("\(mode.nativeLabel)失败：\(error.localizedDescription)", to: localSessionID)
          } else if self.hostCurrentSessionID == hostSessionID {
            self.status = "\(mode.nativeLabel)失败：\(error.localizedDescription)"
          }
        }
      }
    }
  }

  func steerQueuedMessages() {
    guard canMutateDisplayedQueue,
          displayedIsRunning,
          let hostClient,
          let sessionID = hostCurrentSessionID else { return }
    let items = queueItems.filter(\.isQueued)
    let localSessionID = selectedSessionID
    guard !items.isEmpty else { return }
    guard beginRunningSubmission(sessionID: sessionID) else { return }
    Task {
      do {
        for item in items {
          try await hostClient.updateQueue(sessionId: sessionID, itemId: item.id, action: .steer)
        }
        await MainActor.run {
          self.endRunningSubmission(sessionID: sessionID)
          if self.hostCurrentSessionID == sessionID {
            self.status = "已将 \(items.count) 条排队消息追加到当前轮"
          }
        }
      } catch {
        await MainActor.run {
          self.endRunningSubmission(sessionID: sessionID)
          if let rpc = error as? DSHRPCError,
             ["steer-unavailable", "queue-item-not-found"].contains(rpc.code) { return }
          if let localSessionID {
            self.appendSystem("插话发送排队消息失败：\(error.localizedDescription)", to: localSessionID)
          }
        }
      }
    }
  }
}
