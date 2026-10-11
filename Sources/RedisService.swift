import Foundation

struct RedisStatus {
    var installed = false
    var binary = ""
    var cli = ""
    var running = false
    var pid: Int32 = 0
    var host = "127.0.0.1"
    var port = 6379
    var confPath = ""
    var confExists = false
    var dirPath = ""
    var logFile = ""
    var version = ""
    var ping = ""
    var keys = ""
    var memory = ""
    var uptime = ""
}

struct RedisOverview {
    var database = 0
    var keys = 0
    var version = ""
    var mode = ""
    var uptime = ""
    var clients = ""
    var memory = ""
    var memoryPeak = ""
    var role = ""
    var aof = ""
    var hitRate = ""
    var keyspace: [(String, String)] = []
}

struct RedisKeyRow: Identifiable {
    var id: String { key }
    var key: String
    var type: String
    var typeLabel: String
    var ttl: Int

    var ttlLabel: String {
        if ttl == -2 { return "已过期" }
        if ttl == -1 { return "永久" }
        return "\(ttl)s"
    }
}

struct ScanPage {
    var cursor: Int
    var rows: [RedisKeyRow]
    var totalKeys: Int
    var scannedAll: Bool
}

struct RedisEntryRow: Identifiable {
    let id = UUID()
    var label: String
    var value: String
}

struct RedisValueDetail {
    var key = ""
    var type = ""
    var typeLabel = ""
    var ttlLabel = ""
    var encoding = ""
    var count: Int?
    var text: String?
    var rows: [RedisEntryRow] = []
    var truncated = false
    var note = ""
}

/// 只持有值类型的设置，本身无状态，可在后台线程安全使用。
final class RedisService: @unchecked Sendable {
    private(set) var settings: RedisSettings
    private static let maxItems = 200
    private static let maxStringPreview = 8000

    init(settings: RedisSettings) {
        self.settings = settings
    }

    // MARK: 路径解析

    var binary: String? {
        let custom = settings.bin.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return FileTools.exists(custom) ? custom : nil }
        return Paths.which("redis-server")
    }

    var cliPath: String? {
        let custom = settings.cli.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return FileTools.exists(custom) ? custom : nil }
        return Paths.which("redis-cli")
    }

    var confPath: String {
        let custom = settings.config.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        for candidate in [Paths.brewPrefix + "/etc/redis.conf", "/usr/local/etc/redis.conf"]
        where FileTools.exists(candidate) { return candidate }
        return Paths.confDir.appendingPathComponent("redis.conf").path
    }

    var defaultDir: String {
        let custom = settings.dir.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        let brewDir = Paths.brewPrefix + "/var/db/redis"
        return FileTools.isDirectory(brewDir) ? brewDir : Paths.appSupport.appendingPathComponent("redis").path
    }

    var defaultLogFile: String {
        let custom = settings.logfile.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? Paths.logDir.appendingPathComponent("redis.log").path : custom
    }

    var defaultPidFile: String {
        let custom = settings.pidfile.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? Paths.runDir.appendingPathComponent("redis.pid").path : custom
    }

    var host: String {
        let raw = settings.bind.trimmingCharacters(in: .whitespaces)
        let first = raw.split(separator: " ").first.map(String.init) ?? "127.0.0.1"
        return ["0.0.0.0", "*", "::", "-::1"].contains(first) ? "127.0.0.1" : first
    }

    var port: Int { settings.port }

    var password: String {
        let configured = settings.password
        if !configured.isEmpty { return configured }
        return ConfStore.redisGet(rawConfigText(), key: "requirepass")
    }

    // MARK: 配置文件

    @discardableResult
    func ensureConf() -> (path: String, generated: Bool) {
        let path = confPath
        if FileTools.exists(path) { return (path, false) }
        Paths.ensureDirectory(forFile: path)
        let text = ConfStore.generateRedisConf(port: port,
                                              bind: settings.bind.isEmpty ? "127.0.0.1" : settings.bind,
                                              dir: defaultDir, logFile: defaultLogFile,
                                              pidFile: defaultPidFile, password: settings.password)
        FileTools.write(path, text)
        return (path, true)
    }

    func rawConfigText() -> String {
        let (path, _) = ensureConf()
        return FileTools.read(path)
    }

    func configText() -> String {
        let (path, generated) = ensureConf()
        return "# 文件：\(path)\(generated ? "（由 Seraphim 生成）" : "")\n" + FileTools.read(path)
    }

    func confParams() -> [(spec: ConfStore.KeySpec, value: String)] {
        let text = rawConfigText()
        return ConfStore.redisKeys.map { spec in
            let value = ConfStore.redisGet(text, key: spec.id)
            return (spec, value.isEmpty ? spec.placeholder : value)
        }
    }

    func setParam(_ key: String, value: String) -> ActionResult {
        let (path, _) = ensureConf()
        let old = FileTools.read(path)
        let new = value.isEmpty ? ConfStore.redisUnset(old, key: key) : ConfStore.redisSet(old, key: key, value: value)
        return commit(path: path, old: old, new: new, verb: "已更新 \(key) = \(value.isEmpty ? "（注释掉）" : value)")
    }

    func saveConfigText(_ new: String) -> ActionResult {
        let (path, _) = ensureConf()
        let old = FileTools.read(path)
        return commit(path: path, old: old, new: new, verb: "配置已保存")
    }

    private func commit(path: String, old: String, new: String, verb: String) -> ActionResult {
        guard old != new else { return ActionResult(ok: false, message: "内容没有变化") }
        let (backup, error) = FileTools.writeWithBackup(path, old: old, new: new)
        if let error { return .failure("写入失败：\(error)") }
        var result = ActionResult(ok: true, message: verb)
        result.backupPath = backup ?? ""
        if status().running { result.detail = "Redis 正在运行，改动需重启后生效" }
        return result
    }

    func logTail(lines: Int = 80) -> String {
        let configured = ConfStore.redisGet(rawConfigText(), key: "logfile")
        if configured.isEmpty {
            return "配置里 logfile 为空，Redis 日志输出到 stdout（daemonize yes 时通常被丢弃）。"
        }
        let text = FileTools.tail(configured, lines: lines)
        return text.isEmpty ? "（日志为空或不存在：\(configured)）" : text
    }

    // MARK: 状态

    func status() -> RedisStatus {
        let (conf, _) = ensureConf()
        var info = RedisStatus()
        info.binary = binary ?? ""
        info.cli = cliPath ?? ""
        info.installed = binary != nil
        info.confPath = conf
        info.confExists = FileTools.exists(conf)
        info.dirPath = ConfStore.redisGet(rawConfigText(), key: "dir")
        if info.dirPath.isEmpty { info.dirPath = defaultDir }
        info.logFile = defaultLogFile
        info.host = host
        info.port = port
        let portIsOpen = PortCheck.isOpen(host: host, port: port)
        info.pid = currentPid()
        if portIsOpen && info.pid == 0 { info.pid = PortCheck.pids(forPort: port).first ?? 0 }

        if let binary {
            let version = Shell.run([binary, "--version"], timeout: 20)
            if version.ok, let line = version.stdout.lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                info.version = line.trimmingCharacters(in: .whitespaces)
            }
        }
        guard portIsOpen else { return info }
        info.running = true
        do {
            let client = try connectedClient()
            defer { client.close() }
            _ = try client.command(["PING"])
            let raw = try client.info()
            info.ping = "ok"
            if info.version.isEmpty, let v = raw["redis_version"] { info.version = "Redis \(v)" }
            info.keys = raw["db0"] ?? ""
            info.memory = raw["used_memory_human"] ?? ""
            info.uptime = raw["uptime_in_seconds"] ?? ""
        } catch {
            info.ping = "端口在监听，但握手失败：\(error.localizedDescription)"
        }
        return info
    }

    /// 只返回「确实是 redis-server」的 pid（同上：pid 文件会残留、pid 会被复用）。
    private func currentPid() -> Int32 {
        let fromPort = ProcUtil.servicePid(port: port, named: "redis-server")
        if fromPort > 0 { return fromPort }

        var candidates: [Int32] = [ProcUtil.readPidFile(defaultPidFile)]
        let configured = ConfStore.redisGet(rawConfigText(), key: "pidfile")
        if !configured.isEmpty { candidates.append(ProcUtil.readPidFile(configured)) }

        for candidate in candidates where ProcUtil.isProcess(candidate, named: "redis-server") {
            return candidate
        }
        return 0
    }

    // MARK: 启动 / 停止

    func start() -> ActionResult {
        guard let binary else {
            return .failure("找不到 redis-server。请先安装（brew install redis），或在「设置」里手动指定路径。")
        }
        if PortCheck.isOpen(host: host, port: port) {
            let owner = ProcUtil.describePortOwner(port: port)
            if ProcUtil.servicePid(port: port, named: "redis-server") > 0 {
                return .failure("端口 \(port) 已在监听，Redis 看起来已经在运行")
            }
            return .failure("端口 \(port) 被其它程序占用（\(owner)），不是 Redis。请先释放端口，或改配置文件里的 port。")
        }

        let (conf, generated) = ensureConf()
        let text = FileTools.read(conf)
        // 配置里的 dir / logfile 若是相对路径（brew 默认是 "."），不能直接用：
        // GUI app 的工作目录是 "/"，会写不进去。这里统一换成绝对路径。
        let configuredDir = ConfStore.redisGet(text, key: "dir")
        let resolvedDir = configuredDir.hasPrefix("/") ? configuredDir : defaultDir
        let configuredLog = ConfStore.redisGet(text, key: "logfile")
        let resolvedLog = configuredLog.hasPrefix("/") ? configuredLog : defaultLogFile

        do {
            try FileManager.default.createDirectory(atPath: resolvedDir, withIntermediateDirectories: true)
        } catch {
            return .failure("无法创建工作目录 \(resolvedDir)：\(error.localizedDescription)")
        }
        Paths.ensureDirectory(forFile: resolvedLog)
        Paths.ensureDirectory(forFile: defaultPidFile)

        var args = [binary, conf]
        if ConfStore.redisGet(text, key: "daemonize").lowercased() != "yes" {
            args += ["--daemonize", "yes"]
        }
        // 显式覆盖这三个路径，避免沿用配置里的相对路径或系统默认位置。
        args += ["--dir", resolvedDir, "--logfile", resolvedLog, "--pidfile", defaultPidFile]

        let result = Shell.run(args, timeout: 40)
        guard result.ok else {
            var failure = ActionResult.failure("启动失败：\(result.message)")
            failure.logTail = FileTools.tail(resolvedLog, lines: 30)
            return failure
        }
        guard PortCheck.waitOpen(host: host, port: port, timeout: 20) else {
            var failure = ActionResult.failure("进程已拉起，但端口 \(port) 未就绪")
            failure.logTail = FileTools.tail(resolvedLog, lines: 30)
            return failure
        }
        var success = ActionResult(ok: true, message: "Redis 已启动")
        if generated { success.detail = "使用新生成的配置：\(conf)" }
        return success
    }

    func stop() -> ActionResult {
        guard PortCheck.isOpen(host: host, port: port) || ProcUtil.isAlive(currentPid()) else {
            return .failure("Redis 当前没有在运行")
        }

        var shutdownError = ""
        do {
            let client = try connectedClient()
            defer { client.close() }
            // SHUTDOWN 会让服务端**立刻断开连接**，所以命令返回什么都别管 ——
            // 唯一可靠的判据是端口有没有关（之前靠命令返回值判断，导致明明停掉了却报失败）。
            _ = try? client.commandAllowingDisconnect(["SHUTDOWN", "SAVE"])
            if PortCheck.waitClosed(host: host, port: port, timeout: 5) {
                return ActionResult(ok: true, message: "Redis 已优雅停止（SHUTDOWN SAVE）")
            }
            // SAVE 可能失败：实测 RDB 目录不可写时，Redis 会回
            // "ERR Errors trying to SHUTDOWN" 并**拒绝退出**（日志里是 Operation not permitted）。
            // 这时退而求其次用 NOSAVE —— 该停还是要停，但要在结果里讲清"数据没落盘"。
            _ = try? client.commandAllowingDisconnect(["SHUTDOWN", "NOSAVE"])
            if PortCheck.waitClosed(host: host, port: port, timeout: 8) {
                var result = ActionResult(ok: true, message: "Redis 已停止（NOSAVE —— 未能写入 RDB）")
                result.detail = "SHUTDOWN SAVE 被 Redis 拒绝（多半是 RDB 目录不可写），"
                              + "已改用 NOSAVE 停止：内存中的数据**没有落盘**，请留意。"
                return result
            }
            shutdownError = "SHUTDOWN 已发送，但端口 \(port) 仍在监听"
        } catch {
            shutdownError = error.localizedDescription
        }

        // 最后一道保险：只有确认是 redis-server 才发信号
        let pid = currentPid()
        if ProcUtil.isAlive(pid), ProcUtil.isProcess(pid, named: "redis-server"), ProcUtil.terminate(pid) {
            if PortCheck.waitClosed(host: host, port: port, timeout: 25) {
                return ActionResult(ok: true, message: "Redis 已停止（SIGTERM pid=\(pid)）")
            }
            _ = ProcUtil.terminate(pid, signal: SIGKILL)
            if PortCheck.waitClosed(host: host, port: port, timeout: 10) {
                return ActionResult(ok: true, message: "Redis 被强制停止（SIGKILL pid=\(pid)）")
            }
        }
        var failure = ActionResult.failure("停止失败：\(shutdownError)")
        if !settings.password.isEmpty && ProcUtil.readPidFile(defaultPidFile) == 0 {
            failure.detail = "提示：配置里的 requirepass 与「设置」中的密码不一致时无法通过协议关停。"
        }
        return failure
    }

    func restart() -> ActionResult {
        let stopResult = stop()
        let startResult = start()
        guard startResult.ok else { return startResult }
        return ActionResult(ok: true, message: "重启完成", detail: stopResult.message)
    }

    // MARK: 客户端

    func connectedClient(database: Int? = nil) throws -> RedisClient {
        let client = RedisClient(host: host, port: port, password: password)
        try client.connect()
        if let database, database != 0 { try client.select(database) }
        return client
    }

    // MARK: 内容浏览

    func overview(database: Int) -> Outcome<RedisOverview> {
        do {
            let client = try connectedClient(database: database)
            defer { client.close() }
            let raw = try client.info()
            var overview = RedisOverview()
            overview.database = database
            overview.keys = try client.dbSize()
            overview.version = raw["redis_version"] ?? ""
            overview.mode = raw["redis_mode"] ?? ""
            overview.uptime = raw["uptime_in_seconds"] ?? ""
            overview.clients = raw["connected_clients"] ?? ""
            overview.memory = raw["used_memory_human"] ?? ""
            overview.memoryPeak = raw["used_memory_peak_human"] ?? ""
            overview.role = raw["role"] ?? ""
            overview.aof = raw["aof_enabled"] ?? ""
            let hits = Int(raw["keyspace_hits"] ?? "0") ?? 0
            let misses = Int(raw["keyspace_misses"] ?? "0") ?? 0
            overview.hitRate = (hits + misses) > 0
                ? String(format: "%.1f%%", Double(hits) * 100 / Double(hits + misses)) : "n/a"
            overview.keyspace = raw.filter { $0.key.hasPrefix("db") }
                .sorted { $0.key < $1.key }
                .map { ($0.key, $0.value) }
            return .success(overview)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func scanKeys(pattern: String, cursor: Int, count: Int, database: Int) -> Outcome<ScanPage> {
        do {
            let client = try connectedClient(database: database)
            defer { client.close() }
            let (next, keys) = try client.scan(pattern: pattern, cursor: cursor, count: count)
            var rows: [RedisKeyRow] = []
            for key in keys.prefix(Self.maxItems) {
                let type = (try? client.type(ofKey: key)) ?? "?"
                let ttl = (try? client.ttl(ofKey: key)) ?? -1
                rows.append(RedisKeyRow(key: key, type: type, typeLabel: Self.typeLabel(type), ttl: ttl))
            }
            rows.sort { $0.key < $1.key }
            return .success(ScanPage(cursor: next, rows: rows, totalKeys: try client.dbSize(),
                                     scannedAll: next == 0))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func value(forKey key: String, database: Int) -> Outcome<RedisValueDetail> {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure("key 不能为空") }
        do {
            let client = try connectedClient(database: database)
            defer { client.close() }
            let type = try client.type(ofKey: trimmed)
            guard type != "none" else { return .failure("key 不存在：\(trimmed)") }

            var detail = RedisValueDetail()
            detail.key = trimmed
            detail.type = type
            detail.typeLabel = Self.typeLabel(type)
            let ttl = try client.ttl(ofKey: trimmed)
            detail.ttlLabel = ttl == -1 ? "永久" : (ttl >= 0 ? "\(ttl) 秒" : "无")
            detail.encoding = (try? client.command(["OBJECT", "ENCODING", trimmed]).stringValue ?? "") ?? ""
            let limit = Self.maxItems

            switch type {
            case "string":
                let raw = (try client.command(["GET", trimmed])).stringValue ?? ""
                detail.count = raw.count
                detail.text = String(raw.prefix(Self.maxStringPreview))
                detail.truncated = raw.count > Self.maxStringPreview
                if detail.encoding.isEmpty { detail.encoding = "—" }
            case "hash":
                let flat = try client.command(["HGETALL", trimmed])
                let all = client.pairs(flat)
                detail.count = (try client.command(["HLEN", trimmed])).intValue ?? all.count
                detail.rows = all.prefix(limit).map { RedisEntryRow(label: $0.0, value: $0.1) }
                detail.truncated = all.count > limit
            case "list":
                detail.count = (try client.command(["LLEN", trimmed])).intValue ?? 0
                let items = (try client.command(["LRANGE", trimmed, "0", String(limit - 1)])).arrayValue ?? []
                detail.rows = items.enumerated().map { RedisEntryRow(label: "[\($0.offset)]", value: $0.element.stringValue ?? "") }
                detail.truncated = (detail.count ?? 0) > limit
            case "set":
                detail.count = (try client.command(["SCARD", trimmed])).intValue ?? 0
                let items = (try client.command(["SRANDMEMBER", trimmed, String(limit)])).arrayValue ?? []
                detail.rows = items.map { RedisEntryRow(label: "member", value: $0.stringValue ?? "") }
                    .sorted { $0.value < $1.value }
                detail.truncated = (detail.count ?? 0) > limit
                detail.note = "集合无序，这里随机取样展示"
            case "zset":
                detail.count = (try client.command(["ZCARD", trimmed])).intValue ?? 0
                let flat = try client.command(["ZRANGE", trimmed, "0", String(limit - 1), "WITHSCORES"])
                let pairs = client.pairs(flat)
                detail.rows = pairs.enumerated().map {
                    RedisEntryRow(label: "#\($0.offset + 1)  score=\($0.element.1)", value: $0.element.0)
                }
                detail.truncated = (detail.count ?? 0) > limit
            case "stream":
                detail.count = (try client.command(["XLEN", trimmed])).intValue ?? 0
                let entries = (try client.command(["XRANGE", trimmed, "-", "+", "COUNT", String(limit)])).arrayValue ?? []
                detail.rows = entries.map { entry in
                    let parts = entry.arrayValue ?? []
                    let id = parts.first?.stringValue ?? "?"
                    let fields = (parts.count > 1 ? parts[1].arrayValue ?? [] : []).compactMap { $0.stringValue }
                    var text = ""
                    var index = 0
                    while index + 1 < fields.count {
                        text += fields[index] + "=" + fields[index + 1] + "\n"
                        index += 2
                    }
                    return RedisEntryRow(label: id, value: text.trimmingCharacters(in: .newlines))
                }
                detail.truncated = (detail.count ?? 0) > limit
            default:
                detail.note = "暂不支持的类型：\(type)"
            }
            return .success(detail)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func execute(_ line: String, database: Int) -> Outcome<String> {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("命令不能为空") }
        guard let args = Self.splitCommandLine(trimmed), !args.isEmpty else {
            return .failure("命令解析失败（引号不配对？）")
        }
        if args.count == 1, ["exit", "quit"].contains(args[0].lowercased()) {
            return .success("（已退出，可继续输入）")
        }
        do {
            let client = try connectedClient(database: database)
            defer { client.close() }
            let reply = try client.command(args)
            return .success(reply.display)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func configGet(pattern: String) -> Outcome<[(String, String)]> {
        do {
            let client = try connectedClient()
            defer { client.close() }
            let reply = try client.command(["CONFIG", "GET", pattern.isEmpty ? "*" : pattern])
            return .success(client.pairs(reply))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: 辅助

    static func typeLabel(_ type: String) -> String {
        switch type {
        case "string": return "字符串"
        case "list": return "列表"
        case "set": return "集合"
        case "zset": return "有序集合"
        case "hash": return "哈希"
        case "stream": return "流"
        case "none": return "不存在"
        default: return type
        }
    }

    /// 把一行命令拆成参数，支持单/双引号与反斜杠转义。
    static func splitCommandLine(_ line: String) -> [String]? {
        var args: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?
        var escaped = false

        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                hasToken = true
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                hasToken = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasToken = true
                continue
            }
            if character == " " || character == "\t" {
                if hasToken {
                    args.append(current)
                    current = ""
                    hasToken = false
                }
                continue
            }
            current.append(character)
            hasToken = true
        }
        if escaped { current.append("\\"); hasToken = true }
        if quote != nil { return nil }
        if hasToken { args.append(current) }
        return args
    }
}
