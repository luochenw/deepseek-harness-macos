import Foundation

struct DSHSkillEntry: Decodable, Identifiable {
  let name: String
  let description: String
  let whenToUse: String?
  let modelInvocable: Bool
  var id: String { name }
}
struct DSHSkillList: Decodable { let skills: [DSHSkillEntry] }
struct DSHSessionIDPayload: Encodable { let sessionId: String }
