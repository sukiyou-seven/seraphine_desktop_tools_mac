import Foundation

struct RemoteSoftware: Decodable, Identifiable {
    let id: String
    let name: String
    let version: String
    let description: String
    let category: String?
    let installAvailable: Bool?
    let serviceAvailable: Bool?
    let installPath: String
    let logPath: String
    let credentialPath: String
    let state: String
    let message: String
    let serviceState: String
    let enabled: Bool
    let supported: Bool

    var isInstalled: Bool { state == "installed" || state == "multiple_versions" }
    var canUninstall: Bool { state == "installed" }
    var isRunning: Bool { serviceState == "active" }
    var canInstall: Bool { installAvailable ?? true }
    var hasService: Bool { (serviceAvailable ?? true) && state != "multiple_versions" }
    var categoryText: String { category ?? "其他" }
    var storeStateText: String { !canInstall && !isInstalled ? "待支持" : stateText }

    var stateText: String {
        switch state {
        case "installed": return "已安装"
        case "multiple_versions": return "多版本已安装"
        case "installing": return "安装中"
        case "uninstalling": return "卸载中"
        case "queued": return "排队中"
        case "cancelling": return "停止中"
        case "cancelled": return "已停止"
        case "failed": return "安装失败"
        case "needs_attention": return "需要处理"
        default: return "未安装"
        }
    }

    var runningText: String {
        switch serviceState {
        case "active": return "运行中"
        case "failed": return "运行失败"
        case "activating": return "启动中"
        case "deactivating": return "停止中"
        default: return "已停止"
        }
    }

    /// 这些运行时由「环境管理」按版本安装，软件商店只显示入口、不重复提供安装按钮，
    /// 否则同一个运行时会有两条能力不同的安装路径。
    static let runtimeIDs: Set<String> = [
        "python", "go", "node", "openjdk", "dotnet", "ruby", "bun", "deno", "php",
    ]

    var isRuntime: Bool { RemoteSoftware.runtimeIDs.contains(id) }
}

enum RemoteSoftwareUninstallMode: String {
    case backup
    case purge
}

struct RemoteSoftwareListing: Decodable {
    let items: [RemoteSoftware]
}

struct RemoteSoftwareJob: Decodable, Identifiable {
    let id: String
    let operation: String
    let state: String
    let message: String
    let createdAt: String
}

struct RemoteSoftwareJobs: Decodable { let items: [RemoteSoftwareJob] }

enum ServerSoftwareError: LocalizedError {
    case invalidResponse
    case response(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无法识别的软件商店响应"
        case .response(401, _): return "连接令牌无效"
        case .response(404, _): return "当前服务端尚不支持软件商店，请更新服务端"
        case .response(_, let detail) where !detail.isEmpty: return detail
        case .response(let code, _): return "软件商店接口返回 HTTP \(code)"
        }
    }
}

enum ServerSoftwareAPI {
    static func url(endpoint: String, path: String = "/v1/software") throws -> URL {
        let status = try ServerStatusAPI.statusURL(endpoint)
        guard var parts = URLComponents(url: status, resolvingAgainstBaseURL: false) else {
            throw ServerStatusError.invalidAddress
        }
        parts.path = path
        guard let url = parts.url else { throw ServerStatusError.invalidAddress }
        return url
    }

    private static func session(connection: ServerConnection) throws -> URLSession {
        let pin = try ServerStatusAPI.normalizedFingerprint(connection.fingerprint)
        let config = ServerStatusAPI.sessionConfiguration(endpoint: connection.endpoint)
        config.timeoutIntervalForRequest = 100
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config,
                          delegate: CertificatePinDelegate(fingerprint: pin), delegateQueue: nil)
    }

    private static func request(connection: ServerConnection, token: String,
                                path: String, method: String, json: Data? = nil) throws -> URLRequest {
        var request = URLRequest(url: try url(endpoint: connection.endpoint, path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let json {
            request.httpBody = json
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func check(_ response: URLResponse, data: Data, expected: Int) throws {
        guard let http = response as? HTTPURLResponse else { throw ServerSoftwareError.invalidResponse }
        guard http.statusCode == expected else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ServerSoftwareError.response(http.statusCode, detail)
        }
    }

    static func list(connection: ServerConnection, token: String) async throws -> [RemoteSoftware] {
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                      path: "/v1/software", method: "GET"))
        try check(response, data: data, expected: 200)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RemoteSoftwareListing.self, from: data).items
    }

    static func install(connection: ServerConnection, token: String, id: String,
                        version: String? = nil) async throws {
        struct Payload: Encodable { let version: String }
        let body = try version.map { try JSONEncoder().encode(Payload(version: $0)) }
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                      path: "/v1/software/\(id)/install", method: "POST", json: body))
        try check(response, data: data, expected: 202)
    }

    static func jobs(connection: ServerConnection, token: String) async throws -> [RemoteSoftwareJob] {
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                      path: "/v1/software/jobs", method: "GET"))
        try check(response, data: data, expected: 200)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RemoteSoftwareJobs.self, from: data).items
    }

    static func cancel(connection: ServerConnection, token: String, id: String) async throws {
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                      path: "/v1/software/\(id)/cancel", method: "POST"))
        try check(response, data: data, expected: 204)
    }

    static func uninstall(connection: ServerConnection, token: String, id: String,
                          mode: RemoteSoftwareUninstallMode) async throws {
        struct Payload: Encodable { let mode: String }
        let body = try JSONEncoder().encode(Payload(mode: mode.rawValue))
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                      path: "/v1/software/\(id)/uninstall", method: "POST", json: body))
        try check(response, data: data, expected: 202)
    }

    static func service(connection: ServerConnection, token: String, id: String, action: String) async throws {
        struct Payload: Encodable { let action: String }
        let body = try JSONEncoder().encode(Payload(action: action))
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                      path: "/v1/software/\(id)/service", method: "POST", json: body))
        try check(response, data: data, expected: 204)
    }

    static func log(connection: ServerConnection, token: String, id: String) async throws -> String {
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                      path: "/v1/software/\(id)/log", method: "GET"))
        try check(response, data: data, expected: 200)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
