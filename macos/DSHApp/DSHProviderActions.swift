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

  /// Store profile fields through the shared revisioned mutation path
  /// (`mutateSettings`, including its conflict handling), then separately send
  /// a nonempty credential through the write-only credentials API.
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
    mutateSettings(
      ns: namespace.ns,
      ops: [DSHSettingsPathOperation.set(path, .object(profile))],
      revision: namespace.revision,
      success: { _ in
        Task {
          do {
            if let credentialRef, !credentialValue.isEmpty {
              try await hostClient.setCredential(ref: credentialRef, value: credentialValue)
            }
            await MainActor.run {
              self.status = "提供方已保存"
              self.showProviderAuthoring = false
              completion(.success(()))
              self.refreshProviderConfiguration()
            }
          } catch {
            await MainActor.run { completion(.failure(error)) }
          }
        }
      },
      conflict: {
        self.refreshProviderConfiguration()
        completion(.failure(NSError(domain: "DSH", code: 2, userInfo: [NSLocalizedDescriptionKey: "设置冲突：请在最新配置上重新编辑。"])))
      },
      failure: { error in completion(.failure(error)) }
    )
  }

  private static func credentialRefs(providers: [DSHConfigurableProvider], settings: DSHSettingsDescription) -> [String] {
    let namespaces = Dictionary(uniqueKeysWithValues: settings.namespaces.map { ($0.ns, $0) })
    let refs = providers.compactMap { provider -> String? in
      guard let namespace = namespaces[provider.settingsNs],
            let profile = namespace.value.objectValue(at: provider.settingsPath),
            let ref = profile.apiKeyEnv, !ref.isEmpty else { return nil }
      return ref
    }
    // LOCAL_RELAY_API_KEY/RELAY_API_KEY/DEEPSEEK_API_KEY are the built-in
    // default route's credential refs. No provider profile references them
    // explicitly, so without hardcoding them here the default route's
    // credential-configured badge never lights up in the UI.
    return Array(Set(refs + ["LOCAL_RELAY_API_KEY", "RELAY_API_KEY", "DEEPSEEK_API_KEY"])).sorted()
  }
}
