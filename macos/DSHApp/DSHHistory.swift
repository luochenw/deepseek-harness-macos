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
struct DSHHistoryPage: Decodable { let events: [DSHHistoryEntry]; let hasMore: Bool }
struct DSHHistoryPayload: Encodable { let sessionId: String; let beforeSeq: Int?; let maxMessages: Int }

extension HarnessController {
  func loadSkills(sessionId: String) {
    guard let hostClient else { return }
    Task {
      do {
        let result = try await hostClient.skills(sessionId: sessionId)
        await MainActor.run { self.skills = result }
      } catch { await MainActor.run { self.skills = [] } }
    }
  }

  /// Typert-layer session context: the slash-command roster and per-message
  /// feedback state. Both are structurally unreachable over the legacy
  /// ApiProxy layer — see DSHTypertGateway.swift.
  func loadCommands(sessionId: String) {
    guard let hostClient else { return }
    Task { if let commands = try? await hostClient.listCommands(sessionId: sessionId) { await MainActor.run { self.hostCommands = commands } } }
  }

  /// Re-pull the slash palette's two catalogs for the current session.
  /// Fired when the user types the leading `/` so a skill installed (or a
  /// command registered) mid-session shows up without re-attaching — the
  /// native stand-in for the web client's `commands/change` invalidation.
  func refreshSlashCatalog() {
    guard let sessionId = hostCurrentSessionID else { return }
    loadSkills(sessionId: sessionId)
    loadCommands(sessionId: sessionId)
  }

  func loadMessageFeedback(sessionId: String) {
    guard let hostClient else { return }
    Task {
      if let items = try? await hostClient.messageFeedback(sessionId: sessionId) {
        await MainActor.run { self.messageFeedback = Dictionary(uniqueKeysWithValues: items.map { ($0.messageId, $0) }) }
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
    Task {
      do {
        let catalog = try await hostClient.subagents(parentSessionId: parentSessionId)
        await MainActor.run { self.subagents = catalog.entries }
      } catch { await MainActor.run { self.subagents = [] } }
    }
  }

  func loadHistory(sessionId: String, localSessionID: UUID) {
    guard let hostClient else { return }
    Task {
      do {
        let page = try await hostClient.history(sessionId: sessionId)
        let messages = foldHistory(page.events)
        await MainActor.run {
          guard let index = self.sessions.firstIndex(where: { $0.id == localSessionID }) else { return }
          self.sessions[index].messages = messages.isEmpty ? [Message(role: .system, text: "这个会话还没有可显示的消息。")] : messages
          self.historyHasMore = page.hasMore
          self.historyOldestSeq = page.events.map { $0.event.seq }.min()
          self.sessions[index].updatedAt = Date()
          self.status = "已载入 \(messages.count) 条原生会话消息"
        }
      } catch {
        await MainActor.run { self.appendSystem("载入会话历史失败：\(error.localizedDescription)") }
      }
    }
  }

  func loadOlderHistory() {
    guard let hostClient, let sessionId = hostCurrentSessionID, let before = historyOldestSeq, historyHasMore, let index = selectedSessionIndex else { return }
    Task {
      do {
        let page = try await hostClient.history(sessionId: sessionId, beforeSeq: before, maxMessages: 100)
        let older = foldHistory(page.events)
        await MainActor.run {
          self.sessions[index].messages = older + self.sessions[index].messages
          self.historyHasMore = page.hasMore
          self.historyOldestSeq = page.events.map { $0.event.seq }.min() ?? self.historyOldestSeq
        }
      } catch {
        await MainActor.run { self.status = "载入更早消息失败" }
      }
    }
  }
  func foldHistory(_ entries: [DSHHistoryEntry]) -> [Message] {
    var result: [Message] = []
    var tools: [String: ToolActivity] = [:]
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
        if let text = textFromMessage(message) { result.append(Message(role: .user, text: userDisplayText(text), timestamp: Date(timeIntervalSince1970: event.time / 1000), attachment: attachmentFromMessage(message), isRelayMessage: relay)) }
      case "assistant/message":
        let payload = historyMessage(data)
        if let text = textFromMessage(payload) {
          var message = Message(role: .assistant, text: text, timestamp: Date(timeIntervalSince1970: event.time / 1000), attachment: attachmentFromMessage(payload), reasoning: reasoningFromMessage(payload))
          message.hostMessageId = payload.object?["id"]?.string
          // Adapters that stream chunks first may also log the settled
          // message — the settled one is authoritative, so it replaces the
          // chunk accumulation instead of doubling the bubble.
          if result.last?.role == .assistant {
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
          if result.last?.role == .assistant { result[result.count - 1].text += delta }
          else { result.append(Message(role: .assistant, text: delta, timestamp: Date(timeIntervalSince1970: event.time / 1000))) }
        }
        if chunk["type"]?.string == "reasoning-delta", let delta = chunk["text"]?.string {
          if result.last?.role == .assistant {
            result[result.count - 1].reasoning = (result[result.count - 1].reasoning ?? "") + delta
          } else {
            var message = Message(role: .assistant, text: "", timestamp: Date(timeIntervalSince1970: event.time / 1000))
            message.reasoning = delta
            result.append(message)
          }
        }
      case "tool/call":
        let name = data["name"]?.string ?? "tool"
        let id = data["callId"]?.string ?? "\(event.seq)"
        tools[id] = ToolActivity(callId: id, name: name, summary: "工具调用", state: .running, output: "", presentation: historyPresentation(entry.view))
        result.append(Message(role: .tool, text: name, timestamp: Date(timeIntervalSince1970: event.time / 1000), toolCallId: id))
      case "tool/result":
        let id = data["callId"]?.string ?? "\(event.seq)"
        if var tool = tools[id] {
          tool.state = .succeeded
          tool.presentation = historyPresentation(entry.view) ?? tool.presentation
          tool.output = tool.presentation?.output ?? textFromValue(data["result"]) ?? "工具已完成"
          tools[id] = tool
        }
      case "todo/write":
        if let todos = data["todos"]?.array { result.append(Message(role: .system, text: "任务清单更新：\(todos.count) 项")) }
      case "turn/end":
        break
      default:
        continue
      }
    }
    activeTools = Array(tools.values)
    if selectedTool == nil { selectedTool = activeTools.first }
    return result
  }

  private func reasoningFromMessage(_ value: DSHJSONValue?) -> String? {
    guard let object = value?.object, let content = object["content"]?.array else { return nil }
    let text = content.compactMap { block -> String? in guard let data = block.object, data["type"]?.string == "reasoning" else { return nil }; return data["text"]?.string }.joined()
    return text.isEmpty ? nil : text
  }

  private func historyPresentation(_ view: DSHJSONValue?) -> ToolPresentation? {
    guard let object = view?.object, let embedded = object["view"]?.object else { return nil }
    let raw = Dictionary(uniqueKeysWithValues: embedded.map { ($0.key, anyValue($0.value)) })
    return ToolPresentation.from(raw)
  }

  private func attachmentFromMessage(_ value: DSHJSONValue?) -> DSHAttachmentRef? {
    guard let object = value?.object, let content = object["content"]?.array else { return nil }
    for block in content {
      guard let data = block.object, data["type"]?.string == "image", let attachment = data["attachment"]?.object else { continue }
      guard let id = attachment["attachmentId"]?.string, let media = attachment["mediaType"]?.string, let bytes = attachment["bytes"] else { continue }
      let size: Int
      if case let .number(value) = bytes { size = Int(value) } else { continue }
      let width: Int = { if case let .number(v) = attachment["width"] { return Int(v) }; return 0 }()
      let height: Int = { if case let .number(v) = attachment["height"] { return Int(v) }; return 0 }()
      return DSHAttachmentRef(attachmentId: id, mediaType: media, bytes: size, width: width, height: height, name: attachment["name"]?.string)
    }
    return nil
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
