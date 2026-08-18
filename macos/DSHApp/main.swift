import SwiftUI
import AppKit
import Darwin

private let appName = "DeepSeek Harness"
let workspaceKey = "dsh.workspace"
let modelKey = "dsh.model"
let providerKey = "dsh.provider"
let reasoningEffortKey = "dsh.reasoningEffort"
let presetKey = "dsh.preset"

@main
struct DSHNativeApp: App {
  @StateObject private var controller = HarnessController()

  var body: some Scene {
    WindowGroup(appName) {
      ContentView()
        .environmentObject(controller)
        .frame(minWidth: 1180, minHeight: 760)
        .onAppear { FloatingBubbleManager.shared.attach(controller) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
          controller.stopForTermination()
        }
    }
    // Custom chrome: the in-app header (ConversationHeader + sidebar top) IS
    // the top of the page; the native title bar only duplicated the app name.
    // Traffic lights float over the sidebar's padded top row.
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(after: .newItem) {
        Button("新会话") { controller.newSession() }.keyboardShortcut("n", modifiers: .command)
        Button("选择工作区…") { controller.chooseWorkspace() }.keyboardShortcut("w", modifiers: .command)
      }
      CommandGroup(after: .toolbar) {
        Button("搜索会话") { controller.showSessionSearch = true }.keyboardShortcut("f", modifiers: [.command, .shift])
        Button("打开工作区") { controller.openWorkspace() }.keyboardShortcut("o", modifiers: .command)
        Button("显示/隐藏悬浮圈") { FloatingBubbleManager.shared.toggle() }.keyboardShortcut("y", modifiers: [.command, .option])
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
    /// True for `source: {kind:"plugin", plugin:"session-relay"}` messages
    /// (dsh-tool-session-relay) — the one non-"user" source kind admitted
    /// past the injected-context filter below, so the transcript can show
    /// who a cross-session message came from without text-sniffing the
    /// plugin's envelope wording.
    var isRelayMessage = false
  }

  struct Session: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var workspaceName: String
    var updatedAt: Date
    var messages: [Message]
    var isRunning = false
    var hasUnread = false
    /// The backing persistent Host session, once known — the durable join
    /// key for event routing and row reuse (title matching is only the
    /// fallback for rows created before the id existed).
    var hostSessionId: String?
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

  @Published var sessions: [Session] = []
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
  /// `/model` 的原生落点：composer 模型选择 popover（SwiftUI Menu 无法编程打开）。
  @Published var showModelPicker = false
  @Published var isRunning = false {
    didSet { nativeAlerts.setRunning(isRunning) }
  }
  @Published var status = "准备就绪"
  @Published var workspace: URL?
  @Published var showSettingsEditor = false
  @Published var selectedSettingsNamespace: DSHSettingsNamespace?
  @Published var showProviderAuthoring = false
  @Published var selectedProviderForAuthoring: DSHConfigurableProvider?

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
  /// Preset chosen while no Host session exists yet (lazy creation);
  /// consumed by attachHostSessionToCurrentPlaceholder.
  @Published var pendingHostPresetID: String?
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
  @Published var hostCurrentSessionID: String?
  /// True while the lazy first-send path is creating the session backing the
  /// default page's first message — gates duplicate sends until it resolves.
  var isCreatingFirstSession = false
  let attachmentStore = DSHAttachmentStore()
  // Internal, not private: the voice-dispatch extension
  // (DSHVoiceDispatch.swift) posts completion/approval notifications.
  let nativeAlerts = NativeAlerts()
  /// Wake-dispatched background sessions: sessionId → short task label.
  /// Their mux events are intercepted for completion notification instead
  /// of being dropped with other non-current sessions.
  @Published var voiceTaskSessions: [String: String] = [:]
  /// 最近一次语音派发的会话——悬浮圈点击直接进入这条对话（进入后清空，
  /// 恢复悬浮圈"只回主窗口"的默认行为）。
  @Published var pendingVoiceTaskFocusID: String?
  var hostClientForAttachments: DSHHostClient? { hostClient }

  private(set) var hostRuntime: DSHHostRuntime?
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
    // 启动不再自动建会话：停在默认页（空态 + 可输入的 composer），第一条
    // 消息发出时才懒创建 —— 见 lazy-first-session Agent Note。
    startPersistentHost()
  }

  deinit { muxEvents?.stop(); hostEvents?.stop(); hostRuntime?.stop() }

  var workspaceName: String { workspace?.lastPathComponent ?? "选择工作区" }
  var selectedSessionIndex: Int? { sessions.firstIndex { $0.id == selectedSessionID } }
  var selectedSession: Session? { selectedSessionIndex.map { sessions[$0] } }
  /// What the conversation pane actually shows: an open subagent transcript
  /// overlays the selected top-level session, never replaces it in `sessions`.
  var displayedSession: Session? { subagentTranscript ?? selectedSession }
  /// True while the shown conversation has no user/assistant content yet —
  /// drives where the workspace chips render (above the composer vs header).
  var isNewConversation: Bool {
    !(displayedSession?.messages.contains { $0.role == .user || $0.role == .assistant } ?? false)
  }
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

  struct WorkspaceSessionGroup: Identifiable {
    let workspace: DSHWorkspaceView?
    let sessions: [DSHSessionSummary]
    /// Directory-derived header for sessions whose cwd matches no registered
    /// workspace — grouping stays meaningful even when the registry shrinks.
    var fallbackTitle: String?
    var id: String { workspace?.workspaceId ?? "cwd:\(fallbackTitle ?? "其他")" }
    var title: String { workspace?.title ?? fallbackTitle ?? "其他" }
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
    // Orphans bucket by their own directory name instead of one flat "其他":
    // deleting registry entries must not make the sidebar's分类 disappear.
    let orphans = visible.filter { !claimed.contains($0.sessionId) }
    let orphanBuckets = Dictionary(grouping: orphans) { session in
      session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "其他"
    }
    for (folderName, members) in orphanBuckets.sorted(by: { ($0.value.first?.updatedAt ?? 0) > ($1.value.first?.updatedAt ?? 0) }) {
      groups.append(WorkspaceSessionGroup(
        workspace: nil,
        sessions: members.sorted { $0.updatedAt > $1.updatedAt },
        fallbackTitle: folderName
      ))
    }
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
        // No session auto-creation on connect: the app sits on the default
        // page until the first send lazily creates one (⌘N also just
        // returns to the default page — see the lazy-first-session note).
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
      // Turn boundaries route for EVERY session before the current-session
      // filter below: the sidebar's live dot reads `hostSessions[i].running`
      // and a background row's own flag/unread must move without the session
      // being displayed — sessions run concurrently on the Host and the UI
      // used to drop these frames wholesale.
      if let kind = event["type"] as? String, kind == "turn/start" || kind == "turn/end" {
        let running = kind == "turn/start"
        if let i = hostSessions.firstIndex(where: { $0.sessionId == sessionID }) { hostSessions[i].running = running }
        if sessionID != hostCurrentSessionID, let row = sessions.firstIndex(where: { $0.hostSessionId == sessionID }) {
          sessions[row].isRunning = running
          if !running {
            sessions[row].hasUnread = true
            sessions[row].updatedAt = Date()
          }
        }
      }
      if let address = activeSubagentAddress, sessionID == address.childSessionId {
        applyLiveSubagentEvent(event)
      } else if sessionID == hostCurrentSessionID {
        applyLiveEvent(event, view: frame["view"] as? [String: Any])
      } else if voiceTaskSessions[sessionID] != nil {
        handleVoiceTaskEvent(sessionID: sessionID, event: event)
      }
    case "session/projection":
      guard let sessionId = frame["sessionId"] as? String, sessionId == hostCurrentSessionID,
            let key = frame["key"] as? String, let value = frame["value"] else { return }
      applyProjection(key: key, value: value)
    case "session/queue":
      // Scope to the displayed session — with concurrent sessions, another
      // session's queue push must not overwrite this composer's dock.
      if let sid = frame["sessionId"] as? String, sid != hostCurrentSessionID { return }
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
      // 同 session/queue：mux 是全会话聚合流，后台会话（语音派发、fork、
      // 子代理）的 job 不能混进当前转录的工具行。activeTools 只被主转录
      // 消费——子代理转录只显示文本，不收 job，故不看 activeSubagentAddress。
      if let sid = frame["sessionId"] as? String, sid != hostCurrentSessionID { return }
      // 合并更新，绝不整表覆盖：覆盖会把转录里已完成的工具行全部换成
      // job 条目，且旧映射除 failed 外一律算 .running（包括 completed）
      // —— 这正是"run_code 都执行结束了还在动"的来源。
      if let jobs = frame["jobs"] as? [[String: Any]] {
        for job in jobs {
          guard let id = job["id"] as? String else { continue }
          let status = (job["status"] as? String ?? "running").lowercased()
          let state: ToolActivity.State =
            status == "failed" ? .failed :
            ["running", "pending", "in-progress", "in_progress"].contains(status) ? .running : .succeeded
          if let index = activeTools.lastIndex(where: { $0.callId == id }) {
            activeTools[index].state = state
            if let detail = job["detail"] as? String { activeTools[index].summary = detail }
          } else {
            activeTools.append(ToolActivity(
              callId: id, name: job["label"] as? String ?? "后台任务",
              summary: job["detail"] as? String ?? status, state: state,
              output: "", presentation: nil))
          }
        }
      }
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
      let payload = liveMessagePayload(data)
      if let text = liveMessageText(payload) {
        var message = Message(role: .assistant, text: text)
        message.hostMessageId = payload["id"] as? String
        // The chunk stream above may already have built this bubble — the
        // settled message replaces the accumulation instead of doubling it.
        if sessions[index].messages.last?.role == .assistant {
          message.reasoning = sessions[index].messages[sessions[index].messages.count - 1].reasoning
          sessions[index].messages[sessions[index].messages.count - 1] = message
        } else {
          sessions[index].messages.append(message)
        }
      }
    case "user/message":
      let payload = liveMessagePayload(data)
      // Injected user-role contexts never render — except the cross-session
      // relay plugin's own delivered messages, which are real conversation
      // content from another session's model, not machine plumbing. Real
      // typed input dedupes against the local echo send() already appended
      // (the outgoing first message may carry the workspace-context
      // appendix, hence prefix matching). Queue drains, slash fallbacks, and
      // other clients still land here.
      let relay = liveIsRelayMessage(payload)
      if liveSourceKind(payload) == nil || liveSourceKind(payload) == "user" || relay, let text = liveMessageText(payload).map(userDisplayText) {
        let lastUser = sessions[index].messages.last(where: { $0.role == .user })?.text
        if let lastUser, text == lastUser || text.hasPrefix(lastUser) {} else {
          sessions[index].messages.append(Message(role: .user, text: text, isRelayMessage: relay))
        }
      }
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
    case "turn/start":
      // The Host opens a fresh turn for every model round — including ones
      // no local send() initiated: a queued followup draining, a goal round
      // driver advancing, plan-mode confirmation. Arm the running flag from
      // the stream so those turns animate and offer the stop button; before
      // this, only send() ever set it, and a Host-initiated turn rendered
      // the settled (static) tail while streaming.
      isRunning = true
      sessions[index].isRunning = true
      runNotice = nil
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
      // 兜底：turn 已结束，转录里不该再有"运行中"的工具——没等到
      // tool/result 的（callId 对不上、事件丢失）一律落定为完成，防止
      // 状态点永远闪烁。仍在跑的真后台 job 会被下一帧 session/jobs
      // 快照重新标回 running，不受影响。
      for toolIndex in activeTools.indices where activeTools[toolIndex].state == .running {
        activeTools[toolIndex].state = .succeeded
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
        if subagentTranscript?.messages.last?.role == .assistant, let count = subagentTranscript?.messages.count { subagentTranscript?.messages[count - 1].text += delta }
        else { subagentTranscript?.messages.append(Message(role: .assistant, text: delta)) }
      }
    case "assistant/message":
      let payload = liveMessagePayload(data)
      if let text = liveMessageText(payload) {
        if subagentTranscript?.messages.last?.role == .assistant, let count = subagentTranscript?.messages.count {
          subagentTranscript?.messages[count - 1].text = text
        } else {
          subagentTranscript?.messages.append(Message(role: .assistant, text: text))
        }
      }
    case "user/message":
      let payload = liveMessagePayload(data)
      if liveSourceKind(payload) == nil || liveSourceKind(payload) == "user", let text = liveMessageText(payload) {
        subagentTranscript?.messages.append(Message(role: .user, text: text))
      }
    case "turn/start":
      subagentTranscript?.isRunning = true
    case "turn/end":
      subagentTranscript?.isRunning = false
    default:
      break
    }
  }

  /// Message-event payload: fields may sit directly on the event data
  /// (`{content, id, role, source}` — the session log's shape) or nest under
  /// `message`. The nested-only lookup silently dropped every flat user
  /// message, which is how typed input vanished from transcripts.
  private func liveMessagePayload(_ data: [String: Any]) -> [String: Any] {
    (data["message"] as? [String: Any]) ?? data
  }

  private func liveSourceKind(_ message: [String: Any]) -> String? {
    (message["source"] as? [String: Any])?["kind"] as? String
  }

  /// True for `source: {kind:"plugin", plugin:"session-relay"}` — the one
  /// non-"user" source kind admitted past the injected-context filter, since
  /// it carries real cross-session conversation content rather than model
  /// plumbing (agent-instructions, skill catalogs, snapshots stay filtered).
  private func liveIsRelayMessage(_ message: [String: Any]) -> Bool {
    liveSourceKind(message) == "plugin" && (message["source"] as? [String: Any])?["plugin"] as? String == "session-relay"
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
    // Lazy sessions: before the first message there is no Host session to
    // select on — remember the choice instead of silently dropping it (点了
    // 没反应 = "无法切换模式"), and apply it when the session is created.
    guard let hostClient, let sessionId = hostCurrentSessionID else {
      pendingHostPresetID = preset
      return
    }
    Task {
      do { try await hostClient.selectPreset(sessionId: sessionId, preset: preset); await MainActor.run { self.status = "已切换 Agent preset：\(preset)"; self.refreshHostSnapshots() } }
      catch { await MainActor.run { self.appendSystem("Preset 切换失败：\(error.localizedDescription)") } }
    }
  }

  /// Chip label for the preset control: the pending (not-yet-created-session)
  /// choice wins over the local default enum.
  var activePresetLabel: String {
    if let pending = pendingHostPresetID {
      return hostPresets.first(where: { $0.id == pending })?.name ?? pending
    }
    return preset.label
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

  var dshHome: URL {
    // DSH_APP_HOME 只影响本 App 的配置根；$HOME 骗不过
    // homeDirectoryForCurrentUser（passwd 解析），所以隔离实例（演示、
    // 截图、并行测试）需要一个显式出口。
    if let override = ProcessInfo.processInfo.environment["DSH_APP_HOME"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DeepSeek Harness/dsh", isDirectory: true)
  }
  private var resources: URL { Bundle.main.resourceURL! }
  private var runtime: URL { resources.appendingPathComponent("Runtime") }
  private var bundledNode: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/node") }
  private var bundledDSH: URL { runtime.appendingPathComponent("dsh/lib/bin.js") }

}
