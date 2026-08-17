import SwiftUI

/// Extend the decodable JSON value with encoding so the editor can render a
/// namespace's redacted value back to text before diffing it as path ops.
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
/// editable JSON text; on save it diffs the edited JSON against the snapshot
/// taken when the text was loaded and commits only the changed paths as
/// revisioned `settings.mutate` ops. `role('secret')` fields are structurally
/// removed from the described value (no sentinel), so a root-level replace
/// would erase stored secrets — the diff guarantees untouched keys (secrets
/// included, since they never appear in either side of the diff) are never
/// written. Also manages the Relay / DeepSeek API keys through
/// credentials.set / credentials.unset.
struct SettingsEditorView: View {
  @EnvironmentObject var harness: HarnessController
  let namespace: DSHSettingsNamespace

  @State private var jsonText = ""
  /// Plain-JSON snapshot of the value the editor buffer was loaded from; the
  /// save diff runs against this, so only keys the user actually edited are
  /// sent to the Host.
  @State private var baseline: [String: Any] = [:]
  @State private var credentialRef = "RELAY_API_KEY"
  @State private var credentialValue = ""
  @State private var error: String?
  @State private var notice: String?
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
            Button("放弃我的修改，载入最新") { load(currentNamespace); conflict = false }.buttonStyle(.dshSecondary)
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
      if let notice {
        Text(notice).font(.caption).foregroundStyle(DSHTheme.inkSoft)
      }

      HStack(spacing: DSHSpace.s2) {
        Button("重置") { load(currentNamespace) }.buttonStyle(.dshSecondary)
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
    .onAppear { load(namespace) }
  }

  /// Fill the editor buffer from a namespace value and reset the diff baseline
  /// to match, so a subsequent save diffs against exactly what is shown.
  private func load(_ source: DSHSettingsNamespace) {
    jsonText = Self.prettyJSON(source.value)
    baseline = Self.plainValue(source.value) as? [String: Any] ?? [:]
  }

  private func save() {
    error = nil
    notice = nil
    guard let edited = Self.parseObject(jsonText) else {
      error = "JSON 无效，无法保存。请检查后重试。"
      return
    }
    let ops = Self.diffOperations(old: baseline, new: edited, path: [])
    guard !ops.isEmpty else {
      notice = "没有修改，无需保存"
      return
    }
    harness.mutateSettings(
      ns: namespace.ns,
      ops: ops,
      revision: currentNamespace.revision,
      success: { _ in harness.showSettingsEditor = false },
      conflict: {
        conflict = true
        harness.refreshSettings()
      }
    )
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

  /// Parse the editor buffer back into a plain JSON object.
  private static func parseObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data),
          let object = raw as? [String: Any] else { return nil }
    return object
  }

  /// Convert a decoded namespace value into the plain Foundation JSON shapes
  /// `JSONSerialization` produces, so the baseline and the parsed editor
  /// buffer diff over one representation.
  private static func plainValue(_ value: DSHJSONValue) -> Any {
    switch value {
    case .string(let value): return value
    case .number(let value): return value
    case .bool(let value): return value
    case .object(let value): return value.mapValues(plainValue)
    case .array(let value): return value.map(plainValue)
    case .null: return NSNull()
    }
  }

  /// Minimal path ops turning `old` into `new`: unchanged keys produce no op
  /// at all (so redacted secret fields — absent from both sides — are never
  /// written), object values recurse so sibling edits do not replace a whole
  /// subtree, and everything else is set or unset at its own path.
  private static func diffOperations(old: [String: Any], new: [String: Any], path: [String]) -> [DSHSettingsPathOperation] {
    var ops: [DSHSettingsPathOperation] = []
    for key in Set(old.keys).union(new.keys).sorted() {
      let childPath = path + [key]
      switch (old[key], new[key]) {
      case (nil, nil):
        continue
      case (nil, let added?):
        // Parsed JSON always converts; `.null` is an unreachable fallback.
        ops.append(.set(path: childPath, value: DSHJSONPatchValue(added) ?? .null))
      case (_?, nil):
        ops.append(.unset(path: childPath))
      case (let before?, let after?):
        if deepEqual(before, after) { continue }
        if let beforeObject = before as? [String: Any], let afterObject = after as? [String: Any] {
          ops.append(contentsOf: diffOperations(old: beforeObject, new: afterObject, path: childPath))
        } else {
          ops.append(.set(path: childPath, value: DSHJSONPatchValue(after) ?? .null))
        }
      }
    }
    return ops
  }

  /// Structural equality over plain JSON values (objects, arrays, numbers,
  /// strings, bools, null) — the diff's change-detection predicate.
  private static func deepEqual(_ a: Any, _ b: Any) -> Bool {
    switch (a, b) {
    case (is NSNull, is NSNull):
      return true
    case (let a as [String: Any], let b as [String: Any]):
      guard a.count == b.count else { return false }
      return a.allSatisfy { key, value in b[key].map { deepEqual(value, $0) } ?? false }
    case (let a as [Any], let b as [Any]):
      guard a.count == b.count else { return false }
      return zip(a, b).allSatisfy { deepEqual($0, $1) }
    case (let a as String, let b as String):
      return a == b
    case (let a as NSNumber, let b as NSNumber):
      return a == b
    default:
      return false
    }
  }
}
