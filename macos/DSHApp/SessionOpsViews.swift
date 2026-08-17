import AppKit
import SwiftUI

// Views for the session-operations surface (DSHSessionOps.swift):
// archived-session browser, preset manager, and model discovery. Styled
// entirely on the DSHTheme token system (DSHTheme.swift) to match the rest
// of the app's ocean-toned chrome — see WorkspaceManagerView.swift and
// DSHSettingsEditor.swift for the sheet/list conventions this file follows.

/// Archived sessions from workspace.list's registry-global archive set. The
/// Host protocol registers no unarchive method (rpc-map.d.ts lists only
/// workspace.archiveSession), so this view offers open/export instead of
/// restore and says so explicitly.
struct ArchivedSessionsView: View {
  @EnvironmentObject var harness: HarnessController
  @Environment(\.dismiss) private var dismiss
  @State private var rows: [HarnessController.ArchivedSessionRow] = []
  @State private var loading = true

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      HStack {
        Text("归档会话").font(.title2.weight(.bold)).foregroundStyle(DSHTheme.ink)
        Spacer()
        Button(action: { loading = true; Task { await load() } }) { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.dshGhost)
          .help("重新读取归档列表")
      }
      if loading {
        Spacer()
        ProgressView("正在读取归档会话…").foregroundStyle(DSHTheme.inkSoft)
        Spacer()
      } else if rows.isEmpty {
        Spacer()
        Text("暂无归档会话。").foregroundStyle(DSHTheme.inkFaint)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: DSHSpace.s2) {
            ForEach(rows) { row in ArchivedSessionRowView(row: row) }
          }
        }
      }
      Label("Host 暂不支持恢复归档：协议仅提供 workspace.archiveSession，没有 unarchive 方法。归档会话仍可打开查看或导出日志。", systemImage: "info.circle")
        .font(.caption).foregroundStyle(DSHTheme.inkFaint)
      HStack { Spacer(); Button("关闭") { dismiss() }.buttonStyle(.dshSecondary).keyboardShortcut(.cancelAction) }
    }
    .padding(DSHSpace.s5)
    .frame(width: 580, height: 460)
    .background(DSHTheme.surface)
    .task { await load() }
  }

  private func load() async {
    rows = await harness.loadArchivedSessions()
    loading = false
  }
}

/// One archived-session row: title/id/updated-at/cwd on the left, open/export
/// actions on the right. Card-tinted like the rows in the built-in session
/// search sheet (main.swift's SessionSearchView) rather than a system List
/// separator.
private struct ArchivedSessionRowView: View {
  @EnvironmentObject var harness: HarnessController
  @Environment(\.dismiss) private var dismiss
  let row: HarnessController.ArchivedSessionRow

  var body: some View {
    HStack(spacing: DSHSpace.s3) {
      VStack(alignment: .leading, spacing: 3) {
        Text(row.title ?? row.sessionId)
          .font(row.title == nil ? .system(.body, design: .monospaced) : .body)
          .foregroundStyle(DSHTheme.ink)
          .lineLimit(1)
        HStack(spacing: DSHSpace.s2) {
          if row.title != nil { Text(row.sessionId).font(.caption2.monospaced()).foregroundStyle(DSHTheme.inkFaint).lineLimit(1) }
          if let updatedAt = row.updatedAt { Text(updatedAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(DSHTheme.inkFaint) }
          if let cwd = row.cwd { Text(cwd).font(.caption2).foregroundStyle(DSHTheme.inkFaint).lineLimit(1) }
        }
      }
      Spacer()
      Button("打开") { harness.openHostSessionID(row.sessionId); dismiss() }.buttonStyle(.dshSecondary)
      Button("导出 ZIP") { harness.exportSessionLog(sessionId: row.sessionId) }.buttonStyle(.dshSecondary)
    }
    .padding(DSHSpace.s3)
    .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
  }
}

/// Host preset roster with the loopback-only authoring calls:
/// read (viewer), copy (the only authoring write), openDocument, remove.
/// Shipped (`system`) presets refuse openDocument/remove, so those buttons
/// disable; copy disables when the deployment configures no authorable root.
///
/// Embeddable content view (no outer frame/background) so it can drop into
/// SettingsView's "Agent 预设" section content area — see the `default:`
/// case in main.swift's `settingsBody` for that section's current shape.
struct PresetManagerView: View {
  @EnvironmentObject var harness: HarnessController
  @State private var authorable = false
  @State private var hasDocument = false
  @State private var readResult: DSHPresetReadResult?
  @State private var copySource: DSHAgentPreset?
  @State private var copyId = ""
  @State private var copyName = ""
  @State private var removeTarget: DSHAgentPreset?
  @State private var documentPath: String?

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      HStack {
        Text("Host 提供的 Agent 预设决定新会话由哪些插件组合而成。").font(.caption).foregroundStyle(DSHTheme.inkSoft)
        Spacer()
        Button(action: { Task { await loadCatalog() } }) { Image(systemName: "arrow.clockwise") }.buttonStyle(.dshGhost).help("刷新预设列表")
      }
      if harness.hostPresets.isEmpty {
        Text("Host 未提供任何预设（所有会话共用 Host 组合）。").foregroundStyle(DSHTheme.inkFaint)
      } else {
        LazyVStack(alignment: .leading, spacing: DSHSpace.s2) {
          ForEach(harness.hostPresets) { preset in
            PresetRowView(
              preset: preset,
              authorable: authorable,
              hasDocument: hasDocument,
              onRead: { Task { readResult = await harness.readHostPreset(preset.id) } },
              onCopy: { copyId = "\(preset.id)-copy"; copyName = ""; copySource = preset },
              onDocument: { Task { documentPath = await harness.openHostPresetDocument(preset.id) } },
              onRemove: { removeTarget = preset }
            )
          }
        }
      }
      if !authorable { Text("当前部署未配置可写预设根目录，「复制」不可用。").font(.caption2).foregroundStyle(DSHTheme.inkFaint) }
    }
    .task { await loadCatalog() }
    .sheet(item: $readResult) { result in PresetReadSheet(result: result) }
    .sheet(item: $copySource) { source in copySheet(source) }
    .alert("删除预设", isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })) {
      Button("取消", role: .cancel) { removeTarget = nil }
      Button("删除", role: .destructive) { if let target = removeTarget { harness.removeHostPreset(target.id) }; removeTarget = nil }
    } message: {
      Text("将删除本地预设「\(removeTarget?.name ?? removeTarget?.id ?? "")」的目录，此操作不可恢复。")
    }
    .alert("预设目录", isPresented: Binding(get: { documentPath != nil }, set: { if !$0 { documentPath = nil } })) {
      Button("复制路径") {
        if let path = documentPath { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
        documentPath = nil
      }
      Button("好", role: .cancel) { documentPath = nil }
    } message: {
      Text(documentPath ?? "")
    }
  }

  private func loadCatalog() async {
    guard let catalog = await harness.loadPresetCatalog() else { return }
    authorable = catalog.authorable ?? false
    hasDocument = catalog.hasDocument ?? false
  }

  private func copySheet(_ source: DSHAgentPreset) -> some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      Text("复制预设").font(.title3.weight(.bold)).foregroundStyle(DSHTheme.ink)
      Text("从「\(source.name ?? source.id)」复制出一个本地可编辑的预设。Host 只按 id 解析，不传输任何路径或组合文本。")
        .font(.caption).foregroundStyle(DSHTheme.inkSoft)
      TextField("新预设 id", text: $copyId).dshField(tint: DSHTheme.surfaceTint)
      TextField("显示名称（可选）", text: $copyName).dshField(tint: DSHTheme.surfaceTint)
      HStack {
        Spacer()
        Button("取消") { copySource = nil }.buttonStyle(.dshSecondary).keyboardShortcut(.cancelAction)
        Button("复制") {
          harness.copyHostPreset(from: source.id, newId: copyId, name: copyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : copyName)
          copySource = nil
        }
        .buttonStyle(.dshPrimary)
        .disabled(copyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(DSHSpace.s5)
    .frame(width: 440)
    .background(DSHTheme.surface)
  }
}

/// One preset row: trust/default badges, broken-composition warning, and the
/// four authoring actions (view/copy/document/remove) gated on Host facts.
private struct PresetRowView: View {
  let preset: DSHAgentPreset
  let authorable: Bool
  let hasDocument: Bool
  let onRead: () -> Void
  let onCopy: () -> Void
  let onDocument: () -> Void
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      HStack(spacing: DSHSpace.s2) {
        Text(preset.name ?? preset.id).font(.headline).foregroundStyle(DSHTheme.ink)
        // Trust is a category tag, not a severity signal — both trust states
        // read as neutral; only the still-uncommon "默认" state earns the
        // accent color, matching how DSHBadge(tone: .accent) marks "已配置"
        // elsewhere (DSHProviderAuthoring.swift).
        DSHBadge(text: preset.trust == "system" ? "内置" : "用户", tone: .neutral)
        if preset.isDefault { DSHBadge(text: "默认", tone: .accent) }
        Spacer()
      }
      if preset.name != nil { Text(preset.id).font(.caption2.monospaced()).foregroundStyle(DSHTheme.inkFaint) }
      if let description = preset.description { Text(description).font(.caption).foregroundStyle(DSHTheme.inkSoft) }
      if let broken = preset.broken {
        Label("无法组合会话：\(broken)", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(DSHTheme.warm)
      }
      HStack(spacing: DSHSpace.s2) {
        Button("查看", action: onRead).buttonStyle(.dshSecondary)
        Button("复制", action: onCopy).buttonStyle(.dshSecondary).disabled(!authorable)
        Button(hasDocument ? "打开目录" : "查看路径", action: onDocument).buttonStyle(.dshSecondary).disabled(preset.trust != "user")
        Button("删除", role: .destructive, action: onRemove).buttonStyle(.dshSecondary).disabled(preset.trust != "user")
      }
    }
    .padding(DSHSpace.s3)
    .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
  }
}

/// Read-only viewer for one preset's composition text (agentPreset.read).
struct PresetReadSheet: View {
  @Environment(\.dismiss) private var dismiss
  let result: DSHPresetReadResult

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      HStack(spacing: DSHSpace.s2) {
        Text(result.name ?? result.agentPreset).font(.title3.weight(.bold)).foregroundStyle(DSHTheme.ink)
        DSHBadge(text: result.trust == "system" ? "内置" : "用户", tone: .neutral)
        Spacer()
      }
      Text(result.agentPreset).font(.caption.monospaced()).foregroundStyle(DSHTheme.inkFaint)
      if let description = result.description { Text(description).font(.caption).foregroundStyle(DSHTheme.inkSoft) }
      ScrollView {
        Text(result.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(DSHSpace.s2)
      .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
      HStack {
        Button("复制内容") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.content, forType: .string) }.buttonStyle(.dshSecondary)
        Spacer()
        Button("关闭") { dismiss() }.buttonStyle(.dshSecondary).keyboardShortcut(.cancelAction)
      }
    }
    .padding(DSHSpace.s5)
    .frame(width: 640, height: 520)
    .background(DSHTheme.surface)
  }
}

/// llm.discoverModels result browser. Discovery never writes configuration —
/// the reply is candidates only — so each row offers "复制 ID" for pasting
/// into the provider editor's model list.
struct DiscoveredModelsSheet: View {
  @EnvironmentObject var harness: HarnessController
  @Environment(\.dismiss) private var dismiss
  let settingsNs: String
  var provider: String? = nil
  var baseURL: String? = nil
  var api: String? = nil
  var apiKey: String? = nil

  @State private var models: [DSHDiscoveredModel] = []
  @State private var loading = true
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      Text("发现模型").font(.title2.weight(.bold)).foregroundStyle(DSHTheme.ink)
      Text(provider.map { "查询提供方「\($0)」当前通告的模型。" } ?? "按草稿中的 API 地址查询该端点通告的模型。")
        .font(.caption).foregroundStyle(DSHTheme.inkSoft)
      if loading {
        Spacer()
        ProgressView("正在询问端点…").foregroundStyle(DSHTheme.inkSoft)
        Spacer()
      } else if let error {
        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(DSHTheme.coral)
        Spacer()
      } else if models.isEmpty {
        Spacer()
        Text("端点没有通告任何模型。").foregroundStyle(DSHTheme.inkFaint)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: DSHSpace.s2) {
            ForEach(models) { model in DiscoveredModelRowView(model: model) }
          }
        }
        Text("把需要的模型 ID 粘贴到「自定义配置 → 编辑」的模型 ID 列表中保存；发现结果不会自动写入配置。")
          .font(.caption2).foregroundStyle(DSHTheme.inkFaint)
      }
      HStack { Spacer(); Button("关闭") { dismiss() }.buttonStyle(.dshSecondary).keyboardShortcut(.cancelAction) }
    }
    .padding(DSHSpace.s5)
    .frame(width: 580, height: 460)
    .background(DSHTheme.surface)
    .task {
      do { models = try await harness.discoverModels(settingsNs: settingsNs, provider: provider, baseURL: baseURL, api: api, apiKey: apiKey) }
      catch { self.error = "模型发现失败：\(error.localizedDescription)" }
      loading = false
    }
  }
}

/// One discovered-model row: id/name/context/max-output on the left, a
/// clipboard action on the right (discovery never writes configuration).
private struct DiscoveredModelRowView: View {
  let model: DSHDiscoveredModel

  var body: some View {
    HStack(spacing: DSHSpace.s3) {
      VStack(alignment: .leading, spacing: 2) {
        Text(model.id).font(.system(.body, design: .monospaced)).foregroundStyle(DSHTheme.ink)
        HStack(spacing: DSHSpace.s2) {
          if let name = model.name { Text(name).font(.caption).foregroundStyle(DSHTheme.inkSoft) }
          if let window = model.contextWindow { Text("上下文 \(window)").font(.caption2).foregroundStyle(DSHTheme.inkFaint) }
          if let maxTokens = model.maxTokens { Text("最大输出 \(maxTokens)").font(.caption2).foregroundStyle(DSHTheme.inkFaint) }
        }
      }
      Spacer()
      Button("复制 ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.id, forType: .string) }.buttonStyle(.dshSecondary)
    }
    .padding(DSHSpace.s3)
    .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
  }
}
