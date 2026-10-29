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
      if args.count >= 2, let message = args[1] as? String { appendSystem("DSH Host 错误：\(message)") }
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

  func consumeMuxFrame(_ input: [String: Any]) {
    var frame = input
    if let rpcId = frame.removeValue(forKey: "_rpcId") { frame["_rpcId"] = rpcId }
    guard let type = frame["type"] as? String else { return }
    switch type {
    case "session/event":
      guard let sessionID = frame["sessionId"] as? String,
            let event = frame["event"] as? [String: Any] else { return }
      consumeModelWorkbenchEvent(sessionID: sessionID, event: event)
      // Turn boundaries route for EVERY session before the current-session
      // filter below: the sidebar's live dot reads `hostSessions[i].running`
      // and a background row's own flag/unread must move without the session
      // being displayed — sessions run concurrently on the Host and the UI
      // used to drop these frames wholesale.
      if let kind = event["type"] as? String, kind == "turn/start" || kind == "turn/end" {
        let running = kind == "turn/start"
        if let i = hostSessions.firstIndex(where: { $0.sessionId == sessionID }) { hostSessions[i].running = running }
        if sessionID != hostCurrentSessionID, let row = sessions.firstIndex(where: { $0.hostSessionId == sessionID }) {
          sessions[row].isRunning = running
          if !running {
            sessions[row].hasUnread = true
            sessions[row].updatedAt = Date()
          }
        }
      }
      if event["type"] as? String == "user/message",
         let data = event["data"] as? [String: Any],
         let messageID = liveMessagePayload(data)["id"] as? String {
        retireSteeringItem(messageID: messageID, sessionID: sessionID)
        if hasSubagentPresentation(sessionID: sessionID) {
          retireSubagentSteeringItem(messageID: messageID, sessionID: sessionID)
        }
      }
      if voiceTaskSessions[sessionID] != nil {
        handleVoiceTaskEvent(sessionID: sessionID, event: event)
      }
      if isLoadingSubagentPresentation(sessionID: sessionID) {
        bufferSubagentEvent(sessionID: sessionID, event: event, view: frame["view"] as? [String: Any])
      } else if sessionID == activeSubagentAddress?.childSessionId || hasSubagentPresentation(sessionID: sessionID) {
        applyLiveSubagentEvent(sessionID: sessionID, event: event, view: frame["view"] as? [String: Any])
      } else if sessionID == hostCurrentSessionID {
        applyLiveEvent(event, view: frame["view"] as? [String: Any])
      }
    case "session/projection":
      guard let sessionId = frame["sessionId"] as? String,
            let key = frame["key"] as? String,
            let value = frame["value"],
            let seq = frame["seq"] as? Int else { return }
      if key == "permissions",
         let selection = DSHProjectionDecoder.decode(DSHPermissionSelection.self, from: value) {
        rememberPermissionSelection(selection, sessionID: sessionId, seq: seq)
      }
      if sessionId == hostCurrentSessionID {
        applyProjection(key: key, value: value)
      } else if hasSubagentPresentation(sessionID: sessionId) {
        applySubagentProjection(sessionID: sessionId, key: key, value: value, seq: seq)
      }
    case "session/queue":
      guard let sessionID = frame["sessionId"] as? String,
            let values = frame["items"] as? [[String: Any]] else { return }
      let items = DSHQueueItem.fromMux(values)
      rememberQueueSnapshot(items, sessionID: sessionID)
      if hasSubagentPresentation(sessionID: sessionID) {
        replaceSubagentQueue(sessionID: sessionID, items: items)
      }
    case "session/subscribed":
      guard let sessionID = frame["sessionId"] as? String,
            let lastSeq = frame["lastSeq"] as? Int else { return }
      let permissionReset = truncatePermissionSelection(sessionID: sessionID, lastSeq: lastSeq)
      rememberQueueSnapshot([], sessionID: sessionID)
      if hasSubagentPresentation(sessionID: sessionID) {
        replaceSubagentQueue(sessionID: sessionID, items: [])
      }
      if permissionReset && sessionID == hostCurrentSessionID {
        refreshHostSnapshots()
      }
    case "session/jobs":
      guard let sessionID = frame["sessionId"] as? String,
            let jobs = frame["jobs"] as? [[String: Any]] else { return }
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
    case "approval/requested":
      guard let rpcId = frame["_rpcId"] as? String, let sessionId = frame["sessionId"] as? String, let approvalId = frame["approvalId"] as? String else { return }
      let toolName = frame["toolName"] as? String ?? "工具"
      if alwaysAllowedTools.contains(Self.alwaysAllowKey(sessionId: sessionId, toolName: toolName)) {
        Task { try? await hostEvents?.eventResult(eventID: rpcId, value: "allowed-once") }
        return
      }
      let approval = PendingApproval(id: approvalId, rpcId: rpcId, sessionId: sessionId, toolName: toolName, reason: frame["reason"] as? String)
      // A second request while one is already showing used to silently
      // overwrite `pendingApproval`, leaving the first's RPC unanswered
      // forever — queue instead, see the reconcile-parallel-redesigns note.
      if pendingApproval == nil { pendingApproval = approval } else { queuedApprovals.append(approval) }
      nativeAlerts.notifyApprovalNeeded(toolName: toolName)
    case "approval/resolved":
      // Another client (or a Host-side timeout) settled it — retract it
      // from whichever of the shown slot / backlog it's sitting in.
      if let approvalId = frame["approvalId"] as? String {
        if pendingApproval?.id == approvalId { pendingApproval = queuedApprovals.isEmpty ? nil : queuedApprovals.removeFirst() }
        else { queuedApprovals.removeAll { $0.id == approvalId } }
        refreshAttentionBadge()
      }
    case "question/requested":
      guard let rpcId = frame["_rpcId"] as? String, let sessionId = frame["sessionId"] as? String, let questions = frame["questions"] as? [[String: Any]] else { return }
      let items = questions.compactMap { value -> PendingQuestion.Item? in
        guard let id = value["id"] as? String, let question = value["question"] as? String else { return nil }
        let options = (value["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        return PendingQuestion.Item(id: id, question: question, options: options)
      }
      let question = PendingQuestion(id: rpcId, rpcId: rpcId, sessionId: sessionId, items: items)
      if pendingQuestion == nil { pendingQuestion = question } else { queuedQuestions.append(question) }
      nativeAlerts.notifyQuestionNeeded()
    case "question/resolved":
      if let rpcId = (frame["_rpcId"] as? String) ?? (frame["rpcId"] as? String) {
        if pendingQuestion?.id == rpcId { pendingQuestion = queuedQuestions.isEmpty ? nil : queuedQuestions.removeFirst() }
        else { queuedQuestions.removeAll { $0.id == rpcId } }
        refreshAttentionBadge()
      }
    default:
      break
    }
  }

  private func applyLiveEvent(_ event: [String: Any], view: [String: Any]? = nil) {
    guard let kind = event["type"] as? String, let data = event["data"] as? [String: Any], let index = selectedSessionIndex else { return }
    switch kind {
    case "assistant/chunk", "text-chunks", "reasoning-chunks":
      // Anchor on whether the *last* message is already this turn's
      // assistant reply, not "the last assistant message anywhere" — with
      // no placeholder seeding a fresh bubble on send() (see send()'s
      // comment), the previous turn's assistant message would otherwise
      // still be the most recent assistant-role entry and silently absorb
      // the new turn's first delta.
      guard let delta = DSHAssistantStreamProjection.live(eventType: kind, data: data) else { break }
      if sessions[index].messages.last?.role == .assistant,
         sessions[index].messages.last?.hostMessageId == DSHTranscriptMessageMarker.streamingAssistantHostMessageID {
        let last = sessions[index].messages.count - 1
        DSHAssistantStreamProjection.append(delta, to: &sessions[index].messages[last])
      } else {
        sessions[index].messages.append(DSHAssistantStreamProjection.createMessage(from: delta))
      }
    case "assistant/message":
      let payload = liveMessagePayload(data)
      let text = liveMessageText(payload) ?? ""
      let reasoning = liveMessageReasoning(payload)
      let attachment = DSHAttachmentRef.fromLiveMessage(payload)
      // A trailing assistant message without a durable Host id is the
      // stream-only placeholder created by assistant/chunk. Settle it in
      // place even when the model emitted only reasoning/tool blocks and no
      // answer text; otherwise the row remains "streaming" after the step.
      if sessions[index].messages.last?.role == .assistant,
         sessions[index].messages.last?.hostMessageId == DSHTranscriptMessageMarker.streamingAssistantHostMessageID,
         let count = sessions[index].messages.indices.last {
        if !text.isEmpty { sessions[index].messages[count].text = text }
        if let reasoning { sessions[index].messages[count].reasoning = reasoning }
        if let attachment { sessions[index].messages[count].attachment = attachment }
        if let messageID = payload["id"] as? String {
          sessions[index].messages[count].hostMessageId = messageID
        }
      } else if !text.isEmpty || reasoning != nil || attachment != nil {
        var message = Message(
          role: .assistant,
          text: text,
          attachment: attachment,
          reasoning: reasoning)
        message.hostMessageId = payload["id"] as? String
        sessions[index].messages.append(message)
      }
    case "user/message":
      let payload = liveMessagePayload(data)
      // Injected user-role contexts never render — except the cross-session
      // relay plugin's own delivered messages, which are real conversation
      // content from another session's model, not machine plumbing. Real
      // typed input dedupes against the local echo send() already appended
      // (the outgoing first message may carry the workspace-context
      // appendix, hence prefix matching). Queue drains, slash fallbacks, and
      // other clients still land here.
      let relay = liveIsRelayMessage(payload)
      if liveSourceKind(payload) == nil || liveSourceKind(payload) == "user" || relay, let text = liveMessageText(payload).map(userDisplayText) {
        let attachment = DSHAttachmentRef.fromLiveMessage(payload)
        if !relay, let lastUserIndex = sessions[index].messages.lastIndex(where: {
          $0.role == .user && $0.hostMessageId == DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
        }) {
          let lastUser = sessions[index].messages[lastUserIndex].text
          if DSHTranscriptMessageMarker.matchesPendingLocalUserEcho(
            localText: lastUser,
            incomingText: text,
            attachment: attachment) {
            sessions[index].messages[lastUserIndex].hostMessageId = payload["id"] as? String
            if let attachment { sessions[index].messages[lastUserIndex].attachment = attachment }
          } else {
            sessions[index].messages.append(Message(role: .user, text: text, attachment: attachment, isRelayMessage: relay))
          }
        } else {
          sessions[index].messages.append(Message(role: .user, text: text, attachment: attachment, isRelayMessage: relay))
        }
      }
    case "tool/call":
      let name = data["name"] as? String ?? "工具"
      let presentation = ToolPresentation.from(view?["view"] as? [String: Any])
        ?? ToolPresentation.fromToolCall(name: name, arguments: data["arguments"])
      let tool = ToolActivity(
        callId: data["callId"] as? String ?? UUID().uuidString,
        name: name,
        summary: "正在运行",
        state: .running,
        output: "",
        arguments: DSHToolArguments.live(data["arguments"]),
        presentation: presentation)
      activeTools.append(tool)
      // Inline transcript row (Claude Code style); the row itself renders
      // live state by looking up `activeTools` via toolCallId, so tool/result
      // below only needs to update the activity, not this message.
      sessions[index].messages.append(Message(role: .tool, text: tool.name, toolCallId: tool.callId))
    case "tool/result":
      guard let result = DSHToolResultDecoder.live(from: data),
            let toolIndex = activeTools.lastIndex(where: { $0.callId == result.callId })
      else { return }
      var tool = activeTools[toolIndex]
      tool.state = result.isError ? .failed : .succeeded
      let resultPresentation = ToolPresentation.fromEventView(view)
      tool.presentation = ToolPresentation.merging(
        call: tool.presentation,
        result: resultPresentation,
        rawOutput: result.output)
      tool.output = tool.presentation?.output?.nonEmpty
        ?? result.output.nonEmpty
        ?? result.errorSummary
        ?? "工具已完成"
      if !result.imageAttachments.isEmpty {
        tool.imageAttachments = result.imageAttachments
      }
      if let errorSummary = result.errorSummary, !errorSummary.isEmpty {
        tool.summary = errorSummary
      }
      activeTools[toolIndex] = tool
    case "tool/ptc-dispatch-start", "tool/code-dispatch-start":
      guard let subcall = DSHSubcallDecoder.live(from: data),
            let index = activeTools.lastIndex(where: { $0.callId == subcall.rootCallId })
      else { return }
      activeTools[index].startChild(subcall)
    case "tool/ptc-dispatch", "tool/code-dispatch":
      guard let subcall = DSHSubcallDecoder.live(from: data),
            let index = activeTools.lastIndex(where: { $0.callId == subcall.rootCallId })
      else { return }
      activeTools[index].finishChild(
        subcall,
        output: DSHSubcallDecoder.output(from: data["content"]),
        failed: data["isError"] as? Bool == true,
        imageAttachments: DSHAttachmentRef.fromLiveContent(
          data["content"] as? [[String: Any]] ?? []))
    case "tool-workflow/run-start":
      if let runId = data["runId"] as? String, let name = data["name"] as? String, let parentSessionId = hostCurrentSessionID { workflows.append(WorkflowRun(id: runId, parentSessionId: parentSessionId, name: name)) }
    case "tool-workflow/agent-start":
      if let runId = data["runId"] as? String, let seq = data["seq"] as? Int, let label = data["label"] as? String, let childId = data["childId"] as? String, let index = workflows.firstIndex(where: { $0.id == runId }) { workflows[index].members.append(WorkflowRun.Member(id: seq, label: label, phase: data["phase"] as? String, childId: childId, outcome: nil)) }
    case "tool-workflow/agent-end":
      if let runId = data["runId"] as? String, let seq = data["seq"] as? Int, let outcome = data["outcome"] as? String, let index = workflows.firstIndex(where: { $0.id == runId }), let member = workflows[index].members.firstIndex(where: { $0.id == seq }) { workflows[index].members[member].outcome = outcome }
    case "tool-workflow/run-end":
      if let runId = data["runId"] as? String, let reason = data["stopReason"] as? String, let index = workflows.firstIndex(where: { $0.id == runId }) { workflows[index].stopReason = reason }
    case "todo/write":
      if let rawTodos = data["todos"] as? [[String: Any]] {
        todos = rawTodos.compactMap { item in
          guard let content = item["content"] as? String, let status = item["status"] as? String else { return nil }
          return DSHTodoItem(content: content, status: status)
        }
      }
    case "plan/mode":
      hostPlanActive = (data["active"] as? Bool) ?? hostPlanActive
    case "goal/change":
      refreshHostSnapshots()
    case "llm/retry":
      let retry = data["retry"] as? Int ?? 0
      let delay = data["delayMs"] as? Int ?? 0
      let provider = data["provider"] as? String ?? "模型"
      retryNotice = "\(provider) 请求失败，正在第 \(retry) 次重试（等待 \(delay)ms）"
    case "llm/retry-started":
      retryNotice = nil
    case "turn/start":
      // The Host opens a fresh turn for every model round — including ones
      // no local send() initiated: a queued followup draining, a goal round
      // driver advancing, plan-mode confirmation. Arm the running flag from
      // the stream so those turns animate and offer the stop button; before
      // this, only send() ever set it, and a Host-initiated turn rendered
      // the settled (static) tail while streaming.
      isRunning = true
      sessions[index].isRunning = true
      sessions[index].turnStartedAt = DSHTurnTiming.date(
        from: DSHTurnTiming.milliseconds(from: event))
      runNotice = nil
    case "turn/end":
      let kind = (data["reason"] as? [String: Any])?["kind"] as? String
      switch kind {
      case "max-tokens": runNotice = "本轮达到最大输出 token 限制"
      case "error": runNotice = "本轮执行失败"
      case "aborted", "interrupted": runNotice = "本轮已中断"
      default: break
      }
      // Host turns end async; nothing previously reset these for the Host
      // path (only the removed legacy one-shot process's completion handler
      // did), so the composer stayed stuck on "停止/排队" after the first
      // message — see .agents/notes/implemented/feature/2026-08-17-port-feature-completeness-branch.md.
      isRunning = false
      sessions[index].isRunning = false
      // 兜底：turn 已结束，转录里不该再有"运行中"的工具——没等到
      // tool/result 的（callId 对不上、事件丢失）一律落定为完成，防止
      // 状态点永远闪烁。仍在跑的真后台 job 会被下一帧 session/jobs
      // 快照重新标回 running，不受影响。
      for toolIndex in activeTools.indices where activeTools[toolIndex].state == .running {
        activeTools[toolIndex].state = .succeeded
      }
      if let start = sessions[index].turnStartedAt {
        let endMilliseconds = DSHTurnTiming.milliseconds(from: event)
        let duration = DSHTurnTiming.duration(
          from: start,
          to: endMilliseconds) ?? 0
        sessions[index].messages.append(Message(
          role: .system,
          text: "本轮用时 \(DSHTurnTiming.label(duration))",
          timestamp: DSHTurnTiming.date(from: endMilliseconds) ?? Date()))
      }
      sessions[index].turnStartedAt = nil
      nativeAlerts.notifyTurnFinished(summary: sessions[index].title)
    case "compaction/start":
      runNotice = "正在压缩历史上下文…"
    case "compaction/end":
      runNotice = "历史上下文压缩完成"
    case "compaction/summary":
      let summary = data["summary"] as? String
      runNotice = summary.map { "上下文摘要：\($0)" } ?? "已生成上下文摘要"
      // Persist into the scrollback — the banner above is overwritten by the
      // next event, but a compaction is a rare, meaningful moment worth
      // being able to scroll back to (unlike retries, left as ephemeral).
      sessions[index].messages.append(Message(role: .system, text: summary.map { "历史上下文已压缩。摘要：\($0)" } ?? "历史上下文已压缩。"))
    default:
      break
    }
  }

  /// Applies child events into the child-keyed presentation context. Message
  /// rows update only the currently displayed child transcript, while tools
  /// and projections remain isolated by child session ID even after navigation.
  func applyLiveSubagentEvent(
    sessionID: String,
    event: [String: Any],
    view: [String: Any]?
  ) {
    guard let kind = event["type"] as? String, let data = event["data"] as? [String: Any] else { return }
    let isDisplayed = activeSubagentAddress?.childSessionId == sessionID
    switch kind {
    case "assistant/chunk", "text-chunks", "reasoning-chunks":
      guard isDisplayed,
            let delta = DSHAssistantStreamProjection.live(eventType: kind, data: data),
            var transcript = subagentTranscript
      else { return }
      if transcript.messages.last?.role == .assistant,
         transcript.messages.last?.hostMessageId == DSHTranscriptMessageMarker.streamingAssistantHostMessageID {
        DSHAssistantStreamProjection.append(delta, to: &transcript.messages[transcript.messages.count - 1])
      } else {
        transcript.messages.append(DSHAssistantStreamProjection.createMessage(from: delta))
      }
      subagentTranscript = transcript
    case "assistant/message":
      guard isDisplayed else { return }
      let payload = liveMessagePayload(data)
      let text = liveMessageText(payload) ?? ""
      let reasoning = liveMessageReasoning(payload)
      let attachment = DSHAttachmentRef.fromLiveMessage(payload)
      if var transcript = subagentTranscript {
        if transcript.messages.last?.role == .assistant,
           transcript.messages.last?.hostMessageId == DSHTranscriptMessageMarker.streamingAssistantHostMessageID,
           let count = transcript.messages.indices.last {
          if !text.isEmpty { transcript.messages[count].text = text }
          if let reasoning { transcript.messages[count].reasoning = reasoning }
          if let attachment { transcript.messages[count].attachment = attachment }
          if let messageID = payload["id"] as? String {
            transcript.messages[count].hostMessageId = messageID
          }
        } else if !text.isEmpty || reasoning != nil || attachment != nil {
          var message = Message(
            role: .assistant,
            text: text,
            attachment: attachment,
            reasoning: reasoning)
          message.hostMessageId = payload["id"] as? String
          transcript.messages.append(message)
        }
        subagentTranscript = transcript
      }
    case "user/message":
      guard isDisplayed else { return }
      let payload = liveMessagePayload(data)
      if liveSourceKind(payload) == nil || liveSourceKind(payload) == "user", let text = liveMessageText(payload) {
        subagentTranscript?.messages.append(Message(role: .user, text: text, attachment: DSHAttachmentRef.fromLiveMessage(payload)))
      }
    case "tool/call":
      let name = data["name"] as? String ?? "工具"
      let presentation = ToolPresentation.from(view?["view"] as? [String: Any])
        ?? ToolPresentation.fromToolCall(name: name, arguments: data["arguments"])
      let tool = ToolActivity(
        callId: data["callId"] as? String ?? UUID().uuidString,
        name: name,
        summary: "正在运行",
        state: .running,
        output: "",
        arguments: DSHToolArguments.live(data["arguments"]),
        presentation: presentation)
      appendSubagentTool(
        sessionID: sessionID,
        tool: tool,
        seq: event["seq"] as? Int ?? -1)
      if isDisplayed {
        subagentTranscript?.messages.append(Message(role: .tool, text: tool.name, toolCallId: tool.callId))
      }
    case "tool/result":
      guard let result = DSHToolResultDecoder.live(from: data) else { return }
      _ = updateSubagentTool(
        sessionID: sessionID,
        callID: result.callId,
        seq: event["seq"] as? Int ?? -1) { tool in
        tool.state = result.isError ? .failed : .succeeded
        let resultPresentation = ToolPresentation.fromEventView(view)
        tool.presentation = ToolPresentation.merging(
          call: tool.presentation,
          result: resultPresentation,
          rawOutput: result.output)
        tool.output = tool.presentation?.output?.nonEmpty
          ?? result.output.nonEmpty
          ?? result.errorSummary
          ?? "工具已完成"
        if !result.imageAttachments.isEmpty {
          tool.imageAttachments = result.imageAttachments
        }
        if let errorSummary = result.errorSummary, !errorSummary.isEmpty {
          tool.summary = errorSummary
        }
      }
    case "tool/ptc-dispatch-start", "tool/code-dispatch-start":
      guard let subcall = DSHSubcallDecoder.live(from: data) else { return }
      _ = updateSubagentTool(
        sessionID: sessionID,
        callID: subcall.rootCallId,
        seq: event["seq"] as? Int ?? -1) { tool in
        tool.startChild(subcall)
      }
    case "tool/ptc-dispatch", "tool/code-dispatch":
      guard let subcall = DSHSubcallDecoder.live(from: data) else { return }
      _ = updateSubagentTool(
        sessionID: sessionID,
        callID: subcall.rootCallId,
        seq: event["seq"] as? Int ?? -1) { tool in
        tool.finishChild(
          subcall,
          output: DSHSubcallDecoder.output(from: data["content"]),
          failed: data["isError"] as? Bool == true,
          imageAttachments: DSHAttachmentRef.fromLiveContent(
            data["content"] as? [[String: Any]] ?? []))
      }
    case "todo/write":
      if let rawTodos = data["todos"] as? [[String: Any]],
         let seq = event["seq"] as? Int {
        replaceSubagentTodos(sessionID: sessionID, value: rawTodos, seq: seq)
      }
    case "turn/start":
      if isDisplayed {
        subagentTranscript?.isRunning = true
        subagentTranscript?.turnStartedAt = DSHTurnTiming.date(
          from: DSHTurnTiming.milliseconds(from: event))
      }
    case "turn/end":
      settleSubagentTools(sessionID: sessionID, seq: event["seq"] as? Int ?? -1)
      if isDisplayed, var transcript = subagentTranscript {
        transcript.isRunning = false
        if let start = transcript.turnStartedAt {
          let endMilliseconds = DSHTurnTiming.milliseconds(from: event)
          let duration = DSHTurnTiming.duration(from: start, to: endMilliseconds) ?? 0
          transcript.messages.append(Message(
            role: .system,
            text: "本轮用时 \(DSHTurnTiming.label(duration))",
            timestamp: DSHTurnTiming.date(from: endMilliseconds) ?? Date()))
        }
        transcript.turnStartedAt = nil
        subagentTranscript = transcript
      }
    default:
      break
    }
  }

  /// Message-event payload: fields may sit directly on the event data
  /// (`{content, id, role, source}` — the session log's shape) or nest under
  /// `message`. The nested-only lookup silently dropped every flat user
  /// message, which is how typed input vanished from transcripts.
  private func liveMessagePayload(_ data: [String: Any]) -> [String: Any] {
    (data["message"] as? [String: Any]) ?? data
  }

  private func liveSourceKind(_ message: [String: Any]) -> String? {
    (message["source"] as? [String: Any])?["kind"] as? String
  }

  /// True for `source: {kind:"plugin", plugin:"session-relay"}` — the one
  /// non-"user" source kind admitted past the injected-context filter, since
  /// it carries real cross-session conversation content rather than model
  /// plumbing (agent-instructions, skill catalogs, snapshots stay filtered).
  private func liveIsRelayMessage(_ message: [String: Any]) -> Bool {
    liveSourceKind(message) == "plugin" && (message["source"] as? [String: Any])?["plugin"] as? String == "session-relay"
  }

  private func liveMessageText(_ value: Any?) -> String? {
    guard let message = value as? [String: Any], let content = message["content"] as? [[String: Any]] else { return nil }
    return content.compactMap { block -> String? in
      guard block["type"] as? String == "text" else { return nil }
      return block["text"] as? String
    }.joined()
  }

  private func liveMessageReasoning(_ value: Any?) -> String? {
    guard let message = value as? [String: Any],
          let content = message["content"] as? [[String: Any]]
    else { return nil }
    let reasoning = content.compactMap { block -> String? in
      guard block["type"] as? String == "reasoning" else { return nil }
      return block["text"] as? String
    }.joined()
    return reasoning.isEmpty ? nil : reasoning
  }

  func consumeHostFrame(_ frame: [String: Any]) {
    guard let type = frame["type"] as? String else { return }
    switch type {
    case "host/session-added", "host/session-removed", "host/workspace-changed", "host/workspace-removed", "host/workspace-order-changed", "host/archived-sessions-changed":
      refreshHostSnapshots()
    case "host/session-status":
      if let running = frame["running"] as? Bool { status = running ? "DSH 正在运行" : "DSH 已空闲" }
    case "host/agent-error":
      if let message = frame["message"] as? String { appendSystem("DSH Host 错误：\(message)") }
    case "host/remote-event":
      if let event = frame["event"] as? String {
        if event == "settings/document-updated" { refreshSettings(); refreshModelConfiguration() }
        if event == "llm/adapters-updated" { refreshModelConfiguration(); refreshSessionModels() }
        if event == "agent-platform/profiles-updated" { refreshAgentPlatform() }
      }
    default:
      break
    }
  }
}
