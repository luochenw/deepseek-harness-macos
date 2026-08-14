import Foundation


struct DSHSubagentEntry: Decodable, Identifiable {
  let kind: String
  let id: String
  let activity: String?
  let hasChildren: Bool?
  let mode: String?
  let label: String?
  let reason: String?
}

struct DSHSubagentCatalog: Decodable {
  let entries: [DSHSubagentEntry]
  let parentAvailable: Bool
}

struct DSHSubagentListPayload: Encodable { let parentSessionId: String }

struct DSHSubagentAddress: Encodable {
  let parentSessionId: String
  let childSessionId: String
  let mode: String
}

struct DSHSubagentInterruptReceipt: Decodable { let accepted: Bool }
struct DSHSubagentHistoryPayload: Encodable { let parentSessionId: String; let childSessionId: String; let mode: String; let maxMessages: Int }
struct DSHSubagentPromptPayload: Encodable { let parentSessionId: String; let childSessionId: String; let mode: String; let content: [DSHPromptContent] }
struct DSHSubagentPromptReceipt: Decodable { let messageId: String }
