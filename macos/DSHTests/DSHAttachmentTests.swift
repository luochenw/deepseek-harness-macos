import AppKit
import Foundation
@testable import DSHAppLib

private func attachmentFixture(
  id: String = "attachment-a",
  name: String = "a.png"
) -> DSHAttachmentRef {
  DSHAttachmentRef(
    attachmentId: id,
    mediaType: "image/png",
    bytes: 1,
    width: 10,
    height: 10,
    name: name)
}

private func testAttachmentRail_preservesMessageOrderAndRepeatedReferences() throws {
  let first = HarnessController.Message(
    role: .user,
    text: "第一张",
    attachment: attachmentFixture())
  let second = HarnessController.Message(role: .assistant, text: "没有图片")
  let third = HarnessController.Message(
    role: .assistant,
    text: "重复引用",
    attachment: attachmentFixture())

  let items = DSHAttachmentRail.items(
    messages: [first, second, third],
    sessionID: "child-session")

  try expectEqual(items.map { $0.ref.attachmentId }, ["attachment-a", "attachment-a"])
  try expectEqual(items.map { $0.sessionID }, ["child-session", "child-session"])
  try expectEqual(items.map { $0.messageID }, [first.id, third.id])
}

private func testAttachmentRail_refusesMissingAuthorizationSession() throws {
  let message = HarnessController.Message(
    role: .user,
    text: "图片",
    attachment: attachmentFixture())

  try expect(DSHAttachmentRail.items(messages: [message], sessionID: nil).isEmpty)
  try expect(DSHAttachmentRail.items(messages: [message], sessionID: "  ").isEmpty)
}

private func testAttachmentRail_prefersChildSessionForSubagentTranscript() throws {
  try expectEqual(
    DSHAttachmentRail.authorizationSessionID(
      rootSessionID: "root-session",
      childSessionID: "child-session",
      showsSubagent: true),
    "child-session")
  try expectEqual(
    DSHAttachmentRail.authorizationSessionID(
      rootSessionID: "root-session",
      childSessionID: "child-session",
      showsSubagent: false),
    "root-session")
  try expect(
    DSHAttachmentRail.authorizationSessionID(
      rootSessionID: "root-session",
      childSessionID: nil,
      showsSubagent: true) == nil)
}

private func testAttachmentRef_decodesLiveMessageImage() throws {
  let ref = DSHAttachmentRef.fromLiveMessage([
    "content": [[
      "type": "image",
      "attachment": [
        "attachmentId": "live-image",
        "mediaType": "image/jpeg",
        "bytes": 42,
        "width": 120,
        "height": 80,
        "name": "live.jpg",
      ],
    ]],
  ])

  try expectEqual(ref?.attachmentId, "live-image")
  try expectEqual(ref?.mediaType, "image/jpeg")
  try expectEqual(ref?.bytes, 42)
  try expectEqual(ref?.width, 120)
  try expectEqual(ref?.height, 80)
  try expectEqual(ref?.name, "live.jpg")
}

private func testAttachmentRail_matchesLocalImageEchoWithoutDuplicatingText() throws {
  let attachment = attachmentFixture()

  try expect(DSHAttachmentRail.matchesLocalUserEcho(
    localText: "请看这里\n[图片附件：a.png]",
    incomingText: "请看这里",
    attachment: attachment))
  try expect(DSHAttachmentRail.matchesLocalUserEcho(
    localText: "\n[图片附件：a.png]",
    incomingText: "",
    attachment: attachment))
  try expect(!DSHAttachmentRail.matchesLocalUserEcho(
    localText: "请看这里",
    incomingText: "请看这里",
    attachment: attachment))
  try expect(!DSHAttachmentRail.matchesLocalUserEcho(
    localText: "请看这里\n[图片附件：a.png]",
    incomingText: "请看这里",
    attachment: nil))
}

private func testAttachmentStore_startsOneLoadAndAllowsExplicitRetry() throws {
  try MainActor.assumeIsolated {
    let store = DSHAttachmentStore()

    try expect(store.beginLoad(for: "attachment-a"))
    try expect(!store.beginLoad(for: "attachment-a"))
    store.recordFailure("network", for: "attachment-a")
    try expect(store.errors["attachment-a"] == "network")
    try expect(!store.beginLoad(for: "attachment-a"))
    try expect(store.beginLoad(for: "attachment-a", retry: true))
    try expect(store.errors["attachment-a"] == nil)

    store.cache(NSImage(size: NSSize(width: 1, height: 1)), for: "attachment-a")
    try expect(!store.beginLoad(for: "attachment-a"))
  }
}

private func testPendingLocalUserMarker_clearsOnlyTheExactMessage() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    var first = HarnessController.Message(role: .user, text: "first")
    first.hostMessageId = DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
    var second = HarnessController.Message(role: .user, text: "second")
    second.hostMessageId = DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
    let session = HarnessController.Session(
      title: "根会话",
      workspaceName: "测试",
      updatedAt: Date(),
      messages: [first, second])
    harness.sessions = [session]

    harness.clearPendingLocalUserMessage(localSessionID: session.id, messageID: first.id)

    try expectEqual(harness.sessions[0].messages[0].hostMessageId, nil)
    try expectEqual(
      harness.sessions[0].messages[1].hostMessageId,
      DSHTranscriptMessageMarker.pendingLocalUserHostMessageID)
  }
}

private func testLiveRootEvent_keepsDistinctPrefixUserImageMessage() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let existing = HarnessController.Message(role: .user, text: "比较")
    let session = HarnessController.Session(
      title: "根会话",
      workspaceName: "测试",
      updatedAt: Date(),
      messages: [existing],
      hostSessionId: "root-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "root-session"

    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "root-session",
      "event": [
        "type": "user/message",
        "data": liveImageMessage(
          id: "remote-user",
          text: "比较这张图",
          attachmentID: "remote-image"),
      ],
    ])

    try expectEqual(harness.sessions[0].messages.count, 2)
    try expectEqual(harness.sessions[0].messages[0].text, "比较")
    try expectEqual(harness.sessions[0].messages[1].text, "比较这张图")
    try expectEqual(harness.sessions[0].messages[1].attachment?.attachmentId, "remote-image")
  }
}

private func testLiveRootEvent_reconcilesLocalImageEchoIntoExistingMessage() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    var local = HarnessController.Message(role: .user, text: "请看这里\n[图片附件：a.png]")
    local.hostMessageId = DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
    let session = HarnessController.Session(
      title: "根会话",
      workspaceName: "测试",
      updatedAt: Date(),
      messages: [local],
      hostSessionId: "root-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "root-session"

    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "root-session",
      "event": [
        "type": "user/message",
        "data": liveImageMessage(
          id: "echo-user",
          text: "请看这里",
          attachmentID: "echo-image"),
      ],
    ])

    try expectEqual(harness.sessions[0].messages.count, 1)
    try expectEqual(harness.sessions[0].messages[0].attachment?.attachmentId, "echo-image")
  }
}

private func testLiveRootEvent_neverReconcilesRelayIntoPendingLocalMessage() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    var local = HarnessController.Message(role: .user, text: "请看这里\n[图片附件：a.png]")
    local.hostMessageId = DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
    let session = HarnessController.Session(
      title: "根会话",
      workspaceName: "测试",
      updatedAt: Date(),
      messages: [local],
      hostSessionId: "root-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "root-session"

    var relay = liveImageMessage(id: "relay-user", text: "请看这里", attachmentID: "relay-image")
    relay["source"] = ["kind": "plugin", "plugin": "session-relay"]
    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "root-session",
      "event": ["type": "user/message", "data": relay],
    ])

    try expectEqual(harness.sessions[0].messages.count, 2)
    try expectEqual(harness.sessions[0].messages[0].attachment, nil)
    try expectEqual(harness.sessions[0].messages[1].attachment?.attachmentId, "relay-image")
    try expect(harness.sessions[0].messages[1].isRelayMessage)
  }
}

private func testLiveRootEvent_settlesStreamingAssistantPlaceholder() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "根会话",
      workspaceName: "测试",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "root-session"

    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "root-session",
      "event": [
        "type": "assistant/chunk",
        "data": ["chunk": ["type": "text-delta", "textDelta": "流式"]],
      ],
    ])
    harness.consumeMuxFrame([
      "type": "session/event",
      "sessionId": "root-session",
      "event": [
        "type": "assistant/message",
        "data": liveImageMessage(id: "settled-assistant", text: "已结算", attachmentID: "settled-image"),
      ],
    ])

    try expectEqual(harness.sessions[0].messages.count, 1)
    try expectEqual(harness.sessions[0].messages[0].text, "已结算")
    try expectEqual(harness.sessions[0].messages[0].hostMessageId, "settled-assistant")
    try expectEqual(harness.sessions[0].messages[0].attachment?.attachmentId, "settled-image")
  }
}

private func testHistoryFold_settlesStreamingAssistantPlaceholder() throws {
  let page = try JSONDecoder().decode(DSHHistoryPage.self, from: Data("""
  {
    "events": [
      {
        "event": {
          "type": "assistant/chunk",
          "seq": 1,
          "time": 1000,
          "data": {"chunk": {"type": "text-delta", "textDelta": "流式"}}
        }
      },
      {
        "event": {
          "type": "assistant/message",
          "seq": 2,
          "time": 2000,
          "data": {
            "id": "history-settled",
            "content": [
              {"type": "text", "text": "已结算"},
              {"type": "image", "attachment": {"attachmentId": "history-settled-image", "mediaType": "image/png", "bytes": 1, "width": 10, "height": 10, "name": "settled.png"}}
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
    let messages = harness.foldHistory(page.events)
    try expectEqual(messages.count, 1)
    try expectEqual(messages[0].text, "已结算")
    try expectEqual(messages[0].hostMessageId, "history-settled")
    try expectEqual(messages[0].attachment?.attachmentId, "history-settled-image")
  }
}

private func testLiveRootEvent_preservesConsecutiveAssistantAttachments() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "根会话",
      workspaceName: "测试",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "root-session"

    for (id, text, attachmentID) in [
      ("assistant-a", "第一张", "assistant-image-a"),
      ("assistant-b", "第二张", "assistant-image-b"),
    ] {
      harness.consumeMuxFrame([
        "type": "session/event",
        "sessionId": "root-session",
        "event": [
          "type": "assistant/message",
          "data": liveImageMessage(id: id, text: text, attachmentID: attachmentID),
        ],
      ])
    }

    try expectEqual(harness.sessions[0].messages.count, 2)
    try expectEqual(harness.sessions[0].messages.map(\.text), ["第一张", "第二张"])
    try expectEqual(
      harness.sessions[0].messages.compactMap { $0.attachment?.attachmentId },
      ["assistant-image-a", "assistant-image-b"])
  }
}

private func testLiveRootEvent_preservesConsecutiveAssistantAttachmentsWithoutMessageIDs() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "根会话",
      workspaceName: "测试",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "root-session"

    for (text, attachmentID) in [
      ("无 ID 第一张", "anonymous-image-a"),
      ("无 ID 第二张", "anonymous-image-b"),
    ] {
      harness.consumeMuxFrame([
        "type": "session/event",
        "sessionId": "root-session",
        "event": [
          "type": "assistant/message",
          "data": liveImageMessage(id: nil, text: text, attachmentID: attachmentID),
        ],
      ])
    }

    try expectEqual(harness.sessions[0].messages.count, 2)
    try expectEqual(
      harness.sessions[0].messages.compactMap { $0.attachment?.attachmentId },
      ["anonymous-image-a", "anonymous-image-b"])
  }
}

private func testLiveSubagentEvent_preservesConsecutiveAssistantAttachments() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "root-session"
    harness.activeSubagentAddress = DSHSubagentAddress(
      parentSessionId: "root-session",
      childSessionId: "child-session",
      mode: "continuable")
    harness.subagentTranscript = HarnessController.Session(
      title: "子代理",
      workspaceName: "子代理",
      updatedAt: Date(),
      messages: [])

    for (id, text, attachmentID) in [
      ("child-a", "子代理第一张", "child-image-a"),
      ("child-b", "子代理第二张", "child-image-b"),
    ] {
      harness.consumeMuxFrame([
        "type": "session/event",
        "sessionId": "child-session",
        "event": [
          "type": "assistant/message",
          "data": liveImageMessage(id: id, text: text, attachmentID: attachmentID),
        ],
      ])
    }

    try expectEqual(harness.subagentTranscript?.messages.count, 2)
    try expectEqual(
      harness.subagentTranscript?.messages.compactMap { $0.attachment?.attachmentId },
      ["child-image-a", "child-image-b"])
  }
}

private func testHistoryFold_preservesConsecutiveAssistantAttachments() throws {
  let page = try JSONDecoder().decode(DSHHistoryPage.self, from: Data("""
  {
    "events": [
      {
        "event": {
          "type": "assistant/message",
          "seq": 1,
          "time": 1000,
          "data": {
            "id": "history-a",
            "content": [
              {"type": "text", "text": "历史第一张"},
              {"type": "image", "attachment": {"attachmentId": "history-image-a", "mediaType": "image/png", "bytes": 1, "width": 10, "height": 10, "name": "a.png"}}
            ]
          }
        }
      },
      {
        "event": {
          "type": "assistant/message",
          "seq": 2,
          "time": 2000,
          "data": {
            "id": "history-b",
            "content": [
              {"type": "text", "text": "历史第二张"},
              {"type": "image", "attachment": {"attachmentId": "history-image-b", "mediaType": "image/png", "bytes": 1, "width": 10, "height": 10, "name": "b.png"}}
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
    let messages = harness.foldHistory(page.events)
    try expectEqual(messages.count, 2)
    try expectEqual(messages.map(\.text), ["历史第一张", "历史第二张"])
    try expectEqual(
      messages.compactMap { $0.attachment?.attachmentId },
      ["history-image-a", "history-image-b"])
  }
}

private func liveImageMessage(id: String?, text: String, attachmentID: String) -> [String: Any] {
  var message: [String: Any] = [
    "source": ["kind": "user"],
    "content": [
      ["type": "text", "text": text],
      [
        "type": "image",
        "attachment": [
          "attachmentId": attachmentID,
          "mediaType": "image/png",
          "bytes": 1,
          "width": 10,
          "height": 10,
          "name": "\(attachmentID).png",
        ],
      ],
    ],
  ]
  if let id { message["id"] = id }
  return message
}

let dshAttachmentTests: [NamedTest] = [
  ("Attachment rail preserves message order and repeated references", testAttachmentRail_preservesMessageOrderAndRepeatedReferences),
  ("Attachment rail refuses a missing authorization session", testAttachmentRail_refusesMissingAuthorizationSession),
  ("Attachment rail prefers child session for a subagent transcript", testAttachmentRail_prefersChildSessionForSubagentTranscript),
  ("Attachment ref decodes a live message image", testAttachmentRef_decodesLiveMessageImage),
  ("Attachment rail matches a local image echo without duplicate text", testAttachmentRail_matchesLocalImageEchoWithoutDuplicatingText),
  ("Attachment store starts one load and allows explicit retry", testAttachmentStore_startsOneLoadAndAllowsExplicitRetry),
  ("Pending local user marker clears only the exact message", testPendingLocalUserMarker_clearsOnlyTheExactMessage),
  ("Live root event keeps a distinct prefix user image message", testLiveRootEvent_keepsDistinctPrefixUserImageMessage),
  ("Live root event reconciles a local image echo", testLiveRootEvent_reconcilesLocalImageEchoIntoExistingMessage),
  ("Live root event never reconciles relay into a pending local message", testLiveRootEvent_neverReconcilesRelayIntoPendingLocalMessage),
  ("Live root event settles a streaming assistant placeholder", testLiveRootEvent_settlesStreamingAssistantPlaceholder),
  ("Live root event preserves consecutive assistant attachments", testLiveRootEvent_preservesConsecutiveAssistantAttachments),
  ("Live root event preserves consecutive assistant attachments without message IDs", testLiveRootEvent_preservesConsecutiveAssistantAttachmentsWithoutMessageIDs),
  ("Live subagent event preserves consecutive assistant attachments", testLiveSubagentEvent_preservesConsecutiveAssistantAttachments),
  ("History fold preserves consecutive assistant attachments", testHistoryFold_preservesConsecutiveAssistantAttachments),
  ("History fold settles a streaming assistant placeholder", testHistoryFold_settlesStreamingAssistantPlaceholder),
]
