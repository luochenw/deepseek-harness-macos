import Foundation

extension HarnessController {
  func openHostSettingsDocument() {
    guard let hostClient else { return }
    Task {
      do {
        try await hostClient.openSettingsDocument()
        await MainActor.run { self.status = "已请求 Host 打开配置文件" }
      } catch {
        await MainActor.run { self.status = "打开配置文件失败" }
      }
    }
  }

  /// Commit minimal revisioned operations and retain the Host-returned revision.
  func mutateSettings(
    ns: String,
    ops: [DSHSettingsPathOperation],
    revision: Int,
    success: @escaping (DSHSettingsNamespace) -> Void = { _ in },
    conflict: @escaping () -> Void = {},
    failure: @escaping (Error) -> Void = { _ in }
  ) {
    guard let hostClient else { return }
    Task {
      do {
        let updated = try await hostClient.mutateSettings(ns: ns, ops: ops, revision: revision)
        await MainActor.run {
          if var settings = self.settingsDescription, let index = settings.namespaces.firstIndex(where: { $0.ns == ns }) {
            settings.namespaces[index] = updated
            self.settingsDescription = settings
          }
          self.status = "设置已保存"
          success(updated)
        }
      } catch {
        await MainActor.run {
          if let rpc = error as? DSHRPCError, rpc.code == "settings-conflict" {
            self.status = "设置已被其他客户端修改。请重新载入最新配置后再重试。"
            conflict()
          } else {
            self.status = "设置保存失败：\(error.localizedDescription)"
            failure(error)
          }
        }
      }
    }
  }
}

extension HarnessController {
  func openProviderAuthoring(_ provider: DSHConfigurableProvider? = nil) {
    selectedProviderForAuthoring = provider
    showProviderAuthoring = true
  }

  func openSettingsEditor(ns: DSHSettingsNamespace) {
    selectedSettingsNamespace = ns
    showSettingsEditor = true
  }

  func saveSettings(ns: String, patch: [String: Any], revision: Int, conflict: @escaping () -> Void = {}) {
    guard let patchValue = DSHJSONPatchValue(patch) else {
      status = "设置格式无效"
      return
    }
    mutateSettings(
      ns: ns,
      ops: [DSHSettingsPathOperation.set(path: [], value: patchValue)],
      revision: revision,
      success: { _ in self.showSettingsEditor = false },
      conflict: conflict
    )
  }

  func saveCredential(ref: String, value: String) { guard let hostClient else { return }; Task { do { try await hostClient.setCredential(ref: ref, value: value); await MainActor.run { self.status = "凭据已保存"; self.refreshModelConfiguration() } } catch { await MainActor.run { self.status = "凭据保存失败：\(error.localizedDescription)" } } } }
  func unsetCredential(ref: String) { guard let hostClient else { return }; Task { do { try await hostClient.unsetCredential(ref: ref); await MainActor.run { self.status = "凭据已清除"; self.refreshModelConfiguration() } } catch { await MainActor.run { self.status = "凭据清除失败：\(error.localizedDescription)" } } } }

  /// Clamp a requested effort to what the target model actually advertises:
  /// the requested level when offered, else the adapter default, else the
  /// first offered level; nil (omit the field on the wire) for a model with
  /// no reasoning metadata — pi-ai rejects any named level beyond "off" there.
  func advertisedEffort(provider: String, model: String, requested: String?) -> String? {
    guard let entry = availableModels.first(where: { $0.id == provider })?.models.first(where: { $0.id == model }),
          let reasoning = entry.reasoning else { return nil }
    if let requested, reasoning.efforts.contains(where: { $0.id == requested }) { return requested }
    return reasoning.defaultEffort ?? reasoning.efforts.first?.id
  }
}
