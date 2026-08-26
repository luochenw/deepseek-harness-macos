import Foundation
@testable import DSHAppLib

private func profileFixture(id: String = "profile-1", mention: String = "reviewer") -> DSHAgentProfile {
  DSHAgentProfile(
    id: id,
    name: "审查助手",
    mention: mention,
    description: "检查实现",
    persona: "只报告有证据的问题。",
    defaultTask: "检查当前改动并运行测试。",
    defaultMode: .analysis,
    allowModelDispatch: false,
    integrationPolicy: .manual,
    revision: 1,
    adapters: [
      DSHAgentAdapterBinding(
        id: "dsh",
        runtime: "dsh",
        enabled: true,
        displayName: "DSH",
        model: nil,
        toolAllowlist: ["read", "grep"],
        toolDenylist: ["bash"],
        analysisSupported: true,
        executionSupported: true,
        config: nil),
    ])
}

private func testMentionMatcher_findsTrailingProfileToken() throws {
  let draft = "检查这个实现 @rev"
  guard let query = DSHAgentMentionMatcher.query(in: draft) else {
    throw TestFailure.message("expected trailing @ mention query")
  }
  try expectEqual(query.query, "rev")
  try expectEqual(String(draft[query.range]), "@rev")
  try expectEqual(DSHAgentMentionMatcher.profiles([profileFixture()], matching: query.query).map(\.id), ["profile-1"])
}

private func testMentionMatcher_ignoresCompletedToken() throws {
  try expect(DSHAgentMentionMatcher.query(in: "@reviewer 请检查") == nil)
}

private func testPolicy_routesOnlyResolvedProfile() throws {
  try expect(DSHAgentPlatformPolicy.shouldRouteToBatch(selectedProfileID: "p1", profileResolved: true))
  try expect(!DSHAgentPlatformPolicy.shouldRouteToBatch(selectedProfileID: "p1", profileResolved: false))
  try expect(DSHAgentPlatformPolicy.hasUnresolvedSelection(selectedProfileID: "p1", profileResolved: false))
}

private func testPolicy_forbidsRetryAfterProfileDeletion() throws {
  try expect(!DSHAgentPlatformPolicy.canRetry(
    profileID: "p1",
    profileDeleted: true,
    activeProfileIDs: ["p1"],
    runStatus: "interrupted",
    retryable: true))
  try expect(!DSHAgentPlatformPolicy.canRetry(
    profileID: "p1",
    profileDeleted: false,
    activeProfileIDs: [],
    runStatus: "failed",
    retryable: true))
  try expect(!DSHAgentPlatformPolicy.canRetry(
    profileID: "p1",
    profileDeleted: false,
    activeProfileIDs: ["p1"],
    runStatus: "failed",
    retryable: false))
}

private func testPolicy_blocksDuplicateIntegrationRequest() throws {
  try expect(!DSHAgentPlatformPolicy.canRequestIntegration(
    policy: "manual",
    state: "manualPending",
    isActive: false,
    hasEligibleMember: true,
    requestInFlight: true))
  try expect(!DSHAgentPlatformPolicy.canRequestIntegration(
    policy: "auto",
    state: "integrating",
    isActive: false,
    hasEligibleMember: true))
  try expect(!DSHAgentPlatformPolicy.canRequestIntegration(
    policy: "manual",
    state: "discarded",
    isActive: false,
    hasEligibleMember: true))
  try expect(DSHAgentPlatformPolicy.canRequestIntegration(
    policy: "manual",
    state: "partiallyDiscarded",
    isActive: false,
    hasEligibleMember: true))
  try expect(DSHAgentPlatformPolicy.canRequestIntegration(
    policy: "manual",
    state: "partiallyAdopted",
    isActive: false,
    hasEligibleMember: true))
  try expect(!DSHAgentPlatformPolicy.canRequestIntegration(
    policy: "manual",
    state: "manualPending",
    isActive: false,
    hasEligibleMember: false))
  try expect(!DSHAgentPlatformPolicy.canRequestIntegration(
    policy: "manual",
    state: "manualPending",
    isActive: false,
    hasEligibleMember: true,
    recoveryBlocked: true))
  try expect(!DSHAgentPlatformPolicy.canDiscardResult(
    integrationState: "integrating",
    runIsActive: false,
    workspaceCleaned: false))
  try expect(!DSHAgentPlatformPolicy.canDiscardResult(
    integrationState: "failed",
    runIsActive: false,
    workspaceCleaned: false))
  try expect(DSHAgentPlatformPolicy.canDiscardResult(
    integrationState: "partiallyAdopted",
    runIsActive: false,
    workspaceCleaned: false))
}

private func testProfileDraft_preservesDefaultTask() throws {
  let profile = profileFixture()
  let draft = DSHAgentProfileDraft(profile: profile)
  try expectEqual(draft.defaultTask, "检查当前改动并运行测试。")
}

private func testBatchDecodesHistoricalSnapshotsAndIntegrationEvidence() throws {
  let json = """
  {
    "id":"batch-1",
    "rootSessionId":"root-1",
    "initiatorSessionId":"child-1",
    "initiatorLabel":"Subagent child-1",
    "rootCwd":"/workspace",
    "sourceCwd":"/workspace/feature",
    "sandboxMode":"workspace-write",
    "sourceAgentOptions":{"provider":"relay","model":"source-model","maxTokens":4096},
    "sourceToolAllowlist":["read","grep"],
    "sourceAgentPreset":"code",
    "profileId":"deleted-profile",
    "profileName":"审查助手",
    "profileMention":"reviewer",
    "profileDeleted":true,
    "profileSnapshot":{
      "id":"deleted-profile",
      "name":"审查助手",
      "mention":"reviewer",
      "persona":"只报告有证据的问题。",
      "defaultMode":"analysis",
      "allowModelDispatch":false,
      "integrationPolicy":"manual",
      "revision":1,
      "adapters":[{
        "id":"dsh",
        "runtime":"dsh",
        "enabled":true,
        "displayName":"DSH",
        "toolAllowlist":["read","grep"],
        "toolDenylist":["bash"]
      }]
    },
    "task":"检查实现",
    "mode":"execution",
    "integrationPolicy":"manual",
    "capabilitySnapshotVersion":0,
    "recoveryBlocked":true,
    "status":"succeeded",
    "createdAt":1,
    "summary":"完成",
    "integrationState":"adopted",
    "integrationSummary":"采纳了校验修复",
    "integrationTestSummary":"14 tests passed",
    "integrationError":"上一次清理失败",
    "runs":[{
      "id":"run-1",
      "batchId":"batch-1",
      "adapter":"dsh",
      "adapterBindingId":"dsh",
      "adapterSnapshot":{"id":"dsh","runtime":"dsh","enabled":true,"displayName":"DSH"},
      "runtimeProfileSnapshot":{
        "id":"deleted-profile",
        "name":"审查助手",
        "mention":"reviewer",
        "defaultMode":"analysis",
        "allowModelDispatch":false,
        "integrationPolicy":"manual",
        "revision":1,
        "adapters":[{"id":"dsh","runtime":"dsh","enabled":true}]
      },
      "label":"DSH",
      "status":"succeeded",
      "childSessionId":"child-platform",
      "worktreePath":"/tmp/worktree",
      "workspaceCleaned":true,
      "workspaceOutcome":"adopted",
      "retryable":false
    }]
  }
  """
  let batch = try JSONDecoder().decode(DSHAgentBatch.self, from: Data(json.utf8))
  try expectEqual(batch.profileSnapshot?.adapters.first?.toolDenylist, ["bash"])
  try expectEqual(batch.sourceCwd, "/workspace/feature")
  try expectEqual(batch.sandboxMode, "workspace-write")
  try expectEqual(batch.sourceAgentOptions?.modelLabel, "relay/source-model")
  try expectEqual(batch.sourceToolAllowlist, ["read", "grep"])
  try expectEqual(batch.sourceAgentPreset, "code")
  try expectEqual(batch.integrationSummary, "采纳了校验修复")
  try expectEqual(batch.integrationTestSummary, "14 tests passed")
  try expectEqual(batch.integrationError, "上一次清理失败")
  try expectEqual(batch.capabilitySnapshotVersion, 0)
  try expectEqual(batch.recoveryBlocked, true)
  try expectEqual(batch.runs.first?.adapterSnapshot?.displayName, "DSH")
  try expectEqual(batch.runs.first?.runtimeProfileSnapshot?.revision, 1)
  try expectEqual(batch.runs.first?.workspaceOutcome, "adopted")
}

private func testBatchStartEncodesModeAndIntegrationOverride() throws {
  let args = DSHAgentBatchStartArgs(
    profileId: "profile-1",
    rootSessionId: "root-1",
    initiatorSessionId: "child-1",
    task: "检查实现",
    mode: .execution,
    integrationPolicy: .auto,
    source: .composer)
  let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(args)) as? [String: Any]
  try expectEqual(object?["mode"] as? String, "execution")
  try expectEqual(object?["integrationPolicy"] as? String, "auto")
  try expectEqual(object?["source"] as? String, "composer")
}

let dshAgentPlatformTests: [NamedTest] = [
  ("Agent mention matcher finds trailing token", testMentionMatcher_findsTrailingProfileToken),
  ("Agent mention matcher ignores completed token", testMentionMatcher_ignoresCompletedToken),
  ("Agent policy routes only resolved profiles", testPolicy_routesOnlyResolvedProfile),
  ("Agent policy forbids retry after deletion", testPolicy_forbidsRetryAfterProfileDeletion),
  ("Agent policy blocks duplicate integration request", testPolicy_blocksDuplicateIntegrationRequest),
  ("Agent Profile draft preserves default task", testProfileDraft_preservesDefaultTask),
  ("Agent Batch decodes snapshots and integration evidence", testBatchDecodesHistoricalSnapshotsAndIntegrationEvidence),
  ("Agent Batch start encodes per-run overrides", testBatchStartEncodesModeAndIntegrationOverride),
]
