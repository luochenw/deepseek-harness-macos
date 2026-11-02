import Foundation

/// State behind the child-session cards: one pending decision per tool call id,
/// the decisions already taken, and the delegations the user confirmed up front.
///
/// `main.swift` is frozen, so this lives in the transcript domain and is held
/// by the controller's `stateBag` rather than as stored `@Published` state.
@MainActor
final class DSHChildSessionPromptState: ObservableObject {
  struct Request: Identifiable {
    let callId: String
    let sessionId: String
    let toolName: String
    let description: String
    /// The child's task text, exactly as the model wrote it.
    let prompt: String
    let approval: HarnessController.PendingApproval
    var id: String { callId }
  }

  /// Unanswered requests, keyed by tool call id so two cards in one turn cannot
  /// read each other's approval.
  @Published private(set) var requests: [String: Request] = [:]
  @Published private(set) var decisions: [String: DSHChildSessionDecision] = [:]
  /// `sessionId → task text` for delegations the user already confirmed through
  /// the 新建 entry. Not a standing grant: it is consumed by one matching ask.
  @Published private(set) var delegatedTasks: [String: String] = [:]

  func request(_ callId: String) -> Request? { requests[callId] }

  func decision(_ callId: String) -> DSHChildSessionDecision? { decisions[callId] }

  var hasPendingRequest: Bool { !requests.isEmpty }

  /// Whether this approval belongs to a delegation the user already confirmed.
  /// Exact text match only: a reworded task is a different task.
  func shouldAutoApprove(sessionId: String, prompt: String) -> Bool {
    guard let task = delegatedTasks[sessionId] else { return false }
    return prompt == task
  }

  func noteDelegation(sessionId: String, task: String) {
    delegatedTasks[sessionId] = task
  }

  /// One confirmation covers one call.
  func clearDelegation(sessionId: String) {
    delegatedTasks[sessionId] = nil
  }

  func add(_ request: Request) {
    requests[request.callId] = request
    decisions[request.callId] = nil
  }

  func take(_ callId: String) -> Request? {
    requests.removeValue(forKey: callId)
  }

  func retract(approvalId: String) {
    guard let callId = requests.first(where: { $0.value.approval.id == approvalId })?.key else { return }
    requests[callId] = nil
  }

  func record(_ decision: DSHChildSessionDecision, for callId: String) {
    requests[callId] = nil
    decisions[callId] = decision
  }
}

extension HarnessController {
  var childSessionPrompts: DSHChildSessionPromptState {
    stateBag.state { DSHChildSessionPromptState() }
  }

  /// Route one approval coming from the Host: child-session requests become a
  /// transcript card, everything else keeps the existing sheet.
  ///
  /// `request` is the raw approval payload, which carries the model's own label
  /// and task text next to the fields the Host logs.
  func queueApproval(_ approval: PendingApproval, request: [String: Any]) {
    guard DSHChildSessionCard.isChildSessionTool(approval.toolName), let callId = approval.callId else {
      if pendingApproval == nil { pendingApproval = approval } else { queuedApprovals.append(approval) }
      nativeAlerts.notifyApprovalNeeded(toolName: approval.toolName)
      return
    }
    let prompt = request["prompt"] as? String ?? ""
    // The 新建 entry's delegation was confirmed when the user pressed send.
    if childSessionPrompts.shouldAutoApprove(sessionId: approval.sessionId, prompt: prompt) {
      childSessionPrompts.clearDelegation(sessionId: approval.sessionId)
      Task { try? await hostEvents?.eventResult(eventID: approval.rpcId, value: "allowed-once") }
      return
    }
    let label = request["description"] as? String ?? ""
    childSessionPrompts.add(DSHChildSessionPromptState.Request(
      callId: callId,
      sessionId: approval.sessionId,
      toolName: approval.toolName,
      description: label,
      prompt: prompt,
      approval: approval))
    nativeAlerts.notifyApprovalNeeded(toolName: approval.toolName)
  }

  /// Answer a card's pending approval. `allowed` starts the child session;
  /// otherwise the Host refuses the call and the model continues here.
  func answerChildSessionApproval(callId: String, allowed: Bool) {
    guard let request = childSessionPrompts.take(callId) else { return }
    childSessionPrompts.record(allowed ? .allowed : .declined, for: callId)
    refreshAttentionBadge()
    Task {
      do {
        try await hostEvents?.eventResult(
          eventID: request.approval.rpcId,
          value: allowed ? "allowed-once" : "rejected")
        await MainActor.run {
          self.appendSystem(allowed ? "已允许新开子会话。" : "已选择在当前会话完成。")
        }
      } catch {
        await MainActor.run {
          // The Host is still waiting: bring the buttons back so it can be retried.
          self.childSessionPrompts.add(request)
          self.refreshAttentionBadge()
          self.appendSystem("审批响应失败：\(error.localizedDescription)")
        }
      }
    }
  }

  /// Open the child session a card stands for, through the same parent-first
  /// path the sidebar rows use.
  func openChildSessionFromCard(childSessionId: String) {
    guard let child = hostSessions.first(where: { $0.sessionId == childSessionId }) else {
      status = "子会话还没有出现在会话列表里"
      return
    }
    openSidebarSubagent(child)
  }
}
