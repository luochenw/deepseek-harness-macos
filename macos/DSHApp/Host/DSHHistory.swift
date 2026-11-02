import Foundation


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

enum DSHHistoryLoadError: LocalizedError {
  case cursorDidNotAdvance

  var errorDescription: String? {
    switch self {
    case .cursorDidNotAdvance:
      return "Host 返回了更多历史，但分页游标没有前进"
    }
  }
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

extension HarnessController {
  private var rootHistoryLoadState: DSHRootHistoryLoadState {
    stateBag.state { DSHRootHistoryLoadState(controller: self) }
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
      rootScope.workflowLog = cachedRootHistoryWorkflows(sessionID: sessionId) ?? DSHWorkflowLog()
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
          // Same rule as a follow snapshot: a page smaller than what is already
          // displayed is a partial view of the log, not a correction. Folding it
          // in keeps the rows (and the scroll position) instead of collapsing
          // the transcript and letting it grow back.
          self.sessions[index].messages = DSHHistoryPageMerge.applyFollowSnapshot(
            folded.messages,
            to: self.sessions[index].messages,
            isComplete: !page.hasMore)
          self.sessions[index].turnStartedAt = folded.activeTurnStartedAt
          self.reconcileRootSessionRunningState(
            sessionID: sessionId,
            localSessionID: localSessionID,
            running: folded.activeTurnStartedAt != nil)
          self.sessions[index].isLoadingHistory = page.hasMore
          self.activeTools = DSHToolActivityMerge.preservingDetails(
            incoming: folded.tools,
            previous: self.activeTools)
          self.recordWorkflowHistory(folded, sessionID: sessionId)
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
            self.recordWorkflowHistory(older, sessionID: sessionId)
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
    DSHReplayTimelineStore.fold(entries)
  }
}
