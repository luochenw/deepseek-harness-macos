import Foundation

extension HarnessController {
  func providerCredentialReference(_ provider: DSHConfigurableProvider) -> String? {
    guard let namespace = settingsDescription?.namespaces.first(where: { $0.ns == provider.settingsNs }),
          let profile = namespace.value.objectValue(at: provider.settingsPath) else { return nil }
    return profile.apiKeyEnv
  }

  static func credentialReferences(in settings: DSHSettingsDescription) -> [String] {
    Array(Set(settings.namespaces.flatMap { $0.value.credentialReferences() })).sorted()
  }

  static func llmCredentialReferences(in settings: DSHSettingsDescription) -> [String] {
    Array(Set(
      settings.namespaces
        .filter { $0.ns.hasPrefix("llm-") }
        .flatMap { $0.value.credentialReferences() }
    )).sorted()
  }
}

extension DSHJSONValue {
  func credentialReferences() -> [String] {
    switch self {
    case .string, .number, .bool, .null:
      return []
    case .array(let values):
      return values.flatMap { $0.credentialReferences() }
    case .object(let values):
      let ownReference: [String]
      if case let .string(value)? = values["apiKeyEnv"],
         !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        ownReference = [value]
      } else {
        ownReference = []
      }
      return ownReference + values.values.flatMap { $0.credentialReferences() }
    }
  }
}
