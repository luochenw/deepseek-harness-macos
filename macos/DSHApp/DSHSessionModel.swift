import Foundation

struct DSHSelectModelPayload: Encodable { let sessionId: String; let provider: String; let model: String; let reasoningEffort: String? }
struct DSHSelectModelResult: Decodable { let selected: DSHSelectedModel }
struct DSHSelectedModel: Decodable { let provider: String; let model: String; let reasoningEffort: String? }
