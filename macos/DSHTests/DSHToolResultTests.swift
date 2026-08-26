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

private func testToolResultDecoder_readsNestedCallIdAndContent() throws {
  let decoded = DSHToolResultDecoder.live(
    from: nestedToolResult(callId: "call-a", text: "nested output"))

  try expectEqual(decoded?.callId, "call-a")
  try expectEqual(decoded?.output, "nested output")
  try expectEqual(decoded?.isError, false)
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

let dshToolResultTests: [NamedTest] = [
  ("Tool result decoder reads nested call id and content", testToolResultDecoder_readsNestedCallIdAndContent),
  ("Tool presentation merge keeps terminal call context for generic result", testToolPresentation_mergeKeepsTerminalCallContextForGenericResult),
  ("Tool presentation merge keeps raw web fetch body", testToolPresentation_mergeKeepsRawWebFetchBody),
  ("Live tool result updates only correlated call and merges call context", testLiveToolResult_updatesOnlyCorrelatedCallAndMergesCallContext),
  ("History tool result uses nested call id and message content", testHistoryToolResult_usesNestedCallIdAndMessageContent),
]
