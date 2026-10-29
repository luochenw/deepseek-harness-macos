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
  var bool: Bool? { if case let .bool(value) = self { value } else { nil } }
  var array: [DSHJSONValue]? { if case let .array(value) = self { value } else { nil } }
  var integer: Int? {
    guard case let .number(value) = self else { return nil }
    return Int(exactly: value)
  }
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

enum DSHHistoryPagination {
  static let pageSize = 500

  static func oldestSeq(in records: [DSHHistoryEntry]) -> Int? {
    records.map(\.event.seq).min()
  }

  static func advances(currentOldest: Int, pageOldest: Int?) -> Bool {
    guard let pageOldest else { return false }
    return pageOldest < currentOldest
  }
}

enum DSHHistoryLoadingPolicy {
  static let watchdogNanoseconds: UInt64 = 15_000_000_000
}

struct DSHHistoryCacheVersion: Equatable {
  let sequence: Int?
  let updatedAt: Double?
}

enum DSHHistoryCachePolicy {
  static func canReuse(
    cached: DSHHistoryCacheVersion?,
    hostSequence: Int?,
    hostUpdatedAt: Double,
    hasMessages: Bool
  ) -> Bool {
    guard hasMessages, let cached else { return false }
    if let sequence = cached.sequence, let hostSequence {
      return sequence >= hostSequence
    }
    guard let updatedAt = cached.updatedAt else { return false }
    return updatedAt >= hostUpdatedAt
  }
}

enum DSHHistoryPageMerge {
  static func prepend(
    _ olderMessages: [HarnessController.Message],
    to currentMessages: [HarnessController.Message]
  ) -> [HarnessController.Message] {
    guard !olderMessages.isEmpty else { return currentMessages }
    let currentIDs = Set(currentMessages.map(\.id))
    return olderMessages.filter { !currentIDs.contains($0.id) } + currentMessages
  }

  /// Merge a follow snapshot's recent tail into an already visible transcript.
  /// Existing row UUIDs are retained so LazyVStack identities and scroll
  /// anchors stay stable while reconnect repair runs in the background.
  static func mergeTail(
    _ incomingMessages: [HarnessController.Message],
    into currentMessages: [HarnessController.Message]
  ) -> [HarnessController.Message] {
    var merged = currentMessages
    for incoming in incomingMessages {
      if let index = merged.firstIndex(where: { sameRow($0, incoming) }) {
        var updated = merged[index]
        updated.text = incoming.text
        updated.timestamp = incoming.timestamp
        if let attachment = incoming.attachment { updated.attachment = attachment }
        if let reasoning = incoming.reasoning { updated.reasoning = reasoning }
        if let hostMessageId = incoming.hostMessageId { updated.hostMessageId = hostMessageId }
        if let toolCallId = incoming.toolCallId { updated.toolCallId = toolCallId }
        updated.isRelayMessage = incoming.isRelayMessage
        merged[index] = updated
      } else {
        merged.append(incoming)
      }
    }
    return merged
  }

  private static func sameRow(
    _ existing: HarnessController.Message,
    _ incoming: HarnessController.Message
  ) -> Bool {
    if let existingKey = durableKey(existing),
       let incomingKey = durableKey(incoming) {
      return existingKey == incomingKey
    }
    if matchesPendingEcho(existing, incoming) || matchesPendingEcho(incoming, existing) {
      return true
    }
    return contentKey(existing) == contentKey(incoming)
  }

  private static func durableKey(_ message: HarnessController.Message) -> String? {
    if let hostID = message.hostMessageId {
      if hostID == DSHTranscriptMessageMarker.streamingAssistantHostMessageID {
        return "streaming-assistant"
      }
      if hostID == DSHTranscriptMessageMarker.pendingLocalUserHostMessageID {
        return nil
      }
      if !hostID.isEmpty { return "host:\(hostID)" }
    }
    if let callID = message.toolCallId, !callID.isEmpty {
      return "tool:\(callID)"
    }
    return nil
  }

  private static func matchesPendingEcho(
    _ pending: HarnessController.Message,
    _ durable: HarnessController.Message
  ) -> Bool {
    pending.hostMessageId == DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
      && pending.role == .user
      && durable.role == .user
      && pending.text == durable.text
      && pending.attachment?.attachmentId == durable.attachment?.attachmentId
  }

  private static func contentKey(_ message: HarnessController.Message) -> String {
    let millis = Int((message.timestamp.timeIntervalSince1970 * 1_000).rounded())
    return [
      String(describing: message.role),
      message.text,
      message.attachment?.attachmentId ?? "",
      message.toolCallId ?? "",
      String(millis),
    ].joined(separator: "\u{1f}")
  }
}

enum DSHHistoryLoadError: LocalizedError {
  case cursorDidNotAdvance

  var errorDescription: String? {
    switch self {
    case .cursorDidNotAdvance:
      return "Host 返回了更多历史，但分页游标没有前进"
    }
  }
}

struct DSHFoldedHistory {
  let messages: [HarnessController.Message]
  let tools: [HarnessController.ToolActivity]
  let toolSequences: [String: Int]
  let activeTurnStartedAt: Date?
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

  func loadHistory(summary: DSHSessionSummary, localSessionID: UUID) {
    let sessionId = summary.sessionId
    let cached = cachedRootHistoryVersion(sessionID: sessionId)
    let hasMessages = sessions.first(where: { $0.id == localSessionID })
      .map { !$0.messages.isEmpty } ?? false
    let reuseCache = DSHHistoryCachePolicy.canReuse(
      cached: cached,
      hostSequence: summary.projections?.asOfSeq,
      hostUpdatedAt: summary.updatedAt,
      hasMessages: hasMessages)
    if let index = sessions.firstIndex(where: { $0.id == localSessionID }) {
      sessions[index].isLoadingHistory = !reuseCache
    }
    if reuseCache {
      activeTools = cachedRootHistoryTools(sessionID: sessionId) ?? []
      status = "已从本地缓存恢复会话"
    }
    startRootSessionFollow(
      sessionID: sessionId,
      localSessionID: localSessionID,
      preservingCachedHistory: reuseCache)
    scheduleHistoryPageFallback(sessionId: sessionId, localSessionID: localSessionID)
  }

  private func scheduleHistoryLoadingWatchdog(
    sessionID: String,
    localSessionID: UUID,
    generation: Int
  ) {
    Task {
      try? await Task.sleep(nanoseconds: DSHHistoryLoadingPolicy.watchdogNanoseconds)
      self.expireHistoryLoadingIfNeeded(
        sessionID: sessionID,
        localSessionID: localSessionID,
        generation: generation)
    }
  }

  @discardableResult
  func expireHistoryLoadingIfNeeded(
    sessionID: String,
    localSessionID: UUID,
    generation: Int
  ) -> Bool {
    guard acceptsRootHistoryRequest(
      sessionID: sessionID,
      localSessionID: localSessionID,
      generation: generation),
      let index = sessions.firstIndex(where: { $0.id == localSessionID }),
      sessions[index].isLoadingHistory
    else { return false }
    sessions[index].isLoadingHistory = false
    status = "会话历史仍在后台补齐，当前内容已可继续使用"
    return true
  }

  private func scheduleHistoryPageFallback(sessionId: String, localSessionID: UUID) {
    guard let hostClient else { return }
    guard let throughSeq = hostSessions.first(where: { $0.sessionId == sessionId })?
      .projections?.asOfSeq else {
      if let index = sessions.firstIndex(where: { $0.id == localSessionID }) {
        sessions[index].isLoadingHistory = false
      }
      hostStatus = "会话历史加载失败：缺少可用的历史游标"
      return
    }
    let generation = beginRootHistoryRequest(
      sessionID: sessionId,
      localSessionID: localSessionID)
    scheduleHistoryLoadingWatchdog(
      sessionID: sessionId,
      localSessionID: localSessionID,
      generation: generation)
    Task {
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      let shouldLoad = await MainActor.run {
        self.acceptsRootHistoryRequest(
          sessionID: sessionId,
          localSessionID: localSessionID,
          generation: generation)
          && self.rootSessionFollowCursor == nil
          && !self.isPreservingCachedRootHistory(sessionID: sessionId)
      }
      guard shouldLoad else { return }
      do {
        let page = try await hostClient.sessionPage(
          sessionId: sessionId,
          throughSeq: throughSeq,
          beforeSeq: nil,
          maxMessages: DSHHistoryPagination.pageSize)
        let folded = foldHistoryContent(page.records)
        await MainActor.run {
          guard self.acceptsRootHistoryRequest(
            sessionID: sessionId,
            localSessionID: localSessionID,
            generation: generation),
            self.rootSessionFollowCursor == nil,
            let index = self.sessions.firstIndex(where: { $0.id == localSessionID })
          else { return }
          self.sessions[index].messages = folded.messages.isEmpty && !page.hasMore
            ? [Message(role: .system, text: "这个会话还没有可显示的消息。")]
            : folded.messages
          self.sessions[index].turnStartedAt = folded.activeTurnStartedAt
          self.reconcileRootSessionRunningState(
            sessionID: sessionId,
            localSessionID: localSessionID,
            running: folded.activeTurnStartedAt != nil)
          self.sessions[index].isLoadingHistory = page.hasMore
          self.activeTools = DSHToolActivityMerge.preservingDetails(
            incoming: folded.tools,
            previous: self.activeTools)
          let oldest = DSHHistoryPagination.oldestSeq(in: page.records)
          self.status = page.hasMore
            ? "已载入 \(folded.messages.count) 条消息，正在补齐完整历史"
            : "已载入完整会话历史"
          if !page.hasMore {
            self.markRootHistoryComplete(
              sessionID: sessionId,
              throughSeq: throughSeq)
          }
          self.refreshHostSnapshots()
          if page.hasMore {
            guard let oldest else {
              self.sessions[index].isLoadingHistory = false
              self.hostStatus = DSHHistoryLoadError.cursorDidNotAdvance.localizedDescription
              return
            }
            self.loadAllOlderHistory(
              sessionID: sessionId,
              localSessionID: localSessionID,
              throughSeq: throughSeq,
              beforeSeq: oldest)
          }
        }
      } catch {
        await MainActor.run {
          guard self.acceptsRootHistoryRequest(
            sessionID: sessionId,
            localSessionID: localSessionID,
            generation: generation) else { return }
          if let index = self.sessions.firstIndex(where: { $0.id == localSessionID }) {
            self.sessions[index].isLoadingHistory = false
          }
          self.hostStatus = "会话历史加载失败：\(error.localizedDescription)"
        }
      }
    }
  }

  /// `session/page` stays bounded, but the UI owns the complete transcript.
  /// Fetch every page in sequence and expose one loading state to the user.
  func loadAllOlderHistory(
    sessionID sessionId: String,
    localSessionID: UUID,
    throughSeq: Int,
    beforeSeq: Int,
    showsProgress: Bool = true,
    replaceVisibleOnCompletion: Bool = false,
    replacementSeed: [Message] = [],
    replacementTools: [ToolActivity] = []
  ) {
    guard let hostClient else { return }
    if let index = sessions.firstIndex(where: { $0.id == localSessionID }) {
      sessions[index].isLoadingHistory = showsProgress
    }
    let generation = beginRootHistoryRequest(
      sessionID: sessionId,
      localSessionID: localSessionID)
    scheduleHistoryLoadingWatchdog(
      sessionID: sessionId,
      localSessionID: localSessionID,
      generation: generation)
    Task {
      var before = beforeSeq
      var hasMore = true
      var repairedMessages = replacementSeed
      var repairedTools = replacementTools
      do {
        while hasMore {
          let page = try await hostClient.sessionPage(
            sessionId: sessionId,
            throughSeq: throughSeq,
            beforeSeq: before,
            maxMessages: DSHHistoryPagination.pageSize)
          guard acceptsRootHistoryRequest(
            sessionID: sessionId,
            localSessionID: localSessionID,
            generation: generation)
          else {
            if let index = sessions.firstIndex(where: { $0.id == localSessionID }) {
              sessions[index].isLoadingHistory = false
            }
            return
          }
          if page.records.isEmpty {
            guard page.hasMore else {
              hasMore = false
              break
            }
            throw DSHHistoryLoadError.cursorDidNotAdvance
          }
          let pageOldest = DSHHistoryPagination.oldestSeq(in: page.records)
          guard DSHHistoryPagination.advances(
            currentOldest: before,
            pageOldest: pageOldest),
            let pageOldest
          else { throw DSHHistoryLoadError.cursorDidNotAdvance }
          let older = foldHistoryContent(page.records)
          let applied = await MainActor.run {
            guard self.acceptsRootHistoryRequest(
              sessionID: sessionId,
              localSessionID: localSessionID,
              generation: generation),
              let index = self.sessions.firstIndex(where: { $0.id == localSessionID })
            else { return false }
            if replaceVisibleOnCompletion {
              repairedMessages = DSHHistoryPageMerge.prepend(
                older.messages,
                to: repairedMessages)
              repairedTools.append(contentsOf: older.tools)
            } else {
              self.sessions[index].messages = DSHHistoryPageMerge.prepend(
                older.messages,
                to: self.sessions[index].messages)
              for tool in older.tools
              where !self.activeTools.contains(where: { $0.callId == tool.callId }) {
                self.activeTools.append(tool)
              }
            }
            self.sessions[index].isLoadingHistory =
              showsProgress && !replaceVisibleOnCompletion && page.hasMore
            self.status = page.hasMore
              ? "已显示最近内容，正在继续补齐更早历史"
              : "已载入完整会话历史"
            return true
          }
          guard applied else { return }
          before = pageOldest
          hasMore = page.hasMore
        }
        await MainActor.run {
          guard self.acceptsRootHistoryRequest(
            sessionID: sessionId,
            localSessionID: localSessionID,
            generation: generation)
          else { return }
          guard let index = self.sessions.firstIndex(where: { $0.id == localSessionID }) else { return }
          if replaceVisibleOnCompletion, !repairedMessages.isEmpty {
            self.sessions[index].messages = DSHHistoryPageMerge.mergeTail(
              self.sessions[index].messages,
              into: repairedMessages)
            for tool in repairedTools
            where !self.activeTools.contains(where: { $0.callId == tool.callId }) {
              self.activeTools.append(tool)
            }
          } else if self.sessions[index].messages.isEmpty {
            self.sessions[index].messages = [
              Message(role: .system, text: "这个会话还没有可显示的消息。")
            ]
          }
          self.sessions[index].isLoadingHistory = false
          self.status = "已载入完整会话历史"
          self.markRootHistoryComplete(
            sessionID: sessionId,
            throughSeq: throughSeq)
        }
      } catch {
        await MainActor.run {
          guard self.acceptsRootHistoryRequest(
            sessionID: sessionId,
            localSessionID: localSessionID,
            generation: generation)
          else { return }
          if let index = self.sessions.firstIndex(where: { $0.id == localSessionID }) {
            self.sessions[index].isLoadingHistory = false
          }
          self.hostStatus = "完整会话历史加载失败：\(error.localizedDescription)"
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
    var activeTurnStartedAt: Double?
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
      case "assistant/chunk", "text-chunks", "reasoning-chunks":
        // Some adapters log only the stream and some interrupted sessions
        // never produce a final assistant message. Fold every supported
        // stream shape so reloading does not erase the response.
        guard let delta = DSHAssistantStreamProjection.history(eventType: event.type, data: data) else { continue }
        if result.last?.role == .assistant,
           result.last?.hostMessageId == DSHTranscriptMessageMarker.streamingAssistantHostMessageID {
          DSHAssistantStreamProjection.append(delta, to: &result[result.count - 1])
        } else {
          result.append(DSHAssistantStreamProjection.createMessage(
            from: delta,
            timestamp: Date(timeIntervalSince1970: event.time / 1000)))
        }
      case "tool/call":
        let name = data["name"]?.string ?? "tool"
        let id = data["callId"]?.string ?? "\(event.seq)"
        let presentation = historyPresentation(entry.view)
          ?? ToolPresentation.fromHistoryToolCall(name: name, arguments: data["arguments"])
        tools[id] = ToolActivity(
          callId: id,
          name: name,
          summary: "工具调用",
          state: .running,
          output: "",
          arguments: DSHToolArguments.history(data["arguments"]),
          presentation: presentation)
        toolSequences[id] = event.seq
        result.append(Message(role: .tool, text: name, timestamp: Date(timeIntervalSince1970: event.time / 1000), toolCallId: id))
      case "tool/ptc-dispatch-start", "tool/code-dispatch-start":
        guard let subcall = DSHSubcallDecoder.history(from: data),
              var tool = tools[subcall.rootCallId] else { continue }
        tool.startChild(subcall)
        tools[subcall.rootCallId] = tool
      case "tool/ptc-dispatch", "tool/code-dispatch":
        guard let subcall = DSHSubcallDecoder.history(from: data),
              var tool = tools[subcall.rootCallId] else { continue }
        let failed = data["isError"]?.bool == true
        let output = DSHSubcallDecoder.output(from: data["content"])
        tool.finishChild(
          subcall,
          output: output,
          failed: failed,
          imageAttachments: DSHAttachmentRef.fromHistoryContent(
            data["content"]?.array ?? []))
        tools[subcall.rootCallId] = tool
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
        tool.imageAttachments = result.imageAttachments
        if let errorSummary = result.errorSummary, !errorSummary.isEmpty {
          tool.summary = errorSummary
        }
        tools[result.callId] = tool
        toolSequences[result.callId] = event.seq
      case "todo/write":
        if let todos = data["todos"]?.array { result.append(Message(role: .system, text: "任务清单更新：\(todos.count) 项")) }
      case "command/run":
        let sourceKind = data["source"]?.object?["kind"]?.string
        if sourceKind == nil || sourceKind == "user",
           let name = data["name"]?.string,
           !name.isEmpty {
          let args = data["args"]?.string ?? ""
          result.append(Message(
            role: .user,
            text: "/\(name)\(args)",
            timestamp: Date(timeIntervalSince1970: event.time / 1000)))
        }
      case "command/done":
        if let text = data["text"]?.string, !text.isEmpty {
          let failed = data["kind"]?.string != "success"
          result.append(Message(
            role: .system,
            text: failed ? "命令失败：\(text)" : text,
            timestamp: Date(timeIntervalSince1970: event.time / 1000)))
        }
      case "compaction/summary":
        let summary = data["summary"]?.string
        result.append(Message(
          role: .system,
          text: summary.map { "历史上下文已压缩。摘要：\($0)" } ?? "历史上下文已压缩。",
          timestamp: Date(timeIntervalSince1970: event.time / 1000)))
      case "turn/start":
        activeTurnStartedAt = event.time
      case "turn/end":
        for id in tools.keys where tools[id]?.state == .running {
          tools[id]?.state = .succeeded
        }
        let reason = data["reason"]?.object
        switch reason?["kind"]?.string {
        case "error":
          let detail = reason?["error"]?.object?["message"]?.string
          let text = detail.flatMap { $0.isEmpty ? nil : "本轮执行失败：\($0)" }
            ?? "本轮执行失败"
          result.append(Message(
            role: .system,
            text: text,
            timestamp: Date(timeIntervalSince1970: event.time / 1000)))
        case "aborted", "interrupted":
          result.append(Message(
            role: .system,
            text: "本轮已中断",
            timestamp: Date(timeIntervalSince1970: event.time / 1000)))
        case "max-tokens":
          result.append(Message(
            role: .system,
            text: "本轮达到最大输出 token 限制",
            timestamp: Date(timeIntervalSince1970: event.time / 1000)))
        default:
          break
        }
        if let start = activeTurnStartedAt {
          let duration = max(0, event.time - start)
          result.append(Message(
            role: .system,
            text: "本轮用时 \(DSHTurnTiming.label(duration))",
            timestamp: Date(timeIntervalSince1970: event.time / 1000)))
        }
        activeTurnStartedAt = nil
      default:
        continue
      }
    }
    return DSHFoldedHistory(
      messages: result,
      tools: Array(tools.values),
      toolSequences: toolSequences,
      activeTurnStartedAt: DSHTurnTiming.date(from: activeTurnStartedAt))
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

  func anyValue(_ value: DSHJSONValue) -> Any {
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
