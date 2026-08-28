import Foundation
import AppKit
import Combine

enum DSHAgentMode: String, Codable, CaseIterable, Identifiable {
  case analysis, execution
  var id: String { rawValue }
  var label: String { self == .analysis ? "分析" : "执行" }
}

enum DSHAgentIntegrationPolicy: String, Codable, CaseIterable, Identifiable {
  case manual, auto
  var id: String { rawValue }
  var label: String { self == .manual ? "手动整合" : "自动整合" }
}

enum DSHAgentBatchSource: String, Codable {
  case composer, manual
}

enum DSHAgentDetailsMode: Hashable {
  case execution, agents, tool
}

@MainActor
final class DSHAgentPlatformState: ObservableObject {
  @Published var detailsPanelMode: DSHAgentDetailsMode = .execution
  @Published var profiles: [DSHAgentProfile] = []
  @Published var runtimeStatuses: [DSHAgentRuntimeStatus] = []
  @Published var batches: [DSHAgentBatch] = []
  @Published var selectedBatchID: String?
  @Published var selectedRunID: String?
  @Published var selectedRunLog: [DSHAgentRunLogEntry] = []
  @Published var selectedWorkspace: DSHAgentWorkspaceInspection?
  @Published var runLogHasMore = false
  @Published var showProfileEditor = false
  @Published var editingProfile: DSHAgentProfile?
  @Published var manualProfile: DSHAgentProfile?
  @Published var composerProfileID: String?
  @Published var composerMode: DSHAgentMode = .analysis
  @Published var composerIntegrationPolicy: DSHAgentIntegrationPolicy = .manual
  @Published var batchStarting = false
  @Published var integrationRequests: Set<String> = []
  private var relay: AnyCancellable?

  func attach(to harness: HarnessController) {
    relay = objectWillChange.sink { [weak harness] _ in harness?.objectWillChange.send() }
  }
}

struct DSHAgentAdapterBinding: Codable, Identifiable, Equatable {
  let id: String
  var runtime: String
  var enabled: Bool
  var displayName: String?
  var model: String?
  var toolAllowlist: [String]?
  var toolDenylist: [String]?
  var analysisSupported: Bool?
  var executionSupported: Bool?
  var config: [String: String]?

  var label: String {
    guard let displayName, !displayName.isEmpty else { return runtime }
    return displayName
  }
}

struct DSHAgentProfileDraft: Encodable, Equatable {
  var id: String?
  var name: String
  var mention: String
  var description: String?
  var persona: String?
  var defaultTask: String?
  var defaultMode: DSHAgentMode
  var allowModelDispatch: Bool
  var integrationPolicy: DSHAgentIntegrationPolicy
  var adapters: [DSHAgentAdapterBinding]

  init(profile: DSHAgentProfile? = nil) {
    id = profile?.id
    name = profile?.name ?? ""
    mention = profile?.mention ?? ""
    description = profile?.description
    persona = profile?.persona
    defaultTask = profile?.defaultTask
    defaultMode = profile?.defaultMode ?? .analysis
    allowModelDispatch = profile?.allowModelDispatch ?? false
    integrationPolicy = profile?.integrationPolicy ?? .manual
    adapters = profile?.adapters ?? []
  }

  init(
    id: String?,
    name: String,
    mention: String,
    description: String?,
    persona: String?,
    defaultTask: String?,
    defaultMode: DSHAgentMode,
    allowModelDispatch: Bool,
    integrationPolicy: DSHAgentIntegrationPolicy,
    adapters: [DSHAgentAdapterBinding]
  ) {
    self.id = id
    self.name = name
    self.mention = mention
    self.description = description
    self.persona = persona
    self.defaultTask = defaultTask
    self.defaultMode = defaultMode
    self.allowModelDispatch = allowModelDispatch
    self.integrationPolicy = integrationPolicy
    self.adapters = adapters
  }
}

struct DSHAgentProfile: Codable, Identifiable, Equatable {
  let id: String
  let name: String
  let mention: String
  let description: String?
  let persona: String?
  let defaultTask: String?
  let defaultMode: DSHAgentMode
  let allowModelDispatch: Bool
  let integrationPolicy: DSHAgentIntegrationPolicy
  let revision: Int?
  let adapters: [DSHAgentAdapterBinding]

  var enabledAdapterCount: Int { adapters.filter(\.enabled).count }
}

struct DSHAgentProfileList: Decodable {
  let items: [DSHAgentProfile]
}

struct DSHAgentRuntimeStatus: Decodable, Identifiable, Equatable {
  let runtime: String
  let displayName: String?
  let available: Bool
  let version: String?
  let detail: String?
  let analysisSupported: Bool
  let executionSupported: Bool
  var id: String { runtime }
  var label: String {
    guard let displayName, !displayName.isEmpty else { return runtime }
    return displayName
  }
}

struct DSHAgentRuntimeStatusList: Decodable {
  let items: [DSHAgentRuntimeStatus]
}

struct DSHAgentRun: Decodable, Identifiable, Equatable {
  let id: String
  let batchId: String?
  let adapter: String
  let adapterBindingId: String?
  let adapterSnapshot: DSHAgentAdapterBinding?
  let runtimeProfileSnapshot: DSHAgentProfile?
  let label: String?
  let status: String
  let attempt: Int?
  let contextId: String?
  let childSessionId: String?
  let queuedAt: Double?
  let startedAt: Double?
  let finishedAt: Double?
  let output: String?
  let error: String?
  let worktreePath: String?
  let branch: String?
  let baselineCommit: String?
  let diffSummary: String?
  let testSummary: String?
  let workspaceFiles: [String]?
  let retryable: Bool?
  let workspaceCleaned: Bool?
  let workspaceOutcome: String?
  let adopted: Bool?
  let discarded: Bool?

  var displayLabel: String {
    guard let label, !label.isEmpty else { return adapter }
    return label
  }
  var isActive: Bool { ["queued", "preparing", "running", "stopping"].contains(status) }
  var isIntegrationEligible: Bool {
    guard adopted != true,
          discarded != true,
          workspaceCleaned != true,
          workspaceOutcome != "adopted",
          workspaceOutcome != "discarded" else { return false }
    return worktreePath != nil
      || !(output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
      || ["succeeded", "failed", "cancelled", "interrupted"].contains(status)
  }
}

struct DSHAgentOptionsSnapshot: Decodable, Equatable {
  let provider: String?
  let model: String?
  let maxTokens: Int?

  var modelLabel: String? {
    guard let model, !model.isEmpty else { return nil }
    guard let provider, !provider.isEmpty else { return model }
    return "\(provider)/\(model)"
  }
}

struct DSHAgentBatch: Decodable, Identifiable, Equatable {
  let id: String
  let capabilitySnapshotVersion: Int?
  let recoveryBlocked: Bool?
  let rootSessionId: String
  let initiatorSessionId: String?
  let initiatorLabel: String?
  let rootCwd: String?
  let sourceCwd: String?
  let sandboxMode: String?
  let sourceAgentOptions: DSHAgentOptionsSnapshot?
  let sourceToolAllowlist: [String]?
  let sourceAgentPreset: String?
  let profileId: String?
  let profileName: String
  let profileMention: String?
  let profileDeleted: Bool?
  let profileSnapshot: DSHAgentProfile?
  let task: String
  let mode: DSHAgentMode
  let integrationPolicy: DSHAgentIntegrationPolicy
  let status: String
  let createdAt: Double
  let updatedAt: Double?
  let summary: String?
  let runs: [DSHAgentRun]
  let integrationState: String?
  let integrationSummary: String?
  let integrationTestSummary: String?
  let integrationError: String?

  var isActive: Bool { ["queued", "running"].contains(status) || runs.contains(where: \.isActive) }
}

struct DSHAgentBatchList: Decodable {
  let items: [DSHAgentBatch]
}

struct DSHAgentRunLogEntry: Decodable, Identifiable, Equatable {
  let seq: Int
  let time: Double
  let stream: String?
  let text: String
  var id: Int { seq }
}

struct DSHAgentRunLogPage: Decodable {
  let items: [DSHAgentRunLogEntry]
  let hasMore: Bool
}

struct DSHAgentWorkspaceInspection: Decodable {
  let worktreePath: String?
  let branch: String?
  let diffSummary: String?
  let testSummary: String?
  let files: [String]?
  let workspaceCleaned: Bool?
  let workspaceOutcome: String?
}

struct DSHAgentRemoved: Decodable {
  let removed: Bool
}

struct DSHAgentProfileSaveArgs: Encodable { let profile: DSHAgentProfileDraft }
struct DSHAgentProfileIDArgs: Encodable { let profileId: String }
struct DSHAgentRootSessionArgs: Encodable { let rootSessionId: String }
struct DSHAgentBatchIDArgs: Encodable { let batchId: String }
struct DSHAgentRunIDArgs: Encodable { let runId: String }

struct DSHAgentBatchStartArgs: Encodable {
  let profileId: String
  let rootSessionId: String
  let initiatorSessionId: String
  let task: String
  let mode: DSHAgentMode
  let integrationPolicy: DSHAgentIntegrationPolicy
  let source: DSHAgentBatchSource
}

struct DSHAgentBatchIntegrationArgs: Encodable {
  let batchId: String
  let integrationPolicy: DSHAgentIntegrationPolicy
}

struct DSHAgentIntegrationRequestArgs: Encodable {
  let batchId: String
  let preferredRunIds: [String]?
}

struct DSHAgentRunLogArgs: Encodable {
  let runId: String
  let before: Int?
  let limit: Int
}

struct DSHAgentContextIDArgs: Encodable { let contextId: String }
struct DSHAgentAnalysisResetArgs: Encodable { let profileId: String; let parentSessionId: String }

extension DSHHostClient {
  func agentProfiles() async throws -> [DSHAgentProfile] {
    try await invoke(ns: "agentProfiles", method: "list", args: EmptyPayload(), as: DSHAgentProfileList.self).items
  }

  func saveAgentProfile(_ profile: DSHAgentProfileDraft) async throws -> DSHAgentProfile {
    try await invoke(ns: "agentProfiles", method: "save", args: DSHAgentProfileSaveArgs(profile: profile), as: DSHAgentProfile.self)
  }

  func removeAgentProfile(_ profileId: String) async throws {
    _ = try await invoke(ns: "agentProfiles", method: "remove", args: DSHAgentProfileIDArgs(profileId: profileId), as: DSHAgentRemoved.self)
  }

  func agentRuntimeStatuses() async throws -> [DSHAgentRuntimeStatus] {
    try await invoke(ns: "agentProfiles", method: "runtimeStatus", args: EmptyPayload(), as: DSHAgentRuntimeStatusList.self).items
  }

  func startAgentBatch(_ args: DSHAgentBatchStartArgs) async throws -> DSHAgentBatch {
    try await invoke(ns: "agentBatches", method: "start", args: args, as: DSHAgentBatch.self)
  }

  func agentBatches(rootSessionId: String) async throws -> [DSHAgentBatch] {
    try await invoke(ns: "agentBatches", method: "list", args: DSHAgentRootSessionArgs(rootSessionId: rootSessionId), as: DSHAgentBatchList.self).items
  }

  func agentBatch(_ batchId: String) async throws -> DSHAgentBatch {
    try await invoke(ns: "agentBatches", method: "detail", args: DSHAgentBatchIDArgs(batchId: batchId), as: DSHAgentBatch.self)
  }

  func stopAgentBatch(_ batchId: String) async throws {
    _ = try await invokeOptional(ns: "agentBatches", method: "stop", args: DSHAgentBatchIDArgs(batchId: batchId), as: EmptyPayload.self)
  }

  func retryAgentRun(_ runId: String) async throws {
    _ = try await invokeOptional(ns: "agentBatches", method: "retryRun", args: DSHAgentRunIDArgs(runId: runId), as: EmptyPayload.self)
  }

  func setAgentBatchIntegration(_ batchId: String, policy: DSHAgentIntegrationPolicy) async throws {
    _ = try await invokeOptional(ns: "agentBatches", method: "setIntegration", args: DSHAgentBatchIntegrationArgs(batchId: batchId, integrationPolicy: policy), as: EmptyPayload.self)
  }

  func requestAgentIntegration(_ batchId: String, preferredRunIds: [String]? = nil) async throws {
    _ = try await invokeOptional(ns: "agentBatches", method: "requestIntegration", args: DSHAgentIntegrationRequestArgs(batchId: batchId, preferredRunIds: preferredRunIds), as: EmptyPayload.self)
  }

  func agentRunLog(_ runId: String, before: Int? = nil, limit: Int = 200) async throws -> DSHAgentRunLogPage {
    try await invoke(ns: "agentRuns", method: "log", args: DSHAgentRunLogArgs(runId: runId, before: before, limit: limit), as: DSHAgentRunLogPage.self)
  }

  func inspectAgentWorkspace(_ runId: String) async throws -> DSHAgentWorkspaceInspection {
    try await invoke(ns: "agentRuns", method: "inspectWorkspace", args: DSHAgentRunIDArgs(runId: runId), as: DSHAgentWorkspaceInspection.self)
  }

  func discardAgentContext(_ contextId: String) async throws {
    _ = try await invokeOptional(ns: "agentContexts", method: "discard", args: DSHAgentContextIDArgs(contextId: contextId), as: EmptyPayload.self)
  }

  func resetAgentAnalysisContext(profileId: String, parentSessionId: String) async throws {
    _ = try await invokeOptional(
      ns: "agentContexts",
      method: "resetAnalysis",
      args: DSHAgentAnalysisResetArgs(profileId: profileId, parentSessionId: parentSessionId),
      as: EmptyPayload.self)
  }

  func discardAgentRun(_ runId: String) async throws {
    _ = try await invokeOptional(ns: "agentRuns", method: "discard", args: DSHAgentRunIDArgs(runId: runId), as: EmptyPayload.self)
  }
}

extension HarnessController {
  var detailsPanelMode: DSHAgentDetailsMode {
    get { agentPlatform.detailsPanelMode }
    set { agentPlatform.detailsPanelMode = newValue }
  }
  var agentProfiles: [DSHAgentProfile] {
    get { agentPlatform.profiles }
    set { agentPlatform.profiles = newValue }
  }
  var agentRuntimeStatuses: [DSHAgentRuntimeStatus] {
    get { agentPlatform.runtimeStatuses }
    set { agentPlatform.runtimeStatuses = newValue }
  }
  var agentBatches: [DSHAgentBatch] {
    get { agentPlatform.batches }
    set { agentPlatform.batches = newValue }
  }
  var selectedAgentBatchID: String? {
    get { agentPlatform.selectedBatchID }
    set { agentPlatform.selectedBatchID = newValue }
  }
  var selectedAgentRunID: String? {
    get { agentPlatform.selectedRunID }
    set { agentPlatform.selectedRunID = newValue }
  }
  var selectedAgentRunLog: [DSHAgentRunLogEntry] {
    get { agentPlatform.selectedRunLog }
    set { agentPlatform.selectedRunLog = newValue }
  }
  var selectedAgentWorkspace: DSHAgentWorkspaceInspection? {
    get { agentPlatform.selectedWorkspace }
    set { agentPlatform.selectedWorkspace = newValue }
  }
  var agentRunLogHasMore: Bool {
    get { agentPlatform.runLogHasMore }
    set { agentPlatform.runLogHasMore = newValue }
  }
  var showAgentProfileEditor: Bool {
    get { agentPlatform.showProfileEditor }
    set { agentPlatform.showProfileEditor = newValue }
  }
  var editingAgentProfile: DSHAgentProfile? {
    get { agentPlatform.editingProfile }
    set { agentPlatform.editingProfile = newValue }
  }
  var manualAgentProfile: DSHAgentProfile? {
    get { agentPlatform.manualProfile }
    set { agentPlatform.manualProfile = newValue }
  }
  var composerAgentProfileID: String? {
    get { agentPlatform.composerProfileID }
    set { agentPlatform.composerProfileID = newValue }
  }
  var composerAgentMode: DSHAgentMode {
    get { agentPlatform.composerMode }
    set { agentPlatform.composerMode = newValue }
  }
  var composerAgentIntegrationPolicy: DSHAgentIntegrationPolicy {
    get { agentPlatform.composerIntegrationPolicy }
    set { agentPlatform.composerIntegrationPolicy = newValue }
  }
  var agentBatchStarting: Bool {
    get { agentPlatform.batchStarting }
    set { agentPlatform.batchStarting = newValue }
  }
  var agentIntegrationRequests: Set<String> {
    get { agentPlatform.integrationRequests }
    set { agentPlatform.integrationRequests = newValue }
  }

  var selectedComposerAgentProfile: DSHAgentProfile? {
    guard let composerAgentProfileID else { return nil }
    return agentProfiles.first { $0.id == composerAgentProfileID }
  }

  var selectedAgentBatch: DSHAgentBatch? {
    guard let selectedAgentBatchID else { return nil }
    return agentBatches.first { $0.id == selectedAgentBatchID }
  }

  var selectedAgentRun: DSHAgentRun? {
    guard let selectedAgentRunID else { return nil }
    return agentBatches.lazy.flatMap(\.runs).first { $0.id == selectedAgentRunID }
  }

  var managedAgentChildSessionIDs: Set<String> {
    Set(agentBatches.flatMap(\.runs).compactMap(\.childSessionId))
  }

  func isManagedAgentChild(_ entry: DSHSubagentEntry) -> Bool {
    managedAgentChildSessionIDs.contains(entry.id)
      || entry.label?.hasPrefix("__dsh_agent_platform__:") == true
  }

  var composerCanSubmit: Bool {
    let hasTask = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard !composerSubmissionInFlight else { return false }
    guard composerAgentProfileID != nil else { return canSend && !runningSubmissionInFlight }
    return hasTask && selectedComposerAgentProfile != nil && workspace != nil
      && !agentBatchStarting && !displayedIsRunning && !isViewingReadOnlySubagent
  }

  func submitComposer() {
    if DSHAgentPlatformPolicy.hasUnresolvedSelection(
      selectedProfileID: composerAgentProfileID,
      profileResolved: selectedComposerAgentProfile != nil
    ) {
      status = "所选 Agent Profile 已不可用；请移除标签后重新选择"
      return
    }
    if DSHAgentPlatformPolicy.shouldRouteToBatch(
      selectedProfileID: composerAgentProfileID,
      profileResolved: selectedComposerAgentProfile != nil
    ) {
      guard draftImage == nil else {
        status = "Agent Batch 暂不支持图片附件；请移除附件或改用普通消息"
        return
      }
      dispatchSelectedComposerAgentTask(draft)
      return
    }
    send()
  }

  func toolDetail(_ tool: ToolActivity) {
    selectedTool = tool
    detailsPanelMode = .tool
    showDetails = true
  }

  func showAgentManagement() {
    detailsPanelMode = .agents
    showDetails = true
    selectedAgentRunID = nil
    refreshAgentProfiles()
    refreshAgentRuntimeStatuses()
  }

  func toggleExecutionDetails() {
    if showDetails && detailsPanelMode == .execution {
      showDetails = false
    } else {
      detailsPanelMode = .execution
      showDetails = true
      selectedAgentRunID = nil
      refreshAgentBatches()
    }
  }

  func refreshAgentPlatform() {
    refreshAgentProfiles()
    refreshAgentRuntimeStatuses()
    refreshAgentBatches()
  }

  func refreshAgentProfiles() {
    guard let hostClient else { return }
    Task {
      do {
        let profiles = try await hostClient.agentProfiles()
        await MainActor.run {
          self.agentProfiles = profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
          if let selected = self.composerAgentProfileID, !profiles.contains(where: { $0.id == selected }) {
            self.clearComposerAgentProfile()
          }
        }
      } catch {
        await MainActor.run { self.status = "Agent Profile 刷新失败：\(error.localizedDescription)" }
      }
    }
  }

  func refreshAgentRuntimeStatuses() {
    guard let hostClient else { return }
    Task {
      do {
        let values = try await hostClient.agentRuntimeStatuses()
        await MainActor.run { self.agentRuntimeStatuses = values }
      } catch {
        await MainActor.run { self.agentRuntimeStatuses = [] }
      }
    }
  }

  func refreshAgentBatches(rootSessionId: String? = nil) {
    guard let hostClient else { return }
    guard let root = rootSessionId ?? hostCurrentSessionID else {
      agentBatches = []
      selectedAgentBatchID = nil
      return
    }
    Task {
      do {
        let values = try await hostClient.agentBatches(rootSessionId: root)
        await MainActor.run { self.applyAgentBatches(values, rootSessionId: root) }
      } catch {
        await MainActor.run {
          if self.hostCurrentSessionID == root { self.agentBatches = [] }
        }
      }
    }
  }

  func applyAgentBatchProjection(_ value: Any) {
    if let snapshot = DSHProjectionDecoder.decode(DSHAgentBatchList.self, from: value) {
      applyAgentBatches(snapshot.items, rootSessionId: hostCurrentSessionID)
    } else if let items = DSHProjectionDecoder.decode([DSHAgentBatch].self, from: value) {
      applyAgentBatches(items, rootSessionId: hostCurrentSessionID)
    }
  }

  private func applyAgentBatches(_ values: [DSHAgentBatch], rootSessionId: String?) {
    guard rootSessionId == nil || rootSessionId == hostCurrentSessionID else { return }
    agentBatches = values.sorted { $0.createdAt > $1.createdAt }
    if let selected = selectedAgentBatchID, !values.contains(where: { $0.id == selected }) { selectedAgentBatchID = nil }
  }

  func saveAgentProfile(_ draft: DSHAgentProfileDraft) {
    guard let hostClient else { return }
    Task {
      do {
        let profile = try await hostClient.saveAgentProfile(draft)
        await MainActor.run {
          if let index = self.agentProfiles.firstIndex(where: { $0.id == profile.id }) { self.agentProfiles[index] = profile }
          else { self.agentProfiles.append(profile) }
          self.agentProfiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
          self.showAgentProfileEditor = false
          self.editingAgentProfile = nil
          self.status = "Agent Profile 已保存"
          self.refreshAgentBatches()
        }
      } catch {
        await MainActor.run { self.status = "保存 Agent Profile 失败：\(error.localizedDescription)" }
      }
    }
  }

  func removeAgentProfile(_ profile: DSHAgentProfile) {
    guard let hostClient else { return }
    Task {
      do {
        try await hostClient.removeAgentProfile(profile.id)
        await MainActor.run {
          self.agentProfiles.removeAll { $0.id == profile.id }
          if self.composerAgentProfileID == profile.id { self.clearComposerAgentProfile() }
          self.status = "Agent Profile 已删除，历史运行仍保留"
          self.refreshAgentBatches()
        }
      } catch {
        await MainActor.run { self.status = "删除 Agent Profile 失败：\(error.localizedDescription)" }
      }
    }
  }

  func editAgentProfile(_ profile: DSHAgentProfile? = nil) {
    editingAgentProfile = profile
    showAgentProfileEditor = true
  }

  func runAgentProfile(_ profile: DSHAgentProfile) {
    manualAgentProfile = profile
  }

  func selectComposerAgentProfile(_ profile: DSHAgentProfile, replacing range: Range<String.Index>? = nil) {
    if let range { draft.removeSubrange(range) }
    composerAgentProfileID = profile.id
    composerAgentMode = profile.defaultMode
    composerAgentIntegrationPolicy = profile.integrationPolicy
  }

  func clearComposerAgentProfile() {
    composerAgentProfileID = nil
    composerAgentMode = .analysis
    composerAgentIntegrationPolicy = .manual
  }

  func ensureHostSessionForAgentPlatform(_ onComplete: @escaping (String?, UUID?) -> Void) {
    if let sessionId = hostCurrentSessionID {
      onComplete(sessionId, selectedSessionID)
      return
    }
    guard !isCreatingFirstSession, hostClient != nil else {
      status = "Host 正在创建会话，请稍后重试"
      onComplete(nil, selectedSessionID)
      return
    }
    isCreatingFirstSession = true
    let localSessionID = selectedSessionID ?? insertLocalSessionRow()
    attachHostSessionToPlaceholder(localSessionID: localSessionID) { [weak self] sessionId in
      guard let self else { return }
      self.isCreatingFirstSession = false
      onComplete(sessionId, localSessionID)
    }
  }

  func startAgentBatch(
    profile: DSHAgentProfile,
    task: String,
    mode: DSHAgentMode,
    integrationPolicy: DSHAgentIntegrationPolicy,
    source: DSHAgentBatchSource,
    appendToTranscript: Bool = false,
    accepted: ((String) -> Void)? = nil,
    failed: ((String) -> Void)? = nil
  ) {
    let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { failed?("任务不能为空"); return }
    let originSubagentSessionID = activeSubagentAddress?.mode == "continuable"
      ? activeSubagentAddress?.childSessionId
      : nil
    ensureHostSessionForAgentPlatform { [weak self] rootSessionId, originLocalSessionID in
      guard let self else { return }
      guard let rootSessionId, let hostClient = self.hostClient else {
        failed?("无法创建 Agent Batch 的根会话")
        return
      }
      let initiator = originSubagentSessionID ?? rootSessionId
      let args = DSHAgentBatchStartArgs(
        profileId: profile.id,
        rootSessionId: rootSessionId,
        initiatorSessionId: initiator,
        task: trimmed,
        mode: mode,
        integrationPolicy: integrationPolicy,
        source: source)
      Task {
        do {
          let batch = try await hostClient.startAgentBatch(args)
          await MainActor.run {
            if appendToTranscript {
              self.appendAgentDispatchMessage(
                profile: profile,
                task: trimmed,
                localSessionID: originLocalSessionID,
                subagentSessionID: originSubagentSessionID)
            }
            if DSHAgentPlatformPolicy.shouldApplyBatch(
              acceptedRootSessionID: rootSessionId,
              displayedRootSessionID: self.hostCurrentSessionID
            ) {
              if let index = self.agentBatches.firstIndex(where: { $0.id == batch.id }) { self.agentBatches[index] = batch }
              else { self.agentBatches.insert(batch, at: 0) }
              self.detailsPanelMode = .execution
              self.showDetails = true
              self.selectedAgentBatchID = batch.id
            }
            self.status = "已派发 \(profile.name) · \(mode.label)"
            accepted?(rootSessionId)
          }
        } catch {
          await MainActor.run {
            let message = "Agent Batch 启动失败：\(error.localizedDescription)"
            self.status = message
            failed?(message)
          }
        }
      }
    }
  }

  func dispatchSelectedComposerAgentTask(_ task: String) {
    guard let profile = selectedComposerAgentProfile else { return }
    let mode = composerAgentMode
    let policy = composerAgentIntegrationPolicy
    let submitted = task.trimmingCharacters(in: .whitespacesAndNewlines)
    agentBatchStarting = true
    startAgentBatch(
      profile: profile,
      task: submitted,
      mode: mode,
      integrationPolicy: policy,
      source: .composer,
      appendToTranscript: true,
      accepted: { [weak self] acceptedRootSessionID in
        guard let self else { return }
        self.agentBatchStarting = false
        if DSHAgentPlatformPolicy.shouldClearComposer(
          acceptedRootSessionID: acceptedRootSessionID,
          displayedRootSessionID: self.hostCurrentSessionID,
          submittedProfileID: profile.id,
          selectedProfileID: self.composerAgentProfileID,
          submittedTask: submitted,
          currentDraft: self.draft
        ) {
          self.draft = ""
          self.draftImage = nil
          self.clearComposerAgentProfile()
        }
      },
      failed: { [weak self] _ in
        self?.agentBatchStarting = false
      })
  }

  private func appendAgentDispatchMessage(
    profile: DSHAgentProfile,
    task: String,
    localSessionID: UUID?,
    subagentSessionID: String?
  ) {
    appendAgentDispatchUserMessage(
      "@\(profile.mention) \(task)",
      localSessionID: localSessionID,
      subagentSessionID: subagentSessionID)
  }

  func appendAgentDispatchUserMessage(_ text: String, localSessionID: UUID?, subagentSessionID: String?) {
    if let subagentSessionID {
      if activeSubagentAddress?.childSessionId == subagentSessionID, subagentTranscript != nil {
        subagentTranscript?.messages.append(Message(role: .user, text: text))
        subagentTranscript?.updatedAt = Date()
      }
      return
    }
    guard let localSessionID,
          let index = sessions.firstIndex(where: { $0.id == localSessionID }) else { return }
    sessions[index].messages.append(Message(role: .user, text: text))
    sessions[index].updatedAt = Date()
  }

  func appendSystem(_ text: String, to localSessionID: UUID) {
    guard let index = sessions.firstIndex(where: { $0.id == localSessionID }) else { return }
    sessions[index].messages.append(Message(role: .system, text: text))
    sessions[index].updatedAt = Date()
  }

  func resetAgentSessionState() {
    selectedAgentBatchID = nil
    selectedAgentRunID = nil
    selectedAgentRunLog = []
    selectedAgentWorkspace = nil
    agentBatches = []
  }

  func stopAgentBatch(_ batch: DSHAgentBatch) {
    guard let hostClient else { return }
    Task {
      do {
        try await hostClient.stopAgentBatch(batch.id)
        await MainActor.run { self.status = "已请求停止 Agent Batch"; self.refreshAgentBatches() }
      } catch { await MainActor.run { self.status = "停止 Agent Batch 失败：\(error.localizedDescription)" } }
    }
  }

  func retryAgentRun(_ run: DSHAgentRun) {
    guard let hostClient else { return }
    Task {
      do {
        try await hostClient.retryAgentRun(run.id)
        await MainActor.run { self.status = "Agent 成员已重新排队"; self.refreshAgentBatches() }
      } catch { await MainActor.run { self.status = "重试 Agent 成员失败：\(error.localizedDescription)" } }
    }
  }

  func loadAgentRunLog(_ run: DSHAgentRun, before: Int? = nil) {
    guard let hostClient else { return }
    if before == nil {
      selectedAgentRunID = run.id
      selectedAgentRunLog = []
      selectedAgentWorkspace = nil
      agentRunLogHasMore = false
      detailsPanelMode = .execution
      showDetails = true
    }
    Task {
      do {
        async let logPage = hostClient.agentRunLog(run.id, before: before)
        async let workspace = before == nil ? hostClient.inspectAgentWorkspace(run.id) : nil
        let page = try await logPage
        let inspection = try await workspace
        await MainActor.run {
          guard self.selectedAgentRunID == run.id else { return }
          if before == nil { self.selectedAgentRunLog = page.items }
          else { self.selectedAgentRunLog = page.items + self.selectedAgentRunLog }
          if before == nil { self.selectedAgentWorkspace = inspection }
          self.agentRunLogHasMore = page.hasMore
        }
      } catch { await MainActor.run { self.status = "读取 Agent 日志失败：\(error.localizedDescription)" } }
    }
  }

  func closeAgentRunLog() {
    selectedAgentRunID = nil
    selectedAgentRunLog = []
    selectedAgentWorkspace = nil
    agentRunLogHasMore = false
  }

  func requestAgentIntegration(_ batch: DSHAgentBatch, preferredRunIds: [String]? = nil) {
    guard let hostClient, !agentIntegrationRequests.contains(batch.id) else { return }
    agentIntegrationRequests.insert(batch.id)
    Task {
      do {
        try await hostClient.requestAgentIntegration(batch.id, preferredRunIds: preferredRunIds)
        await MainActor.run {
          self.agentIntegrationRequests.remove(batch.id)
          self.status = "已交给主 Agent 整合"
          self.refreshAgentBatches()
        }
      } catch {
        await MainActor.run {
          self.agentIntegrationRequests.remove(batch.id)
          self.status = "请求整合失败：\(error.localizedDescription)"
        }
      }
    }
  }

  func discardAgentContext(_ contextId: String) {
    guard let hostClient else { return }
    Task {
      do {
        try await hostClient.discardAgentContext(contextId)
        await MainActor.run { self.status = "已丢弃 Agent 执行上下文"; self.refreshAgentBatches() }
      } catch { await MainActor.run { self.status = "丢弃 Agent 上下文失败：\(error.localizedDescription)" } }
    }
  }

  func discardAgentRun(_ run: DSHAgentRun) {
    guard let hostClient else { return }
    Task {
      do {
        try await hostClient.discardAgentRun(run.id)
        await MainActor.run {
          self.status = "已丢弃 Agent 成员结果并清理 worktree"
          self.closeAgentRunLog()
          self.refreshAgentBatches()
        }
      } catch {
        await MainActor.run { self.status = "丢弃 Agent 成员失败：\(error.localizedDescription)" }
      }
    }
  }

  func resetAgentAnalysisContext(_ batch: DSHAgentBatch) {
    guard let hostClient, let profileId = batch.profileId else { return }
    Task {
      do {
        try await hostClient.resetAgentAnalysisContext(profileId: profileId, parentSessionId: batch.initiatorSessionId ?? batch.rootSessionId)
        await MainActor.run {
          self.status = "已重置 DSH 分析上下文；下次运行将使用新的 Profile 配置"
          self.refreshAgentBatches()
        }
      } catch {
        await MainActor.run { self.status = "重置分析上下文失败：\(error.localizedDescription)" }
      }
    }
  }

  func openAgentWorkspace(_ run: DSHAgentRun) {
    guard let path = run.worktreePath else { return }
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
  }
}
