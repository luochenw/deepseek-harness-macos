import Foundation
struct DSHAgentPreset: Decodable, Identifiable { let id: String; let trust: String?; let isDefault: Bool; let name: String?; let description: String?; let broken: String? }
/// DSH 0.2 exposes a read-only roster. Authoring flags remain optional so the
/// native manager can keep its existing presentation without inventing support.
struct DSHAgentPresetList: Decodable { let presets: [DSHAgentPreset]; let authorable: Bool?; let hasDocument: Bool? }
struct DSHSelectPresetPayload: Encodable { let sessionId: String; let agentPreset: String }
struct DSHSelectPresetResult: Decodable { let agentPreset: String }
struct DSHSelectPresetArgs: Encodable { let agentId: String; let agentPreset: String }

struct DSHPresetIdPayload: Encodable { let agentPreset: String }
struct DSHPresetReadResult: Decodable, Identifiable {
  let agentPreset: String
  let trust: String?
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
  /// Full read-only roster (`presets()` in DSHHostClientExtensions.swift keeps
  /// returning the rows only).
  func presetCatalog() async throws -> DSHAgentPresetList {
    let roster = try await call("agentPresets/list", args: EmptyPayload(), as: DSHAgentPresetList.self)
    return DSHAgentPresetList(presets: roster.presets, authorable: false, hasDocument: false)
  }
  func readPreset(_ agentPreset: String) async throws -> DSHPresetReadResult {
    try await call("agentPresets/read", args: DSHPresetIdPayload(agentPreset: agentPreset), as: DSHPresetReadResult.self)
  }
  func copyPreset(from: String, to agentPreset: String, name: String?) async throws -> String {
    throw URLError(.unsupportedURL)
  }
  func openPresetDocument(_ agentPreset: String) async throws -> DSHPresetOpenDocumentResult { throw URLError(.unsupportedURL) }
  func removePreset(_ agentPreset: String) async throws { throw URLError(.unsupportedURL) }
}
