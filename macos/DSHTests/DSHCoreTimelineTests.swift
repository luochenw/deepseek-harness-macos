import Foundation
@testable import DSHAppLib

struct DSHParityStep {
  let event: [String: Any]
  var view: [String: Any]?
}

func dshStep(
  _ type: String,
  _ seq: Int,
  _ data: [String: Any],
  view: [String: Any]? = nil
) -> DSHParityStep {
  DSHParityStep(
    event: ["type": type, "seq": seq, "time": 1_000_000 + seq * 1_000, "data": data],
    view: view)
}

private func text(_ value: String) -> [[String: Any]] { [["type": "text", "text": value]] }

private func imageBlock(_ id: String) -> [String: Any] {
  ["type": "image", "attachment": ["attachmentId": id, "mediaType": "image/png", "bytes": 10, "width": 1, "height": 1]]
}

/// Every event family the client handles, in the shapes the Host has actually
/// emitted: flat and nested messages, delta and legacy chunks, flat and legacy
/// tool results, and a tool call that never receives a result.
let dshParitySteps: [DSHParityStep] = [
  dshStep("turn/start", 1, [:]),
  dshStep("user/message", 2, [
    "id": "u1",
    "role": "user",
    "source": ["kind": "user"],
    "content": text("typed\n\n[工作区上下文]\ncwd=/Users/developer/project"),
  ]),
  dshStep("user/message", 3, [
    "id": "u-injected",
    "source": ["kind": "agent-instructions"],
    "content": text("injected context"),
  ]),
  dshStep("user/message", 4, [
    "id": "u2",
    "source": ["kind": "plugin", "plugin": "session-relay"],
    "content": text("relayed"),
  ]),
  dshStep("assistant/chunk", 5, ["chunk": ["type": "reasoning-delta", "text": "thinking"]]),
  dshStep("assistant/chunk", 6, ["chunk": ["type": "text-delta", "text": "Hello"]]),
  dshStep("assistant/chunk", 7, ["chunk": ["type": "text-delta", "textDelta": " world"]]),
  dshStep("assistant/message", 8, ["message": [
    "id": "a1",
    "content": [
      ["type": "reasoning", "text": "thinking"],
      ["type": "text", "text": "Hello world"],
    ],
  ]]),
  dshStep("tool/call", 9, [
    "callId": "c1",
    "name": "run_code",
    "arguments": "{\"code\":\"print(1)\",\"description\":\"Print one\"}",
  ]),
  dshStep("tool/ptc-dispatch-start", 10, [
    "rootCallId": "c1",
    "subCallId": "c1:1",
    "name": "bash",
    "arguments": ["command": "pwd"],
  ]),
  dshStep("tool/ptc-dispatch", 11, [
    "rootCallId": "c1",
    "subCallId": "c1:1",
    "name": "bash",
    "content": text("/tmp"),
    "isError": false,
  ]),
  dshStep("tool/result", 12, ["message": [
    "source": ["kind": "tool", "callId": "c1"],
    "toolCallId": "c1",
    "isError": false,
    "content": text("run output"),
  ]]),
  dshStep(
    "tool/call",
    13,
    ["callId": "c2", "name": "read", "arguments": ["path": "/tmp/a"]],
    view: ["view": ["card": "read", "title": "a", "path": "/tmp/a"]]),
  dshStep(
    "tool/result",
    14,
    ["callId": "c2", "result": text("denied"), "error": ["name": "Denied", "code": "E1"]],
    view: ["view": ["card": "read", "output": "denied view"]]),
  dshStep("tool/call", 15, ["callId": "c3", "name": "bash", "arguments": "{\"command\":\"sleep\"}"]),
  dshStep("todo/write", 16, ["todos": [
    ["content": "one", "status": "pending"],
    ["content": "two", "status": "completed"],
  ]]),
  dshStep("compaction/start", 17, [:]),
  dshStep("compaction/summary", 18, ["summary": "condensed"]),
  dshStep("compaction/end", 19, [:]),
  dshStep("text-chunks", 20, ["texts": ["Part"]]),
  dshStep("reasoning-chunks", 21, ["texts": ["more"]]),
  dshStep("assistant/message", 22, ["id": "a2", "content": [["type": "tool-call", "name": "bash"]]]),
  dshStep("assistant/message", 23, ["id": "a3", "content": [["type": "tool-call", "name": "read"]]]),
  dshStep("command/run", 24, ["name": "compact", "args": " now", "source": ["kind": "user"]]),
  dshStep("command/done", 25, ["text": "compacted", "kind": "success"]),
  dshStep("command/done", 26, ["text": "broken", "kind": "error"]),
  dshStep("plan/mode", 27, ["active": true]),
  dshStep("llm/retry", 28, ["retry": 2, "delayMs": 500, "provider": "relay"]),
  dshStep("llm/retry-started", 29, [:]),
  dshStep("tool-workflow/run-start", 30, ["runId": "w1", "name": "flow"]),
  dshStep("tool-workflow/agent-start", 31, ["runId": "w1", "seq": 1, "label": "first", "childId": "wc1"]),
  dshStep("tool-workflow/agent-end", 32, ["runId": "w1", "seq": 1, "outcome": "completed"]),
  dshStep("tool-workflow/run-end", 33, ["runId": "w1", "stopReason": "completed"]),
  dshStep("turn/end", 34, ["reason": ["kind": "error", "error": ["message": "boom"]]]),
  dshStep("turn/start", 35, [:]),
  dshStep("assistant/message", 36, ["id": "a4", "content": text("second")]),
  dshStep("turn/end", 37, ["reason": ["kind": "aborted"]]),
  dshStep("turn/start", 38, [:]),
  dshStep("turn/end", 39, ["reason": ["kind": "max-tokens"]]),
  dshStep("turn/start", 40, [:]),
  dshStep("assistant/chunk", 41, ["chunk": ["type": "block-end", "block": ["type": "text", "text": "open"]]]),
  dshStep("tool/call", 42, ["callId": "c4", "name": "read_image", "arguments": ["path": "/tmp/i.png"]]),
  dshStep("tool/result", 43, ["callId": "c4", "message": [
    "source": ["kind": "tool", "callId": "c4"],
    "content": [imageBlock("img-1")],
  ]]),
  dshStep("tool/result", 44, ["callId": "c4", "result": text("re-read without image")]),
  dshStep("tool/call", 45, ["callId": "c5", "name": "run_code", "arguments": "{\"code\":\"x\"}"]),
  dshStep("tool/code-dispatch-start", 46, [
    "parentCallId": "c5",
    "subCallId": "c5:1",
    "name": "bash",
    "arguments": ["command": "ls"],
  ]),
  dshStep("tool/code-dispatch", 47, [
    "rootCallId": "",
    "parentCallId": "c5",
    "subCallId": "c5:1",
    "name": "bash",
    "content": [imageBlock("img-2")],
    "isError": true,
  ]),
  dshStep("goal/change", 48, [:]),
  dshStep("user/message", 49, ["id": "u3", "source": ["kind": "user"], "content": text("with image") + [imageBlock("img-3")]]),
]

func dshFrame(_ item: DSHParityStep, sessionID: String) -> [String: Any] {
  var result: [String: Any] = ["type": "session/event", "sessionId": sessionID, "event": item.event]
  if let view = item.view { result["view"] = view }
  return result
}

func dshEntries(_ steps: [DSHParityStep]) throws -> [DSHHistoryEntry] {
  try steps.map { item in
    var object: [String: Any] = ["event": item.event]
    if let view = item.view { object["view"] = view }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(DSHHistoryEntry.self, from: data)
  }
}

private func rowID(_ value: String?) -> String {
  switch value {
  case nil: "-"
  case DSHTranscriptMessageMarker.streamingAssistantHostMessageID?: "streaming"
  case DSHTranscriptMessageMarker.pendingLocalUserHostMessageID?: "pending"
  case let value?: value
  }
}

func dshRows(_ messages: [DSHMessage]) -> [String] {
  messages.map { message in
    [
      "\(message.role)",
      message.text.replacingOccurrences(of: "\n", with: "⏎"),
      message.reasoning ?? "-",
      rowID(message.hostMessageId),
      message.toolCallId ?? "-",
      message.isRelayMessage ? "relay" : "-",
      message.attachment?.attachmentId ?? "-",
    ].joined(separator: " | ")
  }
}

func dshToolRows(_ tools: [DSHToolActivity]) -> [String] {
  tools
    .sorted { $0.callId < $1.callId }
    .map { tool in
      [
        tool.callId,
        tool.name,
        "\(tool.state)",
        tool.summary,
        tool.output,
        tool.presentation?.card ?? "-",
        tool.children.map { "\($0.callId):\($0.state)" }.joined(separator: ","),
        tool.arguments?.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "") ?? "-",
        tool.imageAttachments.map(\.attachmentId).joined(separator: ","),
      ].joined(separator: " | ")
    }
}

/// A live surface with no controller: what the timeline produces on its own.
struct DSHCoreLiveStore: DSHTimelineStore {
  var turnStartedAt: Date?
  var messages: [DSHMessage] = []
  var tools: [DSHToolActivity] = []
  var running = false
  var workflowLog = DSHWorkflowLog()

  mutating func withMessages(_ body: (inout [DSHMessage]) -> Void) { body(&messages) }
  mutating func addTool(_ tool: DSHToolActivity, seq: Int) { tools.append(tool) }
  mutating func updateTool(callID: String, seq: Int, _ update: (inout DSHToolActivity) -> Void) {
    guard let index = tools.lastIndex(where: { $0.callId == callID }) else { return }
    update(&tools[index])
  }
  mutating func settleRunningTools(as state: DSHToolActivity.State, seq: Int) {
    for index in tools.indices where tools[index].state == .running { tools[index].settle(as: state) }
  }
  mutating func setRunning(_ running: Bool) { self.running = running }
  mutating func recordWorkflowEvent(_ event: DSHSessionEvent, seq: Int) {
    workflowLog.record([(seq, event)], parentSessionID: "root")
  }
}

@MainActor
func dshRunCoreLive(_ steps: [DSHParityStep] = dshParitySteps) throws -> DSHCoreLiveStore {
  var store = DSHCoreLiveStore()
  for entry in try dshEntries(steps) {
    guard let event = DSHSessionEvent(raw: entry.event, view: entry.view) else { continue }
    DSHSessionTimeline.apply(event, raw: entry.event, mode: .live, to: &store)
  }
  return store
}

/// Commands are the one row difference: while a turn runs, `send()` shows them.
private func isCommandRow(_ row: String) -> Bool {
  row.hasPrefix("user | /compact") || row.hasPrefix("system | compacted") || row.hasPrefix("system | 命令失败")
}

private func testLiveAndReplay_renderTheSameRows() throws {
  try MainActor.assumeIsolated {
    let live = dshRows(try dshRunCoreLive().messages)
    let replay = dshRows(DSHReplayTimelineStore.fold(try dshEntries(dshParitySteps)).messages)
    try expectEqual(replay.filter { !isCommandRow($0) }, live)
    try expect(replay.count == live.count + 3, "only the three command rows are replay-only")
  }
}

/// Live and replay could agree and both be wrong, so the rows are also pinned. These
/// are the rows the app rendered before the timeline existed, plus the three turn
/// outcome rows the transcript now shows while a turn is watched, and the durable id
/// user rows now carry so a reopened transcript can merge them.
private func testLiveRows_matchTheExpectedTranscript() throws {
  try MainActor.assumeIsolated {
    let live = try dshRunCoreLive()
    try expectEqual(dshRows(live.messages), [
      "user | typed | - | u1 | - | - | -",
      "user | relayed | - | u2 | - | relay | -",
      "assistant | Hello world | thinking | a1 | - | - | -",
      "tool | run_code | - | - | c1 | - | -",
      "tool | read | - | - | c2 | - | -",
      "tool | bash | - | - | c3 | - | -",
      "system | 历史上下文已压缩。摘要：condensed | - | - | - | - | -",
      "assistant | Part | more | a2 | - | - | -",
      "system | 本轮执行失败：boom | - | - | - | - | -",
      "system | 本轮用时 33 秒 | - | - | - | - | -",
      "assistant | second | - | a4 | - | - | -",
      "system | 本轮已中断 | - | - | - | - | -",
      "system | 本轮用时 2.0 秒 | - | - | - | - | -",
      "system | 本轮达到最大输出 token 限制 | - | - | - | - | -",
      "system | 本轮用时 1.0 秒 | - | - | - | - | -",
      "assistant | open | - | streaming | - | - | -",
      "tool | read_image | - | - | c4 | - | -",
      "tool | run_code | - | - | c5 | - | -",
      "user | with image | - | u3 | - | - | img-3",
    ])
    try expectEqual(dshToolRows(live.tools), [
      #"c1 | run_code | succeeded | 正在运行 | run output | code | c1:1:succeeded | {"code":"print(1)","description":"Printone"} | "#,
      #"c2 | read | failed | Denied · E1 | denied view | read |  | {"path":"\/tmp\/a"} | "#,
      #"c3 | bash | interrupted | 正在运行 |  | - |  | {"command":"sleep"} | "#,
      #"c4 | read_image | succeeded | 正在运行 | re-read without image | image |  | {"path":"\/tmp\/i.png"} | img-1"#,
      #"c5 | run_code | running | 正在运行 |  | code | c5:1:failed | {"code":"x"} | "#,
    ])
  }
}

private func testTodoUpdates_addNoRows() throws {
  try MainActor.assumeIsolated {
    let steps = [
      dshStep("tool/call", 1, ["callId": "a", "name": "bash"]),
      dshStep("todo/write", 2, ["todos": [["content": "one", "status": "pending"]]]),
      dshStep("tool/call", 3, ["callId": "b", "name": "bash"]),
    ]
    let rows = DSHReplayTimelineStore.fold(try dshEntries(steps)).messages
    try expectEqual(rows.map(\.role), [.tool, .tool])
  }
}

private func testStreamedText_survivesAnEmptyFinalMessage() throws {
  try MainActor.assumeIsolated {
    let steps = [
      dshStep("assistant/chunk", 1, ["chunk": ["type": "text-delta", "text": "kept"]]),
      dshStep("assistant/message", 2, ["id": "final", "content": [["type": "tool-call", "name": "bash"]]]),
    ]
    let replay = DSHReplayTimelineStore.fold(try dshEntries(steps)).messages
    try expectEqual(replay.map(\.text), ["kept"])
    try expectEqual(replay.first?.hostMessageId, "final")
  }
}

private func toolEndingTurn(_ reason: String) -> [DSHParityStep] {
  [
    dshStep("tool/call", 1, ["callId": "open", "name": "run_code", "arguments": "{\"code\":\"x\"}"]),
    dshStep("tool/ptc-dispatch-start", 2, ["rootCallId": "open", "subCallId": "open:1", "name": "bash"]),
    dshStep("turn/end", 3, ["reason": ["kind": reason]]),
  ]
}

private func testInterruptedTurn_doesNotReportOpenToolsAsSucceeded() throws {
  try MainActor.assumeIsolated {
    for reason in ["aborted", "interrupted", "error", "max-tokens"] {
      let live = try dshRunCoreLive(toolEndingTurn(reason)).tools[0]
      try expectEqual("\(reason) \(live.state)", "\(reason) interrupted")
      try expectEqual(live.children.map { "\(reason) \($0.state)" }, ["\(reason) interrupted"])
      let replay = DSHReplayTimelineStore.fold(try dshEntries(toolEndingTurn(reason))).tools[0]
      try expectEqual("\(reason) \(replay.state)", "\(reason) interrupted")
    }
    let completed = try dshRunCoreLive(toolEndingTurn("end-turn")).tools[0]
    try expectEqual("\(completed.state)", "succeeded")
  }
}

private func testFailedTurn_writesItsReasonIntoTheTranscript() throws {
  try MainActor.assumeIsolated {
    let steps = [dshStep("turn/end", 1, ["reason": ["kind": "error", "error": ["message": "boom"]]])]
    try expectEqual(try dshRunCoreLive(steps).messages.map(\.text), ["本轮执行失败：boom"])
  }
}

private func testReplayedRows_mergeIntoTheirLiveTwins() throws {
  try MainActor.assumeIsolated {
    let live = try dshRunCoreLive().messages
    let replay = DSHReplayTimelineStore.fold(try dshEntries(dshParitySteps)).messages
    let merged = DSHHistoryPageMerge.mergeTail(replay, into: live)
    try expectEqual(merged.count, live.count + 3)
  }
}

private func testFailedAttempt_keepsWhatStreamedOnReopen() throws {
  try MainActor.assumeIsolated {
    let steps = [
      dshStep("assistant/chunk", 1, ["chunk": ["type": "text-delta", "text": "partial"]]),
      dshStep("assistant/attempt", 2, ["turn": 1, "step": 1, "stream": [
        ["time": 1, "chunk": ["type": "text-delta", "text": "partial"]],
      ]]),
    ]
    let live = try dshRunCoreLive(steps).messages
    // History logs the stream only inside the attempt.
    let replay = DSHReplayTimelineStore.fold(try dshEntries([steps[1]])).messages
    try expectEqual(dshRows(live), ["assistant | partial | - | - | - | - | -"])
    try expectEqual(dshRows(replay), dshRows(live))
  }
}

private func testFailedAttempt_mergesWithItsReplayedTwin() throws {
  try MainActor.assumeIsolated {
    let steps = [
      dshStep("assistant/chunk", 1, ["chunk": ["type": "text-delta", "text": "partial"]]),
      dshStep("assistant/attempt", 9, ["turn": 1, "step": 1, "stream": [
        ["time": 1, "chunk": ["type": "text-delta", "text": "partial"]],
      ]]),
    ]
    let live = try dshRunCoreLive(steps).messages
    let replay = DSHReplayTimelineStore.fold(try dshEntries([steps[1]])).messages
    try expectEqual(DSHHistoryPageMerge.mergeTail(replay, into: live).count, 1)
  }
}

private func testLocalEcho_mergesWithItsReplayedTwin() throws {
  try MainActor.assumeIsolated {
    var local = DSHMessage(role: .user, text: "hi", timestamp: Date(timeIntervalSince1970: 1))
    local.hostMessageId = DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
    var store = DSHCoreLiveStore()
    store.messages = [local]
    let step = dshStep("user/message", 5, ["id": "u", "source": ["kind": "user"], "content": [["type": "text", "text": "hi"]]])
    let entry = try dshEntries([step])[0]
    DSHSessionTimeline.apply(try unwrapEvent(entry), raw: entry.event, mode: .live, to: &store)
    let replay = DSHReplayTimelineStore.fold([entry]).messages
    try expectEqual(DSHHistoryPageMerge.mergeTail(replay, into: store.messages).count, 1)
  }
}

private func unwrapEvent(_ entry: DSHHistoryEntry) throws -> DSHSessionEvent {
  guard let event = DSHSessionEvent(raw: entry.event, view: entry.view) else {
    throw TestFailure.message("fixture event did not decode")
  }
  return event
}

private func testFirstSnapshot_keepsAMessageTheHostHasNotLoggedYet() throws {
  var echo = DSHMessage(role: .user, text: "第一条", timestamp: Date())
  echo.hostMessageId = DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
  let connected = DSHMessage(role: .system, text: "已连接到持久 DSH 会话。")
  let empty = DSHHistoryPageMerge.replacingRows(with: [], keepingUnloggedFrom: [connected, echo])
  try expectEqual(empty.map(\.text), ["第一条"])
  var logged = DSHMessage(role: .user, text: "第一条", timestamp: Date())
  logged.hostMessageId = "u1"
  let caughtUp = DSHHistoryPageMerge.replacingRows(with: [logged], keepingUnloggedFrom: [echo])
  try expectEqual(caughtUp.map(\.hostMessageId), ["u1"])
  try expect(DSHHistoryPageMerge.replacingRows(with: [], keepingUnloggedFrom: [connected]).isEmpty,
             "an empty session shows the empty state, not a placeholder row")
}

private func testSnapshotTail_keepsToolsOfEarlierRows() throws {
  let earlier = DSHToolActivity(callId: "old", name: "bash", summary: "", state: .succeeded, output: "done")
  let cachedTail = DSHToolActivity(callId: "new", name: "bash", summary: "", state: .running, output: "")
  let snapshotTail = DSHToolActivity(callId: "new", name: "bash", summary: "", state: .succeeded, output: "ok")
  let merged = DSHToolActivityMerge.mergingTail([snapshotTail], into: [earlier, cachedTail])
  try expectEqual(merged.map(\.callId), ["old", "new"])
  try expectEqual("\(merged[1].state)", "succeeded")
}

private func testWorkflowLog_replacesWhatAReusedSequenceLogged() throws {
  var log = DSHWorkflowLog()
  log.record([(100, .workflowRunStarted(id: "ghost", name: "lost in a crash"))], parentSessionID: "root")
  // After the crash the Host wrote other events at 100...102.
  log.record([], parentSessionID: "root", replacing: 100...102)
  try expect(log.runs.isEmpty)
}

private func testWorkflowLog_rebuildsRunsAcrossPagesInAnyOrder() throws {
  try MainActor.assumeIsolated {
    let newest = DSHReplayTimelineStore.fold(try dshEntries([
      dshStep("tool-workflow/agent-end", 3, ["runId": "w", "seq": 1, "outcome": "failed"]),
      dshStep("tool-workflow/run-end", 4, ["runId": "w", "stopReason": "error"]),
    ]))
    let older = DSHReplayTimelineStore.fold(try dshEntries([
      dshStep("tool-workflow/run-start", 1, ["runId": "w", "name": "flow"]),
      dshStep("tool-workflow/agent-start", 2, ["runId": "w", "seq": 1, "label": "a", "childId": "c"]),
    ]))
    var log = DSHWorkflowLog()
    log.record(newest.workflowEvents, parentSessionID: "root")
    try expect(log.runs.isEmpty, "a run is unknown until its start is seen")
    log.record(older.workflowEvents, parentSessionID: "root")
    try expectEqual(log.runs.map(\.name), ["flow"])
    try expectEqual(log.runs.first?.members.first?.outcome, "failed")
    try expectEqual("\(log.runs.first?.status ?? .running)", "failed")
  }
}

private func testSubcall_treatsEmptyRootAsAbsentAndKeepsParentlessCalls() throws {
  let viaParent = DSHSubcallDecoder.decode(from: decodedObject([
    "rootCallId": "", "parentCallId": "parent", "subCallId": "sub", "name": "bash",
  ]))
  try expectEqual(viaParent?.rootCallId, "parent")
  let parentless = DSHSubcallDecoder.decode(from: decodedObject(["subCallId": "sub", "name": "open"]))
  try expectEqual(parentless?.callId, "sub")
  try expect(parentless?.rootCallId == nil)
  try expect(DSHSubcallDecoder.decode(from: decodedObject(["subCallId": "", "name": "open"])) == nil)
}

private func testUnknownEvent_isRecordedInsteadOfDropped() throws {
  let raw = DSHRawEvent(type: "future/thing", seq: 1, time: 0, data: .object([:]))
  guard case .ignored? = DSHSessionEvent(raw: raw, view: nil) else {
    throw TestFailure.message("unknown events decode to .ignored")
  }
  try expect(DSHContractDrift.unknownEventTypes.contains("future/thing"))
}

let dshCoreTimelineTests: [NamedTest] = [
  ("Live and replay render the same rows", testLiveAndReplay_renderTheSameRows),
  ("Live rows match the expected transcript", testLiveRows_matchTheExpectedTranscript),
  ("Todo updates add no transcript rows", testTodoUpdates_addNoRows),
  ("Streamed text survives an empty final message", testStreamedText_survivesAnEmptyFinalMessage),
  ("Interrupted turns do not report open tools as succeeded", testInterruptedTurn_doesNotReportOpenToolsAsSucceeded),
  ("Failed turns write their reason into the transcript", testFailedTurn_writesItsReasonIntoTheTranscript),
  ("Replayed rows merge into their live twins", testReplayedRows_mergeIntoTheirLiveTwins),
  ("Workflow log replaces what a reused sequence logged", testWorkflowLog_replacesWhatAReusedSequenceLogged),
  ("The first snapshot keeps a message the Host has not logged yet", testFirstSnapshot_keepsAMessageTheHostHasNotLoggedYet),
  ("A snapshot tail keeps the tools of earlier rows", testSnapshotTail_keepsToolsOfEarlierRows),
  ("A failed attempt keeps what streamed on reopen", testFailedAttempt_keepsWhatStreamedOnReopen),
  ("A local echo merges with its replayed twin", testLocalEcho_mergesWithItsReplayedTwin),
  ("A failed attempt merges with its replayed twin", testFailedAttempt_mergesWithItsReplayedTwin),
  ("Workflow log rebuilds runs across pages in any order", testWorkflowLog_rebuildsRunsAcrossPagesInAnyOrder),
  ("Subcalls treat an empty root as absent and keep parentless calls", testSubcall_treatsEmptyRootAsAbsentAndKeepsParentlessCalls),
  ("Unknown event types are recorded instead of dropped", testUnknownEvent_isRecordedInsteadOfDropped),
]
