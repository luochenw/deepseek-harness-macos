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
