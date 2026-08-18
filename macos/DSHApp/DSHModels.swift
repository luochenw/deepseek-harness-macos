import Foundation

/// Adapter-owned reasoning metadata on a catalog model (apiproxy
/// `modelReasoningSchema`). Absent entirely for a model that offers no
/// selectable effort — hand-declared routes without `reasoningEfforts`, and
/// catalog models pi-ai marks non-reasoning — in which case the adapter
/// accepts only "off" (or an omitted effort) at `session.selectModel`; any
/// other level is rejected with UNSUPPORTED_REASONING_EFFORT.
struct DSHModelReasoningEffort: Decodable, Identifiable { let id: String; let name: String; var description: String? }
struct DSHModelReasoning: Decodable { let efforts: [DSHModelReasoningEffort]; let defaultEffort: String? }
struct DSHModelCatalogModel: Decodable, Identifiable { let id: String; let name: String; var description: String?; var reasoning: DSHModelReasoning? }
struct DSHModelGroup: Decodable, Identifiable { let id: String; let name: String; let models: [DSHModelCatalogModel] }
struct DSHModelCatalog: Decodable { let groups: [DSHModelGroup] }
struct DSHCredentialView: Decodable { let configured: Bool; let source: String?; let writable: Bool }
struct DSHCredentialCatalog: Decodable { let credentials: [String: DSHCredentialView] }
struct DSHCredentialRefsPayload: Encodable { let refs: [String] }

extension DSHModelGroup {
  /// Preserve the legacy route ID on the wire while presenting it as the
  /// generic custom-configuration entry everywhere in the native UI.
  var nativeDisplayName: String { id == "relay" ? "自定义配置" : name }
}

/// llm.discoverModels draft payload (llm.d.ts): `settingsNs` selects the
/// adapter family; `provider` names an existing route (answered from the
/// adapter registry, no endpoint needed); `baseURL`/`api`/`apiKey` describe a
/// route the adapter does not know yet. Nil fields are omitted from the wire.
struct DSHDiscoverModelsPayload: Encodable {
  let settingsNs: String
  let provider: String?
  let baseURL: String?
  let api: String?
  let apiKey: String?
}
struct DSHDiscoveredModel: Decodable, Identifiable { let id: String; let name: String?; let contextWindow: Int?; let maxTokens: Int? }
struct DSHDiscoveredModelList: Decodable { let models: [DSHDiscoveredModel] }

extension DSHHostClient {
  func discoverModels(settingsNs: String, provider: String? = nil, baseURL: String? = nil, api: String? = nil, apiKey: String? = nil) async throws -> [DSHDiscoveredModel] {
    try await call(
      "llm.discoverModels",
      payload: DSHDiscoverModelsPayload(settingsNs: settingsNs, provider: provider, baseURL: baseURL, api: api, apiKey: apiKey),
      as: DSHDiscoveredModelList.self,
    ).models
  }
}

extension HarnessController {
  /// Interrogate an already-configured provider route for the models it
  /// advertises. The adapter answers from its own registry when it describes
  /// the route, so no endpoint fields are needed.
  func discoverModels(provider: DSHConfigurableProvider) async throws -> [DSHDiscoveredModel] {
    try await discoverModels(settingsNs: provider.settingsNs, provider: provider.provider)
  }

  /// Draft form: interrogate an endpoint the configuration surface is still
  /// editing. Nothing is written — the reply is candidates only, and `apiKey`
  /// is never stored or echoed by the Host.
  func discoverModels(settingsNs: String, provider: String? = nil, baseURL: String? = nil, api: String? = nil, apiKey: String? = nil) async throws -> [DSHDiscoveredModel] {
    guard let hostClient else { throw URLError(.cannotConnectToHost) }
    return try await hostClient.discoverModels(settingsNs: settingsNs, provider: provider, baseURL: baseURL, api: api, apiKey: apiKey)
  }
}

extension HarnessController {
  /// `reasoning` nil means "don't ask for a specific effort" — sent to the
  /// Host as an omitted field (not a fallback to whatever `reasoningEffort`
  /// happened to be left at), so switching to a model that doesn't support
  /// the previously-selected model's effort (e.g. Relay's models have no
  /// `reasoning.efforts` at all, so "high"/"max" from a DeepSeek-official
  /// pick get rejected as `model-unavailable`) lets the Host fall back to
  /// that model's own default instead of failing the switch outright.
  func selectCurrentModel(provider: String, model: String, reasoning: String? = nil) {
    let nextProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
    let nextModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !nextProvider.isEmpty, !nextModel.isEmpty else { return }
    self.provider = nextProvider
    self.model = nextModel
    if let reasoning { self.reasoningEffort = reasoning }
    // Persist the full triple — restoring provider/model but resetting the
    // effort would recreate invalid pairs on relaunch (e.g. a model that only
    // supports "off" coming back with the hardcoded "high" default).
    UserDefaults.standard.set(nextProvider, forKey: providerKey)
    UserDefaults.standard.set(nextModel, forKey: modelKey)
    UserDefaults.standard.set(reasoningEffort, forKey: reasoningEffortKey)
    // No live session yet: keep the local choice; newSession() pushes it via
    // session.selectModel the moment the next session is created.
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task {
      do {
        let selected = try await hostClient.selectModel(sessionId: sessionId, provider: nextProvider, model: nextModel, reasoningEffort: reasoning)
        await MainActor.run {
          // Sync back whatever effort the Host actually resolved to (its
          // own default when we omitted one) so the composer label doesn't
          // keep showing a stale effort the switch didn't actually request.
          if let resolved = selected.reasoningEffort { self.reasoningEffort = resolved }
          self.status = "已切换到 \(self.nativeProviderDisplayName(nextProvider)) / \(nextModel)"
        }
      } catch { await MainActor.run { self.appendSystem("模型切换失败：\(error.localizedDescription)") } }
    }
  }

  func setPreset(_ next: Preset) {
    preset = next
    UserDefaults.standard.set(next.rawValue, forKey: presetKey)
    appendSystem("新会话将使用\(next.label)。当前运行中的会话不受影响。")
  }

  private func nativeProviderDisplayName(_ provider: String) -> String {
    availableModels.first(where: { $0.id == provider })?.nativeDisplayName
      ?? (provider == "relay" ? "自定义配置" : provider)
  }

  func toolDetail(_ tool: ToolActivity) { selectedTool = tool; showDetails = true }
}
