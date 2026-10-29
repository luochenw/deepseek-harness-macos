import Foundation
struct DSHSessionModels: Decodable {
  let current: DSHSelectedModel
  let routable: Bool
  let groups: [DSHModelGroup]
}
struct DSHSessionIDModelPayload: Encodable { let sessionId: String }
