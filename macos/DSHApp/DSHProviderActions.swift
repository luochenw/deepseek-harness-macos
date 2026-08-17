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
        let refs = Self.credentialReferences(in: settings)
        let credentials = try await hostClient.credentials(refs: refs)
        await MainActor.run {
          self.configurableProviders = providers
          self.settingsDescription = settings
          self.credentialStates = credentials
        }
      } catch {
        await MainActor.run { self.status = "自定义配置读取失败：\(error.localizedDescription)" }
      }
    }
  }

  /// Store profile fields through the shared revisioned mutation path
  /// (`mutateSettings`, including its conflict handling), then separately send
  /// a nonempty credential through the write-only credentials API.
  func saveProviderProfile(
    namespace: DSHSettingsNamespace,
    ops: [DSHSettingsPathOperation],
    credentialRef: String?,
    credentialValue: String,
    completion: @escaping (Result<Void, Error>) -> Void,
  ) {
    guard let hostClient else { completion(.failure(NSError(domain: "DSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "Host 未连接"]))); return }
    let finish: () -> Void = {
      self.status = "自定义配置已保存"
      self.showProviderAuthoring = false
      completion(.success(()))
      self.refreshModelConfiguration()
    }
    let writeCredential: () -> Void = {
      Task {
        do {
          if let credentialRef, !credentialValue.isEmpty {
            try await hostClient.setCredential(ref: credentialRef, value: credentialValue)
          }
          await MainActor.run { finish() }
        } catch {
          await MainActor.run { completion(.failure(error)) }
        }
      }
    }

    guard !ops.isEmpty else {
      writeCredential()
      return
    }

    mutateSettings(
      ns: namespace.ns,
      ops: ops,
      revision: namespace.revision,
      success: { _ in
        writeCredential()
      },
      conflict: {
        self.refreshProviderConfiguration()
        completion(.failure(NSError(domain: "DSH", code: 2, userInfo: [NSLocalizedDescriptionKey: "设置冲突：请在最新配置上重新编辑。"])))
      },
      failure: { error in completion(.failure(error)) }
    )
  }

}
