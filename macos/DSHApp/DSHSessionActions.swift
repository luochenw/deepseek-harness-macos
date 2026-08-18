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

  /// "新会话" / ⌘N：只回到默认页，不创建任何东西——会话（本地行 +
  /// Host 持久会话）一律等第一条消息发出时由 send() 懒创建。用户反馈
  /// 点按钮就冒出一个空会话仍然是"直接新增"，与启动自动建会话是
  /// 同一个问题。
  func newSession() {
    clearToDefaultPage()
    status = "输入内容即可开始新会话"
  }

  /// The local sidebar row + selection reset for the lazy first-send path
  /// (which needs the row without the fire-and-forget attach so it can
  /// sequence the send after the Host session exists).
  func insertLocalSessionRow() {
    let session = Session(title: "新会话", workspaceName: workspaceName, updatedAt: Date(), messages: [
      Message(role: .system, text: "正在创建持久 DSH 会话…")
    ])
    sessions.insert(session, at: 0)
    selectedSessionID = session.id
    selectedTool = nil
    activeSubagentAddress = nil
    subagentPath = []
    subagentTranscript = nil
    selectedWorkflowRunID = nil
  }

  /// Back to the launch default page: nothing selected, empty-state hero in
  /// the conversation pane, and the next send lazily creates a fresh session.
  /// Every session-scoped global resets too — a blank new conversation used
  /// to keep the previous session's running flag (stop button, blocked
  /// send) and usage figures.
  private func clearToDefaultPage() {
    hostCurrentSessionID = nil
    selectedSessionID = nil
    selectedTool = nil
    activeSubagentAddress = nil
    subagentPath = []
    subagentTranscript = nil
    selectedWorkflowRunID = nil
    isRunning = false
    todos = []
    hostPlanActive = false
    goal = nil
    tokenUsage = nil
    contextPressure = nil
    sessionStats = nil
    queueItems = []
    runNotice = nil
    retryNotice = nil
  }

  /// Create the persistent Host session backing the currently-selected local
  /// row. Sole caller: `send()`'s lazy first-message path, which passes
  /// `onComplete` to sequence the actual send after the Host session is bound.
  func attachHostSessionToCurrentPlaceholder(onComplete: ((Bool) -> Void)? = nil) {
    guard let hostClient else { onComplete?(false); return }
    let cwd = workspace?.path
    let presetId = pendingHostPresetID ?? (preset == .creator ? "cordis" : preset.rawValue)
    // Capture the composer's advertised selection before hopping off the main
    // actor — `session.create` takes no model, so without an explicit
    // `session.selectModel` right after, the Host silently runs its own
    // config default (`agent-default-model` in the app-scoped DSH home) while
    // the composer label keeps showing this local state. That mismatch is
    // exactly the "picked GPT-5.6 Terra, Host errored about
    // ark/deepseek-v4-flash" bug — see the composer-consolidation Agent Note.
    let (chosenProvider, chosenModel) = (provider, model)
    // Clamped, not raw `reasoningEffort`: pushing a level the model never
    // advertised (the stored "high" against an effort-less relay model) would
    // fail the whole selectModel call and leave the session on the config
    // default — the very bug this push exists to fix.
    let chosenEffort = advertisedEffort(provider: provider, model: model, requested: reasoningEffort)
    Task {
      do {
        let created = try await hostClient.createSession(cwd: cwd, agentPreset: presetId)
        await MainActor.run {
          self.hostCurrentSessionID = created.sessionId
          if let index = self.selectedSessionIndex {
            self.sessions[index].hostSessionId = created.sessionId
            self.sessions[index].messages = [Message(role: .system, text: "已连接到持久 DSH 会话。")]}
          self.refreshHostSnapshots()
        }
        if !chosenProvider.isEmpty, !chosenModel.isEmpty {
          do {
            try await hostClient.selectModel(sessionId: created.sessionId, provider: chosenProvider, model: chosenModel, reasoningEffort: chosenEffort)
          } catch {
            await MainActor.run { self.appendSystem("新会话未能应用所选模型（\(chosenProvider) / \(chosenModel)）：\(error.localizedDescription)") }
          }
        }
        // Sync back from the Host either way so the composer label reflects
        // the session's real model, not an unconfirmed local wish.
        await MainActor.run { self.refreshSessionModels(); onComplete?(true) }
      } catch {
        await MainActor.run {
          self.appendSystem("持久会话创建失败：\(error.localizedDescription)")
          onComplete?(false)
        }
      }
    }
  }

  func selectSession(_ id: UUID) {
    selectedSessionID = id
    if let index = sessions.firstIndex(where: { $0.id == id }) {
      sessions[index].hasUnread = false
      // The global flag follows the selected row — a placeholder row
      // switched to while another session runs must not inherit its state.
      isRunning = sessions[index].isRunning
    }
  }

  func openHostSession(_ summary: DSHSessionSummary) {
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
    queueItems = []  // repopulated by this session's own queue push
    runNotice = nil
    retryNotice = nil
    loadSubagents(parentSessionId: summary.sessionId)
    refreshSessionModels()
    loadSkills(sessionId: summary.sessionId)
    loadCommands(sessionId: summary.sessionId)
    loadMessageFeedback(sessionId: summary.sessionId)
  }
}
