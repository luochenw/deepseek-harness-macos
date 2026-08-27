import Foundation
import AppKit

enum DSHWorkspacePreference {
  static let workspaceKey = "dsh.workspace"
  static let noWorkspaceKey = "dsh.noWorkspace"

  static func restoredWorkspace(
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default,
    defaultURL: @autoclosure () -> URL?
  ) -> URL? {
    guard !defaults.bool(forKey: noWorkspaceKey) else { return nil }
    if let path = defaults.string(forKey: workspaceKey), fileManager.fileExists(atPath: path) {
      return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
    guard let url = defaultURL() else { return nil }
    try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    defaults.set(url.standardizedFileURL.path, forKey: workspaceKey)
    return url.standardizedFileURL
  }

  static func persist(_ workspace: URL?, defaults: UserDefaults = .standard) {
    guard let workspace else {
      defaults.removeObject(forKey: workspaceKey)
      defaults.set(true, forKey: noWorkspaceKey)
      return
    }
    defaults.set(workspace.standardizedFileURL.path, forKey: workspaceKey)
    defaults.removeObject(forKey: noWorkspaceKey)
  }
}

enum DSHWorkspaceContext {
  static func additionalFolders(activeWorkspace: URL?, registered: [DSHWorkspaceView]) -> [DSHWorkspaceView] {
    guard let current = activeWorkspace?.standardizedFileURL.path else { return [] }
    return registered.filter {
      URL(fileURLWithPath: $0.path).standardizedFileURL.path != current
    }
  }
}

struct DSHWorkspaceCreatePayload: Encodable { let path: String }
struct DSHWorkspaceCreateResult: Decodable { let workspace: DSHWorkspaceView; let created: Bool }
struct DSHWorkspaceRenamePayload: Encodable { let workspaceId: String; let title: String }
struct DSHWorkspaceDeletePayload: Encodable { let workspaceId: String }
struct DSHWorkspaceDeleteResult: Decodable { let deleted: Bool }

extension HarnessController {
  func restoreWorkspaceSelection() {
    let defaultURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
      .appendingPathComponent("DeepSeek Harness", isDirectory: true)
    workspace = DSHWorkspacePreference.restoredWorkspace(defaultURL: defaultURL)
  }

  func selectNoWorkspace() {
    workspace = nil
    DSHWorkspacePreference.persist(nil)
    status = "已选择无工作区；新会话将使用 Host 默认目录"
  }

  func renameWorkspace(_ workspace: DSHWorkspaceView, title: String) {
    guard let hostClient, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    Task { do { _ = try await hostClient.renameWorkspace(id: workspace.workspaceId, title: title); await MainActor.run { self.refreshHostSnapshots() } } catch { await MainActor.run { self.status = "工作区重命名失败：\(error.localizedDescription)" } } }
  }

  func deleteWorkspace(_ workspace: DSHWorkspaceView) {
    guard let hostClient else { return }
    Task { do { try await hostClient.deleteWorkspace(id: workspace.workspaceId); await MainActor.run { self.refreshHostSnapshots() } } catch { await MainActor.run { self.status = "工作区删除失败：\(error.localizedDescription)" } } }
  }

  /// 引入一个已有的本地文件夹：注册进 Host 工作区表但不切换当前工作区 —
  /// 之后它出现在目录 chip 的菜单里随取随用（＋ chip 的动作）。
  func importWorkspaceFolder() {
    let panel = NSOpenPanel()
    panel.title = "添加本地文件夹"
    panel.message = "引入一个已有目录；它会加入工作区列表，但不会切换当前会话的工作区。"
    panel.prompt = "引入"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url, let hostClient else { return }
    Task {
      do {
        _ = try await hostClient.createWorkspace(path: url.standardizedFileURL.path)
        await MainActor.run {
          // Visible feedback: the status line no longer exists, so confirm in
          // the transcript; the chips row also shows the new folder now.
          self.appendSystem("已引入文件夹：\(url.lastPathComponent)，可在目录 chips 中切换。")
          self.refreshHostSnapshots()
        }
      } catch { await MainActor.run { self.appendSystem("引入文件夹失败：\(error.localizedDescription)") } }
    }
  }

  func registerWorkspace(_ url: URL) {
    // Fail fast and *visibly* when the directory is gone from disk — letting
    // it through used to surface only at session creation, as an opaque
    // "找不到" from the Host (and half the errors here wrote to the removed
    // status line, so the user saw nothing actionable).
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      appendSystem("工作区目录已不存在：\(url.path)。若它还在文件夹列表里，右键对应 chip 选「从列表移除」。")
      return
    }
    guard let hostClient else { return }
    Task {
      do {
        let result = try await hostClient.createWorkspace(path: url.path)
        await MainActor.run {
          self.workspace = url.standardizedFileURL
          DSHWorkspacePreference.persist(url)
          self.status = result.created ? "工作区已添加" : "工作区已选择"
          self.refreshHostSnapshots()
        }
      } catch {
        await MainActor.run { self.appendSystem("工作区注册失败：\(error.localizedDescription)") }
      }
    }
  }

  func chooseWorkspace() {
    let panel = NSOpenPanel()
    panel.title = "选择 DSH 工作区"
    panel.message = "DSH 将在此目录中读取、修改文件并运行终端命令。"
    panel.prompt = "选择工作区"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = workspace
    guard panel.runModal() == .OK, let selected = panel.url else { return }
    registerWorkspace(selected.standardizedFileURL)
    if let index = selectedSessionIndex { sessions[index].workspaceName = selected.lastPathComponent }
  }

  /// Match the Host/Web path contract: absolute paths pass through, while file-tool
  /// paths relative to the selected workspace are resolved before they reach Host.
  nonisolated static func resolveWorkspacePath(_ path: String, workspace: URL?) -> String {
    guard !path.hasPrefix("/"), !path.hasPrefix("\\"),
          path.range(of: "^[A-Za-z]:[/\\]", options: .regularExpression) == nil,
          let workspace else { return path }
    return workspace.appendingPathComponent(path).standardizedFileURL.path
  }

  func openDeliveredFile(_ path: String) {
    openHostPath(Self.resolveWorkspacePath(path, workspace: workspace))
  }

  func revealDeliveredFile(_ path: String) {
    let resolved = Self.resolveWorkspacePath(path, workspace: workspace)
    let directory = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
    openHostPath(directory)
  }

  func openHostPath(_ path: String) {
    guard let hostClient else { return }
    Task {
      do {
        try await hostClient.openPath(path)
        await MainActor.run { self.status = "已请求 Host 打开路径" }
      } catch {
        await MainActor.run { self.status = "打开路径失败" }
      }
    }
  }

  func openWorkspace() {
    guard let workspace else { chooseWorkspace(); return }
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path)
  }
}
