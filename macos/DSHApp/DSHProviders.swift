import Foundation
struct DSHConfigurableProvider: Decodable, Identifiable {
  let provider: String
  let displayName: String
  let settingsNs: String
  let settingsPath: [String]
  let active: Bool
  /// True only when the adapter knows this route was declared in settings.
  /// Absence is intentionally unknown, not a shipped-route classification.
  let declared: Bool?
  var id: String { provider }
}
struct DSHProviderList: Decodable { let providers: [DSHConfigurableProvider] }
