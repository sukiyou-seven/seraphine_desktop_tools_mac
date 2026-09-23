import Foundation
import Darwin

enum FakeRedisError: Error, LocalizedError {
    case socket(String)
    case bindFailed(String)

    var errorDescription: String? {
        switch self {
        case .socket(let message): return message
        case .bindFailed(let message): return message
        }
    }
}

/// 进程内假 Redis 服务器，只实现 DBManager 用到的那些 RESP 命令，供自测使用。
final class FakeRedisServer {
    private let port: Int
    private var listenFD: Int32 = -1
    private var running = false

    /// 实际监听的端口（构造时传 0 表示自动挑一个空闲端口）。
    private(set) var boundPort: Int = 0

    private var strings: [String: String] = ["user:1": "hello world", "counter": "42", "tmp:session": "abc123"]
    private let hashes: [String: [String: String]] = ["cart:1": ["apple": "3", "banana": "5"]]
    private let lists: [String: [String]] = ["queue:jobs": ["job1", "job2", "job3"]]

    init(port: Int = 0) {
        self.port = port
    }

    var allKeys: [String] {
        (Array(strings.keys) + Array(hashes.keys) + Array(lists.keys)).sorted()
    }

    // MARK: 生命周期

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FakeRedisError.socket("无法创建 socket") }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw FakeRedisError.bindFailed("端口 \(port) 绑定失败：\(String(cString: strerror(errno)))")
        }
        guard listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw FakeRedisError.socket("listen 失败：\(String(cString: strerror(errno)))")
        }

        var actual = sockaddr_in()
        var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &actualLength)
            }
        }
        boundPort = named == 0 ? Int(UInt16(bigEndian: actual.sin_port)) : port

        listenFD = fd
        running = true
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFD, &clientAddr, &length)
            if client < 0 {
                if !running { break }
                continue
            }
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    // MARK: 单个连接

    private func serve(_ fd: Int32) {
        var buffer = Data()
        defer { Darwin.close(fd) }
        while running {
            guard let args = readCommand(fd, buffer: &buffer) else { return }
            guard let reply = handle(args) else { return }   // nil 表示响应后主动断开（SHUTDOWN）
            if !write(fd, reply) { return }
        }
    }

    private func readCommand(_ fd: Int32, buffer: inout Data) -> [String]? {
        guard let header = readLine(fd, buffer: &buffer), header.hasPrefix("*") else { return nil }
        guard let count = Int(header.dropFirst()) else { return nil }
        var args: [String] = []
        for _ in 0..<count {
            guard let lengthLine = readLine(fd, buffer: &buffer), lengthLine.hasPrefix("$"),
                  let length = Int(lengthLine.dropFirst()) else { return nil }
            guard let payload = readBytes(fd, buffer: &buffer, count: length) else { return nil }
            _ = readBytes(fd, buffer: &buffer, count: 2)   // 尾随 CRLF
            args.append(String(data: payload, encoding: .utf8) ?? "")
        }
        return args
    }

    private func readLine(_ fd: Int32, buffer: inout Data) -> String? {
        while true {
            if let range = buffer.range(of: Data([0x0D, 0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(data: line, encoding: .utf8)
            }
            guard fill(fd, buffer: &buffer) else { return nil }
        }
    }

    private func readBytes(_ fd: Int32, buffer: inout Data, count: Int) -> Data? {
        while buffer.count < count {
            guard fill(fd, buffer: &buffer) else { return nil }
        }
        let data = buffer.subdata(in: buffer.startIndex..<buffer.startIndex + count)
        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + count)
        return data
    }

    private func fill(_ fd: Int32, buffer: inout Data) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let read = Darwin.read(fd, &chunk, chunk.count)
        if read <= 0 { return false }
        buffer.append(contentsOf: chunk[0..<read])
        return true
    }

    private func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    // MARK: 命令实现

    private func handle(_ args: [String]) -> Data? {
        guard let command = args.first?.uppercased() else { return nil }
        switch command {
        case "PING":
            return simple("PONG")
        case "AUTH", "SELECT":
            return simple("OK")
        case "INFO":
            return bulk("redis_version:7.2.0\r\nredis_mode:standalone\r\nrole:master\r\n"
                        + "connected_clients:1\r\nused_memory_human:1.05M\r\nused_memory_peak_human:2.00M\r\n"
                        + "aof_enabled:0\r\nuptime_in_seconds:321\r\nkeyspace_hits:10\r\nkeyspace_misses:2\r\n"
                        + "db0:keys=5,expires=0,avg_ttl=0\r\n")
        case "DBSIZE":
            return integer(allKeys.count)
        case "SCAN":
            return array([bulk("0"), array(allKeys.map { bulk($0) })])
        case "TYPE":
            return simple(typeOf(args.count > 1 ? args[1] : ""))
        case "TTL":
            return integer(typeOf(args.count > 1 ? args[1] : "") == "none" ? -2 : -1)
        case "OBJECT":
            return bulk("embstr")
        case "SET":
            guard args.count > 2 else { return errorReply("ERR wrong number of arguments for 'set' command") }
            strings[args[1]] = args[2]
            return simple("OK")
        case "GET":
            guard args.count > 1, let value = strings[args[1]] else { return nullBulk() }
            return bulk(value)
        case "HGETALL":
            var flat: [Data] = []
            for (field, value) in (args.count > 1 ? hashes[args[1]] : nil) ?? [:] {
                flat.append(bulk(field))
                flat.append(bulk(value))
            }
            return array(flat)
        case "HLEN":
            return integer((args.count > 1 ? hashes[args[1]] : nil)?.count ?? 0)
        case "LLEN":
            return integer((args.count > 1 ? lists[args[1]] : nil)?.count ?? 0)
        case "LRANGE":
            return array((args.count > 1 ? lists[args[1]] : nil)?.map { bulk($0) } ?? [])
        case "SCARD", "ZCARD", "XLEN":
            return integer(0)
        case "SRANDMEMBER", "ZRANGE", "XRANGE":
            return array([])
        case "SHUTDOWN":
            return nil   // 模拟关停：不回复，直接断开
        default:
            return errorReply("ERR unknown command '\(args.first ?? "")'")
        }
    }

    private func typeOf(_ key: String) -> String {
        if strings[key] != nil { return "string" }
        if hashes[key] != nil { return "hash" }
        if lists[key] != nil { return "list" }
        return "none"
    }

    private func simple(_ text: String) -> Data { Data("+\(text)\r\n".utf8) }

    private func errorReply(_ text: String) -> Data { Data("-\(text)\r\n".utf8) }

    private func integer(_ value: Int) -> Data { Data(":\(value)\r\n".utf8) }

    private func bulk(_ text: String) -> Data {
        let data = Data(text.utf8)
        var out = Data("$\(data.count)\r\n".utf8)
        out.append(data)
        out.append(Data("\r\n".utf8))
        return out
    }

    private func nullBulk() -> Data { Data("$-1\r\n".utf8) }

    private func array(_ items: [Data]) -> Data {
        var out = Data("*\(items.count)\r\n".utf8)
        for item in items { out.append(item) }
        return out
    }
}
