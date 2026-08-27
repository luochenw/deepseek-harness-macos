import SwiftUI
import AppKit
import Darwin

private let appName = "DeepSeek Harness"
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
      switch self { case .standard: "标准模式"; case .code: "PTC 模式"; case .minimal: "极简模式"; case .creator: "创造模式" }
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
        guard let number = DSHToolPresentationNumber.integerValue(line["number"]), let text = line["text"] as? String else { return nil }
        return FileLine(number: number, text: text)
      }
      let files = (view["files"] as? [[String: Any]] ?? []).compactMap { file -> SearchFile? in
        guard let path = file["path"] as? String else { return nil }
        let matches = (file["matches"] as? [[String: Any]] ?? []).compactMap { match -> SearchMatch? in
          guard let lineNumber = DSHToolPresentationNumber.integerValue(match["lineNumber"]), let line = match["line"] as? String else { return nil }
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
        output: view["output"] as? String, exitCode: DSHToolPresentationNumber.integerValue(view["exitCode"]),
        signal: view["signal"] as? String, cwd: view["cwd"] as? String,
        description: view["description"] as? String, diffs: diffs, lines: lines,
        totalLines: DSHToolPresentationNumber.integerValue(view["totalLines"]), lang: view["lang"] as? String,
        searchShape: view["shape"] as? String, files: files,
        paths: view["paths"] as? [String] ?? [], truncated: view["truncated"] as? Bool ?? false,
        total: DSHToolPresentationNumber.integerValue(view["total"]), webKind: view["kind"] as? String,
        answer: view["answer"] as? String, url: view["url"] as? String,
        statusCode: DSHToolPresentationNumber.integerValue(view["statusCode"]), sources: sources
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
  @Published var hostStatus = "正在启动持久 DSH Host…"
  @Published var hostSessions: [DSHSessionSummary] = []
  @Published var hostWorkspaces: [DSHWorkspaceView] = []
  @Published var hostCurrentSessionID: String?
  /// True while the lazy first-send path is creating the session backing the
  /// default page's first message — gates duplicate sends until it resolves.
  var isCreatingFirstSession = false
  let attachmentStore = DSHAttachmentStore()
  let agentPlatform = DSHAgentPlatformState()
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

  var hostRuntime: DSHHostRuntime?
  var hostClient: DSHHostClient?
  var hostEvents: DSHEventSocket?
  var muxEvents: DSHEventSocket?

  init(startRuntime: Bool = true) {
    agentPlatform.attach(to: self)
    // 启动不再自动建会话：停在默认页（空态 + 可输入的 composer），第一条
    // 消息发出时才懒创建 —— 见 lazy-first-session Agent Note。
    if startRuntime {
      restoreWorkspaceSelection()
      provider = UserDefaults.standard.string(forKey: providerKey) ?? ""
      model = UserDefaults.standard.string(forKey: modelKey) ?? ""
      reasoningEffort = UserDefaults.standard.string(forKey: reasoningEffortKey) ?? "high"
      preset = Preset(rawValue: UserDefaults.standard.string(forKey: presetKey) ?? Preset.code.rawValue) ?? .code
      seedConfigurationFromUserDSHIfNeeded()
      nativeAlerts.attach()
      startPersistentHost()
    }
  }

  deinit { muxEvents?.stop(); hostEvents?.stop(); hostRuntime?.stop() }

  var workspaceName: String { workspace?.lastPathComponent ?? "无工作区" }
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
  var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasCredential && !displayedIsRunning && !isViewingReadOnlySubagent }
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

  var dshHome: URL {
    // DSH_APP_HOME 只影响本 App 的配置根；$HOME 骗不过
    // homeDirectoryForCurrentUser（passwd 解析），所以隔离实例（演示、
    // 截图、并行测试）需要一个显式出口。
    if let override = ProcessInfo.processInfo.environment["DSH_APP_HOME"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DeepSeek Harness/dsh", isDirectory: true)
  }
  var resources: URL { Bundle.main.resourceURL! }
  var runtime: URL { resources.appendingPathComponent("Runtime") }
  var bundledNode: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/node") }
  var bundledDSH: URL { runtime.appendingPathComponent("dsh/lib/bin.js") }

}
