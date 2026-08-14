import Foundation

extension HarnessController {
  func providerCredentialReference(_ provider: DSHConfigurableProvider) -> String? {
    guard let namespace = settingsDescription?.namespaces.first(where: { $0.ns == provider.settingsNs }),
          let profile = namespace.value.objectValue(at: provider.settingsPath) else { return nil }
    return profile.apiKeyEnv
  }
}
