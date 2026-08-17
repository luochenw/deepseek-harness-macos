import Foundation

/// Typert Gateway client — the Host's second RPC surface.
///
/// The Gateway (`@deepseek-ai/dsh-api-gateway`) intercepts the shared `/api`
/// channel for every two-segment `<namespace>/<method>` endpoint (legacy
/// dot-named methods fall through to the API proxy). The HTTP carrier is the
/// same client-request envelope as the legacy surface (`rpcFetchHandler` in
/// `dsh-client-connection`): POST `api/<namespace>/<method>` with
/// `{type: "client-request", rpcId, method: "<namespace>/<method>", payload}`,
/// answered by `{type: "server-response", rpcId, result}`.
///
/// The Gateway additionally requires the payload to be exactly one plain
/// object field `args` (`invokeRpc` rejects anything else), and its result is
/// `{ok: true, value}` or `{ok: false, error: {code, message, details}}`.
/// `value` may be legitimately absent when the business method returned
/// `undefined` (e.g. `commands/execute` on an unresolvable line), so this
/// client decodes it as optional instead of reusing the legacy `call(...)`.
/// Host-header trust is identical to the legacy surface: loopback origin
/// plus a loopback `Host` header.

// MARK: - Gateway wire plumbing

/// The mandatory single-field payload shape: `{"args": {...}}`.
struct DSHTypertArgsEnvelope<Args: Encodable>: Encodable {
  let args: Args
}

/// Gateway failure envelope (`rpcFailure`): dispatch failures and the agent
/// lookup adapter both produce `{code, message, details}`, but lookup-policy
/// failures keep an adapter-owned shape, so both fields decode leniently.
struct DSHTypertGatewayError: Decodable, Error, LocalizedError {
  let code: String?
  let message: String?

  init(code: String?, message: String?) {
    self.code = code
    self.message = message
  }

  var errorDescription: String? {
    switch (code, message) {
    case (let code?, let message?): return "\(code): \(message)"
    case (let code?, nil): return code
    case (nil, let message?): return message
    case (nil, nil): return "typert gateway: unknown failure"
    }
  }
}

/// Server response for a Gateway endpoint. Unlike `DSHRPCServerResponse`,
/// `value` staying `nil` while `ok` is true is a valid business outcome.
struct DSHTypertServerResponse<Value: Decodable>: Decodable {
  struct Result: Decodable {
    let ok: Bool
    let value: Value?
    let error: DSHTypertGatewayError?
  }
  let result: Result
}

extension DSHHostClient {
  /// Invoke one Typert Gateway endpoint whose value may be absent on success.
  /// Uses `URLSession.shared` because actor extensions cannot add stored state
  /// and the request shape needs nothing beyond the default configuration.
  func invokeOptional<Args: Encodable, Value: Decodable>(
    ns: String,
    method: String,
    args: Args,
    as valueType: Value.Type,
  ) async throws -> Value? {
    let endpoint = "\(ns)/\(method)"
    var request = URLRequest(url: baseURL.appendingPathComponent("api/\(endpoint)"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(baseURL.host.map { host in
      baseURL.port.map { "\(host):\($0)" } ?? host
    } ?? "127.0.0.1", forHTTPHeaderField: "Host")
    request.httpBody = try JSONEncoder().encode(
      DSHRPCEnvelope(rpcId: UUID().uuidString, method: endpoint, payload: DSHTypertArgsEnvelope(args: args)))
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    let decoded = try JSONDecoder().decode(DSHTypertServerResponse<Value>.self, from: data)
    guard decoded.result.ok else {
      throw decoded.result.error ?? DSHTypertGatewayError(code: "internal", message: "\(endpoint) failed without an error envelope")
    }
    return decoded.result.value
  }

  /// Invoke one Typert Gateway endpoint whose value must be present.
  func invoke<Args: Encodable, Value: Decodable>(
    ns: String,
    method: String,
    args: Args,
    as valueType: Value.Type,
  ) async throws -> Value {
    guard let value = try await invokeOptional(ns: ns, method: method, args: args, as: valueType) else {
      throw DSHTypertGatewayError(code: "value-missing", message: "\(ns)/\(method) returned ok without a value")
    }
    return value
  }
}

// MARK: - commands/* (@deepseek-ai/dsh-commands)

/// One roster entry from `commands/list`: `{name, description, input?: {hint}}`.
struct DSHCommandDescriptor: Decodable, Identifiable {
  struct Input: Decodable { let hint: String }
  let name: String
  let description: String
  let input: Input?
  var id: String { name }
}

/// Settled execution from `commands/execute`:
/// `{commandId, result: {kind: "success", text?, sourceEventSeq?} | {kind: "error", text}}`.
struct DSHCommandExecution: Decodable {
  struct Outcome: Decodable {
    let kind: String
    let text: String?
    let sourceEventSeq: Int?
  }
  let commandId: String
  let result: Outcome

  var succeeded: Bool { result.kind == "success" }
}

struct DSHCommandListArgs: Encodable { let agentId: String }
struct DSHCommandExecuteArgs: Encodable {
  let agentId: String
  let line: String
}

extension DSHHostClient {
  /// List the effective slash commands for one session's agent.
  func listCommands(sessionId: String) async throws -> [DSHCommandDescriptor] {
    try await invoke(ns: "commands", method: "list", args: DSHCommandListArgs(agentId: sessionId), as: [DSHCommandDescriptor].self)
  }

  /// Execute one complete slash-command line without sending it to the model.
  /// Returns nil when syntax or name does not resolve to a known command
  /// (the Host answers `undefined`, so the caller should fall back to
  /// treating the line as an ordinary prompt).
  func executeCommand(sessionId: String, line: String) async throws -> DSHCommandExecution? {
    try await invokeOptional(ns: "commands", method: "execute", args: DSHCommandExecuteArgs(agentId: sessionId, line: line), as: DSHCommandExecution.self)
  }
}

// MARK: - messageFeedback/* (@deepseek-ai/dsh-message-feedback)

/// One stored feedback row: per-message rating plus optional note, versioned
/// for optimistic concurrency.
struct DSHMessageFeedbackItem: Decodable, Identifiable {
  let messageId: String
  let rating: String
  let note: String?
  let version: String
  let createdAt: Double
  let updatedAt: Double
  var id: String { messageId }
}

/// Business failure from the feedback service. Codes: `session-not-found`
/// (+sessionId), `target-not-found` (+sessionId, messageId),
/// `version-conflict` (+current, null when the row is gone), `note-blank`,
/// `note-too-large` (+maxBytes, actualBytes).
struct DSHMessageFeedbackFailure: Decodable, Error, LocalizedError {
  let code: String
  let sessionId: String?
  let messageId: String?
  let current: DSHMessageFeedbackItem?
  let maxBytes: Int?
  let actualBytes: Int?
  var errorDescription: String? { "message feedback: \(code)" }
}

/// The feedback service wraps every result in its own business envelope
/// (`{ok: true, value} | {ok: false, error}`) nested inside the Gateway
/// `value`, so a successful RPC can still carry a typed business failure.
struct DSHMessageFeedbackOutcome<Value: Decodable>: Decodable {
  let ok: Bool
  let value: Value?
  let error: DSHMessageFeedbackFailure?
}

struct DSHMessageFeedbackListValue: Decodable { let items: [DSHMessageFeedbackItem] }
struct DSHMessageFeedbackAbsent: Decodable { let absent: Bool }

/// All three endpoints take a single wire field `request`.
struct DSHMessageFeedbackRequestArgs<Request: Encodable>: Encodable {
  let request: Request
}

struct DSHMessageFeedbackListRequest: Encodable { let sessionId: String }

/// Put request. `ifVersion` must be present on the wire even when null
/// (`null` means "create; fail if feedback already exists"), so encoding is
/// explicit instead of the synthesized nil-dropping conformance.
struct DSHMessageFeedbackPutRequest: Encodable {
  let sessionId: String
  let messageId: String
  let rating: String
  let note: String?
  let ifVersion: String?

  private enum CodingKeys: String, CodingKey {
    case sessionId, messageId, rating, note, ifVersion
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(messageId, forKey: .messageId)
    try container.encode(rating, forKey: .rating)
    try container.encodeIfPresent(note, forKey: .note)
    if let ifVersion {
      try container.encode(ifVersion, forKey: .ifVersion)
    } else {
      try container.encodeNil(forKey: .ifVersion)
    }
  }
}

struct DSHMessageFeedbackDeleteRequest: Encodable {
  let sessionId: String
  let messageId: String
  let ifVersion: String
}

/// Unwrap the nested business envelope, surfacing failures as thrown
/// `DSHMessageFeedbackFailure` so call sites keep one error path.
private func unwrapFeedbackOutcome<Value: Decodable>(_ outcome: DSHMessageFeedbackOutcome<Value>) throws -> Value {
  guard outcome.ok, let value = outcome.value else {
    throw outcome.error ?? DSHMessageFeedbackFailure(code: "internal", sessionId: nil, messageId: nil, current: nil, maxBytes: nil, actualBytes: nil)
  }
  return value
}

extension DSHHostClient {
  /// List feedback for the current persisted lifecycle of one session.
  func messageFeedback(sessionId: String) async throws -> [DSHMessageFeedbackItem] {
    let outcome = try await invoke(
      ns: "messageFeedback",
      method: "list",
      args: DSHMessageFeedbackRequestArgs(request: DSHMessageFeedbackListRequest(sessionId: sessionId)),
      as: DSHMessageFeedbackOutcome<DSHMessageFeedbackListValue>.self)
    return try unwrapFeedbackOutcome(outcome).items
  }

  /// Create or replace feedback for one assistant message. Pass the observed
  /// item version as `ifVersion` when replacing; nil creates a fresh row.
  /// Rating is `positive` or `negative`; a whitespace-only note is rejected.
  func putMessageFeedback(
    sessionId: String,
    messageId: String,
    rating: String,
    note: String? = nil,
    ifVersion: String? = nil,
  ) async throws -> DSHMessageFeedbackItem {
    let request = DSHMessageFeedbackPutRequest(sessionId: sessionId, messageId: messageId, rating: rating, note: note, ifVersion: ifVersion)
    let outcome = try await invoke(
      ns: "messageFeedback",
      method: "put",
      args: DSHMessageFeedbackRequestArgs(request: request),
      as: DSHMessageFeedbackOutcome<DSHMessageFeedbackItem>.self)
    return try unwrapFeedbackOutcome(outcome)
  }

  /// Delete one feedback item. An existing item requires its exact version;
  /// absence is already the successful postcondition.
  func deleteMessageFeedback(sessionId: String, messageId: String, ifVersion: String) async throws {
    let request = DSHMessageFeedbackDeleteRequest(sessionId: sessionId, messageId: messageId, ifVersion: ifVersion)
    let outcome = try await invoke(
      ns: "messageFeedback",
      method: "delete",
      args: DSHMessageFeedbackRequestArgs(request: request),
      as: DSHMessageFeedbackOutcome<DSHMessageFeedbackAbsent>.self)
    _ = try unwrapFeedbackOutcome(outcome)
  }
}

// MARK: - pluginInventory/* (@deepseek-ai/dsh-host-plugin-inventory)

/// One inventory row: configured module plus its live fiber phase.
/// `fiberPhase` is nil for a configured-but-not-instantiated entry, otherwise
/// `failed` | `pending` | `active` | `loading` | `unloading`.
struct DSHPluginInventoryEntry: Decodable, Identifiable {
  let entryId: String
  let moduleName: String
  let enabled: Bool
  let fiberPhase: String?
  var id: String { entryId }
}

struct DSHPluginInventorySnapshot: Decodable { let entries: [DSHPluginInventoryEntry] }

extension DSHHostClient {
  /// Snapshot the Host's plugin inventory. Takes no arguments beyond the
  /// mandatory empty `args` object.
  func pluginInventory() async throws -> [DSHPluginInventoryEntry] {
    try await invoke(ns: "pluginInventory", method: "list", args: EmptyPayload(), as: DSHPluginInventorySnapshot.self).entries
  }
}
