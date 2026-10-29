import AppKit
import Combine
import Darwin
import Foundation
import UniformTypeIdentifiers

enum DSHModelWorkbenchRequest: Equatable {
  case browser(URL)
  case markdown(URL, anchor: String?)
}

enum DSHModelWorkbenchRequestError: LocalizedError {
  case invalidArguments
  case unsupportedBrowserURL
  case missingWorkspace
  case unsupportedMarkdown
  case outsideWorkspace
  case missingFile

  var errorDescription: String? {
    switch self {
    case .invalidArguments: "工作台工具参数无效"
    case .unsupportedBrowserURL: "模型只能在工作台打开 HTTP 或 HTTPS 地址"
    case .missingWorkspace: "当前会话没有可用于校验 Markdown 的工作目录"
    case .unsupportedMarkdown: "模型只能打开 .md、.markdown、.mdown 或 .mkd 文档"
    case .outsideWorkspace: "模型只能打开当前会话工作目录内的 Markdown 文档"
    case .missingFile: "Markdown 文档不存在或不是普通文件"
    }
  }
}

enum DSHModelWorkbenchTool {
  static let browserName = "open_workbench_browser"
  static let markdownName = "open_workbench_markdown"
  static let names: Set<String> = [browserName, markdownName]
  private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

  static func decode(
    data: [String: Any],
    workingDirectory: URL?
  ) throws -> DSHModelWorkbenchRequest? {
    guard let name = data["name"] as? String, names.contains(name) else { return nil }
    let arguments: [String: Any]
    if let object = data["arguments"] as? [String: Any] {
      arguments = object
    } else if let rawArguments = data["arguments"] as? String,
              let bytes = rawArguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
      arguments = object
    } else {
      throw DSHModelWorkbenchRequestError.invalidArguments
    }

    switch name {
    case browserName:
      guard let rawURL = arguments["url"] as? String,
            let url = DSHBrowserRuntime.normalizedURL(from: rawURL),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host?.isEmpty == false
      else { throw DSHModelWorkbenchRequestError.unsupportedBrowserURL }
      return .browser(url)
    case markdownName:
      guard let workingDirectory else { throw DSHModelWorkbenchRequestError.missingWorkspace }
      guard let rawPath = arguments["path"] as? String,
            !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw DSHModelWorkbenchRequestError.invalidArguments }
      let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
      let rawAnchor = (arguments["anchor"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let anchor = rawAnchor?.isEmpty == false ? rawAnchor : nil
      return .markdown(
        try validatedMarkdownURL(path, workingDirectory: workingDirectory),
        anchor: anchor)
    default:
      return nil
    }
  }

  private static func validatedMarkdownURL(
    _ rawPath: String,
    workingDirectory: URL
  ) throws -> URL {
    let root = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let expanded = (rawPath as NSString).expandingTildeInPath
    let candidate = expanded.hasPrefix("/")
      ? URL(fileURLWithPath: expanded)
      : root.appendingPathComponent(expanded)
    guard let target = authorizedFileURL(candidate, within: root) else {
      throw DSHModelWorkbenchRequestError.outsideWorkspace
    }
    guard markdownExtensions.contains(target.pathExtension.lowercased()) else {
      throw DSHModelWorkbenchRequestError.unsupportedMarkdown
    }
    guard let verified = try? DSHVerifiedFile.verifiedURL(target, within: root) else {
      throw DSHModelWorkbenchRequestError.missingFile
    }
    return verified
  }

  static func authorizedFileURL(_ url: URL, within root: URL) -> URL? {
    guard url.isFileURL, root.isFileURL else { return nil }
    let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = canonicalRoot.path.hasSuffix("/")
      ? canonicalRoot.path
      : canonicalRoot.path + "/"
    guard canonicalURL.path == canonicalRoot.path
      || canonicalURL.path.hasPrefix(rootPath) else { return nil }
    return URL(fileURLWithPath: canonicalURL.path)
  }
}

enum DSHVerifiedFileError: LocalizedError {
  case outsideRoot
  case unavailable
  case notRegular
  case tooLarge(Int)
  case readFailed

  var errorDescription: String? {
    switch self {
    case .outsideRoot: "文件已移出当前会话的工作目录。"
    case .unavailable: "文件不存在或无法读取。"
    case .notRegular: "这不是可读取的普通文件。"
    case .tooLarge(let megabytes): "文件超过 \(megabytes) MB，请使用默认应用打开。"
    case .readFailed: "读取文件失败。"
    }
  }
}

enum DSHVerifiedFile {
  private struct Descriptor {
    let value: Int32
    let url: URL
    let size: Int
  }

  static func verifiedURL(_ url: URL, within allowedRoot: URL?) throws -> URL {
    try withDescriptor(url, within: allowedRoot) { $0.url }
  }

  static func readData(
    _ url: URL,
    within allowedRoot: URL?,
    maxBytes: Int
  ) throws -> Data {
    try withDescriptor(url, within: allowedRoot) { descriptor in
      guard descriptor.size <= maxBytes else {
        throw DSHVerifiedFileError.tooLarge(max(1, maxBytes / 1024 / 1024))
      }
      var data = Data()
      data.reserveCapacity(descriptor.size)
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while true {
        let count = Darwin.read(descriptor.value, &buffer, buffer.count)
        if count == 0 { return data }
        guard count > 0 else {
          if errno == EINTR { continue }
          throw DSHVerifiedFileError.readFailed
        }
        guard data.count + count <= maxBytes else {
          throw DSHVerifiedFileError.tooLarge(max(1, maxBytes / 1024 / 1024))
        }
        data.append(buffer, count: count)
      }
    }
  }

  private static func withDescriptor<T>(
    _ url: URL,
    within allowedRoot: URL?,
    body: (Descriptor) throws -> T
  ) throws -> T {
    guard url.isFileURL else { throw DSHVerifiedFileError.unavailable }
    let root = allowedRoot?.standardizedFileURL.resolvingSymlinksInPath()
    let candidate: URL
    if let root {
      guard let authorized = DSHModelWorkbenchTool.authorizedFileURL(url, within: root) else {
        throw DSHVerifiedFileError.outsideRoot
      }
      candidate = authorized
    } else {
      candidate = url.standardizedFileURL
    }
    let flags = O_RDONLY | O_CLOEXEC | (root == nil ? 0 : O_NOFOLLOW)
    let descriptor = Darwin.open(candidate.path, flags)
    guard descriptor >= 0 else { throw DSHVerifiedFileError.unavailable }
    defer { Darwin.close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw DSHVerifiedFileError.unavailable }
    guard (info.st_mode & S_IFMT) == S_IFREG else { throw DSHVerifiedFileError.notRegular }

    let openedURL = try descriptorURL(descriptor)
    if let root,
       !contains(openedURL, within: root) {
      throw DSHVerifiedFileError.outsideRoot
    }
    guard info.st_size >= 0, info.st_size <= off_t(Int.max) else {
      throw DSHVerifiedFileError.tooLarge(Int.max / 1024 / 1024)
    }
    return try body(Descriptor(value: descriptor, url: openedURL, size: Int(info.st_size)))
  }

  private static func descriptorURL(_ descriptor: Int32) throws -> URL {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &path) == 0 else {
      throw DSHVerifiedFileError.unavailable
    }
    return URL(fileURLWithPath: String(cString: path)).standardizedFileURL
  }

  private static func contains(_ url: URL, within root: URL) -> Bool {
    guard let canonicalURL = canonicalizedURL(url),
          let canonicalRoot = canonicalizedURL(root) else { return false }
    let rootPath = canonicalRoot.path.hasSuffix("/")
      ? canonicalRoot.path
      : canonicalRoot.path + "/"
    return canonicalURL.path == canonicalRoot.path
      || canonicalURL.path.hasPrefix(rootPath)
  }

  private static func canonicalizedURL(_ url: URL) -> URL? {
    url.withUnsafeFileSystemRepresentation { path in
      guard let path, let resolved = realpath(path, nil) else { return nil }
      defer { free(resolved) }
      return URL(fileURLWithPath: String(cString: resolved))
    }
  }
}

struct DSHWorkbenchTab: Identifiable, Equatable {
  enum Kind: Equatable {
    case execution
    case agents
    case tool(sessionID: String?, callID: String)
    case browser
    case markdown(path: String)
  }

  let id: UUID
  var kind: Kind
  var title: String
  var preview: Bool

  init(id: UUID = UUID(), kind: Kind, title: String, preview: Bool = false) {
    self.id = id
    self.kind = kind
    self.title = title
    self.preview = preview
  }

  var systemImage: String {
    switch kind {
    case .execution: "bolt.horizontal.circle"
    case .agents: "person.3.sequence"
    case .tool: "wrench.and.screwdriver"
    case .browser: "globe"
    case .markdown: "doc.richtext"
    }
  }
}

struct DSHWorkbenchContext: Equatable {
  var tabs: [DSHWorkbenchTab] = []
  var selectedTabID: UUID?

  var selectedTab: DSHWorkbenchTab? {
    guard let selectedTabID else { return nil }
    return tabs.first { $0.id == selectedTabID }
  }

  mutating func select(_ id: UUID) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    selectedTabID = id
  }

  mutating func appendAndSelect(_ tab: DSHWorkbenchTab) {
    tabs.append(tab)
    selectedTabID = tab.id
  }

  @discardableResult
  mutating func close(_ id: UUID) -> Bool {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
    let wasSelected = selectedTabID == id
    tabs.remove(at: index)
    if wasSelected {
      if tabs.indices.contains(index) { selectedTabID = tabs[index].id }
      else { selectedTabID = tabs.last?.id }
    }
    return true
  }
}

private struct DSHModelWorkbenchPendingCall {
  let sessionID: String
  let data: [String: Any]
  let rootSessionID: String?
  let workingDirectory: URL?
  var settled: Bool
  var handledKey: String?
}

@MainActor
private final class DSHWorkbenchState {
  weak var controller: HarnessController?
  var contexts: [String: DSHWorkbenchContext] = [:]
  var browserRuntimes: [UUID: DSHBrowserRuntime] = [:]
  var markdownDocuments: [UUID: DSHMarkdownDocumentState] = [:]
  var toolSnapshots: [UUID: HarnessController.ToolActivity] = [:]
  var pendingModelCalls: [String: DSHModelWorkbenchPendingCall] = [:]
  var pendingModelCallOrder: [String] = []
  var handledModelCallKeys: Set<String> = []
  var handledModelCallOrder: [String] = []

  init(controller: HarnessController) {
    self.controller = controller
  }

  func notify() {
    controller?.objectWillChange.send()
  }
}

@MainActor
private final class DSHWorkbenchRegistry {
  static let shared = DSHWorkbenchRegistry()
  private var states: [ObjectIdentifier: DSHWorkbenchState] = [:]

  func state(for controller: HarnessController) -> DSHWorkbenchState {
    states = states.filter { $0.value.controller != nil }
    let key = ObjectIdentifier(controller)
    if let state = states[key], let owner = state.controller, owner === controller {
      return state
    }
    let state = DSHWorkbenchState(controller: controller)
    states[key] = state
    return state
  }
}

extension HarnessController {
  private static let defaultWorkbenchContextKey = "default"

  private var workbenchState: DSHWorkbenchState {
    DSHWorkbenchRegistry.shared.state(for: self)
  }

  static func workbenchLocalContextKey(_ id: UUID) -> String { "local:\(id.uuidString)" }
  static func workbenchHostContextKey(_ id: String) -> String { "host:\(id)" }

  private var workbenchContextKey: String {
    if let selectedSession {
      if let hostSessionId = selectedSession.hostSessionId {
        return Self.workbenchHostContextKey(hostSessionId)
      }
      return Self.workbenchLocalContextKey(selectedSession.id)
    }
    if let hostCurrentSessionID {
      return Self.workbenchHostContextKey(hostCurrentSessionID)
    }
    return Self.defaultWorkbenchContextKey
  }

  var workbenchTabs: [DSHWorkbenchTab] {
    workbenchState.contexts[workbenchContextKey]?.tabs ?? []
  }

  var selectedWorkbenchTab: DSHWorkbenchTab? {
    workbenchState.contexts[workbenchContextKey]?.selectedTab
  }

  func toggleWorkbench() {
    if showDetails {
      showDetails = false
      pauseWorkbenchMedia()
      return
    }
    if workbenchTabs.isEmpty { openExecutionWorkbench() }
    else { showDetails = true }
  }

  func selectWorkbenchTab(_ id: UUID) {
    if let current = selectedWorkbenchTab,
       current.id != id,
       case .browser = current.kind {
      workbenchState.browserRuntimes[current.id]?.pauseMedia()
    }
    mutateWorkbenchContext { $0.select(id) }
  }

  func selectNeighborWorkbenchTab(offset: Int) {
    let tabs = workbenchTabs
    guard !tabs.isEmpty else { return }
    guard let current = selectedWorkbenchTab,
          let index = tabs.firstIndex(where: { $0.id == current.id }) else {
      selectWorkbenchTab(tabs[0].id)
      return
    }
    let next = (index + offset + tabs.count) % tabs.count
    selectWorkbenchTab(tabs[next].id)
  }

  func closeWorkbenchTab(_ id: UUID) {
    let state = workbenchState
    guard state.contexts[workbenchContextKey]?.tabs.contains(where: { $0.id == id }) == true else { return }
    state.browserRuntimes[id]?.stop()
    state.browserRuntimes.removeValue(forKey: id)
    state.markdownDocuments[id]?.stopMonitoring()
    state.markdownDocuments.removeValue(forKey: id)
    state.toolSnapshots.removeValue(forKey: id)
    mutateWorkbenchContext { _ = $0.close(id) }
  }

  func openExecutionWorkbench(refresh: Bool = true, resetRunSelection: Bool = true) {
    openSingletonWorkbenchTab(kind: .execution, title: "执行")
    if resetRunSelection { selectedAgentRunID = nil }
    if refresh { refreshAgentBatches() }
  }

  func openAgentsWorkbench() {
    openSingletonWorkbenchTab(kind: .agents, title: "Agent")
    selectedAgentRunID = nil
    refreshAgentProfiles()
    refreshAgentRuntimeStatuses()
  }

  func openToolWorkbench(_ tool: ToolActivity) {
    pauseSelectedWorkbenchBrowser()
    let sessionID: String?
    switch displayedExecutionTarget {
    case .root(let id): sessionID = id
    case .subagent(let address): sessionID = address.childSessionId
    case .none: sessionID = nil
    }
    let state = workbenchState
    var context = state.contexts[workbenchContextKey] ?? DSHWorkbenchContext()
    if let existing = context.tabs.first(where: {
      guard case .tool(let existingSessionID, let callID) = $0.kind else { return false }
      return existingSessionID == sessionID && callID == tool.callId
    }) {
      context.select(existing.id)
      state.contexts[workbenchContextKey] = context
      state.toolSnapshots[existing.id] = tool
      showDetails = true
      state.notify()
      return
    }
    if let previewIndex = context.tabs.firstIndex(where: {
      if case .tool = $0.kind { return $0.preview }
      return false
    }) {
      let id = context.tabs[previewIndex].id
      context.tabs[previewIndex] = DSHWorkbenchTab(
        id: id,
        kind: .tool(sessionID: sessionID, callID: tool.callId),
        title: tool.name,
        preview: true)
      context.select(id)
      state.toolSnapshots[id] = tool
    } else {
      let tab = DSHWorkbenchTab(
        kind: .tool(sessionID: sessionID, callID: tool.callId),
        title: tool.name,
        preview: true)
      context.appendAndSelect(tab)
      state.toolSnapshots[tab.id] = tool
    }
    state.contexts[workbenchContextKey] = context
    showDetails = true
    state.notify()
  }

  func pinWorkbenchTab(_ id: UUID) {
    mutateWorkbenchContext { context in
      guard let index = context.tabs.firstIndex(where: { $0.id == id }) else { return }
      context.tabs[index].preview = false
    }
  }

  func newBrowserWorkbench(url: URL? = nil) {
    createBrowserWorkbench(url: url, contextKey: workbenchContextKey, reveal: true)
  }

  func consumeModelWorkbenchEvent(sessionID: String, event: [String: Any]) {
    guard let kind = event["type"] as? String,
          let data = event["data"] as? [String: Any] else { return }
    switch kind {
    case "tool/call":
      rememberModelWorkbenchCall(
        sessionID: sessionID,
        key: modelWorkbenchCallKey(sessionID: sessionID, data: data),
        data: data)
    case "tool/code-dispatch-start":
      guard let callID = data["subCallId"] as? String else { return }
      rememberModelWorkbenchCall(
        sessionID: sessionID,
        key: modelWorkbenchCodeCallKey(
          sessionID: sessionID,
          data: data,
          callID: callID),
        data: [
          "callId": callID,
          "name": data["name"] ?? "",
          "arguments": data["arguments"] ?? [:],
        ])
    case "tool/result":
      guard let result = DSHToolResultDecoder.live(from: data) else { return }
      let key = modelWorkbenchCallKey(
        sessionID: sessionID,
        data: data,
        callID: result.callId)
      finishModelWorkbenchCall(
        sessionID: sessionID,
        key: key,
        succeeded: !result.isError,
        handledKey: modelWorkbenchEventKey(
          sessionID: sessionID,
          event: event,
          fallback: key))
    case "tool/code-dispatch":
      guard let name = data["name"] as? String,
            DSHModelWorkbenchTool.names.contains(name),
            let callID = data["subCallId"] as? String
      else { return }
      let key = modelWorkbenchCodeCallKey(
        sessionID: sessionID,
        data: data,
        callID: callID)
      if workbenchState.pendingModelCalls[key] != nil {
        finishModelWorkbenchCall(
          sessionID: sessionID,
          key: key,
          succeeded: data["isError"] as? Bool == false,
          handledKey: modelWorkbenchEventKey(
            sessionID: sessionID,
            event: event,
            fallback: key))
      } else if data["isError"] as? Bool == false {
        rememberModelWorkbenchCall(
          sessionID: sessionID,
          key: key,
          data: [
            "callId": callID,
            "name": name,
            "arguments": data["arguments"] ?? [:],
          ])
        finishModelWorkbenchCall(
          sessionID: sessionID,
          key: key,
          succeeded: true,
          handledKey: modelWorkbenchEventKey(
            sessionID: sessionID,
            event: event,
            fallback: key))
      }
    case "turn/end":
      clearPendingModelWorkbenchRequests(sessionID: sessionID, includeSettled: false)
    default:
      break
    }
  }

  func clearPendingModelWorkbenchRequests(
    sessionID: String? = nil,
    includeSettled: Bool = true
  ) {
    let state = workbenchState
    guard let sessionID else {
      state.pendingModelCalls.removeAll()
      state.pendingModelCallOrder.removeAll()
      state.handledModelCallKeys.removeAll()
      state.handledModelCallOrder.removeAll()
      return
    }
    let keys = state.pendingModelCalls.compactMap { key, pending in
      pending.sessionID == sessionID && (includeSettled || !pending.settled) ? key : nil
    }
    keys.forEach { state.pendingModelCalls.removeValue(forKey: $0) }
    let removed = Set(keys)
    state.pendingModelCallOrder.removeAll { removed.contains($0) }
  }

  func resumePendingModelWorkbenchRequests() {
    let state = workbenchState
    for key in state.pendingModelCallOrder {
      guard let pending = state.pendingModelCalls[key], pending.settled else { continue }
      if executeModelWorkbenchCall(
        sessionID: pending.sessionID,
        handledKey: pending.handledKey ?? key,
        data: pending.data,
        rootSessionID: pending.rootSessionID,
        workingDirectory: pending.workingDirectory
      ) {
        state.pendingModelCalls.removeValue(forKey: key)
      }
    }
    state.pendingModelCallOrder.removeAll { state.pendingModelCalls[$0] == nil }
  }

  @discardableResult
  private func executeModelWorkbenchCall(
    sessionID: String,
    handledKey: String,
    data: [String: Any],
    rootSessionID: String?,
    workingDirectory: URL?
  ) -> Bool {
    guard let rootSessionID = rootSessionID ?? topLevelWorkbenchSessionID(for: sessionID) else {
      return false
    }
    let workingDirectory = workingDirectory ?? modelWorkbenchWorkingDirectory(
        sessionID: sessionID,
        rootSessionID: rootSessionID)
    if data["name"] as? String == DSHModelWorkbenchTool.markdownName,
       workingDirectory == nil {
      return false
    }
    do {
      guard let request = try DSHModelWorkbenchTool.decode(
        data: data,
        workingDirectory: workingDirectory)
      else { return true }
      guard claimModelWorkbenchCall(handledKey) else { return true }
      let contextKey = Self.workbenchHostContextKey(rootSessionID)
      let reveal = rootSessionID == hostCurrentSessionID
      switch request {
      case .browser(let url):
        createBrowserWorkbench(
          url: url,
          contextKey: contextKey,
          reveal: reveal,
          restrictToHTTP: true)
      case .markdown(let url, let anchor):
        createMarkdownWorkbench(
          url: url,
          contextKey: contextKey,
          reveal: reveal,
          anchor: anchor,
          allowedFileRoot: workingDirectory)
      }
    } catch {
      guard claimModelWorkbenchCall(handledKey) else { return true }
      reportModelWorkbenchFailure(
        error.localizedDescription,
        rootSessionID: rootSessionID)
    }
    return true
  }

  private func createBrowserWorkbench(
    url: URL?,
    contextKey: String,
    reveal: Bool,
    restrictToHTTP: Bool = false
  ) {
    if let url, url.isFileURL {
      if ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()) {
        createMarkdownWorkbench(url: url.standardizedFileURL, contextKey: contextKey, reveal: reveal)
      } else {
        NSWorkspace.shared.open(url)
      }
      return
    }
    if let url, !["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") {
      NSWorkspace.shared.open(url)
      return
    }
    if contextKey == workbenchContextKey { pauseSelectedWorkbenchBrowser() }
    let tab = DSHWorkbenchTab(kind: .browser, title: url?.host ?? "新标签")
    let runtime = DSHBrowserRuntime(restrictToHTTP: restrictToHTTP)
    runtime.onTitleChange = { [weak self] title in self?.updateWorkbenchTabTitle(tab.id, title: title) }
    runtime.onOpenNewWindow = { [weak self, weak runtime] target in
      guard let self else { return }
      let ownerKey = self.workbenchContextKey(containingTab: tab.id) ?? self.workbenchContextKey
      self.createBrowserWorkbench(
        url: target,
        contextKey: ownerKey,
        reveal: ownerKey == self.workbenchContextKey,
        restrictToHTTP: runtime?.restrictToHTTP == true)
    }
    runtime.onOpenFile = { [weak self, weak runtime] target in
      guard let self else { return }
      runtime?.pauseMedia()
      if ["md", "markdown", "mdown", "mkd"].contains(target.pathExtension.lowercased()) {
        let ownerKey = self.workbenchContextKey(containingTab: tab.id) ?? self.workbenchContextKey
        self.createMarkdownWorkbench(
          url: target.standardizedFileURL,
          contextKey: ownerKey,
          reveal: ownerKey == self.workbenchContextKey)
      } else {
        NSWorkspace.shared.open(target)
      }
    }
    let state = workbenchState
    state.browserRuntimes[tab.id] = runtime
    var context = state.contexts[contextKey] ?? DSHWorkbenchContext()
    context.appendAndSelect(tab)
    state.contexts[contextKey] = context
    if reveal { showDetails = true }
    state.notify()
    if let url { runtime.navigate(to: url) }
  }

  func openBrowserWorkbench(_ rawAddress: String) {
    guard let url = DSHBrowserRuntime.normalizedURL(from: rawAddress) else {
      status = "无法识别浏览器地址：\(rawAddress)"
      return
    }
    newBrowserWorkbench(url: url)
  }

  func browserRuntime(for tabID: UUID) -> DSHBrowserRuntime? {
    workbenchState.browserRuntimes[tabID]
  }

  func focusWorkbenchBrowserAddress() {
    if let selected = selectedWorkbenchTab,
       case .browser = selected.kind,
       let runtime = browserRuntime(for: selected.id) {
      showDetails = true
      runtime.requestAddressFocus()
      return
    }
    newBrowserWorkbench()
    guard let selected = selectedWorkbenchTab else { return }
    browserRuntime(for: selected.id)?.requestAddressFocus()
  }

  func chooseMarkdownWorkbench() {
    let panel = NSOpenPanel()
    panel.title = "打开 Markdown"
    panel.message = "选择一个 Markdown 文档在右侧工作台阅读。"
    panel.prompt = "打开"
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = workspace
    panel.allowedContentTypes = ["md", "markdown", "mdown", "mkd"].compactMap { UTType(filenameExtension: $0) }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    openMarkdownWorkbench(url.path)
  }

  func openMarkdownWorkbench(_ path: String, anchor: String? = nil) {
    pauseSelectedWorkbenchBrowser()
    let currentDirectory = hostCurrentSessionID
      .flatMap { sessionID in hostSessions.first(where: { $0.sessionId == sessionID })?.cwd }
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? workspace
    let resolved = Self.resolveWorkspacePath(path, workspace: currentDirectory)
    let url = URL(fileURLWithPath: resolved).standardizedFileURL
    createMarkdownWorkbench(url: url, contextKey: workbenchContextKey, reveal: true, anchor: anchor)
  }

  private func createMarkdownWorkbench(
    url: URL,
    contextKey: String,
    reveal: Bool,
    anchor: String? = nil,
    allowedFileRoot: URL? = nil
  ) {
    let state = workbenchState
    var context = state.contexts[contextKey] ?? DSHWorkbenchContext()
    if let existing = context.tabs.first(where: {
      guard case .markdown(let existingPath) = $0.kind else { return false }
      return existingPath == url.path
        && state.markdownDocuments[$0.id]?.allowedFileRoot?.path
          == allowedFileRoot?.standardizedFileURL.resolvingSymlinksInPath().path
    }) {
      context.select(existing.id)
      state.contexts[contextKey] = context
      if let anchor { state.markdownDocuments[existing.id]?.requestAnchor(anchor) }
      if reveal { showDetails = true }
      state.notify()
      return
    }
    let tab = DSHWorkbenchTab(kind: .markdown(path: url.path), title: url.lastPathComponent)
    let document = DSHMarkdownDocumentState(url: url, allowedFileRoot: allowedFileRoot)
    state.markdownDocuments[tab.id] = document
    if let anchor { document.requestAnchor(anchor) }
    context.appendAndSelect(tab)
    state.contexts[contextKey] = context
    if reveal { showDetails = true }
    state.notify()
  }

  func markdownDocument(for tabID: UUID) -> DSHMarkdownDocumentState? {
    workbenchState.markdownDocuments[tabID]
  }

  func toolActivity(for tab: DSHWorkbenchTab) -> ToolActivity? {
    guard case .tool(let sessionID, let callID) = tab.kind else { return nil }
    if let sessionID {
      if sessionID == hostCurrentSessionID {
        return activeTools.last { $0.callId == callID } ?? workbenchState.toolSnapshots[tab.id]
      }
      return subagentTool(sessionID: sessionID, callID: callID) ?? workbenchState.toolSnapshots[tab.id]
    }
    return workbenchState.toolSnapshots[tab.id]
  }

  func migrateWorkbenchContext(localSessionID: UUID, hostSessionID: String) {
    migrateWorkbenchContext(
      from: Self.workbenchLocalContextKey(localSessionID),
      to: Self.workbenchHostContextKey(hostSessionID))
  }

  func migrateDefaultWorkbenchContext(to localSessionID: UUID) {
    migrateWorkbenchContext(
      from: Self.defaultWorkbenchContextKey,
      to: Self.workbenchLocalContextKey(localSessionID))
  }

  func discardWorkbenchContext(hostSessionID: String) {
    discardWorkbenchContext(key: Self.workbenchHostContextKey(hostSessionID))
  }

  func discardArchivedWorkbenchContexts(hostSessionIDs: Set<String>) {
    hostSessionIDs.forEach { discardWorkbenchContext(hostSessionID: $0) }
  }

  func pauseWorkbenchMedia() {
    workbenchState.browserRuntimes.values.forEach { $0.pauseMedia() }
  }

  func shutdownWorkbench() {
    let state = workbenchState
    state.browserRuntimes.values.forEach { $0.stop() }
    state.markdownDocuments.values.forEach { $0.stopMonitoring() }
    state.browserRuntimes.removeAll()
    state.markdownDocuments.removeAll()
    state.toolSnapshots.removeAll()
    state.contexts.removeAll()
    state.pendingModelCalls.removeAll()
    state.pendingModelCallOrder.removeAll()
    state.handledModelCallKeys.removeAll()
    state.handledModelCallOrder.removeAll()
  }

  nonisolated static func resolvedMarkdownLink(_ destination: URL, documentURL: URL) -> URL {
    guard destination.scheme == nil else { return destination }
    if destination.relativeString.hasPrefix("#") { return destination }
    let fileURL = URL(
      fileURLWithPath: destination.path,
      relativeTo: documentURL.deletingLastPathComponent()
    ).standardizedFileURL
    guard let rawFragment = destination.fragment else { return fileURL }
    var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
    components?.fragment = rawFragment.removingPercentEncoding ?? rawFragment
    return components?.url ?? fileURL
  }

  func openMarkdownLink(
    _ destination: URL,
    documentURL: URL,
    allowedFileRoot: URL? = nil
  ) {
    var resolved = Self.resolvedMarkdownLink(destination, documentURL: documentURL)
    if resolved.relativeString.hasPrefix("#") { return }
    let anchor = resolved.fragment
    if resolved.isFileURL, let allowedFileRoot {
      guard let authorized = DSHModelWorkbenchTool.authorizedFileURL(
        resolved,
        within: allowedFileRoot)
      else {
        status = "该链接超出模型文档的工作区范围"
        return
      }
      resolved = authorized
    }
    if ["http", "https"].contains(resolved.scheme?.lowercased() ?? "") {
      newBrowserWorkbench(url: resolved)
    } else if ["md", "markdown", "mdown", "mkd"].contains(resolved.pathExtension.lowercased()) {
      pauseSelectedWorkbenchBrowser()
      createMarkdownWorkbench(
        url: resolved.standardizedFileURL,
        contextKey: workbenchContextKey,
        reveal: true,
        anchor: anchor,
        allowedFileRoot: allowedFileRoot)
    } else {
      NSWorkspace.shared.open(resolved)
    }
  }

  private func mutateWorkbenchContext(_ body: (inout DSHWorkbenchContext) -> Void) {
    let state = workbenchState
    var context = state.contexts[workbenchContextKey] ?? DSHWorkbenchContext()
    body(&context)
    state.contexts[workbenchContextKey] = context
    state.notify()
  }

  private func openSingletonWorkbenchTab(kind: DSHWorkbenchTab.Kind, title: String) {
    pauseSelectedWorkbenchBrowser()
    let state = workbenchState
    var context = state.contexts[workbenchContextKey] ?? DSHWorkbenchContext()
    if let existing = context.tabs.first(where: { $0.kind == kind }) {
      context.select(existing.id)
    } else {
      context.appendAndSelect(DSHWorkbenchTab(kind: kind, title: title))
    }
    state.contexts[workbenchContextKey] = context
    showDetails = true
    state.notify()
  }

  private func updateWorkbenchTabTitle(_ id: UUID, title: String) {
    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    let state = workbenchState
    for key in Array(state.contexts.keys) {
      guard let index = state.contexts[key]?.tabs.firstIndex(where: { $0.id == id }) else { continue }
      state.contexts[key]?.tabs[index].title = clean
      state.notify()
      return
    }
  }

  private func workbenchContextKey(containingTab id: UUID) -> String? {
    workbenchState.contexts.first { _, context in
      context.tabs.contains { $0.id == id }
    }?.key
  }

  private func pauseSelectedWorkbenchBrowser() {
    guard let selected = selectedWorkbenchTab, case .browser = selected.kind else { return }
    workbenchState.browserRuntimes[selected.id]?.pauseMedia()
  }

  private func claimModelWorkbenchCall(_ key: String) -> Bool {
    let state = workbenchState
    guard state.handledModelCallKeys.insert(key).inserted else { return false }
    state.handledModelCallOrder.append(key)
    if state.handledModelCallOrder.count > 512 {
      let overflow = state.handledModelCallOrder.count - 512
      let expired = state.handledModelCallOrder.prefix(overflow)
      state.handledModelCallKeys.subtract(expired)
      state.handledModelCallOrder.removeFirst(overflow)
    }
    return true
  }

  private func rememberModelWorkbenchCall(
    sessionID: String,
    key: String,
    data: [String: Any]
  ) {
    guard let name = data["name"] as? String,
          DSHModelWorkbenchTool.names.contains(name) else { return }
    let rootSessionID = topLevelWorkbenchSessionID(for: sessionID)
    let state = workbenchState
    if state.pendingModelCalls[key] == nil { state.pendingModelCallOrder.append(key) }
    state.pendingModelCalls[key] = DSHModelWorkbenchPendingCall(
      sessionID: sessionID,
      data: data,
      rootSessionID: rootSessionID,
      workingDirectory: rootSessionID.flatMap {
        modelWorkbenchWorkingDirectory(sessionID: sessionID, rootSessionID: $0)
      },
      settled: false,
      handledKey: nil)
    if state.pendingModelCallOrder.count > 512 {
      let overflow = state.pendingModelCallOrder.count - 512
      for expired in state.pendingModelCallOrder.prefix(overflow) {
        state.pendingModelCalls.removeValue(forKey: expired)
      }
      state.pendingModelCallOrder.removeFirst(overflow)
    }
  }

  private func finishModelWorkbenchCall(
    sessionID: String,
    key: String,
    succeeded: Bool,
    handledKey: String? = nil
  ) {
    let state = workbenchState
    guard var pending = state.pendingModelCalls[key] else { return }
    guard succeeded else {
      state.pendingModelCalls.removeValue(forKey: key)
      state.pendingModelCallOrder.removeAll { $0 == key }
      return
    }
    pending.settled = true
    pending.handledKey = handledKey ?? key
    state.pendingModelCalls[key] = pending
    if executeModelWorkbenchCall(
      sessionID: pending.sessionID,
      handledKey: pending.handledKey ?? key,
      data: pending.data,
      rootSessionID: pending.rootSessionID,
      workingDirectory: pending.workingDirectory
    ) {
      state.pendingModelCalls.removeValue(forKey: key)
      state.pendingModelCallOrder.removeAll { $0 == key }
    } else {
      refreshHostSnapshots()
      if let rootSessionID = pending.rootSessionID ?? topLevelWorkbenchSessionID(for: pending.sessionID) {
        refreshAgentBatches(rootSessionId: rootSessionID)
      }
    }
  }

  private func modelWorkbenchCallKey(
    sessionID: String,
    data: [String: Any],
    callID: String? = nil
  ) -> String {
    let callID = callID ?? data["callId"] as? String ?? "unknown"
    let turn = DSHToolPresentationNumber.integerValue(data["turn"]) ?? -1
    let step = DSHToolPresentationNumber.integerValue(data["step"]) ?? -1
    return "\(sessionID):call:\(turn):\(step):\(callID)"
  }

  private func modelWorkbenchCodeCallKey(
    sessionID: String,
    data: [String: Any],
    callID: String
  ) -> String {
    let rootCallID = data["rootCallId"] as? String ?? data["parentCallId"] as? String ?? "unknown"
    return "\(sessionID):code:\(rootCallID):\(callID)"
  }

  private func modelWorkbenchEventKey(
    sessionID: String,
    event: [String: Any],
    fallback: String
  ) -> String {
    guard let seq = DSHToolPresentationNumber.integerValue(event["seq"]) else { return fallback }
    return "\(sessionID):event:\(seq)"
  }

  private func topLevelWorkbenchSessionID(for sessionID: String) -> String? {
    if sessionID == hostCurrentSessionID { return sessionID }
    if activeSubagentAddress?.childSessionId == sessionID { return hostCurrentSessionID }
    if voiceTaskSessions[sessionID] != nil { return sessionID }
    if let batch = agentBatches.first(where: {
      $0.runs.contains { $0.childSessionId == sessionID }
    }) {
      return batch.rootSessionId
    }
    var current = sessionID
    var visited = Set<String>()
    while visited.insert(current).inserted {
      guard let summary = hostSessions.first(where: { $0.sessionId == current }) else {
        return sessions.contains(where: { $0.hostSessionId == current }) ? current : nil
      }
      guard let parent = summary.parentSessionId, !parent.isEmpty else { return current }
      current = parent
    }
    return nil
  }

  private func modelWorkbenchWorkingDirectory(
    sessionID: String,
    rootSessionID: String
  ) -> URL? {
    if let cwd = hostSessions.first(where: { $0.sessionId == sessionID })?.cwd {
      return URL(fileURLWithPath: cwd, isDirectory: true)
    }
    if let path = agentBatches.lazy.flatMap(\.runs)
      .first(where: { $0.childSessionId == sessionID })?.worktreePath {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    guard sessionID == rootSessionID else { return nil }
    if let cwd = hostSessions.first(where: { $0.sessionId == rootSessionID })?.cwd {
      return URL(fileURLWithPath: cwd, isDirectory: true)
    }
    return rootSessionID == hostCurrentSessionID ? workspace : nil
  }

  private func reportModelWorkbenchFailure(_ message: String, rootSessionID: String) {
    if let localSessionID = sessions.first(where: { $0.hostSessionId == rootSessionID })?.id {
      appendSystem("模型工作台请求未执行：\(message)", to: localSessionID)
    } else if rootSessionID == hostCurrentSessionID {
      status = "模型工作台请求未执行：\(message)"
    }
  }

  private func migrateWorkbenchContext(from source: String, to destination: String) {
    guard source != destination else { return }
    let state = workbenchState
    guard let sourceContext = state.contexts.removeValue(forKey: source) else { return }
    if var destinationContext = state.contexts[destination], !destinationContext.tabs.isEmpty {
      let existingIDs = Set(destinationContext.tabs.map(\.id))
      destinationContext.tabs.append(contentsOf: sourceContext.tabs.filter { !existingIDs.contains($0.id) })
      if let selected = sourceContext.selectedTabID { destinationContext.selectedTabID = selected }
      state.contexts[destination] = destinationContext
    } else {
      state.contexts[destination] = sourceContext
    }
    state.notify()
  }

  private func discardWorkbenchContext(key: String) {
    let state = workbenchState
    guard let context = state.contexts.removeValue(forKey: key) else { return }
    for tab in context.tabs {
      state.browserRuntimes[tab.id]?.stop()
      state.browserRuntimes.removeValue(forKey: tab.id)
      state.markdownDocuments[tab.id]?.stopMonitoring()
      state.markdownDocuments.removeValue(forKey: tab.id)
      state.toolSnapshots.removeValue(forKey: tab.id)
    }
    state.notify()
  }
}
