import SwiftUI

/// Native editor for one Host-owned custom API configuration. It writes only
/// profile fields it displays and keeps the API-key draft local and write-only.
struct ProviderAuthoringView: View {
  @EnvironmentObject private var harness: HarnessController
  let namespace: DSHSettingsNamespace
  let provider: DSHConfigurableProvider?

  @State private var route = ""
  @State private var displayName = ""
  @State private var baseURL = ""
  @State private var api = "openai-completions"
  @State private var models = ""
  @State private var credential = ""
  @State private var error: String?

  private let protocols = ["openai-completions", "openai-responses", "anthropic-messages"]

  init(namespace: DSHSettingsNamespace, provider: DSHConfigurableProvider? = nil) {
    self.namespace = namespace
    self.provider = provider
    let profile = provider.flatMap { namespace.value.objectValue(at: $0.settingsPath) }
    _route = State(initialValue: provider?.provider ?? "")
    _displayName = State(initialValue: profile?.string("displayName") ?? provider?.displayName ?? "")
    _baseURL = State(initialValue: profile?.string("baseURL") ?? "")
    _api = State(initialValue: profile?.string("api") ?? "openai-completions")
    _models = State(initialValue: profile?.modelIDs.joined(separator: ", ") ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s5) {
      VStack(alignment: .leading, spacing: DSHSpace.s1) {
        Text(provider == nil ? "添加自定义配置" : "编辑自定义配置")
          .font(.title2.weight(.bold))
          .foregroundStyle(DSHTheme.ink)
        Text("llm-pi-ai · revision \(namespace.revision)")
          .font(.caption)
          .foregroundStyle(DSHTheme.inkFaint)
      }

      basicInfoSection
      credentialSection

      if let error {
        Text(error)
          .font(.caption)
          .foregroundStyle(DSHTheme.coral)
          .padding(.horizontal, DSHSpace.s3).padding(.vertical, DSHSpace.s2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .dshCard(tint: DSHTheme.coralSoft, radius: DSHRadius.sm)
      }

      HStack {
        Spacer()
        Button("取消") { harness.showProviderAuthoring = false }
          .buttonStyle(.dshGhost)
          .keyboardShortcut(.cancelAction)
        Button(provider == nil ? "创建" : "保存") { save() }
          .buttonStyle(.dshPrimary)
          .disabled(!canSave)
      }
    }
    .padding(DSHSpace.s5)
    .frame(width: 560)
    .background(DSHTheme.canvas)
  }

  private var basicInfoSection: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      Text("连接信息").dshSectionLabel()
      Text("配置 ID").dshSectionLabel()
      TextField("小写字母开头，可含数字和短横线", text: $route)
        .disabled(provider != nil)
        .dshField()
      Text("显示名称（可选）").dshSectionLabel()
      TextField("例如 团队网关", text: $displayName)
        .dshField()
      Text("API 地址").dshSectionLabel()
      TextField("https://api.example.com/v1", text: $baseURL)
        .dshField()
      Picker("API 协议", selection: $api) {
        ForEach(protocols, id: \.self) { Text($0).tag($0) }
      }
      .tint(DSHTheme.accent)
      Text("模型 ID").dshSectionLabel()
      TextField("使用逗号分隔，例如 gpt-4.1, claude-sonnet-4", text: $models)
        .dshField()
    }
    .padding(DSHSpace.s4)
    .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.lg)
  }

  private var credentialSection: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      HStack(spacing: DSHSpace.s2) {
        Text("API Key").dshSectionLabel()
        if credentialConfigured {
          DSHBadge(text: credentialWritable == false ? "只读" : "已配置", tone: credentialWritable == false ? .warm : .accent)
        }
      }
      Text("仅写入；不会显示或保存在界面中")
        .font(.caption)
        .foregroundStyle(DSHTheme.inkSoft)
      SecureField(credentialConfigured ? "已配置——输入新值以替换" : "输入 API Key（可留空）", text: $credential)
        .disabled(credentialWritable == false)
        .dshField()
      if credentialWritable == false {
        Text("该凭据由 Host 标记为只读。")
          .font(.caption)
          .foregroundStyle(DSHTheme.warm)
      }
    }
    .padding(DSHSpace.s4)
    .dshCard(tint: DSHTheme.surfaceTint2, radius: DSHRadius.lg)
  }

  private var normalizedRoute: String { route.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var profile: [String: DSHJSONValue]? { provider.flatMap { namespace.value.objectValue(at: $0.settingsPath) } }
  private var keyRef: String { profile?.apiKeyEnv ?? "\(normalizedRoute.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY" }
  private var credentialState: DSHCredentialView? { harness.credentialStates[keyRef] }
  private var credentialConfigured: Bool { credentialState?.configured == true }
  private var credentialWritable: Bool? { credentialState?.writable }
  private var canSave: Bool {
    guard normalizedRoute.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
          !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !modelIDs.isEmpty else { return false }
    return credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || credentialWritable != false
  }
  private var modelIDs: [String] {
    models.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }

  private func save() {
    error = nil
    guard provider != nil || !harness.configurableProviders.contains(where: { $0.provider == normalizedRoute }) else {
      error = "该配置 ID 已存在。"
      return
    }
    let path = provider?.settingsPath ?? ["providers", normalizedRoute]
    let ops = profileOperations(path: path)
    let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
    var profileOps = ops
    if !key.isEmpty, profile?.apiKeyEnv != keyRef {
      profileOps.append(.set(path: path + ["apiKeyEnv"], value: .string(keyRef)))
    }
    harness.saveProviderProfile(namespace: namespace, ops: profileOps, credentialRef: key.isEmpty ? nil : keyRef, credentialValue: key) { result in
      if case let .failure(saveError) = result { error = saveError.localizedDescription }
    }
    credential = ""
  }

  /// Existing profiles can carry gateway-specific fields the native form does
  /// not expose. Update only the keys this form owns so those fields survive.
  private func profileOperations(path: [String]) -> [DSHSettingsPathOperation] {
    let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let modelsValue = DSHJSONPatchValue.array(modelIDs.map(modelPatchValue))

    guard let profile else {
      var created: [String: DSHJSONPatchValue] = [
        "baseURL": .string(normalizedBaseURL),
        "api": .string(api),
        "models": modelsValue,
      ]
      if !normalizedDisplayName.isEmpty { created["displayName"] = .string(normalizedDisplayName) }
      return [.set(path: path, value: .object(created))]
    }

    var ops: [DSHSettingsPathOperation] = []
    if profile.string("baseURL") != normalizedBaseURL {
      ops.append(.set(path: path + ["baseURL"], value: .string(normalizedBaseURL)))
    }
    if profile.string("api") != api {
      ops.append(.set(path: path + ["api"], value: .string(api)))
    }
    if profile.modelIDs != modelIDs {
      ops.append(.set(path: path + ["models"], value: modelsValue))
    }
    if normalizedDisplayName.isEmpty {
      if profile.string("displayName") != nil { ops.append(.unset(path: path + ["displayName"])) }
    } else if profile.string("displayName") != normalizedDisplayName {
      ops.append(.set(path: path + ["displayName"], value: .string(normalizedDisplayName)))
    }
    return ops
  }

  private func modelPatchValue(_ id: String) -> DSHJSONPatchValue {
    guard case let .array(values)? = profile?["models"],
          let existing = values.first(where: { $0.object?["id"]?.string == id }),
          case let .object(object) = existing else {
      return .object(["id": .string(id)])
    }
    return .object(object.mapValues(\.patchValue))
  }
}

extension DSHJSONValue {
  func objectValue(at path: [String]) -> [String: DSHJSONValue]? {
    var current: DSHJSONValue = self
    for key in path {
      guard case let .object(object) = current, let next = object[key] else { return nil }
      current = next
    }
    guard case let .object(object) = current else { return nil }
    return object
  }

  subscript(_ key: String) -> DSHJSONValue? {
    guard case let .object(object) = self else { return nil }
    return object[key]
  }

  var patchValue: DSHJSONPatchValue {
    switch self {
    case .string(let value): .string(value)
    case .number(let value): .number(value)
    case .bool(let value): .bool(value)
    case .object(let value): .object(value.mapValues(\.patchValue))
    case .array(let value): .array(value.map(\.patchValue))
    case .null: .null
    }
  }
}
