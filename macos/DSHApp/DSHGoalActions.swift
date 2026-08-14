import Foundation


struct DSHGoalRef: Codable { let id: String; let revision: Int }
struct DSHGoalActionPayload: Encodable { let sessionId: String; let ref: DSHGoalRef }
struct DSHGoalActionResult: Decodable { let ref: DSHGoalRef }
