import Foundation

struct DSHRenameSessionPayload: Encodable { let sessionId: String; let title: String }
struct DSHRenameSessionResult: Decodable { let title: String; let seq: Int }
struct DSHForkSessionPayload: Encodable { let sessionId: String }
struct DSHForkSessionResult: Decodable { let sessionId: String }
struct DSHArchiveSessionPayload: Encodable { let sessionId: String }
struct DSHArchiveSessionResult: Decodable { let archivedSessionIds: [String] }
