import Foundation

extension HarnessController {
  /// Snapshot and list responses are the recovery boundary for missed turn
  /// boundaries. Keep the row, sidebar summary, and displayed root flag in
  /// lockstep so a reconnect cannot leave the composer stuck on Stop.
  func reconcileRootSessionRunningState(
    sessionID: String,
    localSessionID: UUID,
    running: Bool
  ) {
    if let hostIndex = hostSessions.firstIndex(where: { $0.sessionId == sessionID }) {
      hostSessions[hostIndex].running = running
    }
    guard let sessionIndex = sessions.firstIndex(where: { $0.id == localSessionID }) else {
      return
    }
    sessions[sessionIndex].isRunning = running
    guard hostCurrentSessionID == sessionID,
          selectedSessionID == localSessionID
    else { return }
    isRunning = running
  }

  /// `session/cancel` accepts the request even for an idle Agent. Since an
  /// idle Agent emits no new `turn/end`, use a short bounded list reconciliation
  /// to release a stale local running flag.
  func reconcileRootSessionAfterStop(sessionID: String, localSessionID: UUID) {
    guard let hostClient else { return }
    Task {
      let delays: [UInt64] = [0, 150_000_000, 350_000_000, 750_000_000, 1_500_000_000]
      for delay in delays {
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        guard !Task.isCancelled else { return }
        guard let summaries = try? await hostClient.sessions(),
              let summary = summaries.first(where: { $0.sessionId == sessionID })
        else { continue }
        guard !summary.running else { continue }
        await MainActor.run {
          self.reconcileRootSessionRunningState(
            sessionID: sessionID,
            localSessionID: localSessionID,
            running: false)
          if self.hostCurrentSessionID == sessionID,
             self.selectedSessionID == localSessionID {
            self.status = "本轮已停止"
          }
        }
        return
      }
    }
  }

  func resetRootSessionPresentationState() {
    activeTools = []
    subagents = []
    skills = []
    workflows = []
    selectedWorkflowRunID = nil
    hostCommands = []
    messageFeedback = [:]
    todos = []
    hostPlanActive = false
    goal = nil
    tokenUsage = nil
    contextPressure = nil
    sessionStats = nil
    queueItems = []
    runNotice = nil
    retryNotice = nil
    currentSessionModels = nil
    resetAgentSessionState()
  }

  /// "新会话" / ⌘N only returns to the default page. The first submitted
  /// message or Agent Batch lazily creates the durable Host session.
  func newSession() {
    clearToDefaultPage()
    status = "输入内容即可开始新会话"
  }

  @discardableResult
  func insertLocalSessionRow() -> UUID {
    // Not `workspaceName`: its no-workspace fallback is the header CTA
    // label "无工作区", which would read as this row's folder name.
    let session = Session(title: "新会话", workspaceName: workspace?.lastPathComponent ?? "未指定工作区", updatedAt: Date(), messages: [
      Message(role: .system, text: "正在创建持久 DSH 会话…")
    ])
    sessions.insert(session, at: 0)
    selectedSessionID = session.id
    migrateDefaultWorkbenchContext(to: session.id)
    invalidateRootHistoryRequests()
    invalidateSubagentPresentationLoad()
    activeSubagentAddress = nil
    subagentPath = []
    subagentTranscript = nil
    selectedWorkflowRunID = nil
    return session.id
  }

  func clearToDefaultPage() {
    pauseWorkbenchMedia()
    invalidateRootHistoryRequests()
    invalidateSubagentPresentationLoad()
    resetRootSessionPresentationState()
    hostCurrentSessionID = nil
    selectedSessionID = nil
    activeSubagentAddress = nil
    subagentPath = []
    subagentTranscript = nil
    isRunning = false
  }

  /// Bind Host creation to one exact local row. Session switching while the
  /// RPC is in flight cannot redirect its result or errors to another row.
  func attachHostSessionToPlaceholder(localSessionID: UUID, onComplete: ((String?) -> Void)? = nil) {
    guard let hostClient else { onComplete?(nil); return }
    let cwd = workspace?.path
    let presetId = pendingHostPresetID.map(Self.canonicalHostPresetID) ?? preset.hostPresetID
    let (chosenProvider, chosenModel) = (provider, model)
    let chosenEffort = advertisedEffort(provider: provider, model: model, requested: reasoningEffort)
    Task {
      do {
        let created = try await hostClient.createSession(cwd: cwd, agentPreset: presetId)
        await MainActor.run {
          if let index = self.sessions.firstIndex(where: { $0.id == localSessionID }) {
            self.sessions[index].hostSessionId = created.sessionId
            self.sessions[index].messages = [Message(role: .system, text: "已连接到持久 DSH 会话。")]
          }
          self.migrateWorkbenchContext(localSessionID: localSessionID, hostSessionID: created.sessionId)
          if self.selectedSessionID == localSessionID {
            self.hostCurrentSessionID = created.sessionId
            self.startRootSessionFollow(
              sessionID: created.sessionId,
              localSessionID: localSessionID)
          }
          self.refreshHostSnapshots()
        }
        if !chosenProvider.isEmpty, !chosenModel.isEmpty {
          do {
            try await hostClient.selectModel(
              sessionId: created.sessionId,
              provider: chosenProvider,
              model: chosenModel,
              reasoningEffort: chosenEffort)
          } catch {
            await MainActor.run {
              self.appendSystem(
                "新会话未能应用所选模型（\(chosenProvider) / \(chosenModel)）：\(error.localizedDescription)",
                to: localSessionID)
            }
          }
        }
        await MainActor.run {
          if self.selectedSessionID == localSessionID { self.refreshSessionModels() }
          onComplete?(created.sessionId)
        }
      } catch {
        await MainActor.run {
          self.appendSystem("持久会话创建失败：\(error.localizedDescription)", to: localSessionID)
          onComplete?(nil)
        }
      }
    }
  }

  func selectSession(_ id: UUID) {
    pauseWorkbenchMedia()
    invalidateRootHistoryRequests()
    invalidateSubagentPresentationLoad()
    if selectedSessionID != id { resetRootSessionPresentationState() }
    activeSubagentAddress = nil
    subagentPath = []
    subagentTranscript = nil
    selectedSessionID = id
    if let index = sessions.firstIndex(where: { $0.id == id }) {
      hostCurrentSessionID = sessions[index].hostSessionId
      sessions[index].hasUnread = false
      isRunning = sessions[index].isRunning
    }
  }
}
