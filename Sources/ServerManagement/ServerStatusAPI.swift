import Foundation
import CryptoKit
import Security
import Darwin

// 只读接口的数据协议。服务端增加字段不会影响旧客户端；schema_version 变更时明确报错。
struct ServerSnapshot: Decodable {
    struct Host: Decodable {
        let hostname: String
        let os: String
        let kernel: String
        let architecture: String
        let uptimeSeconds: UInt64
    }

    struct CPU: Decodable {
        let usagePercent: Double
        let logicalCores: Int
        let load1M: Double
        let load5M: Double
        let load15M: Double
    }

    struct Memory: Decodable {
        let totalBytes: UInt64
        let availableBytes: UInt64
        let usedBytes: UInt64
        let usagePercent: Double
    }

    struct Swap: Decodable {
        let totalBytes: UInt64
        let usedBytes: UInt64
        let usagePercent: Double
    }

    struct Disk: Decodable {
        let device: String
        let mountpoint: String
        let filesystem: String
        let totalBytes: UInt64
        let availableBytes: UInt64
        let usedBytes: UInt64
        let usagePercent: Double
    }

    struct Network: Decodable {
        let name: String
        let rxBytes: UInt64
        let txBytes: UInt64
        let rxBytesPerSecond: UInt64
        let txBytesPerSecond: UInt64
    }

    let schemaVersion: Int
    let timestamp: String
    let host: Host
    let cpu: CPU
    let memory: Memory
    let swap: Swap
    let disks: [Disk]
    let network: [Network]
}

enum ServerStatusError: LocalizedError {
    case invalidAddress
    case invalidFingerprint
    case unsupportedSchema(Int)
    case http(Int)
    case tls(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请输入完整的 HTTPS 地址，例如 https://1.2.3.4:27520"
        case .invalidFingerprint: return "证书指纹应为 64 位 SHA-256 十六进制字符"
        case .unsupportedSchema(let version): return "服务端数据版本 \(version) 暂不支持"
        case .http(401): return "API 令牌无效，请核对当前服务器的连接令牌"
        case .http(let code): return "服务器返回 HTTP \(code)"
        case .tls(let detail): return detail
        }
    }
}

struct ServerConnection: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = ""
    var endpoint = ""
    var fingerprint = ""

    var label: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (endpoint.isEmpty ? "新服务器" : endpoint) : name
    }
}

enum ServerConnectionStore {
    private static let connectionsKey = "serverManagement.connections"
    private static let selectedKey = "serverManagement.selectedID"
    private struct Entry: Codable {
        var connection: ServerConnection
        var token: String
    }
    private struct Document: Codable {
        var selectedID: String
        var entries: [Entry]
    }

    // 测试可指定临时目录；正式应用始终使用用户的应用数据目录。
    static var storageDirectoryOverride: URL?

    static var storageDirectory: URL {
        if let storageDirectoryOverride { return storageDirectoryOverride }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Seraphim/server-management", isDirectory: true)
    }

    static var storageFile: URL { storageDirectory.appendingPathComponent("connections.json") }

    private static func read() throws -> Document {
        if FileManager.default.fileExists(atPath: storageFile.path) {
            return try JSONDecoder().decode(Document.self, from: Data(contentsOf: storageFile))
        }
        // 只搬旧连接的地址、名称、指纹；不访问钥匙串，避免再次要求系统密码。
        let old = UserDefaults.standard.data(forKey: connectionsKey)
            .flatMap { try? JSONDecoder().decode([ServerConnection].self, from: $0) } ?? []
        let connections = old.isEmpty ? [ServerConnection(name: "服务器 1",
                                                         endpoint: UserDefaults.standard.string(forKey: "serverStatus.endpoint") ?? "",
                                                         fingerprint: UserDefaults.standard.string(forKey: "serverStatus.fingerprint") ?? "")] : old
        let savedID = UserDefaults.standard.string(forKey: selectedKey) ?? ""
        let selectedID = connections.contains(where: { $0.id == savedID }) ? savedID : connections[0].id
        let migrated = Document(selectedID: selectedID, entries: connections.map { Entry(connection: $0, token: "") })
        try write(migrated)
        return migrated
    }

    private static func write(_ document: Document) throws {
        let directory = storageDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".connections-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try JSONEncoder().encode(document)
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if rename(temporary.path, storageFile.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func load() -> [ServerConnection] {
        (try? read().entries.map(\.connection)) ?? [ServerConnection(name: "服务器 1")]
    }

    static var selectedID: String {
        (try? read().selectedID) ?? load()[0].id
    }

    static func save(_ connections: [ServerConnection], selectedID: String, token: String? = nil) throws {
        let previous = try read()
        let oldTokens = Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.connection.id, $0.token) })
        let entries = connections.map { connection in
            Entry(connection: connection,
                  token: connection.id == selectedID ? (token ?? oldTokens[connection.id] ?? "")
                                                     : (oldTokens[connection.id] ?? ""))
        }
        try write(Document(selectedID: selectedID, entries: entries))
    }

    static func select(_ id: String) throws {
        var document = try read()
        document.selectedID = id
        try write(document)
    }

    static func token(for id: String) -> String {
        (try? read().entries.first(where: { $0.connection.id == id })?.token) ?? ""
    }
}

final class CertificatePinDelegate: NSObject, URLSessionDelegate {
    let fingerprint: String
    private let lock = NSLock()
    private var rejection: String?

    init(fingerprint: String) { self.fingerprint = fingerprint }

    var rejectionMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return rejection
    }

    private func reject(_ message: String,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        lock.lock()
        rejection = message
        lock.unlock()
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward the bearer token to a different endpoint.
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !fingerprint.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first else {
            reject("无法读取服务器证书，请检查 HTTPS 地址。", completionHandler: completionHandler)
            return
        }
        let bytes = SecCertificateCopyData(certificate) as Data
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if actual == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            reject("服务器证书指纹不匹配，请核对连接地址与证书指纹。", completionHandler: completionHandler)
        }
    }
}

enum ServerStatusAPI {
    static func sessionConfiguration(endpoint: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        guard let rawHost = URLComponents(string: endpoint)?.host else { return configuration }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv4.s_addr) { Array($0) }
            if bytes[0] == 10 || bytes[0] == 127 ||
                (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
                (bytes[0] == 192 && bytes[1] == 168) ||
                (bytes[0] == 169 && bytes[1] == 254) ||
                (bytes[0] == 100 && (64...127).contains(bytes[1])) {
                configuration.connectionProxyDictionary = [:]
            }
        } else if host == "localhost" || host.lowercased().hasSuffix(".local") {
            configuration.connectionProxyDictionary = [:]
        } else {
            var ipv6 = in6_addr()
            if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
                let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
                if bytes == [UInt8](repeating: 0, count: 15) + [1] ||
                    (bytes[0] & 0xfe) == 0xfc ||
                    (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) {
                    configuration.connectionProxyDictionary = [:]
                }
            }
        }
        return configuration
    }

    static func normalizedFingerprint(_ input: String) throws -> String {
        let normalized = input.lowercased().filter { $0 != ":" && $0 != " " && $0 != "-" }
        guard normalized.isEmpty || (normalized.count == 64 && normalized.allSatisfy(\.isHexDigit)) else {
            throw ServerStatusError.invalidFingerprint
        }
        return normalized
    }

    static func statusURL(_ input: String) throws -> URL {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", parts.host != nil,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw ServerStatusError.invalidAddress
        }
        parts.path = "/v1/status"
        guard let url = parts.url else { throw ServerStatusError.invalidAddress }
        return url
    }

    static func fetch(endpoint: String, token: String, fingerprint: String) async throws -> ServerSnapshot {
        let url = try statusURL(endpoint)
        let pin = try normalizedFingerprint(fingerprint)
        let config = sessionConfiguration(endpoint: endpoint)
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let delegate = CertificatePinDelegate(fingerprint: pin)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let reason = delegate.rejectionMessage { throw ServerStatusError.tls(reason) }
            let networkError = error as NSError
            if networkError.domain == NSURLErrorDomain,
               [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot].contains(networkError.code) {
                if pin.isEmpty {
                    throw ServerStatusError.tls("HTTPS 证书未通过验证。自签证书请填写服务端证书的 SHA-256 指纹；正式证书请核对域名和有效期。")
                }
                throw ServerStatusError.tls("TLS 握手失败，请检查地址、端口和服务器证书。")
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw ServerStatusError.http(0) }
        guard http.statusCode == 200 else { throw ServerStatusError.http(http.statusCode) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let snapshot = try decoder.decode(ServerSnapshot.self, from: data)
        guard snapshot.schemaVersion == 1 else { throw ServerStatusError.unsupportedSchema(snapshot.schemaVersion) }
        return snapshot
    }
}
