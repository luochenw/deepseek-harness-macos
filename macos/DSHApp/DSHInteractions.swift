import Foundation


struct DSHClientResponse<Value: Encodable>: Encodable {
  let type = "client-response"
  let rpcId: String
  let result: DSHClientResponseResult<Value>
}

struct DSHClientResponseResult<Value: Encodable>: Encodable {
  let ok = true
  let value: Value
}

struct DSHApprovalAnswer: Encodable {
  let sessionId: String
  let approvalId: String
  let outcome: String
}

struct DSHQuestionAnswer: Encodable {
  struct Item: Encodable { let id: String; let selected: [String]; let custom: String? }
  let sessionId: String
  let answer: [Item]
}
