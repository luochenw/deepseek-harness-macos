import Foundation
struct DSHWorkspaceCreatePayload: Encodable { let path: String }
struct DSHWorkspaceCreateResult: Decodable { let workspace: DSHWorkspaceView; let created: Bool }
struct DSHWorkspaceRenamePayload: Encodable { let workspaceId: String; let title: String }
struct DSHWorkspaceDeletePayload: Encodable { let workspaceId: String }
struct DSHWorkspaceDeleteResult: Decodable { let deleted: Bool }
