import Foundation
@testable import DSHAppLib

private func testPermissionProjection_decodesDynamicOptions() throws {
  let data = Data("""
  {
    "options": [
      {"value":"read-only","name":"read-only"},
      {"value":"workspace-write","name":"workspace-write"},
      {"value":"danger-full-access","name":"danger-full-access"}
    ],
    "currentValue":"workspace-write"
  }
  """.utf8)
  let selection = try JSONDecoder().decode(DSHPermissionSelection.self, from: data)
  try expectEqual(selection.options.map(\.value), ["read-only", "workspace-write", "danger-full-access"])
  try expectEqual(selection.currentOption?.nativeLabel, "工作区访问")
  try expect(selection.options.last?.requiresConfirmation == true)
}

private func testPermissionProjection_customIsDisplayOnly() throws {
  let custom = DSHPermissionOption(value: "custom", name: "Custom", description: nil)
  try expect(!custom.isSelectable)
  try expectEqual(custom.nativeLabel, "自定义")
}

private func testSettingsSchema_extractsStringChoices() throws {
  let data = Data("""
  {
    "ns":"permission",
    "schema":{
      "uid":5,
      "refs":{
        "1":{"type":"const","meta":{"description":"只读"},"value":"read-only"},
        "2":{"type":"const","meta":{},"value":"workspace-write"},
        "4":{"type":"union","meta":{"required":true},"list":[1,2]},
        "5":{"type":"object","meta":{},"dict":{"defaultPreset":4}}
      }
    },
    "value":{"defaultPreset":"workspace-write"},
    "applies":"live",
    "secrets":[],
    "revision":0
  }
  """.utf8)
  let namespace = try JSONDecoder().decode(DSHSettingsNamespace.self, from: data)
  try expectEqual(
    DSHSettingsSchema.stringChoices(in: namespace, field: "defaultPreset"),
    [
      DSHSettingsStringChoice(value: "read-only", name: "只读"),
      DSHSettingsStringChoice(value: "workspace-write", name: "workspace-write"),
    ])
}

private func testPromptPayload_encodesSteerMode() throws {
  let payload = DSHPromptPayload(sessionId: "session-1", mode: .steer, content: [.text("补充约束")])
  let data = try JSONEncoder().encode(payload)
  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  try expectEqual(object?["mode"] as? String, "steer")
}

private func testCommandExecutePayload_includesEmptyAttachments() throws {
  let payload = DSHTypertArgsEnvelope(
    args: DSHCommandExecuteArgs(
      agentId: "session-1",
      line: "/permission workspace-write",
      submittedAttachments: []))
  let data = try JSONEncoder().encode(payload)
  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let args = object?["args"] as? [String: Any]
  try expectEqual(args?["agentId"] as? String, "session-1")
  try expectEqual(args?["line"] as? String, "/permission workspace-write")
  try expectEqual((args?["submittedAttachments"] as? [Any])?.count, 0)
}

private func testComposerSubmissionPolicy_sendsDirectlyWhenQueueIsEmpty() throws {
  try expectEqual(
    DSHComposerSubmissionPolicy.mode(
      running: false,
      accelerated: true,
      preferredBusyMode: .steer,
      steeringAvailable: true,
      hasQueuedMessages: true),
    .queue)
  try expectEqual(
    DSHComposerSubmissionPolicy.mode(
      running: true,
      accelerated: false,
      preferredBusyMode: .queue,
      steeringAvailable: true,
      hasQueuedMessages: false),
    .steer)
  try expectEqual(
    DSHComposerSubmissionPolicy.mode(
      running: true,
      accelerated: true,
      preferredBusyMode: .queue,
      steeringAvailable: true,
      hasQueuedMessages: false),
    .steer)
  try expectEqual(
    DSHComposerSubmissionPolicy.mode(
      running: true,
      accelerated: false,
      preferredBusyMode: .queue,
      steeringAvailable: true,
      hasQueuedMessages: true),
    .queue)
  try expectEqual(
    DSHComposerSubmissionPolicy.mode(
      running: true,
      accelerated: true,
      preferredBusyMode: .queue,
      steeringAvailable: true,
      hasQueuedMessages: true),
    .steer)
  try expectEqual(
    DSHComposerSubmissionPolicy.mode(
      running: true,
      accelerated: false,
      preferredBusyMode: .steer,
      steeringAvailable: true,
      hasQueuedMessages: true),
    .steer)
  try expectEqual(
    DSHComposerSubmissionPolicy.mode(
      running: true,
      accelerated: true,
      preferredBusyMode: .steer,
      steeringAvailable: false,
      hasQueuedMessages: true),
    .queue)
}

private func testBusySubmission_requiresPlainComposerMode() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.isRunning = true
    harness.draft = "补充约束"
    harness.composerAgentProfileID = "profile-1"
    try expect(harness.submitBusyComposer(accelerated: false))
    try expectEqual(harness.draft, "补充约束")
    try expectEqual(harness.status, "当前会话运行中，暂不能派发 Agent Batch")
  }
}

private func testBusySubmission_emptyDraftOnlySteersWhenResolvedModeIsSteer() throws {
  try expect(DSHComposerSubmissionPolicy.shouldSteerQueuedMessages(hasContent: false, mode: .steer))
  try expect(!DSHComposerSubmissionPolicy.shouldSteerQueuedMessages(hasContent: false, mode: .queue))
  try expect(!DSHComposerSubmissionPolicy.shouldSteerQueuedMessages(hasContent: true, mode: .steer))
}

private func testBusySubmission_routesRootSlashCommandsThroughCommandPlane() throws {
  try expect(DSHComposerSubmissionPolicy.shouldExecuteCommand(
    text: "/permission read-only",
    hasImage: false,
    isRootSession: true))
  try expect(!DSHComposerSubmissionPolicy.shouldExecuteCommand(
    text: "/permission read-only",
    hasImage: true,
    isRootSession: true))
  try expect(!DSHComposerSubmissionPolicy.shouldExecuteCommand(
    text: "/permission read-only",
    hasImage: false,
    isRootSession: false))
  try expect(!DSHComposerSubmissionPolicy.shouldExecuteCommand(
    text: "普通补充",
    hasImage: false,
    isRootSession: true))
}

private func testComposerSubmissionPolicy_keepsNativeCommandsLocal() throws {
  try expectEqual(
    DSHComposerSubmissionPolicy.nativeCommand(text: "/export", hasImage: false),
    .export)
  try expectEqual(
    DSHComposerSubmissionPolicy.nativeCommand(text: "/model", hasImage: false),
    .model)
  try expect(
    DSHComposerSubmissionPolicy.nativeCommand(text: "/export path", hasImage: false) == nil)
  try expect(
    DSHComposerSubmissionPolicy.nativeCommand(text: "/model", hasImage: true) == nil)
}

private func testQueueItems_separateQueuedAndSteering() throws {
  let items = DSHQueueItem.fromInbox([
    "next-turn": [["id": "queue-1", "content": [["type": "text", "text": "下一轮"]]]],
    "next-step": [["id": "steer-1", "content": [["type": "text", "text": "当前轮"]]]],
  ]) ?? []
  try expectEqual(items.filter(\.isQueued).map(\.id), ["queue-1"])
  try expectEqual(items.filter(\.isSteering).map(\.id), ["steer-1"])
  try expectEqual(items.last?.messageID, "steer-1")
}

private func testQueueChrome_waitsForStableQueueSnapshot() throws {
  try expect(DSHQueueChrome.settleDelayMilliseconds >= 200)
}

private func testQueueItems_disableEditingForNonTextContent() throws {
  let items = DSHQueueItem.fromInbox([
    "next-turn": [[
      "id": "queue-image",
      "content": [
        ["type": "text", "text": "参考这张图"],
        ["type": "image", "attachment": ["attachmentId": "image-1"]],
      ],
    ]],
  ]) ?? []
  try expectEqual(items.first?.text, "参考这张图")
  try expect(items.first?.hasNonTextContent == true)
  try expect(items.first?.isEditable == false)
}

private func testQueueSnapshots_restoreBySessionAndRetireByMessageID() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "session-a"
    harness.rememberQueueSnapshot(
      [DSHQueueItem(
        id: "occurrence-a",
        messageID: "message-a",
        placement: "steering",
        text: "当前轮")],
      sessionID: "session-a")
    harness.rememberQueueSnapshot(
      [DSHQueueItem(id: "occurrence-b", placement: "queued", text: "下一轮")],
      sessionID: "session-b")
    try expectEqual(harness.queueItems.map(\.id), ["occurrence-a"])
    harness.hostCurrentSessionID = "session-b"
    harness.restoreRootQueue(sessionID: "session-b")
    try expectEqual(harness.queueItems.map(\.id), ["occurrence-b"])
    harness.retireSteeringItem(messageID: "message-a", sessionID: "session-a")
    try expect(harness.cachedQueueSnapshot(sessionID: "session-a").isEmpty)
  }
}

private func testSettingsChoiceMutationLocksPerNamespaceAndSession() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    try expect(harness.beginSettingsChoiceMutation("permission"))
    try expect(!harness.beginSettingsChoiceMutation("permission"))
    try expect(harness.permissionSettingsMutationInFlight)
    try expect(harness.beginSettingsChoiceMutation("ui-conversation"))
    try expect(harness.busyEnterSettingsMutationInFlight)
    harness.hostCurrentSessionID = "session-1"
    try expect(harness.beginPermissionSessionMutation("session-1"))
    try expect(!harness.beginPermissionSessionMutation("session-1"))
    try expect(harness.permissionMenuBusy)
    harness.endSettingsChoiceMutation("permission")
    harness.endSettingsChoiceMutation("ui-conversation")
    harness.endPermissionSessionMutation("session-1")
    try expect(!harness.permissionSettingsMutationInFlight)
    try expect(!harness.busyEnterSettingsMutationInFlight)
    try expect(!harness.permissionMenuBusy)
  }
}

private func testRunningSubmissionLocksPerSession() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "session-1"
    try expect(harness.beginRunningSubmission(sessionID: "session-1"))
    try expect(!harness.beginRunningSubmission(sessionID: "session-1"))
    try expect(harness.runningSubmissionInFlight)
    harness.endRunningSubmission(sessionID: "session-1")
    try expect(!harness.runningSubmissionInFlight)
  }
}

private func testComposerSubmissionLockFollowsSharedDraftAcrossSessions() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "session-a"
    try expect(harness.beginComposerSubmission(sessionID: "session-a"))
    harness.hostCurrentSessionID = "session-b"
    try expect(harness.composerSubmissionInFlight)
    try expect(!harness.beginComposerSubmission(sessionID: "session-b"))
    harness.endComposerSubmission(sessionID: "session-a")
    try expect(!harness.composerSubmissionInFlight)
    try expect(harness.beginComposerSubmission(sessionID: "session-b"))
    harness.endComposerSubmission(sessionID: "session-b")
  }
}

private func testAcceptedRunningDraftRemainder_preservesNewTyping() throws {
  try expectEqual(
    HarnessController.acceptedRunningDraftRemainder(
      current: "原始内容，随后补充",
      submitted: "原始内容"),
    "，随后补充")
  try expectEqual(
    HarnessController.acceptedRunningDraftRemainder(
      current: "原始内容",
      submitted: "原始内容"),
    "")
  try expect(
    HarnessController.acceptedRunningDraftRemainder(
      current: "用户已改写",
      submitted: "原始内容") == nil)
}

private func testAcceptedComposerDraft_clearsSubmittedPrefixAfterNavigation() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.draft = "原始内容，随后补充"
    harness.clearAcceptedComposerDraft(originalText: "原始内容", originalImageIDs: [])
    try expectEqual(harness.draft, "，随后补充")
  }
}

private func testSubmissionRunning_updatesOnlyOriginatingSession() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let first = HarnessController.Session(
      title: "A",
      workspaceName: "A",
      updatedAt: Date(),
      messages: [],
      isRunning: true,
      hostSessionId: "session-a")
    let second = HarnessController.Session(
      title: "B",
      workspaceName: "B",
      updatedAt: Date(),
      messages: [],
      isRunning: true,
      hostSessionId: "session-b")
    harness.sessions = [first, second]
    harness.selectedSessionID = second.id
    harness.hostCurrentSessionID = "session-b"
    harness.isRunning = true
    // Another client started a turn in A while this submission was in flight.
    harness.hostSessions = [DSHSessionSummary(
      sessionId: "session-a",
      updatedAt: 0,
      running: true,
      blank: false,
      cwd: nil,
      agentPreset: nil,
      parentSessionId: nil,
      origin: nil,
      projections: nil)]
    harness.reconcileRootSessionRunningState(
      sessionID: "session-a",
      localSessionID: first.id,
      running: false,
      reportedByHost: false)
    try expect(!harness.sessions[0].isRunning)
    try expect(harness.sessions[1].isRunning)
    try expect(harness.isRunning)
    try expect(harness.hostSessions[0].running, "a late local completion must not clear what the Host reported")
  }
}

private func testRootRunningReconciliation_clearsDisplayedStaleSession() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let root = HarnessController.Session(
      title: "Root",
      workspaceName: "Workspace",
      updatedAt: Date(),
      messages: [],
      isRunning: true,
      hostSessionId: "root")
    harness.sessions = [root]
    harness.selectedSessionID = root.id
    harness.hostCurrentSessionID = "root"
    harness.isRunning = true

    harness.reconcileRootSessionRunningState(
      sessionID: "root",
      localSessionID: root.id,
      running: false)

    try expect(!harness.sessions[0].isRunning)
    try expect(!harness.isRunning)
  }
}

private func testRootRunningReconciliation_updatesBackgroundRowWithoutDisplayedFlag() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let first = HarnessController.Session(
      title: "A",
      workspaceName: "A",
      updatedAt: Date(),
      messages: [],
      isRunning: true,
      hostSessionId: "session-a")
    let second = HarnessController.Session(
      title: "B",
      workspaceName: "B",
      updatedAt: Date(),
      messages: [],
      isRunning: true,
      hostSessionId: "session-b")
    harness.sessions = [first, second]
    harness.selectedSessionID = second.id
    harness.hostCurrentSessionID = "session-b"
    harness.isRunning = true

    harness.reconcileRootSessionRunningState(
      sessionID: "session-a",
      localSessionID: first.id,
      running: false)

    try expect(!harness.sessions[0].isRunning)
    try expect(harness.sessions[1].isRunning)
    try expect(harness.isRunning)
  }
}

private func testRemoteSessionStatus_clearsDisplayedRunningState() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let root = HarnessController.Session(
      title: "Root",
      workspaceName: "Workspace",
      updatedAt: Date(),
      messages: [],
      isRunning: true,
      hostSessionId: "root")
    harness.sessions = [root]
    harness.selectedSessionID = root.id
    harness.hostCurrentSessionID = "root"
    harness.isRunning = true

    harness.applyRemoteSessionStatus(sessionID: "root", running: false)

    try expect(!harness.sessions[0].isRunning)
    try expect(!harness.isRunning)
  }
}

private func testStop_reportsFailureInTheConversation() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let root = HarnessController.Session(
      title: "Root",
      workspaceName: "Workspace",
      updatedAt: Date(),
      messages: [],
      isRunning: true,
      hostSessionId: "root")
    harness.sessions = [root]
    harness.selectedSessionID = root.id
    harness.hostCurrentSessionID = "root"
    harness.isRunning = true

    harness.stop()
    try expectEqual(harness.sessions[0].messages.last?.text, "Host 未连接，无法停止本轮。")

    // Port 1 refuses the connection, so the cancel itself fails.
    harness.hostClient = DSHHostClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    harness.stop()
    let deadline = Date().addingTimeInterval(5)
    while harness.sessions[0].messages.last?.text.hasPrefix("停止失败：") != true, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    try expect(harness.sessions[0].messages.last?.text.hasPrefix("停止失败：") == true)
  }
}

private func testSubagentFailure_routesToOriginatingRootAfterNavigation() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    let root = HarnessController.Session(
      title: "Root",
      workspaceName: "Workspace",
      updatedAt: Date(),
      messages: [],
      hostSessionId: "root")
    harness.sessions = [root]
    harness.selectedSessionID = nil
    harness.activeSubagentAddress = nil
    harness.reportSubagentComposerFailure(
      "network",
      address: DSHSubagentAddress(
        parentSessionId: "root",
        childSessionId: "child",
        mode: "continuable"),
      localSessionID: root.id)
    try expectEqual(harness.sessions[0].messages.last?.text, "子代理追问失败：network")
  }
}

private func testPermissionProjection_rejectsOlderSnapshot() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "session-1"
    harness.rememberPermissionSelection(
      DSHPermissionSelection(
        options: [
          DSHPermissionOption(value: "read-only", name: "read-only", description: nil),
          DSHPermissionOption(value: "workspace-write", name: "workspace-write", description: nil),
        ],
        currentValue: "workspace-write"),
      sessionID: "session-1",
      seq: 8)
    harness.rememberPermissionSelection(
      DSHPermissionSelection(
        options: [
          DSHPermissionOption(value: "read-only", name: "read-only", description: nil),
          DSHPermissionOption(value: "workspace-write", name: "workspace-write", description: nil),
        ],
        currentValue: "read-only"),
      sessionID: "session-1",
      seq: 7)
    try expectEqual(harness.currentPermissionSelection?.currentValue, "workspace-write")
  }
}

let dshPermissionAndSubmissionTests: [NamedTest] = [
  ("Permission projection decodes dynamic options", testPermissionProjection_decodesDynamicOptions),
  ("Permission custom state is display-only", testPermissionProjection_customIsDisplayOnly),
  ("Settings schema extracts string choices", testSettingsSchema_extractsStringChoices),
  ("Prompt payload encodes steer mode", testPromptPayload_encodesSteerMode),
  ("Command execution payload includes empty attachments", testCommandExecutePayload_includesEmptyAttachments),
  ("Composer submission sends directly when the queue is empty", testComposerSubmissionPolicy_sendsDirectlyWhenQueueIsEmpty),
  ("Busy submission preserves selected Agent Profile semantics", testBusySubmission_requiresPlainComposerMode),
  ("Empty busy submission respects the resolved alternate mode", testBusySubmission_emptyDraftOnlySteersWhenResolvedModeIsSteer),
  ("Busy submission routes root slash commands through command plane", testBusySubmission_routesRootSlashCommandsThroughCommandPlane),
  ("Native composer commands stay local while busy", testComposerSubmissionPolicy_keepsNativeCommandsLocal),
  ("Queue items separate queued and steering placements", testQueueItems_separateQueuedAndSteering),
  ("Queue chrome waits for a stable queue snapshot", testQueueChrome_waitsForStableQueueSnapshot),
  ("Queue items disable editing for non-text content", testQueueItems_disableEditingForNonTextContent),
  ("Queue snapshots restore by session and retire by message id", testQueueSnapshots_restoreBySessionAndRetireByMessageID),
  ("Settings choice mutations lock independently", testSettingsChoiceMutationLocksPerNamespaceAndSession),
  ("Running submissions lock independently by session", testRunningSubmissionLocksPerSession),
  ("Composer submissions lock the shared draft across sessions", testComposerSubmissionLockFollowsSharedDraftAcrossSessions),
  ("Accepted running submission preserves later typing", testAcceptedRunningDraftRemainder_preservesNewTyping),
  ("Accepted composer submission clears its prefix after navigation", testAcceptedComposerDraft_clearsSubmittedPrefixAfterNavigation),
  ("Submission completion updates only its originating session", testSubmissionRunning_updatesOnlyOriginatingSession),
  ("Root running reconciliation clears a displayed stale session", testRootRunningReconciliation_clearsDisplayedStaleSession),
  ("Root running reconciliation keeps background state isolated", testRootRunningReconciliation_updatesBackgroundRowWithoutDisplayedFlag),
  ("Remote session status clears the displayed running state", testRemoteSessionStatus_clearsDisplayedRunningState),
  ("Stop reports a failure in the conversation", testStop_reportsFailureInTheConversation),
  ("Subagent failures route to their originating root session", testSubagentFailure_routesToOriginatingRootAfterNavigation),
  ("Permission projection rejects an older snapshot", testPermissionProjection_rejectsOlderSnapshot),
]
