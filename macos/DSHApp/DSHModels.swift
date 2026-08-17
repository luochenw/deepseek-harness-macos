import Foundation

struct DSHModelCatalogModel: Decodable, Identifiable { let id: String; let name: String; var description: String? }
struct DSHModelGroup: Decodable, Identifiable { let id: String; let name: String; let models: [DSHModelCatalogModel] }
struct DSHModelCatalog: Decodable { let groups: [DSHModelGroup] }
struct DSHCredentialView: Decodable { let configured: Bool; let source: String?; let writable: Bool }
struct DSHCredentialCatalog: Decodable { let credentials: [String: DSHCredentialView] }
struct DSHCredentialRefsPayload: Encodable { let refs: [String] }

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
