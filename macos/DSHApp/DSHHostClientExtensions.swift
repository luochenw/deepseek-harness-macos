import Foundation

extension DSHHostClient {
  func presets() async throws -> [DSHAgentPreset] { try await call("agentPreset.list", payload: EmptyPayload(), as: DSHAgentPresetList.self).presets }
  func selectPreset(sessionId: String, preset: String) async throws { _ = try await call("agentPreset.select", payload: DSHSelectPresetPayload(sessionId: sessionId, agentPreset: preset), as: DSHSelectPresetResult.self) }
  func subagents(parentSessionId: String) async throws -> DSHSubagentCatalog { try await call("subagent.list", payload: DSHSubagentListPayload(parentSessionId: parentSessionId), as: DSHSubagentCatalog.self) }
  func promptSubagent(parentSessionId: String, childSessionId: String, content: [DSHPromptContent]) async throws {
    let payload = DSHSubagentPromptPayload(parentSessionId: parentSessionId, childSessionId: childSessionId, mode: "continuable", content: content)
    _ = try await call("subagent.prompt", payload: payload, as: DSHSubagentPromptReceipt.self)
  }
  func subagentHistory(parentSessionId: String, childSessionId: String, mode: String) async throws -> DSHHistoryPage { try await call("subagent.history", payload: DSHSubagentHistoryPayload(parentSessionId: parentSessionId, childSessionId: childSessionId, mode: mode, maxMessages: 100), as: DSHHistoryPage.self) }
  func interruptSubagent(parentSessionId: String, childSessionId: String) async throws { _ = try await call("subagent.interrupt", payload: DSHSubagentAddress(parentSessionId: parentSessionId, childSessionId: childSessionId, mode: "continuable"), as: DSHSubagentInterruptReceipt.self) }
  func goalAction(_ action: String, sessionId: String, goalId: String, revision: Int) async throws {
    let payload = DSHGoalActionPayload(sessionId: sessionId, ref: DSHGoalRef(id: goalId, revision: revision))
    _ = try await call("goal.\(action)", payload: payload, as: DSHGoalActionResult.self)
  }
  func updateQueue(sessionId: String, itemId: String, action: DSHQueueAction) async throws {
    _ = try await call("session.updateQueue", payload: DSHQueueActionPayload(sessionId: sessionId, itemId: itemId, action: action), as: DSHQueueMutationResult.self)
  }
  func history(sessionId: String, beforeSeq: Int? = nil, maxMessages: Int = 100) async throws -> DSHHistoryPage { try await call("session.history", payload: DSHHistoryPayload(sessionId: sessionId, beforeSeq: beforeSeq, maxMessages: maxMessages), as: DSHHistoryPage.self) }
  func respond<Value: Encodable>(rpcId: String, value: Value) async throws {
    var request = URLRequest(url: baseURL.appendingPathComponent("api/respond"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(DSHClientResponse(rpcId: rpcId, result: DSHClientResponseResult(value: value)))
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
  }
}