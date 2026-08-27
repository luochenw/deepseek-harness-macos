import SwiftUI

/// Codex-style workspace context chips: `[📁 directory] [⎇ branch | worktree] [＋]`.
/// Shown above the composer for a fresh conversation and inside the page
/// header once a session has content. Git state is view-local (`@State` +
/// `.task(id:)`), not HarnessController state — see the
/// workspace-chips-git-worktree Agent Note.
struct WorkspaceChips: View {
  @EnvironmentObject var harness: HarnessController
  /// Compact mode for the header row (smaller type, no ＋ chip).
  var compact = false
  @State private var git: DSHGitOps.Info?

  /// Registered folders other than the active one — each gets its own chip,
  /// Codex-style, so an imported folder is visibly there without opening
  /// any menu.
  private var otherWorkspaces: [DSHWorkspaceView] {
    DSHWorkspaceContext.additionalFolders(
      activeWorkspace: harness.workspace,
      registered: harness.hostWorkspaces)
  }

  var body: some View {
    HStack(spacing: 6) {
      // Active directory chip — menu also lists everything for completeness.
      Menu {
        Button(action: harness.selectNoWorkspace) {
          if harness.workspace == nil { Label("无工作区", systemImage: "checkmark") }
          else { Text("无工作区") }
        }
        if !harness.hostWorkspaces.isEmpty { Divider() }
        ForEach(harness.hostWorkspaces) { workspace in
          Button(action: {
            harness.registerWorkspace(URL(fileURLWithPath: workspace.path, isDirectory: true))
          }) {
            if harness.workspace?.standardizedFileURL.path == URL(fileURLWithPath: workspace.path).standardizedFileURL.path {
              Label(workspace.title, systemImage: "checkmark")
            } else {
              Text(workspace.title)
            }
          }
        }
        Divider()
        Button("打开工作区…", action: harness.chooseWorkspace)
      } label: {
        chipLabel(icon: harness.workspace == nil ? "folder.badge.minus" : "folder", text: harness.workspaceName, emphasized: true)
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

      // Imported folders sit beside it as passive context chips — they show
      // what the session can reach, not switch targets (switching lives in
      // the active chip's menu). Right-click removes one from the registry.
      ForEach(otherWorkspaces.prefix(compact ? 2 : 4)) { workspace in
        let missing = !FileManager.default.fileExists(atPath: workspace.path)
        chipLabel(icon: missing ? "exclamationmark.triangle" : "folder",
                  text: workspace.title + (missing ? "（目录已删除）" : ""))
          .help(missing ? "磁盘上已找不到 \(workspace.path)，右键可从列表移除" : workspace.path)
          .contextMenu {
            Button("从列表移除", role: .destructive) { harness.deleteWorkspace(workspace) }
          }
      }

      // Branch chip — only for git workspaces: pick a branch (checkout) or
      // spin the current branch into a worktree and switch to it.
      if let git {
        Menu {
          ForEach(git.branches, id: \.self) { branch in
            Button(action: { checkout(branch) }) {
              if branch == git.branch { Label(branch, systemImage: "checkmark") } else { Text(branch) }
            }
          }
          Divider()
          Button("为当前分支创建 worktree", action: createWorktree)
            .disabled(git.branch == nil)
        } label: {
          chipLabel(icon: "arrow.triangle.branch",
                    text: (git.branch ?? "分离 HEAD") + (git.isWorktree ? " · worktree" : ""))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      }

      if !compact {
        Button(action: harness.importWorkspaceFolder) {
          Image(systemName: "plus.square.on.square")
            .font(.system(size: 11))
            .foregroundStyle(DSHTheme.inkSoft)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(DSHTheme.fieldFill, in: Capsule())
            .overlay(Capsule().strokeBorder(DSHTheme.fieldStroke.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("添加本地文件夹：引入已有目录到工作区列表")
      }
    }
    .task(id: harness.workspace?.path) { await reloadGit() }
  }

  private func chipLabel(icon: String, text: String, emphasized: Bool = false) -> some View {
    HStack(spacing: 5) {
      Image(systemName: icon).font(.system(size: compact ? 9.5 : 10.5))
      Text(text).font(.system(size: compact ? 11 : 12, weight: emphasized ? .medium : .regular)).lineLimit(1)
    }
    .foregroundStyle(emphasized ? DSHTheme.ink : DSHTheme.inkFaint)
    .padding(.horizontal, 9).padding(.vertical, compact ? 4 : 5)
    .background(emphasized ? DSHTheme.accentSoft : DSHTheme.fieldFill, in: Capsule())
    .overlay(Capsule().strokeBorder(DSHTheme.fieldStroke.opacity(emphasized ? 0.8 : 0.4), lineWidth: 1))
  }

  private func reloadGit() async {
    guard let path = harness.workspace?.path else { git = nil; return }
    let info = await Task.detached { DSHGitOps.info(at: path) }.value
    git = info
  }

  private func checkout(_ branch: String) {
    guard let path = harness.workspace?.path else { return }
    Task {
      let failure = await Task.detached { DSHGitOps.checkout(branch, at: path) }.value
      if let failure { harness.appendSystem("切换分支失败：\(failure)") }
      await reloadGit()
    }
  }

  private func createWorktree() {
    guard let path = harness.workspace?.path, let branch = git?.branch else { return }
    Task {
      let result = await Task.detached { DSHGitOps.addWorktree(branch: branch, at: path) }.value
      switch result {
      case .success(let worktreePath):
        harness.registerWorkspace(URL(fileURLWithPath: worktreePath, isDirectory: true))
        harness.appendSystem("worktree 已就绪：\(worktreePath)，新会话将在其中运行。")
      case .failure(let message):
        harness.appendSystem("创建 worktree 失败：\(message)")
      }
      await reloadGit()
    }
  }
}
