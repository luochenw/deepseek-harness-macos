import Foundation

/// A typed carrier for the DSH Web Host RPC protocol used by the native client.
/// The Host remains authoritative for persistent sessions, workspaces, tools,
/// approvals, jobs, subagents, and settings.
struct DSHRPCEnvelope<Payload: Encodable>: Encodable {
  let type = "client-request"
  let rpcId: String
  let method: String
  let payload: Payload
}

struct DSHArgsPayload<Args: Encodable>: Encodable {
  let args: Args
}

struct DSHRequestArgsPayload<Request: Encodable>: Encodable {
  let request: Request
}

struct DSHRPCServerResponse<Value: Decodable>: Decodable {
  struct Result: Decodable {
    let ok: Bool
    let value: Value?
    let error: DSHRPCError?
  }
  let type: String
  let rpcId: String
  let result: Result
}

struct DSHRPCError: Decodable, Error, LocalizedError {
  let code: String
  let message: String
  var errorDescription: String? { "\(code): \(message)" }
}

struct DSHHostDescription: Decodable {
  let version: String
  let cwd: String
  let provider: String?
  let model: String?
  let attachedSessions: Int
  let home: String
  let canOpenPath: Bool
}

struct DSHSessionSummary: Decodable, Identifiable {
  let sessionId: String
  var updatedAt: Double
  /// Whether a live Agent currently owns this persistent Session.
  var agentAvailable = false
  /// `current`, `migration-required`, or nil when this old row cannot report it.
  var formatStatus: String?
  /// Mutable: the mux stream's turn/start / turn/end frames keep this live
  /// between snapshot refreshes (the sidebar dot reads it).
  var running: Bool
  let blank: Bool
  let cwd: String?
  let agentPreset: String?
  let parentSessionId: String?
  let origin: String?
  let projections: DSHSessionProjections?
  var id: String { sessionId }
  var title: String { projections?.values.title ?? "新会话" }
  var needsMigration: Bool { formatStatus == "migration-required" }
  var isCurrentFormat: Bool { formatStatus == nil || formatStatus == "current" }
}

struct DSHSessionProjections: Decodable {
  enum Kind: String, Decodable, Equatable {
    case cached
    case sequenced
    case migrationRequired = "migration-required"
  }

  let kind: Kind
  let asOfSeq: Int?
  let values: DSHSessionProjectionValues
  /// Projection values are intentionally wide on the wire. The raw form
  /// distinguishes a missing capability from a present JSON null so child
  /// contexts can apply Host-cleared Todo/Goal values at the right sequence.
  let rawValues: [String: DSHJSONValue]

  init(
    asOfSeq: Int,
    values: DSHSessionProjectionValues,
    rawValues: [String: DSHJSONValue] = [:]
  ) {
    self.kind = .sequenced
    self.asOfSeq = asOfSeq
    self.values = values
    self.rawValues = rawValues
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case asOfSeq
    case values
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .sequenced
    asOfSeq = try container.decodeIfPresent(Int.self, forKey: .asOfSeq)
    if kind == .sequenced && asOfSeq == nil {
      throw DecodingError.keyNotFound(
        CodingKeys.asOfSeq,
        DecodingError.Context(codingPath: container.codingPath, debugDescription: "sequenced projections require asOfSeq"))
    }
    values = try container.decode(DSHSessionProjectionValues.self, forKey: .values)
    rawValues = try container.decode([String: DSHJSONValue].self, forKey: .values)
  }

  var canMerge: Bool { kind == .sequenced && asOfSeq != nil }
}

struct DSHSessionProjectionValues: Decodable {
  let title: String?
  let todos: [DSHTodoItem]?
  let plan: DSHPlanState?
  let goal: DSHGoalProjection?
  let modelSelection: DSHModelSelectionProjection?
  let tokenUsage: DSHTokenUsage?
  let contextPressure: DSHContextPressure?
  let sessionStats: DSHSessionStats?
  let permissions: DSHPermissionSelection?

  init(
    title: String?,
    todos: [DSHTodoItem]?,
    plan: DSHPlanState?,
    goal: DSHGoalProjection?,
    modelSelection: DSHModelSelectionProjection? = nil,
    tokenUsage: DSHTokenUsage?,
    contextPressure: DSHContextPressure?,
    sessionStats: DSHSessionStats?,
    permissions: DSHPermissionSelection? = nil
  ) {
    self.title = title
    self.todos = todos
    self.plan = plan
    self.goal = goal
    self.modelSelection = modelSelection
    self.tokenUsage = tokenUsage
    self.contextPressure = contextPressure
    self.sessionStats = sessionStats
    self.permissions = permissions
  }
}

struct DSHGoalProjection: Decodable {
  struct Goal: Decodable {
    let id: String
    let revision: Int
    let objective: String
    let phase: String
    let maxGoalRounds: Int
  }
  let goal: Goal?
  let roundsStarted: Int?
}

struct DSHTodoItem: Decodable, Identifiable {
  let content: String
  let status: String
  var id: String { content }
}

struct DSHPlanState: Decodable {
  let active: Bool
  let pending: Bool
}

struct DSHSessionList: Decodable {
  let items: [DSHSessionSummary]
}

struct DSHSessionListArgs: Encodable {
  let _request: DSHSessionListRequest
}

struct DSHSessionListRequest: Encodable {
  let cursor: String?
  init(cursor: String? = nil) { self.cursor = cursor }
}

struct DSHCreatedSession: Decodable {
  let sessionId: String
  let agentPreset: String?
}

struct DSHPromptAccepted: Decodable {
  let accepted: Bool
}

struct DSHCreateSessionPayload: Encodable {
  let cwd: String?
  let agentPreset: String?
}

struct DSHPromptContent: Encodable {
  let type: String
  let text: String?
  let mediaType: String?
  let data: String?
  let name: String?
  static func text(_ text: String) -> Self { Self(type: "text", text: text, mediaType: nil, data: nil, name: nil) }
  static func image(data: String, mediaType: String, name: String) -> Self { Self(type: "image", text: nil, mediaType: mediaType, data: data, name: name) }
}

enum DSHPromptMode: String, Encodable, CaseIterable, Identifiable {
  case queue, steer
  var id: String { rawValue }
}

struct DSHPromptPayload: Encodable {
  let requestId: String
  let sessionId: String
  let mode: DSHPromptMode
  let content: [DSHPromptContent]

  init(
    requestId: String = UUID().uuidString,
    sessionId: String,
    mode: DSHPromptMode,
    content: [DSHPromptContent]
  ) {
    self.requestId = requestId
    self.sessionId = sessionId
    self.mode = mode
    self.content = content
  }
}

struct DSHCancelPayload: Encodable {
  let sessionId: String
}

struct DSHWorkspaceView: Decodable, Identifiable {
  let workspaceId: String
  let path: String
  let title: String
  let sessionIds: [String]
  var id: String { workspaceId }
}

struct DSHWorkspaceList: Decodable {
  let items: [DSHWorkspaceView]
  let archivedSessionIds: [String]
}

actor DSHHostClient {
  let baseURL: URL
  private let session: URLSession
  private let launch: DSHHostLaunch?
  private var authCookie: DSHHostAuthCookie?

  init(baseURL: URL) {
    self.baseURL = baseURL
    self.session = Self.authenticatedSession()
    self.launch = nil
    self.authCookie = nil
  }

  init(connection: DSHHostConnection) {
    self.baseURL = connection.launch.baseURL
    self.session = Self.authenticatedSession()
    self.launch = connection.launch
    self.authCookie = connection.cookie
  }

  func call<Payload: Encodable, Value: Decodable>(
    _ method: String,
    payload: Payload,
    as valueType: Value.Type,
  ) async throws -> Value {
    try await call(method, args: payload, as: valueType)
  }

  /// Calls one 0.2 Remote. The argument value is wrapped in the mandatory
  /// single `args` field; endpoint-specific wrappers such as `request` and
  /// `_request` are supplied by their typed wrapper methods.
  func call<Args: Encodable, Value: Decodable>(
    _ method: String,
    args: Args,
    as valueType: Value.Type,
  ) async throws -> Value {
    guard let value = try await callOptional(method, args: args, as: valueType) else {
      throw URLError(.cannotParseResponse)
    }
    return value
  }

  func callOptional<Args: Encodable, Value: Decodable>(
    _ method: String,
    args: Args,
    as valueType: Value.Type,
  ) async throws -> Value? {
    let rpcId = UUID().uuidString
    let body = try JSONEncoder().encode(
      DSHRPCEnvelope(
        rpcId: rpcId,
        method: method,
        payload: DSHArgsPayload(args: args)))
    let data = try await post(method, body: body)
    let decoded = try JSONDecoder().decode(DSHRPCServerResponse<Value>.self, from: data)
    guard decoded.type == "server-response", decoded.rpcId == rpcId else {
      throw URLError(.cannotParseResponse)
    }
    guard decoded.result.ok else {
      throw decoded.result.error ?? URLError(.cannotParseResponse)
    }
    return decoded.result.value
  }

  /// Shared authenticated unary carrier used by the main RPC client and the
  /// Typert extension surface. A 401 refreshes the launch handshake once and
  /// replays the exact encoded body with a fresh cookie.
  func post(_ method: String, body: Data) async throws -> Data {
    for attempt in 0...1 {
      try await ensureAuthentication()
      var request = URLRequest(url: baseURL.appendingPathComponent("api/\(method)"))
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(loopbackHost, forHTTPHeaderField: "Host")
      if let authCookie { request.setValue(authCookie.headerValue, forHTTPHeaderField: "Cookie") }
      request.httpBody = body
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
      if http.statusCode == 401, attempt == 0, launch?.token != nil {
        authCookie = nil
        continue
      }
      guard (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
      return data
    }
    throw URLError(.userAuthenticationRequired)
  }

  func authenticatedRequest(path: String, method: String = "GET", body: Data? = nil) async throws -> URLRequest {
    try await ensureAuthentication()
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.httpMethod = method
    request.setValue(loopbackHost, forHTTPHeaderField: "Host")
    if let authCookie { request.setValue(authCookie.headerValue, forHTTPHeaderField: "Cookie") }
    request.httpBody = body
    return request
  }

  func authenticatedDownload(_ request: URLRequest) async throws -> (URL, URLResponse) {
    for attempt in 0...1 {
      var authenticated = request
      try await ensureAuthentication()
      if let authCookie { authenticated.setValue(authCookie.headerValue, forHTTPHeaderField: "Cookie") }
      let result = try await session.download(for: authenticated)
      if let http = result.1 as? HTTPURLResponse,
         http.statusCode == 401,
         attempt == 0,
         launch?.token != nil {
        authCookie = nil
        continue
      }
      return result
    }
    throw URLError(.userAuthenticationRequired)
  }

  func webSocketRequest(path: String) async throws -> URLRequest {
    try await ensureAuthentication()
    guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
      throw URLError(.badURL)
    }
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    guard let url = components.url else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.setValue(loopbackHost, forHTTPHeaderField: "Host")
    if let authCookie { request.setValue(authCookie.headerValue, forHTTPHeaderField: "Cookie") }
    return request
  }

  private var loopbackHost: String {
    baseURL.host.map { host in
      baseURL.port.map { "\(host):\($0)" } ?? host
    } ?? "127.0.0.1"
  }

  private static func authenticatedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    return URLSession(configuration: configuration)
  }

  private func ensureAuthentication() async throws {
    guard authCookie == nil, let launch else { return }
    authCookie = try await DSHHostHandshake.authenticate(launch: launch)
  }

  func openPath(_ path: String) async throws {
    _ = try await call(
      "session/openWorkspacePath",
      args: DSHRequestArgsPayload(request: DSHOpenPathPayload(path: path)),
      as: DSHOpenPathResult.self)
  }

  func describe() async throws -> DSHHostDescription {
    throw URLError(.unsupportedURL)
  }

  func sessions() async throws -> [DSHSessionSummary] {
    try await call(
      "session/list",
      args: DSHSessionListArgs(_request: DSHSessionListRequest()),
      as: DSHSessionList.self).items
  }

  func searchSessions(query: String) async throws -> DSHSessionSearchResults {
    try await call(
      "session/search",
      args: DSHRequestArgsPayload(request: DSHSessionSearchPayload(query: query)),
      as: DSHSessionSearchResults.self)
  }

  @discardableResult
  func archiveSession(_ sessionId: String) async throws -> [String] {
    try await call(
      "workspace/archiveSession",
      args: DSHRequestArgsPayload(request: DSHArchiveSessionPayload(sessionId: sessionId)),
      as: DSHArchiveSessionResult.self).archivedSessionIds
  }

  @discardableResult
  func unarchiveSession(_ sessionId: String) async throws -> [String] {
    try await call(
      "workspace/unarchiveSession",
      args: DSHRequestArgsPayload(request: DSHArchiveSessionPayload(sessionId: sessionId)),
      as: DSHArchiveSessionResult.self).archivedSessionIds
  }

  func createWorkspace(path: String) async throws -> DSHWorkspaceCreateResult {
    try await call(
      "workspace/create",
      args: DSHRequestArgsPayload(request: DSHWorkspaceCreatePayload(path: path)),
      as: DSHWorkspaceCreateResult.self)
  }

  func renameWorkspace(id: String, title: String) async throws -> DSHWorkspaceView {
    try await call(
      "workspace/rename",
      args: DSHRequestArgsPayload(request: DSHWorkspaceRenamePayload(workspaceId: id, title: title)),
      as: DSHWorkspaceValue.self).workspace
  }

  func deleteWorkspace(id: String) async throws {
    _ = try await call(
      "workspace/delete",
      args: DSHRequestArgsPayload(request: DSHWorkspaceDeletePayload(workspaceId: id)),
      as: DSHWorkspaceDeleteResult.self)
  }

  func sessionModels(sessionId: String) async throws -> DSHSessionModels {
    async let summaries = sessions()
    async let catalog = modelCatalog()
    let (rows, nextCatalog) = try await (summaries, catalog)
    let current = rows.first(where: { $0.sessionId == sessionId })?
      .projections?.values.modelSelection
    return DSHSessionModels(
      current: current?.next ?? current?.lastUsed ?? nextCatalog.default,
      routable: !nextCatalog.groups.isEmpty,
      groups: nextCatalog.groups)
  }

  @discardableResult
  func selectModel(sessionId: String, provider: String, model: String, reasoningEffort: String? = nil) async throws -> DSHSelectedModel {
    try await call(
      "session/selectModel",
      args: DSHRequestArgsPayload(request: DSHSelectModelPayload(sessionId: sessionId, provider: provider, model: model, reasoningEffort: reasoningEffort)),
      as: DSHSelectModelResult.self).selected
  }

  func renameSession(_ sessionId: String, title: String) async throws -> String {
    try await call(
      "session/rename",
      args: DSHRequestArgsPayload(request: DSHRenameSessionPayload(sessionId: sessionId, title: title)),
      as: DSHRenameSessionResult.self).title
  }

  func forkSession(_ sessionId: String) async throws -> String {
    try await call(
      "session/fork",
      args: DSHRequestArgsPayload(request: DSHForkSessionPayload(sessionId: sessionId)),
      as: DSHForkSessionResult.self).sessionId
  }

  func createSession(cwd: String?, agentPreset: String?) async throws -> DSHCreatedSession {
    try await call(
      "session/create",
      args: DSHRequestArgsPayload(request: DSHCreateSessionPayload(cwd: cwd, agentPreset: agentPreset)),
      as: DSHCreatedSession.self)
  }

  func prompt(sessionId: String, content: [DSHPromptContent], mode: DSHPromptMode = .queue) async throws {
    _ = try await call(
      "session/prompt",
      args: DSHRequestArgsPayload(request: DSHPromptPayload(sessionId: sessionId, mode: mode, content: content)),
      as: DSHPromptAccepted.self)
  }

  func attachment(sessionId: String, attachmentId: String) async throws -> DSHAttachmentResult {
    try await call(
      "session/attachment",
      args: DSHRequestArgsPayload(request: DSHAttachmentPayload(sessionId: sessionId, attachmentId: attachmentId)),
      as: DSHAttachmentResult.self)
  }

  func prompt(sessionId: String, text: String, mode: DSHPromptMode = .queue) async throws {
    try await prompt(sessionId: sessionId, content: [.text(text)], mode: mode)
  }

  func cancel(sessionId: String) async throws {
    _ = try await call(
      "session/cancel",
      args: DSHRequestArgsPayload(request: DSHCancelPayload(sessionId: sessionId)),
      as: DSHPromptAccepted.self)
  }

  func openSettingsDocument() async throws {
    _ = try await call("settings/openSettingsDocument", args: EmptyPayload(), as: DSHSettingsOpenResult.self)
  }

  func mutateSettings(ns: String, ops: [DSHSettingsPathOperation], revision: Int) async throws -> DSHSettingsNamespace {
    try await call(
      "settings/mutate",
      args: DSHSettingsMutatePayload(ns: ns, ops: ops, expectedRevision: revision),
      as: DSHSettingsNamespace.self)
  }

  func updateSettings(ns: String, patch: [String: Any], expectedRevision: Int? = nil) async throws -> DSHSettingsNamespace {
    try await call(
      "settings/update",
      args: DSHSettingsUpdatePayload(ns: ns, patch: DSHJSONPatch(values: patch), expectedRevision: expectedRevision),
      as: DSHSettingsNamespace.self)
  }

  func setCredential(ref: String, value: String) async throws {
    _ = try await callOptional(
      "credentials/set",
      args: DSHCredentialSetPayload(ref: ref, value: value),
      as: DSHJSONValue.self)
  }

  func unsetCredential(ref: String) async throws {
    _ = try await callOptional(
      "credentials/unset",
      args: DSHCredentialRefPayload(ref: ref),
      as: DSHJSONValue.self)
  }

  func settings() async throws -> DSHSettingsDescription {
    try await call("settings/describe", args: EmptyPayload(), as: DSHSettingsDescription.self)
  }

  func providers() async throws -> [DSHConfigurableProvider] {
    async let configurable = call(
      "llm/listConfigurableProviders",
      args: EmptyPayload(),
      as: [DSHConfigurableProvider].self)
    async let available = call(
      "llm/listProviders",
      args: EmptyPayload(),
      as: [DSHProviderInfo].self)
    let (routes, live) = try await (configurable, available)
    let active = Set(live.map(\.id))
    return routes.map { route in
      var route = route
      route.active = active.contains(route.provider)
      return route
    }
  }

  func modelCatalog() async throws -> DSHModelCatalog {
    try await call("session/modelCatalog", args: EmptyPayload(), as: DSHModelCatalog.self)
  }

  func models() async throws -> [DSHModelGroup] {
    try await modelCatalog().groups
  }

  func credentials(refs: [String]) async throws -> [String: DSHCredentialView] {
    try await call(
      "credentials/describe",
      args: DSHCredentialRefsPayload(refs: refs),
      as: [String: DSHCredentialView].self)
  }

  func skills(sessionId: String) async throws -> [DSHSkillEntry] {
    try await call(
      "skills/list",
      args: DSHRequestArgsPayload(request: DSHSessionIDPayload(sessionId: sessionId)),
      as: DSHSkillList.self).skills
  }
}

struct EmptyPayload: Codable {}

/// Recursive JSON tree used to encode settings patches. Settings values are
/// arbitrary JSON, so trees from JSONSerialization are wrapped into this value
/// before riding an Encodable RPC payload.
indirect enum DSHJSONPatchValue: Encodable {
  case string(String), number(Double), bool(Bool), object([String: DSHJSONPatchValue]), array([DSHJSONPatchValue]), null

  init?(_ any: Any) {
    switch any {
    case let value as Bool: self = .bool(value)
    case let value as NSNumber: self = .number(value.doubleValue)
    case let value as String: self = .string(value)
    case let value as [String: Any]: self = .object(value.compactMapValues { DSHJSONPatchValue($0) })
    case let value as [Any]: self = .array(value.compactMap { DSHJSONPatchValue($0) })
    case _ as NSNull: self = .null
    default: return nil
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

/// Wraps a JSON object so a settings patch can ride an Encodable payload.
struct DSHJSONPatch: Encodable {
  let values: [String: Any]
  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(DSHJSONPatchValue.object(values.compactMapValues { DSHJSONPatchValue($0) }))
  }
}

struct DSHSettingsUpdatePayload: Encodable {
  let ns: String
  let patch: DSHJSONPatch
  let expectedRevision: Int?
}

/// Starts the packaged DSH Web Host. The native UI consumes its persistent Host
/// protocol instead of launching one headless process per prompt.
final class DSHHostRuntime {
  private static let startupTimeout: TimeInterval = 20

  private let node: URL
  private let dsh: URL
  private let home: URL
  private var process: Process?
  private var output = ""

  init(node: URL, dsh: URL, home: URL) {
    self.node = node
    self.dsh = dsh
    self.home = home
  }

  static func launchArguments(dshPath: String) -> [String] {
    [dshPath, "web", "--host", "127.0.0.1", "--port", "0", "--no-open"]
  }

  func start(onReady: @escaping (Result<DSHHostConnection, Error>) -> Void) {
    guard process == nil else { return }
    let process = Process()
    process.executableURL = node
    process.arguments = Self.launchArguments(dshPath: dsh.path)
    var environment = ProcessInfo.processInfo.environment
    environment["DSH_HOME"] = home.path
    environment["PATH"] = "\(node.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
    process.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    self.process = process

    var resolved = false
    var timeoutItem: DispatchWorkItem?
    let resolve: (Result<DSHHostConnection, Error>) -> Void = { result in
      guard !resolved else { return }
      resolved = true
      timeoutItem?.cancel()
      stdout.fileHandleForReading.readabilityHandler = nil
      onReady(result)
    }
    let timeout = DispatchWorkItem { resolve(.failure(URLError(.timedOut))) }
    timeoutItem = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupTimeout, execute: timeout)

    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = String(decoding: handle.availableData, as: UTF8.self)
      DispatchQueue.main.async {
        guard let self else { return }
        self.output += chunk
        for line in self.output.split(separator: "\n", omittingEmptySubsequences: true) {
          let value = String(line)
          guard value.hasPrefix("dsh web: http://127.0.0.1:"),
                let launch = DSHHostLaunch.parse(launchLine: value) else { continue }
          Task {
            do {
              let cookie = try await DSHHostHandshake.authenticate(launch: launch)
              resolve(.success(DSHHostConnection(launch: launch, cookie: cookie)))
            } catch {
              resolve(.failure(error))
            }
          }
          return
        }
      }
    }
    process.terminationHandler = { ended in
      if ended.terminationStatus != 0 { DispatchQueue.main.async { resolve(.failure(URLError(.cannotConnectToHost))) } }
    }
    do { try process.run() } catch { resolve(.failure(error)) }
  }

  func stop() {
    guard let process, process.isRunning else { return }
    process.terminate()
  }
}
