import Foundation

struct RemoteDatabaseInstance: Decodable, Identifiable {
    let id: String
    let name: String
    let version: String
    let installed: Bool
    let running: Bool
    let port: Int
    let manageUsers: Bool
    let authState: String
}

struct RemoteDatabaseUser: Decodable, Identifiable {
    let name: String
    let host: String
    var id: String { "\(name)@\(host)" }
}

struct RemoteDatabaseCatalog: Decodable {
    let databases: [String]
    let users: [RemoteDatabaseUser]
}

struct RemoteDatabasePassword: Decodable {
    let user: String
    let password: String
}

struct RemoteKeyValueUser: Decodable, Identifiable {
    let name: String
    let enabled: Bool
    let level: String
    var id: String { name }
}

struct RemoteKeyValueACL: Decodable {
    let persistent: Bool
    let users: [RemoteKeyValueUser]
}

enum ServerDatabaseError: LocalizedError {
    case invalidResponse
    case response(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无法识别的数据库响应"
        case .response(401, _): return "连接令牌无效"
        case .response(404, _): return "数据库接口不存在，请更新服务端"
        case .response(_, let detail) where !detail.isEmpty: return detail
        case .response(let code, _): return "数据库接口返回 HTTP \(code)"
        }
    }
}

enum ServerDatabaseAPI {
    private static func url(connection: ServerConnection, path: String) throws -> URL {
        let status = try ServerStatusAPI.statusURL(connection.endpoint)
        guard var parts = URLComponents(url: status, resolvingAgainstBaseURL: false) else { throw ServerStatusError.invalidAddress }
        parts.path = path
        guard let url = parts.url else { throw ServerStatusError.invalidAddress }
        return url
    }

    private static func session(connection: ServerConnection) throws -> URLSession {
        let pin = try ServerStatusAPI.normalizedFingerprint(connection.fingerprint)
        let config = ServerStatusAPI.sessionConfiguration(endpoint: connection.endpoint)
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config, delegate: CertificatePinDelegate(fingerprint: pin), delegateQueue: nil)
    }

    private static func call(connection: ServerConnection, token: String, path: String, method: String,
                             body: Data? = nil, expected: Int) async throws -> Data {
        var request = URLRequest(url: try url(connection: connection, path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServerDatabaseError.invalidResponse }
        guard http.statusCode == expected else {
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServerDatabaseError.response(http.statusCode, detail)
        }
        return data
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func list(connection: ServerConnection, token: String) async throws -> [RemoteDatabaseInstance] {
        struct Listing: Decodable { let items: [RemoteDatabaseInstance] }
        let data = try await call(connection: connection, token: token, path: "/v1/databases", method: "GET", expected: 200)
        return try decoder().decode(Listing.self, from: data).items
    }

    static func catalog(connection: ServerConnection, token: String, engine: String) async throws -> RemoteDatabaseCatalog {
        let data = try await call(connection: connection, token: token, path: "/v1/databases/\(engine)/catalog", method: "GET", expected: 200)
        return try decoder().decode(RemoteDatabaseCatalog.self, from: data)
    }

    static func createDatabase(connection: ServerConnection, token: String, engine: String, name: String) async throws {
        struct Payload: Encodable { let name: String }
        _ = try await call(connection: connection, token: token, path: "/v1/databases/\(engine)/databases", method: "POST",
                           body: JSONEncoder().encode(Payload(name: name)), expected: 201)
    }

    static func deleteDatabase(connection: ServerConnection, token: String, engine: String, name: String) async throws {
        _ = try await call(connection: connection, token: token, path: "/v1/databases/\(engine)/databases/\(name)",
                           method: "DELETE", expected: 204)
    }

    static func createUser(connection: ServerConnection, token: String, engine: String, name: String) async throws -> RemoteDatabasePassword {
        struct Payload: Encodable { let name: String }
        let data = try await call(connection: connection, token: token, path: "/v1/databases/\(engine)/users", method: "POST",
                                  body: JSONEncoder().encode(Payload(name: name)), expected: 201)
        return try decoder().decode(RemoteDatabasePassword.self, from: data)
    }

    static func deleteUser(connection: ServerConnection, token: String, engine: String, name: String) async throws {
        _ = try await call(connection: connection, token: token, path: "/v1/databases/\(engine)/users/\(name)",
                           method: "DELETE", expected: 204)
    }

    static func resetPassword(connection: ServerConnection, token: String, engine: String, name: String) async throws -> RemoteDatabasePassword {
        let data = try await call(connection: connection, token: token, path: "/v1/databases/\(engine)/users/\(name):reset",
                                  method: "POST", expected: 200)
        return try decoder().decode(RemoteDatabasePassword.self, from: data)
    }

    static func grant(connection: ServerConnection, token: String, engine: String, database: String,
                      user: String, level: String, revoke: Bool) async throws {
        struct Payload: Encodable { let database: String; let user: String; let level: String }
        _ = try await call(connection: connection, token: token, path: "/v1/databases/\(engine)/grants",
                           method: revoke ? "DELETE" : "POST",
                           body: JSONEncoder().encode(Payload(database: database, user: user, level: level)), expected: 204)
    }

    static func bootstrapMySQL(connection: ServerConnection, token: String) async throws -> RemoteDatabasePassword {
        let data = try await call(connection: connection, token: token, path: "/v1/databases/mysql/bootstrap", method: "POST", expected: 200)
        return try decoder().decode(RemoteDatabasePassword.self, from: data)
    }

    static func setMySQLCredential(connection: ServerConnection, token: String, password: String) async throws {
        struct Payload: Encodable { let password: String }
        _ = try await call(connection: connection, token: token, path: "/v1/databases/mysql/credential", method: "POST",
                           body: JSONEncoder().encode(Payload(password: password)), expected: 204)
    }

    static func changeMySQLCredential(connection: ServerConnection, token: String,
                                      current: String, next: String) async throws {
        struct Payload: Encodable {
            let currentPassword: String
            let newPassword: String
            enum CodingKeys: String, CodingKey { case currentPassword = "current_password"; case newPassword = "new_password" }
        }
        _ = try await call(connection: connection, token: token, path: "/v1/databases/mysql/credential/change",
                           method: "POST", body: JSONEncoder().encode(Payload(currentPassword: current, newPassword: next)), expected: 204)
    }

    static func savedPassword(connection: ServerConnection, token: String, engine: String, user: String? = nil) async throws -> RemoteDatabasePassword {
        let path: String
        if let user {
            path = ["redis", "valkey"].contains(engine) ? "/v1/databases/\(engine)/acl/users/\(user):password" : "/v1/databases/\(engine)/users/\(user):password"
        } else {
            path = ["redis", "valkey"].contains(engine) ? "/v1/databases/\(engine)/acl/credential" : "/v1/databases/\(engine)/credential"
        }
        let data = try await call(connection: connection, token: token, path: path, method: "GET", expected: 200)
        return try decoder().decode(RemoteDatabasePassword.self, from: data)
    }

    static func enablePostgresLocalAccess(connection: ServerConnection, token: String) async throws {
        _ = try await call(connection: connection, token: token, path: "/v1/databases/postgresql/local-access",
                           method: "POST", expected: 204)
    }

    static func keyValueACL(connection: ServerConnection, token: String, engine: String) async throws -> RemoteKeyValueACL {
        let data = try await call(connection: connection, token: token, path: "/v1/databases/\(engine)/acl", method: "GET", expected: 200)
        return try decoder().decode(RemoteKeyValueACL.self, from: data)
    }

    static func enableKeyValueACL(connection: ServerConnection, token: String, engine: String) async throws {
        _ = try await call(connection: connection, token: token, path: "/v1/databases/\(engine)/acl/enable", method: "POST", expected: 204)
    }

    static func setKeyValueCredential(connection: ServerConnection, token: String, engine: String, password: String) async throws {
        struct Payload: Encodable { let password: String }
        _ = try await call(connection: connection, token: token, path: "/v1/databases/\(engine)/acl/credential", method: "POST",
                           body: JSONEncoder().encode(Payload(password: password)), expected: 204)
    }

    static func createKeyValueUser(connection: ServerConnection, token: String, engine: String,
                                   name: String, level: String) async throws -> RemoteDatabasePassword {
        struct Payload: Encodable { let name: String; let level: String }
        let data = try await call(connection: connection, token: token, path: "/v1/databases/\(engine)/acl/users", method: "POST",
                                  body: JSONEncoder().encode(Payload(name: name, level: level)), expected: 201)
        return try decoder().decode(RemoteDatabasePassword.self, from: data)
    }

    static func resetKeyValueUser(connection: ServerConnection, token: String, engine: String,
                                  name: String) async throws -> RemoteDatabasePassword {
        let data = try await call(connection: connection, token: token,
                                  path: "/v1/databases/\(engine)/acl/users/\(name):reset", method: "POST", expected: 200)
        return try decoder().decode(RemoteDatabasePassword.self, from: data)
    }

    static func updateKeyValueUser(connection: ServerConnection, token: String, engine: String,
                                   name: String, level: String, enabled: Bool) async throws {
        struct Payload: Encodable { let level: String; let enabled: Bool }
        _ = try await call(connection: connection, token: token,
                           path: "/v1/databases/\(engine)/acl/users/\(name)", method: "PUT",
                           body: JSONEncoder().encode(Payload(level: level, enabled: enabled)), expected: 204)
    }

    static func deleteKeyValueUser(connection: ServerConnection, token: String, engine: String,
                                   name: String) async throws {
        _ = try await call(connection: connection, token: token,
                           path: "/v1/databases/\(engine)/acl/users/\(name)", method: "DELETE", expected: 204)
    }
}
