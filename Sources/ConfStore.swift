import Foundation

/// 配置文件的行级读写：mongod.conf（YAML 子集）与 redis.conf（平铺 key value）。
/// 只动目标行，其余内容（注释、格式）原样保留。
enum ConfStore {

    // MARK: mongod.conf

    private struct Line {
        let index: Int
        let indent: Int
        let key: String
        let value: String?
    }

    private static func parseMongo(_ text: String) -> [Line] {
        var rows: [Line] = []
        for (index, raw) in text.lines.enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#"), !value.hasPrefix("\"") {
                value = String(value[value.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
            }
            rows.append(Line(index: index, indent: indent, key: key, value: value.isEmpty ? nil : value))
        }
        return rows
    }

    static func mongoGet(_ text: String, path: [String]) -> String {
        let rows = parseMongo(text)
        let wantedSection = path.count > 1 ? path[0] : nil
        let wantedKey = path[path.count - 1]
        var section: String?
        for row in rows {
            if row.indent == 0 {
                section = row.key
                if wantedSection == nil && row.key == wantedKey { return row.value ?? "" }
                continue
            }
            if section == wantedSection && row.key == wantedKey { return row.value ?? "" }
        }
        return ""
    }

    static func mongoSet(_ text: String, path: [String], value: String) -> String {
        var lines = text.lines
        let rows = parseMongo(text)
        let wantedSection = path.count > 1 ? path[0] : nil
        let wantedKey = path[path.count - 1]
        let rendered = "\(wantedKey): \(value)"

        if wantedSection == nil {
            for row in rows where row.indent == 0 && row.key == wantedKey {
                lines[row.index] = rendered + inlineComment(lines[row.index])
                return join(lines, like: text)
            }
            lines.append(rendered)
            return join(lines, like: text)
        }

        var sectionLine: Int?
        var sectionIndent = 0
        var sectionEnd = lines.count
        for row in rows {
            if row.indent == 0 && row.key == wantedSection {
                sectionLine = row.index
                sectionIndent = row.indent
                continue
            }
            guard let start = sectionLine, row.index > start else { continue }
            if row.indent == 0 { sectionEnd = row.index; break }
            if row.key == wantedKey {
                lines[row.index] = String(repeating: " ", count: sectionIndent + 2) + rendered
                    + inlineComment(lines[row.index])
                return join(lines, like: text)
            }
        }

        guard sectionLine != nil else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append("\(wantedSection!):")
            lines.append("  " + rendered)
            return join(lines, like: text)
        }

        lines.insert(String(repeating: " ", count: sectionIndent + 2) + rendered, at: sectionEnd)
        return join(lines, like: text)
    }

    static func generateMongodConf(dbPath: String, logPath: String, port: Int,
                                   bindIp: String, auth: Bool) -> String {
        """
        # 由 DBManager 生成的最小可用配置
        storage:
          dbPath: \(dbPath)
        systemLog:
          destination: file
          logAppend: true
          path: \(logPath)
        net:
          bindIp: \(bindIp)
          port: \(port)
        processManagement:
          fork: true
          pidFilePath: \(dbPath.hasSuffix("/") ? dbPath : dbPath + "/")mongod.pid
        security:
          authorization: \(auth ? "enabled" : "disabled")

        """
    }

    struct KeySpec: Identifiable {
        struct Option {
            let value: String
            let label: String
        }

        let id: String
        let label: String
        let placeholder: String
        /// 非空表示这是个「只能取固定值」的配置项，界面上渲染成下拉选择。
        var options: [Option] = []

        var isChoice: Bool { !options.isEmpty }
    }

    static let mongoKeys: [KeySpec] = [
        KeySpec(id: "net.bindIp", label: "监听地址", placeholder: "127.0.0.1"),
        KeySpec(id: "net.port", label: "端口", placeholder: "27017"),
        KeySpec(id: "storage.dbPath", label: "数据目录", placeholder: ""),
        KeySpec(id: "systemLog.path", label: "日志文件", placeholder: ""),
        KeySpec(id: "security.authorization", label: "是否开启鉴权", placeholder: "disabled",
                options: [.init(value: "disabled", label: "关闭（不需要密码）"),
                          .init(value: "enabled", label: "开启（需要账号密码）")]),
        KeySpec(id: "processManagement.fork", label: "后台运行 fork", placeholder: "false",
                options: [.init(value: "false", label: "否（macOS 必需）"),
                          .init(value: "true", label: "是（仅旧版本可用）")]),
        KeySpec(id: "net.maxIncomingConnections", label: "最大连接数", placeholder: "不限"),
        KeySpec(id: "operationProfiling.mode", label: "慢查询剖析", placeholder: "off",
                options: [.init(value: "off", label: "关闭"),
                          .init(value: "slowOp", label: "只记录慢操作"),
                          .init(value: "all", label: "记录全部操作")]),
    ]

    // MARK: redis.conf

    static func redisGet(_ text: String, key: String) -> String {
        for raw in text.lines {
            let trimmed = String(raw).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count >= 1, parts[0] == key {
                return parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            }
        }
        return ""
    }

    static func redisSet(_ text: String, key: String, value: String) -> String {
        var lines = text.lines
        let rendered = value.isEmpty ? key : "\(key) \(value)"
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.first == Substring(key) {
                lines[index] = rendered + inlineComment(lines[index])
                return join(lines, like: text)
            }
            if trimmed.hasPrefix("#") {
                let inner = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if inner.split(separator: " ").first == Substring(key) {
                    lines[index] = rendered
                    return join(lines, like: text)
                }
            }
        }
        lines.append(rendered)
        return join(lines, like: text)
    }

    static func redisUnset(_ text: String, key: String) -> String {
        var lines = text.lines
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.split(separator: " ").first == Substring(key) {
                lines[index] = "# " + trimmed
            }
        }
        return join(lines, like: text)
    }

    static func generateRedisConf(port: Int, bind: String, dir: String, logFile: String,
                                  pidFile: String, password: String) -> String {
        var lines = [
            "# 由 DBManager 生成的最小可用配置",
            "bind \(bind)",
            "port \(port)",
            "daemonize yes",
            "protected-mode yes",
            "dir \(dir)",
            "logfile \(logFile)",
            "pidfile \(pidFile)",
            "save 3600 1 300 100 60 10000",
            "appendonly no",
        ]
        if !password.isEmpty { lines.append("requirepass \(password)") }
        return lines.joined(separator: "\n") + "\n"
    }

    static let redisKeys: [KeySpec] = [
        KeySpec(id: "bind", label: "监听地址", placeholder: "127.0.0.1"),
        KeySpec(id: "port", label: "端口", placeholder: "6379"),
        KeySpec(id: "requirepass", label: "密码（留空表示无密码）", placeholder: "无密码"),
        KeySpec(id: "daemonize", label: "后台运行 daemonize", placeholder: "yes",
                options: [.init(value: "yes", label: "是"), .init(value: "no", label: "否")]),
        KeySpec(id: "appendonly", label: "AOF 持久化", placeholder: "no",
                options: [.init(value: "no", label: "关闭"), .init(value: "yes", label: "开启")]),
        KeySpec(id: "maxmemory", label: "最大内存", placeholder: "不限，如 512mb"),
        KeySpec(id: "maxmemory-policy", label: "内存淘汰策略", placeholder: "noeviction",
                options: [.init(value: "noeviction", label: "不淘汰，写入报错"),
                          .init(value: "allkeys-lru", label: "全部 key：最近最少使用"),
                          .init(value: "allkeys-lfu", label: "全部 key：最少使用频率"),
                          .init(value: "allkeys-random", label: "全部 key：随机"),
                          .init(value: "volatile-lru", label: "仅带过期时间：最近最少使用"),
                          .init(value: "volatile-lfu", label: "仅带过期时间：最少使用频率"),
                          .init(value: "volatile-random", label: "仅带过期时间：随机"),
                          .init(value: "volatile-ttl", label: "仅带过期时间：最快过期优先")]),
        KeySpec(id: "dir", label: "数据目录", placeholder: ""),
        KeySpec(id: "logfile", label: "日志文件", placeholder: ""),
        KeySpec(id: "pidfile", label: "PID 文件", placeholder: ""),
        KeySpec(id: "protected-mode", label: "保护模式", placeholder: "yes",
                options: [.init(value: "yes", label: "开启"), .init(value: "no", label: "关闭")]),
        KeySpec(id: "save", label: "RDB 快照策略", placeholder: "3600 1 300 100 60 10000"),
    ]

    // MARK: my.cnf（INI：[section] 下 key = value）

    private struct IniLine {
        let index: Int
        let section: String?
        let key: String?
        let value: String?
    }

    private static func iniParse(_ text: String) -> [IniLine] {
        var result: [IniLine] = []
        var current: String?
        for (index, raw) in text.lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                result.append(IniLine(index: index, section: current, key: nil, value: nil))
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                result.append(IniLine(index: index, section: current, key: nil, value: nil))
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                result.append(IniLine(index: index, section: current, key: nil, value: nil))
                continue
            }
            let key = String(line[line.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if let hash = value.firstIndex(of: "#") {
                value = String(value[value.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
            }
            result.append(IniLine(index: index, section: current, key: key, value: value))
        }
        return result
    }

    static func iniGet(_ text: String, section: String, key: String) -> String {
        for line in iniParse(text) where line.section == section && line.key == key {
            return line.value ?? ""
        }
        return ""
    }

    static func iniSet(_ text: String, section: String, key: String, value: String) -> String {
        var lines = text.lines
        let parsed = iniParse(text)

        // 1) 同 section 同名 key：原地替换（保留行尾注释）
        for line in parsed where line.section == section && line.key == key {
            lines[line.index] = "\(key) = \(value)" + inlineComment(lines[line.index])
            return join(lines, like: text)
        }

        // 2) 有 [section]：插到它的末尾（下一个 [ 之前）
        var sectionHeader: Int?
        var sectionEnd = lines.count
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { continue }
            let name = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if name == section {
                sectionHeader = index
            } else if sectionHeader != nil {
                sectionEnd = index
                break
            }
        }
        if sectionHeader != nil {
            lines.insert("\(key) = \(value)", at: min(sectionEnd, lines.count))
            return join(lines, like: text)
        }

        // 3) 整个 section 都不存在：新建
        if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
        lines.append("[\(section)]")
        lines.append("\(key) = \(value)")
        return join(lines, like: text)
    }

    static let mysqlKeys: [KeySpec] = [
        KeySpec(id: "mysqld.port", label: "端口", placeholder: "3306"),
        KeySpec(id: "mysqld.bind-address", label: "监听地址", placeholder: "127.0.0.1"),
        KeySpec(id: "mysqld.datadir", label: "数据目录", placeholder: ""),
        KeySpec(id: "mysqld.socket", label: "socket 文件", placeholder: ""),
        KeySpec(id: "mysqld.log-error", label: "错误日志", placeholder: ""),
        KeySpec(id: "mysqld.max_connections", label: "最大连接数", placeholder: "151"),
        KeySpec(id: "mysqld.character-set-server", label: "服务端字符集", placeholder: "utf8mb4",
                options: [.init(value: "utf8mb4", label: "utf8mb4（推荐，支持 emoji）"),
                          .init(value: "utf8mb3", label: "utf8mb3"),
                          .init(value: "latin1", label: "latin1")]),
        KeySpec(id: "mysqld.collation-server", label: "排序规则", placeholder: "utf8mb4_unicode_ci",
                options: [.init(value: "utf8mb4_unicode_ci", label: "utf8mb4_unicode_ci"),
                          .init(value: "utf8mb4_general_ci", label: "utf8mb4_general_ci"),
                          .init(value: "utf8mb4_0900_ai_ci", label: "utf8mb4_0900_ai_ci（8.0 默认）")]),
        KeySpec(id: "mysqld.default-storage-engine", label: "默认存储引擎", placeholder: "InnoDB",
                options: [.init(value: "InnoDB", label: "InnoDB（推荐）"),
                          .init(value: "MyISAM", label: "MyISAM")]),
        KeySpec(id: "mysqld.innodb_buffer_pool_size", label: "InnoDB 缓冲池", placeholder: "128M"),
        KeySpec(id: "mysqld.skip-name-resolve", label: "跳过域名反解", placeholder: "ON",
                options: [.init(value: "OFF", label: "关闭"), .init(value: "ON", label: "开启（连接更快）")]),
    ]

    // MARK: 通用

    /// 取出行尾注释（形如 "  # 说明"），改写配置行时原样保留，避免悄悄丢掉用户的注释。
    private static func inlineComment(_ line: String) -> String {
        guard let range = line.range(of: " #", options: .backwards) else { return "" }
        let tail = String(line[range.lowerBound...])
        // 只把确定是注释的部分带回来：注释后不应再出现引号包裹的值
        return tail.hasPrefix(" #") ? tail : ""
    }

    /// 用原文件的换行风格拼接，避免把 CRLF 文件改成 LF。
    private static func join(_ lines: [String], like original: String) -> String {
        let separator = original.dominantNewline
        var text = lines.joined(separator: separator)
        // split 会保留末尾空元素，join 后即还原原本的结尾换行
        if !original.isEmpty && !original.hasSuffix("\n") && text.hasSuffix(separator) {
            text = String(text.dropLast(separator.count))
        }
        return text
    }
}
