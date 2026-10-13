import Foundation

struct RemoteProjectRuntime: Decodable, Identifiable {
    let id: String
    let name: String
    let installed: Bool
    let versions: [String]?
    let legacyInstalled: Bool?
}

struct RemoteProject: Decodable, Identifiable {
    let id: String
    let name: String
    let runtime: String
    let runtimeVersion: String?
    let entry: String
    let port: Int
    let directory: String
    let activeState: String
    let enabled: Bool
    let runtimeReady: Bool
    let useVenv: Bool?
    let venvReady: Bool?
    let pythonServer: String?
    let pythonWorker: String?
    let pythonCallable: String?
    let pythonWorkers: Int?
    let pythonThreads: Int?
    let serverReady: Bool?

    var usesVenv: Bool { useVenv == true }
    var hasReadyVenv: Bool { venvReady == true }
    var hasReadyServer: Bool { serverReady != false }

    var running: Bool { activeState == "active" }
    var stateText: String {
        switch activeState {
        case "active": return "运行中"
        case "inactive": return "已停止"
        case "failed": return "启动失败"
        case "activating": return "启动中"
        case "deactivating": return "停止中"
        default: return "状态未知"
        }
    }
}

struct RemoteProjectListing: Decodable {
    let items: [RemoteProject]
    let runtimes: [RemoteProjectRuntime]
}

struct RemoteProjectPayload: Encodable {
    let id: String
    let name: String
    let runtime: String
    let runtimeVersion: String
    let useVenv: Bool
    let pythonServer: String
    let pythonWorker: String
    let pythonCallable: String
    let pythonWorkers: Int
    let pythonThreads: Int
    let entry: String
    let port: Int
    let directory: String

    enum CodingKeys: String, CodingKey {
        case id, name, runtime, entry, port
        case runtimeVersion = "runtime_version"
        case useVenv = "use_venv"
        case pythonServer = "python_server"
        case pythonWorker = "python_worker"
        case pythonCallable = "python_callable"
        case pythonWorkers = "python_workers"
        case pythonThreads = "python_threads"
        case directory
    }
}

enum ServerProjectError: LocalizedError {
    case invalidResponse
    case response(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无法识别的项目响应"
        case .response(401, _): return "连接令牌无效"
        case .response(404, _): return "项目不存在，或服务端尚未支持项目管理"
        case .response(_, let detail) where !detail.isEmpty: return detail
        case .response(let code, _): return "项目接口返回 HTTP \(code)"
        }
    }
}

enum ServerProjectAPI {
    private static func url(connection: ServerConnection, path: String) throws -> URL {
        let status = try ServerStatusAPI.statusURL(connection.endpoint)
        guard var parts = URLComponents(url: status, resolvingAgainstBaseURL: false) else {
            throw ServerStatusError.invalidAddress
        }
        parts.path = path
        guard let url = parts.url else { throw ServerStatusError.invalidAddress }
        return url
    }

    private static func session(connection: ServerConnection, timeout: TimeInterval = 45) throws -> URLSession {
        let pin = try ServerStatusAPI.normalizedFingerprint(connection.fingerprint)
        let configuration = ServerStatusAPI.sessionConfiguration(endpoint: connection.endpoint)
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 30
        return URLSession(configuration: configuration,
                          delegate: CertificatePinDelegate(fingerprint: pin), delegateQueue: nil)
    }

    private static func request(connection: ServerConnection, token: String,
                                path: String, method: String, body: Data? = nil) throws -> URLRequest {
        var result = URLRequest(url: try url(connection: connection, path: path))
        result.httpMethod = method
        result.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        result.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            result.httpBody = body
            result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return result
    }

    private static func checked(_ response: URLResponse, data: Data, expected: Int) throws {
        guard let http = response as? HTTPURLResponse else { throw ServerProjectError.invalidResponse }
        guard http.statusCode == expected else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ServerProjectError.response(http.statusCode, detail)
        }
    }

    private static func call(connection: ServerConnection, token: String,
                             path: String, method: String, body: Data? = nil,
                             expected: Int, timeout: TimeInterval = 45) async throws -> Data {
        let session = try session(connection: connection, timeout: timeout)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                    path: path, method: method, body: body))
        try checked(response, data: data, expected: expected)
        return data
    }

    static func list(connection: ServerConnection, token: String) async throws -> RemoteProjectListing {
        let data = try await call(connection: connection, token: token, path: "/v1/projects", method: "GET", expected: 200)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RemoteProjectListing.self, from: data)
    }

    static func create(connection: ServerConnection, token: String, payload: RemoteProjectPayload) async throws -> RemoteProject {
        let data = try await call(connection: connection, token: token, path: "/v1/projects", method: "POST",
                                  body: JSONEncoder().encode(payload), expected: 201)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RemoteProject.self, from: data)
    }

    static func update(connection: ServerConnection, token: String, payload: RemoteProjectPayload) async throws {
        _ = try await call(connection: connection, token: token, path: "/v1/projects/\(payload.id)", method: "PUT",
                           body: JSONEncoder().encode(payload), expected: 204)
    }

    static func delete(connection: ServerConnection, token: String, id: String) async throws {
        _ = try await call(connection: connection, token: token, path: "/v1/projects/\(id)", method: "DELETE", expected: 204)
    }

    static func action(connection: ServerConnection, token: String, id: String, action: String) async throws {
        struct Command: Encodable { let action: String }
        _ = try await call(connection: connection, token: token, path: "/v1/projects/\(id)/action", method: "POST",
                           body: JSONEncoder().encode(Command(action: action)), expected: 204)
    }

    static func venv(connection: ServerConnection, token: String, id: String, action: String) async throws {
        struct Command: Encodable { let action: String }
        _ = try await call(connection: connection, token: token, path: "/v1/projects/\(id)/venv", method: "POST",
                           body: JSONEncoder().encode(Command(action: action)), expected: 204, timeout: 660)
    }

    static func log(connection: ServerConnection, token: String, id: String) async throws -> String {
        let data = try await call(connection: connection, token: token, path: "/v1/projects/\(id)/log", method: "GET", expected: 200)
        return String(decoding: data, as: UTF8.self)
    }
}
