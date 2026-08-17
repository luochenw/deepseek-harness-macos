import SwiftUI

struct SettingsView: View {
  private enum Section: String, CaseIterable, Identifiable {
    case general = "通用"
    case models = "模型"
    case plugins = "插件"
    case voice = "语音"
    case presets = "Agent 预设"

    var id: String { rawValue }

    var icon: String {
      switch self {
      case .general: "gearshape"
      case .models: "cpu"
      case .plugins: "puzzlepiece"
      case .voice: "waveform"
      case .presets: "square.stack.3d.up"
      }
    }
  }

  @EnvironmentObject private var harness: HarnessController
  @State private var section: Section = .general

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      VStack(alignment: .leading, spacing: DSHSpace.s4) {
        Text(section.rawValue)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(DSHTheme.ink)

        ScrollView {
          VStack(alignment: .leading, spacing: DSHSpace.s5) {
            sectionContent
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.trailing, DSHSpace.s2)
          .padding(.vertical, DSHSpace.s1)
        }
        .scrollIndicators(.visible, axes: .vertical)
        .frame(maxHeight: .infinity)

        HStack {
          Button("打开配置文件", action: harness.openHostSettingsDocument)
            .buttonStyle(.dshSecondary)
          Spacer()
          Button("关闭") { harness.showSettings = false }
            .buttonStyle(.dshPrimary)
            .keyboardShortcut(.defaultAction)
        }
      }
      .padding(DSHSpace.s5)
      .frame(width: 630, height: 580, alignment: .topLeading)
    }
    .frame(width: 810, height: 580)
    .background(DSHTheme.surface)
    // 编辑抽屉挂在设置窗口自己身上：挂主窗口会与设置 sheet 抢同一个
    // 挂载点（一次只能出一个 sheet），设置开着时编辑按钮就没反应。
    .sheet(isPresented: $harness.showSettingsEditor) {
      if let namespace = harness.selectedSettingsNamespace { SettingsEditorView(namespace: namespace) }
    }
    .sheet(isPresented: $harness.showProviderAuthoring) {
      if let namespace = harness.settingsDescription?.namespaces.first(where: { $0.ns == "llm-pi-ai" }) {
        ProviderAuthoringView(namespace: namespace, provider: harness.selectedProviderForAuthoring)
      }
    }
    .onAppear {
      harness.refreshModelConfiguration()
      harness.loadPluginInventory()
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s1) {
      ForEach(Section.allCases) { item in
        Button(action: { section = item }) {
          Label(item.rawValue, systemImage: item.icon)
            .font(.system(size: 12.5, weight: section == item ? .semibold : .regular))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(section == item ? DSHTheme.ink : DSHTheme.inkSoft)
        .padding(.horizontal, DSHSpace.s3)
        .padding(.vertical, DSHSpace.s2)
        .background(
          section == item ? DSHTheme.sidebarSelected : .clear,
          in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous)
        )
      }
      Spacer()
    }
    .padding(DSHSpace.s3)
    .frame(width: 180)
    .background(DSHTheme.sidebarBg)
  }

  @ViewBuilder private var sectionContent: some View {
    switch section {
    case .general:
      GeneralSettingsSection()
    case .models:
      ModelSettingsSection()
    case .plugins:
      PluginSettingsSection()
    case .voice:
      VoiceSettingsView()
    case .presets:
      PresetSettingsSection()
    }
  }
}

/// Claude Code 桌面端式的设置行：左边标题 + 灰字说明，右边一枚小 switch。
/// 行自己不带背景——由外层的组卡片承载。
struct DSHToggleRow: View {
  let title: String
  var caption: String?
  @Binding var isOn: Bool

  var body: some View {
    HStack(alignment: .center, spacing: DSHSpace.s3) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13)).foregroundStyle(DSHTheme.ink)
        if let caption {
          Text(caption)
            .font(.system(size: 11))
            .foregroundStyle(DSHTheme.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: DSHSpace.s3)
      Toggle("", isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(DSHTheme.accent)
    }
  }
}

/// 设置组：小节标题 + 一张卡片，行间距分组（不用分割线）。
struct DSHSettingsGroup<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      Text(title).dshSectionLabel()
      VStack(alignment: .leading, spacing: DSHSpace.s3) { content }
        .padding(DSHSpace.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
    }
  }
}

// 真正"通用"的客户端行为开关。默认 Agent preset 的选择挪回「Agent 预设」
// 页（此前两处展示同一状态，改哪个生效说不清）。
private struct GeneralSettingsSection: View {
  @ObservedObject private var bubble = FloatingBubbleManager.shared
  @AppStorage(AppPrefs.enterToSendKey) private var enterToSend = true
  @AppStorage(AppPrefs.notifyTurnEndKey) private var notifyTurnEnd = true
  @AppStorage(AppPrefs.notifyAttentionKey) private var notifyAttention = true
  // 读文件而非 UserDefaults：真值来自 cordis.patch.yml 里标记块是否存在
  // （见 DSHSessionRelaySettings.swift），跟用户手改那份文件不会状态漂移。
  // 初值先给 false，真值在 .onAppear 里读一次——State 初始化表达式在这个
  // 视图每次被重新构造时都会重新求值（父级任何 @Published 字段变化都会
  // 触发），当初值是一次同步磁盘读时，那就是白白读盘。
  @State private var sessionRelayEnabled = false

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      DSHSettingsGroup(title: "窗口") {
        DSHToggleRow(
          title: "显示悬浮圈",
          caption: "置顶的小圆窗，随时看到会话运行状态；后台完成会亮红点。快捷键 ⌥⌘Y。",
          isOn: Binding(
            get: { bubble.enabled },
            set: { if $0 != bubble.enabled { bubble.toggle() } }
          ))
      }

      DSHSettingsGroup(title: "通知") {
        DSHToggleRow(
          title: "回合完成时发送系统通知",
          caption: "横幅只在 app 不在前台时弹出。",
          isOn: $notifyTurnEnd)
        DSHToggleRow(
          title: "需要审批或提问时提醒",
          caption: "菜单栏图标始终显示实时状态，不受通知开关影响。",
          isOn: $notifyAttention)
      }

      DSHSettingsGroup(title: "输入") {
        DSHToggleRow(
          title: "回车直接发送",
          caption: enterToSend
            ? "Shift+回车换行。关闭后：回车换行，⌘回车发送。"
            : "当前：回车换行，⌘回车发送。",
          isOn: $enterToSend)
      }

      DSHSettingsGroup(title: "会话互通") {
        DSHToggleRow(
          title: "允许会话之间互相发现与发消息",
          caption: sessionRelayEnabled
            ? "已启用：模型可以用 list_sessions / send_to_session 找到其他会话并发消息，对方无需单独开启即可收到；实验性功能，默认关闭。"
            : "开启后，模型能看到本机其他正在跑的会话并互相发消息、完成后互相提醒——不代表用户已授权对方请求的操作，实验性功能。",
          isOn: Binding(
            get: { sessionRelayEnabled },
            set: { newValue in
              // cordis.patch.yml is the source of truth (see
              // DSHSessionRelaySettings.swift's doc comment) — if the write
              // fails (permissions, full disk, unwritable config root), the
              // switch must reflect what's actually on disk, not what the
              // user asked for and didn't get.
              sessionRelayEnabled = SessionRelaySettings.setEnabled(newValue) ? newValue : SessionRelaySettings.enabled
            }
          ))
      }
    }
    .onAppear { sessionRelayEnabled = SessionRelaySettings.enabled }
  }
}

/// 官方与自定义彻底分区：各自一张卡片，各管各的 Key 与模型；模型行
/// 点击即为当前会话选用。顶部不再放"提供方/模型"下拉——那是输入框旁
/// 模型菜单的职责，这里只留当前使用摘要。
private struct ModelSettingsSection: View {
  @EnvironmentObject private var harness: HarnessController

  /// Catalog groups that belong to custom (llm-pi-ai) configurations —
  /// everything else is official.
  private var customProviderIDs: Set<String> {
    Set(harness.configurableProviders.map(\.provider))
  }
  private var officialGroups: [DSHModelGroup] {
    harness.availableModels.filter { !customProviderIDs.contains($0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      HStack {
        if let group = harness.availableModels.first(where: { $0.id == harness.provider }),
           let model = group.models.first(where: { $0.id == harness.model }) {
          Text("当前会话使用：\(group.nativeDisplayName) · \(model.name)")
            .font(.caption).foregroundStyle(DSHTheme.inkSoft)
        } else {
          Text("尚未读到 Host 模型目录；先刷新，或添加自定义配置。")
            .font(.caption).foregroundStyle(DSHTheme.inkFaint)
        }
        Spacer()
        Button(action: harness.refreshModelConfiguration) { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.dshGhost)
          .help("刷新 Host 模型目录")
      }

      DSHSettingsGroup(title: "官方配置") {
        // LOCAL_ 前缀是本机管道凭据（两端读同一引用），不需要用户管理。
        ForEach(officialCredentialRefs, id: \.self) { reference in
          CredentialQuickEntry(reference: reference)
        }
        if officialGroups.isEmpty {
          Text("尚未读到官方模型目录。")
            .font(.caption).foregroundStyle(DSHTheme.inkFaint)
        }
        ForEach(officialGroups) { group in
          if officialGroups.count > 1 {
            Text(group.nativeDisplayName)
              .font(.system(size: 12, weight: .semibold)).foregroundStyle(DSHTheme.ink)
          }
          ForEach(group.models) { model in
            ModelSelectRow(groupID: group.id, model: model)
          }
        }
      }

      CustomConfigurationSettingsSection()
    }
  }

  /// Refs not owned by any custom provider and not internal plumbing.
  private var officialCredentialRefs: [String] {
    let customRefs = Set(harness.configurableProviders.compactMap { harness.providerCredentialReference($0) })
    return harness.credentialStates.keys
      .filter { !customRefs.contains($0) && !$0.hasPrefix("LOCAL_") }
      .sorted()
  }
}

/// 点击整行即为当前会话选用该模型；当前使用的行带高亮勾。
private struct ModelSelectRow: View {
  @EnvironmentObject private var harness: HarnessController
  let groupID: String
  let model: DSHModelCatalogModel

  private var isCurrent: Bool { harness.provider == groupID && harness.model == model.id }

  var body: some View {
    Button {
      harness.selectCurrentModel(provider: groupID, model: model.id)
    } label: {
      HStack(spacing: DSHSpace.s3) {
        VStack(alignment: .leading, spacing: 2) {
          Text(model.name).font(.system(size: 13)).foregroundStyle(DSHTheme.ink)
          if let description = model.description, !description.isEmpty {
            Text(description)
              .font(.system(size: 11)).foregroundStyle(DSHTheme.inkFaint)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: DSHSpace.s3)
        if isCurrent {
          Label("当前使用", systemImage: "checkmark.circle.fill")
            .font(.system(size: 11)).foregroundStyle(DSHTheme.accent)
        } else {
          Text("使用").font(.system(size: 11)).foregroundStyle(DSHTheme.inkSoft)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// One credential reference row: the CURRENT value is read back and prefilled
/// in password style (eye button reveals it) — a bare configured badge wasn't
/// enough to verify what's actually stored. Save arms only on a change.
private struct CredentialQuickEntry: View {
  @EnvironmentObject private var harness: HarnessController
  let reference: String
  @State private var value = ""
  @State private var stored = ""
  @State private var reveal = false

  private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    HStack(spacing: DSHSpace.s2) {
      Text(reference)
        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(DSHTheme.ink)
        .lineLimit(1).truncationMode(.middle)
        .frame(width: 168, alignment: .leading)
      Group {
        if reveal {
          TextField("粘贴 API Key", text: $value)
        } else {
          SecureField("粘贴 API Key", text: $value)
        }
      }
      .dshField()
      Button { reveal.toggle() } label: {
        Image(systemName: reveal ? "eye.slash" : "eye")
      }
      .buttonStyle(.dshGhost)
      .help(reveal ? "隐藏" : "显示明文")
      let configured = harness.credentialStates[reference]?.configured == true
      DSHBadge(text: configured ? "已配置" : "未配置", tone: configured ? .accent : .warm)
      Button("保存") {
        harness.saveCredential(ref: reference, value: trimmed)
        stored = trimmed
      }
      .buttonStyle(.dshSecondary)
      .disabled(trimmed.isEmpty || trimmed == stored)
    }
    .onAppear {
      stored = harness.credentialValue(ref: reference) ?? ""
      value = stored
    }
  }
}

private struct CustomConfigurationSettingsSection: View {
  @EnvironmentObject private var harness: HarnessController

  private var namespace: DSHSettingsNamespace? {
    harness.settingsDescription?.namespaces.first(where: { $0.ns == "llm-pi-ai" })
  }

  private var configuredProviders: [DSHConfigurableProvider] {
    harness.configurableProviders
      .filter { $0.settingsNs == "llm-pi-ai" && $0.declared != false }
      .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      HStack {
        Text("自定义配置").dshSectionLabel()
        Spacer()
        Button(action: harness.refreshProviderConfiguration) {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.dshGhost)
        .help("刷新自定义配置")
      }

      Text("为任意兼容端点配置 API 地址、协议、模型 ID 和 API Key。已有历史路由会继续按自定义配置兼容，不需要新用户预先具备某个固定提供方。")
        .font(.caption)
        .foregroundStyle(DSHTheme.inkFaint)
        .fixedSize(horizontal: false, vertical: true)

      if let namespace, let settings = harness.settingsDescription {
        Text(settings.writable ? "配置可写 · revision \(namespace.revision)" : "当前 Host 将配置标记为只读")
          .font(.caption)
          .foregroundStyle(settings.writable ? DSHTheme.accent : DSHTheme.warm)

        if configuredProviders.isEmpty {
          Text("还没有自定义配置。添加一个端点后，它会出现在模型目录中。")
            .font(.caption)
            .foregroundStyle(DSHTheme.inkFaint)
        } else {
          VStack(alignment: .leading, spacing: DSHSpace.s2) {
            ForEach(configuredProviders) { provider in
              CustomProviderRow(provider: provider) {
                harness.openProviderAuthoring(provider)
              }
              .disabled(!settings.writable)
            }
          }
        }

        Button("添加自定义配置") { harness.openProviderAuthoring() }
          .buttonStyle(.dshPrimary)
          .disabled(!settings.writable)
      } else {
        Text("正在读取 Host 的自定义配置能力…")
          .font(.caption)
          .foregroundStyle(DSHTheme.inkFaint)
      }
    }
  }
}

private struct CustomProviderRow: View {
  @EnvironmentObject private var harness: HarnessController
  let provider: DSHConfigurableProvider
  let edit: () -> Void

  private var isLegacyRelay: Bool { provider.provider == "relay" }
  private var profile: [String: DSHJSONValue]? { harness.providerProfile(provider) }
  private var credentialConfigured: Bool {
    guard let reference = harness.providerCredentialReference(provider) else { return false }
    return harness.credentialStates[reference]?.configured == true
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      HStack(spacing: DSHSpace.s3) {
        VStack(alignment: .leading, spacing: 2) {
          Text(isLegacyRelay ? "自定义配置" : provider.displayName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DSHTheme.ink)
          Text(isLegacyRelay ? "通用 API 接入" : "配置 ID：\(provider.provider)")
            .font(.caption)
            .foregroundStyle(DSHTheme.inkFaint)
            .lineLimit(1)
        }
        Spacer()
        DSHBadge(text: credentialConfigured ? "已配置" : "待填写 Key", tone: credentialConfigured ? .accent : .warm)
        Button("编辑", action: edit)
          .buttonStyle(.dshSecondary)
      }
      // 当前配置直接可见（与编辑抽屉同源），不用点进去才知道配了什么。
      if let profile {
        detailRow("API 地址", profile.string("baseURL") ?? "—")
        detailRow("协议", profile.string("api") ?? "—")
        let models = profile.modelIDs
        if models.isEmpty {
          detailRow("模型", "—")
        } else {
          // 模型胶囊点击即为当前会话选用，与官方组的模型行同一语义。
          HStack(alignment: .firstTextBaseline, spacing: DSHSpace.s2) {
            Text("模型")
              .font(.system(size: 11)).foregroundStyle(DSHTheme.inkFaint)
              .frame(width: 56, alignment: .leading)
            HStack(spacing: DSHSpace.s1) {
              ForEach(models, id: \.self) { id in
                modelChip(id)
              }
            }
          }
        }
        // Key 的填写/修改集中在「编辑」抽屉里（当前值会预填）；这里只
        // 展示引用名，状态看右上角徽标。
        if let keyRef = profile.apiKeyEnv {
          detailRow("Key 引用", keyRef)
        }
      }
    }
    .padding(.vertical, DSHSpace.s2)
  }

  private func detailRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DSHSpace.s2) {
      Text(label)
        .font(.system(size: 11)).foregroundStyle(DSHTheme.inkFaint)
        .frame(width: 56, alignment: .leading)
      Text(value)
        .font(.system(size: 11, design: .monospaced)).foregroundStyle(DSHTheme.inkSoft)
        .lineLimit(1).truncationMode(.middle)
        .textSelection(.enabled)
    }
  }

  private func modelChip(_ id: String) -> some View {
    let isCurrent = harness.provider == provider.provider && harness.model == id
    return Button {
      harness.selectCurrentModel(provider: provider.provider, model: id)
    } label: {
      Text(id)
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(isCurrent ? DSHTheme.accentSoft : DSHTheme.surfaceTint, in: Capsule())
        .foregroundStyle(isCurrent ? DSHTheme.accent : DSHTheme.inkSoft)
    }
    .buttonStyle(.plain)
    .help(isCurrent ? "当前会话正在使用" : "为当前会话选用此模型")
  }
}

private struct PluginSettingsSection: View {
  @EnvironmentObject private var harness: HarnessController

  private var credentialReferences: [String] {
    guard let settings = harness.settingsDescription else { return [] }
    return HarnessController.credentialReferences(in: settings)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s5) {
      VStack(alignment: .leading, spacing: DSHSpace.s3) {
        HStack {
          Text("Host 设置").dshSectionLabel()
          Spacer()
          Button("刷新", action: harness.refreshModelConfiguration)
            .buttonStyle(.dshSecondary)
        }

        if let settings = harness.settingsDescription {
          Text(settings.writable ? "配置可写" : "当前 Host 将配置标记为只读")
            .font(.caption)
            .foregroundStyle(settings.writable ? DSHTheme.accent : DSHTheme.warm)

          ForEach(settings.namespaces) { namespace in
            HStack(spacing: DSHSpace.s3) {
              Label("\(namespace.ns) · \(namespace.applies)", systemImage: "puzzlepiece")
                .foregroundStyle(DSHTheme.ink)
                .lineLimit(1)
              Spacer()
              Button("编辑") { harness.openSettingsEditor(ns: namespace) }
                .buttonStyle(.dshSecondary)
                .disabled(!settings.writable)
            }
            .padding(.vertical, DSHSpace.s1)
          }
        } else {
          Text("正在读取 Host 设置…")
            .font(.caption)
            .foregroundStyle(DSHTheme.inkFaint)
        }
      }

      VStack(alignment: .leading, spacing: DSHSpace.s3) {
        Text("凭据").dshSectionLabel()
        if credentialReferences.isEmpty {
          Text("当前设置没有声明凭据引用。")
            .font(.caption)
            .foregroundStyle(DSHTheme.inkFaint)
        } else {
          ForEach(credentialReferences, id: \.self) { reference in
            HStack(spacing: DSHSpace.s3) {
              Text(reference)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(DSHTheme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer()
              let configured = harness.credentialStates[reference]?.configured == true
              DSHBadge(text: configured ? "已配置" : "未配置", tone: configured ? .accent : .warm)
            }
          }
        }
        Text("凭据引用来自 Host 当前配置；在对应的自定义配置或命名空间编辑器中写入、轮换或清除。")
          .font(.caption)
          .foregroundStyle(DSHTheme.inkFaint)
      }

      VStack(alignment: .leading, spacing: DSHSpace.s3) {
        HStack {
          Text("插件运行清单").dshSectionLabel()
          Spacer()
          Button("刷新", action: harness.loadPluginInventory)
            .buttonStyle(.dshSecondary)
        }

        if harness.pluginEntries.isEmpty {
          Text("暂无运行清单；点击刷新读取 Cordis 加载器的插件状态。")
            .font(.caption)
            .foregroundStyle(DSHTheme.inkFaint)
        } else {
          ForEach(harness.pluginEntries) { entry in
            HStack(spacing: DSHSpace.s3) {
              Label(entry.moduleName, systemImage: "shippingbox")
                .foregroundStyle(DSHTheme.ink)
                .lineLimit(1)
              Spacer()
              Text(entry.fiberPhase ?? (entry.enabled ? "未运行" : "已禁用"))
                .font(.caption)
                .foregroundStyle(entry.fiberPhase == "failed" ? DSHTheme.coral : DSHTheme.inkFaint)
            }
            .padding(.vertical, DSHSpace.s1)
          }
        }
      }
    }
  }
}

private struct PresetSettingsSection: View {
  @EnvironmentObject private var harness: HarnessController

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      Text("选择新会话使用的 Agent 能力组合。")
        .font(.caption)
        .foregroundStyle(DSHTheme.inkFaint)

      ForEach(HarnessController.Preset.allCases) { preset in
        Button(action: { harness.setPreset(preset) }) {
          HStack(spacing: DSHSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
              Text(preset.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DSHTheme.ink)
              Text(preset.detail)
                .font(.caption)
                .foregroundStyle(DSHTheme.inkFaint)
            }
            Spacer()
            if harness.preset == preset {
              Image(systemName: "checkmark")
                .foregroundStyle(DSHTheme.accent)
            }
          }
          .padding(.vertical, DSHSpace.s1)
        }
        .buttonStyle(.plain)
      }

      Text("Host Agent Preset 管理").dshSectionLabel()
      PresetManagerView()
    }
  }
}
