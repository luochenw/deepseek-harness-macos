import Foundation

struct DSHSettingsSecret: Decodable, Identifiable {
  let path: [String]
  let set: Bool
  var id: String { path.joined(separator: ".") }
}

/// A redacted, revisioned Host settings namespace. `value`, `base`, and `user`
/// never contain secret values; secret state is represented by `secrets`.
struct DSHSettingsNamespace: Decodable, Identifiable {
  let ns: String
  let schema: DSHJSONValue?
  let value: DSHJSONValue
  let base: DSHJSONValue?
  let user: DSHJSONValue?
  let applies: String
  let secrets: [DSHSettingsSecret]
  let revision: Int
  var id: String { ns }
}
struct DSHSettingsDescription: Decodable {
  let writable: Bool
  let hasDocument: Bool
  var namespaces: [DSHSettingsNamespace]
}
