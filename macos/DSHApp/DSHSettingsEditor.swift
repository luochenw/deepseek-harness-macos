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
/// it was read at, and writes/clears an arbitrary credential ref through
/// credentials.set / credentials.unset — free text, not limited to the two
/// built-in refs, since Host deployments can wire a provider's `apiKeyEnv`
/// to any name (e.g. a local relay override).
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
    VStack(alignment: .leading, spacing: 12) {
      Text("编辑配置：\(namespace.ns)").font(.title2.weight(.bold))
      Text("applies: \(namespace.applies) · revision \(currentNamespace.revision)").font(.caption).foregroundStyle(.secondary)

      if conflict {
        VStack(alignment: .leading, spacing: 8) {
          Label("配置已被其他客户端修改（当前 revision \(currentNamespace.revision)）", systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.bold)).foregroundStyle(.orange)
          HStack {
            Button("放弃我的修改，载入最新") { jsonText = Self.prettyJSON(currentNamespace.value); conflict = false }
            Button("保留我的修改，基于最新版本重试保存") { conflict = false; save() }.buttonStyle(.borderedProminent)
          }
        }.padding(10).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      }

      TextEditor(text: $jsonText)
        .font(.system(.body, design: .monospaced))
        .frame(minHeight: 200)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))

      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }

      HStack {
        Button("重置") { jsonText = Self.prettyJSON(currentNamespace.value) }
        Spacer()
        Button("保存") { save() }.buttonStyle(.borderedProminent)
      }

      Divider()

      Text("凭据").font(.headline)
      TextField("凭据引用（如 RELAY_API_KEY、LOCAL_RELAY_API_KEY）", text: $credentialRef)
      HStack(spacing: 6) {
        ForEach(["RELAY_API_KEY", "DEEPSEEK_API_KEY"], id: \.self) { ref in
          Button(ref) { credentialRef = ref }.buttonStyle(.bordered).font(.caption)
        }
      }
      SecureField("写入新值（留空保持不变）", text: $credentialValue)
      HStack {
        Button("写凭据") { saveCredential() }
          .disabled(credentialRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || credentialValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("清除凭据") { unsetCredential() }
          .disabled(credentialRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Spacer()
        Text(harness.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Button("关闭") { harness.showSettingsEditor = false }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 600, height: 560)
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
