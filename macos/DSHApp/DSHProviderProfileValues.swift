
extension Dictionary where Key == String, Value == DSHJSONValue {
  func string(_ key: String) -> String? {
    guard case let .string(value)? = self[key] else { return nil }
    return value
  }

  var modelIDs: [String] {
    guard case let .array(values)? = self["models"] else { return [] }
    return values.compactMap { value in
      guard case let .object(model) = value, case let .string(id)? = model["id"] else { return nil }
      return id
    }
  }

  /// The resolved write-only credential reference for an existing profile.
  var apiKeyEnv: String? { string("apiKeyEnv") }
}
