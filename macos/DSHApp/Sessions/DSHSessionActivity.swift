import Foundation

/// Sessions the Host has reported as running. Only the open root session and an
/// open subagent are followed, so for every other session these status changes
/// are the only signal there is.
@MainActor
private final class DSHSessionActivityState {
  var runningSessions: Set<String> = []
  /// Counts status events, so a list requested before one cannot overrule it.
  var statusEpoch = 0
  var lastStatusEpoch: [String: Int] = [:]
  var listRequests = 0
  var appliedListRequest = 0
  /// Bumped when Host streams restart; status events from the gap are lost.
  var streamGeneration = 0
  /// Sessions this app prompted that have not been seen running yet, by the stream
  /// generation of the prompt.
  var promptedSessions: [String: Int] = [:]
  /// Errors from sessions with no row yet, shown once the session is opened.
  var pendingErrors: [String: [String]] = [:]
}

/// What a session list request saw when it was sent.
struct DSHSessionListTicket {
  let number: Int
  let statusEpoch: Int
  let streamGeneration: Int
}

extension HarnessController {
  private var sessionActivityState: DSHSessionActivityState {
    stateBag.state { DSHSessionActivityState() }
  }

  var sessionStatusEpoch: Int { sessionActivityState.statusEpoch }

  func beginSessionListRequest() -> DSHSessionListTicket {
    let activity = sessionActivityState
    activity.listRequests += 1
    return DSHSessionListTicket(
      number: activity.listRequests,
      statusEpoch: activity.statusEpoch,
      streamGeneration: activity.streamGeneration)
  }

  /// Responses can arrive out of order; only one newer than the last applied counts.
  func acceptSessionList(_ request: DSHSessionListTicket) -> Bool {
    let activity = sessionActivityState
    // A list requested before a reconnect describes the old streams.
    guard request.streamGeneration == activity.streamGeneration,
          request.number > activity.appliedListRequest
    else { return false }
    activity.appliedListRequest = request.number
    return true
  }

  /// A summary's running flag is as old as its request; a status event since then is newer.
  func applyingNewerStatus(
    to summaries: [DSHSessionSummary],
    since request: DSHSessionListTicket
  ) -> [DSHSessionSummary] {
    let activity = sessionActivityState
    return summaries.map { summary in
      guard activity.lastStatusEpoch[summary.sessionId, default: 0] > request.statusEpoch else { return summary }
      var current = summary
      current.running = activity.runningSessions.contains(summary.sessionId)
      return current
    }
  }

  /// A prompt this app sent may sit queued before its turn starts, so it does not
  /// count as running. It lets a list finish the session only after a reconnect, when
  /// every status of its run may have been lost.
  func noteSessionStarted(_ sessionID: String) {
    let activity = sessionActivityState
    activity.promptedSessions[sessionID] = activity.streamGeneration
  }

  /// Host streams restarted: statuses from the gap are lost, lists requested before it
  /// are stale, and a crashed Host may come back with lower sequences.
  func noteHostStreamsRestarted() {
    sessionActivityState.streamGeneration += 1
    relaxPermissionWatermarks()
  }

  func applyRemoteSessionStatus(sessionID: String, running: Bool) {
    if let index = hostSessions.firstIndex(where: { $0.sessionId == sessionID }) {
      hostSessions[index].running = running
    }
    if let index = sessions.firstIndex(where: { $0.hostSessionId == sessionID }) {
      reconcileRootSessionRunningState(
        sessionID: sessionID,
        localSessionID: sessions[index].id,
        running: running)
      if !running && sessionID != hostCurrentSessionID {
        sessions[index].hasUnread = true
      }
    }
    let activity = sessionActivityState
    activity.statusEpoch += 1
    activity.lastStatusEpoch[sessionID] = activity.statusEpoch
    if running {
      activity.runningSessions.insert(sessionID)
      activity.promptedSessions[sessionID] = nil
    } else if activity.runningSessions.remove(sessionID) != nil {
      sessionDidFinish(sessionID)
    }
    nativeAlerts.recomputeBadge()
  }

  /// A list response is the recovery path for a status event lost during a
  /// reconnect. A session the list does not mention stays tracked, because a fresh
  /// session can start before the list that includes it arrives, and a status newer
  /// than the list's request wins over what the list says.
  func reconcileSessionActivity(with summaries: [DSHSessionSummary], request: DSHSessionListTicket) {
    let activity = sessionActivityState
    for summary in summaries where activity.lastStatusEpoch[summary.sessionId, default: 0] <= request.statusEpoch {
      if summary.running {
        activity.runningSessions.insert(summary.sessionId)
        activity.promptedSessions[summary.sessionId] = nil
      } else if activity.runningSessions.remove(summary.sessionId) != nil {
        sessionDidFinish(summary.sessionId)
      } else if let prompted = activity.promptedSessions[summary.sessionId], request.streamGeneration > prompted {
        activity.promptedSessions[summary.sessionId] = nil
        sessionDidFinish(summary.sessionId)
      }
    }
    nativeAlerts.recomputeBadge()
  }

  /// The one place a finished run is announced, open or not, so no ordering of
  /// `turn/end` and status can announce it twice. Children report through their parent.
  private func sessionDidFinish(_ sessionID: String) {
    if let label = voiceTaskSessions.removeValue(forKey: sessionID) {
      nativeAlerts.notifyTurnFinished(summary: "语音任务完成：\(label)。点击查看会话列表。")
      refreshHostSnapshots()
      return
    }
    let summary = hostSessions.first { $0.sessionId == sessionID }
    guard summary?.parentSessionId == nil,
          let title = summary?.title ?? sessions.first(where: { $0.hostSessionId == sessionID })?.title
    else { return }
    nativeAlerts.notifyTurnFinished(summary: title)
  }

  /// The Host keys errors by agent, so they land in that session rather than in
  /// whichever one happens to be open.
  func reportSessionError(sessionID: String, message: String) {
    let text = "DSH Host 错误：\(message)"
    if activeSubagentAddress?.childSessionId == sessionID {
      subagentTranscript?.messages.append(Message(role: .system, text: text))
    } else if sessionID == hostCurrentSessionID, rootSessionFollowCursor != nil,
              let row = sessions.first(where: { $0.hostSessionId == sessionID }) {
      appendSystem(text, to: row.id)
    } else {
      // Not on screen, or its history is still loading and would replace the row.
      sessionActivityState.pendingErrors[sessionID, default: []].append(text)
      status = "\(requestSourceDescription(sessionID: sessionID))：\(message)"
    }
  }

  /// Called once an opened session's follow snapshot has replaced its rows.
  func deliverPendingSessionErrors(sessionID: String, localSessionID: UUID) {
    guard let errors = sessionActivityState.pendingErrors.removeValue(forKey: sessionID) else { return }
    for text in errors { appendSystem(text, to: localSessionID) }
  }

  func deliverPendingSubagentErrors(sessionID: String) {
    guard let errors = sessionActivityState.pendingErrors.removeValue(forKey: sessionID) else { return }
    for text in errors { subagentTranscript?.messages.append(Message(role: .system, text: text)) }
  }

  /// Names the session behind an approval, question or error.
  func requestSourceDescription(sessionID: String) -> String {
    if activeSubagentAddress?.childSessionId == sessionID, let title = subagentTranscript?.title {
      return "来自子代理：\(title)"
    }
    if let child = subagents.first(where: { $0.id == sessionID }) {
      return "来自子代理：\(child.label ?? "未命名")"
    }
    let title = hostSessions.first { $0.sessionId == sessionID }?.title
      ?? sessions.first { $0.hostSessionId == sessionID }?.title
    guard let title else { return "来自后台任务" }
    return sessionID == hostCurrentSessionID ? "来自当前会话：\(title)" : "来自其他会话：\(title)"
  }
}
