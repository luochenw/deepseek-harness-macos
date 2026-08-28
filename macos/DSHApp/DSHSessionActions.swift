import Foundation
import AppKit

struct DSHRenameSessionPayload: Encodable { let sessionId: String; let title: String }
struct DSHRenameSessionResult: Decodable { let title: String; let seq: Int }
struct DSHForkSessionPayload: Encodable { let sessionId: String }
struct DSHForkSessionResult: Decodable { let sessionId: String }
struct DSHArchiveSessionPayload: Encodable { let sessionId: String }
struct DSHArchiveSessionResult: Decodable { let archivedSessionIds: [String] }

extension HarnessController {
  func searchSessions(_ query: String) {
    guard let hostClient else { return }
    let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    guard !trimmed.isEmpty else { searchResults = []; searchHasMore = false; return }
    Task {
      do {
        let result = try await hostClient.searchSessions(query: trimmed)
        await MainActor.run { self.searchResults = result.items; self.searchHasMore = result.hasMore }
      } catch { await MainActor.run { self.status = "会话搜索失败：\(error.localizedDescription)" } }
    }
  }

  func openHostSessionID(_ id: String) {
    guard let summary = hostSessions.first(where: { $0.sessionId == id }) else { return }
    openHostSession(summary)
  }




  func beginRenameCurrentSession() {
    renameDraft = selectedSession?.title ?? ""
    showRenameSession = hostCurrentSessionID != nil
  }

  func renameCurrentSession() {
    let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let hostClient, let sessionId = hostCurrentSessionID, !title.isEmpty else { return }
    Task {
      do {
        let accepted = try await hostClient.renameSession(sessionId, title: title)
        await MainActor.run {
          if let index = self.selectedSessionIndex { self.sessions[index].title = accepted }
          self.showRenameSession = false
          self.refreshHostSnapshots()
        }
      } catch { await MainActor.run { self.appendSystem("重命名失败：\(error.localizedDescription)") } }
    }
  }

  func forkCurrentSession() {
    guard let sessionId = hostCurrentSessionID else { return }
    forkSession(sessionId)
  }

  /// Codex-style fork: branch any listed session and jump straight into the
  /// new branch (the original stays untouched in the list).
  func forkSession(_ sessionId: String) {
    guard let hostClient else { return }
    Task {
      do {
        let childID = try await hostClient.forkSession(sessionId)
        await MainActor.run {
          self.refreshHostSnapshots()
          self.status = "已创建会话分支"
          self.openHostSessionID(childID)
        }
      } catch { await MainActor.run { self.appendSystem("创建分支失败：\(error.localizedDescription)") } }
    }
  }

  func copySessionID(_ sessionId: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(sessionId, forType: .string)
    status = "会话 ID 已复制"
  }

  /// "删除" from the sidebar. The Host protocol has no destructive delete —
  /// archive is its sanctioned removal (event log retained, hidden from
  /// every grouping surface); the archived-sessions view stays the recovery
  /// path. A deleted current session is replaced with a fresh one.
  func deleteSession(_ sessionId: String) {
    guard let hostClient else { return }
    Task {
      do {
        try await hostClient.archiveSession(sessionId)
        await MainActor.run {
          self.status = "会话已删除（可在归档中找回）"
          if self.hostCurrentSessionID == sessionId { self.clearToDefaultPage() }
          self.refreshHostSnapshots()
        }
      } catch { await MainActor.run { self.appendSystem("删除会话失败：\(error.localizedDescription)") } }
    }
  }

  func archiveCurrentSession() {
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task {
      do {
        try await hostClient.archiveSession(sessionId)
        await MainActor.run {
          self.status = "会话已归档"
          self.refreshHostSnapshots()
          self.clearToDefaultPage()
        }
      } catch { await MainActor.run { self.appendSystem("归档会话失败：\(error.localizedDescription)") } }
    }
  }

  func openHostSession(_ summary: DSHSessionSummary) {
    invalidateRootHistoryRequests()
    invalidateSubagentPresentationLoad()
    hostCurrentSessionID = summary.sessionId
    activeSubagentAddress = nil
    subagentPath = []
    subagentTranscript = nil
    selectedWorkflowRunID = nil
    // Durable host-id match first; the legacy title+workspace pair only
    // rescues rows created before the id existed (renames broke it).
    if let existing = sessions.firstIndex(where: { $0.hostSessionId == summary.sessionId })
      ?? sessions.firstIndex(where: { $0.hostSessionId == nil && $0.title == summary.title && $0.workspaceName == (summary.cwd ?? "") }) {
      sessions[existing].hostSessionId = summary.sessionId
      sessions[existing].hasUnread = false
      selectedSessionID = sessions[existing].id
      // Re-selecting an already-open row previously kept every
      // session-scoped global (running flag, usage strip, todos, goal,
      // queue…) from whichever session was displayed before — the composer
      // wore the old session's state on the new one. The row's own flag
      // wins over the snapshot: mux turn events keep it fresher.
      syncSessionScopedState(from: summary, rowRunning: sessions[existing].isRunning)
      return
    }
    let local = Session(
      title: summary.title,
      workspaceName: summary.cwd ?? "未指定工作区",
      updatedAt: Date(timeIntervalSince1970: summary.updatedAt / 1000),
      messages: [Message(role: .system, text: "已打开持久 DSH 会话。历史事件、工具、审批与子代理将从 Host 流同步。")],
      isRunning: summary.running,
      hostSessionId: summary.sessionId,
    )
    sessions.insert(local, at: 0)
    selectedSessionID = local.id
    syncSessionScopedState(from: summary, rowRunning: summary.running)
    status = summary.running ? "持久会话正在运行" : "正在载入持久会话"
    loadHistory(sessionId: summary.sessionId, localSessionID: local.id)
  }

  /// Session-scoped globals follow the displayed session. Attaching to a
  /// mid-turn session (relaunch, sidebar switch) must arm the *global*
  /// running flag — the composer's stop button and the transcript tail
  /// animation read it, and only a local send() used to set it.
  private func syncSessionScopedState(from summary: DSHSessionSummary, rowRunning: Bool) {
    isRunning = rowRunning || summary.running
    todos = summary.projections?.values.todos ?? []
    hostPlanActive = summary.projections?.values.plan?.active ?? false
    goal = summary.projections?.values.goal
    tokenUsage = summary.projections?.values.tokenUsage
    contextPressure = summary.projections?.values.contextPressure
    sessionStats = summary.projections?.values.sessionStats
    rememberPermissionSelection(
      summary.projections?.values.permissions,
      sessionID: summary.sessionId,
      seq: summary.projections?.asOfSeq ?? -1)
    restoreRootQueue(sessionID: summary.sessionId)
    runNotice = nil
    retryNotice = nil
    loadSubagents(parentSessionId: summary.sessionId)
    refreshSessionModels()
    loadSkills(sessionId: summary.sessionId)
    loadCommands(sessionId: summary.sessionId)
    loadMessageFeedback(sessionId: summary.sessionId)
    refreshAgentBatches(rootSessionId: summary.sessionId)
  }
}
