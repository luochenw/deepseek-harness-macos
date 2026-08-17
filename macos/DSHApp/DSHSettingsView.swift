import SwiftUI

/// Sidebar sections for the settings sheet, in native macOS System Settings
/// style: an icon-labeled sidebar driving a grouped `Form` per section
/// instead of a plain-text list over a hand-rolled VStack.
private enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
  case general, model, provider, plugin, preset
  var id: String { rawValue }
  var label: String {
    switch self {
    case .general: "通用"
    case .model: "模型"
    case .provider: "提供方"
    case .plugin: "插件"
    case .preset: "Agent 预设"
    }
  }
  var icon: String {
    switch self {
    case .general: "gearshape"
    case .model: "cpu"
    case .provider: "network"
    case .plugin: "puzzlepiece"
    case .preset: "square.stack"
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject var harness: HarnessController
  @State private var section: SettingsSection? = .general

  private var currentSection: SettingsSection { section ?? .general }

  var body: some View {
    HStack(spacing: 0) {
      List(selection: $section) {
        ForEach(SettingsSection.allCases) { item in
          Label(item.label, systemImage: item.icon).tag(item)
        }
      }
      .listStyle(.sidebar)
      .frame(width: 170)

      Divider()

      VStack(alignment: .leading, spacing: 0) {
        Text(currentSection.label)
          .font(.title2.weight(.bold))
          .padding(.horizontal, 20)
          .padding(.top, 20)
          .padding(.bottom, 4)

        sectionBody
          .frame(maxHeight: .infinity)

        Divider()
        HStack {
          Button("打开配置文件", action: harness.openHostSettingsDocument)
          Spacer()
          Text(harness.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          Button("关闭") { harness.showSettings = false }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
      }
    }
    .frame(width: 680, height: 540)
  }

  @ViewBuilder private var sectionBody: some View {
    switch currentSection {
    case .general: GeneralSettingsSection()
    case .model: ModelSettingsSection()
    case .provider: ProviderSettingsSection()
    case .plugin: PluginSettingsSection()
    case .preset: PresetSettingsSection()
    }
  }
}

private struct GeneralSettingsSection: View {
  @EnvironmentObject var harness: HarnessController

  var body: some View {
    Form {
      Section {
        Picker("默认 Agent preset", selection: $harness.preset) {
          ForEach(HarnessController.Preset.allCases) { Text($0.label).tag($0) }
        }
        .onChange(of: harness.preset) { _, v in harness.setPreset(v) }
        Picker("默认权限", selection: $harness.permission) {
          ForEach(HarnessController.PermissionMode.allCases) { Text($0.label).tag($0) }
        }
        .onChange(of: harness.permission) { _, v in harness.setPermission(v) }
      } footer: {
        Text("当前会话保持原有 preset；新会话使用新的默认配置。")
      }
    }
    .formStyle(.grouped)
  }
}

private struct ModelSettingsSection: View {
  @EnvironmentObject var harness: HarnessController

  var body: some View {
    Form {
      Section {
        Picker("提供方", selection: $harness.provider) {
          Text("Relay（本机）").tag("relay")
          Text("DeepSeek 官方").tag("deepseek")
        }
        .pickerStyle(.segmented)
        Picker("模型", selection: $harness.model) {
          ForEach(harness.availableModels) { group in
            ForEach(group.models) { model in
              Text("\(group.name) / \(model.name)").tag(model.id)
            }
          }
          if harness.availableModels.isEmpty {
            Text("GPT-5.6 Terra").tag("gpt-5.6-terra")
          }
        }
        LabeledContent("Host 模型目录") {
          Button("刷新", action: harness.refreshModelConfiguration).buttonStyle(.bordered)
        }
      }

      Section {
        SecureField(harness.provider == "relay" ? "Relay API Key（写入 DSH Host）" : "DeepSeek API Key（写入 DSH Host）", text: $harness.apiKey)
        HStack {
          Spacer()
          Button("保存凭据", action: harness.saveCredential)
            .buttonStyle(.bordered)
            .disabled(harness.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        TextField("可选 API Base URL", text: $harness.baseURL)
      } header: {
        Text("凭据")
      } footer: {
        Label(harness.hasCredential ? "凭据已可用" : "请提供 API Key", systemImage: harness.hasCredential ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(harness.hasCredential ? .green : .orange)
      }
    }
    .formStyle(.grouped)
  }
}

private struct ProviderSettingsSection: View {
  @EnvironmentObject var harness: HarnessController

  var body: some View {
    Form {
      Section {
        HStack {
          Spacer()
          Button("刷新提供方配置", action: harness.refreshProviderConfiguration).buttonStyle(.bordered)
          Spacer()
        }
      }

      if let settings = harness.settingsDescription, let pi = settings.namespaces.first(where: { $0.ns == "llm-pi-ai" }) {
        Section {
          ForEach(harness.configurableProviders.filter { $0.settingsNs == pi.ns }) { provider in
            HStack {
              Text(provider.displayName)
              Spacer()
              Button("编辑") { harness.openProviderAuthoring(provider) }
                .buttonStyle(.bordered)
                .disabled(!settings.writable)
            }
          }
          HStack {
            Spacer()
            Button("添加自定义提供方") { harness.openProviderAuthoring() }
              .buttonStyle(.borderedProminent)
              .disabled(!settings.writable)
          }
        } header: {
          Text("llm-pi-ai")
        } footer: {
          Label(settings.writable ? "配置可写 · revision \(pi.revision)" : "配置只读", systemImage: settings.writable ? "checkmark.circle.fill" : "lock.fill")
            .font(.caption)
            .foregroundStyle(settings.writable ? .green : .orange)
        }
      } else {
        Section {
          Text("llm-pi-ai 未由当前 Host 提供。").foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct PluginSettingsSection: View {
  @EnvironmentObject var harness: HarnessController

  private var credentialRefs: [String] {
    Array(Set(harness.configurableProviders.compactMap { harness.providerCredentialReference($0) } + ["DEEPSEEK_API_KEY"])).sorted()
  }

  var body: some View {
    Form {
      Section {
        HStack {
          Text("已安装插件由内置 DSH runtime 管理。").foregroundStyle(.secondary)
          Spacer()
          Button("刷新", action: harness.refreshSettings).buttonStyle(.bordered)
        }
      }

      if let settings = harness.settingsDescription {
        Section {
          ForEach(settings.namespaces) { ns in
            HStack {
              Label("\(ns.ns) · \(ns.applies)", systemImage: "puzzlepiece")
              Spacer()
              Button("编辑") { harness.openSettingsEditor(ns: ns) }
                .buttonStyle(.bordered)
                .disabled(!settings.writable)
            }
          }
        } header: {
          Text("命名空间")
        } footer: {
          Label(settings.writable ? "配置可写" : "配置只读", systemImage: settings.writable ? "checkmark.circle.fill" : "lock.fill")
            .font(.caption)
            .foregroundStyle(settings.writable ? .green : .orange)
        }

        Section {
          ForEach(credentialRefs, id: \.self) { ref in
            HStack {
              Text(ref).font(.system(.body, design: .monospaced))
              Spacer()
              let configured = harness.credentialStates[ref]?.configured ?? false
              Text(configured ? "已配置" : "未配置")
                .font(.caption)
                .foregroundStyle(configured ? .green : .orange)
            }
          }
        } header: {
          Text("凭据")
        } footer: {
          Text("在命名空间编辑器里可写入或清除 API Key。")
        }
      } else {
        Section {
          Text("正在读取 Host 设置…").foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct PresetSettingsSection: View {
  @EnvironmentObject var harness: HarnessController

  var body: some View {
    Form {
      Section {
        ForEach(HarnessController.Preset.allCases) { preset in
          PresetRow(preset: preset, isSelected: harness.preset == preset, action: { harness.setPreset(preset) })
        }
      } footer: {
        Text("选择新会话使用的 Agent 能力组合。")
      }
    }
    .formStyle(.grouped)
  }
}

/// Broken out of `PresetSettingsSection`'s `ForEach` because the inline
/// closure (row layout + conditional checkmark + button chrome, all nested
/// inside `ForEach`) pushed Swift's type-checker into misdiagnosing the
/// `ForEach` overload entirely rather than reporting the real issue.
private struct PresetRow: View {
  let preset: HarnessController.Preset
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(preset.label).font(.headline)
          Text(preset.detail).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if isSelected {
          Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
        }
      }
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
  }
}
