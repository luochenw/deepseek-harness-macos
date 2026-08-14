import Foundation


indirect enum DSHJSONValue: Decodable {
  case string(String), number(Double), bool(Bool), object([String: DSHJSONValue]), array([DSHJSONValue]), null
  init(from decoder: Decoder) throws {
    let box = try decoder.singleValueContainer()
    if box.decodeNil() { self = .null }
    else if let value = try? box.decode(Bool.self) { self = .bool(value) }
    else if let value = try? box.decode(Double.self) { self = .number(value) }
    else if let value = try? box.decode(String.self) { self = .string(value) }
    else if let value = try? box.decode([String: DSHJSONValue].self) { self = .object(value) }
    else { self = .array(try box.decode([DSHJSONValue].self)) }
  }
  var object: [String: DSHJSONValue]? { if case let .object(value) = self { value } else { nil } }
  var string: String? { if case let .string(value) = self { value } else { nil } }
  var array: [DSHJSONValue]? { if case let .array(value) = self { value } else { nil } }
}

struct DSHRawEvent: Decodable {
  let type: String
  let seq: Int
  let time: Double
  let data: DSHJSONValue
}

struct DSHHistoryEntry: Decodable { let event: DSHRawEvent; let view: DSHJSONValue? }
struct DSHHistoryPage: Decodable { let events: [DSHHistoryEntry]; let hasMore: Bool }
struct DSHHistoryPayload: Encodable { let sessionId: String; let beforeSeq: Int?; let maxMessages: Int }
