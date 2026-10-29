import Foundation
struct DSHOpenPathPayload: Encodable { let path: String }
struct DSHOpenPathResult: Decodable { let opened: Bool }
