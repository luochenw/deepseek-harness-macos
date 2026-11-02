import Foundation

/// Fixed delegation template behind the dashboard's 新建子会话 entry.
///
/// The task text is spliced in verbatim: the main session is told to hand it
/// to the new child unchanged, so trimming or re-wrapping it here would
/// silently rewrite the user's brief before the child ever sees it.
enum DSHNewChildDelegation {
  static let emptyTag = "由你根据任务起一个短标签"

  static func canSubmit(task: String) -> Bool {
    !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func tag(_ label: String) -> String {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? emptyTag : trimmed
  }

  static func instruction(task: String, label: String) -> String {
    [
      "【委派】请用 subagent 工具开一个全新的子会话（标签：\(tag(label))），把下面「任务」部分原样作为它的任务，一个字都不要改；你自己不要做这个任务，开完子会话就结束这一步。",
      "任务：",
      task,
    ].joined(separator: "\n")
  }

  /// An idle session takes a normal (queue) prompt; a running one needs
  /// `steer` so the delegation lands in its next step instead of waiting for
  /// the current turn to end.
  static func mode(running: Bool) -> DSHPromptMode {
    running ? .steer : .queue
  }
}

extension HarnessController {
  /// True only for a live top-level session. The entry disappears on the blank
  /// default page (no Host session yet) and while a child is open, so the card
  /// never offers a delegation that could only fail.
  var canCreateChildSession: Bool {
    hostCurrentSessionID != nil && subagentPath.isEmpty && activeSubagentAddress == nil
  }

  /// Returns false when nothing was sent, so the popover keeps the typed task
  /// instead of closing on a rejection the user never saw.
  @discardableResult
  func delegateNewChildSession(task: String, label: String) -> Bool {
    guard DSHNewChildDelegation.canSubmit(task: task) else { return false }
    guard canCreateChildSession else {
      rejectNewChildSession("只能在主会话里新建子会话")
      return false
    }
    guard let hostClient, let sessionId = hostCurrentSessionID else {
      rejectNewChildSession("Host 未连接，无法委派子会话")
      return false
    }
    // Root `isRunning`, not `displayedIsRunning`: the prompt goes to the root
    // session, so the same session must answer "is it running".
    let mode = DSHNewChildDelegation.mode(running: isRunning)
    let instruction = DSHNewChildDelegation.instruction(task: task, label: label)
    // The user confirmed this delegation by pressing send, so the child-session
    // gate must not ask again: record the exact task text the model is told to
    // hand over, and a matching approval is answered automatically.
    childSessionPrompts.noteDelegation(sessionId: sessionId, task: task)
    Task {
      do {
        try await hostClient.prompt(sessionId: sessionId, text: instruction, mode: mode)
        await MainActor.run {
          guard self.hostCurrentSessionID == sessionId else { return }
          self.status = mode == .steer ? "已插话委派新子会话" : "已把委派交给主会话"
          self.noteDelegation(self.status, of: sessionId)
        }
      } catch {
        await MainActor.run {
          // Nothing was delegated, so the confirmation must not stay armed.
          self.childSessionPrompts.clearDelegation(sessionId: sessionId)
          guard self.hostCurrentSessionID == sessionId else { return }
          self.status = "委派子会话失败：\(error.localizedDescription)"
          self.noteDelegation(self.status, of: sessionId)
        }
      }
    }
    return true
  }

  /// `status` alone is not a readout — the composer deliberately shows none —
  /// so a refusal also lands in the transcript, where the user is looking.
  private func rejectNewChildSession(_ message: String) {
    status = message
    if let sessionId = hostCurrentSessionID { noteDelegation(message, of: sessionId) }
  }

  private func noteDelegation(_ message: String, of hostSessionID: String) {
    guard let localSessionID = sessions.first(where: { $0.hostSessionId == hostSessionID })?.id else {
      appendSystem(message)
      return
    }
    appendSystem(message, to: localSessionID)
  }
}
