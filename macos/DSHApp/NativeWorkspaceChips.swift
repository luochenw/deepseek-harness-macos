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

  var body: some View {
    HStack(spacing: 6) {
      // Directory chip — switch between Host workspaces or pick a folder.
      Menu {
        ForEach(harness.hostWorkspaces) { workspace in
          Button(workspace.title) {
            harness.registerWorkspace(URL(fileURLWithPath: workspace.path, isDirectory: true))
          }
        }
        if !harness.hostWorkspaces.isEmpty { Divider() }
        Button("打开工作区…", action: harness.chooseWorkspace)
      } label: {
        chipLabel(icon: "folder", text: harness.workspaceName)
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

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
        Button(action: createFolder) {
          Image(systemName: "plus.square.on.square")
            .font(.system(size: 11))
            .foregroundStyle(DSHTheme.inkSoft)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(DSHTheme.fieldFill, in: Capsule())
            .overlay(Capsule().strokeBorder(DSHTheme.fieldStroke.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("添加新的文件夹（创建目录并作为工作区）")
      }
    }
    .task(id: harness.workspace?.path) { await reloadGit() }
  }

  private func chipLabel(icon: String, text: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: icon).font(.system(size: compact ? 9.5 : 10.5))
      Text(text).font(.system(size: compact ? 11 : 12)).lineLimit(1)
    }
    .foregroundStyle(DSHTheme.inkSoft)
    .padding(.horizontal, 9).padding(.vertical, compact ? 4 : 5)
    .background(DSHTheme.fieldFill, in: Capsule())
    .overlay(Capsule().strokeBorder(DSHTheme.fieldStroke.opacity(0.5), lineWidth: 1))
  }

  /// ＋ chip: create a brand-new folder and make it the workspace (existing
  /// folders go through the directory chip's 打开工作区…).
  private func createFolder() {
    let panel = NSSavePanel()
    panel.title = "添加新的文件夹"
    panel.prompt = "创建"
    panel.nameFieldStringValue = "新项目"
    panel.canCreateDirectories = true
    panel.directoryURL = harness.workspace?.deletingLastPathComponent()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      harness.registerWorkspace(url.standardizedFileURL)
    } catch {
      harness.appendSystem("创建文件夹失败：\(error.localizedDescription)")
    }
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
