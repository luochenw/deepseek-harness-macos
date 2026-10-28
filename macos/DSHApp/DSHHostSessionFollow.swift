import AppKit
import Foundation

struct DSHSessionAddress: Encodable {
  let kind = "session"
  let sessionId: String
}

struct DSHSessionTurnWindow: Encodable {
  let minMessages: Int
  let minTurns: Int
}

struct DSHSessionPageRequest: Encodable {
  let address: DSHSessionAddress
  let throughSeq: Int
  let beforeSeq: Int?
  let maxMessages: Int
  let turnWindow: DSHSessionTurnWindow
}

struct DSHSessionProjectionsRequest: Encodable {
  let sessionId: String
}

struct DSHSessionPage: Decodable {
  let records: [DSHHistoryEntry]
  let hasMore: Bool
}

struct DSHSessionFollowSnapshot: Decodable {
  struct Header: Decodable {
    let id: String
    let cwd: String?
    let parentSession: String?
    let origin: String?
    let agentPreset: String?
  }

  struct AssistantStream: Decodable {
    struct StreamChunk: Decodable {
      let chunk: DSHJSONValue
    }

    struct ActiveAttempt: Decodable {
      let attemptId: String
      let nextIndex: Int
      let stream: [StreamChunk]?
    }

    let revision: Int
    let activeAttempt: ActiveAttempt?
  }

  let type: String
  let header: Header
  let cursor: Int
  let records: [DSHHistoryEntry]
  let hasMore: Bool
  let projections: DSHSessionProjections?
  let assistantStream: AssistantStream?
}

enum DSHSessionFollowSnapshotDecoder {
  static func decode(_ frame: [String: Any]) -> DSHSessionFollowSnapshot? {
    if let strict = DSHProjectionDecoder.decode(DSHSessionFollowSnapshot.self, from: frame) {
      return strict
    }
    guard frame["type"] as? String == "snapshot",
          let header = frame["header"] as? [String: Any],
          let id = header["id"] as? String,
          let cursor = integer(frame["cursor"]),
          let rawRecords = frame["records"] as? [Any] else { return nil }
    let records = rawRecords.compactMap {
      DSHProjectionDecoder.decode(DSHHistoryEntry.self, from: $0)
    }
    let projections = frame["projections"].flatMap {
      DSHProjectionDecoder.decode(DSHSessionProjections.self, from: $0)
    }
    let assistantStream = frame["assistantStream"].flatMap {
      DSHProjectionDecoder.decode(DSHSessionFollowSnapshot.AssistantStream.self, from: $0)
    }
    return DSHSessionFollowSnapshot(
      type: "snapshot",
      header: .init(
        id: id,
        cwd: header["cwd"] as? String,
        parentSession: header["parentSession"] as? String,
        origin: header["origin"] as? String,
        agentPreset: header["agentPreset"] as? String),
      cursor: cursor,
      records: records,
      hasMore: frame["hasMore"] as? Bool ?? false,
      projections: projections,
      assistantStream: assistantStream)
  }

  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? Double, value.rounded() == value { return Int(value) }
    return nil
  }
}

struct DSHSessionWireEventFrame: Decodable {
  let type: String
  let event: DSHRawEvent
}

struct DSHSessionAssistantStreamEnvelope: Decodable {
  let type: String
  let frame: [String: DSHJSONValue]
}

struct DSHSessionControlBaseline: Decodable {
  struct Baseline: Decodable {
    let asOfSeq: Int
    let values: DSHSessionProjectionValues
    let rawValues: [String: DSHJSONValue]

    private enum CodingKeys: String, CodingKey { case asOfSeq, values }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      asOfSeq = try container.decode(Int.self, forKey: .asOfSeq)
      values = try container.decode(DSHSessionProjectionValues.self, forKey: .values)
      rawValues = try container.decode([String: DSHJSONValue].self, forKey: .values)
    }
  }

  let type: String
  let value: Value

  struct Value: Decodable {
    let projections: [String: Baseline]
  }
}

struct DSHSessionControlProjection: Decodable {
  let type: String
  let sessionId: String
  let key: String
  let value: DSHJSONValue
  let seq: Int
}

extension DSHHostClient {
  func sessionProjections(sessionId: String) async throws -> DSHSessionProjections? {
    try await callOptional(
      "session/projections",
      args: DSHRequestArgsPayload(request: DSHSessionProjectionsRequest(sessionId: sessionId)),
      as: DSHSessionProjections.self)
  }

  func sessionPage(
    sessionId: String,
    throughSeq: Int,
    beforeSeq: Int?,
    maxMessages: Int = 100
  ) async throws -> DSHSessionPage {
    try await call(
      "session/page",
      args: DSHRequestArgsPayload(
        request: DSHSessionPageRequest(
          address: DSHSessionAddress(sessionId: sessionId),
          throughSeq: throughSeq,
          beforeSeq: beforeSeq,
          maxMessages: maxMessages,
          turnWindow: DSHSessionTurnWindow(minMessages: 20, minTurns: 2))),
      as: DSHSessionPage.self)
  }
}

@MainActor
private final class DSHSessionFollowState {
  weak var controller: HarnessController?
  var streamID: String?
  var jobStreamID: String?
  var sessionID: String?
  var localSessionID: UUID?
  var cursor: Int?
  var nextSeq: Int?
  var assistantRevision: Int?
  var assistantAttemptID: String?
  var assistantNextIndex: Int?
  var generation = 0
  var subagentStreams: [String: String] = [:]
  var completedHistoryBySession: [String: DSHHistoryCacheVersion] = [:]
  var completedHistoryToolsBySession: [String: [HarnessController.ToolActivity]] = [:]
  var preservingCachedHistory = false
  var retainingVisibleHistory = false

  init(controller: HarnessController) {
    self.controller = controller
  }
}

@MainActor
private final class DSHSessionFollowRegistry {
  static let shared = DSHSessionFollowRegistry()
  private var states: [ObjectIdentifier: DSHSessionFollowState] = [:]

  func state(for controller: HarnessController) -> DSHSessionFollowState {
    states = states.filter { $0.value.controller != nil }
    let key = ObjectIdentifier(controller)
    if let state = states[key], let owner = state.controller, owner === controller {
      return state
    }
    let state = DSHSessionFollowState(controller: controller)
    states[key] = state
    return state
  }
}

extension HarnessController {
  private var sessionFollowState: DSHSessionFollowState {
    DSHSessionFollowRegistry.shared.state(for: self)
  }

  var rootSessionFollowCursor: Int? { sessionFollowState.cursor }

  func cachedRootHistoryVersion(sessionID: String) -> DSHHistoryCacheVersion? {
    sessionFollowState.completedHistoryBySession[sessionID]
  }

  func cachedRootHistoryTools(sessionID: String) -> [HarnessController.ToolActivity]? {
    sessionFollowState.completedHistoryToolsBySession[sessionID]
  }

  func isPreservingCachedRootHistory(sessionID: String) -> Bool {
    let state = sessionFollowState
    return state.preservingCachedHistory && state.sessionID == sessionID
  }

  func markRootHistoryComplete(sessionID: String, throughSeq: Int) {
    let state = sessionFollowState
    let existing = state.completedHistoryBySession[sessionID]
    let summaryUpdatedAt = hostSessions.first(where: { $0.sessionId == sessionID })?.updatedAt
    state.completedHistoryBySession[sessionID] = DSHHistoryCacheVersion(
      sequence: max(existing?.sequence ?? throughSeq, throughSeq),
      updatedAt: max(
        existing?.updatedAt ?? 0,
        summaryUpdatedAt ?? Date().timeIntervalSince1970 * 1_000))
    if hostCurrentSessionID == sessionID {
      state.completedHistoryToolsBySession[sessionID] = activeTools
    }
  }

  func cancelRootSessionFollow() {
    let state = sessionFollowState
    state.generation += 1
    hostEvents?.cancel(state.streamID)
    hostEvents?.cancel(state.jobStreamID)
    state.streamID = nil
    state.jobStreamID = nil
    state.sessionID = nil
    state.localSessionID = nil
    state.cursor = nil
    state.nextSeq = nil
    state.assistantRevision = nil
    state.assistantAttemptID = nil
    state.assistantNextIndex = nil
    state.preservingCachedHistory = false
    state.retainingVisibleHistory = false
    for streamID in state.subagentStreams.values { hostEvents?.cancel(streamID) }
    state.subagentStreams = [:]
  }

  func replaceSubagentFollow(childSessionID: String, streamID: String) {
    let state = sessionFollowState
    hostEvents?.cancel(state.subagentStreams[childSessionID])
    state.subagentStreams[childSessionID] = streamID
  }

  func startRootSessionFollow(
    sessionID: String,
    localSessionID: UUID,
    preservingCachedHistory: Bool = false,
    retainingVisibleHistory: Bool = false
  ) {
    guard let hostEvents else {
      if let index = sessions.firstIndex(where: { $0.id == localSessionID }) {
        sessions[index].isLoadingHistory = false
      }
      appendSystem("会话流尚未连接，无法打开 \(sessionID)", to: localSessionID)
      return
    }
    invalidateRootHistoryRequests()
    cancelRootSessionFollow()
    let state = sessionFollowState
    state.generation += 1
    let generation = state.generation
    state.sessionID = sessionID
    state.localSessionID = localSessionID
    state.preservingCachedHistory = preservingCachedHistory
    state.retainingVisibleHistory = retainingVisibleHistory
    state.streamID = hostEvents.openSessionFollow(
      sessionID: sessionID,
      onItem: { [weak self] frame in
        self?.consumeRootFollowFrame(
          frame,
          sessionID: sessionID,
          localSessionID: localSessionID,
          generation: generation)
      },
      onEnd: { [weak self] in
        guard let self, self.sessionFollowState.generation == generation else { return }
        self.sessionFollowState.preservingCachedHistory = false
        self.sessionFollowState.retainingVisibleHistory = false
        if let index = self.sessions.firstIndex(where: { $0.id == localSessionID }) {
          self.sessions[index].isLoadingHistory = false
        }
        self.hostStatus = "会话事件流已结束"
      },
      onError: { [weak self] message in
        guard let self, self.sessionFollowState.generation == generation else { return }
        self.sessionFollowState.preservingCachedHistory = false
        self.sessionFollowState.retainingVisibleHistory = false
        if let index = self.sessions.firstIndex(where: { $0.id == localSessionID }) {
          self.sessions[index].isLoadingHistory = false
        }
        self.hostStatus = "会话事件流失败：\(message)"
      })
    state.jobStreamID = hostEvents.openJobList(
      sessionID: sessionID,
      onItem: { [weak self] frame in
        guard let jobs = frame["jobs"] as? [[String: Any]] else { return }
        self?.consumeMuxFrame(["type": "session/jobs", "sessionId": sessionID, "jobs": jobs])
      },
      onEnd: {},
      onError: { [weak self] message in self?.hostStatus = "后台任务流失败：\(message)" })
  }

  func openSessionControl() {
    _ = hostEvents?.openSessionControl(
      onItem: { [weak self] frame in self?.consumeSessionControlFrame(frame) },
      onEnd: { [weak self] in self?.hostStatus = "会话控制流已结束" },
      onError: { [weak self] message in self?.hostStatus = "会话控制流失败：\(message)" })
  }

  func consumeSessionControlFrame(_ frame: [String: Any]) {
    guard let type = frame["type"] as? String else { return }
    if type == "projection",
       let projection = DSHProjectionDecoder.decode(DSHSessionControlProjection.self, from: frame) {
      applyProjection(sessionID: projection.sessionId, key: projection.key, value: anyValue(projection.value), seq: projection.seq)
      return
    }
    guard type == "baseline",
          let baseline = DSHProjectionDecoder.decode(DSHSessionControlBaseline.self, from: frame)
    else { return }
    for (sessionID, projection) in baseline.value.projections {
      applyProjectionBaseline(
        sessionID: sessionID,
        values: projection.values,
        rawValues: projection.rawValues,
        seq: projection.asOfSeq)
    }
  }

  private func consumeRootFollowFrame(
    _ frame: [String: Any],
    sessionID: String,
    localSessionID: UUID,
    generation: Int
  ) {
    let state = sessionFollowState
    guard state.generation == generation,
          state.sessionID == sessionID,
          hostCurrentSessionID == sessionID,
          selectedSessionID == localSessionID
    else { return }
    guard let type = frame["type"] as? String else { return }
    switch type {
    case "snapshot":
      guard let snapshot = DSHSessionFollowSnapshotDecoder.decode(frame),
            snapshot.type == "snapshot",
            snapshot.header.id == sessionID,
            let index = sessions.firstIndex(where: { $0.id == localSessionID })
      else {
        if let index = sessions.firstIndex(where: { $0.id == localSessionID }) {
          sessions[index].isLoadingHistory = false
        }
        state.preservingCachedHistory = false
        state.retainingVisibleHistory = false
        hostStatus = "会话快照与请求的 Session 不匹配"
        hostEvents?.cancel(state.streamID)
        return
      }
      let folded = foldHistoryContent(snapshot.records)
      let cached = state.completedHistoryBySession[sessionID]
      let cachedSequence = cached?.sequence
      let preserveCachedHistory = state.preservingCachedHistory
        && !sessions[index].messages.isEmpty
        && (cachedSequence.map { $0 >= snapshot.cursor } ?? (cached?.updatedAt != nil))
      let retainVisibleHistory = state.retainingVisibleHistory
        && !sessions[index].messages.isEmpty
      if preserveCachedHistory || retainVisibleHistory {
        sessions[index].messages = DSHHistoryPageMerge.mergeTail(
          folded.messages,
          into: sessions[index].messages)
      } else {
        sessions[index].messages = folded.messages.isEmpty && !snapshot.hasMore
          ? [Message(role: .system, text: "这个会话还没有可显示的消息。")]
          : folded.messages
      }
      sessions[index].turnStartedAt = folded.activeTurnStartedAt
      reconcileRootSessionRunningState(
        sessionID: sessionID,
        localSessionID: localSessionID,
        running: folded.activeTurnStartedAt != nil)
      sessions[index].isLoadingHistory = preserveCachedHistory || retainVisibleHistory
        ? false
        : snapshot.hasMore
      activeTools = DSHToolActivityMerge.preservingDetails(
        incoming: folded.tools,
        previous: activeTools)
      let oldest = DSHHistoryPagination.oldestSeq(in: snapshot.records)
      sessions[index].updatedAt = Date()
      if let projections = snapshot.projections {
        applyProjectionBaseline(
          sessionID: sessionID,
          values: projections.values,
          rawValues: projections.rawValues,
          seq: projections.asOfSeq ?? snapshot.cursor)
      }
      state.cursor = snapshot.cursor
      state.nextSeq = snapshot.cursor + 1
      state.assistantRevision = snapshot.assistantStream?.revision
      state.assistantAttemptID = snapshot.assistantStream?.activeAttempt?.attemptId
      state.assistantNextIndex = snapshot.assistantStream?.activeAttempt?.nextIndex
      for streamChunk in snapshot.assistantStream?.activeAttempt?.stream ?? [] {
        guard let chunk = jsonObject(streamChunk.chunk) else { continue }
        consumeMuxFrame([
          "type": "session/event",
          "sessionId": sessionID,
          "event": [
            "type": "assistant/chunk",
            "seq": state.cursor ?? 0,
            "time": 0,
            "data": ["chunk": chunk],
          ],
        ])
      }
      status = preserveCachedHistory
        ? "已从本地缓存恢复完整会话"
        : retainVisibleHistory
          ? "已在后台校对会话历史"
        : snapshot.hasMore
          ? "已载入 \(folded.messages.count) 条消息，正在补齐完整历史"
          : "已载入完整会话历史"
      refreshHostSnapshots()
      if snapshot.hasMore, !preserveCachedHistory {
        guard let oldest else {
          sessions[index].isLoadingHistory = false
          state.preservingCachedHistory = false
          hostStatus = DSHHistoryLoadError.cursorDidNotAdvance.localizedDescription
          return
        }
        loadAllOlderHistory(
          sessionID: sessionID,
          localSessionID: localSessionID,
          throughSeq: snapshot.cursor,
          beforeSeq: oldest,
          showsProgress: !retainVisibleHistory,
          replaceVisibleOnCompletion: retainVisibleHistory && !preserveCachedHistory,
          replacementSeed: folded.messages,
          replacementTools: folded.tools)
      } else {
        markRootHistoryComplete(
          sessionID: sessionID,
          throughSeq: max(cached?.sequence ?? 0, snapshot.cursor))
      }
      state.preservingCachedHistory = false
      state.retainingVisibleHistory = false
    case "event":
      guard let eventFrame = DSHProjectionDecoder.decode(DSHSessionWireEventFrame.self, from: frame),
            let data = jsonObject(eventFrame.event.data)
      else { return }
      if let expected = state.nextSeq, eventFrame.event.seq != expected {
        hostStatus = "会话事件序号断裂：期望 \(expected)，收到 \(eventFrame.event.seq)"
        // The Host session is healthy; only this logical reader missed a
        // durable event. Reopen follow so its snapshot repairs history and
        // running state instead of leaving both permanently stale.
        startRootSessionFollow(
          sessionID: sessionID,
          localSessionID: localSessionID,
          retainingVisibleHistory: true)
        return
      }
      state.nextSeq = eventFrame.event.seq + 1
      state.cursor = eventFrame.event.seq
      consumeMuxFrame([
        "type": "session/event",
        "sessionId": sessionID,
        "event": [
          "type": eventFrame.event.type,
          "seq": eventFrame.event.seq,
          "time": eventFrame.event.time,
          "data": data,
        ],
        "view": frame["view"] ?? [:],
      ])
      if let cached = state.completedHistoryBySession[sessionID] {
        state.completedHistoryBySession[sessionID] = DSHHistoryCacheVersion(
          sequence: max(cached.sequence ?? eventFrame.event.seq, eventFrame.event.seq),
          updatedAt: Date().timeIntervalSince1970 * 1_000)
        state.completedHistoryToolsBySession[sessionID] = activeTools
      }
    case "assistant-stream":
      guard let envelope = DSHProjectionDecoder.decode(DSHSessionAssistantStreamEnvelope.self, from: frame),
            let revision = envelope.frame["revision"]?.integer
      else { return }
      let expected = (state.assistantRevision ?? 0) + 1
      guard let frameType = envelope.frame["type"]?.string,
            let attemptID = envelope.frame["attemptId"]?.string
      else { return }
      if revision != expected {
        state.assistantRevision = revision
        state.assistantAttemptID = nil
        state.assistantNextIndex = nil
        guard frameType == "start" else { return }
      } else {
        state.assistantRevision = revision
      }
      switch frameType {
      case "start":
        state.assistantAttemptID = attemptID
        state.assistantNextIndex = 0
      case "chunk":
        guard let index = envelope.frame["index"]?.integer else {
          return
        }
        if let activeAttemptID = state.assistantAttemptID,
           activeAttemptID != attemptID {
          state.assistantAttemptID = nil
          state.assistantNextIndex = nil
        }
        guard index == (state.assistantNextIndex ?? 0) else {
          state.assistantAttemptID = nil
          state.assistantNextIndex = nil
          return
        }
        state.assistantAttemptID = attemptID
        state.assistantNextIndex = index + 1
        guard let chunk = plainValue(envelope.frame["chunk"]) as? [String: Any] else { return }
        consumeMuxFrame([
          "type": "session/event",
          "sessionId": sessionID,
          "event": ["type": "assistant/chunk", "seq": state.cursor ?? 0, "time": 0, "data": ["chunk": chunk]],
        ])
      case "end":
        guard let index = envelope.frame["index"]?.integer,
              index == (state.assistantNextIndex ?? 0) else {
          state.assistantAttemptID = nil
          state.assistantNextIndex = nil
          return
        }
        state.assistantAttemptID = nil
        state.assistantNextIndex = nil
      default:
        return
      }
    default:
      break
    }
  }

  private func applyProjectionBaseline(
    sessionID: String,
    values: DSHSessionProjectionValues,
    rawValues: [String: DSHJSONValue],
    seq: Int
  ) {
    rememberPermissionSelection(values.permissions, sessionID: sessionID, seq: seq)
    guard sessionID == hostCurrentSessionID else { return }
    for (key, rawValue) in rawValues {
      guard key != "permissions" else { continue }
      applyProjection(key: key, value: anyValue(rawValue))
    }
  }

  private func applyProjection(sessionID: String, key: String, value: Any, seq: Int) {
    if key == "permissions",
       let selection = DSHProjectionDecoder.decode(DSHPermissionSelection.self, from: value) {
      rememberPermissionSelection(selection, sessionID: sessionID, seq: seq)
    }
    if sessionID == hostCurrentSessionID {
      applyProjection(key: key, value: value)
    } else if hasSubagentPresentation(sessionID: sessionID) {
      applySubagentProjection(sessionID: sessionID, key: key, value: value, seq: seq)
    }
  }

  private func jsonObject(_ value: DSHJSONValue) -> [String: Any]? {
    anyValue(value) as? [String: Any]
  }

  private func plainValue(_ value: DSHJSONValue?) -> Any? {
    value.map(anyValue)
  }

  func confirmMigrationIfNeeded(for summary: DSHSessionSummary) -> Bool {
    guard summary.needsMigration else { return true }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "需要升级这个旧版会话"
    alert.informativeText = "打开会话会将它的磁盘格式升级到 DSH 0.2。升级后旧版客户端可能无法继续读取。建议先在归档或导出中保留备份。"
    alert.addButton(withTitle: "升级并打开")
    alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn
  }
}
