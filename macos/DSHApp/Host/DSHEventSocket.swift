import Foundation

struct DSHEventResultArgs: Encodable {
  struct Outcome: Encodable {
    let kind: String
    let value: DSHJSONPatchValue?
  }

  let clientId: String
  let eventId: String
  let outcome: Outcome
}

enum DSHSessionFollowOpeningPolicy {
  /// The live opening only needs to establish the durable cursor and current
  /// tail. Complete history is fetched over ordinary HTTP session/page calls.
  static let maxMessages = 1
  static let minMessages = 1
  static let minTurns = 1

  static func payload(address: [String: Any]) -> [String: Any] {
    [
      "args": [
        "request": [
          "address": address,
          "maxMessages": maxMessages,
          "turnWindow": [
            "minMessages": minMessages,
            "minTurns": minTurns,
          ],
          "assistantStream": true,
        ],
      ],
    ]
  }
}


/// One authenticated `/api/remote.mux` WebSocket carrying every 0.2 logical
/// stream: `$events`, `session/control`, and root/subagent `session/follow`.
@MainActor
final class DSHEventSocket {
  private struct Stream {
    let onItem: ([String: Any]) -> Void
    let onEnd: () -> Void
    let onError: (String) -> Void
  }

  private let client: DSHHostClient
  private let session: URLSession
  private var task: URLSessionWebSocketTask?
  private var stopped = false
  /// Set by `detach()`: `close()` stays silent from then on.
  private var detached = false
  private var streams: [String: Stream] = [:]
  private var pendingOpens: [[String: Any]] = []
  private var eventClientID: String?
  private let onClosed: (() -> Void)?

  init(client: DSHHostClient, onClosed: (() -> Void)? = nil) {
    self.client = client
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    self.session = URLSession(configuration: configuration)
    self.onClosed = onClosed
  }

  func start() {
    guard task == nil, !stopped else { return }
    Task {
      do {
        let request = try await client.webSocketRequest(path: "api/remote.mux")
        guard !stopped else { return }
        let task = self.session.webSocketTask(with: request)
        self.task = task
        task.resume()
        for frame in pendingOpens { send(frame) }
        pendingOpens = []
        receive()
      } catch {
        close()
      }
    }
  }

  nonisolated func stop() {
    Task { @MainActor [self] in self.stopStream() }
  }

  /// Stop reporting `onClosed` from here on. The supervisor calls this when the
  /// Host *process* died: the exit already owns the user-visible status
  /// ("Host 已退出，N 秒后自动重启" / the give-up copy), and the socket teardown
  /// that follows would otherwise overwrite it with the generic
  /// "消息流已断开" retry copy from `handleHostStreamClosed()`. Purely a latch —
  /// `stop()` still performs the actual teardown.
  func detach() {
    detached = true
  }

  private func stopStream() {
    stopped = true
    task?.cancel(with: .goingAway, reason: nil)
    task = nil
    session.invalidateAndCancel()
    streams = [:]
    pendingOpens = []
    eventClientID = nil
  }

  @discardableResult
  func open(
    endpoint: String,
    payload: [String: Any],
    onItem: @escaping ([String: Any]) -> Void,
    onEnd: @escaping () -> Void,
    onError: @escaping (String) -> Void,
  ) -> String {
    let streamID = UUID().uuidString
    streams[streamID] = Stream(onItem: onItem, onEnd: onEnd, onError: onError)
    let frame: [String: Any] = [
      "type": "open",
      "streamId": streamID,
      "endpoint": endpoint,
      "payload": payload,
    ]
    if task == nil { pendingOpens.append(frame) } else { send(frame) }
    return streamID
  }

  func cancel(_ streamID: String?) {
    guard let streamID else { return }
    streams[streamID] = nil
    send(["type": "cancel", "streamId": streamID])
  }

  private func receive() {
    task?.receive { [weak self] result in
      Task { @MainActor in
        guard let self, !self.stopped else { return }
        switch result {
        case .success(let message):
          self.handle(message)
          self.receive()
        case .failure:
          self.close()
        }
      }
    }
  }

  private func handle(_ message: URLSessionWebSocketTask.Message) {
    let data: Data?
    switch message {
    case .string(let text): data = text.data(using: .utf8)
    case .data(let bytes): data = bytes
    @unknown default: data = nil
    }
    guard let data,
          let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = frame["type"] as? String,
          let streamID = frame["streamId"] as? String,
          let stream = streams[streamID]
    else { return }
    switch type {
    case "item":
      if let value = frame["value"] as? [String: Any] { stream.onItem(value) }
    case "end":
      streams[streamID] = nil
      stream.onEnd()
    case "error":
      streams[streamID] = nil
      let error = frame["error"] as? [String: Any]
      let code = error?["code"] as? String ?? "remote-stream"
      let message = error?["message"] as? String ?? "Remote stream failed"
      stream.onError("\(code): \(message)")
    default:
      break
    }
  }

  private func send(_ object: [String: Any]) {
    guard let task,
          JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8)
    else { return }
    task.send(.string(text)) { [weak self] error in
      guard error != nil else { return }
      Task { @MainActor in self?.close() }
    }
  }

  private func close() {
    guard !stopped else { return }
    stopped = true
    task?.cancel(with: .goingAway, reason: nil)
    task = nil
    session.invalidateAndCancel()
    streams = [:]
    pendingOpens = []
    // A detached socket was retired together with its Host process; the
    // supervisor's exit path has already written the status that applies.
    guard !detached else { return }
    onClosed?()
  }
}

extension DSHEventSocket {
  func openSessionFollow(
    sessionID: String,
    onItem: @escaping ([String: Any]) -> Void,
    onEnd: @escaping () -> Void,
    onError: @escaping (String) -> Void,
  ) -> String {
    openFollow(
      address: ["kind": "session", "sessionId": sessionID],
      onItem: onItem,
      onEnd: onEnd,
      onError: onError)
  }

  func openFollow(
    address: [String: Any],
    onItem: @escaping ([String: Any]) -> Void,
    onEnd: @escaping () -> Void,
    onError: @escaping (String) -> Void,
  ) -> String {
    open(
      endpoint: "session/follow",
      payload: DSHSessionFollowOpeningPolicy.payload(address: address),
      onItem: onItem,
      onEnd: onEnd,
      onError: onError)
  }

  func openSessionControl(
    onItem: @escaping ([String: Any]) -> Void,
    onEnd: @escaping () -> Void,
    onError: @escaping (String) -> Void,
  ) -> String {
    open(
      endpoint: "session/control",
      payload: ["args": [:]],
      onItem: onItem,
      onEnd: onEnd,
      onError: onError)
  }

  func openJobList(
    sessionID: String,
    onItem: @escaping ([String: Any]) -> Void,
    onEnd: @escaping () -> Void,
    onError: @escaping (String) -> Void,
  ) -> String {
    open(
      endpoint: "job/list",
      payload: ["args": ["request": ["sessionId": sessionID]]],
      onItem: onItem,
      onEnd: onEnd,
      onError: onError)
  }

  func openRemoteEvents(
    onItem: @escaping ([String: Any]) -> Void,
    onEnd: @escaping () -> Void,
    onError: @escaping (String) -> Void,
  ) -> String {
    open(
      endpoint: "$events",
      payload: ["args": [:]],
      onItem: { [weak self] value in
        if value["type"] as? String == "ready" {
          self?.eventClientID = value["clientId"] as? String
        }
        onItem(value)
      },
      onEnd: onEnd,
      onError: onError)
  }

  func eventResult(eventID: String, value: Any) async throws {
    guard let eventClientID,
          let encoded = DSHJSONPatchValue(value)
    else { throw URLError(.userAuthenticationRequired) }
    _ = try await client.callOptional(
      "$events/result",
      args: DSHEventResultArgs(
        clientId: eventClientID,
        eventId: eventID,
        outcome: .init(kind: "result", value: encoded)),
      as: DSHJSONValue.self)
  }
}

extension HarnessController {
  /// Seed the app-local DSH home from the user's existing ~/.dsh configuration
  /// when the app home has no credentials yet. Existing routes and secrets are
  /// preserved verbatim; the native UI does not create a product-specific
  /// default route for a new install.
  func seedConfigurationFromUserDSHIfNeeded() {
    let fm = FileManager.default
    let userDSH = fm.homeDirectoryForCurrentUser.appendingPathComponent(".dsh", isDirectory: true)
    let appHome = dshHome
    let appCredential = appHome.appendingPathComponent(".credentials.yaml")
    guard !fm.fileExists(atPath: appCredential.path),
          fm.fileExists(atPath: userDSH.appendingPathComponent(".credentials.yaml").path) else { return }
    do {
      try fm.createDirectory(at: appHome, withIntermediateDirectories: true)
      for name in [".credentials.yaml", "cordis.patch.yml", "settings.yaml"] {
        let source = userDSH.appendingPathComponent(name)
        let target = appHome.appendingPathComponent(name)
        if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: target) }
      }
      status = "已导入 ~/.dsh 的模型配置"
    } catch {
      status = "导入 ~/.dsh 配置失败：\(error.localizedDescription)"
    }
  }

  func openRemoteEventStream() {
    _ = hostEvents?.openRemoteEvents(
      onItem: { [weak self] value in self?.consumeRemoteEventFrame(value) },
      onEnd: { [weak self] in self?.hostStatus = "Host 应用事件流已结束" },
      onError: { [weak self] message in self?.hostStatus = "Host 应用事件流失败：\(message)" })
  }

  private func consumeRemoteEventFrame(_ frame: [String: Any]) {
    guard let type = frame["type"] as? String else { return }
    switch type {
    case "ready":
      hostStreamDidBecomeReady()
      hostStatus = "Host 事件流已就绪"
    case "emit":
      guard let event = frame["event"] as? String,
            let args = frame["args"] as? [Any]
      else { return }
      consumeRemoteEmit(event: event, args: args)
    case "waterfall":
      consumeRemoteWaterfall(frame)
    case "cancel":
      guard let eventID = frame["eventId"] as? String else { return }
      queuedApprovals.removeAll { $0.rpcId == eventID }
      queuedQuestions.removeAll { $0.rpcId == eventID }
      if pendingApproval?.rpcId == eventID {
        pendingApproval = queuedApprovals.isEmpty ? nil : queuedApprovals.removeFirst()
      }
      if pendingQuestion?.rpcId == eventID {
        pendingQuestion = queuedQuestions.isEmpty ? nil : queuedQuestions.removeFirst()
      }
      refreshAttentionBadge()
    default:
      break
    }
  }

  private func consumeRemoteEmit(event: String, args: [Any]) {
    switch event {
    case "api-session/status":
      guard args.count >= 2, let sessionID = args[0] as? String, let running = args[1] as? Bool else { return }
      applyRemoteSessionStatus(sessionID: sessionID, running: running)
    case "api-session/activity":
      guard args.count >= 2, let sessionID = args[0] as? String else { return }
      if let updatedAt = number(args[1]),
         let index = hostSessions.firstIndex(where: { $0.sessionId == sessionID }) {
        hostSessions[index].updatedAt = updatedAt
      }
      if let index = sessions.firstIndex(where: { $0.hostSessionId == sessionID }) {
        sessions[index].updatedAt = Date()
      }
    case "api-session/added":
      if let value = args.first,
         let data = try? JSONSerialization.data(withJSONObject: value),
         let summary = try? JSONDecoder().decode(DSHSessionSummary.self, from: data) {
        if let index = hostSessions.firstIndex(where: { $0.sessionId == summary.sessionId }) {
          hostSessions[index] = summary
        } else {
          hostSessions.append(summary)
        }
      } else {
        refreshHostSnapshots()
      }
    case "api-session/removed":
      guard let sessionID = args.first as? String else { return }
      hostSessions.removeAll { $0.sessionId == sessionID }
    case "api-session/error":
      if args.count >= 2, let sessionID = args[0] as? String, let message = args[1] as? String {
        reportSessionError(sessionID: sessionID, message: message)
      }
    case "settings/document-updated":
      refreshSettings()
      refreshModelConfiguration()
    case "llm/adapters-updated":
      refreshModelConfiguration()
      refreshSessionModels()
    case "agent-platform/profiles-updated":
      refreshAgentPlatform()
    case "agent-preset/selected":
      refreshHostSnapshots()
    default:
      break
    }
  }

  private func consumeRemoteWaterfall(_ frame: [String: Any]) {
    guard let event = frame["event"] as? String,
          let eventID = frame["eventId"] as? String,
          let request = frame["request"] as? [String: Any]
    else { return }
    let sessionID = (frame["agentId"] as? String)
      ?? (request["agentId"] as? String)
      ?? (request["sessionId"] as? String)
      ?? ""
    switch event {
    case "approval/request":
      let toolName = request["toolName"] as? String ?? "工具"
      if alwaysAllowedTools.contains(Self.alwaysAllowKey(sessionId: sessionID, toolName: toolName)) {
        Task { try? await hostEvents?.eventResult(eventID: eventID, value: "allowed-once") }
        return
      }
      let approval = PendingApproval(
        id: eventID,
        rpcId: eventID,
        sessionId: sessionID,
        toolName: toolName,
        reason: request["reason"] as? String)
      if pendingApproval == nil { pendingApproval = approval } else { queuedApprovals.append(approval) }
      nativeAlerts.notifyApprovalNeeded(toolName: toolName)
    case "user-questions/request":
      guard let rawQuestions = request["questions"] as? [[String: Any]] else { return }
      let items = rawQuestions.compactMap { value -> PendingQuestion.Item? in
        guard let id = value["id"] as? String,
              let question = value["question"] as? String
        else { return nil }
        let options = (value["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        return PendingQuestion.Item(id: id, question: question, options: options)
      }
      let question = PendingQuestion(id: eventID, rpcId: eventID, sessionId: sessionID, items: items)
      if pendingQuestion == nil { pendingQuestion = question } else { queuedQuestions.append(question) }
      nativeAlerts.notifyQuestionNeeded()
    default:
      Task { try? await hostEvents?.eventResult(eventID: eventID, value: NSNull()) }
    }
  }

  private func number(_ value: Any) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? NSNumber { return value.doubleValue }
    return nil
  }

  /// Job snapshots for the open root session, and for a child whose stream is still attached.
  func applySessionJobs(sessionID: String, jobs: [[String: Any]]) {
    if sessionID != hostCurrentSessionID {
      if isLoadingSubagentPresentation(sessionID: sessionID) {
        bufferSubagentJobs(sessionID: sessionID, jobs: jobs)
        return
      }
      guard hasSubagentPresentation(sessionID: sessionID) else { return }
      mergeSubagentJobs(sessionID: sessionID, jobs: jobs)
      return
    }
    // 合并更新，绝不整表覆盖：覆盖会把转录里已完成的工具行全部换成
    // job 条目，且旧映射除 failed 外一律算 .running（包括 completed）
    // —— 这正是"run_code 都执行结束了还在动"的来源。
    for job in jobs {
      guard let id = job["id"] as? String else { continue }
      let status = (job["status"] as? String ?? "running").lowercased()
      let state = DSHToolJobState.resolve(status)
      if let index = activeTools.lastIndex(where: { $0.callId == id }) {
        activeTools[index].state = state
        if let detail = job["detail"] as? String { activeTools[index].summary = detail }
      } else {
        activeTools.append(ToolActivity(
          callId: id, name: job["label"] as? String ?? "后台任务",
          summary: job["detail"] as? String ?? status, state: state,
          output: "", presentation: nil))
      }
    }
  }

  /// The entry point for every session event, whichever follow stream carried it.
  func consumeSessionEvent(_ raw: DSHRawEvent, view: DSHJSONValue?, sessionID: String) {
    guard let event = DSHSessionEvent(raw: raw, view: view) else { return }
    consumeModelWorkbenchEvent(sessionID: sessionID, raw: raw, event: event)
    if case .userMessage(let message) = event, let messageID = message.id {
      retireSteeringItem(messageID: messageID, sessionID: sessionID)
      if hasSubagentPresentation(sessionID: sessionID) {
        retireSubagentSteeringItem(messageID: messageID, sessionID: sessionID)
      }
    }
    if isLoadingSubagentPresentation(sessionID: sessionID) {
      bufferSubagentEvent(sessionID: sessionID, raw: raw, event: event)
    } else if sessionID == activeSubagentAddress?.childSessionId || hasSubagentPresentation(sessionID: sessionID) {
      applySubagentEvent(event, raw: raw, sessionID: sessionID)
    } else if sessionID == hostCurrentSessionID {
      applyRootEvent(event, raw: raw)
    }
  }

  private func applyRootEvent(_ event: DSHSessionEvent, raw: DSHRawEvent) {
    guard let index = selectedSessionIndex else { return }
    var store = DSHRootTimelineStore(controller: self, index: index)
    DSHSessionTimeline.apply(event, raw: raw, mode: .live, to: &store)
    switch event {
    case .todos(let items):
      todos = items
    case .planMode(let active):
      hostPlanActive = active ?? hostPlanActive
    case .goalChanged:
      refreshHostSnapshots()
    case .retryScheduled(let provider, let attempt, let delayMs):
      retryNotice = "\(provider) 请求失败，正在第 \(attempt) 次重试（等待 \(delayMs)ms）"
    case .retryStarted:
      retryNotice = nil
    case .turnStarted:
      runNotice = nil
    case .turnEnded(let reason):
      if let notice = reason.notice { runNotice = notice }
    case .compactionStarted:
      runNotice = "正在压缩历史上下文…"
    case .compactionEnded:
      runNotice = "历史上下文压缩完成"
    case .compactionSummary(let summary):
      // The row in the transcript outlives this banner, which the next event overwrites.
      runNotice = summary.map { "上下文摘要：\($0)" } ?? "已生成上下文摘要"
    default:
      break
    }
  }
}

/// The open root session: rows live on its `Session`, tools on the controller.
@MainActor
struct DSHRootTimelineStore: DSHTimelineStore {
  let controller: HarnessController
  let index: Int

  var turnStartedAt: Date? {
    get { controller.sessions[index].turnStartedAt }
    nonmutating set { controller.sessions[index].turnStartedAt = newValue }
  }

  mutating func withMessages(_ body: (inout [HarnessController.Message]) -> Void) {
    body(&controller.sessions[index].messages)
  }

  mutating func addTool(_ tool: HarnessController.ToolActivity, seq: Int) {
    controller.activeTools.append(tool)
  }

  mutating func updateTool(
    callID: String,
    seq: Int,
    _ update: (inout HarnessController.ToolActivity) -> Void
  ) {
    guard let tool = controller.activeTools.lastIndex(where: { $0.callId == callID }) else { return }
    update(&controller.activeTools[tool])
  }

  /// A turn that ended cannot still own a running tool, whether or not its
  /// result arrived. Real background jobs are restored by the next
  /// `session/jobs` snapshot.
  mutating func settleRunningTools(as state: DSHToolActivity.State, seq: Int) {
    for tool in controller.activeTools.indices where controller.activeTools[tool].state == .running {
      controller.activeTools[tool].settle(as: state)
    }
  }

  mutating func setRunning(_ running: Bool) {
    guard let sessionID = controller.hostCurrentSessionID else { return }
    controller.reconcileRootSessionRunningState(
      sessionID: sessionID,
      localSessionID: controller.sessions[index].id,
      running: running)
  }

  mutating func recordWorkflowEvent(_ event: DSHSessionEvent, seq: Int) {
    guard let sessionID = controller.hostCurrentSessionID else { return }
    controller.rootScope.workflowLog.record([(seq, event)], parentSessionID: sessionID)
  }
}
