import SwiftUI

/// Native editor for the Host-owned llm-pi-ai provider directory. It writes only
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
    VStack(alignment: .leading, spacing: 14) {
      Text(provider == nil ? "添加自定义提供方" : "编辑提供方")
        .font(.title2.weight(.bold))
      Text("llm-pi-ai · revision \(namespace.revision)").font(.caption).foregroundStyle(.secondary)

      TextField("Provider ID（小写字母开头，可含数字和短横线）", text: $route)
        .disabled(provider != nil)
      TextField("显示名称", text: $displayName)
      TextField("API 地址", text: $baseURL)
      Picker("API 协议", selection: $api) {
        ForEach(protocols, id: \.self) { Text($0).tag($0) }
      }
      TextField("模型 ID（使用逗号分隔）", text: $models)

      Divider()
      Text("API Key（仅写入；不会显示或保存在界面中）").font(.headline)
      SecureField(credentialConfigured ? "已配置——输入新值以替换" : "输入 API Key（可留空）", text: $credential)
        .disabled(credentialWritable == false)
      if credentialWritable == false {
        Text("该凭据由 Host 标记为只读。") .font(.caption).foregroundStyle(.orange)
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }

      HStack {
        Spacer()
        Button("取消") { harness.showProviderAuthoring = false }.keyboardShortcut(.cancelAction)
        Button(provider == nil ? "创建" : "保存") { save() }
          .buttonStyle(.borderedProminent)
          .disabled(!canSave)
      }
    }
    .padding(24)
    .frame(width: 560)
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
      error = "该 Provider ID 已存在。"
      return
    }
    let path = provider?.settingsPath ?? ["providers", normalizedRoute]
    var profile: [String: DSHJSONPatchValue] = [
      "baseURL": .string(baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
      "api": .string(api),
      "models": .array(modelIDs.map { .object(["id": .string($0)]) }),
    ]
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty { profile["displayName"] = .string(name) }
    let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
    // Retain an existing reference when rotating nothing; its secret value stays
    // exclusively behind the Host credential API.
    if let existingRef = self.profile?.apiKeyEnv { profile["apiKeyEnv"] = .string(existingRef) }
    if !key.isEmpty { profile["apiKeyEnv"] = .string(keyRef) }
    harness.saveProviderProfile(namespace: namespace, path: path, profile: profile, credentialRef: key.isEmpty ? nil : keyRef, credentialValue: key) { result in
      if case let .failure(saveError) = result { error = saveError.localizedDescription }
    }
    credential = ""
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
}
