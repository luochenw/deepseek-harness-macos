import SwiftUI
import AppKit
import Darwin

private let appName = "DeepSeek Harness"
private let workspaceKey = "dsh.workspace"
private let modelKey = "dsh.model"
private let providerKey = "dsh.provider"
private let reasoningEffortKey = "dsh.reasoningEffort"
private let presetKey = "dsh.preset"

@main
struct DSHNativeApp: App {
  @StateObject private var controller = HarnessController()

  var body: some Scene {
    WindowGroup(appName) {
      ContentView()
        .environmentObject(controller)
        .frame(minWidth: 1180, minHeight: 760)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
          controller.stopForTermination()
        }
    }
    .commands {
      CommandGroup(after: .newItem) {
        Button("新会话") { controller.newSession() }.keyboardShortcut("n", modifiers: .command)
        Button("选择工作区…") { controller.chooseWorkspace() }.keyboardShortcut("w", modifiers: .command)
      }
      CommandGroup(after: .toolbar) {
        Button("搜索会话") { controller.showSessionSearch = true }.keyboardShortcut("f", modifiers: [.command, .shift])
        Button("打开工作区") { controller.openWorkspace() }.keyboardShortcut("o", modifiers: .command)
        Button("设置…") { controller.showSettings = true }.keyboardShortcut(",", modifiers: .command)
      }
    }
  }
}

@MainActor
final class HarnessController: ObservableObject {
  enum Preset: String, CaseIterable, Identifiable {
    case standard, code, minimal, creator
    var id: String { rawValue }
    var label: String {
      switch self { case .standard: "标准模式"; case .code: "代码模式"; case .minimal: "极简模式"; case .creator: "创建者模式" }
    }
    var detail: String {
      switch self {
      case .standard: "完整编码 Agent：编辑、终端、文件、Web、技能、计划、目标、子代理与工作流。"
      case .code: "通过 Code Mode SDK 暴露工具，适合组合多步骤 TypeScript 操作。"
      case .minimal: "持久终端与 str_replace_editor 的精简编码 Agent。"
      case .creator: "用于创建与调试自定义 Agent preset。"
      }
    }
  }

  struct Message: Identifiable, Equatable {
    enum Role { case user, assistant, system, tool }
    let id = UUID()
    let role: Role
    var text: String
    var timestamp = Date()
    var attachment: DSHAttachmentRef?
    var reasoning: String?
    /// Host durable message id — the key for per-message Typert feedback.
    var hostMessageId: String?
    /// For `.tool` rows: joins the transcript row to its live `ToolActivity`
    /// (state, summary, presentation) in `activeTools` at render time, so the
    /// row updates in place when the result lands without mutating messages.
    var toolCallId: String?
  }

  struct Session: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var workspaceName: String
    var updatedAt: Date
    var messages: [Message]
    var isRunning = false
    var hasUnread = false
  }

  struct PendingApproval: Identifiable {
    let id: String
    let rpcId: String
    let sessionId: String
    let toolName: String
    let reason: String?
  }

  struct PendingQuestion: Identifiable {
    struct Item: Identifiable {
      let id: String
      let question: String
      let options: [String]
    }
    let id: String
    let rpcId: String
    let sessionId: String
    let items: [Item]
  }

  struct DraftImage: Identifiable {
    let id = UUID()
    let url: URL
    let mediaType: String
  }

  struct WorkflowRun: Identifiable {
    /// The wire vocabulary is `WorkflowAgentOutcome = 'completed' | 'failed'
    /// | 'cancelled'` (member-level) and `WorkflowStopReason = 'completed' |
    /// 'cancelled' | 'error'` (run-level) — both absent while running. See
    /// .agents/notes/implemented/feature/2026-08-14-workflow-phase-grouping-and-status.md.
    enum Status { case running, completed, failed, cancelled }
    struct Member: Identifiable {
      let id: Int; var label: String; var phase: String?; let childId: String; var outcome: String?
      var status: Status {
        switch outcome {
        case "completed": .completed
        case "failed": .failed
        case "cancelled": .cancelled
        default: .running
        }
      }
    }
    let id: String
    let parentSessionId: String
    var name: String
    var stopReason: String?
    var members: [Member] = []
    var status: Status {
      switch stopReason {
      case "completed": .completed
      case "error": .failed
      case "cancelled": .cancelled
      default: .running
      }
    }
  }

  struct SubagentNavigationNode: Identifiable {
    let address: DSHSubagentAddress
    let title: String
    var id: String { address.childSessionId }
  }

  /// One node of a client-walked subagent tree — see
  /// .agents/notes/implemented/feature/2026-08-14-subagent-descendants-tree.md.
  struct SubagentTreeNode: Identifiable {
    let entry: DSHSubagentEntry
    let depth: Int
    /// The breadcrumb path from the tree root down to (not including) this
    /// node — assigning this to `subagentPath` before calling `openSubagent`
    /// re-enters the existing one-level navigation at the right place.
    let ancestorPath: [SubagentNavigationNode]
    var children: [SubagentTreeNode] = []
    var id: String { entry.id }
    func flattened() -> [SubagentTreeNode] { [self] + children.flatMap { $0.flattened() } }
  }

  struct ToolActivity: Identifiable {
    enum State { case running, succeeded, failed }
    let id = UUID()
    let callId: String
    var name: String
    var summary: String
    var state: State
    var output: String
    var presentation: ToolPresentation?
  }

  struct ToolPresentation {
    struct Diff: Identifiable { let id = UUID(); let path: String; let oldText: String?; let newText: String }
    struct FileLine: Identifiable { let id = UUID(); let number: Int; let text: String }
    struct SearchMatch: Identifiable { let id = UUID(); let lineNumber: Int; let line: String }
    struct SearchFile: Identifiable { let id = UUID(); let path: String; let matches: [SearchMatch] }
    struct Source: Identifiable { let id = UUID(); let url: String; let title: String?; let snippet: String?; let publishedAt: String? }

    let card: String
    let title: String?
    let path: String?
    let output: String?
    let exitCode: Int?
    let signal: String?
    let cwd: String?
    let description: String?
    let diffs: [Diff]
    let lines: [FileLine]
    let totalLines: Int?
    let lang: String?
    let searchShape: String?
    let files: [SearchFile]
    let paths: [String]
    let truncated: Bool
    let total: Int?
    let webKind: String?
    let answer: String?
    let url: String?
    let statusCode: Int?
    let sources: [Source]

    static func from(_ view: [String: Any]?) -> Self? {
      guard let view, let card = view["card"] as? String else { return nil }
      let diffs = (view["diffs"] as? [[String: Any]] ?? []).compactMap { diff -> Diff? in
        guard let path = diff["path"] as? String, let newText = diff["newText"] as? String else { return nil }
        return Diff(path: path, oldText: diff["oldText"] as? String, newText: newText)
      }
      let lines = (view["lines"] as? [[String: Any]] ?? []).compactMap { line -> FileLine? in
        guard let number = line["number"] as? Int, let text = line["text"] as? String else { return nil }
        return FileLine(number: number, text: text)
      }
      let files = (view["files"] as? [[String: Any]] ?? []).compactMap { file -> SearchFile? in
        guard let path = file["path"] as? String else { return nil }
        let matches = (file["matches"] as? [[String: Any]] ?? []).compactMap { match -> SearchMatch? in
          guard let lineNumber = match["lineNumber"] as? Int, let line = match["line"] as? String else { return nil }
          return SearchMatch(lineNumber: lineNumber, line: line)
        }
        return SearchFile(path: path, matches: matches)
      }
      let sources = (view["sources"] as? [[String: Any]] ?? []).compactMap { source -> Source? in
        guard let url = source["url"] as? String else { return nil }
        return Source(url: url, title: source["title"] as? String, snippet: source["snippet"] as? String, publishedAt: source["publishedAt"] as? String)
      }
      return ToolPresentation(
        card: card, title: view["title"] as? String, path: view["path"] as? String,
        output: view["output"] as? String, exitCode: view["exitCode"] as? Int,
        signal: view["signal"] as? String, cwd: view["cwd"] as? String,
        description: view["description"] as? String, diffs: diffs, lines: lines,
        totalLines: view["totalLines"] as? Int, lang: view["lang"] as? String,
        searchShape: view["shape"] as? String, files: files,
        paths: view["paths"] as? [String] ?? [], truncated: view["truncated"] as? Bool ?? false,
        total: view["total"] as? Int, webKind: view["kind"] as? String,
        answer: view["answer"] as? String, url: view["url"] as? String,
        statusCode: view["statusCode"] as? Int, sources: sources
      )
    }
  }

  @Published private(set) var sessions: [Session] = []
  @Published var selectedSessionID: UUID?
  @Published var draft = ""
  @Published var activeSubagentAddress: DSHSubagentAddress?
  @Published var subagentPath: [SubagentNavigationNode] = []
  /// The currently open subagent's folded transcript, overlaying the main
  /// conversation pane. Never inserted into `sessions` — see
  /// .agents/notes/implemented/feature/2026-08-14-subagent-transcript-redesign.md.
  @Published var subagentTranscript: Session?
  @Published var showSubagentTree = false
  @Published var subagentTree: [SubagentTreeNode]?
  @Published var subagentTreeLoading = false
  @Published var subagentTreeTruncated = false
  @Published var selectedWorkflowRunID: String?
  @Published var draftImage: DraftImage?
  @Published private(set) var isRunning = false {
    didSet { nativeAlerts.setRunning(isRunning) }
  }
  @Published var status = "准备就绪"
  @Published private(set) var workspace: URL?
  @Published var showSettingsEditor = false
  @Published var selectedSettingsNamespace: DSHSettingsNamespace?
  @Published var showProviderAuthoring = false
  @Published var selectedProviderForAuthoring: DSHConfigurableProvider?

  func openProviderAuthoring(_ provider: DSHConfigurableProvider? = nil) {
    selectedProviderForAuthoring = provider
    showProviderAuthoring = true
  }

  func openSettingsEditor(ns: DSHSettingsNamespace) {
    selectedSettingsNamespace = ns
    showSettingsEditor = true
  }

  func saveSettings(ns: String, patch: [String: Any], revision: Int, conflict: @escaping () -> Void = {}) {
    guard let patchValue = DSHJSONPatchValue(patch) else {
      status = "设置格式无效"
      return
    }
    mutateSettings(
      ns: ns,
      ops: [DSHSettingsPathOperation.set(path: [], value: patchValue)],
      revision: revision,
      success: { _ in self.showSettingsEditor = false },
      conflict: conflict
    )
  }

  func saveCredential(ref: String, value: String) { guard let hostClient else { return }; Task { do { try await hostClient.setCredential(ref: ref, value: value); await MainActor.run { self.status = "凭据已保存"; self.refreshModelConfiguration() } } catch { await MainActor.run { self.status = "凭据保存失败：\(error.localizedDescription)" } } } }
  func unsetCredential(ref: String) { guard let hostClient else { return }; Task { do { try await hostClient.unsetCredential(ref: ref); await MainActor.run { self.status = "凭据已清除"; self.refreshModelConfiguration() } } catch { await MainActor.run { self.status = "凭据清除失败：\(error.localizedDescription)" } } } }

  @Published var showSettings = false
  @Published var showSessionSearch = false
  @Published var showRenameSession = false
  @Published var showArchivedSessions = false
  @Published var renameDraft = ""
  @Published var searchResults: [DSHSessionSearchItem] = []
  @Published var searchHasMore = false
  @Published var showDetails = false
  @Published var selectedTool: ToolActivity?
  @Published var provider = ""
  @Published var model = ""
  @Published var reasoningEffort = "high"
  @Published var preset: Preset = .code
  @Published var activeTools: [ToolActivity] = []
  @Published var todos: [DSHTodoItem] = []
  @Published var subagents: [DSHSubagentEntry] = []
  @Published var skills: [DSHSkillEntry] = []
  @Published var workflows: [WorkflowRun] = []
  @Published var runNotice: String?
  @Published var retryNotice: String?
  @Published var availableModels: [DSHModelGroup] = []
  @Published var currentSessionModels: DSHSessionModels?
  @Published var historyHasMore = false
  @Published var historyOldestSeq: Int?
  @Published var configurableProviders: [DSHConfigurableProvider] = []
  @Published var credentialStates: [String: DSHCredentialView] = [:]
  @Published var settingsDescription: DSHSettingsDescription?
  @Published var hostPresets: [DSHAgentPreset] = []
  @Published var hostPlanActive = false
  @Published var goal: DSHGoalProjection?
  @Published var tokenUsage: DSHTokenUsage?
  @Published var contextPressure: DSHContextPressure?
  @Published var sessionStats: DSHSessionStats?
  @Published var hostCommands: [DSHCommandDescriptor] = []
  @Published var messageFeedback: [String: DSHMessageFeedbackItem] = [:]
  @Published var pluginEntries: [DSHPluginInventoryEntry] = []
  @Published var queueItems: [DSHQueueItem] = []
  @Published var pendingApproval: PendingApproval?
  @Published var pendingQuestion: PendingQuestion?
  /// Backlog behind the currently-shown `pendingApproval`/`pendingQuestion` —
  /// a second concurrent request no longer overwrites (and orphans) the first.
  @Published var queuedApprovals: [PendingApproval] = []
  @Published var queuedQuestions: [PendingQuestion] = []
  /// "本会话总是允许" — `"sessionId::toolName"` keys auto-answered without
  /// ever surfacing a sheet. Cleared implicitly when the session changes
  /// (nothing persists this across sessions by design).
  @Published var alwaysAllowedTools: Set<String> = []
  @Published private(set) var hostStatus = "正在启动持久 DSH Host…"
  @Published private(set) var hostSessions: [DSHSessionSummary] = []
  @Published private(set) var hostWorkspaces: [DSHWorkspaceView] = []
  @Published private(set) var hostCurrentSessionID: String?
  let attachmentStore = DSHAttachmentStore()
  private let nativeAlerts = NativeAlerts()
  var hostClientForAttachments: DSHHostClient? { hostClient }

  private var hostRuntime: DSHHostRuntime?
  var hostClient: DSHHostClient?
  private var hostEvents: DSHEventSocket?
  private var muxEvents: DSHEventSocket?

  /// `~/Documents/DeepSeek Harness`, created on first use. Used only when no
  /// workspace has ever been chosen — keeps `workspace` non-nil (and
  /// `canSend` usable) without forcing a file-picker dialog before the very
  /// first message. The Host registers it as a real workspace the first time
  /// `newSession()` creates a session with this cwd, same as it already does
  /// for a workspace restored from UserDefaults.
  private static func defaultWorkspaceURL() -> URL? {
    guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
    let url = documents.appendingPathComponent("DeepSeek Harness", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  init() {
    if let path = UserDefaults.standard.string(forKey: workspaceKey), FileManager.default.fileExists(atPath: path) {
      workspace = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    } else if let defaultURL = Self.defaultWorkspaceURL() {
      workspace = defaultURL
      UserDefaults.standard.set(defaultURL.path, forKey: workspaceKey)
    }
    provider = UserDefaults.standard.string(forKey: providerKey) ?? ""
    model = UserDefaults.standard.string(forKey: modelKey) ?? ""
    reasoningEffort = UserDefaults.standard.string(forKey: reasoningEffortKey) ?? "high"
    preset = Preset(rawValue: UserDefaults.standard.string(forKey: presetKey) ?? Preset.code.rawValue) ?? .code
    seedConfigurationFromUserDSHIfNeeded()
    nativeAlerts.attach()
    newSession()
    startPersistentHost()
  }

  deinit { muxEvents?.stop(); hostEvents?.stop(); hostRuntime?.stop() }

  var workspaceName: String { workspace?.lastPathComponent ?? "选择工作区" }
  var selectedSessionIndex: Int? { sessions.firstIndex { $0.id == selectedSessionID } }
  var selectedSession: Session? { selectedSessionIndex.map { sessions[$0] } }
  /// What the conversation pane actually shows: an open subagent transcript
  /// overlays the selected top-level session, never replaces it in `sessions`.
  var displayedSession: Session? { subagentTranscript ?? selectedSession }
  var hasCredential: Bool {
    guard let settings = settingsDescription else { return false }
    return Self.llmCredentialReferences(in: settings).contains { credentialStates[$0]?.configured == true }
  }
  /// A one-shot subagent's transcript is a frozen, read-only overlay — see
  /// the subagent-transcript-redesign Agent Note.
  var isViewingReadOnlySubagent: Bool { subagentTranscript != nil && activeSubagentAddress?.mode != "continuable" }
  var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && workspace != nil && hasCredential && !isRunning && !isViewingReadOnlySubagent }
  /// The currently-selected model's catalog entry, when the live catalog
  /// lists it. Carries the adapter-owned reasoning metadata (nil for a model
  /// with no selectable effort).
  var currentModelEntry: DSHModelCatalogModel? {
    availableModels.first(where: { $0.id == provider })?.models.first(where: { $0.id == model })
  }
  /// Friendly "<group> / <model> · <effort>" label for the composer/settings
  /// model picker — falls back to the raw ids when the live catalog hasn't
  /// loaded yet (or no longer lists the currently-selected pair). The effort
  /// suffix appears only when the model actually advertises selectable
  /// efforts — printing "· high" next to a model whose adapter only accepts
  /// "off" was part of the "界面一个说法、Host 另一个说法" bug.
  var currentModelLabel: String {
    guard !provider.isEmpty, !model.isEmpty else { return "Host 默认模型" }
    if let group = availableModels.first(where: { $0.id == provider }), let match = group.models.first(where: { $0.id == model }) {
      let suffix = match.reasoning == nil ? "" : " · \(reasoningEffort)"
      return "\(group.nativeDisplayName) / \(match.name)\(suffix)"
    }
    return "\(provider == "relay" ? "自定义配置" : provider) / \(model)"
  }
  /// Clamp a requested effort to what the target model actually advertises:
  /// the requested level when offered, else the adapter default, else the
  /// first offered level; nil (omit the field on the wire) for a model with
  /// no reasoning metadata — pi-ai rejects any named level beyond "off" there.
  func advertisedEffort(provider: String, model: String, requested: String?) -> String? {
    guard let entry = availableModels.first(where: { $0.id == provider })?.models.first(where: { $0.id == model }),
          let reasoning = entry.reasoning else { return nil }
    if let requested, reasoning.efforts.contains(where: { $0.id == requested }) { return requested }
    return reasoning.defaultEffort ?? reasoning.efforts.first?.id
  }

  struct WorkspaceSessionGroup: Identifiable {
    let workspace: DSHWorkspaceView?
    let sessions: [DSHSessionSummary]
    var id: String { workspace?.workspaceId ?? "__ungrouped__" }
  }

  /// `hostSessions` grouped by matching each session's own working directory
  /// (`DSHSessionSummary.cwd`) against each workspace's folder path — see
  /// .agents/notes/implemented/architecture/2026-08-17-ocean-design-system.md.
  /// Not `DSHWorkspaceView.sessionIds`: a parallel investigation into the same
  /// grouping feature checked a real `workspace.json` on disk and found that
  /// field empty even for a workspace with sessions under it, so the Host
  /// isn't maintaining that list in practice — `cwd` is populated per-session
  /// and is the reliable signal. A session whose `cwd` doesn't match any
  /// known workspace falls into an "其他" group rather than being dropped.
  var sessionGroups: [WorkspaceSessionGroup] {
    let visible = hostSessions.filter { $0.origin != "subagent" }
    guard !hostWorkspaces.isEmpty else {
      return visible.isEmpty ? [] : [WorkspaceSessionGroup(workspace: nil, sessions: visible)]
    }
    var claimed = Set<String>()
    var groups: [WorkspaceSessionGroup] = hostWorkspaces.compactMap { ws in
      let members = visible.filter { $0.cwd == ws.path }.sorted { $0.updatedAt > $1.updatedAt }
      guard !members.isEmpty else { return nil }
      members.forEach { claimed.insert($0.sessionId) }
      return WorkspaceSessionGroup(workspace: ws, sessions: members)
    }
    let orphans = visible.filter { !claimed.contains($0.sessionId) }.sorted { $0.updatedAt > $1.updatedAt }
    if !orphans.isEmpty { groups.append(WorkspaceSessionGroup(workspace: nil, sessions: orphans)) }
    // `workspace` is a locally `.standardizedFileURL` path, not the raw
    // Host-echoed `ws.path` string the grouping above compares against
    // itself — normalize both sides here too, otherwise the current
    // workspace's group can silently fall out of "pinned first" ordering
    // (unlike the grouping match above, this compares a local URL against a
    // Host string, so it needs the normalization the Host-to-Host match doesn't).
    let currentPath = workspace?.standardizedFileURL.path
    groups.sort { a, b in
      let aCurrent = currentPath != nil && a.workspace.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path } == currentPath
      let bCurrent = currentPath != nil && b.workspace.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path } == currentPath
      if aCurrent != bCurrent { return aCurrent }
      return (a.sessions.first?.updatedAt ?? 0) > (b.sessions.first?.updatedAt ?? 0)
    }
    return groups
  }

  /// Seed the app-local DSH home from the user's existing ~/.dsh configuration
  /// when the app home has no credentials yet. Existing routes and secrets are
  /// preserved verbatim; the native UI does not create a product-specific
  /// default route for a new install.
  private func seedConfigurationFromUserDSHIfNeeded() {
    let fm = FileManager.default
    let userDSH = fm.homeDirectoryForCurrentUser.appendingPathComponent(".dsh", isDirectory: true)
    let appHome = dshHome
    let appCredential = appHome.appendingPathComponent(".credentials.yaml")
    guard !fm.fileExists(atPath: appCredential.path),
          fm.fileExists(atPath: userDSH.appendingPathComponent(".credentials.yaml").path) else { return }
    do {
      try fm.createDirectory(at: appHome, withIntermediateDirectories: true)
      for name in [".credentials.yaml", "cordis.patch.yml", "settings.yaml"] {
        let source = userDSH.appendingPathComponent(name)
        let target = appHome.appendingPathComponent(name)
        if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: target) }
      }
      status = "已导入 ~/.dsh 的模型配置"
    } catch {
      status = "导入 ~/.dsh 配置失败：\(error.localizedDescription)"
    }
  }

  private func startPersistentHost() {
    let runtime = DSHHostRuntime(node: bundledNode, dsh: bundledDSH, home: dshHome)
    hostRuntime = runtime
    runtime.start { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let url):
        self.hostClient = DSHHostClient(baseURL: url)
        self.hostEvents = DSHEventSocket(baseURL: url, path: "api/events.host", handler: { [weak self] frame in
          self?.consumeHostFrame(frame)
        }, onClosed: { [weak self] in
          self?.hostStatus = "Host 事件流已断开，正在等待重新连接"
        })
        self.hostEvents?.start()
        self.muxEvents = DSHEventSocket(baseURL: url, path: "api/events.mux", handler: { [weak self] frame in
          self?.consumeMuxFrame(frame)
        }, onClosed: { [weak self] in
          self?.hostStatus = "Host 消息流已断开，刷新会话后可恢复"
        })
        self.muxEvents?.start()
        self.hostStatus = "Host 已连接：\(url.absoluteString)"
        self.refreshHostSnapshots()
        self.refreshModelConfiguration()
        self.refreshSettings()
        self.refreshPresets()
        // init() created the launch placeholder before the Host was up;
        // give it its persistent session now, or the first send always
        // fails with "Host 未连接" — see attachHostSessionToCurrentPlaceholder.
        if self.hostCurrentSessionID == nil { self.attachHostSessionToCurrentPlaceholder() }
      case .failure(let error):
        self.hostStatus = "Host 启动失败：\(error.localizedDescription)"
      }
    }
  }

  private func consumeMuxFrame(_ input: [String: Any]) {
    var frame = input
    if let rpcId = frame.removeValue(forKey: "_rpcId") { frame["_rpcId"] = rpcId }
    guard let type = frame["type"] as? String else { return }
    switch type {
    case "session/event":
      guard let sessionID = frame["sessionId"] as? String,
            let event = frame["event"] as? [String: Any] else { return }
      if let address = activeSubagentAddress, sessionID == address.childSessionId {
        applyLiveSubagentEvent(event)
      } else if sessionID == hostCurrentSessionID {
        applyLiveEvent(event, view: frame["view"] as? [String: Any])
      }
    case "session/projection":
      guard let sessionId = frame["sessionId"] as? String, sessionId == hostCurrentSessionID,
            let key = frame["key"] as? String, let value = frame["value"] else { return }
      applyProjection(key: key, value: value)
    case "session/queue":
      if let items = frame["items"] as? [[String: Any]] {
        queueItems = items.compactMap { item in
          guard let id = item["id"] as? String else { return nil }
          let message = item["message"] as? [String: Any]
          let content = message?["content"] as? [[String: Any]]
          let text = content?.compactMap { $0["text"] as? String }.joined() ?? ""
          return DSHQueueItem(id: id, placement: item["placement"] as? String ?? "queued", text: text)
        }
      }
    case "session/jobs":
      if let jobs = frame["jobs"] as? [[String: Any]] { activeTools = jobs.map { ToolActivity(callId: $0["id"] as? String ?? UUID().uuidString, name: $0["label"] as? String ?? "后台任务", summary: $0["detail"] as? String ?? $0["status"] as? String ?? "", state: ($0["status"] as? String) == "failed" ? .failed : .running, output: "", presentation: nil) } }
    case "approval/requested":
      guard let rpcId = frame["_rpcId"] as? String, let sessionId = frame["sessionId"] as? String, let approvalId = frame["approvalId"] as? String else { return }
      let toolName = frame["toolName"] as? String ?? "工具"
      if alwaysAllowedTools.contains(Self.alwaysAllowKey(sessionId: sessionId, toolName: toolName)), let hostClient {
        Task { try? await hostClient.respond(rpcId: rpcId, value: DSHApprovalAnswer(sessionId: sessionId, approvalId: approvalId, outcome: "allowed-once")) }
        return
      }
      let approval = PendingApproval(id: approvalId, rpcId: rpcId, sessionId: sessionId, toolName: toolName, reason: frame["reason"] as? String)
      // A second request while one is already showing used to silently
      // overwrite `pendingApproval`, leaving the first's RPC unanswered
      // forever — queue instead, see the reconcile-parallel-redesigns note.
      if pendingApproval == nil { pendingApproval = approval } else { queuedApprovals.append(approval) }
      nativeAlerts.notifyApprovalNeeded(toolName: toolName)
    case "approval/resolved":
      // Another client (or a Host-side timeout) settled it — retract it
      // from whichever of the shown slot / backlog it's sitting in.
      if let approvalId = frame["approvalId"] as? String {
        if pendingApproval?.id == approvalId { pendingApproval = queuedApprovals.isEmpty ? nil : queuedApprovals.removeFirst() }
        else { queuedApprovals.removeAll { $0.id == approvalId } }
        refreshAttentionBadge()
      }
    case "question/requested":
      guard let rpcId = frame["_rpcId"] as? String, let sessionId = frame["sessionId"] as? String, let questions = frame["questions"] as? [[String: Any]] else { return }
      let items = questions.compactMap { value -> PendingQuestion.Item? in
        guard let id = value["id"] as? String, let question = value["question"] as? String else { return nil }
        let options = (value["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        return PendingQuestion.Item(id: id, question: question, options: options)
      }
      let question = PendingQuestion(id: rpcId, rpcId: rpcId, sessionId: sessionId, items: items)
      if pendingQuestion == nil { pendingQuestion = question } else { queuedQuestions.append(question) }
      nativeAlerts.notifyQuestionNeeded()
    case "question/resolved":
      if let rpcId = (frame["_rpcId"] as? String) ?? (frame["rpcId"] as? String) {
        if pendingQuestion?.id == rpcId { pendingQuestion = queuedQuestions.isEmpty ? nil : queuedQuestions.removeFirst() }
        else { queuedQuestions.removeAll { $0.id == rpcId } }
        refreshAttentionBadge()
      }
    default:
      break
    }
  }

  private func applyLiveEvent(_ event: [String: Any], view: [String: Any]? = nil) {
    guard let kind = event["type"] as? String, let data = event["data"] as? [String: Any], let index = selectedSessionIndex else { return }
    switch kind {
    case "assistant/chunk":
      // Anchor on whether the *last* message is already this turn's
      // assistant reply, not "the last assistant message anywhere" — with
      // no placeholder seeding a fresh bubble on send() (see send()'s
      // comment), the previous turn's assistant message would otherwise
      // still be the most recent assistant-role entry and silently absorb
      // the new turn's first delta.
      if let chunk = data["chunk"] as? [String: Any], chunk["type"] as? String == "text-delta", let delta = chunk["textDelta"] as? String {
        if sessions[index].messages.last?.role == .assistant { sessions[index].messages[sessions[index].messages.count - 1].text += delta }
        else { sessions[index].messages.append(Message(role: .assistant, text: delta)) }
      }
      // Thinking streams as reasoning-delta chunks (field name is `text`, not
      // `textDelta` — pi-ai adapter shape). Folding them into the message's
      // reasoning field live means thinking lands in the collapsed ✻ block
      // as it happens instead of being dropped until the final message.
      if let chunk = data["chunk"] as? [String: Any], chunk["type"] as? String == "reasoning-delta", let delta = chunk["text"] as? String {
        if sessions[index].messages.last?.role == .assistant {
          let last = sessions[index].messages.count - 1
          sessions[index].messages[last].reasoning = (sessions[index].messages[last].reasoning ?? "") + delta
        } else {
          var message = Message(role: .assistant, text: "")
          message.reasoning = delta
          sessions[index].messages.append(message)
        }
      }
    case "assistant/message":
      if let text = liveMessageText(data["message"]) {
        var message = Message(role: .assistant, text: text)
        message.hostMessageId = (data["message"] as? [String: Any])?["id"] as? String
        sessions[index].messages.append(message)
      }
    case "user/message":
      if let text = liveMessageText(data["message"]) { sessions[index].messages.append(Message(role: .user, text: text)) }
    case "tool/call":
      let tool = ToolActivity(callId: data["callId"] as? String ?? UUID().uuidString, name: data["name"] as? String ?? "工具", summary: "正在运行", state: .running, output: "", presentation: ToolPresentation.from(view?["view"] as? [String: Any]))
      activeTools.append(tool)
      selectedTool = tool
      // Inline transcript row (Claude Code style); the row itself renders
      // live state by looking up `activeTools` via toolCallId, so tool/result
      // below only needs to update the activity, not this message.
      sessions[index].messages.append(Message(role: .tool, text: tool.name, toolCallId: tool.callId))
    case "tool/result":
      let callId = data["callId"] as? String
      if let toolIndex = activeTools.lastIndex(where: { callId == nil || $0.callId == callId }) {
        activeTools[toolIndex].state = .succeeded
        activeTools[toolIndex].presentation = ToolPresentation.from(view?["view"] as? [String: Any]) ?? activeTools[toolIndex].presentation
        activeTools[toolIndex].output = activeTools[toolIndex].presentation?.output ?? "工具已完成"
        selectedTool = activeTools[toolIndex]
      }
    case "tool-workflow/run-start":
      if let runId = data["runId"] as? String, let name = data["name"] as? String, let parentSessionId = hostCurrentSessionID { workflows.append(WorkflowRun(id: runId, parentSessionId: parentSessionId, name: name)) }
    case "tool-workflow/agent-start":
      if let runId = data["runId"] as? String, let seq = data["seq"] as? Int, let label = data["label"] as? String, let childId = data["childId"] as? String, let index = workflows.firstIndex(where: { $0.id == runId }) { workflows[index].members.append(WorkflowRun.Member(id: seq, label: label, phase: data["phase"] as? String, childId: childId, outcome: nil)) }
    case "tool-workflow/agent-end":
      if let runId = data["runId"] as? String, let seq = data["seq"] as? Int, let outcome = data["outcome"] as? String, let index = workflows.firstIndex(where: { $0.id == runId }), let member = workflows[index].members.firstIndex(where: { $0.id == seq }) { workflows[index].members[member].outcome = outcome }
    case "tool-workflow/run-end":
      if let runId = data["runId"] as? String, let reason = data["stopReason"] as? String, let index = workflows.firstIndex(where: { $0.id == runId }) { workflows[index].stopReason = reason }
    case "todo/write":
      if let rawTodos = data["todos"] as? [[String: Any]] {
        todos = rawTodos.compactMap { item in
          guard let content = item["content"] as? String, let status = item["status"] as? String else { return nil }
          return DSHTodoItem(content: content, status: status)
        }
      }
    case "plan/mode":
      hostPlanActive = (data["active"] as? Bool) ?? hostPlanActive
    case "goal/change":
      refreshHostSnapshots()
    case "llm/retry":
      let retry = data["retry"] as? Int ?? 0
      let delay = data["delayMs"] as? Int ?? 0
      let provider = data["provider"] as? String ?? "模型"
      retryNotice = "\(provider) 请求失败，正在第 \(retry) 次重试（等待 \(delay)ms）"
    case "llm/retry-started":
      retryNotice = nil
    case "turn/end":
      let kind = (data["reason"] as? [String: Any])?["kind"] as? String
      switch kind {
      case "max-tokens": runNotice = "本轮达到最大输出 token 限制"
      case "error": runNotice = "本轮执行失败"
      case "aborted": runNotice = "本轮已中断"
      default: break
      }
      // Host turns end async; nothing previously reset these for the Host
      // path (only the removed legacy one-shot process's completion handler
      // did), so the composer stayed stuck on "停止/排队" after the first
      // message — see .agents/notes/implemented/feature/2026-08-17-port-feature-completeness-branch.md.
      isRunning = false
      sessions[index].isRunning = false
      nativeAlerts.notifyTurnFinished(summary: sessions[index].title)
    case "compaction/start":
      runNotice = "正在压缩历史上下文…"
    case "compaction/end":
      runNotice = "历史上下文压缩完成"
    case "compaction/summary":
      let summary = data["summary"] as? String
      runNotice = summary.map { "上下文摘要：\($0)" } ?? "已生成上下文摘要"
      // Persist into the scrollback — the banner above is overwritten by the
      // next event, but a compaction is a rare, meaningful moment worth
      // being able to scroll back to (unlike retries, left as ephemeral).
      sessions[index].messages.append(Message(role: .system, text: summary.map { "历史上下文已压缩。摘要：\($0)" } ?? "历史上下文已压缩。"))
    default:
      break
    }
  }

  /// Mirrors the message-streaming subset of `applyLiveEvent` for the
  /// currently open subagent transcript. Tool/todo/goal/workflow dashboard
  /// events intentionally stay scoped to the top-level session — see the
  /// subagent-transcript-redesign Agent Note.
  private func applyLiveSubagentEvent(_ event: [String: Any]) {
    guard let kind = event["type"] as? String, let data = event["data"] as? [String: Any] else { return }
    switch kind {
    case "assistant/chunk":
      if let chunk = data["chunk"] as? [String: Any], chunk["type"] as? String == "text-delta", let delta = chunk["textDelta"] as? String {
        if subagentTranscript?.messages.last?.role == .assistant, let count = subagentTranscript?.messages.count { subagentTranscript?.messages[count - 1].text += delta }
        else { subagentTranscript?.messages.append(Message(role: .assistant, text: delta)) }
      }
    case "assistant/message":
      if let text = liveMessageText(data["message"]) { subagentTranscript?.messages.append(Message(role: .assistant, text: text)) }
    case "user/message":
      if let text = liveMessageText(data["message"]) { subagentTranscript?.messages.append(Message(role: .user, text: text)) }
    case "turn/end":
      subagentTranscript?.isRunning = false
    default:
      break
    }
  }

  private func liveMessageText(_ value: Any?) -> String? {
    guard let message = value as? [String: Any], let content = message["content"] as? [[String: Any]] else { return nil }
    return content.compactMap { $0["text"] as? String }.joined()
  }

  private func consumeHostFrame(_ frame: [String: Any]) {
    guard let type = frame["type"] as? String else { return }
    switch type {
    case "host/session-added", "host/session-removed", "host/workspace-changed", "host/workspace-removed", "host/workspace-order-changed", "host/archived-sessions-changed":
      refreshHostSnapshots()
    case "host/session-status":
      if let running = frame["running"] as? Bool { status = running ? "DSH 正在运行" : "DSH 已空闲" }
    case "host/agent-error":
      if let message = frame["message"] as? String { appendSystem("DSH Host 错误：\(message)") }
    case "host/remote-event":
      if let event = frame["event"] as? String {
        if event == "settings/document-updated" { refreshSettings(); refreshModelConfiguration() }
        if event == "llm/adapters-updated" { refreshModelConfiguration(); refreshSessionModels() }
      }
    default:
      break
    }
  }



  func refreshPresets() {
    guard let hostClient else { return }
    Task { if let values = try? await hostClient.presets() { await MainActor.run { self.hostPresets = values } } }
  }

  func selectCurrentPreset(_ preset: String) {
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task {
      do { try await hostClient.selectPreset(sessionId: sessionId, preset: preset); await MainActor.run { self.status = "已切换 Agent preset：\(preset)"; self.refreshHostSnapshots() } }
      catch { await MainActor.run { self.appendSystem("Preset 切换失败：\(error.localizedDescription)") } }
    }
  }

  func refreshSettings() {
    guard let hostClient else { return }
    Task {
      do {
        let description = try await hostClient.settings()
        await MainActor.run { self.settingsDescription = description }
      } catch { await MainActor.run { self.status = "设置读取失败：\(error.localizedDescription)" } }
    }
  }

  func refreshSessionModels() {
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task {
      do {
        let models = try await hostClient.sessionModels(sessionId: sessionId)
        await MainActor.run {
          self.currentSessionModels = models
          self.provider = models.current.provider
          self.model = models.current.model
          if let effort = models.current.reasoningEffort { self.reasoningEffort = effort }
        }
      } catch {
        await MainActor.run { self.status = "会话模型读取失败：\(error.localizedDescription)" }
      }
    }
  }

  func refreshModelConfiguration() {
    guard let hostClient else { return }
    Task {
      do {
        async let models = hostClient.models()
        async let providers = hostClient.providers()
        async let settings = hostClient.settings()
        let (nextModels, nextProviders, nextSettings) = try await (models, providers, settings)
        let refs = Self.credentialReferences(in: nextSettings)
        let credentials = try await hostClient.credentials(refs: refs)
        await MainActor.run {
          self.availableModels = nextModels
          self.credentialStates = credentials
          self.configurableProviders = nextProviders
          self.settingsDescription = nextSettings
          if !self.provider.isEmpty,
             !nextModels.contains(where: { group in group.id == self.provider && group.models.contains(where: { $0.id == self.model }) }) {
            self.provider = ""
            self.model = ""
            UserDefaults.standard.removeObject(forKey: providerKey)
            UserDefaults.standard.removeObject(forKey: modelKey)
          }
        }
      } catch { await MainActor.run { self.status = "模型配置读取失败：\(error.localizedDescription)" } }
    }
  }

  func reconnectHostStreams() {
    guard let client = hostClient else {
      startPersistentHost()
      return
    }
    hostEvents?.stop()
    muxEvents?.stop()
    hostEvents = DSHEventSocket(baseURL: client.baseURL, path: "api/events.host", handler: { [weak self] frame in self?.consumeHostFrame(frame) }, onClosed: { [weak self] in self?.hostStatus = "Host 事件流已断开" })
    muxEvents = DSHEventSocket(baseURL: client.baseURL, path: "api/events.mux", handler: { [weak self] frame in self?.consumeMuxFrame(frame) }, onClosed: { [weak self] in self?.hostStatus = "Host 消息流已断开" })
    hostEvents?.start()
    muxEvents?.start()
    hostStatus = "Host 事件流已重新连接"
    refreshHostSnapshots()
    refreshModelConfiguration()
    refreshSettings()
  }

  func refreshHostSnapshots() {
    guard let hostClient else { return }
    Task {
      do {
        async let sessions = hostClient.sessions()
        async let workspaces = hostClient.workspaceSnapshot()
        let (nextSessions, snapshot) = try await (sessions, workspaces)
        // session.list returns every persisted session — per workspace.d.ts,
        // "archived sessions stay in their workspace's sessionIds account;
        // grouping surfaces hide them". Subtracting the registry's archive
        // set here is that hiding; without it, archiving a session looked
        // like a no-op in the sidebar (the rows came straight back on the
        // next refresh) even though the Host had archived it just fine.
        let archived = Set(snapshot.archivedSessionIds)
        let visibleSessions = nextSessions.filter { !archived.contains($0.sessionId) }
        await MainActor.run {
          self.hostSessions = visibleSessions
          self.hostWorkspaces = snapshot.items
          self.hostStatus = "Host 已同步 \(visibleSessions.count) 个会话 / \(snapshot.items.count) 个工作区"
        }
      } catch {
        await MainActor.run { self.hostStatus = "Host 同步失败：\(error.localizedDescription)" }
      }
    }
  }


  func searchSessions(_ query: String) {
    guard let hostClient else { return }
    let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    guard !trimmed.isEmpty else { searchResults = []; searchHasMore = false; return }
    Task {
      do {
        let result = try await hostClient.searchSessions(query: trimmed)
        await MainActor.run { self.searchResults = result.items; self.searchHasMore = result.hasMore }
      } catch { await MainActor.run { self.status = "会话搜索失败：\(error.localizedDescription)" } }
    }
  }

  func openHostSessionID(_ id: String) {
    guard let summary = hostSessions.first(where: { $0.sessionId == id }) else { return }
    openHostSession(summary)
  }




  func beginRenameCurrentSession() {
    renameDraft = selectedSession?.title ?? ""
    showRenameSession = hostCurrentSessionID != nil
  }

  func renameCurrentSession() {
    let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let hostClient, let sessionId = hostCurrentSessionID, !title.isEmpty else { return }
    Task {
      do {
        let accepted = try await hostClient.renameSession(sessionId, title: title)
        await MainActor.run {
          if let index = self.selectedSessionIndex { self.sessions[index].title = accepted }
          self.showRenameSession = false
          self.refreshHostSnapshots()
        }
      } catch { await MainActor.run { self.appendSystem("重命名失败：\(error.localizedDescription)") } }
    }
  }

  func forkCurrentSession() {
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task {
      do {
        let childID = try await hostClient.forkSession(sessionId)
        await MainActor.run {
          self.refreshHostSnapshots()
          self.status = "已创建会话分支"
          self.openHostSessionID(childID)
        }
      } catch { await MainActor.run { self.appendSystem("创建分支失败：\(error.localizedDescription)") } }
    }
  }

  func archiveCurrentSession() {
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task {
      do {
        try await hostClient.archiveSession(sessionId)
        await MainActor.run {
          self.status = "会话已归档"
          self.refreshHostSnapshots()
          self.newSession()
        }
      } catch { await MainActor.run { self.appendSystem("归档会话失败：\(error.localizedDescription)") } }
    }
  }

  func newSession() {
    let session = Session(title: "新会话", workspaceName: workspaceName, updatedAt: Date(), messages: [
      Message(role: .system, text: "正在创建持久 DSH 会话…")
    ])
    sessions.insert(session, at: 0)
    selectedSessionID = session.id
    selectedTool = nil
    activeSubagentAddress = nil
    subagentPath = []
    subagentTranscript = nil
    selectedWorkflowRunID = nil
    attachHostSessionToCurrentPlaceholder()
  }

  /// Create the persistent Host session backing the currently-selected local
  /// placeholder. Split out of `newSession()` because init() runs
  /// `newSession()` before `startPersistentHost()` — the launch placeholder
  /// is created while `hostClient` is still nil, and without a post-connect
  /// retry it stays Host-less forever: every send on a fresh launch died with
  /// "Host 未连接，无法发送" until the user manually hit ⌘N. The connect
  /// callback now calls this when no Host session is bound yet.
  func attachHostSessionToCurrentPlaceholder() {
    guard let hostClient else { return }
    let cwd = workspace?.path
    let presetId = preset == .creator ? "cordis" : preset.rawValue
    // Capture the composer's advertised selection before hopping off the main
    // actor — `session.create` takes no model, so without an explicit
    // `session.selectModel` right after, the Host silently runs its own
    // config default (`agent-default-model` in the app-scoped DSH home) while
    // the composer label keeps showing this local state. That mismatch is
    // exactly the "picked GPT-5.6 Terra, Host errored about
    // ark/deepseek-v4-flash" bug — see the composer-consolidation Agent Note.
    let (chosenProvider, chosenModel) = (provider, model)
    // Clamped, not raw `reasoningEffort`: pushing a level the model never
    // advertised (the stored "high" against an effort-less relay model) would
    // fail the whole selectModel call and leave the session on the config
    // default — the very bug this push exists to fix.
    let chosenEffort = advertisedEffort(provider: provider, model: model, requested: reasoningEffort)
    Task {
      do {
        let created = try await hostClient.createSession(cwd: cwd, agentPreset: presetId)
        await MainActor.run {
          self.hostCurrentSessionID = created.sessionId
          if let index = self.selectedSessionIndex {
            self.sessions[index].messages = [Message(role: .system, text: "已连接到持久 DSH 会话。")]}
          self.refreshHostSnapshots()
        }
        if !chosenProvider.isEmpty, !chosenModel.isEmpty {
          do {
            try await hostClient.selectModel(sessionId: created.sessionId, provider: chosenProvider, model: chosenModel, reasoningEffort: chosenEffort)
          } catch {
            await MainActor.run { self.appendSystem("新会话未能应用所选模型（\(chosenProvider) / \(chosenModel)）：\(error.localizedDescription)") }
          }
        }
        // Sync back from the Host either way so the composer label reflects
        // the session's real model, not an unconfirmed local wish.
        await MainActor.run { self.refreshSessionModels() }
      } catch {
        await MainActor.run { self.appendSystem("持久会话创建失败：\(error.localizedDescription)") }
      }
    }
  }

  func selectSession(_ id: UUID) {
    selectedSessionID = id
    if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].hasUnread = false }
  }

  func openHostSession(_ summary: DSHSessionSummary) {
    hostCurrentSessionID = summary.sessionId
    activeSubagentAddress = nil
    subagentPath = []
    subagentTranscript = nil
    selectedWorkflowRunID = nil
    if let existing = sessions.firstIndex(where: { $0.title == summary.title && $0.workspaceName == (summary.cwd ?? "") }) {
      selectedSessionID = sessions[existing].id
      return
    }
    let local = Session(
      title: summary.title,
      workspaceName: summary.cwd ?? "未指定工作区",
      updatedAt: Date(timeIntervalSince1970: summary.updatedAt / 1000),
      messages: [Message(role: .system, text: "已打开持久 DSH 会话。历史事件、工具、审批与子代理将从 Host 流同步。")],
      isRunning: summary.running,
    )
    sessions.insert(local, at: 0)
    selectedSessionID = local.id
    todos = summary.projections?.values.todos ?? []
    hostPlanActive = summary.projections?.values.plan?.active ?? false
    goal = summary.projections?.values.goal
    tokenUsage = summary.projections?.values.tokenUsage
    contextPressure = summary.projections?.values.contextPressure
    sessionStats = summary.projections?.values.sessionStats
    status = summary.running ? "持久会话正在运行" : "正在载入持久会话"
    loadHistory(sessionId: summary.sessionId, localSessionID: local.id)
    loadSubagents(parentSessionId: summary.sessionId)
    refreshSessionModels()
    loadSkills(sessionId: summary.sessionId)
    loadCommands(sessionId: summary.sessionId)
    loadMessageFeedback(sessionId: summary.sessionId)
  }



  private func loadSkills(sessionId: String) {
    guard let hostClient else { return }
    Task {
      do {
        let result = try await hostClient.skills(sessionId: sessionId)
        await MainActor.run { self.skills = result }
      } catch { await MainActor.run { self.skills = [] } }
    }
  }

  /// Typert-layer session context: the slash-command roster and per-message
  /// feedback state. Both are structurally unreachable over the legacy
  /// ApiProxy layer — see DSHTypertGateway.swift.
  func loadCommands(sessionId: String) {
    guard let hostClient else { return }
    Task { if let commands = try? await hostClient.listCommands(sessionId: sessionId) { await MainActor.run { self.hostCommands = commands } } }
  }

  func loadMessageFeedback(sessionId: String) {
    guard let hostClient else { return }
    Task {
      if let items = try? await hostClient.messageFeedback(sessionId: sessionId) {
        await MainActor.run { self.messageFeedback = Dictionary(uniqueKeysWithValues: items.map { ($0.messageId, $0) }) }
      }
    }
  }

  func loadPluginInventory() {
    guard let hostClient else { return }
    Task { if let entries = try? await hostClient.pluginInventory() { await MainActor.run { self.pluginEntries = entries } } }
  }

  /// Thumb feedback on one assistant message; `rating` nil removes it.
  func setFeedback(messageId: String, rating: String?) {
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    let existing = messageFeedback[messageId]
    Task {
      do {
        if let rating {
          let item = try await hostClient.putMessageFeedback(sessionId: sessionId, messageId: messageId, rating: rating, note: nil, ifVersion: existing?.version)
          await MainActor.run { self.messageFeedback[messageId] = item }
        } else if let existing {
          try await hostClient.deleteMessageFeedback(sessionId: sessionId, messageId: messageId, ifVersion: existing.version)
          await MainActor.run { self.messageFeedback[messageId] = nil }
        }
      } catch {
        await MainActor.run { self.status = "反馈提交失败：\(error.localizedDescription)"; self.loadMessageFeedback(sessionId: sessionId) }
      }
    }
  }

  private func loadSubagents(parentSessionId: String) {
    guard let hostClient else { return }
    Task {
      do {
        let catalog = try await hostClient.subagents(parentSessionId: parentSessionId)
        await MainActor.run { self.subagents = catalog.entries }
      } catch { await MainActor.run { self.subagents = [] } }
    }
  }

  private func loadHistory(sessionId: String, localSessionID: UUID) {
    guard let hostClient else { return }
    Task {
      do {
        let page = try await hostClient.history(sessionId: sessionId)
        let messages = foldHistory(page.events)
        await MainActor.run {
          guard let index = self.sessions.firstIndex(where: { $0.id == localSessionID }) else { return }
          self.sessions[index].messages = messages.isEmpty ? [Message(role: .system, text: "这个会话还没有可显示的消息。")] : messages
          self.historyHasMore = page.hasMore
          self.historyOldestSeq = page.events.map { $0.event.seq }.min()
          self.sessions[index].updatedAt = Date()
          self.status = "已载入 \(messages.count) 条原生会话消息"
        }
      } catch {
        await MainActor.run { self.appendSystem("载入会话历史失败：\(error.localizedDescription)") }
      }
    }
  }

  func loadOlderHistory() {
    guard let hostClient, let sessionId = hostCurrentSessionID, let before = historyOldestSeq, historyHasMore, let index = selectedSessionIndex else { return }
    Task {
      do {
        let page = try await hostClient.history(sessionId: sessionId, beforeSeq: before, maxMessages: 100)
        let older = foldHistory(page.events)
        await MainActor.run {
          self.sessions[index].messages = older + self.sessions[index].messages
          self.historyHasMore = page.hasMore
          self.historyOldestSeq = page.events.map { $0.event.seq }.min() ?? self.historyOldestSeq
        }
      } catch {
        await MainActor.run { self.status = "载入更早消息失败" }
      }
    }
  }
  private func foldHistory(_ entries: [DSHHistoryEntry]) -> [Message] {
    var result: [Message] = []
    var tools: [String: ToolActivity] = [:]
    for entry in entries {
      let event = entry.event
      guard let data = event.data.object else { continue }
      switch event.type {
      case "user/message":
        if let text = textFromMessage(data["message"]) { result.append(Message(role: .user, text: text, timestamp: Date(timeIntervalSince1970: event.time / 1000), attachment: attachmentFromMessage(data["message"]))) }
      case "assistant/message":
        if let text = textFromMessage(data["message"]) {
          var message = Message(role: .assistant, text: text, timestamp: Date(timeIntervalSince1970: event.time / 1000), attachment: attachmentFromMessage(data["message"]), reasoning: reasoningFromMessage(data["message"]))
          message.hostMessageId = data["message"]?.object?["id"]?.string
          result.append(message)
        }
      case "tool/call":
        let name = data["name"]?.string ?? "tool"
        let id = data["callId"]?.string ?? "\(event.seq)"
        tools[id] = ToolActivity(callId: id, name: name, summary: "工具调用", state: .running, output: "", presentation: historyPresentation(entry.view))
        result.append(Message(role: .tool, text: name, timestamp: Date(timeIntervalSince1970: event.time / 1000), toolCallId: id))
      case "tool/result":
        let id = data["callId"]?.string ?? "\(event.seq)"
        if var tool = tools[id] {
          tool.state = .succeeded
          tool.presentation = historyPresentation(entry.view) ?? tool.presentation
          tool.output = tool.presentation?.output ?? textFromValue(data["result"]) ?? "工具已完成"
          tools[id] = tool
        }
      case "todo/write":
        if let todos = data["todos"]?.array { result.append(Message(role: .system, text: "任务清单更新：\(todos.count) 项")) }
      case "turn/end":
        break
      default:
        continue
      }
    }
    activeTools = Array(tools.values)
    if selectedTool == nil { selectedTool = activeTools.first }
    return result
  }

  private func reasoningFromMessage(_ value: DSHJSONValue?) -> String? {
    guard let object = value?.object, let content = object["content"]?.array else { return nil }
    let text = content.compactMap { block -> String? in guard let data = block.object, data["type"]?.string == "reasoning" else { return nil }; return data["text"]?.string }.joined()
    return text.isEmpty ? nil : text
  }

  private func historyPresentation(_ view: DSHJSONValue?) -> ToolPresentation? {
    guard let object = view?.object, let embedded = object["view"]?.object else { return nil }
    let raw = Dictionary(uniqueKeysWithValues: embedded.map { ($0.key, anyValue($0.value)) })
    return ToolPresentation.from(raw)
  }

  private func attachmentFromMessage(_ value: DSHJSONValue?) -> DSHAttachmentRef? {
    guard let object = value?.object, let content = object["content"]?.array else { return nil }
    for block in content {
      guard let data = block.object, data["type"]?.string == "image", let attachment = data["attachment"]?.object else { continue }
      guard let id = attachment["attachmentId"]?.string, let media = attachment["mediaType"]?.string, let bytes = attachment["bytes"] else { continue }
      let size: Int
      if case let .number(value) = bytes { size = Int(value) } else { continue }
      let width: Int = { if case let .number(v) = attachment["width"] { return Int(v) }; return 0 }()
      let height: Int = { if case let .number(v) = attachment["height"] { return Int(v) }; return 0 }()
      return DSHAttachmentRef(attachmentId: id, mediaType: media, bytes: size, width: width, height: height, name: attachment["name"]?.string)
    }
    return nil
  }

  private func textFromMessage(_ value: DSHJSONValue?) -> String? {
    guard let object = value?.object, let content = object["content"]?.array else { return nil }
    return content.compactMap { block in
      guard let data = block.object, data["type"]?.string == "text" else { return nil }
      return data["text"]?.string
    }.joined()
  }

  private func anyValue(_ value: DSHJSONValue) -> Any {
    switch value {
    case .string(let x): return x
    case .number(let x): return x
    case .bool(let x): return x
    case .null: return NSNull()
    case .array(let x): return x.map(anyValue)
    case .object(let x): return Dictionary(uniqueKeysWithValues: x.map { ($0.key, anyValue($0.value)) })
    }
  }

  private func textFromValue(_ value: DSHJSONValue?) -> String? {
    guard let value else { return nil }
    switch value {
    case .string(let text): return text
    case .object(let object):
      if let content = object["content"]?.array { return content.compactMap { $0.object?["text"]?.string }.joined() }
      return object["text"]?.string
    default: return nil
    }
  }

  func renameWorkspace(_ workspace: DSHWorkspaceView, title: String) {
    guard let hostClient, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    Task { do { _ = try await hostClient.renameWorkspace(id: workspace.workspaceId, title: title); await MainActor.run { self.refreshHostSnapshots() } } catch { await MainActor.run { self.status = "工作区重命名失败：\(error.localizedDescription)" } } }
  }

  func deleteWorkspace(_ workspace: DSHWorkspaceView) {
    guard let hostClient else { return }
    Task { do { try await hostClient.deleteWorkspace(id: workspace.workspaceId); await MainActor.run { self.refreshHostSnapshots() } } catch { await MainActor.run { self.status = "工作区删除失败：\(error.localizedDescription)" } } }
  }

  func registerWorkspace(_ url: URL) {
    guard let hostClient else { return }
    Task {
      do {
        let result = try await hostClient.createWorkspace(path: url.path)
        await MainActor.run {
          self.workspace = url.standardizedFileURL
          UserDefaults.standard.set(url.path, forKey: workspaceKey)
          self.status = result.created ? "工作区已添加" : "工作区已选择"
          self.refreshHostSnapshots()
        }
      } catch {
        await MainActor.run { self.status = "工作区注册失败：\(error.localizedDescription)" }
      }
    }
  }

  func chooseWorkspace() {
    let panel = NSOpenPanel()
    panel.title = "选择 DSH 工作区"
    panel.message = "DSH 将在此目录中读取、修改文件并运行终端命令。"
    panel.prompt = "选择工作区"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = workspace
    guard panel.runModal() == .OK, let selected = panel.url else { return }
    registerWorkspace(selected.standardizedFileURL)
    if let index = selectedSessionIndex { sessions[index].workspaceName = selected.lastPathComponent }
  }

  /// Match the Host/Web path contract: absolute paths pass through, while file-tool
  /// paths relative to the selected workspace are resolved before they reach Host.
  nonisolated static func resolveWorkspacePath(_ path: String, workspace: URL?) -> String {
    guard !path.hasPrefix("/"), !path.hasPrefix("\\"),
          path.range(of: "^[A-Za-z]:[/\\]", options: .regularExpression) == nil,
          let workspace else { return path }
    return workspace.appendingPathComponent(path).standardizedFileURL.path
  }

  func openDeliveredFile(_ path: String) {
    openHostPath(Self.resolveWorkspacePath(path, workspace: workspace))
  }

  func revealDeliveredFile(_ path: String) {
    let resolved = Self.resolveWorkspacePath(path, workspace: workspace)
    let directory = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
    openHostPath(directory)
  }

  func openHostPath(_ path: String) {
    guard let hostClient else { return }
    Task {
      do {
        try await hostClient.openPath(path)
        await MainActor.run { self.status = "已请求 Host 打开路径" }
      } catch {
        await MainActor.run { self.status = "打开路径失败" }
      }
    }
  }

  func openWorkspace() {
    guard let workspace else { chooseWorkspace(); return }
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path)
  }

  func loadAttachment(_ ref: DSHAttachmentRef) {
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task { do { let result = try await hostClient.attachment(sessionId: sessionId, attachmentId: ref.attachmentId); await MainActor.run { self.appendSystem("已读取附件：\(result.attachment.name ?? result.attachment.attachmentId)，\(result.attachment.bytes) bytes") } } catch { await MainActor.run { self.appendSystem("附件读取失败：\(error.localizedDescription)") } } }
  }

  func pickImage() {
    let panel = NSOpenPanel()
    panel.title = "选择图片附件"
    panel.allowedContentTypes = [.png, .jpeg, .webP, .gif]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let ext = url.pathExtension.lowercased()
    let type = ext == "png" ? "image/png" : ext == "gif" ? "image/gif" : ext == "webp" ? "image/webp" : "image/jpeg"
    draftImage = DraftImage(url: url, mediaType: type)
  }

  func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let image = draftImage
    guard !text.isEmpty || image != nil else { return }
    guard !isViewingReadOnlySubagent else { return }
    var content: [DSHPromptContent] = text.isEmpty ? [] : [.text(text)]
    if let image, let bytes = try? Data(contentsOf: image.url) { content.append(.image(data: bytes.base64EncodedString(), mediaType: image.mediaType, name: image.url.lastPathComponent)) }

    if let hostClient, let address = activeSubagentAddress, address.mode == "continuable" {
      draft = ""
      draftImage = nil
      Task {
        do { try await hostClient.promptSubagent(parentSessionId: address.parentSessionId, childSessionId: address.childSessionId, content: content); await MainActor.run { self.status = "已发送子代理追问" } }
        catch { await MainActor.run { self.appendSystem("子代理追问失败：\(error.localizedDescription)") } }
      }
      return
    }
    guard workspace != nil else { status = "请选择工作区"; chooseWorkspace(); return }
    guard hasCredential else { status = "需要配置 API Key"; showSettings = true; return }
    guard !isRunning, let sessionIndex = selectedSessionIndex else { return }
    guard let hostClient, let hostSessionID = hostCurrentSessionID else {
      status = "Host 未连接，无法发送；请点击重新连接后再试"
      return
    }

    // Slash commands dispatch through the Typert command registry with a
    // typed result; an unresolvable line falls back to a normal prompt.
    if text.hasPrefix("/"), image == nil {
      draft = ""
      sessions[sessionIndex].messages.append(Message(role: .user, text: text))
      // Gate re-entry the same way the normal-prompt path below does — a
      // fallback to `prompt(...)` starts a real turn, and without this the
      // `guard !isRunning` above never engages, letting a second send fire
      // into the same session while the first is still in flight.
      isRunning = true
      sessions[sessionIndex].isRunning = true
      Task {
        do {
          if let execution = try await hostClient.executeCommand(sessionId: hostSessionID, line: text) {
            await MainActor.run {
              if let output = execution.result.text, !output.isEmpty { self.appendSystem(execution.succeeded ? output : "命令失败：\(output)") }
              else { self.status = execution.succeeded ? "命令已执行" : "命令执行失败" }
              // Command execution isn't a turn — no `turn/end` event will
              // arrive to reset this, unlike the `prompt(...)` fallback below.
              self.isRunning = false
              if let current = self.selectedSessionIndex { self.sessions[current].isRunning = false }
            }
          } else {
            try await hostClient.prompt(sessionId: hostSessionID, content: [.text(text)])
          }
        } catch {
          await MainActor.run {
            self.isRunning = false
            if let current = self.selectedSessionIndex { self.sessions[current].isRunning = false }
            self.appendSystem("命令执行失败：\(error.localizedDescription)")
          }
        }
      }
      return
    }

    draft = ""
    draftImage = nil
    let preview = image == nil ? text : "\(text)\n[图片附件：\(image!.url.lastPathComponent)]"
    sessions[sessionIndex].messages.append(Message(role: .user, text: preview))
    // No placeholder assistant bubble here — `assistant/chunk` (above) opens
    // a fresh bubble itself on the first delta; a synchronous placeholder
    // previously left either a glued-together "处理中…<real text>" bubble or
    // a dangling stale line once real content replaced it (never cleaned up
    // — see .agents/notes/implemented/bug-fix/2026-08-17-composer-consolidation.md).
    sessions[sessionIndex].isRunning = true
    isRunning = true
    status = "持久 Host 正在处理"
    Task {
      do {
        var content: [DSHPromptContent] = text.isEmpty ? [] : [.text(text)]
        if let image, let bytes = try? Data(contentsOf: image.url) { content.append(.image(data: bytes.base64EncodedString(), mediaType: image.mediaType, name: image.url.lastPathComponent)) }
        try await hostClient.prompt(sessionId: hostSessionID, content: content)
        await MainActor.run { self.status = "已交给持久 Host；等待事件流接入" }
      } catch {
        await MainActor.run {
          self.isRunning = false
          if let current = self.selectedSessionIndex { self.sessions[current].isRunning = false }
          self.appendSystem("Host prompt 失败：\(error.localizedDescription)")
        }
      }
    }
  }

  func mutateQueue(_ item: DSHQueueItem, action: DSHQueueAction) {
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task {
      do {
        try await hostClient.updateQueue(sessionId: sessionId, itemId: item.id, action: action)
        await MainActor.run { self.status = "队列操作已提交" }
      } catch { await MainActor.run { self.appendSystem("队列操作失败：\(error.localizedDescription)") } }
    }
  }

  /// Submits while a turn is already running, via the same Host RPC `send()`
  /// uses (`session.prompt` defaults to `mode: "queue"`) — previously this
  /// only appended to a local array that nothing ever drained once the
  /// legacy one-shot CLI path was removed, so a message typed while
  /// "运行中" silently vanished. The Host's own `session/queue` push
  /// (already wired into `queueItems`) is what actually reflects the queued
  /// item back into the UI, not local state here.
  func queueDraft() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let image = draftImage
    guard !text.isEmpty || image != nil else { return }
    guard let hostClient, let hostSessionID = hostCurrentSessionID else { return }
    draft = ""
    draftImage = nil
    Task {
      do {
        var content: [DSHPromptContent] = text.isEmpty ? [] : [.text(text)]
        if let image, let bytes = try? Data(contentsOf: image.url) { content.append(.image(data: bytes.base64EncodedString(), mediaType: image.mediaType, name: image.url.lastPathComponent)) }
        try await hostClient.prompt(sessionId: hostSessionID, content: content, mode: "queue")
        await MainActor.run { self.status = "已排队" }
      } catch { await MainActor.run { self.appendSystem("排队失败：\(error.localizedDescription)") } }
    }
  }

  func stop() {
    guard let hostClient, let hostSessionID = hostCurrentSessionID else { return }
    Task {
      do { try await hostClient.cancel(sessionId: hostSessionID); await MainActor.run { self.status = "已请求取消持久会话" } }
      catch { await MainActor.run { self.status = "取消失败：\(error.localizedDescription)" } }
    }
  }
  /// The bundled Host is a long-lived child process, not per-message — this
  /// is the only place it's asked to stop. `deinit` firing is not reliable
  /// for a GUI app's actual quit path, so `applicationWillTerminate` (wired
  /// in DSHNativeApp) calls this explicitly.
  func stopForTermination() { hostRuntime?.stop() }



  /// `reasoning` nil means "don't ask for a specific effort" — sent to the
  /// Host as an omitted field (not a fallback to whatever `reasoningEffort`
  /// happened to be left at), so switching to a model that doesn't support
  /// the previously-selected model's effort (e.g. Relay's models have no
  /// `reasoning.efforts` at all, so "high"/"max" from a DeepSeek-official
  /// pick get rejected as `model-unavailable`) lets the Host fall back to
  /// that model's own default instead of failing the switch outright.
  func selectCurrentModel(provider: String, model: String, reasoning: String? = nil) {
    let nextProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
    let nextModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !nextProvider.isEmpty, !nextModel.isEmpty else { return }
    self.provider = nextProvider
    self.model = nextModel
    if let reasoning { self.reasoningEffort = reasoning }
    // Persist the full triple — restoring provider/model but resetting the
    // effort would recreate invalid pairs on relaunch (e.g. a model that only
    // supports "off" coming back with the hardcoded "high" default).
    UserDefaults.standard.set(nextProvider, forKey: providerKey)
    UserDefaults.standard.set(nextModel, forKey: modelKey)
    UserDefaults.standard.set(reasoningEffort, forKey: reasoningEffortKey)
    // No live session yet: keep the local choice; newSession() pushes it via
    // session.selectModel the moment the next session is created.
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task {
      do {
        let selected = try await hostClient.selectModel(sessionId: sessionId, provider: nextProvider, model: nextModel, reasoningEffort: reasoning)
        await MainActor.run {
          // Sync back whatever effort the Host actually resolved to (its
          // own default when we omitted one) so the composer label doesn't
          // keep showing a stale effort the switch didn't actually request.
          if let resolved = selected.reasoningEffort { self.reasoningEffort = resolved }
          self.status = "已切换到 \(self.nativeProviderDisplayName(nextProvider)) / \(nextModel)"
        }
      } catch { await MainActor.run { self.appendSystem("模型切换失败：\(error.localizedDescription)") } }
    }
  }

  func setPreset(_ next: Preset) {
    preset = next
    UserDefaults.standard.set(next.rawValue, forKey: presetKey)
    appendSystem("新会话将使用\(next.label)。当前运行中的会话不受影响。")
  }

  private func nativeProviderDisplayName(_ provider: String) -> String {
    availableModels.first(where: { $0.id == provider })?.nativeDisplayName
      ?? (provider == "relay" ? "自定义配置" : provider)
  }

  func toolDetail(_ tool: ToolActivity) { selectedTool = tool; showDetails = true }



  var currentSubagentParentID: String? { subagentPath.last?.address.childSessionId ?? hostCurrentSessionID }

  func openSubagent(_ entry: DSHSubagentEntry) {
    guard let parent = currentSubagentParentID, entry.kind == "child", let mode = entry.mode else { return }
    let address = DSHSubagentAddress(parentSessionId: parent, childSessionId: entry.id, mode: mode)
    let label = entry.label ?? entry.id
    Task {
      guard await loadSubagentTranscript(address: address, label: label, running: entry.activity == "running") else { return }
      await MainActor.run {
        self.subagentPath.append(SubagentNavigationNode(address: address, title: label))
        self.loadSubagents(parentSessionId: entry.id)
      }
    }
  }

  func navigateUpSubagent() {
    guard !subagentPath.isEmpty else { return }
    subagentPath.removeLast()
    guard let node = subagentPath.last else {
      activeSubagentAddress = nil
      subagentTranscript = nil
      if let parent = hostCurrentSessionID { loadSubagents(parentSessionId: parent) }
      return
    }
    Task {
      await loadSubagentTranscript(address: node.address, label: node.title, running: false)
      await MainActor.run { self.loadSubagents(parentSessionId: node.address.childSessionId) }
    }
  }

  /// Fetches and folds a subagent's history into `subagentTranscript`. Shared
  /// by `openSubagent` (drill down) and `navigateUpSubagent` (drill back up
  /// to an ancestor) so both paths can never disagree about what's on screen.
  @discardableResult
  private func loadSubagentTranscript(address: DSHSubagentAddress, label: String, running: Bool) async -> Bool {
    guard let hostClient else { return false }
    do {
      let page = try await hostClient.subagentHistory(parentSessionId: address.parentSessionId, childSessionId: address.childSessionId, mode: address.mode)
      let messages = foldHistory(page.events)
      await MainActor.run {
        self.subagentTranscript = Session(title: label, workspaceName: "子代理", updatedAt: Date(), messages: messages.isEmpty ? [Message(role: .system, text: "子代理尚无可展示的消息。")] : messages, isRunning: running)
        self.activeSubagentAddress = address
        self.status = "已打开子代理历史"
      }
      return true
    } catch {
      await MainActor.run { self.appendSystem("读取子代理历史失败：\(error.localizedDescription)") }
      return false
    }
  }

  func selectWorkflow(_ run: WorkflowRun) { selectedWorkflowRunID = run.id }

  func openWorkflowMember(run: WorkflowRun, member: WorkflowRun.Member) {
    guard let hostClient else { return }
    Task { do {
      let catalog = try await hostClient.subagents(parentSessionId: run.parentSessionId)
      guard let entry = catalog.entries.first(where: { $0.id == member.childId }) else { await MainActor.run { self.status = "工作流成员已不可用" }; return }
      await MainActor.run { self.selectedWorkflowRunID = run.id; self.subagentPath = []; self.hostCurrentSessionID = run.parentSessionId; self.openSubagent(entry) }
    } catch { await MainActor.run { self.appendSystem("读取工作流成员失败：\(error.localizedDescription)") } } }
  }

  func interruptSubagent(_ entry: DSHSubagentEntry) {
    guard let hostClient, let parent = currentSubagentParentID, entry.kind == "child", entry.mode == "continuable" else { return }
    Task {
      do {
        try await hostClient.interruptSubagent(parentSessionId: parent, childSessionId: entry.id)
        await MainActor.run { self.status = "已请求中断子代理"; self.loadSubagents(parentSessionId: parent) }
      } catch { await MainActor.run { self.appendSystem("子代理中断失败：\(error.localizedDescription)") } }
    }
  }

  func performGoalAction(_ action: String) {
    guard let hostClient, let sessionId = hostCurrentSessionID, let state = goal, let goal = state.goal else { return }
    Task {
      do {
        try await hostClient.goalAction(action, sessionId: sessionId, goalId: goal.id, revision: goal.revision)
        await MainActor.run { self.status = "目标操作已提交：\(action)"; self.refreshHostSnapshots() }
      } catch { await MainActor.run { self.appendSystem("目标操作失败：\(error.localizedDescription)") } }
    }
  }


  static func alwaysAllowKey(sessionId: String, toolName: String) -> String { "\(sessionId)::\(toolName)" }

  func answerApproval(_ approval: PendingApproval, allowed: Bool, alwaysThisSession: Bool = false) {
    guard let hostClient else { return }
    // Validate against the specific item the sheet was showing, not just
    // whatever is currently `pendingApproval` — a queued backlog item can
    // promote into that slot between the sheet rendering and the click
    // landing (mirrors `answerQuestionBatch`'s id check below).
    if pendingApproval?.id == approval.id { pendingApproval = queuedApprovals.isEmpty ? nil : queuedApprovals.removeFirst() }
    else { queuedApprovals.removeAll { $0.id == approval.id } }
    refreshAttentionBadge()
    if allowed && alwaysThisSession { alwaysAllowedTools.insert(Self.alwaysAllowKey(sessionId: approval.sessionId, toolName: approval.toolName)) }
    Task {
      do {
        try await hostClient.respond(rpcId: approval.rpcId, value: DSHApprovalAnswer(sessionId: approval.sessionId, approvalId: approval.id, outcome: allowed ? "allowed-once" : "rejected"))
        await MainActor.run { self.appendSystem(allowed ? "已允许 \(approval.toolName) 执行一次。" : "已拒绝 \(approval.toolName)。") }
      } catch { await MainActor.run { self.appendSystem("审批响应失败：\(error.localizedDescription)") } }
    }
  }

  /// Moves the currently-shown question to the back of the backlog instead
  /// of discarding it — the old "取消" button submitted an empty answer,
  /// silently dropping the question. Pulls the next queued one (if any)
  /// into view; `presentDeferredQuestion()` recalls a deferred one later.
  func deferPendingQuestion(_ question: PendingQuestion) {
    guard pendingQuestion?.id == question.id else { return }
    let next = queuedQuestions.isEmpty ? nil : queuedQuestions.removeFirst()
    queuedQuestions.append(question)
    pendingQuestion = next
  }

  func presentDeferredQuestion() {
    guard pendingQuestion == nil, !queuedQuestions.isEmpty else { return }
    pendingQuestion = queuedQuestions.removeFirst()
  }

  func answerQuestionBatch(_ question: PendingQuestion, selections: [String: String], custom: [String: String]) {
    guard let hostClient else { return }
    if pendingQuestion?.id == question.id { pendingQuestion = queuedQuestions.isEmpty ? nil : queuedQuestions.removeFirst() }
    else { queuedQuestions.removeAll { $0.id == question.id } }
    refreshAttentionBadge()
    var answers: [DSHQuestionAnswer.Item] = []
    for item in question.items {
      let selectedValue = selections[item.id] ?? ""
      let selected = selectedValue.isEmpty ? [] : [selectedValue]
      let customValue = custom[item.id] ?? ""
      answers.append(DSHQuestionAnswer.Item(id: item.id, selected: selected, custom: customValue.isEmpty ? nil : customValue))
    }
    Task {
      do {
        try await hostClient.respond(rpcId: question.rpcId, value: DSHQuestionAnswer(sessionId: question.sessionId, answer: answers))
        await MainActor.run { self.appendSystem("已提交 Agent 问题回答。") }
      } catch {
        await MainActor.run { self.appendSystem("问题回答失败") }
      }
    }
  }
  /// Applied from a live `session/projection` "title" push — the Host may
  /// derive/rename a session's title mid-turn (e.g. from the first prompt).
  func applyProjectedTitle(_ title: String) {
    guard !title.isEmpty, let index = selectedSessionIndex else { return }
    sessions[index].title = title
  }

  /// Drops the menu-bar "needs attention" badge once nothing is left
  /// waiting for an answer — called after every approval/question
  /// resolution, whether answered locally or settled by another client.
  private func refreshAttentionBadge() {
    if pendingApproval == nil && pendingQuestion == nil { nativeAlerts.clearAttention() }
  }

  private func appendSystem(_ text: String) {
    guard let index = selectedSessionIndex else { return }
    sessions[index].messages.append(Message(role: .system, text: text))
    sessions[index].updatedAt = Date()
  }

  var dshHome: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DeepSeek Harness/dsh", isDirectory: true)
  }
  private var resources: URL { Bundle.main.resourceURL! }
  private var runtime: URL { resources.appendingPathComponent("Runtime") }
  private var bundledNode: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/node") }
  private var bundledDSH: URL { runtime.appendingPathComponent("dsh/lib/bin.js") }

}

struct ContentView: View {
  @EnvironmentObject private var harness: HarnessController
  var body: some View {
    HStack(spacing: 0) {
      Sidebar().frame(width: 290)
      VStack(spacing: 0) {
        ConversationHeader()
        ConversationView().frame(maxWidth: .infinity, maxHeight: .infinity)
        Composer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      if harness.showDetails {
        DetailsPanel().frame(width: 330).background(DSHTheme.surfaceTint)
      }
    }
    // 果冻海：窗口底是一整片海水渐变，上面的侧栏/卡片全是半透明薄层，
    // 让海水透出来 — 见 2026-08-17-jelly-sea-theme.md
    .background(DSHTheme.canvasGradient)
    .sheet(isPresented: $harness.showSettings) { SettingsView() }
    .sheet(isPresented: $harness.showSettingsEditor) {
      if let namespace = harness.selectedSettingsNamespace { SettingsEditorView(namespace: namespace) }
    }
    .sheet(isPresented: $harness.showProviderAuthoring) {
      if let namespace = harness.settingsDescription?.namespaces.first(where: { $0.ns == "llm-pi-ai" }) {
        ProviderAuthoringView(namespace: namespace, provider: harness.selectedProviderForAuthoring)
      }
    }
    .sheet(isPresented: $harness.showSessionSearch) { SessionSearchView() }
    .sheet(isPresented: $harness.showSubagentTree) { SubagentTreeView() }
    .sheet(isPresented: $harness.showRenameSession) { RenameSessionSheet() }
    .sheet(isPresented: $harness.showArchivedSessions) { ArchivedSessionsView() }
    .sheet(item: $harness.pendingApproval) { approval in ApprovalSheet(approval: approval) }
    .sheet(item: $harness.pendingQuestion) { question in QuestionBatchSheet(question: question) }
  }
}

private struct Sidebar: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s5) {
      HStack {
        HStack(spacing: DSHSpace.s2) {
          Image(systemName: "water.waves").foregroundStyle(DSHTheme.accent)
          Text("DeepSeek Harness").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DSHTheme.ink)
        }
        Spacer()
        Button(action: harness.newSession) { Image(systemName: "square.and.pencil") }.buttonStyle(.dshGhost).help("新会话")
      }
      Button(action: harness.newSession) { Label("新会话", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.dshPrimary)

      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        HStack {
          Text("工作区").dshSectionLabel()
          Spacer()
          Button(action: { harness.showSessionSearch = true }) { Image(systemName: "magnifyingglass") }.buttonStyle(.dshGhost)
        }
        Button(action: harness.chooseWorkspace) {
          Label(harness.workspaceName, systemImage: "folder").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.dshSecondary).help(harness.workspace?.path ?? "选择工作区")
      }

      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        HStack {
          Text("会话").dshSectionLabel()
          Spacer()
          Button(action: harness.refreshHostSnapshots) { Image(systemName: "arrow.clockwise") }.buttonStyle(.dshGhost)
          Text("\(harness.hostSessions.count > 0 ? harness.hostSessions.count : harness.sessions.count)").font(.system(size: 10.5)).foregroundStyle(DSHTheme.inkFaint)
        }
        if harness.hostSessions.isEmpty && harness.sessions.isEmpty {
          SidebarEmptySessionState()
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: DSHSpace.s4) {
              if !harness.hostSessions.isEmpty {
                let groups = harness.sessionGroups
                // Degrade to a flat list with no section labels when every
                // session landed in the single headerless "其他" bucket —
                // don't show grouping chrome when there's nothing to group.
                let showHeaders = !(groups.count == 1 && groups[0].workspace == nil)
                ForEach(groups) { group in
                  VStack(alignment: .leading, spacing: 3) {
                    if showHeaders { Text(group.workspace?.title ?? "其他").dshSectionLabel().padding(.leading, 2) }
                    ForEach(group.sessions) { session in SidebarSessionRow(session: session) }
                  }
                }
              } else {
                ForEach(harness.sessions) { session in SidebarLocalSessionRow(session: session) }
              }
            }
          }
        }
      }.frame(maxHeight: .infinity)

      VStack(alignment: .leading, spacing: 6) {
        Button(action: { harness.showSettings = true }) { Label("设置", systemImage: "gearshape") }.buttonStyle(.dshGhost)
        HStack(spacing: 6) {
          DSHStatusDot(kind: harness.hostClient == nil ? .idle : .live, diameter: 6)
          Text(harness.hostStatus).font(.system(size: 10.5)).foregroundStyle(DSHTheme.inkFaint).lineLimit(2)
        }
      }
    }
    .padding(DSHSpace.s4)
    .background(DSHTheme.sidebarBg)
  }
}

/// Shared chrome for a sidebar session row — both the Host-backed list and
/// the local fallback list render through this so their layout/selection
/// treatment can't drift apart.
private struct SidebarRowChrome: View {
  let title: String
  let date: Date
  let statusKind: DSHStatusDot.Kind
  let isActive: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: DSHSpace.s2) {
        DSHStatusDot(kind: statusKind)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 12.5)).foregroundStyle(DSHTheme.ink).lineLimit(1)
          Text(Self.compactTime(date)).font(.system(size: 10.5)).foregroundStyle(DSHTheme.inkFaint)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, DSHSpace.s2).padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      // contentShape makes the whole row hit-testable — a plain-style Button
      // only responds where content draws, so the trailing blank half of the
      // row was otherwise dead space.
      .contentShape(Rectangle())
      .background(isActive ? DSHTheme.sidebarSelected : .clear, in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
    }.buttonStyle(.plain)
  }
  /// Minute-granularity timestamp — `Text(_, style: .relative)` ticks with
  /// seconds, which reads as visual noise in a static list.
  private static func compactTime(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "刚刚" }
    if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
    if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if Calendar.current.isDateInYesterday(date) { return "昨天 " + date.formatted(date: .omitted, time: .shortened) }
    return date.formatted(.dateTime.month().day())
  }
}

private struct SidebarSessionRow: View {
  @EnvironmentObject var harness: HarnessController
  let session: DSHSessionSummary
  var body: some View {
    // Host sessions carry no "seen/unread" flag (unlike the local fallback
    // `Session.hasUnread` below) — only the running state is real signal
    // here, so a finished session gets no dot rather than a misleading
    // `.unread` amber one.
    SidebarRowChrome(
      title: session.title,
      date: Date(timeIntervalSince1970: session.updatedAt / 1000),
      statusKind: session.running ? .live : .idle,
      isActive: harness.hostCurrentSessionID == session.sessionId,
      action: { harness.openHostSession(session) }
    )
  }
}

private struct SidebarLocalSessionRow: View {
  @EnvironmentObject var harness: HarnessController
  let session: HarnessController.Session
  var body: some View {
    SidebarRowChrome(
      title: session.title,
      date: session.updatedAt,
      statusKind: session.isRunning ? .live : session.hasUnread ? .unread : .idle,
      isActive: harness.selectedSessionID == session.id,
      action: { harness.selectSession(session.id) }
    )
  }
}

private struct SidebarEmptySessionState: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    VStack(spacing: DSHSpace.s2) {
      Image(systemName: "bubble.left").font(.title2).foregroundStyle(DSHTheme.inkFaint)
      Text("还没有会话").font(.caption).foregroundStyle(DSHTheme.inkFaint)
      Button(action: harness.newSession) { Label("新会话", systemImage: "plus") }.buttonStyle(.dshSecondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, DSHSpace.s6)
  }
}

private struct HeaderChip<Content: View>: View {
  let icon: String
  let label: String
  @ViewBuilder let content: () -> Content
  var body: some View {
    Menu { content() } label: {
      HStack(spacing: 6) { Image(systemName: icon).font(.system(size: 11)); Text(label).font(.system(size: 11.5)) }
        .padding(.horizontal, DSHSpace.s3).padding(.vertical, 6)
        .background(DSHTheme.surface, in: Capsule())
        .foregroundStyle(DSHTheme.inkSoft)
    }.menuStyle(.borderlessButton).fixedSize()
  }
}

private struct ConversationHeader: View {
  @EnvironmentObject var harness: HarnessController

  /// The Host's live summary for the session currently shown — used only to
  /// decide whether the preset control should be locked, see `presetLocked`.
  private var currentSessionSummary: DSHSessionSummary? {
    harness.hostSessions.first { $0.sessionId == harness.hostCurrentSessionID }
  }
  /// True once the Host has real presets to offer AND the displayed session
  /// already has turn history — in that state `selectCurrentPreset` would be
  /// rejected by the Host with `agent-preset-locked`, so the control must not
  /// stay clickable and silently fail. The local `setPreset` path (used when
  /// `hostPresets` is empty, i.e. it only affects the *next* new session) is
  /// never rejected and stays untouched.
  private var presetLocked: Bool {
    guard !harness.hostPresets.isEmpty, let summary = currentSessionSummary else { return false }
    return summary.blank == false
  }
  private var lockedPresetLabel: String { currentSessionSummary?.agentPreset ?? harness.preset.label }

  var body: some View {
    HStack(spacing: DSHSpace.s2) {
      VStack(alignment: .leading, spacing: 2) {
        if !harness.subagentPath.isEmpty {
          HStack(spacing: 6) {
            Button(action: harness.navigateUpSubagent) { Image(systemName: "chevron.left") }.buttonStyle(.dshGhost).help("返回上一级")
            Text(harness.subagentPath.map(\.title).joined(separator: " › ")).font(.caption).foregroundStyle(DSHTheme.inkFaint).lineLimit(1)
          }
        }
        Text(harness.displayedSession?.title ?? "新会话").font(.system(size: 15, weight: .semibold)).foregroundStyle(DSHTheme.ink)
        Text(harness.workspace?.path ?? "选择工作区后开始").font(.caption).foregroundStyle(DSHTheme.inkFaint).lineLimit(1)
      }
      Spacer()
      if presetLocked {
        HStack(spacing: 6) { Image(systemName: "lock.fill").font(.system(size: 11)); Text(lockedPresetLabel).font(.system(size: 11.5)) }
          .padding(.horizontal, DSHSpace.s3).padding(.vertical, 6)
          .background(DSHTheme.warmSoft, in: Capsule())
          .foregroundStyle(DSHTheme.warm)
          .help("会话已开始运行，Agent Preset 无法再切换（Host 会拒绝：agent-preset-locked）")
      } else {
        HeaderChip(icon: "cpu", label: harness.preset.label) {
          if harness.hostPresets.isEmpty { ForEach(HarnessController.Preset.allCases) { p in Button(p.label) { harness.setPreset(p) } } }
          else { ForEach(harness.hostPresets.filter { $0.broken == nil }) { p in Button(p.name ?? p.id) { harness.selectCurrentPreset(p.id) } } }
        }
      }
      Button(action: { harness.showDetails.toggle() }) { Image(systemName: "sidebar.right") }.buttonStyle(.dshGhost)
    }.padding(.horizontal, DSHSpace.s5).padding(.vertical, DSHSpace.s3)
  }
}

private struct ConversationView: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: DSHSpace.s4) {
          if harness.historyHasMore && harness.subagentTranscript == nil {
            Button("载入更早消息", action: harness.loadOlderHistory).buttonStyle(.dshSecondary).frame(maxWidth: .infinity)
          }
          let messages = harness.displayedSession?.messages ?? []
          if messages.isEmpty {
            ConversationEmptyState()
          } else {
            ForEach(messages) { message in
              VStack(alignment: .leading, spacing: DSHSpace.s2) {
                if let reasoning = message.reasoning { ReasoningBlock(text: reasoning) }
                MessageBubble(message: message)
              }.id(message.id)
            }
            // Waiting indicator between send and the first streamed token —
            // the send path no longer seeds a placeholder assistant bubble
            // (see the composer-consolidation note), so without this row the
            // transcript sits visually dead until the first delta arrives.
            if harness.isRunning, messages.last?.role != .assistant || messages.last?.text.isEmpty == true {
              WaitingWaveIndicator().id("waiting-indicator")
            }
          }
        }.frame(maxWidth: .infinity).padding(DSHSpace.s6)
      }
      .onChange(of: harness.displayedSession?.messages) { _, messages in if let last = messages?.last { proxy.scrollTo(last.id, anchor: .bottom) } }
    }
  }
}

/// One rolling wave band of the waiting indicator — top edge is a cosine
/// curve whose phase the caller advances per frame.
private struct WaveBand: Shape {
  let baseY: CGFloat
  let amplitude: CGFloat
  let phase: CGFloat
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let steps = 24
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    for i in 0...steps {
      let fraction = CGFloat(i) / CGFloat(steps)
      let x = rect.minX + fraction * rect.width
      let y = rect.minY + baseY * rect.height + amplitude * rect.height * cos(phase + fraction * .pi * 2.5)
      path.addLine(to: CGPoint(x: x, y: y))
    }
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

/// Waiting style for the gap between send and the first streamed token: a
/// miniature of the app icon (deep-sea gradient, moon, layered waves) with
/// the waves actually rolling. Colors are the icon generator's constants —
/// keep the two in sync when the icon changes.
private struct WaitingWaveIndicator: View {
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      ZStack {
        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
          .fill(LinearGradient(
            colors: [Color(red: 0.031, green: 0.106, blue: 0.125), Color(red: 0.043, green: 0.216, blue: 0.235), Color(red: 0.039, green: 0.424, blue: 0.404)],
            startPoint: .top, endPoint: .bottom))
        Circle().fill(Color(red: 0.867, green: 0.980, blue: 0.960)).frame(width: 4.5, height: 4.5).offset(x: 5.5, y: -7)
        WaveBand(baseY: 0.56, amplitude: 0.07, phase: t * 1.7).fill(Color(red: 0.290, green: 0.871, blue: 0.824).opacity(0.30))
        WaveBand(baseY: 0.66, amplitude: 0.065, phase: t * 2.3 + 2.1).fill(Color(red: 0.376, green: 0.925, blue: 0.871).opacity(0.55))
        WaveBand(baseY: 0.75, amplitude: 0.055, phase: t * 2.9 + 4.4).fill(Color(red: 0.173, green: 0.773, blue: 0.722).opacity(0.95))
      }
      .frame(width: 26, height: 26)
      .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ConversationEmptyState: View {
  var body: some View {
    VStack(spacing: DSHSpace.s2) {
      Image(systemName: "bubble.left").font(.system(size: 26)).foregroundStyle(DSHTheme.inkFaint)
      Text("还没有消息").font(.callout).foregroundStyle(DSHTheme.inkFaint)
      Text("在下方输入内容开始对话").font(.caption).foregroundStyle(DSHTheme.inkFaint)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, DSHSpace.s7)
  }
}

/// A model's reasoning/thinking trace, rendered as its own region above the
/// answer, Claude Code-style: flat dim gray, no card. Collapsed it's a single
/// "✻ 思考过程" line with a one-line preview; expanded it's the full
/// reasoning in gray italic, indented under the toggle.
private struct ReasoningBlock: View {
  let text: String
  @State private var expanded = false
  private var preview: String {
    text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
        HStack(spacing: 6) {
          Text("✻").font(.system(size: 11))
          Text("思考过程").font(.system(size: 12)).italic()
          if !expanded, !preview.isEmpty {
            Text(preview).font(.system(size: 12)).italic().lineLimit(1).opacity(0.7)
          }
          Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .foregroundStyle(DSHTheme.inkFaint)
        .contentShape(Rectangle())
      }.buttonStyle(.plain)
      if expanded {
        Text(text)
          .font(.system(size: 12)).italic().foregroundStyle(DSHTheme.inkFaint)
          .textSelection(.enabled)
          .frame(maxWidth: 760, alignment: .leading)
          .padding(.leading, 17)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// Claude Code-style rows, no role captions: role is carried entirely by
// layout — user input is a right-aligned tinted bubble, assistant output is
// plain text on the canvas, system notes are dim small print. Labels like
// "你 / DSH / 系统" restated the same information on every row and made the
// transcript read like a chat log instead of a working session.
private struct MessageBubble: View {
  @EnvironmentObject var harness: HarnessController
  let message: HarnessController.Message
  var body: some View {
    switch message.role {
    case .user:
      HStack {
        Spacer(minLength: 180)
        VStack(alignment: .leading, spacing: 7) {
          Text(message.text)
            .textSelection(.enabled).font(.system(.body, design: .rounded)).foregroundStyle(DSHTheme.ink)
            .frame(maxWidth: 640, alignment: .leading)
          if let attachment = message.attachment { AttachmentPreview(ref: attachment) }
        }
        .padding(.horizontal, DSHSpace.s4).padding(.vertical, DSHSpace.s3)
        .dshCard(tint: DSHTheme.surfaceTint2, radius: DSHRadius.lg)
      }
    case .assistant:
      VStack(alignment: .leading, spacing: 7) {
        if message.text.isEmpty {
          Text("正在思考…").font(.system(.body, design: .rounded)).foregroundStyle(DSHTheme.inkFaint)
        } else {
          MarkdownText(text: message.text).frame(maxWidth: 760, alignment: .leading)
        }
        if let attachment = message.attachment { AttachmentPreview(ref: attachment) }
        if let messageId = message.hostMessageId { FeedbackBar(messageId: messageId) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .system:
      HStack(spacing: 7) {
        Image(systemName: "info.circle").font(.system(size: 11))
        Text(message.text).textSelection(.enabled).font(.system(size: 12, design: .rounded))
      }
      .foregroundStyle(DSHTheme.inkFaint)
      .frame(maxWidth: .infinity, alignment: .leading)
    case .tool:
      ToolCallRow(message: message)
    }
  }
}

/// Claude Code-style inline tool row: a state dot plus `Name(argument)` in
/// monospace, with a dim `⎿ result` line once the result lands. The heavy
/// rendering (diffs, file lines, search matches) stays in the details panel —
/// clicking the row opens it via the existing toolDetail() path.
private struct ToolCallRow: View {
  @EnvironmentObject var harness: HarnessController
  let message: HarnessController.Message
  private var activity: HarnessController.ToolActivity? {
    guard let id = message.toolCallId else { return nil }
    return harness.activeTools.last { $0.callId == id }
  }
  var body: some View {
    Button(action: { if let activity { harness.toolDetail(activity) } }) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Circle().fill(dotColor).frame(width: 7, height: 7)
          Text(headline).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(DSHTheme.ink).lineLimit(1)
        }
        if let detail {
          HStack(alignment: .top, spacing: 6) {
            Text("⎿").font(.system(size: 11, design: .monospaced))
            Text(detail).font(.system(size: 11.5, design: .monospaced)).lineLimit(2).multilineTextAlignment(.leading)
          }
          .foregroundStyle(DSHTheme.inkFaint)
          .padding(.leading, 13)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
  /// `Name(argument)` — the argument is the presentation's own title when the
  /// adapter supplied one (command line, file path, search query), else bare name.
  private var headline: String {
    let name = activity?.name ?? message.text
    let argument = activity?.presentation?.title ?? activity?.presentation?.path
    if let argument, !argument.isEmpty, argument != name { return "\(name)(\(argument))" }
    return name
  }
  /// One dim line under the headline: first non-empty output line while the
  /// tool has produced one, else the running placeholder.
  private var detail: String? {
    guard let activity else { return nil }
    if activity.state == .running { return "运行中…" }
    let firstLine = activity.output.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
    if let firstLine, !firstLine.isEmpty, firstLine != "工具已完成" { return firstLine }
    if activity.state == .failed { return activity.summary }
    return nil
  }
  private var dotColor: Color {
    switch activity?.state {
    case .running: DSHTheme.warm
    case .failed: Color.red.opacity(0.75)
    default: DSHTheme.accent
    }
  }
}

/// Per-message rating strip backed by the Typert messageFeedback service.
private struct FeedbackBar: View {
  @EnvironmentObject var harness: HarnessController
  let messageId: String
  var body: some View {
    let current = harness.messageFeedback[messageId]?.rating
    HStack(spacing: 6) {
      Button(action: { harness.setFeedback(messageId: messageId, rating: current == "positive" ? nil : "positive") }) {
        Image(systemName: current == "positive" ? "hand.thumbsup.fill" : "hand.thumbsup")
      }.help("有帮助")
      Button(action: { harness.setFeedback(messageId: messageId, rating: current == "negative" ? nil : "negative") }) {
        Image(systemName: current == "negative" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
      }.help("没帮助")
    }
    .buttonStyle(.dshGhost).font(.caption)
    .foregroundStyle(current == nil ? DSHTheme.inkFaint : DSHTheme.accent)
  }
}

/// Slash-command autocomplete, shown above the input row while the draft
/// starts with "/" — backed by the Typert `commands/list` roster.
private struct CommandPaletteView: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    let query = String(harness.draft.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
    let matches = harness.hostCommands.filter { query.isEmpty || normalized($0.name).lowercased().contains(query) }.prefix(6)
    if !matches.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(matches)) { command in
          Button(action: { harness.draft = "\(normalized(command.name)) " }) {
            HStack(spacing: DSHSpace.s2) {
              Text(normalized(command.name)).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(DSHTheme.accent)
              Text(command.description).font(.caption2).foregroundStyle(DSHTheme.inkFaint).lineLimit(1)
              Spacer()
              if let hint = command.input?.hint { Text(hint).font(.caption2).foregroundStyle(DSHTheme.inkFaint) }
            }.padding(.vertical, 3).padding(.horizontal, DSHSpace.s2)
          }.buttonStyle(.plain)
        }
      }
      .padding(DSHSpace.s2)
      .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
    }
  }
  private func normalized(_ name: String) -> String { name.hasPrefix("/") ? name : "/" + name }
}

private struct Composer: View {
  @EnvironmentObject var harness: HarnessController
  @FocusState private var editorFocused: Bool
  var body: some View {
    if harness.isViewingReadOnlySubagent {
      HStack { Image(systemName: "lock.fill"); Text("只读：此子代理已结束，历史不可续写。返回上一级可继续操作。"); Spacer() }
        .font(.caption).foregroundStyle(DSHTheme.inkFaint).padding(DSHSpace.s5)
    } else {
    VStack(spacing: DSHSpace.s2) {
      HStack {
        if harness.hostPlanActive { Button("计划模式 ×", action: harness.exitPlanMode).buttonStyle(.dshSecondary) }
        if !harness.queueItems.isEmpty { DSHBadge(text: "已排队 \(harness.queueItems.count)", tone: .warm) }
        Spacer()
        Text(harness.status).font(.caption).foregroundStyle(harness.isRunning ? DSHTheme.warm : DSHTheme.inkFaint)
      }
      GoalBar()
      QueueDockView()
      if harness.draft.hasPrefix("/") { CommandPaletteView() }
      // Text field and every compose-time control (attachments, voice,
      // model picker, send/stop) share one bordered box, matching the
      // consolidated-composer redesign — see
      // .agents/notes/implemented/bug-fix/2026-08-17-composer-consolidation.md.
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        TextEditor(text: $harness.draft).font(.system(.body, design: .rounded)).scrollContentBackground(.hidden)
          .frame(minHeight: 54, maxHeight: 140)
          .focused($editorFocused)
          .overlay(alignment: .topLeading) {
            // Hidden while focused, not just while non-empty: IME marked text
            // (pinyin composition) never reaches the SwiftUI binding, so a
            // focused-empty placeholder would sit under the composition
            // underline text. Focus is the only reliable signal we have.
            if harness.draft.isEmpty && !editorFocused {
              // Insets must mirror TextEditor's own text origin (NSTextView:
              // textContainerInset 0, lineFragmentPadding 5) or the insertion
              // point and this placeholder sit visibly misaligned.
              Text(harness.hostPlanActive ? "描述任务以生成计划" : "描述你想要构建的内容")
                .font(.system(.body, design: .rounded)).foregroundStyle(DSHTheme.inkFaint)
                .padding(.leading, 5).allowsHitTesting(false)
            }
          }
        if let image = harness.draftImage {
          HStack(spacing: 6) {
            Label(image.url.lastPathComponent, systemImage: "photo").font(.caption).foregroundStyle(DSHTheme.inkSoft).lineLimit(1)
            Button(action: { harness.draftImage = nil }) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.dshGhost)
            Spacer()
          }
        }
        HStack(spacing: DSHSpace.s3) {
          Menu { Button("进入计划模式", action: harness.enterPlanMode); Button("设定目标") { harness.draft = "/goal " }; Divider(); Button("重命名当前会话", action: harness.beginRenameCurrentSession); Button("创建会话分支", action: harness.forkCurrentSession); Button("归档当前会话", action: harness.archiveCurrentSession); Button("导出会话日志", action: harness.exportCurrentSessionLog); Button("查看归档会话") { harness.showArchivedSessions = true }; Divider(); Button("新会话", action: harness.newSession); Button("打开工作区", action: harness.openWorkspace) } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().foregroundStyle(DSHTheme.inkSoft).help("更多操作")
          Button(action: harness.pickImage) { Image(systemName: "paperclip") }.buttonStyle(.borderless).foregroundStyle(DSHTheme.inkSoft).help("添加图片")
          VoiceInputButton { text in harness.draft += (harness.draft.isEmpty ? "" : " ") + text; if harness.canSend { harness.send() } }
          ComposerModelMenu()
          Spacer()
          StatusStrip()
          if harness.isRunning {
            Button("停止", action: harness.stop).buttonStyle(.dshSecondary)
            Button("排队", action: harness.queueDraft).buttonStyle(.dshSecondary).disabled(harness.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          } else { Button("发送", action: harness.send).buttonStyle(.dshPrimary).disabled(!harness.canSend) }
        }
      }
      .padding(DSHSpace.s3)
      .dshCard(tint: DSHTheme.surface, radius: DSHRadius.lg)
    }.padding(DSHSpace.s5)
    }
  }
}

/// The composer-docked model/reasoning picker — the only in-app place a
/// model change actually reaches the Host (`selectCurrentModel` posts
/// `session.selectModel`). Options are read live from `harness.availableModels`
/// (`llm.models`'s groups, keyed by real provider id, e.g. "deepseek-official")
/// rather than a hardcoded relay/deepseek pair, so a tap always names a
/// provider id the catalog actually has.
private struct ComposerModelMenu: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    Menu {
      if harness.availableModels.isEmpty {
        Text("尚未读到 Host 模型目录")
        Button("刷新模型目录", action: harness.refreshModelConfiguration)
      } else {
        ForEach(harness.availableModels) { group in
          Menu(group.nativeDisplayName) {
            ForEach(group.models) { model in
              Button(action: { harness.selectCurrentModel(provider: group.id, model: model.id) }) {
                if harness.provider == group.id && harness.model == model.id { Label(model.name, systemImage: "checkmark") }
                else { Text(model.name) }
              }
            }
          }
        }
        // Effort rows come from the selected model's adapter-advertised
        // levels, mirroring the upstream web composer: a fixed off/high/max
        // list offered levels the adapter would reject outright
        // (hand-declared relay models advertise none at all). No metadata →
        // no effort submenu, matching "an adapter without reasoning metadata
        // leaves the Effort row absent" in the model-selection contract.
        if let reasoning = harness.currentModelEntry?.reasoning {
          Divider()
          Menu("推理强度") {
            ForEach(reasoning.efforts) { effort in
              Button(action: { harness.selectCurrentModel(provider: harness.provider, model: harness.model, reasoning: effort.id) }) {
                if harness.reasoningEffort == effort.id { Label(effort.name, systemImage: "checkmark") }
                else { Text(effort.name) }
              }
            }
          }
        }
      }
    } label: {
      Text(harness.currentModelLabel).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(DSHTheme.inkFaint)
    }
    .menuStyle(.borderlessButton).fixedSize()
  }
}

/// Compact live-session figures from the Host's projection pushes: context
/// occupancy vs window, cumulative token usage, and turn/step counts. Hidden
/// entirely once none of the three have data yet (fresh session).
private struct StatusStrip: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    if harness.contextPressure != nil || harness.tokenUsage != nil || (harness.sessionStats?.turns ?? 0) > 0 {
      HStack(spacing: DSHSpace.s3) {
        if let pressure = harness.contextPressure, let occupied = pressure.projectedTokens ?? pressure.pressureTokens {
          Text("上下文 \(Self.compact(occupied))\(pressure.contextWindow.map { "/\(Self.compact($0))" } ?? "")")
            .foregroundStyle(pressure.contextWindow.map { Double(occupied) > Double($0) * 0.8 } == true ? DSHTheme.coral : DSHTheme.inkFaint)
            .help("下一次请求的预计上下文占用 / 模型窗口")
        }
        if let usage = harness.tokenUsage {
          Text("↑\(Self.compact(usage.totalInputTokens)) ↓\(Self.compact(usage.outputTokens))")
            .foregroundStyle(DSHTheme.inkFaint)
            .help("会话累计 token：输入（含缓存读写）↑ / 输出 ↓")
        }
        if let stats = harness.sessionStats, stats.turns > 0 {
          Text("\(stats.turns) 轮 · \(stats.steps) 步")
            .foregroundStyle(DSHTheme.inkFaint)
            .help("整个会话的回合与步骤计数（LLM \(Int(stats.llmMs / 1000))s · 工具 \(Int(stats.toolMs / 1000))s）")
        }
      }
      .font(.system(size: 10.5, design: .monospaced))
    }
  }

  private static func compact(_ value: Int) -> String {
    value >= 10_000 ? String(format: "%.0fk", Double(value) / 1000) : value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : "\(value)"
  }
}

private struct DetailsPanel: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      HStack { Text("详情").font(.system(size: 13, weight: .semibold)).foregroundStyle(DSHTheme.ink); Spacer(); Button(action: { harness.showDetails = false }) { Image(systemName: "xmark") }.buttonStyle(.dshGhost) }
      NativeDashboard()
      if let tool = harness.selectedTool {
        VStack(alignment: .leading, spacing: DSHSpace.s2) {
          Label(tool.name, systemImage: icon(for: tool.state)).foregroundStyle(DSHTheme.ink)
          Text(tool.summary).font(.caption).foregroundStyle(DSHTheme.inkFaint)
          ScrollView { NativeToolPresentationView(tool: tool).frame(maxWidth: .infinity, alignment: .leading) }
        }
      } else {
        Spacer()
        VStack(spacing: DSHSpace.s2) {
          Image(systemName: "sidebar.right").font(.title2).foregroundStyle(DSHTheme.inkFaint)
          Text("点击消息流中的工具行查看详情").multilineTextAlignment(.center).foregroundStyle(DSHTheme.inkFaint)
        }
        Spacer()
      }
    }.padding(DSHSpace.s4)
  }
  private func icon(for state: HarnessController.ToolActivity.State) -> String { switch state { case .running: "hourglass"; case .succeeded: "checkmark.circle"; case .failed: "exclamationmark.triangle" } }
}

private struct SessionSearchView: View {
  @EnvironmentObject var harness: HarnessController
  @State private var query = ""
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      Text("搜索会话").font(.system(size: 18, weight: .semibold)).foregroundStyle(DSHTheme.ink)
      TextField("搜索会话…", text: $query)
        .dshField(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
        .onChange(of: query) { _, text in harness.searchSessions(text) }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: DSHSpace.s2) {
          ForEach(harness.searchResults) { result in
            Button(action: { harness.openHostSessionID(result.sessionId); harness.showSessionSearch = false }) {
              VStack(alignment: .leading, spacing: 4) {
                Text(harness.hostSessions.first(where: { $0.sessionId == result.sessionId })?.title ?? result.sessionId).foregroundStyle(DSHTheme.ink)
                Text(result.snippet).font(.caption).foregroundStyle(DSHTheme.inkFaint).lineLimit(2)
              }.padding(DSHSpace.s3).frame(maxWidth: .infinity, alignment: .leading).dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
            }.buttonStyle(.plain)
          }
          if harness.searchHasMore { Text("结果较多，请缩小搜索范围。").font(.caption).foregroundStyle(DSHTheme.inkFaint) }
        }
      }
      HStack { Spacer(); Button("关闭") { harness.showSessionSearch = false }.buttonStyle(.dshSecondary) }
    }.padding(DSHSpace.s5).frame(width: 520, height: 520).background(DSHTheme.surface)
  }
}
