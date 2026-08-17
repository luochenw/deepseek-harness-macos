import SwiftUI

/// Extend the decodable JSON value with encoding so the editor can render a
/// namespace's redacted value back to text before sending it as a patch.
extension DSHJSONValue: Encodable {
  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

/// Sheet editor for one settings namespace. Shows the redacted value as
/// editable JSON text, saves it back through settings.update with the revision
/// it was read at, and manages the Relay / DeepSeek API keys through
/// credentials.set / credentials.unset.
struct SettingsEditorView: View {
  @EnvironmentObject var harness: HarnessController
  let namespace: DSHSettingsNamespace

  @State private var jsonText = ""
  @State private var credentialRef = "RELAY_API_KEY"
  @State private var credentialValue = ""
  @State private var error: String?
  @State private var conflict = false

  /// The freshest known namespace value/revision — kept live from
  /// `harness.settingsDescription` rather than frozen at sheet-open time, so
  /// the conflict-recovery actions below always act on current state.
  private var currentNamespace: DSHSettingsNamespace {
    harness.settingsDescription?.namespaces.first(where: { $0.ns == namespace.ns }) ?? namespace
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      Text("编辑配置：\(namespace.ns)").font(.title2.weight(.bold)).foregroundStyle(DSHTheme.ink)
      Text("applies: \(namespace.applies) · revision \(currentNamespace.revision)").font(.caption).foregroundStyle(DSHTheme.inkSoft)

      if conflict {
        VStack(alignment: .leading, spacing: DSHSpace.s2) {
          Label("配置已被其他客户端修改（当前 revision \(currentNamespace.revision)）", systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.bold)).foregroundStyle(DSHTheme.warm)
          HStack(spacing: DSHSpace.s2) {
            Button("放弃我的修改，载入最新") { jsonText = Self.prettyJSON(currentNamespace.value); conflict = false }.buttonStyle(.dshSecondary)
            Button("保留我的修改，基于最新版本重试保存") { conflict = false; save() }.buttonStyle(.dshPrimary)
          }
        }.padding(DSHSpace.s3).dshCard(tint: DSHTheme.warmSoft, radius: DSHRadius.md)
      }

      TextEditor(text: $jsonText)
        .font(.system(.body, design: .monospaced))
        .scrollContentBackground(.hidden)
        .frame(minHeight: 200)
        .padding(DSHSpace.s2)
        .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)

      if let error {
        Text(error).font(.caption).foregroundStyle(DSHTheme.coral)
      }

      HStack(spacing: DSHSpace.s2) {
        Button("重置") { jsonText = Self.prettyJSON(currentNamespace.value) }.buttonStyle(.dshSecondary)
        Spacer()
        Button("保存") { save() }.buttonStyle(.dshPrimary)
      }

      VStack(alignment: .leading, spacing: DSHSpace.s3) {
        Text("凭据").font(.headline).foregroundStyle(DSHTheme.ink)
        Picker("凭据引用", selection: $credentialRef) {
          Text("RELAY_API_KEY").tag("RELAY_API_KEY")
          Text("DEEPSEEK_API_KEY").tag("DEEPSEEK_API_KEY")
        }.pickerStyle(.segmented)
        SecureField("写入新值（留空保持不变）", text: $credentialValue).dshField()
        HStack(spacing: DSHSpace.s2) {
          Button("写凭据") { saveCredential() }.buttonStyle(.dshPrimary).disabled(credentialValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("清除凭据") { unsetCredential() }.buttonStyle(.dshSecondary)
          Spacer()
          Text(harness.status).font(.caption).foregroundStyle(DSHTheme.inkSoft).lineLimit(1)
          Button("关闭") { harness.showSettingsEditor = false }.buttonStyle(.dshSecondary).keyboardShortcut(.cancelAction)
        }
      }.padding(DSHSpace.s4).dshCard(tint: DSHTheme.surfaceTint2, radius: DSHRadius.md)
    }
    .padding(DSHSpace.s5)
    .frame(width: 600, height: 560)
    .background(DSHTheme.surface)
    .onAppear { jsonText = Self.prettyJSON(namespace.value) }
  }

  private func save() {
    error = nil
    guard let patch = Self.parseObject(jsonText) else {
      error = "JSON 无效，无法保存。请检查后重试。"
      return
    }
    harness.saveSettings(ns: namespace.ns, patch: patch, revision: currentNamespace.revision, conflict: {
      conflict = true
      harness.refreshSettings()
    })
  }

  private func saveCredential() {
    error = nil
    harness.saveCredential(ref: credentialRef, value: credentialValue)
    credentialValue = ""
  }

  private func unsetCredential() {
    error = nil
    harness.unsetCredential(ref: credentialRef)
  }

  /// Render a namespace value as pretty JSON text for the editor buffer.
  private static func prettyJSON(_ value: DSHJSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
  }

  /// Parse the editor buffer back into a JSON object patch.
  private static func parseObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data),
          let object = raw as? [String: Any] else { return nil }
    return object
  }
}
