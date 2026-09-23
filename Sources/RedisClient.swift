import Foundation
import Darwin

/// RESP2 协议的返回值。
indirect enum RedisValue {
    case simple(String)
    case error(String)
    case integer(Int)
    case bulk(String?)
    case array([RedisValue]?)

    var stringValue: String? {
        switch self {
        case .simple(let value): return value
        case .bulk(let value): return value
        case .integer(let value): return String(value)
        case .error(let message): return message
        case .array: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let value): return value
        case .simple(let value), .bulk(let value?): return Int(value.replacingOccurrences(of: "\r", with: ""))
        default: return nil
        }
    }

    var arrayValue: [RedisValue]? {
        if case .array(let items) = self { return items ?? [] }
        return nil
    }

    /// 面向界面的可读文本。
    var display: String {
        switch self {
        case .simple(let value): return value
        case .error(let message): return "(error) " + message
        case .integer(let value): return "(integer) \(value)"
        case .bulk(let value): return value ?? "(nil)"
        case .array(let items):
            guard let items else { return "(nil)" }
            if items.isEmpty { return "(empty array)" }
            return items.enumerated().map { index, item in
                "\(index + 1)) " + item.display
            }.joined(separator: "\n")
        }
    }
}

enum RedisClientError: LocalizedError {
    case connection(String)
    case server(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .connection(let message): return message
        case .server(let message): return message
        case .malformed(let message): return message
        }
    }
}

/// 只用标准库 socket 实现的 Redis 客户端 —— 不需要 redis-cli。
final class RedisClient {
    private let host: String
    private let port: Int
    private var password: String
    private let timeout: TimeInterval
    private var fd: Int32 = -1
    private var buffer = Data()

    init(host: String, port: Int, password: String, timeout: TimeInterval = 6) {
        self.host = host
        self.port = port
        self.password = password
        self.timeout = timeout
    }

    deinit { close() }

    var isConnected: Bool { fd >= 0 }

    // MARK: 连接

    func connect() throws {
        guard fd < 0 else { return }
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw RedisClientError.connection("无法创建 socket")
        }

        var noSigPipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr(host.isEmpty ? "127.0.0.1" : host)

        let rc = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let reason = String(cString: strerror(errno))
            close()
            throw RedisClientError.connection("无法连接 \(host):\(port) — \(reason)")
        }
        fd = socketFD
        buffer.removeAll(keepingCapacity: true)

        if !password.isEmpty {
            let reply = try command(["AUTH", password])
            if reply.stringValue?.uppercased() != "OK" {
                close()
                throw RedisClientError.server("AUTH 失败：\(reply.display)")
            }
        }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        buffer.removeAll(keepingCapacity: false)
    }

    // MARK: 收发

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    throw RedisClientError.connection("发送失败：\(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
    }

    private func fill() throws {
        var chunk = [UInt8](repeating: 0, count: 16384)
        let read = Darwin.read(fd, &chunk, chunk.count)
        if read < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { throw RedisClientError.connection("读取超时") }
            throw RedisClientError.connection("读取失败：\(String(cString: strerror(errno)))")
        }
        if read == 0 { throw RedisClientError.connection("服务端关闭了连接") }
        buffer.append(contentsOf: chunk[0..<read])
    }

    private func readLine() throws -> String {
        while true {
            if let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            try fill()
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        while buffer.count < count { try fill() }
        let data = buffer.subdata(in: buffer.startIndex..<buffer.startIndex + count)
        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + count)
        return data
    }

    private func readReply() throws -> RedisValue {
        let line = try readLine()
        guard let tag = line.first else { throw RedisClientError.malformed("空响应") }
        let payload = String(line.dropFirst())
        switch tag {
        case "+":
            return .simple(payload)
        case "-":
            throw RedisClientError.server(payload)
        case ":":
            return .integer(Int(payload) ?? 0)
        case "$":
            let length = Int(payload) ?? -1
            if length < 0 {
                _ = try readExactly(2)
                return .bulk(nil)
            }
            let data = try readExactly(length + 2)
            return .bulk(String(data: data.dropLast(2), encoding: .utf8) ?? "")
        case "*":
            let count = Int(payload) ?? -1
            if count < 0 { return .array(nil) }
            var items: [RedisValue] = []
            items.reserveCapacity(count)
            for _ in 0..<count { items.append(try readReply()) }
            return .array(items)
        default:
            throw RedisClientError.malformed("无法识别的响应：\(line)")
        }
    }

    // MARK: 命令

    @discardableResult
    func command(_ args: [String]) throws -> RedisValue {
        try connect()
        var out = Data("*\(args.count)\r\n".utf8)
        for arg in args {
            let data = Data(arg.utf8)
            out.append(Data("$\(data.count)\r\n".utf8))
            out.append(data)
            out.append(Data("\r\n".utf8))
        }
        try writeAll(out)
        return try readReply()
    }

    /// 发送一个可能让对端**直接断开连接**的命令（例如 SHUTDOWN）。
    ///
    /// Redis 收到 SHUTDOWN 会立刻关闭连接，所以此后读响应报错／超时都属正常现象。
    /// 因此**不能**用"读到正常回复"判断命令是否生效，也**不能**去匹配具体错误文本
    /// —— 之前就是只认"关闭了连接"这一个字符串，换个错误消息（连接重置 / EOF / 超时）
    /// 就被误判成失败，于是明明停掉了却报"停止失败"。
    /// 是否真的停掉，由调用方用**端口是否关闭**来确认。
    @discardableResult
    func commandAllowingDisconnect(_ args: [String]) throws -> Bool {
        do {
            _ = try command(args)
            return true
        } catch {
            return false
        }
    }

    // MARK: 便捷封装

    func ping() -> Bool {
        (try? command(["PING"]).stringValue?.uppercased()) == "PONG"
    }

    func select(_ database: Int) throws {
        _ = try command(["SELECT", String(database)])
    }

    func info(_ section: String = "") throws -> [String: String] {
        let raw = section.isEmpty ? try command(["INFO"]) : try command(["INFO", section])
        var result: [String: String] = [:]
        for line in (raw.stringValue ?? "").lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#"), let colon = text.firstIndex(of: ":") else { continue }
            let key = String(text[text.startIndex..<colon])
            let value = String(text[text.index(after: colon)...])
            result[key] = value
        }
        return result
    }

    func scan(pattern: String, cursor: Int, count: Int) throws -> (cursor: Int, keys: [String]) {
        let reply = try command(["SCAN", String(cursor), "MATCH", pattern.isEmpty ? "*" : pattern,
                                 "COUNT", String(count)])
        guard let items = reply.arrayValue, items.count >= 2 else {
            throw RedisClientError.malformed("SCAN 返回异常：\(reply.display)")
        }
        let next = Int(items[0].stringValue ?? "0") ?? 0
        let keys = (items[1].arrayValue ?? []).compactMap { $0.stringValue }
        return (next, keys)
    }

    func type(ofKey key: String) throws -> String {
        (try command(["TYPE", key])).stringValue ?? "none"
    }

    func dbSize() throws -> Int {
        (try command(["DBSIZE"])).intValue ?? 0
    }

    func ttl(ofKey key: String) throws -> Int {
        (try command(["TTL", key])).intValue ?? -1
    }

    func pairs(_ reply: RedisValue) -> [(String, String)] {
        let items = reply.arrayValue ?? []
        var result: [(String, String)] = []
        var index = 0
        while index + 1 < items.count {
            result.append((items[index].stringValue ?? "", items[index + 1].stringValue ?? ""))
            index += 2
        }
        return result
    }
}
