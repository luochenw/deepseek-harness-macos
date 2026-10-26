import Foundation
@testable import DSHAppLib

private let runCodeArguments = """
{"code":"const r = await tools.bash({ command: \\"pwd\\" });\\nconsole.log(r.stdout.text);","description":"Check workspace path"}
"""

private func runCodeResult(callId: String, text: String) -> [String: Any] {
  [
    "turn": 1,
    "step": 1,
    "message": [
      "source": ["kind": "tool", "callId": callId],
      "toolCallId": callId,
      "isError": false,
      "content": [["type": "text", "text": text]],
    ],
  ]
}

private func testRunCodePresentation_extractsDescriptionAndSource() throws {
  let presentation = HarnessController.ToolPresentation.fromToolCall(
    name: "run_code",
    arguments: runCodeArguments)

  try expectEqual(presentation?.card, "code")
  try expectEqual(presentation?.title, "Check workspace path")
  try expect(presentation?.description?.contains("tools.bash") == true)
  try expectEqual(presentation?.lang, "typescript")
}

private func testLiveRunCode_tracksNestedCallAndFinalOutput() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "run_code",
      workspaceName: "test",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "session-run-code")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "session-run-code"

    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "session-run-code",
      "event": [
        "type": "tool/call",
        "seq": 1,
        "time": 1000,
        "data": [
          "callId": "root-call",
          "name": "run_code",
          "arguments": runCodeArguments,
        ],
      ],
    ])
    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "session-run-code",
      "event": [
        "type": "tool/ptc-dispatch-start",
        "seq": 2,
        "time": 1100,
        "data": [
          "rootCallId": "root-call",
          "subCallId": "root-call:code:1",
          "name": "bash",
          "arguments": ["command": "pwd", "description": "Print path"],
        ],
      ],
    ])
    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "session-run-code",
      "event": [
        "type": "tool/ptc-dispatch",
        "seq": 3,
        "time": 1200,
        "data": [
          "rootCallId": "root-call",
          "subCallId": "root-call:code:1",
          "name": "bash",
          "arguments": ["command": "pwd", "description": "Print path"],
          "isError": false,
          "content": [["type": "text", "text": "/workspace"]],
        ],
      ],
    ])
    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "session-run-code",
      "event": [
        "type": "tool/result",
        "seq": 4,
        "time": 1300,
        "data": runCodeResult(callId: "root-call", text: "/workspace"),
      ],
    ])

    let tool = try expectTool(harness.activeTools.first)
    try expectEqual(tool.state, .succeeded)
    try expectEqual(tool.output, "/workspace")
    try expectEqual(tool.presentation?.title, "Check workspace path")
    try expectEqual(tool.children.count, 1)
    try expectEqual(tool.children.first?.name, "bash")
    try expectEqual(tool.children.first?.title, "pwd")
    try expectEqual(tool.children.first?.state, .succeeded)
    try expectEqual(tool.children.first?.output, "/workspace")
  }
}

private func testHistoryRunCode_restoresNestedCallsAndDuration() throws {
  let page = try JSONDecoder().decode(DSHHistoryPage.self, from: Data("""
  {
    "events": [
      {
        "event": {
          "type": "turn/start",
          "seq": 1,
          "time": 1000,
          "data": {"turn":1}
        }
      },
      {
        "event": {
          "type": "tool/call",
          "seq": 2,
          "time": 1100,
          "data": {
            "callId":"root-call",
            "name":"run_code",
            "arguments":"{\\"code\\":\\"await tools.bash({ command: \\\\\\"pwd\\\\\\" })\\",\\"description\\":\\"Check workspace path\\"}"
          }
        }
      },
      {
        "event": {
          "type": "tool/ptc-dispatch-start",
          "seq": 3,
          "time": 1200,
          "data": {
            "rootCallId":"root-call",
            "subCallId":"root-call:code:1",
            "name":"bash",
            "arguments":{"command":"pwd","description":"Print path"}
          }
        }
      },
      {
        "event": {
          "type": "tool/ptc-dispatch",
          "seq": 4,
          "time": 1300,
          "data": {
            "rootCallId":"root-call",
            "subCallId":"root-call:code:1",
            "name":"bash",
            "arguments":{"command":"pwd","description":"Print path"},
            "isError":false,
            "content":[{"type":"text","text":"/workspace"}]
          }
        }
      },
      {
        "event": {
          "type": "tool/result",
          "seq": 5,
          "time": 1400,
          "data": {
            "message":{
              "source":{"kind":"tool","callId":"root-call"},
              "toolCallId":"root-call",
              "isError":false,
              "content":[{"type":"text","text":"/workspace"}]
            }
          }
        }
      },
      {
        "event": {
          "type": "turn/end",
          "seq": 6,
          "time": 3500,
          "data": {"turn":1,"reason":{"kind":"completed"}}
        }
      }
    ],
    "hasMore": false
  }
  """.utf8))

  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let messages = harness.foldHistory(page.events)
    let tool = try expectTool(harness.activeTools.first)
    try expectEqual(tool.presentation?.title, "Check workspace path")
    try expectEqual(tool.children.first?.title, "pwd")
    try expectEqual(tool.children.first?.output, "/workspace")
    try expectEqual(messages.last?.text, "本轮用时 2.5 秒")
  }
}

private func testHistoryRunCode_restoresNestedImageAttachments() throws {
  let page = try JSONDecoder().decode(DSHHistoryPage.self, from: Data("""
  {
    "events": [
      {
        "event": {
          "type": "tool/call",
          "seq": 1,
          "time": 1000,
          "data": {
            "callId": "root-image",
            "name": "run_code",
            "arguments": "{\\"code\\":\\"await tools.read_image({ file_path: \\\\\\"/tmp/frame.png\\\\\\" })\\",\\"description\\":\\"Inspect frame\\"}"
          }
        }
      },
      {
        "event": {
          "type": "tool/ptc-dispatch-start",
          "seq": 2,
          "time": 1100,
          "data": {
            "rootCallId": "root-image",
            "subCallId": "root-image:ptc:1",
            "name": "read_image",
            "arguments": {"file_path": "/tmp/frame.png"}
          }
        }
      },
      {
        "event": {
          "type": "tool/ptc-dispatch",
          "seq": 3,
          "time": 1200,
          "data": {
            "rootCallId": "root-image",
            "subCallId": "root-image:ptc:1",
            "name": "read_image",
            "arguments": {"file_path": "/tmp/frame.png"},
            "isError": false,
            "content": [
              {"type": "text", "text": "image/png image, 800x600 px"},
              {
                "type": "image",
                "attachment": {
                  "attachmentId": "sha256:image",
                  "mediaType": "image/png",
                  "bytes": 2048,
                  "width": 800,
                  "height": 600,
                  "name": "frame.png"
                }
              }
            ]
          }
        }
      }
    ],
    "hasMore": false
  }
  """.utf8))

  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    _ = harness.foldHistory(page.events)
    let tool = try expectTool(harness.activeTools.first)
    try expectEqual(tool.children.first?.title, "/tmp/frame.png")
    try expectEqual(tool.children.first?.imageAttachments.first?.attachmentId, "sha256:image")

    let instruction = DSHToolInstructionFlatten.instructions(from: [tool]).first
    guard case .child(let child) = instruction?.source else {
      throw TestFailure.message("expected the nested image call to become an instruction")
    }
    try expectEqual(child.imageAttachments.first?.name, "frame.png")
  }
}

private func testLiveTurnDuration_isPersistedAtTurnEnd() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "timing",
      workspaceName: "test",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "session-timing")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "session-timing"

    for event in [
      ["type": "turn/start", "seq": 1, "time": 1000, "data": ["turn": 1]],
      ["type": "turn/end", "seq": 2, "time": 1850, "data": [
        "turn": 1,
        "reason": ["kind": "completed"],
      ]],
    ] as [[String: Any]] {
      harness.consumeMuxFrame([
        "type": "session/event",
        "sessionId": "session-timing",
        "event": event,
      ])
    }

    try expectEqual(harness.sessions[0].messages.last?.text, "本轮用时 0.9 秒")
    try expectEqual(harness.sessions[0].turnStartedAt, nil)
  }
}

private func testHistoryFold_exposesActiveTurnStart() throws {
  let page = try JSONDecoder().decode(DSHHistoryPage.self, from: Data("""
  {
    "events": [
      {
        "event": {
          "type": "turn/start",
          "seq": 1,
          "time": 1000,
          "data": {"turn":1}
        }
      }
    ],
    "hasMore": false
  }
  """.utf8))

  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let folded = harness.foldHistoryContent(page.events)
    try expectEqual(
      folded.activeTurnStartedAt?.timeIntervalSince1970,
      1)
  }
}

private func testToolActivityMerge_preservesRunCodeDetailsAcrossSnapshot() throws {
  let presentation = HarnessController.ToolPresentation.fromToolCall(
    name: "run_code",
    arguments: runCodeArguments)
  let previous = HarnessController.ToolActivity(
    callId: "root-call",
    name: "run_code",
    summary: "正在运行",
    state: .running,
    output: "/workspace",
    presentation: presentation,
    children: [
      DSHToolChildActivity(
        callId: "root-call:code:1",
        name: "bash",
        title: "pwd",
        arguments: "{}",
        state: .succeeded,
        output: "/workspace"),
    ])
  let incoming = HarnessController.ToolActivity(
    callId: "root-call",
    name: "run_code",
    summary: "工具调用",
    state: .succeeded,
    output: "",
    presentation: nil)

  let merged = DSHToolActivityMerge.merging(incoming: incoming, previous: previous)

  try expectEqual(merged.presentation?.title, "Check workspace path")
  try expectEqual(merged.children.first?.title, "pwd")
  try expectEqual(merged.output, "/workspace")
  try expectEqual(merged.state, .succeeded)
}

private func testToolGroupStatus_usesLatestChildCommandWithoutCounts() throws {
  let first = HarnessController.ToolActivity(
    callId: "root-1",
    name: "run_code",
    summary: "正在运行",
    state: .succeeded,
    output: "",
    presentation: HarnessController.ToolPresentation.fromToolCall(
      name: "run_code",
      arguments: ["code": "await tools.bash({ command: \"pwd\" })", "description": "Check workspace"]))
  let second = HarnessController.ToolActivity(
    callId: "root-2",
    name: "run_code",
    summary: "正在运行",
    state: .running,
    output: "",
    presentation: HarnessController.ToolPresentation.fromToolCall(
      name: "run_code",
      arguments: ["code": "await tools.read({}); await tools.edit({});", "description": "Update files"]),
    children: [
      DSHToolChildActivity(
        callId: "child-1",
        name: "read",
        title: "Sources/App.swift",
        arguments: "{}",
        state: .succeeded,
        output: ""),
      DSHToolChildActivity(
        callId: "child-2",
        name: "edit",
        title: "Update composer layout",
        arguments: "{}",
        state: .running,
        output: ""),
    ])

  let summary = DSHToolGroupStatus.summary(for: [first, second])

  try expectEqual(summary?.detail, "Update composer layout")
  try expectEqual(summary?.running, true)
  try expectEqual(summary?.failed, false)
}

private func testToolGroupStatus_doesNotInventInstructionFromEmptyJSON() throws {
  let activity = HarnessController.ToolActivity(
    callId: "root-empty",
    name: "run_code",
    summary: "工具调用",
    state: .succeeded,
    output: "",
    presentation: HarnessController.ToolPresentation(
      card: "code",
      title: nil,
      path: nil,
      output: nil,
      exitCode: nil,
      signal: nil,
      cwd: nil,
      description: "{}",
      diffs: [],
      lines: [],
      totalLines: nil,
      lang: "typescript",
      searchShape: nil,
      files: [],
      paths: [],
      truncated: false,
      total: nil,
      webKind: nil,
      answer: nil,
      url: nil,
      statusCode: nil,
      sources: []))

  let summary = DSHToolGroupStatus.summary(for: [activity])

  try expectEqual(summary?.detail, nil)
  try expectEqual(DSHToolGroupStatus.instructionTitle(for: activity), nil)
  try expect(DSHToolInstructionFlatten.instructions(from: [activity]).isEmpty)
}

private func testToolInstructionFlatten_usesActualChildArguments() throws {
  let activity = HarnessController.ToolActivity(
    callId: "root-tools",
    name: "run_code",
    summary: "正在运行",
    state: .running,
    output: "",
    arguments: #"{"description":"Inspect the workspace"}"#,
    presentation: HarnessController.ToolPresentation.fromToolCall(
      name: "run_code",
      arguments: [
        "code": "await tools.bash({ command: \"rg TODO\" })",
        "description": "Inspect the workspace",
      ]),
    children: [
      DSHToolChildActivity(
        callId: "child-bash",
        name: "bash",
        title: "{}",
        arguments: #"{"command":"rg -n TODO src"}"#,
        state: .running,
        output: ""),
      DSHToolChildActivity(
        callId: "child-read",
        name: "read",
        title: "read",
        arguments: #"{"file_path":"README.md"}"#,
        state: .succeeded,
        output: "read output"),
    ])

  let instructions = DSHToolInstructionFlatten.instructions(from: [activity])

  try expectEqual(instructions.map(\.title), ["rg -n TODO src", "README.md"])
  try expectEqual(instructions.map(\.id), [
    "child:root-tools:child-bash",
    "child:root-tools:child-read",
  ])
}

private func expectTool(
  _ tool: HarnessController.ToolActivity?
) throws -> HarnessController.ToolActivity {
  guard let tool else {
    throw TestFailure.message("expected tool activity")
  }
  return tool
}

let dshRunCodeDetailsTests: [NamedTest] = [
  ("Run code presentation extracts description and source", testRunCodePresentation_extractsDescriptionAndSource),
  ("Live run code tracks nested call and final output", testLiveRunCode_tracksNestedCallAndFinalOutput),
  ("History run code restores nested calls and duration", testHistoryRunCode_restoresNestedCallsAndDuration),
  ("History run code restores nested image attachments", testHistoryRunCode_restoresNestedImageAttachments),
  ("Live turn duration is persisted at turn end", testLiveTurnDuration_isPersistedAtTurnEnd),
  ("History fold exposes active turn start", testHistoryFold_exposesActiveTurnStart),
  ("Tool activity merge preserves run code details across snapshot", testToolActivityMerge_preservesRunCodeDetailsAcrossSnapshot),
  ("Tool group status uses the latest child command", testToolGroupStatus_usesLatestChildCommandWithoutCounts),
  ("Tool group status does not invent instructions from empty JSON", testToolGroupStatus_doesNotInventInstructionFromEmptyJSON),
  ("Tool instruction flatten uses actual child arguments", testToolInstructionFlatten_usesActualChildArguments),
]
