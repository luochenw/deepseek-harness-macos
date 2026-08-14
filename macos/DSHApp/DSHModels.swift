import Foundation

struct DSHModelCatalogModel: Decodable, Identifiable { let id: String; let name: String; var description: String? }
struct DSHModelGroup: Decodable, Identifiable { let id: String; let name: String; let models: [DSHModelCatalogModel] }
struct DSHModelCatalog: Decodable { let groups: [DSHModelGroup] }
struct DSHCredentialView: Decodable { let configured: Bool; let source: String?; let writable: Bool }
struct DSHCredentialCatalog: Decodable { let credentials: [String: DSHCredentialView] }
struct DSHCredentialRefsPayload: Encodable { let refs: [String] }
