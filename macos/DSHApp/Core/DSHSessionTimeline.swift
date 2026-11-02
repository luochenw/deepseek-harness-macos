import Foundation

/// Watching a turn and reopening it render the same rows. These are the only
/// differences, and each exists because the two have different inputs.
enum DSHTimelineMode {
  case live
  case replay

  /// `DSHToolActivityMerge` keeps a live summary over either of these.
  var toolCallSummary: String { self == .live ? "正在运行" : "工具调用" }
  /// `send()` already shows a local command and its result while it runs.
  var recordsCommandRows: Bool { self == .replay }
}

/// Where one surface keeps its transcript, tools and turn state.
@MainActor
protocol DSHTimelineStore {
  var turnStartedAt: Date? { get set }
  mutating func withMessages(_ body: (inout [DSHMessage]) -> Void)
  mutating func addTool(_ tool: DSHToolActivity, seq: Int)
  mutating func updateTool(callID: String, seq: Int, _ update: (inout DSHToolActivity) -> Void)
  mutating func settleRunningTools(as state: DSHToolActivity.State, seq: Int)
  mutating func setRunning(_ running: Bool)
  mutating func recordWorkflowEvent(_ event: DSHSessionEvent, seq: Int)
}

/// Turns session events into transcript rows, tool state and turn state. Root
/// live, subagent live and history replay all go through `apply`.
enum DSHSessionTimeline {
  @MainActor
  static func apply<Store: DSHTimelineStore>(
    _ event: DSHSessionEvent,
    raw: DSHRawEvent,
    mode: DSHTimelineMode,
    to store: inout Store
  ) {
    // The recorded time, so a live row and its replayed twin merge instead of doubling.
    let recorded = raw.time > 0 ? Date(timeIntervalSince1970: raw.time / 1000) : nil
    let timestamp = recorded ?? Date()
    switch event {
    case .assistantDelta(let delta):
      store.withMessages { messages in
        appendDelta(delta, timestamp: recorded, to: &messages)
      }
    case .assistantMessage(let message):
      store.withMessages { messages in
        settle(message, timestamp: timestamp, in: &messages)
      }
    case .assistantAttempt(let deltas):
      store.withMessages { messages in
        // Live already streamed these chunks; history only has them here.
        if mode == .replay, !isStreamingRow(messages.last) {
          for delta in deltas { appendDelta(delta, timestamp: recorded, to: &messages) }
        }
        // No message will settle this row, so settle it now and keep what streamed.
        if isStreamingRow(messages.last), let last = messages.indices.last {
          messages[last].hostMessageId = nil
          if let recorded { messages[last].timestamp = recorded }
        }
      }
    case .userMessage(let message):
      guard message.sourceKind == nil || message.sourceKind == "user" || message.isRelay,
            let text = message.text
      else { return }
      let displayText = userDisplayText(text)
      store.withMessages { messages in
        if !message.isRelay, reconcileEcho(message, text: displayText, timestamp: timestamp, in: &messages) { return }
        var row = DSHMessage(
          role: .user,
          text: displayText,
          timestamp: timestamp,
          attachment: message.attachment,
          isRelayMessage: message.isRelay)
        // The durable id lets a reopened transcript merge this row instead of repeating it.
        row.hostMessageId = message.id
        messages.append(row)
      }
    case .toolCall(let call):
      // A folded log must give the same id twice; live ids only need to be distinct.
      let callID = call.callId ?? (mode == .replay ? "\(raw.seq)" : UUID().uuidString)
      let name = call.name ?? "工具"
      store.addTool(
        DSHToolActivity(
          callId: callID,
          name: name,
          summary: mode.toolCallSummary,
          state: .running,
          output: "",
          arguments: call.arguments,
          presentation: call.presentation),
        seq: raw.seq)
      store.withMessages { messages in
        messages.append(DSHMessage(role: .tool, text: name, timestamp: timestamp, toolCallId: callID))
      }
    case .toolResult(let result, let presentation):
      store.updateTool(callID: result.callId, seq: raw.seq) { tool in
        tool.state = result.isError ? .failed : .succeeded
        tool.presentation = DSHToolPresentation.merging(
          call: tool.presentation,
          result: presentation,
          rawOutput: result.output)
        tool.output = tool.presentation?.output?.nonEmpty
          ?? result.output.nonEmpty
          ?? result.errorSummary
          ?? "工具已完成"
        // Live keeps images when a later result has none; replay takes the record as written.
        if mode == .replay || !result.imageAttachments.isEmpty {
          tool.imageAttachments = result.imageAttachments
        }
        if let errorSummary = result.errorSummary, !errorSummary.isEmpty {
          tool.summary = errorSummary
        }
      }
    case .subcallStarted(let subcall, _):
      guard let rootCallID = subcall.rootCallId else { return }
      store.updateTool(callID: rootCallID, seq: raw.seq) { $0.startChild(subcall) }
    case .subcallFinished(let subcall, let result, _):
      guard let rootCallID = subcall.rootCallId else { return }
      store.updateTool(callID: rootCallID, seq: raw.seq) { tool in
        tool.finishChild(
          subcall,
          output: result.output,
          failed: result.failed,
          imageAttachments: result.imageAttachments)
      }
    case .commandRun(let text):
      guard mode.recordsCommandRows else { return }
      store.withMessages { messages in
        messages.append(DSHMessage(role: .user, text: text, timestamp: timestamp))
      }
    case .commandDone(let text, let failed):
      guard mode.recordsCommandRows else { return }
      store.withMessages { messages in
        messages.append(DSHMessage(role: .system, text: failed ? "命令失败：\(text)" : text, timestamp: timestamp))
      }
    case .compactionSummary(let summary):
      store.withMessages { messages in
        messages.append(DSHMessage(
          role: .system,
          text: summary.map { "历史上下文已压缩。摘要：\($0)" } ?? "历史上下文已压缩。",
          timestamp: timestamp))
      }
    case .workflowRunStarted, .workflowAgentStarted, .workflowAgentEnded, .workflowRunEnded:
      store.recordWorkflowEvent(event, seq: raw.seq)
    case .turnStarted:
      store.setRunning(true)
      store.turnStartedAt = DSHTurnTiming.date(from: raw.milliseconds)
    case .turnEnded(let reason):
      store.setRunning(false)
      store.settleRunningTools(as: reason.settledToolState, seq: raw.seq)
      if let text = reason.transcriptText {
        store.withMessages { messages in
          messages.append(DSHMessage(role: .system, text: text, timestamp: timestamp))
        }
      }
      if let start = store.turnStartedAt {
        let duration = DSHTurnTiming.duration(from: start, to: raw.milliseconds) ?? 0
        let endedAt = DSHTurnTiming.date(from: raw.milliseconds) ?? Date()
        store.withMessages { messages in
          messages.append(DSHMessage(
            role: .system,
            text: "本轮用时 \(DSHTurnTiming.label(duration))",
            timestamp: endedAt))
        }
      }
      store.turnStartedAt = nil
    case .todos, .planMode, .goalChanged, .retryScheduled, .retryStarted,
         .compactionStarted, .compactionEnded, .ignored:
      break
    }
  }

  /// Display text of a user message: the transcript shows the message as
  /// typed, so cut from the marker on. Matched by marker only: the appendix
  /// wording has already changed once and stored sessions keep the old phrasing.
  static func userDisplayText(_ text: String) -> String {
    guard let range = text.range(of: "\n\n[工作区上下文]") else { return text }
    return String(text[..<range.lowerBound])
  }

  private static func isStreamingRow(_ message: DSHMessage?) -> Bool {
    message?.role == .assistant
      && message?.hostMessageId == DSHTranscriptMessageMarker.streamingAssistantHostMessageID
  }

  /// Anchors on whether the last row is this turn's stream, not on the last
  /// assistant message anywhere: the previous turn's reply must not absorb the
  /// new turn's first delta.
  private static func appendDelta(
    _ delta: DSHAssistantStreamDelta,
    timestamp: Date?,
    to messages: inout [DSHMessage]
  ) {
    if isStreamingRow(messages.last), let last = messages.indices.last {
      DSHAssistantStreamProjection.append(delta, to: &messages[last])
    } else {
      messages.append(DSHAssistantStreamProjection.createMessage(from: delta, timestamp: timestamp))
    }
  }

  /// A trailing stream row is settled in place even when the final message has no
  /// text, otherwise it would stay "streaming" or lose what already streamed.
  private static func settle(
    _ message: DSHSessionMessagePayload,
    timestamp: Date,
    in messages: inout [DSHMessage]
  ) {
    let text = message.text ?? ""
    if isStreamingRow(messages.last), let last = messages.indices.last {
      if !text.isEmpty { messages[last].text = text }
      if let reasoning = message.reasoning { messages[last].reasoning = reasoning }
      if let attachment = message.attachment { messages[last].attachment = attachment }
      messages[last].hostMessageId = message.id
    } else if !text.isEmpty || message.reasoning != nil || message.attachment != nil {
      var row = DSHMessage(
        role: .assistant,
        text: text,
        timestamp: timestamp,
        attachment: message.attachment,
        reasoning: message.reasoning)
      row.hostMessageId = message.id
      messages.append(row)
    }
  }

  /// Typed input dedupes against the local echo `send()` already appended.
  private static func reconcileEcho(
    _ message: DSHSessionMessagePayload,
    text: String,
    timestamp: Date,
    in messages: inout [DSHMessage]
  ) -> Bool {
    guard let index = messages.lastIndex(where: {
      $0.role == .user && $0.hostMessageId == DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
    }), DSHTranscriptMessageMarker.matchesPendingLocalUserEcho(
      localText: messages[index].text,
      incomingText: text,
      attachment: message.attachment)
    else { return false }
    messages[index].hostMessageId = message.id
    messages[index].timestamp = timestamp
    if let attachment = message.attachment { messages[index].attachment = attachment }
    return true
  }
}

/// History replay accumulates into plain values and applies nothing until the
/// caller has validated its request generation.
struct DSHReplayTimelineStore: DSHTimelineStore {
  var turnStartedAt: Date?
  private(set) var messages: [DSHMessage] = []
  private(set) var tools: [String: DSHToolActivity] = [:]
  private(set) var toolSequences: [String: Int] = [:]
  private(set) var workflowEvents: [(seq: Int, event: DSHSessionEvent)] = []

  mutating func withMessages(_ body: (inout [DSHMessage]) -> Void) {
    body(&messages)
  }

  mutating func addTool(_ tool: DSHToolActivity, seq: Int) {
    tools[tool.callId] = tool
    toolSequences[tool.callId] = seq
  }

  mutating func updateTool(callID: String, seq: Int, _ update: (inout DSHToolActivity) -> Void) {
    guard var tool = tools[callID] else { return }
    update(&tool)
    tools[callID] = tool
    toolSequences[callID] = seq
  }

  mutating func settleRunningTools(as state: DSHToolActivity.State, seq: Int) {
    for id in tools.keys where tools[id]?.state == .running {
      tools[id]?.settle(as: state)
    }
  }

  mutating func setRunning(_ running: Bool) {}

  mutating func recordWorkflowEvent(_ event: DSHSessionEvent, seq: Int) {
    workflowEvents.append((seq, event))
  }

  var folded: DSHFoldedHistory {
    DSHFoldedHistory(
      messages: messages,
      tools: Array(tools.values),
      toolSequences: toolSequences,
      activeTurnStartedAt: turnStartedAt,
      workflowEvents: workflowEvents,
      sequenceRange: sequenceRange)
  }

  private var sequenceRange: ClosedRange<Int>?

  @MainActor
  static func fold(_ entries: [DSHHistoryEntry]) -> DSHFoldedHistory {
    var store = Self()
    let sequences = entries.map(\.event.seq)
    if let first = sequences.min(), let last = sequences.max() { store.sequenceRange = first...last }
    for entry in entries {
      guard let event = DSHSessionEvent(raw: entry.event, view: entry.view) else { continue }
      DSHSessionTimeline.apply(event, raw: entry.event, mode: .replay, to: &store)
    }
    return store.folded
  }
}
