import SwiftUI

/// Sidebar workspace control — the entry point for everything workspace:
/// switch between Host-registered workspaces, add an existing directory,
/// create a brand-new one, or open the manager (rename/delete). Sheet
/// state is all view-local so HarnessController (main.swift) stays
/// untouched — see the workspace-add-switch Agent Note.
struct WorkspaceSwitcherButton: View {
  @EnvironmentObject var harness: HarnessController
  @State private var showCreate = false
  @State private var showManager = false

  var body: some View {
    Menu {
      if !harness.hostWorkspaces.isEmpty {
        ForEach(harness.hostWorkspaces) { ws in
          Button(action: { harness.switchWorkspace(ws) }) {
            if harness.workspace?.path == ws.path { Label(ws.title, systemImage: "checkmark") }
            else { Text(ws.title) }
          }
        }
        Divider()
      }
      Button("添加现有目录…", action: harness.chooseWorkspace)
      Button("新建工作区…") { showCreate = true }
      if !harness.hostWorkspaces.isEmpty {
        Divider()
        Button("管理工作区…") { showManager = true }
      }
    } label: {
      Label(harness.workspaceName, systemImage: "folder").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
    }
    .menuStyle(.borderlessButton)
    .font(.system(size: 12.5, weight: .medium))
    .foregroundStyle(DSHTheme.ink)
    .padding(.horizontal, DSHSpace.s3).padding(.vertical, 8)
    .background(DSHTheme.surfaceTint2, in: RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous))
    .help(harness.workspace?.path ?? "选择工作区")
    .sheet(isPresented: $showCreate) { NewWorkspaceSheet() }
    .sheet(isPresented: $showManager) {
      VStack(alignment: .leading, spacing: DSHSpace.s4) {
        Text("管理工作区").font(.title3.weight(.bold)).foregroundStyle(DSHTheme.ink)
        WorkspaceManagerView()
        HStack { Spacer(); Button("完成") { showManager = false }.buttonStyle(.dshSecondary) }
      }
      .padding(DSHSpace.s5)
      .frame(width: 420)
      .background(DSHTheme.surface)
    }
  }
}

/// "新建工作区"：在选定父目录下创建一个新目录并注册为 Host 工作区。
private struct NewWorkspaceSheet: View {
  @EnvironmentObject var harness: HarnessController
  @Environment(\.dismiss) private var dismiss
  @State private var parent = FileManager.default.homeDirectoryForCurrentUser
  @State private var name = ""
  @State private var errorText: String?

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var nameIsValid: Bool { !trimmedName.isEmpty && !trimmedName.contains("/") && !trimmedName.contains(":") && trimmedName != "." && trimmedName != ".." }
  private var destination: URL { parent.appendingPathComponent(trimmedName, isDirectory: true) }

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      Text("新建工作区").font(.title3.weight(.bold)).foregroundStyle(DSHTheme.ink)
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        Text("位置").dshSectionLabel()
        HStack(spacing: DSHSpace.s2) {
          Label(parent.path, systemImage: "folder").font(.caption).foregroundStyle(DSHTheme.inkSoft).lineLimit(1).truncationMode(.middle)
          Spacer()
          Button("选择…", action: pickParent).buttonStyle(.dshSecondary)
        }
      }
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        Text("名称").dshSectionLabel()
        TextField("例如 my-project", text: $name).dshField()
        if nameIsValid {
          Text(destination.path).font(.caption2).foregroundStyle(DSHTheme.inkFaint).lineLimit(1).truncationMode(.middle)
        }
      }
      if let errorText {
        Text(errorText).font(.caption).foregroundStyle(DSHTheme.coral)
      }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.buttonStyle(.dshSecondary)
        Button("创建并使用", action: create).buttonStyle(.dshPrimary).disabled(!nameIsValid)
      }
    }
    .padding(DSHSpace.s5)
    .frame(width: 430)
    .background(DSHTheme.surface)
  }

  private func pickParent() {
    let panel = NSOpenPanel()
    panel.title = "选择新工作区所在的位置"
    panel.prompt = "选择位置"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = parent
    if panel.runModal() == .OK, let url = panel.url { parent = url.standardizedFileURL }
  }

  private func create() {
    do {
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      harness.registerWorkspace(destination.standardizedFileURL)
      dismiss()
    } catch {
      errorText = "创建目录失败：\(error.localizedDescription)"
    }
  }
}

extension HarnessController {
  /// Switching to an already-registered workspace goes through the same
  /// `workspace.create` RPC — the Host treats an existing path as an
  /// idempotent select (created: false), and `registerWorkspace` already
  /// owns persistence + status + snapshot refresh.
  func switchWorkspace(_ ws: DSHWorkspaceView) {
    registerWorkspace(URL(fileURLWithPath: ws.path, isDirectory: true))
  }
}

struct WorkspaceManagerView: View {
  @EnvironmentObject var harness: HarnessController
  @State private var renameTarget: DSHWorkspaceView?
  @State private var title = ""
  var body: some View {
    if !harness.hostWorkspaces.isEmpty {
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        Text("Host 工作区").dshSectionLabel()
        ForEach(harness.hostWorkspaces) { ws in
          HStack(spacing: DSHSpace.s2) {
            Label(ws.title, systemImage: "folder")
              .font(.caption)
              .foregroundStyle(DSHTheme.ink)
              .lineLimit(1)
            Spacer()
            Button(action: { title = ws.title; renameTarget = ws }) { Image(systemName: "pencil") }.buttonStyle(.dshGhost)
            Button(action: { harness.deleteWorkspace(ws) }) { Image(systemName: "trash") }.buttonStyle(.dshGhost)
          }
        }
      }
      .sheet(item: $renameTarget) { ws in
        VStack(alignment: .leading, spacing: DSHSpace.s4) {
          Text("重命名工作区")
            .font(.title3.weight(.bold))
            .foregroundStyle(DSHTheme.ink)
          TextField("名称", text: $title).dshField(tint: DSHTheme.surfaceTint)
          HStack {
            Spacer()
            Button("取消") { renameTarget = nil }.buttonStyle(.dshSecondary)
            Button("保存") { harness.renameWorkspace(ws, title: title); renameTarget = nil }.buttonStyle(.dshPrimary)
          }
        }
        .padding(DSHSpace.s5)
        .frame(width: 380)
        .background(DSHTheme.surface)
      }
    }
  }
}
