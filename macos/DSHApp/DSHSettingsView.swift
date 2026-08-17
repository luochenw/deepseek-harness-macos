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
    }
  }
}

private struct ModelSettingsSection: View {
  @EnvironmentObject private var harness: HarnessController

  private var selectedGroup: DSHModelGroup? {
    harness.availableModels.first(where: { $0.id == harness.provider }) ?? harness.availableModels.first
  }

  private var selectedModel: DSHModelCatalogModel? {
    guard let group = selectedGroup else { return nil }
    return group.models.first(where: { $0.id == harness.model }) ?? group.models.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      Text("当前会话模型").dshSectionLabel()

      if harness.availableModels.isEmpty {
        Text("尚未读到 Host 模型目录。先刷新；若还没有可用端点，请添加自定义配置。")
          .font(.caption)
          .foregroundStyle(DSHTheme.inkFaint)
      } else {
        Picker("提供方", selection: Binding(
          get: { selectedGroup?.id ?? "" },
          set: { providerID in
            guard let group = harness.availableModels.first(where: { $0.id == providerID }),
                  let firstModel = group.models.first else { return }
            harness.selectCurrentModel(provider: group.id, model: firstModel.id)
          }
        )) {
          ForEach(harness.availableModels) { group in
            Text(group.nativeDisplayName).tag(group.id)
          }
        }

        Picker("模型", selection: Binding(
          get: { selectedModel?.id ?? "" },
          set: { modelID in
            guard let group = selectedGroup else { return }
            harness.selectCurrentModel(provider: group.id, model: modelID)
          }
        )) {
          ForEach(selectedGroup?.models ?? []) { model in
            Text(model.name).tag(model.id)
          }
        }

        if let description = selectedModel?.description, !description.isEmpty {
          Text(description)
            .font(.caption)
            .foregroundStyle(DSHTheme.inkFaint)
        }
      }

      Button("刷新 Host 模型目录", action: harness.refreshModelConfiguration)
        .buttonStyle(.dshSecondary)

      // API keys write straight from here — the credentials service is the
      // same one provider authoring uses, this is just the faster path for
      // "粘贴个 key 就能用" without opening an endpoint editor.
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        Text("API Key").dshSectionLabel()
        if harness.credentialStates.isEmpty {
          Text("尚未发现凭据引用；添加自定义配置后这里会列出对应的 Key。")
            .font(.caption).foregroundStyle(DSHTheme.inkFaint)
        } else {
          ForEach(harness.credentialStates.keys.sorted(), id: \.self) { reference in
            CredentialQuickEntry(reference: reference)
          }
        }
        Text(harness.hasCredential ? "已检测到可用凭据。" : "尚未检测到可用凭据；粘贴对应引用的 API Key 并保存。")
          .font(.caption)
          .foregroundStyle(harness.hasCredential ? DSHTheme.accent : DSHTheme.warm)
      }

      // 自定义配置 lives inline under the model picker now — switching and
      // endpoint management are one surface, not a separate tab.
      CustomConfigurationSettingsSection()
    }
  }
}

/// One credential reference row: masked entry plus save, with the configured
/// badge reflecting the Host's credentials service state.
private struct CredentialQuickEntry: View {
  @EnvironmentObject private var harness: HarnessController
  let reference: String
  @State private var value = ""
  var body: some View {
    HStack(spacing: DSHSpace.s2) {
      Text(reference)
        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(DSHTheme.ink)
        .lineLimit(1).truncationMode(.middle)
        .frame(width: 168, alignment: .leading)
      SecureField("粘贴 API Key", text: $value).dshField()
      let configured = harness.credentialStates[reference]?.configured == true
      DSHBadge(text: configured ? "已配置" : "未配置", tone: configured ? .accent : .warm)
      Button("保存") { harness.saveCredential(ref: reference, value: value); value = "" }
        .buttonStyle(.dshSecondary)
        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        Text("通用 API 接入").dshSectionLabel()
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
  private var credentialConfigured: Bool {
    guard let reference = harness.providerCredentialReference(provider) else { return false }
    return harness.credentialStates[reference]?.configured == true
  }

  var body: some View {
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
    .padding(.vertical, DSHSpace.s2)
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
