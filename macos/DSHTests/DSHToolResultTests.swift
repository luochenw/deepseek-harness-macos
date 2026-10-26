import Foundation
@testable import DSHAppLib

private func toolPresentation(
  card: String,
  title: String? = nil,
  output: String? = nil,
  exitCode: Int? = nil,
  cwd: String? = nil,
  description: String? = nil,
  url: String? = nil,
  statusCode: Int? = nil,
  webKind: String? = nil
) -> HarnessController.ToolPresentation {
  HarnessController.ToolPresentation(
    card: card,
    title: title,
    path: nil,
    output: output,
    exitCode: exitCode,
    signal: nil,
    cwd: cwd,
    description: description,
    diffs: [],
    lines: [],
    totalLines: nil,
    lang: nil,
    searchShape: nil,
    files: [],
    paths: [],
    truncated: false,
    total: nil,
    webKind: webKind,
    answer: nil,
    url: url,
    statusCode: statusCode,
    sources: [])
}

private func nestedToolResult(callId: String, text: String, isError: Bool = false) -> [String: Any] {
  [
    "turn": 1,
    "step": 1,
    "message": [
      "id": "result-\(callId)",
      "role": "user",
      "source": ["kind": "tool", "callId": callId],
      "content": [[
        "type": "tool-result",
        "toolCallId": callId,
        "isError": isError,
        "content": [["type": "text", "text": text]],
      ]],
    ],
  ]
}

private func flatToolResult(callId: String, text: String, isError: Bool = false) -> [String: Any] {
  [
    "turn": 1,
    "step": 1,
    "message": [
      "id": "result-\(callId)",
      "role": "tool",
      "source": ["kind": "tool", "callId": callId],
      "toolCallId": callId,
      "isError": isError,
      "content": [["type": "text", "text": text]],
    ],
  ]
}

private func testToolResultDecoder_readsNestedCallIdAndContent() throws {
  let decoded = DSHToolResultDecoder.live(
    from: nestedToolResult(callId: "call-a", text: "nested output"))

  try expectEqual(decoded?.callId, "call-a")
  try expectEqual(decoded?.output, "nested output")
  try expectEqual(decoded?.isError, false)
}

private func testToolResultDecoder_readsFlatDSH02Message() throws {
  let data = flatToolResult(
    callId: "call-flat",
    text: "flat output",
    isError: true)
  let decoded = DSHToolResultDecoder.live(from: data)
  let encoded = try JSONSerialization.data(withJSONObject: data)
  let historyData = try JSONDecoder().decode(DSHJSONValue.self, from: encoded).object
  let history = historyData.flatMap(DSHToolResultDecoder.history(from:))

  try expectEqual(decoded?.callId, "call-flat")
  try expectEqual(decoded?.output, "flat output")
  try expectEqual(decoded?.isError, true)
  try expectEqual(history?.callId, "call-flat")
  try expectEqual(history?.output, "flat output")
  try expectEqual(history?.isError, true)
}

private func testToolPresentation_mergeKeepsTerminalCallContextForGenericResult() throws {
  let call = toolPresentation(
    card: "terminal",
    title: "ls -la",
    cwd: "/workspace",
    description: "列出目录")
  let generic = HarnessController.ToolPresentation.fromEventView([
    "for": "result",
    "view": [
      "card": "generic",
      "content": [["type": "text", "text": "file-a\nfile-b"]],
    ],
  ])
  let merged = HarnessController.ToolPresentation.merging(
    call: call,
    result: generic,
    rawOutput: "fallback")

  try expectEqual(merged?.card, "terminal")
  try expectEqual(merged?.title, "ls -la")
  try expectEqual(merged?.cwd, "/workspace")
  try expectEqual(merged?.description, "列出目录")
  try expectEqual(merged?.output, "file-a\nfile-b")
}

private func testToolPresentation_mergeKeepsRawWebFetchBody() throws {
  let call = toolPresentation(card: "generic", title: "网页抓取")
  let result = toolPresentation(
    card: "web",
    url: "https://example.com/page",
    statusCode: 200,
    webKind: "fetch")
  let merged = HarnessController.ToolPresentation.merging(
    call: call,
    result: result,
    rawOutput: "# Page body")

  try expectEqual(merged?.card, "web")
  try expectEqual(merged?.url, "https://example.com/page")
  try expectEqual(merged?.output, "# Page body")
}

private func testLiveToolResult_updatesOnlyCorrelatedCallAndMergesCallContext() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "工具会话",
      workspaceName: "测试",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "root-session"

    let terminal = HarnessController.ToolActivity(
      callId: "call-terminal",
      name: "bash",
      summary: "正在运行",
      state: .running,
      output: "",
      presentation: toolPresentation(
        card: "terminal",
        title: "ls -la",
        cwd: "/workspace",
        description: "列出目录"))
    let other = HarnessController.ToolActivity(
      callId: "call-other",
      name: "read",
      summary: "正在运行",
      state: .running,
      output: "",
      presentation: toolPresentation(card: "read", title: "读取"))
    harness.activeTools = [terminal, other]

    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "root-session",
      "event": [
        "type": "tool/result",
        "data": nestedToolResult(callId: "call-terminal", text: "a\nb"),
      ],
      "view": [
        "for": "result",
        "view": [
          "card": "terminal",
          "output": "a\nb",
          "exitCode": 0,
        ],
      ],
    ])

    try expectEqual(harness.activeTools[0].state, .succeeded)
    try expectEqual(harness.activeTools[0].output, "a\nb")
    try expectEqual(harness.activeTools[0].presentation?.card, "terminal")
    try expectEqual(harness.activeTools[0].presentation?.cwd, "/workspace")
    try expectEqual(harness.activeTools[0].presentation?.description, "列出目录")
    try expectEqual(harness.activeTools[0].presentation?.exitCode, 0)
    try expectEqual(harness.activeTools[1].state, .running)
    try expectEqual(harness.activeTools[1].output, "")
  }
}

private func testLiveFlatRunCodeResult_settlesAndPreservesOutput() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "run_code",
      workspaceName: "测试",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "root-session"
    harness.activeTools = [
      HarnessController.ToolActivity(
        callId: "call-run-code",
        name: "run_code",
        summary: "正在运行",
        state: .running,
        output: "",
        presentation: nil),
      HarnessController.ToolActivity(
        callId: "call-still-running",
        name: "run_code",
        summary: "正在运行",
        state: .running,
        output: "",
        presentation: nil),
    ]

    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "root-session",
      "event": [
        "type": "tool/result",
        "seq": 4,
        "data": flatToolResult(
          callId: "call-run-code",
          text: "script output"),
      ],
    ])

    try expectEqual(harness.activeTools[0].state, .succeeded)
    try expectEqual(harness.activeTools[0].output, "script output")
    try expectEqual(harness.activeTools[1].state, .running)
  }
}

private func testHistoryToolResult_usesNestedCallIdAndMessageContent() throws {
  let page = try JSONDecoder().decode(DSHHistoryPage.self, from: Data("""
  {
    "events": [
      {
        "event": {
          "type": "tool/call",
          "seq": 1,
          "time": 1000,
          "data": {"turn":1,"step":1,"callId":"call-a","name":"bash","arguments":"{}"}
        },
        "view": {"for":"call","view":{"card":"terminal","title":"ls -la","cwd":"/workspace","description":"列出目录"}}
      },
      {
        "event": {
          "type": "tool/result",
          "seq": 2,
          "time": 2000,
          "data": {
            "turn":1,
            "step":1,
            "message": {
              "id":"result-call-a",
              "role":"user",
              "source":{"kind":"tool","callId":"call-a"},
              "content":[{"type":"tool-result","toolCallId":"call-a","isError":false,"content":[{"type":"text","text":"nested history output"}]}]
            }
          }
        },
        "view": {"for":"result","view":{"card":"terminal","output":"nested history output","exitCode":0}}
      }
    ],
    "hasMore": false
  }
  """.utf8))

  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    _ = harness.foldHistory(page.events)
    guard let tool = harness.activeTools.first(where: { $0.callId == "call-a" }) else {
      throw TestFailure.message("expected correlated tool activity")
    }
    try expectEqual(tool.state, .succeeded)
    try expectEqual(tool.output, "nested history output")
    try expectEqual(tool.presentation?.card, "terminal")
    try expectEqual(tool.presentation?.cwd, "/workspace")
    try expectEqual(tool.presentation?.description, "列出目录")
    try expectEqual(tool.presentation?.exitCode, 0)
  }
}

private func testHistoryFlatResults_settleCompletedTurnsAndRetainOnlyCurrentRunningCall() throws {
  let page = try JSONDecoder().decode(DSHHistoryPage.self, from: Data("""
  {
    "events": [
      {
        "event": {
          "type": "tool/call",
          "seq": 1,
          "time": 1000,
          "data": {"turn":1,"step":1,"callId":"call-a","name":"run_code","arguments":"{}"}
        }
      },
      {
        "event": {
          "type": "tool/result",
          "seq": 2,
          "time": 2000,
          "data": {
            "turn":1,
            "step":1,
            "message": {
              "source":{"kind":"tool","callId":"call-a"},
              "toolCallId":"call-a",
              "isError":false,
              "content":[{"type":"text","text":"result-a"}]
            }
          }
        }
      },
      {
        "event": {
          "type": "tool/call",
          "seq": 3,
          "time": 3000,
          "data": {"turn":1,"step":2,"callId":"call-b","name":"run_code","arguments":"{}"}
        }
      },
      {
        "event": {
          "type": "turn/end",
          "seq": 4,
          "time": 4000,
          "data": {"turn":1,"reason":{"kind":"completed"}}
        }
      },
      {
        "event": {
          "type": "tool/call",
          "seq": 5,
          "time": 5000,
          "data": {"turn":2,"step":1,"callId":"call-current","name":"run_code","arguments":"{}"}
        }
      }
    ],
    "hasMore": false
  }
  """.utf8))

  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let folded = harness.foldHistoryContent(page.events)
    let byID = Dictionary(uniqueKeysWithValues: folded.tools.map { ($0.callId, $0) })
    try expectEqual(byID["call-a"]?.state, .succeeded)
    try expectEqual(byID["call-a"]?.output, "result-a")
    try expectEqual(byID["call-b"]?.state, .succeeded)
    try expectEqual(byID["call-current"]?.state, .running)
  }
}

let dshToolResultTests: [NamedTest] = [
  ("Tool result decoder reads nested call id and content", testToolResultDecoder_readsNestedCallIdAndContent),
  ("Tool result decoder reads flat DSH 0.2 message", testToolResultDecoder_readsFlatDSH02Message),
  ("Tool presentation merge keeps terminal call context for generic result", testToolPresentation_mergeKeepsTerminalCallContextForGenericResult),
  ("Tool presentation merge keeps raw web fetch body", testToolPresentation_mergeKeepsRawWebFetchBody),
  ("Live tool result updates only correlated call and merges call context", testLiveToolResult_updatesOnlyCorrelatedCallAndMergesCallContext),
  ("Live flat run_code result settles and preserves output", testLiveFlatRunCodeResult_settlesAndPreservesOutput),
  ("History tool result uses nested call id and message content", testHistoryToolResult_usesNestedCallIdAndMessageContent),
  ("History flat results settle completed turns and retain only current running call", testHistoryFlatResults_settleCompletedTurnsAndRetainOnlyCurrentRunningCall),
]
