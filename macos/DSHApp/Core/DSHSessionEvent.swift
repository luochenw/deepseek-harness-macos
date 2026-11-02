import Foundation
import os

extension DSHRawEvent {
  static func assistantChunk(_ chunk: DSHJSONValue, seq: Int) -> Self {
    Self(type: DSHSessionEventName.assistantChunk, seq: seq, time: 0, data: .object(["chunk": chunk]))
  }

  /// Negative means the frame did not carry the field; the wire always does.
  var sequence: Int? { seq >= 0 ? seq : nil }
  var milliseconds: Double? { time >= 0 ? time : nil }
  var plainData: [String: Any] { data.plainValue as? [String: Any] ?? [:] }
}

/// Every DSH event name the client understands. Nothing outside this file spells one.
enum DSHSessionEventName {
  static let assistantChunk = "assistant/chunk"
  static let assistantMessage = "assistant/message"
  static let assistantAttempt = "assistant/attempt"
  static let textChunks = "text-chunks"
  static let reasoningChunks = "reasoning-chunks"
  static let userMessage = "user/message"
  static let toolCall = "tool/call"
  static let toolResult = "tool/result"
  static let ptcDispatchStart = "tool/ptc-dispatch-start"
  static let codeDispatchStart = "tool/code-dispatch-start"
  static let ptcDispatch = "tool/ptc-dispatch"
  static let codeDispatch = "tool/code-dispatch"
  static let workflowRunStart = "tool-workflow/run-start"
  static let workflowAgentStart = "tool-workflow/agent-start"
  static let workflowAgentEnd = "tool-workflow/agent-end"
  static let workflowRunEnd = "tool-workflow/run-end"
  static let todoWrite = "todo/write"
  static let planMode = "plan/mode"
  static let goalChange = "goal/change"
  static let llmRetry = "llm/retry"
  static let llmRetryStarted = "llm/retry-started"
  static let commandRun = "command/run"
  static let commandDone = "command/done"
  static let compactionStart = "compaction/start"
  static let compactionEnd = "compaction/end"
  static let compactionSummary = "compaction/summary"
  static let turnStart = "turn/start"
  static let turnEnd = "turn/end"
}

/// Fields of a `user/message` or `assistant/message`. They may sit directly on
/// the event data (`{content, id, role, source}`, the session log's shape) or
/// nest under `message`.
struct DSHSessionMessagePayload {
  let id: String?
  let sourceKind: String?
  /// `source: {kind:"plugin", plugin:"session-relay"}`: the one non-"user"
  /// source that carries real conversation content rather than model plumbing.
  let isRelay: Bool
  /// nil when the message has no content blocks at all.
  let text: String?
  let reasoning: String?
  let attachment: DSHAttachmentRef?

  init(_ data: [String: DSHJSONValue]) {
    let message = data["message"]?.object ?? data
    let source = message["source"]?.object
    let content = message["content"]?.array
    id = message["id"]?.string
    sourceKind = source?["kind"]?.string
    isRelay = sourceKind == "plugin" && source?["plugin"]?.string == "session-relay"
    text = content.map { Self.joined($0, type: "text") }
    reasoning = content.map { Self.joined($0, type: "reasoning") }?.nonEmpty
    attachment = DSHAttachmentRef.fromMessage(.object(message))
  }

  private static func joined(_ blocks: [DSHJSONValue], type: String) -> String {
    blocks.compactMap { block -> String? in
      guard let object = block.object, object["type"]?.string == type else { return nil }
      return object["text"]?.string
    }.joined()
  }
}

struct DSHToolCallPayload {
  let callId: String?
  let name: String?
  let arguments: String?
  let presentation: DSHToolPresentation?
}

enum DSHSubcallFlavor {
  case code, ptc
}

struct DSHSubcallResult {
  let output: String
  let failed: Bool
  let imageAttachments: [DSHAttachmentRef]
}

enum DSHTurnEndReason: Equatable {
  case completed
  case failed(detail: String?)
  case interrupted
  case maxTokens

  init(_ reason: [String: DSHJSONValue]?) {
    switch reason?["kind"]?.string {
    case "max-tokens": self = .maxTokens
    case "error": self = .failed(detail: reason?["error"]?.object?["message"]?.string)
    case "aborted", "interrupted": self = .interrupted
    default: self = .completed
    }
  }

  /// A tool the turn left running: only a completed turn implies it finished.
  var settledToolState: DSHToolActivity.State {
    self == .completed ? .succeeded : .interrupted
  }

  /// The banner shown while watching a turn end.
  var notice: String? {
    switch self {
    case .completed: nil
    case .failed: "本轮执行失败"
    case .interrupted: "本轮已中断"
    case .maxTokens: "本轮达到最大输出 token 限制"
    }
  }

  /// The durable row replay renders for the same outcome.
  var transcriptText: String? {
    guard case .failed(let detail?) = self, !detail.isEmpty else { return notice }
    return "本轮执行失败：\(detail)"
  }
}

/// One Host session event, decoded. This is the only code that reads event
/// payload shapes; live streaming and history replay both start here.
enum DSHSessionEvent {
  case assistantDelta(DSHAssistantStreamDelta)
  case assistantMessage(DSHSessionMessagePayload)
  /// A model attempt that failed after streaming; the Host logs what streamed.
  case assistantAttempt([DSHAssistantStreamDelta])
  case userMessage(DSHSessionMessagePayload)
  case toolCall(DSHToolCallPayload)
  case toolResult(DSHToolResultPayload, presentation: DSHToolPresentation?)
  case subcallStarted(DSHSubcallPayload, DSHSubcallFlavor)
  case subcallFinished(DSHSubcallPayload, DSHSubcallResult, DSHSubcallFlavor)
  case todos([DSHTodoItem])
  case planMode(active: Bool?)
  case goalChanged
  case retryScheduled(provider: String, attempt: Int, delayMs: Int)
  case retryStarted
  case workflowRunStarted(id: String, name: String)
  case workflowAgentStarted(runID: String, seq: Int, label: String, phase: String?, childID: String)
  case workflowAgentEnded(runID: String, seq: Int, outcome: String)
  case workflowRunEnded(runID: String, stopReason: String)
  case commandRun(text: String)
  case commandDone(text: String, failed: Bool)
  case compactionStarted
  case compactionEnded
  case compactionSummary(String?)
  case turnStarted
  case turnEnded(DSHTurnEndReason)
  /// A known event with nothing to apply, such as a payload missing a required field.
  case ignored

  init?(raw: DSHRawEvent, view: DSHJSONValue?) {
    guard let data = raw.data.object else { return nil }
    switch raw.type {
    case DSHSessionEventName.assistantChunk, DSHSessionEventName.textChunks, DSHSessionEventName.reasoningChunks:
      self = DSHAssistantStreamProjection.decode(eventType: raw.type, data: data).map(Self.assistantDelta) ?? .ignored
    case DSHSessionEventName.assistantMessage:
      self = .assistantMessage(DSHSessionMessagePayload(data))
    case DSHSessionEventName.assistantAttempt:
      // Each entry is `{time, chunk}`; older logs stored the chunk itself.
      self = .assistantAttempt((data["stream"]?.array ?? []).compactMap { entry in
        DSHAssistantStreamProjection.decode(
          eventType: DSHSessionEventName.assistantChunk,
          data: ["chunk": entry.object?["chunk"] ?? entry])
      })
    case DSHSessionEventName.userMessage:
      self = .userMessage(DSHSessionMessagePayload(data))
    case DSHSessionEventName.toolCall:
      let name = data["name"]?.string
      self = .toolCall(DSHToolCallPayload(
        callId: data["callId"]?.string,
        name: name,
        arguments: DSHToolArguments.decode(data["arguments"]),
        presentation: DSHToolPresentation.fromEventView(view)
          ?? DSHToolPresentation.fromDecodedToolCall(name: name ?? "", arguments: data["arguments"])))
    case DSHSessionEventName.toolResult:
      self = DSHToolResultDecoder.decode(from: data).map {
        .toolResult($0, presentation: DSHToolPresentation.fromEventView(view))
      } ?? .ignored
    case DSHSessionEventName.ptcDispatchStart, DSHSessionEventName.codeDispatchStart:
      let flavor: DSHSubcallFlavor = raw.type == DSHSessionEventName.codeDispatchStart ? .code : .ptc
      self = DSHSubcallDecoder.decode(from: data).map { .subcallStarted($0, flavor) } ?? .ignored
    case DSHSessionEventName.ptcDispatch, DSHSessionEventName.codeDispatch:
      let flavor: DSHSubcallFlavor = raw.type == DSHSessionEventName.codeDispatch ? .code : .ptc
      let result = DSHSubcallResult(
        output: DSHSubcallDecoder.output(from: data["content"]),
        failed: data["isError"]?.bool == true,
        imageAttachments: DSHAttachmentRef.fromContent(data["content"]?.array ?? []))
      self = DSHSubcallDecoder.decode(from: data).map { .subcallFinished($0, result, flavor) } ?? .ignored
    case DSHSessionEventName.todoWrite:
      guard let items = data["todos"]?.array else { self = .ignored; return }
      self = .todos(items.compactMap(DSHTodoItem.init(value:)))
    case DSHSessionEventName.planMode:
      self = .planMode(active: data["active"]?.bool)
    case DSHSessionEventName.goalChange:
      self = .goalChanged
    case DSHSessionEventName.llmRetry:
      self = .retryScheduled(
        provider: data["provider"]?.string ?? "模型",
        attempt: data["retry"]?.integer ?? 0,
        delayMs: data["delayMs"]?.integer ?? 0)
    case DSHSessionEventName.llmRetryStarted:
      self = .retryStarted
    case DSHSessionEventName.workflowRunStart:
      guard let id = data["runId"]?.string, let name = data["name"]?.string else { self = .ignored; return }
      self = .workflowRunStarted(id: id, name: name)
    case DSHSessionEventName.workflowAgentStart:
      guard let runID = data["runId"]?.string,
            let seq = data["seq"]?.integer,
            let label = data["label"]?.string,
            let childID = data["childId"]?.string
      else { self = .ignored; return }
      self = .workflowAgentStarted(runID: runID, seq: seq, label: label, phase: data["phase"]?.string, childID: childID)
    case DSHSessionEventName.workflowAgentEnd:
      guard let runID = data["runId"]?.string,
            let seq = data["seq"]?.integer,
            let outcome = data["outcome"]?.string
      else { self = .ignored; return }
      self = .workflowAgentEnded(runID: runID, seq: seq, outcome: outcome)
    case DSHSessionEventName.workflowRunEnd:
      guard let runID = data["runId"]?.string, let reason = data["stopReason"]?.string else { self = .ignored; return }
      self = .workflowRunEnded(runID: runID, stopReason: reason)
    case DSHSessionEventName.commandRun:
      let sourceKind = data["source"]?.object?["kind"]?.string
      guard sourceKind == nil || sourceKind == "user",
            let name = data["name"]?.string,
            !name.isEmpty
      else { self = .ignored; return }
      self = .commandRun(text: "/\(name)\(data["args"]?.string ?? "")")
    case DSHSessionEventName.commandDone:
      guard let text = data["text"]?.string, !text.isEmpty else { self = .ignored; return }
      self = .commandDone(text: text, failed: data["kind"]?.string != "success")
    case DSHSessionEventName.compactionStart:
      self = .compactionStarted
    case DSHSessionEventName.compactionEnd:
      self = .compactionEnded
    case DSHSessionEventName.compactionSummary:
      self = .compactionSummary(data["summary"]?.string)
    case DSHSessionEventName.turnStart:
      self = .turnStarted
    case DSHSessionEventName.turnEnd:
      self = .turnEnded(DSHTurnEndReason(data["reason"]?.object))
    default:
      DSHContractDrift.noteUnknownEvent(raw.type)
      self = .ignored
    }
  }
}

private extension DSHTodoItem {
  init?(value: DSHJSONValue) {
    guard let object = value.object,
          let content = object["content"]?.string,
          let status = object["status"]?.string
    else { return nil }
    self.init(content: content, status: status)
  }
}

/// Upstream event names the client has no case for. Each is logged once, so an
/// upgrade that renames an event shows up instead of silently dropping it.
enum DSHContractDrift {
  private static let logger = Logger(subsystem: "com.github.deepseek-harness-macos", category: "contract")
  private static let seen = OSAllocatedUnfairLock(initialState: Set<String>())

  static var unknownEventTypes: Set<String> { seen.withLock { $0 } }

  static func noteUnknownEvent(_ type: String) {
    guard seen.withLock({ $0.insert(type).inserted }) else { return }
    logger.notice("Unhandled session event type: \(type, privacy: .public)")
  }
}
