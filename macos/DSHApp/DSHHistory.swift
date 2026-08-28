import Foundation


indirect enum DSHJSONValue: Decodable {
  case string(String), number(Double), bool(Bool), object([String: DSHJSONValue]), array([DSHJSONValue]), null
  init(from decoder: Decoder) throws {
    let box = try decoder.singleValueContainer()
    if box.decodeNil() { self = .null }
    else if let value = try? box.decode(Bool.self) { self = .bool(value) }
    else if let value = try? box.decode(Double.self) { self = .number(value) }
    else if let value = try? box.decode(String.self) { self = .string(value) }
    else if let value = try? box.decode([String: DSHJSONValue].self) { self = .object(value) }
    else { self = .array(try box.decode([DSHJSONValue].self)) }
  }
  var object: [String: DSHJSONValue]? { if case let .object(value) = self { value } else { nil } }
  var string: String? { if case let .string(value) = self { value } else { nil } }
  var array: [DSHJSONValue]? { if case let .array(value) = self { value } else { nil } }
}

struct DSHRawEvent: Decodable {
  let type: String
  let seq: Int
  let time: Double
  let data: DSHJSONValue
}

struct DSHHistoryEntry: Decodable { let event: DSHRawEvent; let view: DSHJSONValue? }
struct DSHHistoryPage: Decodable {
  let events: [DSHHistoryEntry]
  let hasMore: Bool
  let projections: DSHSessionProjections?
}
struct DSHHistoryPayload: Encodable { let sessionId: String; let beforeSeq: Int?; let maxMessages: Int }

struct DSHFoldedHistory {
  let messages: [HarnessController.Message]
  let tools: [HarnessController.ToolActivity]
  let toolSequences: [String: Int]
}

private struct DSHRootHistoryRequest: Equatable {
  let sessionID: String
  let localSessionID: UUID
}

@MainActor
private final class DSHRootHistoryLoadState {
  weak var controller: HarnessController?
  var generation = 0
  var request: DSHRootHistoryRequest?

  init(controller: HarnessController) {
    self.controller = controller
  }
}

@MainActor
private final class DSHRootHistoryLoadRegistry {
  static let shared = DSHRootHistoryLoadRegistry()
  private var states: [ObjectIdentifier: DSHRootHistoryLoadState] = [:]

  func state(for controller: HarnessController) -> DSHRootHistoryLoadState {
    states = states.filter { $0.value.controller != nil }
    let key = ObjectIdentifier(controller)
    if let state = states[key], let owner = state.controller, owner === controller {
      return state
    }
    let state = DSHRootHistoryLoadState(controller: controller)
    states[key] = state
    return state
  }
}

enum DSHTranscriptMessageMarker {
  static let streamingAssistantHostMessageID = "\u{0}dsh-streaming-assistant"
  static let pendingLocalUserHostMessageID = "\u{0}dsh-pending-local-user"

  static func matchesPendingLocalUserEcho(
    localText: String,
    incomingText: String,
    attachment: DSHAttachmentRef?
  ) -> Bool {
    if incomingText == localText { return true }
    return DSHAttachmentRail.matchesLocalUserEcho(
      localText: localText,
      incomingText: incomingText,
      attachment: attachment)
  }
}

extension HarnessController {
  private var rootHistoryLoadState: DSHRootHistoryLoadState {
    DSHRootHistoryLoadRegistry.shared.state(for: self)
  }

  @discardableResult
  func beginRootHistoryRequest(sessionID: String, localSessionID: UUID) -> Int {
    let state = rootHistoryLoadState
    state.generation += 1
    state.request = DSHRootHistoryRequest(
      sessionID: sessionID,
      localSessionID: localSessionID)
    return state.generation
  }

  @discardableResult
  func beginRootHistoryRequest(localSessionID: UUID) -> Int {
    beginRootHistoryRequest(
      sessionID: hostCurrentSessionID ?? "",
      localSessionID: localSessionID)
  }

  func acceptsRootHistoryRequest(
    sessionID: String,
    localSessionID: UUID,
    generation: Int
  ) -> Bool {
    let state = rootHistoryLoadState
    return state.generation == generation
      && state.request == DSHRootHistoryRequest(
        sessionID: sessionID,
        localSessionID: localSessionID)
      && hostCurrentSessionID == sessionID
      && selectedSessionID == localSessionID
      && subagentTranscript == nil
  }

  func invalidateRootHistoryRequests() {
    let state = rootHistoryLoadState
    state.generation += 1
    state.request = nil
  }

  func loadSkills(sessionId: String) {
    guard let hostClient else { return }
    Task {
      do {
        let result = try await hostClient.skills(sessionId: sessionId)
        await MainActor.run {
          guard self.hostCurrentSessionID == sessionId else { return }
          self.skills = result
        }
      } catch {
        await MainActor.run {
          guard self.hostCurrentSessionID == sessionId else { return }
          self.skills = []
        }
      }
    }
  }

  /// Typert-layer session context: the slash-command roster and per-message
  /// feedback state. Both are structurally unreachable over the legacy
  /// ApiProxy layer — see DSHTypertGateway.swift.
  func loadCommands(sessionId: String) {
    guard let hostClient else { return }
    Task {
      if let commands = try? await hostClient.listCommands(sessionId: sessionId) {
        await MainActor.run {
          guard self.hostCurrentSessionID == sessionId else { return }
          self.hostCommands = commands
        }
      }
    }
  }

  /// Re-pull the slash palette's two catalogs for the current session.
  /// Fired when the user types the leading `/` so a skill installed (or a
  /// command registered) mid-session shows up without re-attaching — the
  /// native stand-in for the web client's `commands/change` invalidation.
  func refreshSlashCatalog() {
    guard canUseRootSlashCatalog, let sessionId = hostCurrentSessionID else { return }
    loadSkills(sessionId: sessionId)
    loadCommands(sessionId: sessionId)
  }

  func loadMessageFeedback(sessionId: String) {
    guard let hostClient else { return }
    Task {
      if let items = try? await hostClient.messageFeedback(sessionId: sessionId) {
        await MainActor.run {
          guard self.hostCurrentSessionID == sessionId else { return }
          self.messageFeedback = Dictionary(uniqueKeysWithValues: items.map { ($0.messageId, $0) })
        }
      }
    }
  }

  func loadPluginInventory() {
    guard let hostClient else { return }
    Task { if let entries = try? await hostClient.pluginInventory() { await MainActor.run { self.pluginEntries = entries } } }
  }

  /// Thumb feedback on one assistant message; `rating` nil removes it.
  func setFeedback(messageId: String, rating: String?) {
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    let existing = messageFeedback[messageId]
    Task {
      do {
        if let rating {
          let item = try await hostClient.putMessageFeedback(sessionId: sessionId, messageId: messageId, rating: rating, note: nil, ifVersion: existing?.version)
          await MainActor.run { self.messageFeedback[messageId] = item }
        } else if let existing {
          try await hostClient.deleteMessageFeedback(sessionId: sessionId, messageId: messageId, ifVersion: existing.version)
          await MainActor.run { self.messageFeedback[messageId] = nil }
        }
      } catch {
        await MainActor.run { self.status = "反馈提交失败：\(error.localizedDescription)"; self.loadMessageFeedback(sessionId: sessionId) }
      }
    }
  }

  func loadSubagents(parentSessionId: String) {
    guard let hostClient else { return }
    let generation = beginSubagentCatalogLoad(parentSessionID: parentSessionId)
    Task {
      do {
        let catalog = try await hostClient.subagents(parentSessionId: parentSessionId)
        await MainActor.run {
          guard self.acceptsSubagentCatalogLoad(parentSessionID: parentSessionId, generation: generation) else { return }
          self.subagents = catalog.entries
        }
      } catch {
        await MainActor.run {
          guard self.acceptsSubagentCatalogLoad(parentSessionID: parentSessionId, generation: generation) else { return }
          self.subagents = []
        }
      }
    }
  }

  func loadHistory(sessionId: String, localSessionID: UUID) {
    guard let hostClient else { return }
    let generation = beginRootHistoryRequest(
      sessionID: sessionId,
      localSessionID: localSessionID)
    Task {
      do {
        let page = try await hostClient.history(sessionId: sessionId)
        let folded = foldHistoryContent(page.events)
        await MainActor.run {
          guard self.acceptsRootHistoryRequest(
            sessionID: sessionId,
            localSessionID: localSessionID,
            generation: generation),
            let index = self.sessions.firstIndex(where: { $0.id == localSessionID })
          else { return }
          self.sessions[index].messages = folded.messages.isEmpty ? [Message(role: .system, text: "这个会话还没有可显示的消息。")] : folded.messages
          self.activeTools = folded.tools
          self.historyHasMore = page.hasMore
          self.historyOldestSeq = page.events.map { $0.event.seq }.min()
          self.sessions[index].updatedAt = Date()
          self.rememberPermissionSelection(
            page.projections?.values.permissions,
            sessionID: sessionId,
            seq: page.projections?.asOfSeq ?? -1)
          self.status = "已载入 \(folded.messages.count) 条原生会话消息"
        }
      } catch {
        await MainActor.run {
          guard self.acceptsRootHistoryRequest(
            sessionID: sessionId,
            localSessionID: localSessionID,
            generation: generation)
          else { return }
          self.appendSystem("载入会话历史失败：\(error.localizedDescription)", to: localSessionID)
        }
      }
    }
  }

  func loadOlderHistory() {
    guard let hostClient, let sessionId = hostCurrentSessionID,
          let before = historyOldestSeq, historyHasMore,
          let localSessionID = selectedSessionID
    else { return }
    let restoreAnchor = displayedWindowMessages.first?.id
    let generation = beginRootHistoryRequest(
      sessionID: sessionId,
      localSessionID: localSessionID)
    Task {
      do {
        let page = try await hostClient.history(sessionId: sessionId, beforeSeq: before, maxMessages: 100)
        let older = foldHistoryContent(page.events)
        await MainActor.run {
          guard self.acceptsRootHistoryRequest(
            sessionID: sessionId,
            localSessionID: localSessionID,
            generation: generation),
            let index = self.sessions.firstIndex(where: { $0.id == localSessionID })
          else { return }
          self.sessions[index].messages = older.messages + self.sessions[index].messages
          self.prepareDisplayedConversationForPrepend(
            insertedCount: older.messages.count,
            anchorMessageID: restoreAnchor)
          for tool in older.tools
          where !self.activeTools.contains(where: { $0.callId == tool.callId }) {
            self.activeTools.append(tool)
          }
          self.historyHasMore = page.hasMore
          self.historyOldestSeq = page.events.map { $0.event.seq }.min() ?? self.historyOldestSeq
        }
      } catch {
        await MainActor.run {
          guard self.acceptsRootHistoryRequest(
            sessionID: sessionId,
            localSessionID: localSessionID,
            generation: generation)
          else { return }
          self.status = "载入更早消息失败"
        }
      }
    }
  }

  /// Synchronous callers that already own the displayed root context (tests
  /// and local reconstruction helpers) retain this convenience wrapper.
  /// Network history paths use `foldHistoryContent` and apply the result only
  /// after their request generation has been validated.
  func foldHistory(_ entries: [DSHHistoryEntry]) -> [Message] {
    let folded = foldHistoryContent(entries)
    activeTools = folded.tools
    return folded.messages
  }

  func foldHistoryContent(_ entries: [DSHHistoryEntry]) -> DSHFoldedHistory {
    var result: [Message] = []
    var tools: [String: ToolActivity] = [:]
    var toolSequences: [String: Int] = [:]
    for entry in entries {
      let event = entry.event
      guard let data = event.data.object else { continue }
      switch event.type {
      case "user/message":
        let message = historyMessage(data)
        // Only real typed input becomes a bubble; injected user-role
        // contexts (13KB instruction snapshots…) stay out of the transcript
        // — except the cross-session relay plugin's own delivered messages,
        // which are real conversation content, not model plumbing.
        let relay = historyIsRelayMessage(message)
        guard messageSourceKind(message) == nil || messageSourceKind(message) == "user" || relay else { continue }
        if let text = textFromMessage(message) { result.append(Message(role: .user, text: userDisplayText(text), timestamp: Date(timeIntervalSince1970: event.time / 1000), attachment: DSHAttachmentRef.fromHistoryMessage(message), isRelayMessage: relay)) }
      case "assistant/message":
        let payload = historyMessage(data)
        if let text = textFromMessage(payload) {
          var message = Message(role: .assistant, text: text, timestamp: Date(timeIntervalSince1970: event.time / 1000), attachment: DSHAttachmentRef.fromHistoryMessage(payload), reasoning: reasoningFromMessage(payload))
          message.hostMessageId = payload.object?["id"]?.string
          // Stream-only history chunks carry no durable message id. Replace
          // only that placeholder; consecutive settled assistant messages
          // are distinct transcript rows and may each own an attachment.
          if result.last?.role == .assistant,
             result.last?.hostMessageId == DSHTranscriptMessageMarker.streamingAssistantHostMessageID {
            message.reasoning = message.reasoning ?? result[result.count - 1].reasoning
            result[result.count - 1] = message
          } else {
            result.append(message)
          }
        }
      case "assistant/chunk":
        // Some adapters (e.g. hand-declared relay providers) log only the
        // stream — without folding it, a reloaded transcript has no
        // assistant text at all. Mirrors the live anchoring: extend the
        // trailing assistant bubble, otherwise open a fresh one.
        guard let chunk = data["chunk"]?.object else { continue }
        if chunk["type"]?.string == "text-delta", let delta = chunk["textDelta"]?.string {
          if result.last?.role == .assistant,
             result.last?.hostMessageId == DSHTranscriptMessageMarker.streamingAssistantHostMessageID {
            result[result.count - 1].text += delta
          } else {
            var message = Message(role: .assistant, text: delta, timestamp: Date(timeIntervalSince1970: event.time / 1000))
            message.hostMessageId = DSHTranscriptMessageMarker.streamingAssistantHostMessageID
            result.append(message)
          }
        }
        if chunk["type"]?.string == "reasoning-delta", let delta = chunk["text"]?.string {
          if result.last?.role == .assistant,
             result.last?.hostMessageId == DSHTranscriptMessageMarker.streamingAssistantHostMessageID {
            result[result.count - 1].reasoning = (result[result.count - 1].reasoning ?? "") + delta
          } else {
            var message = Message(role: .assistant, text: "", timestamp: Date(timeIntervalSince1970: event.time / 1000))
            message.reasoning = delta
            message.hostMessageId = DSHTranscriptMessageMarker.streamingAssistantHostMessageID
            result.append(message)
          }
        }
      case "tool/call":
        let name = data["name"]?.string ?? "tool"
        let id = data["callId"]?.string ?? "\(event.seq)"
        tools[id] = ToolActivity(callId: id, name: name, summary: "工具调用", state: .running, output: "", presentation: historyPresentation(entry.view))
        toolSequences[id] = event.seq
        result.append(Message(role: .tool, text: name, timestamp: Date(timeIntervalSince1970: event.time / 1000), toolCallId: id))
      case "tool/result":
        guard let result = DSHToolResultDecoder.history(from: data),
              var tool = tools[result.callId] else { continue }
        tool.state = result.isError ? .failed : .succeeded
        let resultPresentation = historyPresentation(entry.view)
        tool.presentation = ToolPresentation.merging(
          call: tool.presentation,
          result: resultPresentation,
          rawOutput: result.output)
        tool.output = tool.presentation?.output?.nonEmpty
          ?? result.output.nonEmpty
          ?? result.errorSummary
          ?? "工具已完成"
        if let errorSummary = result.errorSummary, !errorSummary.isEmpty {
          tool.summary = errorSummary
        }
        tools[result.callId] = tool
        toolSequences[result.callId] = event.seq
      case "todo/write":
        if let todos = data["todos"]?.array { result.append(Message(role: .system, text: "任务清单更新：\(todos.count) 项")) }
      case "turn/end":
        break
      default:
        continue
      }
    }
    return DSHFoldedHistory(
      messages: result,
      tools: Array(tools.values),
      toolSequences: toolSequences)
  }

  private func reasoningFromMessage(_ value: DSHJSONValue?) -> String? {
    guard let object = value?.object, let content = object["content"]?.array else { return nil }
    let text = content.compactMap { block -> String? in guard let data = block.object, data["type"]?.string == "reasoning" else { return nil }; return data["text"]?.string }.joined()
    return text.isEmpty ? nil : text
  }

  private func historyPresentation(_ view: DSHJSONValue?) -> ToolPresentation? {
    ToolPresentation.fromEventView(view)
  }

  private func textFromMessage(_ value: DSHJSONValue?) -> String? {
    guard let object = value?.object, let content = object["content"]?.array else { return nil }
    return content.compactMap { block in
      guard let data = block.object, data["type"]?.string == "text" else { return nil }
      return data["text"]?.string
    }.joined()
  }

  /// The session log stores message fields directly on the event data
  /// (`{content, id, role, source}`); some emitters nest them under
  /// `message`. Accept both — the nested lookup alone silently dropped
  /// every flat-shaped user message from reloaded history.
  private func historyMessage(_ data: [String: DSHJSONValue]) -> DSHJSONValue {
    if let nested = data["message"], nested.object != nil { return nested }
    return .object(data)
  }

  /// `source.kind` of a message event: "user" is real typed input; the
  /// Host also logs user-*role* context injections (agent-instructions,
  /// plugin snapshots, skill catalogs, skill invocations) that are model
  /// plumbing and must never render as conversation bubbles.
  private func messageSourceKind(_ value: DSHJSONValue) -> String? {
    value.object?["source"]?.object?["kind"]?.string
  }

  /// History-replay counterpart of `liveIsRelayMessage(_:)` — same
  /// `source.kind`/`source.plugin` check over the `DSHJSONValue` shape.
  private func historyIsRelayMessage(_ value: DSHJSONValue) -> Bool {
    messageSourceKind(value) == "plugin" && value.object?["source"]?.object?["plugin"]?.string == "session-relay"
  }

  /// Display text of a user message: the outgoing first prompt carries the
  /// machine-facing workspace-context appendix (send() appends it after a
  /// blank line) — the transcript shows the message as typed, so cut from
  /// the marker on. Matched by marker only: the appendix wording has
  /// already changed once and stored sessions keep the old phrasing.
  func userDisplayText(_ text: String) -> String {
    guard let range = text.range(of: "\n\n[工作区上下文]") else { return text }
    return String(text[..<range.lowerBound])
  }

  private func anyValue(_ value: DSHJSONValue) -> Any {
    switch value {
    case .string(let x): return x
    case .number(let x): return x
    case .bool(let x): return x
    case .null: return NSNull()
    case .array(let x): return x.map(anyValue)
    case .object(let x): return Dictionary(uniqueKeysWithValues: x.map { ($0.key, anyValue($0.value)) })
    }
  }

  private func textFromValue(_ value: DSHJSONValue?) -> String? {
    guard let value else { return nil }
    switch value {
    case .string(let text): return text
    case .object(let object):
      if let content = object["content"]?.array { return content.compactMap { $0.object?["text"]?.string }.joined() }
      return object["text"]?.string
    default: return nil
    }
  }
}
