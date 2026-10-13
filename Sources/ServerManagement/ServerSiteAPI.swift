import Foundation

struct RemoteSite: Codable, Identifiable {
    let id: String
    let provider: String
    let domains: [String]
    let kind: String
    let upstream: String
    let phpVersion: String?
    let root: String
    let enabled: Bool
    let tls: Bool?
    var uniqueID: String { "\(provider)/\(id)" }
    var primaryDomain: String { domains.first ?? id }
}

struct RemoteSiteProvider: Decodable, Identifiable {
    let id: String
    let name: String
    let port: Int
    let installed: Bool
    let running: Bool
}

struct RemoteSiteListing: Decodable {
    let items: [RemoteSite]
    let providers: [RemoteSiteProvider]
    let phpVersions: [String]?
}

struct RemoteSitePayload: Encodable {
    let provider: String
    let domains: [String]
    let kind: String
    let upstream: String
    let phpVersion: String?
    let enabled: Bool
}

enum ServerSiteError: LocalizedError {
    case invalidResponse
    case response(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无法识别的网站响应"
        case .response(401, _): return "连接令牌无效"
        case .response(404, _): return "网站不存在，或服务端尚未支持网站管理"
        case .response(_, let detail) where !detail.isEmpty: return detail
        case .response(let code, _): return "网站接口返回 HTTP \(code)"
        }
    }
}

enum ServerSiteAPI {
    private static func url(connection: ServerConnection, path: String) throws -> URL {
        let status = try ServerStatusAPI.statusURL(connection.endpoint)
        guard var parts = URLComponents(url: status, resolvingAgainstBaseURL: false) else {
            throw ServerStatusError.invalidAddress
        }
        parts.path = path
        guard let url = parts.url else { throw ServerStatusError.invalidAddress }
        return url
    }

    private static func session(connection: ServerConnection) throws -> URLSession {
        let pin = try ServerStatusAPI.normalizedFingerprint(connection.fingerprint)
        let configuration = ServerStatusAPI.sessionConfiguration(endpoint: connection.endpoint)
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration,
                          delegate: CertificatePinDelegate(fingerprint: pin), delegateQueue: nil)
    }

    private static func request(connection: ServerConnection, token: String,
                                path: String, method: String, body: Data? = nil) throws -> URLRequest {
        var request = URLRequest(url: try url(connection: connection, path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func check(_ response: URLResponse, data: Data, expected: Int) throws {
        guard let http = response as? HTTPURLResponse else { throw ServerSiteError.invalidResponse }
        guard http.statusCode == expected else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ServerSiteError.response(http.statusCode, detail)
        }
    }

    static func list(connection: ServerConnection, token: String) async throws -> RemoteSiteListing {
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                     path: "/v1/sites", method: "GET"))
        try check(response, data: data, expected: 200)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RemoteSiteListing.self, from: data)
    }

    static func create(connection: ServerConnection, token: String,
                       payload: RemoteSitePayload) async throws -> RemoteSite {
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(payload)
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                     path: "/v1/sites", method: "POST", body: body))
        try check(response, data: data, expected: 201)
        return try JSONDecoder().decode(RemoteSite.self, from: data)
    }

    static func update(connection: ServerConnection, token: String, site: RemoteSite,
                       payload: RemoteSitePayload) async throws {
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(payload)
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                     path: "/v1/sites/\(site.provider)/\(site.id)",
                                                                     method: "PUT", body: body))
        try check(response, data: data, expected: 204)
    }

    static func delete(connection: ServerConnection, token: String, site: RemoteSite) async throws {
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                     path: "/v1/sites/\(site.provider)/\(site.id)",
                                                                     method: "DELETE"))
        try check(response, data: data, expected: 204)
    }

    static func deployCertificate(connection: ServerConnection, token: String, site: RemoteSite,
                                  certificate: String, privateKey: String) async throws {
        struct Payload: Encodable {
            let certificate: String
            let privateKey: String
            enum CodingKeys: String, CodingKey { case certificate; case privateKey = "private_key" }
        }
        let body = try JSONEncoder().encode(Payload(certificate: certificate, privateKey: privateKey))
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                     path: "/v1/sites/\(site.provider)/\(site.id)/certificate",
                                                                     method: "POST", body: body))
        try check(response, data: data, expected: 204)
    }
}
