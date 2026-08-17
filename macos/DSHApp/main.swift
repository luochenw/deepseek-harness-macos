import SwiftUI
import AppKit
import Darwin

private let appName = "DeepSeek Harness"
private let workspaceKey = "dsh.workspace"
private let modelKey = "dsh.model"
private let providerKey = "dsh.provider"
private let presetKey = "dsh.preset"
private let permissionKey = "dsh.permission"
private let defaultProvider = "relay"
private let defaultModel = "gpt-5.6-terra"

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
  enum PermissionMode: String, CaseIterable, Identifiable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case fullAccess = "danger-full-access"
    var id: String { rawValue }
    var label: String {
      switch self { case .readOnly: "只读"; case .workspaceWrite: "工作区写入"; case .fullAccess: "完全访问" }
    }
  }

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
    enum Role { case user, assistant, system }
    let id = UUID()
    let role: Role
    var text: String
    var timestamp = Date()
    var attachment: DSHAttachmentRef?
    var reasoning: String?
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
  @Published private(set) var isRunning = false
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
  @Published var renameDraft = ""
  @Published var searchResults: [DSHSessionSearchItem] = []
  @Published var searchHasMore = false
  @Published var showDetails = true
  @Published var selectedTool: ToolActivity?
  @Published var apiKey = ""
  @Published var baseURL = ""
  @Published var provider = defaultProvider
  @Published var model = defaultModel
  @Published var reasoningEffort = "high"
  @Published var preset: Preset = .code
  @Published var permission: PermissionMode = .workspaceWrite
  @Published var planMode = false
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
  @Published var queuedPrompts: [String] = []
  @Published var queueItems: [DSHQueueItem] = []
  @Published var pendingApproval: PendingApproval?
  @Published var pendingQuestion: PendingQuestion?
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
  private var task: Process?
  private var outputBuffer = ""
  private var errorBuffer = ""
  private var forceStopDeadline: DispatchWorkItem?
  private var runningSessionID: UUID?

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
    apiKey = ProcessInfo.processInfo.environment["RELAY_API_KEY"] ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? ""
    baseURL = ProcessInfo.processInfo.environment["DEEPSEEK_BASE_URL"] ?? ""
    provider = UserDefaults.standard.string(forKey: providerKey) ?? defaultProvider
    model = UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
    preset = Preset(rawValue: UserDefaults.standard.string(forKey: presetKey) ?? Preset.code.rawValue) ?? .code
    permission = PermissionMode(rawValue: UserDefaults.standard.string(forKey: permissionKey) ?? PermissionMode.workspaceWrite.rawValue) ?? .workspaceWrite
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
    if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
    return FileManager.default.fileExists(atPath: dshHome.appendingPathComponent(".credentials.yaml").path)
  }
  /// A one-shot subagent's transcript is a frozen, read-only overlay — see
  /// the subagent-transcript-redesign Agent Note.
  var isViewingReadOnlySubagent: Bool { subagentTranscript != nil && activeSubagentAddress?.mode != "continuable" }
  var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && workspace != nil && hasCredential && !isRunning && !isViewingReadOnlySubagent }

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
  /// when the app home has no credentials yet. This makes the bundled Host work
  /// with the same Relay/DeepSeek providers the user already configured, so a
  /// fresh install can send prompts without re-entering keys.
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
      let profile = appHome.appendingPathComponent("profiles/headless", isDirectory: true)
      try fm.createDirectory(at: profile, withIntermediateDirectories: true)
      let patch = profile.appendingPathComponent("cordis.patch.yml")
      if !fm.fileExists(atPath: patch.path) {
        let content = "- id: agent-default-model\n  config:\n    provider: relay\n    model: ark/deepseek-v4-flash\n"
        try content.write(to: patch, atomically: true, encoding: .utf8)
      }
      status = "已导入 ~/.dsh 的 Relay 配置"
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
    case "session/queue":
      if let items = frame["items"] as? [[String: Any]] {
        queueItems = items.compactMap { item in
          guard let id = item["id"] as? String else { return nil }
          let message = item["message"] as? [String: Any]
          let content = message?["content"] as? [[String: Any]]
          let text = content?.compactMap { $0["text"] as? String }.joined() ?? ""
          return DSHQueueItem(id: id, placement: item["placement"] as? String ?? "queued", text: text)
        }
        queuedPrompts = queueItems.map(\.text)
      }
    case "session/jobs":
      if let jobs = frame["jobs"] as? [[String: Any]] { activeTools = jobs.map { ToolActivity(callId: $0["id"] as? String ?? UUID().uuidString, name: $0["label"] as? String ?? "后台任务", summary: $0["detail"] as? String ?? $0["status"] as? String ?? "", state: ($0["status"] as? String) == "failed" ? .failed : .running, output: "", presentation: nil) } }
    case "approval/requested":
      guard let rpcId = frame["_rpcId"] as? String, let sessionId = frame["sessionId"] as? String, let approvalId = frame["approvalId"] as? String else { return }
      let toolName = frame["toolName"] as? String ?? "工具"
      pendingApproval = PendingApproval(id: approvalId, rpcId: rpcId, sessionId: sessionId, toolName: toolName, reason: frame["reason"] as? String)
      nativeAlerts.notifyApprovalNeeded(toolName: toolName)
    case "question/requested":
      guard let rpcId = frame["_rpcId"] as? String, let sessionId = frame["sessionId"] as? String, let questions = frame["questions"] as? [[String: Any]] else { return }
      let items = questions.compactMap { value -> PendingQuestion.Item? in
        guard let id = value["id"] as? String, let question = value["question"] as? String else { return nil }
        let options = (value["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        return PendingQuestion.Item(id: id, question: question, options: options)
      }
      pendingQuestion = PendingQuestion(id: rpcId, rpcId: rpcId, sessionId: sessionId, items: items)
      nativeAlerts.notifyQuestionNeeded()
    default:
      break
    }
  }

  private func applyLiveEvent(_ event: [String: Any], view: [String: Any]? = nil) {
    guard let kind = event["type"] as? String, let data = event["data"] as? [String: Any], let index = selectedSessionIndex else { return }
    switch kind {
    case "assistant/chunk":
      if let chunk = data["chunk"] as? [String: Any], chunk["type"] as? String == "text-delta", let delta = chunk["textDelta"] as? String {
        if let last = sessions[index].messages.lastIndex(where: { $0.role == .assistant }) { sessions[index].messages[last].text += delta }
        else { sessions[index].messages.append(Message(role: .assistant, text: delta)) }
      }
    case "assistant/message":
      if let text = liveMessageText(data["message"]) { sessions[index].messages.append(Message(role: .assistant, text: text)) }
    case "user/message":
      if let text = liveMessageText(data["message"]) { sessions[index].messages.append(Message(role: .user, text: text)) }
    case "tool/call":
      let tool = ToolActivity(callId: data["callId"] as? String ?? UUID().uuidString, name: data["name"] as? String ?? "工具", summary: "正在运行", state: .running, output: "", presentation: ToolPresentation.from(view?["view"] as? [String: Any]))
      activeTools.append(tool)
      selectedTool = tool
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
        if let last = subagentTranscript?.messages.lastIndex(where: { $0.role == .assistant }) { subagentTranscript?.messages[last].text += delta }
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

  func saveCredential() {
    let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let ref = provider == "relay" ? "RELAY_API_KEY" : "DEEPSEEK_API_KEY"
    guard let hostClient, !value.isEmpty else { return }
    Task {
      do { try await hostClient.setCredential(ref: ref, value: value); await MainActor.run { self.apiKey = ""; self.status = "凭据已通过 DSH Host 保存"; self.refreshModelConfiguration() } }
      catch { await MainActor.run { self.status = "保存凭据失败：\(error.localizedDescription)" } }
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
        async let credentials = hostClient.credentials(refs: ["RELAY_API_KEY", "DEEPSEEK_API_KEY"])
        async let providers = hostClient.providers()
        let (nextModels, nextCredentials, nextProviders) = try await (models, credentials, providers)
        await MainActor.run { self.availableModels = nextModels; self.credentialStates = nextCredentials; self.configurableProviders = nextProviders }
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
        async let workspaces = hostClient.workspaces()
        let (nextSessions, nextWorkspaces) = try await (sessions, workspaces)
        await MainActor.run {
          self.hostSessions = nextSessions
          self.hostWorkspaces = nextWorkspaces
          self.hostStatus = "Host 已同步 \(nextSessions.count) 个会话 / \(nextWorkspaces.count) 个工作区"
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
    guard let hostClient else { return }
    let cwd = workspace?.path
    let presetId = preset == .creator ? "cordis" : preset.rawValue
    Task {
      do {
        let created = try await hostClient.createSession(cwd: cwd, agentPreset: presetId)
        await MainActor.run {
          self.hostCurrentSessionID = created.sessionId
          if let index = self.selectedSessionIndex {
            self.sessions[index].messages = [Message(role: .system, text: "已连接到持久 DSH 会话。")]}
          self.refreshHostSnapshots()
        }
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
    status = summary.running ? "持久会话正在运行" : "正在载入持久会话"
    loadHistory(sessionId: summary.sessionId, localSessionID: local.id)
    loadSubagents(parentSessionId: summary.sessionId)
    refreshSessionModels()
    loadSkills(sessionId: summary.sessionId)
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
        if let text = textFromMessage(data["message"]) { result.append(Message(role: .assistant, text: text, timestamp: Date(timeIntervalSince1970: event.time / 1000), attachment: attachmentFromMessage(data["message"]), reasoning: reasoningFromMessage(data["message"]))) }
      case "tool/call":
        let name = data["name"]?.string ?? "tool"
        let id = data["callId"]?.string ?? "\(event.seq)"
        tools[id] = ToolActivity(callId: id, name: name, summary: "工具调用", state: .running, output: "", presentation: historyPresentation(entry.view))
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
    guard workspace != nil, hasCredential, !isRunning, let workspace, let sessionIndex = selectedSessionIndex else { return }
    guard persistRuntimeConfiguration() else { return }

    if let hostClient, let hostSessionID = hostCurrentSessionID {
      draft = ""
      draftImage = nil
      let preview = image == nil ? text : "\(text)\n[图片附件：\(image!.url.lastPathComponent)]"
      sessions[sessionIndex].messages.append(Message(role: .user, text: preview))
      sessions[sessionIndex].messages.append(Message(role: .assistant, text: "正在由持久 DSH Host 处理…"))
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
      return
    }

    draft = ""
    sessions[sessionIndex].messages.append(Message(role: .user, text: text))
    sessions[sessionIndex].updatedAt = Date()
    if sessions[sessionIndex].title == "新会话" { sessions[sessionIndex].title = String(text.prefix(42)) }
    sessions[sessionIndex].messages.append(Message(role: .assistant, text: ""))
    sessions[sessionIndex].isRunning = true
    isRunning = true
    runningSessionID = sessions[sessionIndex].id
    status = "\(provider) / \(model) 正在工作"
    activeTools = [ToolActivity(callId: "headless-runtime", name: "DSH runtime", summary: "在 \(workspace.lastPathComponent) 中执行任务", state: .running, output: "", presentation: nil)]
    selectedTool = activeTools.first
    outputBuffer = ""
    errorBuffer = ""

    let process = Process()
    process.executableURL = bundledNode
    process.arguments = [bundledDSH.path, "--profile", "headless", text]
    process.currentDirectoryURL = workspace
    var environment = ProcessInfo.processInfo.environment
    try? FileManager.default.createDirectory(at: dshHome, withIntermediateDirectories: true)
    environment["HOME"] = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    environment["DSH_HOME"] = dshHome.path
    environment["PATH"] = "\(runtime.path):/usr/bin:/bin:/usr/sbin:/sbin"
    environment["DSH_PERMISSION_MODE"] = permission.rawValue
    if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      environment[provider == "relay" ? "RELAY_API_KEY" : "DEEPSEEK_API_KEY"] = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { environment["DEEPSEEK_BASE_URL"] = baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    environment["DSH_CWD"] = workspace.path
    process.environment = environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    task = process
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      DispatchQueue.main.async { self?.appendAssistant(String(decoding: data, as: UTF8.self)) }
    }
    stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      DispatchQueue.main.async { self?.errorBuffer = String((self?.errorBuffer ?? "" + String(decoding: data, as: UTF8.self)).suffix(12000)) }
    }
    process.terminationHandler = { [weak self] ended in
      DispatchQueue.main.async { self?.finish(process: ended, stdout: stdout, stderr: stderr) }
    }
    do { try process.run() } catch {
      isRunning = false
      sessions[sessionIndex].isRunning = false
      task = nil
      appendSystem("无法启动内置 DSH：\(error.localizedDescription)")
      status = "启动失败"
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

  func queueDraft() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    queuedPrompts.append(text)
    draft = ""
  }

  func stop() {
    if let hostClient, let hostSessionID = hostCurrentSessionID {
      Task {
        do { try await hostClient.cancel(sessionId: hostSessionID); await MainActor.run { self.status = "已请求取消持久会话" } }
        catch { await MainActor.run { self.status = "取消失败：\(error.localizedDescription)" } }
      }
      return
    }
    stopRuntime(reason: "正在停止 DSH")
  }
  func stopForTermination() { stopRuntime(reason: "正在关闭 DSH") }

  private func stopRuntime(reason: String) {
    guard let task, task.isRunning else { return }
    status = reason
    task.terminate()
    let pid = task.processIdentifier
    let deadline = DispatchWorkItem { if task.isRunning { _ = kill(pid, SIGKILL) } }
    forceStopDeadline?.cancel()
    forceStopDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: deadline)
  }

  func togglePlanMode() {
    planMode.toggle()
    appendSystem(planMode ? "已进入计划模式。请描述任务以生成计划。" : "已退出计划模式。")
  }


  func selectCurrentModel(provider: String, model: String, reasoning: String? = nil) {
    self.provider = provider
    self.model = model
    if let reasoning { self.reasoningEffort = reasoning }
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task {
      do {
        try await hostClient.selectModel(sessionId: sessionId, provider: provider, model: model, reasoningEffort: reasoning ?? self.reasoningEffort)
        await MainActor.run { self.status = "已切换到 \(provider) / \(model)" }
      } catch { await MainActor.run { self.appendSystem("模型切换失败：\(error.localizedDescription)") } }
    }
  }

  func setPreset(_ next: Preset) {
    preset = next
    UserDefaults.standard.set(next.rawValue, forKey: presetKey)
    appendSystem("新会话将使用\(next.label)。当前运行中的会话不受影响。")
  }

  func setPermission(_ next: PermissionMode) {
    permission = next
    UserDefaults.standard.set(next.rawValue, forKey: permissionKey)
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


  func answerApproval(_ allowed: Bool) {
    guard let pending = pendingApproval, let hostClient else { return }
    pendingApproval = nil
    Task {
      do {
        try await hostClient.respond(rpcId: pending.rpcId, value: DSHApprovalAnswer(sessionId: pending.sessionId, approvalId: pending.id, outcome: allowed ? "allowed-once" : "rejected"))
        await MainActor.run { self.appendSystem(allowed ? "已允许 \(pending.toolName) 执行一次。" : "已拒绝 \(pending.toolName)。") }
      } catch { await MainActor.run { self.appendSystem("审批响应失败：\(error.localizedDescription)") } }
    }
  }

  func answerQuestionBatch(_ question: PendingQuestion, selections: [String: String], custom: [String: String]) {
    guard let hostClient else { return }
    pendingQuestion = nil
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

  private func persistRuntimeConfiguration() -> Bool {
    let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard selectedModel.range(of: "^[A-Za-z0-9._:/-]+$", options: .regularExpression) != nil else { appendSystem("模型 ID 无效。"); return false }
    let profile = dshHome.appendingPathComponent("profiles/headless", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
      let selectedProvider = provider == "relay" ? "relay" : "deepseek-official"
      let content = "- id: agent-default-model\n  config:\n    provider: \(selectedProvider)\n    model: \(selectedModel)\n"
      try content.write(to: profile.appendingPathComponent("cordis.patch.yml"), atomically: true, encoding: .utf8)
      UserDefaults.standard.set(provider, forKey: providerKey)
      UserDefaults.standard.set(selectedModel, forKey: modelKey)
      return true
    } catch { appendSystem("无法保存运行配置：\(error.localizedDescription)"); return false }
  }

  private func appendAssistant(_ text: String) {
    outputBuffer += text
    guard let index = sessions.firstIndex(where: { $0.id == runningSessionID }), let message = sessions[index].messages.lastIndex(where: { $0.role == .assistant }) else { return }
    sessions[index].messages[message].text = outputBuffer
    if !activeTools.isEmpty { activeTools[0].output = outputBuffer; selectedTool = activeTools[0] }
  }

  private func finish(process: Process, stdout: Pipe, stderr: Pipe) {
    forceStopDeadline?.cancel()
    stdout.fileHandleForReading.readabilityHandler = nil
    stderr.fileHandleForReading.readabilityHandler = nil
    guard task === process else { return }
    task = nil
    isRunning = false
    if let index = sessions.firstIndex(where: { $0.id == runningSessionID }) {
      sessions[index].isRunning = false
      sessions[index].updatedAt = Date()
      if outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        sessions[index].messages.append(Message(role: .assistant, text: process.terminationStatus == 0 ? "DSH 已完成，但没有文本输出。" : "DSH 失败：\(errorBuffer.isEmpty ? "无诊断输出" : errorBuffer)"))
      }
    }
    let ok = process.terminationStatus == 0
    if !activeTools.isEmpty { activeTools[0].state = ok ? .succeeded : .failed; activeTools[0].output = outputBuffer.isEmpty ? errorBuffer : outputBuffer; selectedTool = activeTools[0] }
    status = ok ? "已完成" : "DSH 退出：\(process.terminationStatus)"
    runningSessionID = nil
    if !queuedPrompts.isEmpty {
      draft = queuedPrompts.removeFirst()
      send()
    }
  }
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
      .background(DSHTheme.canvas)
      if harness.showDetails {
        DetailsPanel().frame(width: 330).background(DSHTheme.surfaceTint)
      }
    }
    .background(DSHTheme.canvas)
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

      WorkspaceManagerView()
      VStack(alignment: .leading, spacing: 6) {
        Button(action: { harness.showSettings = true }) { Label("设置", systemImage: "gearshape") }.buttonStyle(.dshGhost)
        HStack(spacing: 6) {
          DSHStatusDot(kind: harness.hostClient == nil ? .idle : .live, diameter: 6)
          Text(harness.hostStatus).font(.system(size: 10.5)).foregroundStyle(DSHTheme.inkFaint).lineLimit(2)
        }
        Text("本机运行 · \(harness.permission.label)").font(.system(size: 10.5)).foregroundStyle(DSHTheme.inkFaint)
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
          Text(date, style: .relative).font(.system(size: 10.5)).foregroundStyle(DSHTheme.inkFaint)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, DSHSpace.s2).padding(.vertical, 7)
      .background(isActive ? DSHTheme.sidebarSelected : .clear, in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
    }.buttonStyle(.plain)
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
      HeaderChip(icon: "lock.shield", label: harness.permission.label) {
        ForEach(HarnessController.PermissionMode.allCases) { p in Button(p.label) { harness.setPermission(p) } }
      }
      HeaderChip(icon: "brain", label: harness.model) {
        if let sessionModels = harness.currentSessionModels {
          if !sessionModels.routable { Text("当前会话没有可用模型路由") }
          ForEach(sessionModels.groups) { group in ForEach(group.models) { item in Button("\(group.name) / \(item.name)") { harness.selectCurrentModel(provider: group.id, model: item.id) } } }
        } else {
          Button("刷新会话模型") { harness.refreshSessionModels() }
          Button("Relay / GPT-5.6 Terra") { harness.selectCurrentModel(provider: "relay", model: "gpt-5.6-terra") }
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
          }
        }.frame(maxWidth: .infinity).padding(DSHSpace.s6)
      }
      .onChange(of: harness.displayedSession?.messages) { _, messages in if let last = messages?.last { proxy.scrollTo(last.id, anchor: .bottom) } }
    }
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
/// answer bubble rather than nested inside it — see the ocean-design-system
/// Agent Note: "推理过程" and the answer are different kinds of content and
/// shouldn't share one card.
private struct ReasoningBlock: View {
  let text: String
  @State private var expanded = false
  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
            Text("推理过程").font(.system(size: 11, weight: .semibold))
          }.foregroundStyle(DSHTheme.inkFaint)
        }.buttonStyle(.plain)
        if expanded {
          Text(text).font(.system(.caption, design: .monospaced)).foregroundStyle(DSHTheme.inkSoft).textSelection(.enabled)
        }
      }
      .padding(.horizontal, DSHSpace.s3).padding(.vertical, DSHSpace.s2)
      .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
      .frame(maxWidth: 760, alignment: .leading)
      Spacer(minLength: 180)
    }
  }
}

private struct MessageBubble: View {
  @EnvironmentObject var harness: HarnessController
  let message: HarnessController.Message
  var body: some View {
    HStack {
      if message.role == .user { Spacer(minLength: 180) }
      VStack(alignment: .leading, spacing: 7) {
        Text(label).font(.system(size: 10.5, weight: .bold)).foregroundStyle(labelTint)
        Text(message.text.isEmpty ? "正在思考…" : message.text)
          .textSelection(.enabled).font(.system(.body, design: .rounded)).foregroundStyle(DSHTheme.ink)
          .frame(maxWidth: 760, alignment: .leading)
        if let attachment = message.attachment { AttachmentPreview(ref: attachment) }
      }
      .padding(DSHSpace.s4)
      .dshCard(tint: background, radius: DSHRadius.lg)
      if message.role != .user { Spacer(minLength: 180) }
    }
  }
  // Role is already carried by alignment (user right, assistant/system left)
  // and by the background depth step below — the label doesn't also need to
  // be in brand color on every single message, that reads as noisy over a
  // long conversation. Color here stays reserved for state, not decoration.
  private var label: String { switch message.role { case .user: "你"; case .assistant: "DSH"; case .system: "系统" } }
  private var labelTint: Color { DSHTheme.inkFaint }
  private var background: Color { message.role == .user ? DSHTheme.surfaceTint2 : message.role == .assistant ? DSHTheme.surface : DSHTheme.surfaceTint }
}

private struct Composer: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    if harness.isViewingReadOnlySubagent {
      HStack { Image(systemName: "lock.fill"); Text("只读：此子代理已结束，历史不可续写。返回上一级可继续操作。"); Spacer() }
        .font(.caption).foregroundStyle(DSHTheme.inkFaint).padding(DSHSpace.s5)
    } else {
    VStack(spacing: DSHSpace.s2) {
      HStack {
        if harness.planMode { Button("计划模式 ×", action: harness.togglePlanMode).buttonStyle(.dshSecondary) }
        if !harness.queuedPrompts.isEmpty { DSHBadge(text: "已排队 \(harness.queuedPrompts.count)", tone: .warm) }
        Spacer()
        Text(harness.status).font(.caption).foregroundStyle(harness.isRunning ? DSHTheme.warm : DSHTheme.inkFaint)
      }
      QueueDockView()
      HStack(alignment: .bottom, spacing: DSHSpace.s3) {
        TextEditor(text: $harness.draft).font(.system(.body, design: .rounded)).scrollContentBackground(.hidden)
          .frame(minHeight: 54, maxHeight: 140).padding(DSHSpace.s2).dshCard(tint: DSHTheme.surface, radius: DSHRadius.lg)
        if harness.isRunning {
          VStack(spacing: 7) {
            Button("停止", action: harness.stop).buttonStyle(.dshSecondary)
            Button("排队", action: harness.queueDraft).buttonStyle(.dshSecondary).disabled(harness.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        } else { Button("发送", action: harness.send).buttonStyle(.dshPrimary).disabled(!harness.canSend) }
      }
      HStack {
        Menu { Button("添加图片", action: harness.pickImage); Button("进入计划模式", action: harness.togglePlanMode); Button("重命名当前会话", action: harness.beginRenameCurrentSession); Button("创建会话分支", action: harness.forkCurrentSession); Button("归档当前会话", action: harness.archiveCurrentSession); Button("新会话", action: harness.newSession); Button("打开工作区", action: harness.openWorkspace) } label: { Image(systemName: "plus") }.foregroundStyle(DSHTheme.inkSoft)
        if let image = harness.draftImage { Label(image.url.lastPathComponent, systemImage: "photo").font(.caption).foregroundStyle(DSHTheme.inkSoft).lineLimit(1); Button(action: { harness.draftImage = nil }) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.dshGhost) }
        Text(harness.planMode ? "描述任务以生成计划" : "描述你想要构建的内容").font(.caption).foregroundStyle(DSHTheme.inkFaint)
        Spacer()
        Menu { Button("关闭推理") { harness.reasoningEffort = "off"; harness.selectCurrentModel(provider: harness.provider, model: harness.model, reasoning: "off") }; Button("高") { harness.reasoningEffort = "high"; harness.selectCurrentModel(provider: harness.provider, model: harness.model, reasoning: "high") }; Button("最大") { harness.reasoningEffort = "max"; harness.selectCurrentModel(provider: harness.provider, model: harness.model, reasoning: "max") } } label: { Text("\(harness.provider) / \(harness.model) · \(harness.reasoningEffort)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(DSHTheme.inkFaint) }
      }
    }.padding(DSHSpace.s5)
    }
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

private struct SettingsView: View {
  @EnvironmentObject var harness: HarnessController
  @State private var section = "通用"
  private let sections = ["通用", "模型", "提供方", "插件", "Agent 预设"]
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(sections, id: \.self) { s in
          Button(action: { section = s }) { Text(s).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(section == s ? DSHTheme.ink : DSHTheme.inkSoft)
            .padding(.horizontal, DSHSpace.s3).padding(.vertical, 8)
            .background(section == s ? DSHTheme.surfaceTint2 : .clear, in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
        }
        Spacer()
      }.padding(DSHSpace.s3).frame(width: 160).background(DSHTheme.surfaceTint)
      VStack(alignment: .leading, spacing: DSHSpace.s4) {
        Text(section).font(.system(size: 18, weight: .semibold)).foregroundStyle(DSHTheme.ink)
        settingsBody
        Spacer()
        HStack { Button("打开配置文件", action: harness.openHostSettingsDocument).buttonStyle(.dshSecondary); Spacer(); Button("关闭") { harness.showSettings = false }.buttonStyle(.dshPrimary).keyboardShortcut(.defaultAction) }
      }.padding(DSHSpace.s5).frame(width: 600, height: 480).background(DSHTheme.surface)
    }
  }
  @ViewBuilder private var settingsBody: some View { switch section { case "通用": Picker("默认 Agent preset", selection: $harness.preset) { ForEach(HarnessController.Preset.allCases) { Text($0.label).tag($0) } }.onChange(of: harness.preset) { _, v in harness.setPreset(v) }; Picker("默认权限", selection: $harness.permission) { ForEach(HarnessController.PermissionMode.allCases) { Text($0.label).tag($0) } }.onChange(of: harness.permission) { _, v in harness.setPermission(v) }; Text("当前会话保持原有 preset；新会话使用新的默认配置。").font(.caption).foregroundStyle(DSHTheme.inkFaint)
  case "模型": Picker("提供方", selection: $harness.provider) { Text("Relay（本机）").tag("relay"); Text("DeepSeek 官方").tag("deepseek") }.pickerStyle(.segmented); Picker("模型", selection: $harness.model) { ForEach(harness.availableModels) { group in ForEach(group.models) { model in Text("\(group.name) / \(model.name)").tag(model.id) } }; if harness.availableModels.isEmpty { Text("GPT-5.6 Terra").tag("gpt-5.6-terra") } }; Button("刷新 Host 模型目录", action: harness.refreshModelConfiguration).buttonStyle(.dshSecondary); SecureField(harness.provider == "relay" ? "Relay API Key（写入 DSH Host）" : "DeepSeek API Key（写入 DSH Host）", text: $harness.apiKey).dshField(); Button("保存凭据", action: harness.saveCredential).buttonStyle(.dshSecondary).disabled(harness.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); TextField("可选 API Base URL", text: $harness.baseURL).dshField(); Text(harness.hasCredential ? "凭据已可用" : "请提供 API Key").font(.caption).foregroundStyle(harness.hasCredential ? DSHTheme.accent : DSHTheme.warm)
  case "提供方": Button("刷新提供方配置", action: harness.refreshProviderConfiguration).buttonStyle(.dshSecondary); if let settings = harness.settingsDescription, let pi = settings.namespaces.first(where: { $0.ns == "llm-pi-ai" }) { Text(settings.writable ? "配置可写 · revision \(pi.revision)" : "配置只读").font(.caption).foregroundStyle(settings.writable ? DSHTheme.accent : DSHTheme.warm); ForEach(harness.configurableProviders.filter { $0.settingsNs == pi.ns }) { provider in HStack { Text(provider.displayName).foregroundStyle(DSHTheme.ink); Spacer(); Button("编辑") { harness.openProviderAuthoring(provider) }.buttonStyle(.dshSecondary).disabled(!settings.writable) } }; Button("添加自定义提供方") { harness.openProviderAuthoring() }.buttonStyle(.dshPrimary).disabled(!settings.writable) } else { Text("llm-pi-ai 未由当前 Host 提供。").foregroundStyle(DSHTheme.inkFaint) }
  case "插件": Text("已安装插件由内置 DSH runtime 管理。").foregroundStyle(DSHTheme.inkFaint); Button("刷新真实 Host 设置", action: harness.refreshSettings).buttonStyle(.dshSecondary); if let settings = harness.settingsDescription { Text(settings.writable ? "配置可写" : "配置只读").font(.caption).foregroundStyle(settings.writable ? DSHTheme.accent : DSHTheme.warm); ForEach(settings.namespaces) { ns in HStack { Label("\(ns.ns) · \(ns.applies)", systemImage: "puzzlepiece").foregroundStyle(DSHTheme.ink); Spacer(); Button("编辑") { harness.openSettingsEditor(ns: ns) }.buttonStyle(.dshSecondary).disabled(!settings.writable) } }; Text("凭据").font(.system(size: 13, weight: .semibold)).foregroundStyle(DSHTheme.ink).padding(.top, DSHSpace.s2); ForEach(Array(Set(harness.configurableProviders.compactMap { provider in harness.providerCredentialReference(provider) } + ["DEEPSEEK_API_KEY"])).sorted(), id: \.self) { ref in HStack { Text(ref).font(.system(.body, design: .monospaced)).foregroundStyle(DSHTheme.ink); Spacer(); Text((harness.credentialStates[ref]?.configured ?? false) ? "已配置" : "未配置").font(.caption).foregroundStyle((harness.credentialStates[ref]?.configured ?? false) ? DSHTheme.accent : DSHTheme.warm) } }; Text("在命名空间编辑器里可写入或清除 API Key。").font(.caption).foregroundStyle(DSHTheme.inkFaint) } else { Text("正在读取 Host 设置…").font(.caption).foregroundStyle(DSHTheme.inkFaint) }
  default: Text("选择新会话使用的 Agent 能力组合。").foregroundStyle(DSHTheme.inkFaint); ForEach(HarnessController.Preset.allCases) { p in Button(action: { harness.setPreset(p) }) { VStack(alignment: .leading) { Text(p.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(DSHTheme.ink); Text(p.detail).font(.caption).foregroundStyle(DSHTheme.inkFaint) } }.buttonStyle(.plain).padding(.vertical, 4) } } }
}
