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
  let provider: String
  let model: String
  let attachedSessions: Int
  let canOpenPath: Bool
}

struct DSHSessionSummary: Decodable, Identifiable {
  let sessionId: String
  let updatedAt: Double
  let running: Bool
  let blank: Bool
  let cwd: String?
  let agentPreset: String?
  let parentSessionId: String?
  let origin: String?
  let projections: DSHSessionProjections?
  var id: String { sessionId }
  var title: String { projections?.values.title ?? "新会话" }
}

struct DSHSessionProjections: Decodable {
  let asOfSeq: Int
  let values: DSHSessionProjectionValues
}

struct DSHSessionProjectionValues: Decodable {
  let title: String?
  let todos: [DSHTodoItem]?
  let plan: DSHPlanState?
  let goal: DSHGoalProjection?
  let tokenUsage: DSHTokenUsage?
  let contextPressure: DSHContextPressure?
  let sessionStats: DSHSessionStats?
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

struct DSHPromptPayload: Encodable {
  let sessionId: String
  let mode: String
  let content: [DSHPromptContent]
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

  init(baseURL: URL) {
    self.baseURL = baseURL
    self.session = URLSession(configuration: .default)
  }

  func call<Payload: Encodable, Value: Decodable>(
    _ method: String,
    payload: Payload,
    as valueType: Value.Type,
  ) async throws -> Value {
    let endpoint = baseURL.appendingPathComponent("api/\(method)")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(baseURL.host.map { host in
      baseURL.port.map { "\(host):\($0)" } ?? host
    } ?? "127.0.0.1", forHTTPHeaderField: "Host")
    request.httpBody = try JSONEncoder().encode(DSHRPCEnvelope(rpcId: UUID().uuidString, method: method, payload: payload))
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    let decoded = try JSONDecoder().decode(DSHRPCServerResponse<Value>.self, from: data)
    guard decoded.result.ok, let value = decoded.result.value else {
      throw decoded.result.error ?? URLError(.cannotParseResponse)
    }
    return value
  }

  func openPath(_ path: String) async throws {
    _ = try await call("host.openPath", payload: DSHOpenPathPayload(path: path), as: DSHOpenPathResult.self)
  }

  func describe() async throws -> DSHHostDescription {
    try await call("host.describe", payload: EmptyPayload(), as: DSHHostDescription.self)
  }

  func sessions() async throws -> [DSHSessionSummary] {
    try await call("session.list", payload: EmptyPayload(), as: DSHSessionList.self).items
  }

  func searchSessions(query: String) async throws -> DSHSessionSearchResults {
    try await call("session.search", payload: DSHSessionSearchPayload(query: query), as: DSHSessionSearchResults.self)
  }

  func archiveSession(_ sessionId: String) async throws {
    _ = try await call("workspace.archiveSession", payload: DSHArchiveSessionPayload(sessionId: sessionId), as: DSHArchiveSessionResult.self)
  }

  func createWorkspace(path: String) async throws -> DSHWorkspaceCreateResult {
    try await call("workspace.create", payload: DSHWorkspaceCreatePayload(path: path), as: DSHWorkspaceCreateResult.self)
  }

  func renameWorkspace(id: String, title: String) async throws -> DSHWorkspaceView {
    try await call("workspace.rename", payload: DSHWorkspaceRenamePayload(workspaceId: id, title: title), as: DSHWorkspaceView.self)
  }

  func deleteWorkspace(id: String) async throws {
    _ = try await call("workspace.delete", payload: DSHWorkspaceDeletePayload(workspaceId: id), as: DSHWorkspaceDeleteResult.self)
  }

  func workspaces() async throws -> [DSHWorkspaceView] {
    try await call("workspace.list", payload: EmptyPayload(), as: DSHWorkspaceList.self).items
  }

  func sessionModels(sessionId: String) async throws -> DSHSessionModels {
    try await call("session.models", payload: DSHSessionIDModelPayload(sessionId: sessionId), as: DSHSessionModels.self)
  }

  func selectModel(sessionId: String, provider: String, model: String, reasoningEffort: String? = nil) async throws {
    _ = try await call("session.selectModel", payload: DSHSelectModelPayload(sessionId: sessionId, provider: provider, model: model, reasoningEffort: reasoningEffort), as: DSHSelectModelResult.self)
  }

  func renameSession(_ sessionId: String, title: String) async throws -> String {
    try await call("session.rename", payload: DSHRenameSessionPayload(sessionId: sessionId, title: title), as: DSHRenameSessionResult.self).title
  }

  func forkSession(_ sessionId: String) async throws -> String {
    try await call("session.fork", payload: DSHForkSessionPayload(sessionId: sessionId), as: DSHForkSessionResult.self).sessionId
  }

  func createSession(cwd: String?, agentPreset: String?) async throws -> DSHCreatedSession {
    try await call("session.create", payload: DSHCreateSessionPayload(cwd: cwd, agentPreset: agentPreset), as: DSHCreatedSession.self)
  }

  func prompt(sessionId: String, content: [DSHPromptContent], mode: String = "queue") async throws {
    _ = try await call("session.prompt", payload: DSHPromptPayload(sessionId: sessionId, mode: mode, content: content), as: DSHPromptAccepted.self)
  }

  func attachment(sessionId: String, attachmentId: String) async throws -> DSHAttachmentResult {
    try await call("session.attachment", payload: DSHAttachmentPayload(sessionId: sessionId, attachmentId: attachmentId), as: DSHAttachmentResult.self)
  }

  func prompt(sessionId: String, text: String, mode: String = "queue") async throws {
    try await prompt(sessionId: sessionId, content: [.text(text)], mode: mode)
  }

  func cancel(sessionId: String) async throws {
    _ = try await call("session.cancel", payload: DSHCancelPayload(sessionId: sessionId), as: DSHPromptAccepted.self)
  }

  func openSettingsDocument() async throws {
    _ = try await call("settings.openDocument", payload: EmptyPayload(), as: DSHSettingsOpenResult.self)
  }

  func mutateSettings(ns: String, ops: [DSHSettingsPathOperation], revision: Int) async throws -> DSHSettingsNamespace {
    try await call("settings.mutate", payload: DSHSettingsMutatePayload(ns: ns, ops: ops, expectedRevision: revision), as: DSHSettingsNamespace.self)
  }

  func updateSettings(ns: String, patch: [String: Any], expectedRevision: Int? = nil) async throws -> DSHSettingsNamespace {
    try await call("settings.update", payload: DSHSettingsUpdatePayload(ns: ns, patch: DSHJSONPatch(values: patch), expectedRevision: expectedRevision), as: DSHSettingsNamespace.self)
  }

  func setCredential(ref: String, value: String) async throws {
    _ = try await call("credentials.set", payload: DSHCredentialSetPayload(ref: ref, value: value), as: DSHEMPTY.self)
  }

  func unsetCredential(ref: String) async throws {
    _ = try await call("credentials.unset", payload: DSHCredentialRefPayload(ref: ref), as: DSHEMPTY.self)
  }

  func settings() async throws -> DSHSettingsDescription {
    try await call("settings.describe", payload: EmptyPayload(), as: DSHSettingsDescription.self)
  }

  func providers() async throws -> [DSHConfigurableProvider] {
    try await call("llm.providers", payload: EmptyPayload(), as: DSHProviderList.self).providers
  }

  func models() async throws -> [DSHModelGroup] {
    try await call("llm.models", payload: EmptyPayload(), as: DSHModelCatalog.self).groups
  }

  func credentials(refs: [String]) async throws -> [String: DSHCredentialView] {
    try await call("credentials.describe", payload: DSHCredentialRefsPayload(refs: refs), as: DSHCredentialCatalog.self).credentials
  }

  func skills(sessionId: String) async throws -> [DSHSkillEntry] {
    try await call("skill.list", payload: DSHSessionIDPayload(sessionId: sessionId), as: DSHSkillList.self).skills
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

  func start(onReady: @escaping (Result<URL, Error>) -> Void) {
    guard process == nil else { return }
    let process = Process()
    process.executableURL = node
    process.arguments = [dsh.path, "web", "--host", "127.0.0.1", "--port", "0"]
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
    let resolve: (Result<URL, Error>) -> Void = { result in
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
          guard value.hasPrefix("dsh web: http://127.0.0.1:"), let url = URL(string: String(value.dropFirst("dsh web: ".count))) else { continue }
          resolve(.success(url))
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
