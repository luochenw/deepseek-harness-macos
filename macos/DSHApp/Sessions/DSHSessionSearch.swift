import Foundation

struct DSHSessionSearchPayload: Encodable { let query: String }
struct DSHSessionSearchItem: Decodable, Identifiable { let sessionId: String; let snippet: String; var id: String { sessionId } }
struct DSHSessionSearchResults: Decodable { let items: [DSHSessionSearchItem]; let hasMore: Bool }
