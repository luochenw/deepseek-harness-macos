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
    guard !objective.isEmpty, let hostClient, let sessionId = hostCurrentSessionID else { return }
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
  func enterPlanMode() { sendPlanCommand("/plan", label: "进入计划模式") }

  /// Exits host-side plan mode directly: dsh-plan-mode reserves the exact
  /// argument `off`, selecting inactive without sending model input（also
  /// cancelling a still-pending entry）. The reviewed `exit_plan_mode` tool
  /// path is the model-driven alternative and needs nothing from the client.
  func exitPlanMode() { sendPlanCommand("/plan off", label: "退出计划模式") }

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
