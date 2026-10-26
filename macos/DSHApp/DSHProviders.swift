import Foundation
struct DSHConfigurableProvider: Decodable, Identifiable {
  let provider: String
  let displayName: String
  let settingsNs: String
  let settingsPath: [String]
  var active = false
  /// True only when the adapter knows this route was declared in settings.
  /// Absence is intentionally unknown, not a shipped-route classification.
  let declared: Bool?
  var id: String { provider }

  private enum CodingKeys: String, CodingKey {
    case provider, displayName, settingsNs, settingsPath, active, declared
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(String.self, forKey: .provider)
    displayName = try container.decode(String.self, forKey: .displayName)
    settingsNs = try container.decode(String.self, forKey: .settingsNs)
    settingsPath = try container.decode([String].self, forKey: .settingsPath)
    active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
    declared = try container.decodeIfPresent(Bool.self, forKey: .declared)
  }
}
struct DSHProviderInfo: Decodable, Identifiable {
  let id: String
  let name: String?
}

enum DSHProviderClassification {
  static func customProviderIDs(from providers: [DSHConfigurableProvider]) -> Set<String> {
    Set(providers
      .filter { $0.settingsNs == "llm-pi-ai" && $0.declared != false }
      .map(\.provider))
  }
}
