import Foundation
struct DSHCredentialSetPayload: Encodable { let ref: String; let value: String }
struct DSHCredentialRefPayload: Encodable { let ref: String }
struct DSHEMPTY: Decodable {}
