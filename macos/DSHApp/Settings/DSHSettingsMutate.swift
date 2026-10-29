import Foundation

struct DSHSettingsOpenResult: Decodable { let opened: Bool }

/// One minimal, path-addressed mutation against a stored namespace.
enum DSHSettingsPathOperation: Encodable {
  case set(path: [String], value: DSHJSONPatchValue)
  case unset(path: [String])

  static func set(_ path: [String], _ value: DSHJSONPatchValue) -> Self { .set(path: path, value: value) }
  static func unset(_ path: [String]) -> Self { .unset(path: path) }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .set(path, value):
      try container.encode("set", forKey: .op)
      try container.encode(path, forKey: .path)
      try container.encode(value, forKey: .value)
    case let .unset(path):
      try container.encode("unset", forKey: .op)
      try container.encode(path, forKey: .path)
    }
  }

  private enum CodingKeys: String, CodingKey { case op, path, value }
}

struct DSHSettingsMutatePayload: Encodable {
  let ns: String
  let ops: [DSHSettingsPathOperation]
  /// Native forms always send the read revision, preventing stale overwrite.
  let expectedRevision: Int
}
