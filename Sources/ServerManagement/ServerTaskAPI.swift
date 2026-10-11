import Foundation

struct RemoteScheduledTask: Codable, Identifiable {
    var id: String
    var name: String
    var frequency: String
    var time: String
    var weekday: String
    var executable: String
    var arguments: [String]
    var directory: String
    var enabled: Bool
    var lastRun: String?
    var lastResult: String?

    enum CodingKeys: String, CodingKey {
        case id, name, frequency, time, weekday, executable, arguments, directory, enabled
        case lastRun = "last_run", lastResult = "last_result"
    }

    var scheduleText: String {
        switch frequency {
        case "hourly": return "每小时第 \(time) 分钟"
        case "daily": return "每天 \(time)"
        case "weekly": return "每周 \(weekday) \(time)"
        default: return frequency
        }
    }
}

enum ServerTaskAPI {
    private static func request(connection: ServerConnection, token: String, path: String,
                                method: String, body: Data? = nil, expected: Int) async throws -> Data {
        let status = try ServerStatusAPI.statusURL(connection.endpoint)
        guard var components = URLComponents(url: status, resolvingAgainstBaseURL: false) else { throw ServerStatusError.invalidAddress }
        components.path = path
        guard let url = components.url else { throw ServerStatusError.invalidAddress }
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
            if http.statusCode == 404 && path == "/v1/tasks" { throw ServerTaskError.serverOutdated }
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServerTaskError.response(detail.isEmpty ? "HTTP \(http.statusCode)" : detail)
        }
        return data
    }

    static func list(connection: ServerConnection, token: String) async throws -> [RemoteScheduledTask] {
        struct Listing: Decodable { let items: [RemoteScheduledTask] }
        let data = try await request(connection: connection, token: token, path: "/v1/tasks", method: "GET", expected: 200)
        return try JSONDecoder().decode(Listing.self, from: data).items
    }

    static func save(connection: ServerConnection, token: String, task: RemoteScheduledTask, create: Bool) async throws {
        let data = try JSONEncoder().encode(task)
        _ = try await request(connection: connection, token: token, path: create ? "/v1/tasks" : "/v1/tasks/\(task.id)",
                              method: create ? "POST" : "PUT", body: data, expected: create ? 201 : 204)
    }

    static func delete(connection: ServerConnection, token: String, id: String) async throws {
        _ = try await request(connection: connection, token: token, path: "/v1/tasks/\(id)", method: "DELETE", expected: 204)
    }

    static func log(connection: ServerConnection, token: String, id: String) async throws -> String {
        let status = try ServerStatusAPI.statusURL(connection.endpoint)
        guard var components = URLComponents(url: status, resolvingAgainstBaseURL: false) else { throw ServerStatusError.invalidAddress }
        components.path = "/v1/tasks/\(id)"
        components.queryItems = [URLQueryItem(name: "view", value: "log")]
        guard let url = components.url else { throw ServerStatusError.invalidAddress }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let pin = try ServerStatusAPI.normalizedFingerprint(connection.fingerprint)
        let session = URLSession(configuration: ServerStatusAPI.sessionConfiguration(endpoint: connection.endpoint),
                                 delegate: CertificatePinDelegate(fingerprint: pin), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServerStatusError.http(0) }
        guard http.statusCode == 200 || http.statusCode == 204 else { throw ServerStatusError.http(http.statusCode) }
        return String(decoding: data, as: UTF8.self)
    }
}

enum ServerTaskError: LocalizedError {
    case serverOutdated
    case response(String)
    var errorDescription: String? {
        switch self {
        case .serverOutdated: return "计划任务接口不存在，请更新服务端"
        case .response(let detail): return detail
        }
    }
}
