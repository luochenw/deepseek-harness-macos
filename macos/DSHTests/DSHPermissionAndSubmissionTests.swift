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

private func testCommandExecutePayload_includesEmptyImages() throws {
  let payload = DSHTypertArgsEnvelope(
    args: DSHCommandExecuteArgsWithImages(
      agentId: "session-1",
      line: "/permission workspace-write",
      images: []))
  let data = try JSONEncoder().encode(payload)
  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let args = object?["args"] as? [String: Any]
  try expectEqual(args?["agentId"] as? String, "session-1")
  try expectEqual(args?["line"] as? String, "/permission workspace-write")
  try expectEqual((args?["images"] as? [Any])?.count, 0)
}

private func testComposerSubmissionPolicy_matchesBusyEnterPreference() throws {
  try expectEqual(
    DSHComposerSubmissionPolicy.mode(
      running: false,
      accelerated: true,
      preferredBusyMode: .steer,
      steeringAvailable: true),
    .queue)
  try expectEqual(
    DSHComposerSubmissionPolicy.mode(
      running: true,
      accelerated: false,
      preferredBusyMode: .queue,
      steeringAvailable: true),
    .queue)
  try expectEqual(
    DSHComposerSubmissionPolicy.mode(
      running: true,
      accelerated: true,
      preferredBusyMode: .queue,
      steeringAvailable: true),
    .steer)
  try expectEqual(
    DSHComposerSubmissionPolicy.mode(
      running: true,
      accelerated: false,
      preferredBusyMode: .steer,
      steeringAvailable: true),
    .steer)
  try expectEqual(
    DSHComposerSubmissionPolicy.mode(
      running: true,
      accelerated: true,
      preferredBusyMode: .steer,
      steeringAvailable: false),
    .queue)
}

private func testBusySubmission_requiresPlainComposerMode() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.isRunning = true
    harness.draft = "补充约束"
    harness.composerAgentProfileID = "profile-1"
    try expect(!harness.submitBusyComposer(accelerated: false))
    try expectEqual(harness.draft, "补充约束")
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
  let items = DSHQueueItem.fromMux([
    [
      "id": "queue-1",
      "placement": "queued",
      "message": [
        "id": "message-queue-1",
        "content": [["type": "text", "text": "下一轮"]],
      ],
    ],
    [
      "id": "steer-1",
      "placement": "steering",
      "message": [
        "id": "message-steer-1",
        "content": [["type": "text", "text": "当前轮"]],
      ],
    ],
  ])
  try expectEqual(items.filter(\.isQueued).map(\.id), ["queue-1"])
  try expectEqual(items.filter(\.isSteering).map(\.id), ["steer-1"])
  try expectEqual(items.last?.messageID, "message-steer-1")
}

private func testQueueItems_disableEditingForNonTextContent() throws {
  let items = DSHQueueItem.fromMux([
    [
      "id": "queue-image",
      "placement": "queued",
      "message": [
        "id": "message-image",
        "content": [
          ["type": "text", "text": "参考这张图"],
          ["type": "image", "attachment": ["attachmentId": "image-1"]],
        ],
      ],
    ],
  ])
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
    harness.clearAcceptedComposerDraft(originalText: "原始内容", originalImageID: nil)
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
    harness.setSubmissionRunning(
      false,
      localSessionID: first.id,
      hostSessionID: "session-a")
    try expect(!harness.sessions[0].isRunning)
    try expect(harness.sessions[1].isRunning)
    try expect(harness.isRunning)
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

private func testPermissionProjection_acceptsRestartedBaselineAfterReset() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "session-1"
    let options = [
      DSHPermissionOption(value: "read-only", name: "read-only", description: nil),
      DSHPermissionOption(value: "workspace-write", name: "workspace-write", description: nil),
    ]
    harness.rememberPermissionSelection(
      DSHPermissionSelection(options: options, currentValue: "workspace-write"),
      sessionID: "session-1",
      seq: 80)
    try expect(harness.truncatePermissionSelection(sessionID: "session-1", lastSeq: 2))
    harness.rememberPermissionSelection(
      DSHPermissionSelection(options: options, currentValue: "read-only"),
      sessionID: "session-1",
      seq: 2)
    try expectEqual(harness.currentPermissionSelection?.currentValue, "read-only")
  }
}

private func testPermissionProjection_keepsBaselineAtOrBeforeSubscriptionWatermark() throws {
  try MainActor.assumeIsolated {
    let harness = HarnessController(startRuntime: false)
    harness.hostCurrentSessionID = "session-1"
    harness.rememberPermissionSelection(
      DSHPermissionSelection(
        options: [DSHPermissionOption(value: "workspace-write", name: "workspace-write", description: nil)],
        currentValue: "workspace-write"),
      sessionID: "session-1",
      seq: 2)
    try expect(!harness.truncatePermissionSelection(sessionID: "session-1", lastSeq: 2))
    try expectEqual(harness.currentPermissionSelection?.currentValue, "workspace-write")
  }
}

let dshPermissionAndSubmissionTests: [NamedTest] = [
  ("Permission projection decodes dynamic options", testPermissionProjection_decodesDynamicOptions),
  ("Permission custom state is display-only", testPermissionProjection_customIsDisplayOnly),
  ("Settings schema extracts string choices", testSettingsSchema_extractsStringChoices),
  ("Prompt payload encodes steer mode", testPromptPayload_encodesSteerMode),
  ("Command execution payload includes empty images", testCommandExecutePayload_includesEmptyImages),
  ("Composer submission policy matches busy Enter preference", testComposerSubmissionPolicy_matchesBusyEnterPreference),
  ("Busy submission preserves selected Agent Profile semantics", testBusySubmission_requiresPlainComposerMode),
  ("Empty busy submission respects the resolved alternate mode", testBusySubmission_emptyDraftOnlySteersWhenResolvedModeIsSteer),
  ("Busy submission routes root slash commands through command plane", testBusySubmission_routesRootSlashCommandsThroughCommandPlane),
  ("Native composer commands stay local while busy", testComposerSubmissionPolicy_keepsNativeCommandsLocal),
  ("Queue items separate queued and steering placements", testQueueItems_separateQueuedAndSteering),
  ("Queue items disable editing for non-text content", testQueueItems_disableEditingForNonTextContent),
  ("Queue snapshots restore by session and retire by message id", testQueueSnapshots_restoreBySessionAndRetireByMessageID),
  ("Settings choice mutations lock independently", testSettingsChoiceMutationLocksPerNamespaceAndSession),
  ("Running submissions lock independently by session", testRunningSubmissionLocksPerSession),
  ("Composer submissions lock the shared draft across sessions", testComposerSubmissionLockFollowsSharedDraftAcrossSessions),
  ("Accepted running submission preserves later typing", testAcceptedRunningDraftRemainder_preservesNewTyping),
  ("Accepted composer submission clears its prefix after navigation", testAcceptedComposerDraft_clearsSubmittedPrefixAfterNavigation),
  ("Submission completion updates only its originating session", testSubmissionRunning_updatesOnlyOriginatingSession),
  ("Subagent failures route to their originating root session", testSubagentFailure_routesToOriginatingRootAfterNavigation),
  ("Permission projection rejects an older snapshot", testPermissionProjection_rejectsOlderSnapshot),
  ("Permission projection accepts restarted baseline after reset", testPermissionProjection_acceptsRestartedBaselineAfterReset),
  ("Permission projection keeps a valid subscribed baseline", testPermissionProjection_keepsBaselineAtOrBeforeSubscriptionWatermark),
]
