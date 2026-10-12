import Foundation

struct RemoteFile: Decodable, Identifiable {
    let name: String
    let path: String
    let kind: String
    let permissions: String?
    let sizeBytes: Int64
    let modifiedAt: String
    var id: String { path }
    var isDirectory: Bool { kind == "directory" }
    var isRegularFile: Bool { kind == "file" }
    var isProtectedPath: Bool {
        ["/", "/www", "/www/seraphim", "/www/seraphim/server", "/www/seraphim/web",
         "/www/seraphim/projects", "/www/seraphim/download", "/www/seraphim/backup",
         "/www/seraphim/logs", "/bin", "/boot", "/dev", "/etc", "/home",
         "/lib", "/lib64", "/opt", "/proc", "/root", "/run", "/sbin",
         "/srv", "/sys", "/tmp", "/usr", "/var"].contains(path)
    }
}

struct RemoteFileListing: Decodable {
    let path: String
    let parent: String
    let entries: [RemoteFile]
}

enum ServerFileError: LocalizedError {
    case invalidResponse
    case response(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无法识别的文件响应"
        case .response(400): return "路径无效或不允许操作此目录"
        case .response(401): return "连接令牌无效"
        case .response(403): return "没有权限操作此文件"
        case .response(404): return "文件或目录不存在，请刷新"
        case .response(409): return "目标已存在，或目录不为空"
        case .response(413): return "文件超过 2 GiB 上传限制"
        case .response(let code): return "文件接口返回 HTTP \(code)"
        }
    }
}

enum ServerFileAPI {
    struct UploadSummary {
        var files = 0
        var directories = 0
        var skipped = 0
    }

    static func url(endpoint: String, path: String, remotePath: String,
                    extraQuery: [URLQueryItem] = []) throws -> URL {
        let status = try ServerStatusAPI.statusURL(endpoint)
        guard var parts = URLComponents(url: status, resolvingAgainstBaseURL: false) else {
            throw ServerStatusError.invalidAddress
        }
        parts.path = path
        parts.queryItems = [URLQueryItem(name: "path", value: remotePath)] + extraQuery
        guard let url = parts.url else { throw ServerStatusError.invalidAddress }
        return url
    }

    private static func makeSession(connection: ServerConnection) throws -> URLSession {
        let pin = try ServerStatusAPI.normalizedFingerprint(connection.fingerprint)
        let config = ServerStatusAPI.sessionConfiguration(endpoint: connection.endpoint)
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 7200
        return URLSession(configuration: config,
                          delegate: CertificatePinDelegate(fingerprint: pin), delegateQueue: nil)
    }

    private static func request(_ url: URL, method: String, token: String,
                                json: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let json {
            request.httpBody = json
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func check(_ response: URLResponse, expected: Int) throws {
        guard let http = response as? HTTPURLResponse else { throw ServerFileError.invalidResponse }
        guard http.statusCode == expected else { throw ServerFileError.response(http.statusCode) }
    }

    static func list(connection: ServerConnection, token: String, path: String) async throws -> RemoteFileListing {
        let url = try url(endpoint: connection.endpoint, path: "/v1/files", remotePath: path)
        let session = try makeSession(connection: connection)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request(url, method: "GET", token: token))
        try check(response, expected: 200)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RemoteFileListing.self, from: data)
    }

    private static func command(connection: ServerConnection, token: String, operation: String,
                                path: String, destination: String? = nil, overwrite: Bool = false,
                                permissions: String? = nil) async throws {
        struct Payload: Encodable {
            let operation: String
            let path: String
            let destination: String?
            let overwrite: Bool
            let permissions: String?
        }
        let url = try url(endpoint: connection.endpoint, path: "/v1/files", remotePath: path)
        let body = try JSONEncoder().encode(Payload(operation: operation, path: path,
                                                     destination: destination, overwrite: overwrite,
                                                     permissions: permissions))
        let session = try makeSession(connection: connection)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request(url, method: "POST", token: token, json: body))
        try check(response, expected: 204)
    }

    static func mkdir(connection: ServerConnection, token: String, path: String) async throws {
        try await command(connection: connection, token: token, operation: "mkdir", path: path)
    }

    static func createFile(connection: ServerConnection, token: String, path: String) async throws {
        try await command(connection: connection, token: token, operation: "touch", path: path)
    }

    static func chmod(connection: ServerConnection, token: String, path: String,
                      permissions: String) async throws {
        try await command(connection: connection, token: token, operation: "chmod",
                          path: path, permissions: permissions)
    }

    static func rename(connection: ServerConnection, token: String, from: String,
                       to: String, overwrite: Bool = false) async throws {
        try await command(connection: connection, token: token, operation: "rename",
                          path: from, destination: to, overwrite: overwrite)
    }

    static func delete(connection: ServerConnection, token: String, path: String,
                       recursive: Bool) async throws {
        let url = try url(endpoint: connection.endpoint, path: "/v1/files", remotePath: path,
                          extraQuery: [URLQueryItem(name: "recursive", value: recursive ? "true" : "false")])
        let session = try makeSession(connection: connection)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request(url, method: "DELETE", token: token))
        try check(response, expected: 204)
    }

    static func upload(connection: ServerConnection, token: String, localFile: URL,
                       remotePath: String, overwrite: Bool) async throws {
        let url = try url(endpoint: connection.endpoint, path: "/v1/files/content", remotePath: remotePath,
                          extraQuery: [URLQueryItem(name: "overwrite", value: overwrite ? "true" : "false")])
        let session = try makeSession(connection: connection)
        defer { session.invalidateAndCancel() }
        var uploadRequest = request(url, method: "PUT", token: token)
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: uploadRequest, fromFile: localFile)
        try check(response, expected: 204)
    }

    static func uploadSelection(connection: ServerConnection, token: String, localURLs: [URL],
                                remoteDirectory: String, overwrite: Bool) async throws -> UploadSummary {
        guard !localURLs.isEmpty, localURLs.count <= 100 else {
            throw UploadValidationError.invalidSelection
        }
        let manager = FileManager.default
        let names = localURLs.map(\.lastPathComponent)
        guard Set(names).count == names.count else { throw UploadValidationError.duplicateNames }
        var summary = UploadSummary()
        var itemCount = 0
        func visit(_ local: URL, _ parts: [String]) async throws {
            itemCount += 1
            guard itemCount <= 20_000 else { throw UploadValidationError.tooManyItems }
            let values = try local.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                             .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { summary.skipped += 1; return }
            let remote = (remoteDirectory == "/" ? "" : remoteDirectory) + "/" + parts.joined(separator: "/")
            if values.isDirectory == true {
                do {
                    try await mkdir(connection: connection, token: token, path: remote)
                } catch ServerFileError.response(409) where overwrite {
                    _ = try await list(connection: connection, token: token, path: remote)
                }
                summary.directories += 1
                let children = try manager.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children { try await visit(child, parts + [child.lastPathComponent]) }
            } else if values.isRegularFile == true {
                guard Int64(values.fileSize ?? 0) <= 2 * 1024 * 1024 * 1024 else {
                    throw UploadValidationError.fileTooLarge(parts.joined(separator: "/"))
                }
                try await upload(connection: connection, token: token, localFile: local,
                                 remotePath: remote, overwrite: overwrite)
                summary.files += 1
            } else {
                summary.skipped += 1
            }
        }
        for local in localURLs { try await visit(local, [local.lastPathComponent]) }
        return summary
    }

    static func download(connection: ServerConnection, token: String, remotePath: String,
                         saveTo destination: URL) async throws {
        let url = try url(endpoint: connection.endpoint, path: "/v1/files/content", remotePath: remotePath)
        let session = try makeSession(connection: connection)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(for: request(url, method: "GET", token: token))
        try check(response, expected: 200)
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: temporary, to: destination)
    }
}

enum UploadValidationError: LocalizedError {
    case invalidSelection, duplicateNames, tooManyItems, fileTooLarge(String)
    var errorDescription: String? {
        switch self {
        case .invalidSelection: return "一次最多上传 100 个文件或文件夹"
        case .duplicateNames: return "所选文件或文件夹的名称重复"
        case .tooManyItems: return "一次最多上传 20000 个文件和目录"
        case .fileTooLarge(let name): return "\(name) 超过单文件 2 GiB 限制"
        }
    }
}
