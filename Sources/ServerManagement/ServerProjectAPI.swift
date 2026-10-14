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

    // 运行时状态：由服务端每次读取时现算，不落盘。
    let subState: String?
    let unitFileState: String?
    let result: String?
    let mainPid: Int?
    let exitStatus: Int?
    let restarts: Int?
    let memoryBytes: Int64?
    let uptimeSeconds: Int64?
    let portBusy: Bool?

    let env: [String: String]?
    let envFile: Bool?
    /// 面板认出来的依赖清单与安装状态。列表接口也会带上，卡片上就能看见；
    /// 旧服务端没有这个字段时整个依赖行不显示。
    let dependency: RemoteProjectDependency?
    /// 是否把「环境变量管理」里的值加载进这个项目。缺省是不加载：那份值由面板
    /// 统一保管，读不读、读哪几个由项目自己决定；代码也可以直接读共用文件。
    let useGlobalEnv: Bool?

    var usesVenv: Bool { useVenv == true }
    var hasReadyVenv: Bool { venvReady == true }
    var hasReadyServer: Bool { serverReady != false }
    var inheritsGlobalEnv: Bool { useGlobalEnv == true }

    var running: Bool { activeState == "active" }

    /// 「在运行」并不等于「在正常工作」：反复重启时 systemd 的 ActiveState 仍然是
    /// activating/active，子状态才是真相。
    var restarting: Bool { subState == "auto-restart" }
    var failed: Bool { activeState == "failed" || subState == "failed" || result == "exit-code"
        || result == "signal" || result == "timeout" || result == "start-limit-hit" }
    var needsAttention: Bool { restarting || (!running && failed) }

    var stateText: String {
        if restarting { return "反复重启" }
        switch activeState {
        case "active": return "运行中"
        case "inactive": return "已停止"
        case "failed": return "启动失败"
        case "activating": return "启动中"
        case "deactivating": return "停止中"
        default: return "状态未知"
        }
    }

    var failureSummary: String? {
        guard needsAttention else { return nil }
        if restarting { return "进程反复退出，正在自动重启" }
        let reason: String
        switch result {
        case "exit-code": reason = "启动后立即退出"
        case "signal": reason = "被信号终止"
        case "timeout": reason = "启动超时"
        case "start-limit-hit": reason = "连续失败次数过多，已放弃重启"
        case .some(let other) where !other.isEmpty: reason = other
        default: reason = "启动未成功"
        }
        if let code = exitStatus, code > 0 { return "\(reason)（退出码 \(code)）" }
        return reason
    }

    var memoryText: String? {
        guard let bytes = memoryBytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    var uptimeText: String? {
        guard running, let seconds = uptimeSeconds, seconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : (seconds >= 3_600 ? [.hour, .minute] : [.minute, .second])
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds))
    }

    var serverLabel: String? {
        guard runtime == "python" else { return nil }
        switch pythonServer ?? "direct" {
        case "gunicorn": return "Gunicorn"
        case "uwsgi": return "uWSGI"
        case "uvicorn": return "Uvicorn"
        default: return "直接运行"
        }
    }

    var envEntries: [RemoteEnvEntry] {
        (env ?? [:]).sorted { $0.key < $1.key }.map { RemoteEnvEntry(name: $0.key, value: $0.value) }
    }
}

/// 展示用的环境变量条目：字典是无序的，列表要稳定。
struct RemoteEnvEntry: Identifiable, Hashable {
    let name: String
    let value: String
    var id: String { name }
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
    let env: [String: String]
    let envFile: Bool
    let useGlobalEnv: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, runtime, entry, port, env
        case runtimeVersion = "runtime_version"
        case useVenv = "use_venv"
        case pythonServer = "python_server"
        case pythonWorker = "python_worker"
        case pythonCallable = "python_callable"
        case pythonWorkers = "python_workers"
        case pythonThreads = "python_threads"
        case directory
        case envFile = "env_file"
        case useGlobalEnv = "use_global_env"
    }
}

/// 「环境变量管理」里的一条公用变量。
///
/// 面板只负责保管这一份值，读不读、读哪几个由使用方决定：项目可以在配置里勾
/// 「加载面板环境变量」，也可以让代码直接读 `file` 这个共用文件。
struct RemoteGlobalVariable: Decodable, Identifiable, Hashable {
    let name: String
    let value: String

    var id: String { name }
}

struct RemoteGlobalVariableListing: Decodable {
    let variables: [RemoteGlobalVariable]?
    let updatedAt: String?
    let consumers: [String]?
    /// 变量表导出的共用文件路径，shell 里 `.` 一下、代码直接读都行。
    let file: String?

    var items: [RemoteGlobalVariable] { variables ?? [] }
}

struct RemoteGlobalVariableSaveResult: Decodable {
    let variables: [RemoteGlobalVariable]?
    let applied: [String]?
    let updatedAt: String?
    let file: String?

    /// 保存后真的被同步进单元的项目名；没勾「加载面板环境变量」的项目不会出现在这里。
    var appliedProjects: [String] { applied ?? [] }
}

private struct RemoteGlobalVariableItem: Encodable {
    let name: String
    let value: String
}

private struct RemoteGlobalVariablePayload: Encodable {
    let variables: [RemoteGlobalVariableItem]
}

/// 一条启动前自检的结果。
struct RemoteProjectCheck: Decodable, Identifiable {
    let id: String
    let label: String
    let level: String
    let detail: String?
    let hint: String?
    let action: String?

    var isOK: Bool { level == "ok" }
    var isError: Bool { level == "error" }
}

struct RemoteProjectDependency: Decodable {
    let manifest: String?
    let present: Bool
    let installed: Bool
    let command: String?
    let level: String?
    let action: String?
    let detail: String?

    /// 服务端认出来的依赖清单文件名，认不出来时为空。
    var manifestName: String? {
        guard let manifest, !manifest.isEmpty else { return nil }
        return manifest
    }

    /// 依赖清单名。服务端说不出文件名时给一个中性占位——具体原因由 summary 说明，
    /// 一律写成「无需安装」会误导（Python 项目没开虚拟环境也是这个形状）。
    var title: String { manifestName ?? "—" }

    var summary: String {
        if let detail, !detail.isEmpty { return detail }
        if installed { return "依赖已安装" }
        return present ? "依赖尚未安装" : "没有依赖清单"
    }

    /// 项目卡片上的一行结论：面板认的是哪份清单、装了没有。
    ///
    /// 依赖清单的识别结果以前只出现在详情接口里，扫一眼项目列表完全看不出面板支持
    /// pyproject.toml / setup.py。运行环境本来就不需要在服务器上装依赖时返回 nil，
    /// 卡片就不占这一行。
    var cardSummary: String? {
        if let name = manifestName {
            if installed { return name + " · 已安装" }
            // 面板不打算装（例如 Python 没开虚拟环境）时，别挂一个点不动的「尚未安装」。
            if action == "deps", let command, !command.isEmpty {
                return name + " · 尚未安装（" + command + "）"
            }
            return name + " · 面板不会替它装，原因见详情"
        }
        return level == "ok" ? nil : detail
    }
}

struct RemoteProjectDetail: Decodable {
    let project: RemoteProject
    let checks: [RemoteProjectCheck]
    let dependency: RemoteProjectDependency
    /// 该项目实际继承到的全局变量（服务端按名称排好序）。
    let globalVariables: [RemoteGlobalVariable]?
    let log: String
    let journal: String?
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
    static func url(connection: ServerConnection, path: String) throws -> URL {
        let status = try ServerStatusAPI.statusURL(connection.endpoint)
        guard var parts = URLComponents(url: status, resolvingAgainstBaseURL: false) else {
            throw ServerStatusError.invalidAddress
        }
        parts.path = path
        guard let url = parts.url else { throw ServerStatusError.invalidAddress }
        return url
    }

    static func session(connection: ServerConnection, timeout: TimeInterval = 45) throws -> URLSession {
        let pin = try ServerStatusAPI.normalizedFingerprint(connection.fingerprint)
        let configuration = ServerStatusAPI.sessionConfiguration(endpoint: connection.endpoint)
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 30
        return URLSession(configuration: configuration,
                          delegate: CertificatePinDelegate(fingerprint: pin), delegateQueue: nil)
    }

    static func request(connection: ServerConnection, token: String,
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

    static func checked(_ response: URLResponse, data: Data, expected: Int) throws {
        guard let http = response as? HTTPURLResponse else { throw ServerProjectError.invalidResponse }
        guard http.statusCode == expected else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ServerProjectError.response(http.statusCode, detail)
        }
    }

    static func call(connection: ServerConnection, token: String,
                             path: String, method: String, body: Data? = nil,
                             expected: Int, timeout: TimeInterval = 45) async throws -> Data {
        let session = try session(connection: connection, timeout: timeout)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(connection: connection, token: token,
                                                                    path: path, method: method, body: body))
        try checked(response, data: data, expected: expected)
        return data
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func list(connection: ServerConnection, token: String) async throws -> RemoteProjectListing {
        let data = try await call(connection: connection, token: token, path: "/v1/projects", method: "GET", expected: 200)
        return try decoder.decode(RemoteProjectListing.self, from: data)
    }

    static func create(connection: ServerConnection, token: String, payload: RemoteProjectPayload) async throws -> RemoteProject {
        let data = try await call(connection: connection, token: token, path: "/v1/projects", method: "POST",
                                  body: try JSONEncoder().encode(payload), expected: 201)
        return try decoder.decode(RemoteProject.self, from: data)
    }

    static func update(connection: ServerConnection, token: String, payload: RemoteProjectPayload) async throws {
        _ = try await call(connection: connection, token: token, path: "/v1/projects/\(payload.id)", method: "PUT",
                           body: try JSONEncoder().encode(payload), expected: 204)
    }

    static func delete(connection: ServerConnection, token: String, id: String) async throws {
        _ = try await call(connection: connection, token: token, path: "/v1/projects/\(id)", method: "DELETE", expected: 204)
    }

    static func action(connection: ServerConnection, token: String, id: String, action: String) async throws {
        struct Command: Encodable { let action: String }
        _ = try await call(connection: connection, token: token, path: "/v1/projects/\(id)/action", method: "POST",
                           body: try JSONEncoder().encode(Command(action: action)), expected: 204)
    }

    static func venv(connection: ServerConnection, token: String, id: String, action: String) async throws {
        struct Command: Encodable { let action: String }
        _ = try await call(connection: connection, token: token, path: "/v1/projects/\(id)/venv", method: "POST",
                           body: try JSONEncoder().encode(Command(action: action)), expected: 204, timeout: 660)
    }

    /// 安装依赖可能拉很久（npm/pip 都很慢），超时给足。
    static func installDependencies(connection: ServerConnection, token: String, id: String) async throws {
        _ = try await call(connection: connection, token: token, path: "/v1/projects/\(id)/deps", method: "POST",
                           expected: 204, timeout: 960)
    }

    static func status(connection: ServerConnection, token: String, id: String) async throws -> RemoteProjectDetail {
        let data = try await call(connection: connection, token: token, path: "/v1/projects/\(id)/status",
                                  method: "GET", expected: 200)
        return try decoder.decode(RemoteProjectDetail.self, from: data)
    }

    static func log(connection: ServerConnection, token: String, id: String) async throws -> String {
        let data = try await call(connection: connection, token: token, path: "/v1/projects/\(id)/log", method: "GET", expected: 200)
        return String(decoding: data, as: UTF8.self)
    }

    static func clearLog(connection: ServerConnection, token: String, id: String) async throws {
        _ = try await call(connection: connection, token: token, path: "/v1/projects/\(id)/log", method: "DELETE", expected: 204)
    }

    static func freePorts(connection: ServerConnection, token: String, after: Int) async throws -> [Int] {
        let data = try await call(connection: connection, token: token,
                                  path: "/v1/projects/ports?after=\(after)", method: "GET", expected: 200)
        struct Payload: Decodable { let ports: [Int] }
        return try decoder.decode(Payload.self, from: data).ports
    }

    // MARK: - 全局变量

    static func variables(connection: ServerConnection, token: String) async throws -> RemoteGlobalVariableListing {
        let data = try await call(connection: connection, token: token, path: "/v1/variables",
                                  method: "GET", expected: 200)
        return try decoder.decode(RemoteGlobalVariableListing.self, from: data)
    }

    /// 整表替换。服务端保存后会立刻把它同步进所有继承全局变量的项目单元，
    /// 运行中的项目会被重启，所以返回里带着实际被同步的项目名。
    static func saveVariables(connection: ServerConnection, token: String,
                              variables: [RemoteGlobalVariable]) async throws -> RemoteGlobalVariableSaveResult {
        let payload = RemoteGlobalVariablePayload(
            variables: variables.map { RemoteGlobalVariableItem(name: $0.name, value: $0.value) })
        let data = try await call(connection: connection, token: token, path: "/v1/variables", method: "PUT",
                                  body: try JSONEncoder().encode(payload), expected: 200, timeout: 300)
        return try decoder.decode(RemoteGlobalVariableSaveResult.self, from: data)
    }
}
