import Foundation

extension HarnessController {
  /// "新会话" / ⌘N only returns to the default page. The first submitted
  /// message or Agent Batch lazily creates the durable Host session.
  func newSession() {
    clearToDefaultPage()
    status = "输入内容即可开始新会话"
  }

  @discardableResult
  func insertLocalSessionRow() -> UUID {
    // Not `workspaceName`: its no-workspace fallback is the header CTA
    // label "选择工作区", which would read as this row's folder name.
    let session = Session(title: "新会话", workspaceName: workspace?.lastPathComponent ?? "未指定工作区", updatedAt: Date(), messages: [
      Message(role: .system, text: "正在创建持久 DSH 会话…")
    ])
    sessions.insert(session, at: 0)
    selectedSessionID = session.id
    selectedTool = nil
    invalidateRootHistoryRequests()
    invalidateSubagentPresentationLoad()
    activeSubagentAddress = nil
    subagentPath = []
    subagentTranscript = nil
    selectedWorkflowRunID = nil
    return session.id
  }

  func clearToDefaultPage() {
    invalidateRootHistoryRequests()
    invalidateSubagentPresentationLoad()
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
    resetAgentSessionState()
  }

  /// Bind Host creation to one exact local row. Session switching while the
  /// RPC is in flight cannot redirect its result or errors to another row.
  func attachHostSessionToPlaceholder(localSessionID: UUID, onComplete: ((String?) -> Void)? = nil) {
    guard let hostClient else { onComplete?(nil); return }
    let cwd = workspace?.path
    let presetId = pendingHostPresetID ?? (preset == .creator ? "cordis" : preset.rawValue)
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
          if self.selectedSessionID == localSessionID {
            self.hostCurrentSessionID = created.sessionId
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
    invalidateRootHistoryRequests()
    invalidateSubagentPresentationLoad()
    activeSubagentAddress = nil
    subagentPath = []
    subagentTranscript = nil
    selectedSessionID = id
    if let index = sessions.firstIndex(where: { $0.id == id }) {
      sessions[index].hasUnread = false
      isRunning = sessions[index].isRunning
    }
  }
}
