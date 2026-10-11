import Foundation

struct RemoteService: Decodable, Identifiable {
    let name: String
    let description: String
    let activeState: String
    let subState: String
    let unitState: String

    var id: String { name }
    var isActive: Bool { activeState == "active" }
    var isEnabled: Bool { unitState == "enabled" || unitState == "enabled-runtime" }

    var runningText: String {
        switch activeState {
        case "active": return subState == "exited" ? "已启动" : "运行中"
        case "inactive": return "已停止"
        case "failed": return "启动失败"
        case "activating": return "启动中"
        case "deactivating": return "停止中"
        case "reloading": return "重新加载中"
        default: return "状态未知"
        }
    }

    var startupText: String {
        switch unitState {
        case "enabled", "enabled-runtime": return "已启用"
        case "disabled": return "未启用"
        case "static": return "不可单独设置"
        case "masked", "masked-runtime": return "已屏蔽"
        case "indirect": return "间接启用"
        case "generated": return "自动生成"
        default: return "状态未知"
        }
    }
}

struct RemoteServiceListing: Decodable {
    let services: [RemoteService]
}

enum ServerServiceError: LocalizedError {
    case invalidResponse
    case response(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无法识别的服务响应"
        case .response(401, _): return "连接令牌无效"
        case .response(503, _): return "无法读取 systemd 服务列表"
        case .response(_, let detail) where !detail.isEmpty: return detail
        case .response(let code, _): return "服务接口返回 HTTP \(code)"
        }
    }
}

enum ServerServiceAPI {
    static func url(endpoint: String) throws -> URL {
        let status = try ServerStatusAPI.statusURL(endpoint)
        guard var parts = URLComponents(url: status, resolvingAgainstBaseURL: false) else {
            throw ServerStatusError.invalidAddress
        }
        parts.path = "/v1/services"
        guard let url = parts.url else { throw ServerStatusError.invalidAddress }
        return url
    }

    private static func session(connection: ServerConnection) throws -> URLSession {
        let pin = try ServerStatusAPI.normalizedFingerprint(connection.fingerprint)
        let configuration = ServerStatusAPI.sessionConfiguration(endpoint: connection.endpoint)
        configuration.timeoutIntervalForRequest = 100
        configuration.timeoutIntervalForResource = 110
        return URLSession(configuration: configuration,
                          delegate: CertificatePinDelegate(fingerprint: pin), delegateQueue: nil)
    }

    private static func request(connection: ServerConnection, token: String, method: String) throws -> URLRequest {
        var request = URLRequest(url: try url(endpoint: connection.endpoint))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private static func check(_ response: URLResponse, data: Data, expected: Int) throws {
        guard let http = response as? HTTPURLResponse else { throw ServerServiceError.invalidResponse }
        guard http.statusCode == expected else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ServerServiceError.response(http.statusCode, detail)
        }
    }

    static func list(connection: ServerConnection, token: String) async throws -> [RemoteService] {
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(connection: connection, token: token, method: "GET"))
        try check(response, data: data, expected: 200)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RemoteServiceListing.self, from: data).services
    }

    static func perform(connection: ServerConnection, token: String, name: String, action: String) async throws {
        struct Payload: Encodable { let name: String; let action: String }
        var command = try request(connection: connection, token: token, method: "POST")
        command.httpBody = try JSONEncoder().encode(Payload(name: name, action: action))
        command.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: command)
        try check(response, data: data, expected: 204)
    }
}
