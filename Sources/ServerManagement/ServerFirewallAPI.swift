import Foundation

struct RemoteFirewallPort: Decodable, Identifiable {
    let port: Int
    let `protocol`: String
    let source: String
    var id: String { "\(port)/\(`protocol`)/\(source)" }
}

struct RemoteFirewallSnapshot: Decodable {
    let backend: String
    let zone: String
    let rules: [RemoteFirewallPort]
}

enum ServerFirewallAPI {
    private static func call(connection: ServerConnection, token: String, method: String,
                             body: Data? = nil, expected: Int) async throws -> Data {
        let status = try ServerStatusAPI.statusURL(connection.endpoint)
        guard var parts = URLComponents(url: status, resolvingAgainstBaseURL: false) else { throw ServerStatusError.invalidAddress }
        parts.path = "/v1/firewall"
        guard let url = parts.url else { throw ServerStatusError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let pin = try ServerStatusAPI.normalizedFingerprint(connection.fingerprint)
        let configuration = ServerStatusAPI.sessionConfiguration(endpoint: connection.endpoint)
        configuration.timeoutIntervalForRequest = 40
        let session = URLSession(configuration: configuration,
                                 delegate: CertificatePinDelegate(fingerprint: pin), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServerStatusError.http(0) }
        guard http.statusCode == expected else {
            if http.statusCode == 404 { throw ServerTaskError.response("防火墙接口不存在，请更新服务端") }
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServerTaskError.response(detail.isEmpty ? "HTTP \(http.statusCode)" : detail)
        }
        return data
    }

    static func snapshot(connection: ServerConnection, token: String) async throws -> RemoteFirewallSnapshot {
        let data = try await call(connection: connection, token: token, method: "GET", expected: 200)
        return try JSONDecoder().decode(RemoteFirewallSnapshot.self, from: data)
    }

    static func change(connection: ServerConnection, token: String, action: String,
                       port: Int, protocolName: String) async throws {
        struct Command: Encodable { let action: String; let port: Int; let `protocol`: String }
        let data = try JSONEncoder().encode(Command(action: action, port: port, protocol: protocolName))
        _ = try await call(connection: connection, token: token, method: "POST", body: data, expected: 204)
    }
}
