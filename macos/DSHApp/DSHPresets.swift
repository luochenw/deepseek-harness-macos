import Foundation
struct DSHAgentPreset: Decodable, Identifiable { let id: String; let trust: String; let isDefault: Bool; let name: String?; let description: String?; let broken: String? }
/// `authorable` / `hasDocument` are deployment facts carried by every
/// agentPreset.list reply (agent-presets.d.ts). Optional here so older decode
/// sites that only consume `presets` keep working unchanged.
struct DSHAgentPresetList: Decodable { let presets: [DSHAgentPreset]; let authorable: Bool?; let hasDocument: Bool? }
struct DSHSelectPresetPayload: Encodable { let sessionId: String; let agentPreset: String }
struct DSHSelectPresetResult: Decodable { let agentPreset: String }

struct DSHPresetIdPayload: Encodable { let agentPreset: String }
struct DSHPresetReadResult: Decodable, Identifiable {
  let agentPreset: String
  let trust: String
  let content: String
  let name: String?
  let description: String?
  var id: String { agentPreset }
}
struct DSHPresetCopyPayload: Encodable { let from: String; let agentPreset: String; let name: String? }
struct DSHPresetCopyResult: Decodable { let agentPreset: String }
/// Wire union `{opened: true} | {opened: false, path}` flattened: `path` is
/// present exactly when the deployment has no native opener.
struct DSHPresetOpenDocumentResult: Decodable { let opened: Bool; let path: String? }

extension DSHHostClient {
  /// Full agentPreset.list reply including the deployment's authorable /
  /// hasDocument facts (`presets()` in DSHHostClientExtensions.swift keeps
  /// returning the roster only).
  func presetCatalog() async throws -> DSHAgentPresetList { try await call("agentPreset.list", payload: EmptyPayload(), as: DSHAgentPresetList.self) }
  func readPreset(_ agentPreset: String) async throws -> DSHPresetReadResult { try await call("agentPreset.read", payload: DSHPresetIdPayload(agentPreset: agentPreset), as: DSHPresetReadResult.self) }
  func copyPreset(from: String, to agentPreset: String, name: String?) async throws -> String {
    try await call("agentPreset.copy", payload: DSHPresetCopyPayload(from: from, agentPreset: agentPreset, name: name), as: DSHPresetCopyResult.self).agentPreset
  }
  func openPresetDocument(_ agentPreset: String) async throws -> DSHPresetOpenDocumentResult { try await call("agentPreset.openDocument", payload: DSHPresetIdPayload(agentPreset: agentPreset), as: DSHPresetOpenDocumentResult.self) }
  func removePreset(_ agentPreset: String) async throws { _ = try await call("agentPreset.remove", payload: DSHPresetIdPayload(agentPreset: agentPreset), as: EmptyPayload.self) }
}
