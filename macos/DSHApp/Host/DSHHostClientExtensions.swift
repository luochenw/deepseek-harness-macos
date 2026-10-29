import Foundation

extension DSHHostClient {
  func presets() async throws -> [DSHAgentPreset] { try await presetCatalog().presets }
  func selectPreset(sessionId: String, preset: String) async throws {
    _ = try await call(
      "agentPresets/select",
      args: DSHSelectPresetArgs(agentId: sessionId, agentPreset: preset),
      as: String.self)
  }
  func subagents(parentSessionId: String) async throws -> DSHSubagentCatalog {
    DSHSubagentCatalog(entries: try await subagentEntries(sessionId: parentSessionId), parentAvailable: true)
  }
  func promptSubagent(parentSessionId: String, childSessionId: String, content: [DSHPromptContent]) async throws {
    let payload = DSHSubagentPromptPayload(
      requestId: UUID().uuidString,
      parentSessionId: parentSessionId,
      childSessionId: childSessionId,
      mode: "continuable",
      delivery: "queue",
      content: content)
    _ = try await call(
      "subagents/prompt",
      args: DSHRequestArgsPayload(request: payload),
      as: DSHSubagentPromptReceipt.self)
  }
  func interruptSubagent(parentSessionId: String, childSessionId: String) async throws {
    _ = try await call(
      "subagents/interruptByParent",
      args: DSHSubagentInterruptArgs(
        childSessionId: childSessionId,
        parentSessionId: parentSessionId,
        mode: "continuable"),
      as: DSHSubagentInterruptReceipt.self)
  }
  func goalAction(_ action: String, sessionId: String, goalId: String, revision: Int) async throws {
    let payload = DSHGoalActionPayload(agentId: sessionId, ref: DSHGoalRef(id: goalId, revision: revision))
    _ = try await call("goals/\(action)", args: payload, as: DSHGoalRef.self)
  }
  func updateQueue(sessionId: String, itemId: String, action: DSHQueueAction) async throws {
    _ = try await call(
      "session/updateQueue",
      args: DSHRequestArgsPayload(request: DSHQueueActionPayload(sessionId: sessionId, itemId: itemId, action: action)),
      as: DSHQueueMutationResult.self)
  }
}
