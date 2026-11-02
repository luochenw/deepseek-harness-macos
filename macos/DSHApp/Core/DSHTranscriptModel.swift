import Foundation

struct DSHMessage: Identifiable, Equatable {
  enum Role { case user, assistant, system, tool }
  let id = UUID()
  let role: Role
  var text: String
  var timestamp = Date()
  var attachment: DSHAttachmentRef?
  var reasoning: String?
  /// Host durable message id — the key for per-message Typert feedback.
  var hostMessageId: String?
  /// For `.tool` rows: joins the transcript row to its live `ToolActivity`
  /// (state, summary, presentation) in `activeTools` at render time, so the
  /// row updates in place when the result lands without mutating messages.
  var toolCallId: String?
  /// True for `source: {kind:"plugin", plugin:"session-relay"}` messages
  /// (dsh-tool-session-relay) — the one non-"user" source kind admitted
  /// past the injected-context filter below, so the transcript can show
  /// who a cross-session message came from without text-sniffing the
  /// plugin's envelope wording.
  var isRelayMessage = false
}

struct DSHWorkflowRun: Identifiable {
  /// The wire vocabulary is `WorkflowAgentOutcome = 'completed' | 'failed'
  /// | 'cancelled'` (member-level) and `WorkflowStopReason = 'completed' |
  /// 'cancelled' | 'error'` (run-level) — both absent while running. See
  /// .agents/notes/implemented/feature/2026-08-14-workflow-phase-grouping-and-status.md.
  enum Status { case running, completed, failed, cancelled }
  struct Member: Identifiable {
    let id: Int; var label: String; var phase: String?; let childId: String; var outcome: String?
    var status: Status {
      switch outcome {
      case "completed": .completed
      case "failed": .failed
      case "cancelled": .cancelled
      default: .running
      }
    }
  }
  let id: String
  let parentSessionId: String
  var name: String
  var stopReason: String?
  var members: [Member] = []
  var status: Status {
    switch stopReason {
    case "completed": .completed
    case "error": .failed
    case "cancelled": .cancelled
    default: .running
    }
  }
}

struct DSHToolActivity: Identifiable {
  /// `interrupted`: the turn ended before this tool reported a result.
  enum State { case running, succeeded, failed, interrupted }
  let id = UUID(); let callId: String
  var name: String; var summary: String; var state: State
  var output: String; var arguments: String? = nil; var imageAttachments: [DSHAttachmentRef] = []; var presentation: DSHToolPresentation?
  var children: [DSHToolChildActivity] = []
}

struct DSHToolPresentation {
  struct Diff: Identifiable { let id = UUID(); let path: String; let oldText: String?; let newText: String }
  struct FileLine: Identifiable { let id = UUID(); let number: Int; let text: String }
  struct SearchMatch: Identifiable { let id = UUID(); let lineNumber: Int; let line: String }
  struct SearchFile: Identifiable { let id = UUID(); let path: String; let matches: [SearchMatch] }
  struct Source: Identifiable { let id = UUID(); let url: String; let title: String?; let snippet: String?; let publishedAt: String? }

  let card: String
  let title: String?
  let path: String?
  let output: String?
  let exitCode: Int?
  let signal: String?
  let cwd: String?
  let description: String?
  let diffs: [Diff]
  let lines: [FileLine]
  let totalLines: Int?
  let lang: String?
  let searchShape: String?
  let files: [SearchFile]
  let paths: [String]
  let truncated: Bool
  let total: Int?
  let webKind: String?
  let answer: String?
  let url: String?
  let statusCode: Int?
  let sources: [Source]

  static func from(_ view: [String: Any]?) -> Self? {
    guard let view, let card = view["card"] as? String else { return nil }
    let diffs = (view["diffs"] as? [[String: Any]] ?? []).compactMap { diff -> Diff? in
      guard let path = diff["path"] as? String, let newText = diff["newText"] as? String else { return nil }
      return Diff(path: path, oldText: diff["oldText"] as? String, newText: newText)
    }
    let lines = (view["lines"] as? [[String: Any]] ?? []).compactMap { line -> FileLine? in
      guard let number = DSHToolPresentationNumber.integerValue(line["number"]), let text = line["text"] as? String else { return nil }
      return FileLine(number: number, text: text)
    }
    let files = (view["files"] as? [[String: Any]] ?? []).compactMap { file -> SearchFile? in
      guard let path = file["path"] as? String else { return nil }
      let matches = (file["matches"] as? [[String: Any]] ?? []).compactMap { match -> SearchMatch? in
        guard let lineNumber = DSHToolPresentationNumber.integerValue(match["lineNumber"]), let line = match["line"] as? String else { return nil }
        return SearchMatch(lineNumber: lineNumber, line: line)
      }
      return SearchFile(path: path, matches: matches)
    }
    let sources = (view["sources"] as? [[String: Any]] ?? []).compactMap { source -> Source? in
      guard let url = source["url"] as? String else { return nil }
      return Source(url: url, title: source["title"] as? String, snippet: source["snippet"] as? String, publishedAt: source["publishedAt"] as? String)
    }
    return DSHToolPresentation(
      card: card, title: view["title"] as? String, path: view["path"] as? String,
      output: view["output"] as? String, exitCode: DSHToolPresentationNumber.integerValue(view["exitCode"]),
      signal: view["signal"] as? String, cwd: view["cwd"] as? String,
      description: view["description"] as? String, diffs: diffs, lines: lines,
      totalLines: DSHToolPresentationNumber.integerValue(view["totalLines"]), lang: view["lang"] as? String,
      searchShape: view["shape"] as? String, files: files,
      paths: view["paths"] as? [String] ?? [], truncated: view["truncated"] as? Bool ?? false,
      total: DSHToolPresentationNumber.integerValue(view["total"]), webKind: view["kind"] as? String,
      answer: view["answer"] as? String, url: view["url"] as? String,
      statusCode: DSHToolPresentationNumber.integerValue(view["statusCode"]), sources: sources
    )
  }
}

struct DSHAttachmentRef: Decodable, Equatable { let attachmentId: String; let mediaType: String; let bytes: Int; let width: Int; let height: Int; let name: String? }

extension DSHAttachmentRef {
  static func fromMessage(_ message: DSHJSONValue?) -> Self? {
    fromContent(message?.object?["content"]?.array ?? []).first
  }

  static func fromContent(_ content: [DSHJSONValue]) -> [Self] {
    content.compactMap { block in
      guard let block = block.object,
            block["type"]?.string == "image",
            let attachment = block["attachment"]?.object,
            let attachmentId = attachment["attachmentId"]?.string,
            let mediaType = attachment["mediaType"]?.string,
            let bytes = attachment["bytes"]?.integer
      else { return nil }
      return Self(
        attachmentId: attachmentId,
        mediaType: mediaType,
        bytes: bytes,
        width: attachment["width"]?.integer ?? 0,
        height: attachment["height"]?.integer ?? 0,
        name: attachment["name"]?.string)
    }
  }
}

struct DSHTodoItem: Decodable, Identifiable {
  let content: String
  let status: String
  var id: String { content }
}

struct DSHFoldedHistory {
  let messages: [DSHMessage]
  let tools: [DSHToolActivity]
  let toolSequences: [String: Int]
  let activeTurnStartedAt: Date?
  var workflowEvents: [(seq: Int, event: DSHSessionEvent)] = []
  /// The sequences this fold covers; its workflow events are the whole truth for them.
  var sequenceRange: ClosedRange<Int>?
}

/// Workflow runs rebuilt from their events. History arrives newest page first and
/// a run can span pages, so runs are folded from a sequence-keyed log rather than
/// applied as events land.
struct DSHWorkflowLog {
  private var events: [Int: DSHSessionEvent] = [:]
  private var parentSessionID = ""
  private(set) var runs: [DSHWorkflowRun] = []

  /// Records live events, or a history fold that replaces everything logged within
  /// `range`. A Host that crashed before flushing can reuse sequence numbers, so a
  /// folded page wins over whatever was logged for the same span.
  mutating func record(
    _ newEvents: [(seq: Int, event: DSHSessionEvent)],
    parentSessionID: String,
    replacing range: ClosedRange<Int>? = nil
  ) {
    let replaced = range.map { range in events.keys.contains(where: range.contains) } ?? false
    guard !newEvents.isEmpty || replaced else { return }
    self.parentSessionID = parentSessionID
    if let range { events = events.filter { !range.contains($0.key) } }
    let latest = events.keys.max() ?? Int.min
    for item in newEvents { events[item.seq] = item.event }
    if !replaced, newEvents.allSatisfy({ $0.seq > latest }) {
      for item in newEvents.sorted(by: { $0.seq < $1.seq }) { Self.apply(item.event, to: &runs, parent: parentSessionID) }
    } else {
      rebuild()
    }
  }

  private mutating func rebuild() {
    var rebuilt: [DSHWorkflowRun] = []
    for seq in events.keys.sorted() {
      guard let event = events[seq] else { continue }
      Self.apply(event, to: &rebuilt, parent: parentSessionID)
    }
    runs = rebuilt
  }

  private static func apply(_ event: DSHSessionEvent, to runs: inout [DSHWorkflowRun], parent: String) {
    switch event {
    case .workflowRunStarted(let id, let name):
      runs.append(DSHWorkflowRun(id: id, parentSessionId: parent, name: name))
    case .workflowAgentStarted(let runID, let member, let label, let phase, let childID):
      guard let run = runs.firstIndex(where: { $0.id == runID }) else { return }
      runs[run].members.append(.init(id: member, label: label, phase: phase, childId: childID, outcome: nil))
    case .workflowAgentEnded(let runID, let member, let outcome):
      guard let run = runs.firstIndex(where: { $0.id == runID }),
            let index = runs[run].members.firstIndex(where: { $0.id == member })
      else { return }
      runs[run].members[index].outcome = outcome
    case .workflowRunEnded(let runID, let reason):
      guard let run = runs.firstIndex(where: { $0.id == runID }) else { return }
      runs[run].stopReason = reason
    default:
      return
    }
  }
}

enum DSHTranscriptMessageMarker {
  static let streamingAssistantHostMessageID = "\u{0}dsh-streaming-assistant"
  static let pendingLocalUserHostMessageID = "\u{0}dsh-pending-local-user"

  static func matchesPendingLocalUserEcho(
    localText: String,
    incomingText: String,
    attachment: DSHAttachmentRef?
  ) -> Bool {
    if incomingText == localText { return true }
    return matchesAttachmentEcho(
      localText: localText,
      incomingText: incomingText,
      attachment: attachment)
  }

  /// A sent image is echoed locally as text plus a `[图片附件：…]` line, which the
  /// Host's message does not carry.
  static func matchesAttachmentEcho(
    localText: String,
    incomingText: String,
    attachment: DSHAttachmentRef?
  ) -> Bool {
    guard attachment != nil,
          let marker = localText.range(of: "\n[图片附件：") else { return false }
    return incomingText == String(localText[..<marker.lowerBound])
  }
}

enum DSHHistoryPageMerge {
  static func prepend(
    _ olderMessages: [DSHMessage],
    to currentMessages: [DSHMessage]
  ) -> [DSHMessage] {
    guard !olderMessages.isEmpty else { return currentMessages }
    let currentIDs = Set(currentMessages.map(\.id))
    return olderMessages.filter { !currentIDs.contains($0.id) } + currentMessages
  }

  /// A snapshot or first page replaces the rows, except a message this app sent that
  /// the Host has not logged yet: the first snapshot of a new session usually lands
  /// before its first message is written. An empty result is the empty state, not a row.
  static func replacingRows(
    with folded: [DSHMessage],
    keepingUnloggedFrom current: [DSHMessage]
  ) -> [DSHMessage] {
    let unlogged = current.filter { row in
      row.hostMessageId == DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
        && !folded.contains { matchesPendingEcho(row, $0) }
    }
    return folded + unlogged
  }

  /// Apply a `session/follow` snapshot or a first history page to the displayed rows.
  ///
  /// A follow's first frame carries ONE message and ONE turn (a WebSocket frame
  /// has a size cap). So when a stream is (re)opened while a complete transcript
  /// is already on screen, replacing the array with that frame throws the whole
  /// conversation away — the list collapses to a single row and then grows back
  /// page by page. Only replace when the snapshot is the whole log, is at least as
  /// long as what is displayed, or nothing usable is displayed yet.
  static func applyFollowSnapshot(
    _ incoming: [DSHMessage],
    to current: [DSHMessage],
    isComplete: Bool
  ) -> [DSHMessage] {
    guard !current.isEmpty else { return incoming }
    // The whole log is authoritative even when shorter: compaction removes rows.
    if isComplete || incoming.count >= current.count {
      return replacingRows(with: incoming, keepingUnloggedFrom: current)
    }
    // Otherwise a shorter frame is a partial (first-frame) payload. Fold it into
    // the rows already on screen.
    return mergeTail(incoming, into: current)
  }

  /// Merge a follow snapshot's recent tail into an already visible transcript.
  /// Existing row UUIDs are retained so LazyVStack identities and scroll
  /// anchors stay stable while reconnect repair runs in the background.
  static func mergeTail(
    _ incomingMessages: [DSHMessage],
    into currentMessages: [DSHMessage]
  ) -> [DSHMessage] {
    var merged = currentMessages
    for incoming in incomingMessages {
      if let index = merged.firstIndex(where: { sameRow($0, incoming) }) {
        var updated = merged[index]
        updated.text = incoming.text
        updated.timestamp = incoming.timestamp
        if let attachment = incoming.attachment { updated.attachment = attachment }
        if let reasoning = incoming.reasoning { updated.reasoning = reasoning }
        if let hostMessageId = incoming.hostMessageId { updated.hostMessageId = hostMessageId }
        if let toolCallId = incoming.toolCallId { updated.toolCallId = toolCallId }
        updated.isRelayMessage = incoming.isRelayMessage
        merged[index] = updated
      } else {
        merged.append(incoming)
      }
    }
    return merged
  }

  private static func sameRow(
    _ existing: DSHMessage,
    _ incoming: DSHMessage
  ) -> Bool {
    if let existingKey = durableKey(existing),
       let incomingKey = durableKey(incoming) {
      return existingKey == incomingKey
    }
    if matchesPendingEcho(existing, incoming) || matchesPendingEcho(incoming, existing) {
      return true
    }
    return contentKey(existing) == contentKey(incoming)
  }

  private static func durableKey(_ message: DSHMessage) -> String? {
    if let hostID = message.hostMessageId {
      if hostID == DSHTranscriptMessageMarker.streamingAssistantHostMessageID {
        return "streaming-assistant"
      }
      if hostID == DSHTranscriptMessageMarker.pendingLocalUserHostMessageID {
        return nil
      }
      if !hostID.isEmpty { return "host:\(hostID)" }
    }
    if let callID = message.toolCallId, !callID.isEmpty {
      return "tool:\(callID)"
    }
    return nil
  }

  private static func matchesPendingEcho(
    _ pending: DSHMessage,
    _ durable: DSHMessage
  ) -> Bool {
    pending.hostMessageId == DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
      && pending.role == .user
      && durable.role == .user
      && pending.text == durable.text
      && pending.attachment?.attachmentId == durable.attachment?.attachmentId
  }

  private static func contentKey(_ message: DSHMessage) -> String {
    let millis = Int((message.timestamp.timeIntervalSince1970 * 1_000).rounded())
    return [
      String(describing: message.role),
      message.text,
      message.attachment?.attachmentId ?? "",
      message.toolCallId ?? "",
      String(millis),
    ].joined(separator: "\u{1f}")
  }
}
