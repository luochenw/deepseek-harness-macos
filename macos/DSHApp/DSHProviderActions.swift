import Foundation

extension HarnessController {
  /// Refreshes the Host-owned provider directory, redacted settings views, and
  /// credential badges in one snapshot. Credential values never enter app state.
  func refreshProviderConfiguration() {
    guard let hostClient else { return }
    Task {
      do {
        async let providersTask = hostClient.providers()
        async let settingsTask = hostClient.settings()
        let (providers, settings) = try await (providersTask, settingsTask)
        let refs = Self.credentialRefs(providers: providers, settings: settings)
        let credentials = try await hostClient.credentials(refs: refs)
        await MainActor.run {
          self.configurableProviders = providers
          self.settingsDescription = settings
          self.credentialStates = credentials
        }
      } catch {
        await MainActor.run { self.status = "提供方配置读取失败：\(error.localizedDescription)" }
      }
    }
  }

  /// Store profile fields through revisioned path operations, then separately
  /// send a nonempty credential through the write-only credentials API.
  func saveProviderProfile(
    namespace: DSHSettingsNamespace,
    path: [String],
    profile: [String: DSHJSONPatchValue],
    credentialRef: String?,
    credentialValue: String,
    completion: @escaping (Result<Void, Error>) -> Void,
  ) {
    guard let hostClient else { completion(.failure(NSError(domain: "DSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "Host 未连接"]))); return }
    // The editor owns this complete profile representation. Writing the profile
    // at its directory path avoids leaving fields from an older draft behind.
    let ops = [DSHSettingsPathOperation.set(path, .object(profile))]
    Task {
      do {
        let updated = try await hostClient.mutateSettings(ns: namespace.ns, ops: ops, revision: namespace.revision)
        if let credentialRef, !credentialValue.isEmpty {
          try await hostClient.setCredential(ref: credentialRef, value: credentialValue)
        }
        await MainActor.run {
          if var settings = self.settingsDescription, let index = settings.namespaces.firstIndex(where: { $0.ns == updated.ns }) {
            settings.namespaces[index] = updated
            self.settingsDescription = settings
          }
          self.status = "提供方已保存"
          self.showProviderAuthoring = false
          completion(.success(()))
          self.refreshProviderConfiguration()
        }
      } catch {
        await MainActor.run {
          if let rpc = error as? DSHRPCError, rpc.code == "settings-conflict" {
            self.status = "设置已被其他客户端修改；已重新载入，请重新应用更改。"
            self.refreshProviderConfiguration()
            completion(.failure(NSError(domain: "DSH", code: 2, userInfo: [NSLocalizedDescriptionKey: "设置冲突：请在最新配置上重新编辑。"])))
          } else {
            completion(.failure(error))
          }
        }
      }
    }
  }

  private static func credentialRefs(providers: [DSHConfigurableProvider], settings: DSHSettingsDescription) -> [String] {
    let namespaces = Dictionary(uniqueKeysWithValues: settings.namespaces.map { ($0.ns, $0) })
    let refs = providers.compactMap { provider -> String? in
      guard let namespace = namespaces[provider.settingsNs],
            let profile = namespace.value.providerProfile(at: provider.settingsPath),
            case let .string(ref)? = profile["apiKeyEnv"], !ref.isEmpty else { return nil }
      return ref
    }
    return Array(Set(refs)).sorted()
  }
}

private extension DSHJSONValue {
  func providerProfile(at path: [String]) -> [String: DSHJSONValue]? {
    var current = self
    for key in path {
      guard case let .object(object) = current, let next = object[key] else { return nil }
      current = next
    }
    guard case let .object(object) = current else { return nil }
    return object
  }
}
