import Foundation

/// Wire types for the Host's live session-projection values (pushed as
/// `session/projection` mux frames and seeded from the session-list /
/// history-tail projections block). Shapes mirror the upstream
/// `dsh-token-meter` and `dsh-session-stats` projection vocabularies.
struct DSHTokenUsage: Decodable {
  let uncachedInputTokens: Int
  let outputTokens: Int
  let cacheReadTokens: Int
  let cacheWriteTokens: Int
  var totalInputTokens: Int { uncachedInputTokens + cacheReadTokens + cacheWriteTokens }
}

struct DSHContextPressure: Decodable {
  let pressureTokens: Int?
  let projectedTokens: Int?
  let contextWindow: Int?
}

struct DSHSessionStats: Decodable {
  let turns: Int
  let steps: Int
  let llmMs: Double
  let toolMs: Double
}

enum DSHProjectionDecoder {
  /// Projection frame values arrive as untyped JSON objects; round-trip
  /// through JSONSerialization into the typed wire structs.
  static func decode<T: Decodable>(_ type: T.Type, from value: Any) -> T? {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }
}

extension HarnessController {
  /// Applies one live `session/projection` frame for the currently open
  /// session — the push channel that keeps the title, dashboard cards, and
  /// the composer status strip current between history refetches.
  func applyProjection(key: String, value: Any) {
    switch key {
    case "title":
      if let title = value as? String { applyProjectedTitle(title) }
    case "todos":
      if let items = value as? [[String: Any]] {
        todos = items.compactMap { item in
          guard let content = item["content"] as? String, let status = item["status"] as? String else { return nil }
          return DSHTodoItem(content: content, status: status)
        }
      }
    case "plan":
      if let object = value as? [String: Any], let active = object["active"] as? Bool { hostPlanActive = active }
    case "goal":
      if let projection = DSHProjectionDecoder.decode(DSHGoalProjection.self, from: value) { goal = projection }
    case "tokenUsage":
      if let usage = DSHProjectionDecoder.decode(DSHTokenUsage.self, from: value) { tokenUsage = usage }
    case "contextPressure":
      if let pressure = DSHProjectionDecoder.decode(DSHContextPressure.self, from: value) { contextPressure = pressure }
    case "sessionStats":
      if let stats = DSHProjectionDecoder.decode(DSHSessionStats.self, from: value) { sessionStats = stats }
    case "agent-platform/batches":
      applyAgentBatchProjection(value)
    default:
      break
    }
  }
}
