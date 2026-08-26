import Foundation


struct DSHGoalRef: Codable { let id: String; let revision: Int }
struct DSHGoalActionPayload: Encodable { let sessionId: String; let ref: DSHGoalRef }
struct DSHGoalActionResult: Decodable { let ref: DSHGoalRef }

/// goal.create / goal.edit payloads, mirroring `GoalsApi` in
/// dsh-host-apiproxy `lib/types/api/goals.d.ts`:
/// create takes `{ sessionId, objective, maxGoalRounds? }`, edit takes
/// `{ sessionId, ref, objective?, maxGoalRounds? }`. Both acknowledge with
/// the new CAS ref only — the committed goal reaches the client through the
/// `goal` session projection, so responses never feed local state.
struct DSHGoalCreatePayload: Encodable { let sessionId: String; let objective: String; let maxGoalRounds: Int? }
struct DSHGoalEditPayload: Encodable { let sessionId: String; let ref: DSHGoalRef; let objective: String?; let maxGoalRounds: Int? }

extension DSHHostClient {
  func createGoal(sessionId: String, objective: String, maxGoalRounds: Int? = nil) async throws -> DSHGoalRef {
    try await call("goal.create", payload: DSHGoalCreatePayload(sessionId: sessionId, objective: objective, maxGoalRounds: maxGoalRounds), as: DSHGoalActionResult.self).ref
  }

  func editGoal(sessionId: String, ref: DSHGoalRef, objective: String? = nil, maxGoalRounds: Int? = nil) async throws -> DSHGoalRef {
    try await call("goal.edit", payload: DSHGoalEditPayload(sessionId: sessionId, ref: ref, objective: objective, maxGoalRounds: maxGoalRounds), as: DSHGoalActionResult.self).ref
  }
}

extension HarnessController {
  /// Creates and arms a goal on the current persistent session. The RPC
  /// response only acknowledges the CAS ref; the committed goal arrives via
  /// the `goal` projection frame, so nothing is written locally here.
  func createGoal(text: String) {
    let objective = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !objective.isEmpty, canMutateDisplayedGoal,
          let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task {
      do {
        _ = try await hostClient.createGoal(sessionId: sessionId, objective: objective)
        await MainActor.run { self.status = "目标已设定"; self.refreshHostSnapshots() }
      } catch { await MainActor.run { self.status = "目标创建失败：\(error.localizedDescription)" } }
    }
  }

  /// Edits the current goal's objective and/or round cap without changing
  /// its phase, CAS-guarded by the projected revision.
  func editGoal(objective: String? = nil, maxGoalRounds: Int? = nil) {
    guard objective != nil || maxGoalRounds != nil,
          canMutateDisplayedGoal,
          let hostClient, let sessionId = hostCurrentSessionID,
          let current = goal?.goal else { return }
    Task {
      do {
        _ = try await hostClient.editGoal(sessionId: sessionId, ref: DSHGoalRef(id: current.id, revision: current.revision), objective: objective, maxGoalRounds: maxGoalRounds)
        await MainActor.run { self.status = "目标已更新"; self.refreshHostSnapshots() }
      } catch { await MainActor.run { self.status = "目标编辑失败：\(error.localizedDescription)" } }
    }
  }
}

// MARK: - Host plan mode（/plan 斜杠命令）

extension HarnessController {
  /// Enters host-side plan mode. Plan mode is driven by the plugin-owned
  /// `/plan` command: a session.prompt whose content is exactly one text
  /// block starting with "/" is dispatched through the Host's command
  /// registry (mode-agnostic) and never reaches the model. The committed
  /// flip comes back as the `plan` projection (`hostPlanActive`); while the
  /// agent is running the Host holds the selection pending until the next
  /// accepted pre-step, so the flag may flip with a delay.
  func enterPlanMode() { guard canMutateDisplayedPlan else { return }; sendPlanCommand("/plan", label: "进入计划模式") }

  /// Exits host-side plan mode directly: dsh-plan-mode reserves the exact
  /// argument `off`, selecting inactive without sending model input（also
  /// cancelling a still-pending entry）. The reviewed `exit_plan_mode` tool
  /// path is the model-driven alternative and needs nothing from the client.
  func exitPlanMode() { guard canMutateDisplayedPlan else { return }; sendPlanCommand("/plan off", label: "退出计划模式") }

  private func sendPlanCommand(_ command: String, label: String) {
    guard let hostClient, let sessionId = hostCurrentSessionID else {
      status = "没有持久会话，无法\(label)"
      return
    }
    Task {
      do {
        try await hostClient.prompt(sessionId: sessionId, text: command)
        await MainActor.run { self.status = "已请求\(label)" }
      } catch { await MainActor.run { self.status = "\(label)失败：\(error.localizedDescription)" } }
    }
  }
}

extension HarnessController {
  func performGoalAction(_ action: String) {
    guard canMutateDisplayedGoal,
          let hostClient, let sessionId = hostCurrentSessionID,
          let state = goal, let goal = state.goal else { return }
    Task {
      do {
        try await hostClient.goalAction(action, sessionId: sessionId, goalId: goal.id, revision: goal.revision)
        await MainActor.run { self.status = "目标操作已提交：\(action)"; self.refreshHostSnapshots() }
      } catch { await MainActor.run { self.appendSystem("目标操作失败：\(error.localizedDescription)") } }
    }
  }


  static func alwaysAllowKey(sessionId: String, toolName: String) -> String { "\(sessionId)::\(toolName)" }

  func answerApproval(_ approval: PendingApproval, allowed: Bool, alwaysThisSession: Bool = false) {
    guard let hostClient else { return }
    // Validate against the specific item the sheet was showing, not just
    // whatever is currently `pendingApproval` — a queued backlog item can
    // promote into that slot between the sheet rendering and the click
    // landing (mirrors `answerQuestionBatch`'s id check below).
    if pendingApproval?.id == approval.id { pendingApproval = queuedApprovals.isEmpty ? nil : queuedApprovals.removeFirst() }
    else { queuedApprovals.removeAll { $0.id == approval.id } }
    refreshAttentionBadge()
    if allowed && alwaysThisSession { alwaysAllowedTools.insert(Self.alwaysAllowKey(sessionId: approval.sessionId, toolName: approval.toolName)) }
    Task {
      do {
        try await hostClient.respond(rpcId: approval.rpcId, value: DSHApprovalAnswer(sessionId: approval.sessionId, approvalId: approval.id, outcome: allowed ? "allowed-once" : "rejected"))
        await MainActor.run { self.appendSystem(allowed ? "已允许 \(approval.toolName) 执行一次。" : "已拒绝 \(approval.toolName)。") }
      } catch { await MainActor.run { self.appendSystem("审批响应失败：\(error.localizedDescription)") } }
    }
  }

  /// Moves the currently-shown question to the back of the backlog instead
  /// of discarding it — the old "取消" button submitted an empty answer,
  /// silently dropping the question. Pulls the next queued one (if any)
  /// into view; `presentDeferredQuestion()` recalls a deferred one later.
  func deferPendingQuestion(_ question: PendingQuestion) {
    guard pendingQuestion?.id == question.id else { return }
    let next = queuedQuestions.isEmpty ? nil : queuedQuestions.removeFirst()
    queuedQuestions.append(question)
    pendingQuestion = next
  }

  func presentDeferredQuestion() {
    guard pendingQuestion == nil, !queuedQuestions.isEmpty else { return }
    pendingQuestion = queuedQuestions.removeFirst()
  }

  func answerQuestionBatch(_ question: PendingQuestion, selections: [String: String], custom: [String: String]) {
    guard let hostClient else { return }
    if pendingQuestion?.id == question.id { pendingQuestion = queuedQuestions.isEmpty ? nil : queuedQuestions.removeFirst() }
    else { queuedQuestions.removeAll { $0.id == question.id } }
    refreshAttentionBadge()
    var answers: [DSHQuestionAnswer.Item] = []
    for item in question.items {
      let selectedValue = selections[item.id] ?? ""
      let selected = selectedValue.isEmpty ? [] : [selectedValue]
      let customValue = custom[item.id] ?? ""
      answers.append(DSHQuestionAnswer.Item(id: item.id, selected: selected, custom: customValue.isEmpty ? nil : customValue))
    }
    Task {
      do {
        try await hostClient.respond(rpcId: question.rpcId, value: DSHQuestionAnswer(sessionId: question.sessionId, answer: answers))
        await MainActor.run { self.appendSystem("已提交 Agent 问题回答。") }
      } catch {
        await MainActor.run { self.appendSystem("问题回答失败") }
      }
    }
  }
  /// Applied from a live `session/projection` "title" push — the Host may
  /// derive/rename a session's title mid-turn (e.g. from the first prompt).
  func applyProjectedTitle(_ title: String) {
    guard !title.isEmpty, let index = selectedSessionIndex else { return }
    sessions[index].title = title
  }

  /// Drops the menu-bar "needs attention" badge once nothing is left
  /// waiting for an answer — called after every approval/question
  /// resolution, whether answered locally or settled by another client.
  func refreshAttentionBadge() {
    if pendingApproval == nil && pendingQuestion == nil { nativeAlerts.clearAttention() }
  }

  // Internal, not private: the workspace chips (NativeWorkspaceChips.swift)
  // surface git checkout/worktree outcomes through the same channel.
  func appendSystem(_ text: String) {
    guard let index = selectedSessionIndex else { return }
    sessions[index].messages.append(Message(role: .system, text: text))
    sessions[index].updatedAt = Date()
  }
}
