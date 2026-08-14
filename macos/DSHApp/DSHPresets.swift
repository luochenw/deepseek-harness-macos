import Foundation
struct DSHAgentPreset: Decodable, Identifiable { let id: String; let trust: String; let isDefault: Bool; let name: String?; let description: String?; let broken: String? }
struct DSHAgentPresetList: Decodable { let presets: [DSHAgentPreset] }
struct DSHSelectPresetPayload: Encodable { let sessionId: String; let agentPreset: String }
struct DSHSelectPresetResult: Decodable { let agentPreset: String }
