import Foundation
@testable import DSHAppLib

private func testAssistantStreamProjection_readsCurrentAndLegacyShapes() throws {
  let current = DSHAssistantStreamProjection.live(
    eventType: "assistant/chunk",
    data: ["chunk": ["type": "text-delta", "text": "GO"]])
  let legacy = DSHAssistantStreamProjection.live(
    eventType: "assistant/chunk",
    data: ["chunk": ["type": "text-delta", "textDelta": "OLD"]])
  let reasoning = DSHAssistantStreamProjection.live(
    eventType: "assistant/chunk",
    data: ["chunk": [
      "type": "block-end",
      "block": ["type": "reasoning", "text": "thinking"],
    ]])
  let aggregate = DSHAssistantStreamProjection.live(
    eventType: "text-chunks",
    data: ["texts": ["Hello", " world"]])

  try expectEqual(current, DSHAssistantStreamDelta(kind: .text, text: "GO", isSnapshot: false))
  try expectEqual(legacy, DSHAssistantStreamDelta(kind: .text, text: "OLD", isSnapshot: false))
  try expectEqual(reasoning, DSHAssistantStreamDelta(kind: .reasoning, text: "thinking", isSnapshot: true))
  try expectEqual(aggregate, DSHAssistantStreamDelta(kind: .text, text: "Hello world", isSnapshot: false))
}

private func testAssistantStreamProjection_snapshotCompletesPartialDelta() throws {
  try MainActor.assumeIsolated {
    var message = HarnessController.Message(role: .assistant, text: "Hel")
    DSHAssistantStreamProjection.append(
      DSHAssistantStreamDelta(kind: .text, text: "Hello", isSnapshot: true),
      to: &message)
    try expectEqual(message.text, "Hello")

    DSHAssistantStreamProjection.append(
      DSHAssistantStreamDelta(kind: .text, text: "Hello", isSnapshot: true),
      to: &message)
    try expectEqual(message.text, "Hello")
  }
}

private func testHistoryAssistantChunks_preserveStreamAndDoNotDuplicateBlockEnd() throws {
  let page = try JSONDecoder().decode(DSHHistoryPage.self, from: Data("""
  {
    "events": [
      {
        "event": {
          "type": "user/message",
          "seq": 1,
          "time": 1000,
          "data": {"message":{"role":"user","content":[{"type":"text","text":"first"}]}}
        }
      },
      {
        "event": {
          "type": "assistant/chunk",
          "seq": 2,
          "time": 2000,
          "data": {"chunk":{"type":"text-delta","index":0,"text":"Hello"}}
        }
      },
      {
        "event": {
          "type": "reasoning-chunks",
          "seq": 3,
          "time": 3000,
          "data": {"texts":["think","ing"]}
        }
      },
      {
        "event": {
          "type": "assistant/chunk",
          "seq": 4,
          "time": 4000,
          "data": {"chunk":{"type":"block-end","index":0,"block":{"type":"reasoning","text":"thinking"}}}
        }
      },
      {
        "event": {
          "type": "assistant/chunk",
          "seq": 5,
          "time": 5000,
          "data": {"chunk":{"type":"block-end","index":1,"block":{"type":"text","text":"Hello"}}}
        }
      },
      {
        "event": {
          "type": "user/message",
          "seq": 6,
          "time": 6000,
          "data": {"message":{"role":"user","content":[{"type":"text","text":"second"}]}}
        }
      },
      {
        "event": {
          "type": "text-chunks",
          "seq": 7,
          "time": 7000,
          "data": {"texts":["World"]}
        }
      }
    ],
    "hasMore": false
  }
  """.utf8))

  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let messages = harness.foldHistory(page.events)
    try expectEqual(messages.map(\.text), ["first", "Hello", "second", "World"])
    try expectEqual(messages[1].reasoning, "thinking")
  }
}

private func testLiveAssistantChunks_streamCurrentTextWithoutDuplication() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "stream",
      workspaceName: "test",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "session-stream")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "session-stream"

    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "session-stream",
      "event": [
        "type": "assistant/chunk",
        "seq": 1,
        "time": 1000,
        "data": ["chunk": ["type": "text-delta", "text": "Hello"]],
      ],
    ])
    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "session-stream",
      "event": [
        "type": "assistant/chunk",
        "seq": 2,
        "time": 2000,
        "data": ["chunk": [
          "type": "block-end",
          "block": ["type": "text", "text": "Hello"],
        ]],
      ],
    ])

    try expectEqual(harness.sessions[0].messages.map(\.text), ["Hello"])
  }
}

private func testLiveReasoningOnlyAssistantMessage_settlesStreamingPlaceholder() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "stream",
      workspaceName: "test",
      updatedAt: Date(),
      messages: [],
      isRunning: true,
      hostSessionId: "session-stream")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "session-stream"
    harness.isRunning = true

    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "session-stream",
      "event": [
        "type": "assistant/chunk",
        "seq": 1,
        "time": 1000,
        "data": ["chunk": ["type": "reasoning-delta", "text": "thinking"]],
      ],
    ])
    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "session-stream",
      "event": [
        "type": "assistant/message",
        "seq": 2,
        "time": 2000,
        "data": ["message": [
          "id": "durable-message",
          "role": "assistant",
          "content": [
            ["type": "reasoning", "text": "thinking"],
            ["type": "tool-call", "id": "call-1", "name": "run_code", "arguments": "{}"],
          ],
        ]],
      ],
    ])

    let message = harness.sessions[0].messages.last
    try expectEqual(message?.hostMessageId, "durable-message")
    try expectEqual(message?.reasoning, "thinking")
    try expect(message?.text.isEmpty == true)
  }
}

private func testLiveSubagentAssistantChunks_useCurrentTextShape() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "root-session"
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-session",
      childSessionId: "child-session",
      mode: "continuable")
    harness.subagentTranscript = HarnessController.Session(
      title: "child",
      workspaceName: "test",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "child-session")

    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "child-session",
      "event": [
        "type": "assistant/chunk",
        "seq": 1,
        "time": 1000,
        "data": ["chunk": ["type": "text-delta", "text": "child"]],
      ],
    ])

    try expectEqual(harness.subagentTranscript?.messages.last?.text, "child")
  }
}

private func testHistoryTurnError_appendsVisibleSystemMessage() throws {
  let page = try JSONDecoder().decode(DSHHistoryPage.self, from: Data("""
  {
    "events": [
      {
        "event": {
          "type": "user/message",
          "seq": 1,
          "time": 1000,
          "data": {"message":{"role":"user","content":[{"type":"text","text":"go"}]}}
        }
      },
      {
        "event": {
          "type": "turn/end",
          "seq": 2,
          "time": 2000,
          "data": {"turn":1,"reason":{"kind":"error","error":{"code":"TRANSPORT","message":"network failed"}}}
        }
      }
    ],
    "hasMore": false
  }
  """.utf8))

  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let messages = harness.foldHistory(page.events)
    try expectEqual(messages.last?.role, .system)
    try expectEqual(messages.last?.text, "本轮执行失败：network failed")
  }
}

private func testHistoryInterruptedTurn_appendsVisibleSystemMessage() throws {
  let page = try JSONDecoder().decode(DSHHistoryPage.self, from: Data("""
  {
    "events": [
      {
        "event": {
          "type": "turn/end",
          "seq": 1,
          "time": 1000,
          "data": {"turn":1,"reason":{"kind":"interrupted"}}
        }
      }
    ],
    "hasMore": false
  }
  """.utf8))

  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let messages = harness.foldHistory(page.events)
    try expectEqual(messages.last?.text, "本轮已中断")
  }
}

private func testToolJobState_distinguishesStoppingAndKilled() throws {
  try expectEqual(DSHToolJobState.resolve("stopping"), .running)
  try expectEqual(DSHToolJobState.resolve("pending"), .running)
  try expectEqual(DSHToolJobState.resolve("completed"), .succeeded)
  try expectEqual(DSHToolJobState.resolve("failed"), .failed)
  try expectEqual(DSHToolJobState.resolve("killed"), .failed)
}

private func testHistoryCommandAndCompaction_remainVisibleAfterReload() throws {
  let page = try JSONDecoder().decode(DSHHistoryPage.self, from: Data("""
  {
    "events": [
      {
        "event": {
          "type": "command/run",
          "seq": 1,
          "time": 1000,
          "data": {"name":"goal","args":" finish","source":{"kind":"user"}}
        }
      },
      {
        "event": {
          "type": "command/done",
          "seq": 2,
          "time": 2000,
          "data": {"kind":"success","text":"Goal created"}
        }
      },
      {
        "event": {
          "type": "compaction/summary",
          "seq": 3,
          "time": 3000,
          "data": {"summary":"durable summary"}
        }
      }
    ],
    "hasMore": false
  }
  """.utf8))

  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let messages = harness.foldHistory(page.events)
    try expectEqual(messages.map(\.text), [
      "/goal finish",
      "Goal created",
      "历史上下文已压缩。摘要：durable summary",
    ])
  }
}

let dshAssistantStreamTests: [NamedTest] = [
  ("Assistant stream projection reads current and legacy shapes", testAssistantStreamProjection_readsCurrentAndLegacyShapes),
  ("Assistant stream projection snapshot completes partial delta", testAssistantStreamProjection_snapshotCompletesPartialDelta),
  ("History assistant chunks preserve stream without block-end duplication", testHistoryAssistantChunks_preserveStreamAndDoNotDuplicateBlockEnd),
  ("Live assistant chunks stream current text without duplication", testLiveAssistantChunks_streamCurrentTextWithoutDuplication),
  ("Live reasoning-only assistant messages settle their placeholder", testLiveReasoningOnlyAssistantMessage_settlesStreamingPlaceholder),
  ("Live subagent assistant chunks use current text shape", testLiveSubagentAssistantChunks_useCurrentTextShape),
  ("History turn error appends visible system message", testHistoryTurnError_appendsVisibleSystemMessage),
  ("History interrupted turn appends visible system message", testHistoryInterruptedTurn_appendsVisibleSystemMessage),
  ("Tool job state distinguishes stopping and killed", testToolJobState_distinguishesStoppingAndKilled),
  ("History command and compaction remain visible after reload", testHistoryCommandAndCompaction_remainVisibleAfterReload),
]
