import Foundation

struct RemoteEnvironmentTool: Decodable, Identifiable {
    let name: String
    let path: String
    let available: Bool
    let version: String
    let error: String
    var id: String { path }
}

struct RemoteEnvironmentInstallation: Decodable, Identifiable {
    let version: String
    let path: String
    let legacy: Bool
    let serviceState: String?
    let tools: [RemoteEnvironmentTool]
    var id: String { path }
}

struct RemoteEnvironment: Decodable, Identifiable {
    let id: String
    let name: String
    let catalogVersion: String
    let installedVersion: String?
    let availableVersions: [String]?
    let state: String
    let message: String
    let installPath: String
    let supported: Bool
    let serviceState: String
    let tools: [RemoteEnvironmentTool]
    let installations: [RemoteEnvironmentInstallation]?

    var installed: Bool { !(installations ?? []).isEmpty || state == "installed" }
    var displayInstallations: [RemoteEnvironmentInstallation] {
        if let installations { return installations }
        guard state == "installed" else { return [] }
        return [RemoteEnvironmentInstallation(version: installedVersion ?? catalogVersion,
                                              path: installPath, legacy: true,
                                              serviceState: serviceState, tools: tools)]
    }
    var versionChoices: [String] {
        guard let availableVersions, !availableVersions.isEmpty else { return [catalogVersion] }
        return availableVersions
    }
    var hasService: Bool { id == "php" }
    var running: Bool { serviceState == "active" }
    var stateText: String {
        switch state {
        case "installed": return "已安装"
        case "installing": return "安装中"
        case "uninstalling": return "卸载中"
        case "failed": return "安装失败"
        case "needs_attention": return "需要处理"
        default: return "未安装"
        }
    }
}

struct RemoteEnvironmentListing: Decodable {
    let items: [RemoteEnvironment]
}

private struct RemoteEnvironmentVersions: Decodable { let versions: [String] }

enum ServerEnvironmentError: LocalizedError {
    case invalidResponse
    case response(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无法识别的环境管理响应"
        case .response(401, _): return "连接令牌无效"
        case .response(404, _): return "当前服务端尚未支持环境管理，请更新服务端"
        case .response(_, let detail) where !detail.isEmpty: return detail
        case .response(let code, _): return "环境管理接口返回 HTTP \(code)"
        }
    }
}

enum ServerEnvironmentAPI {
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
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration,
                          delegate: CertificatePinDelegate(fingerprint: pin), delegateQueue: nil)
    }

    private static func fetch<T: Decodable>(connection: ServerConnection, token: String,
                                            path: String, method: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: try url(connection: connection, path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServerEnvironmentError.invalidResponse }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ServerEnvironmentError.response(http.statusCode, detail)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    static func list(connection: ServerConnection, token: String) async throws -> [RemoteEnvironment] {
        try await fetch(connection: connection, token: token, path: "/v1/environments",
                        method: "GET", as: RemoteEnvironmentListing.self).items
    }

    static func check(connection: ServerConnection, token: String, id: String) async throws -> RemoteEnvironment {
        try await fetch(connection: connection, token: token,
                        path: "/v1/environments/\(id)/check", method: "POST", as: RemoteEnvironment.self)
    }

    static func versions(connection: ServerConnection, token: String, id: String) async throws -> [String] {
        try await fetch(connection: connection, token: token,
                        path: "/v1/environments/\(id)/versions", method: "GET",
                        as: RemoteEnvironmentVersions.self).versions
    }

    static func checkVersion(connection: ServerConnection, token: String, id: String,
                             version: String) async throws -> RemoteEnvironmentInstallation {
        try await fetch(connection: connection, token: token,
                        path: "/v1/environments/\(id)/versions/\(version)/check", method: "POST",
                        as: RemoteEnvironmentInstallation.self)
    }

    static func install(connection: ServerConnection, token: String, id: String,
                        version: String) async throws {
        try await send(connection: connection, token: token, path: "/v1/environments/\(id)/install",
                       body: ["version": version])
    }

    static func uninstall(connection: ServerConnection, token: String, id: String,
                          version: String, mode: String) async throws {
        try await send(connection: connection, token: token,
                       path: "/v1/environments/\(id)/versions/\(version)/uninstall",
                       body: ["mode": mode])
    }

    static func serviceVersion(connection: ServerConnection, token: String, id: String,
                               version: String, action: String) async throws {
        try await send(connection: connection, token: token,
                       path: "/v1/environments/\(id)/versions/\(version)/service",
                       body: ["action": action], expected: 204)
    }

    private static func send(connection: ServerConnection, token: String, path: String,
                             body: [String: String], expected: Int = 202) async throws {
        var request = URLRequest(url: try url(connection: connection, path: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let session = try session(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServerEnvironmentError.invalidResponse }
        guard http.statusCode == expected else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ServerEnvironmentError.response(http.statusCode, detail)
        }
    }
}
