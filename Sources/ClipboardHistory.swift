import Foundation

/// 一条剪贴板历史。
///
/// **只存文本**：图片、文件等非文本内容在采集那一层就被丢掉了（见 `ClipboardService`），
/// 所以固化文件里永远不会出现图片数据。
struct ClipboardEntry: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var createdAt: Date
    /// 超过单条上限被截断过，界面据此提示。
    var truncated: Bool

    init(id: String = UUID().uuidString, text: String, createdAt: Date = Date(),
         truncated: Bool = false) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.truncated = truncated
    }

    /// 宽松解码：缺哪个字段就用默认值，手改过或旧版本的记录也不至于让**整份**历史读不出来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    var bytes: Int { text.utf8.count }
}

/// 连 Redis 需要的三个值（值类型：可以安全地带到后台线程去用）。
struct ClipboardRedisTarget: Equatable {
    var host: String
    var port: Int
    var password: String
}

/// 剪贴板历史的规则与存取。全是静态方法，本身无状态 —— 自测与界面、后台队列共用同一套规则。
///
/// 三层各司其职：
/// - 内存：界面上的列表；
/// - Redis：**读得快**（整份历史放一个字符串 key，读一次就全拿到）；
/// - 本地 JSON 文件：关机重启后的兜底，**上限 2 MB**，超了从最旧的条目开始丢。
enum ClipboardHistory {

    /// 固化文件上限：2 MB。
    static let maxFileBytes = 2 * 1024 * 1024
    /// 最多保留多少条（内存 / Redis / 文件保持同一份）。
    static let maxEntries = 500
    /// 单条文本上限 256 KB：再长基本是大段日志，塞进来只会把整份历史挤没。
    static let maxTextBytes = 256 * 1024
    /// Redis 里存整份历史的 key。
    static let redisKey = "dbm:clipboard:history"

    // MARK: 编解码

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // 毫秒足够区分「同一秒里连着复制好几段」，又不至于像 ISO8601 那样丢精度。
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func encode(_ entries: [ClipboardEntry]) -> String {
        guard let data = try? makeEncoder().encode(entries),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// 兼容读：正常是整份 JSON 数组；文件被截断成「一行一条」时也尽量把能读的救回来。
    static func decode(_ text: String) -> [ClipboardEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let decoder = makeDecoder()
        if let entries = try? decoder.decode([ClipboardEntry].self, from: Data(trimmed.utf8)) {
            return entries
        }
        return trimmed.lines.compactMap { line in
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.hasPrefix("{") else { return nil }
            return try? decoder.decode(ClipboardEntry.self, from: Data(candidate.utf8))
        }
    }

    // MARK: 规则

    /// 按 UTF-8 字节截断，不会把中文 / emoji 切成半个字符。
    static func clampText(_ text: String, maxBytes: Int = maxTextBytes) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maxBytes else { return (text, false) }
        var kept = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            kept.append(character)
            used += size
        }
        return (kept, true)
    }

    /// 按字节预算裁剪：条目按「最新在前」排列，从最新的开始留，装不下的（更旧的）整条丢掉。
    static func fit(_ entries: [ClipboardEntry], maxBytes: Int = maxFileBytes) -> [ClipboardEntry] {
        var kept: [ClipboardEntry] = []
        var used = 2   // 最外层的 "[]"
        for entry in entries {
            let size = entryBytes(entry) + 1   // 加上分隔用的逗号
            if used + size > maxBytes { break }
            used += size
            kept.append(entry)
        }
        return kept
    }

    /// 多份历史合并：同一段文本只留时间最新的一条，再按时间倒序取前 `limit` 条。
    static func merge(_ lists: [[ClipboardEntry]], limit: Int = maxEntries) -> [ClipboardEntry] {
        var best: [String: ClipboardEntry] = [:]
        for list in lists {
            for entry in list {
                if let existing = best[entry.text], existing.createdAt >= entry.createdAt { continue }
                best[entry.text] = entry
            }
        }
        return best.values
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
            .prefix(limit)
            .map { $0 }
    }

    /// 记一条新内容：空白不记；内容重复时把旧的那条删掉，新的插到最前面。
    static func add(_ text: String, to entries: [ClipboardEntry], now: Date = Date()) -> [ClipboardEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let (clamped, truncated) = clampText(trimmed)
        var updated = entries.filter { $0.text != clamped }
        updated.insert(ClipboardEntry(text: clamped, createdAt: now, truncated: truncated), at: 0)
        return fit(Array(updated.prefix(maxEntries)))
    }

    static func remove(id: String, from entries: [ClipboardEntry]) -> [ClipboardEntry] {
        fit(entries.filter { $0.id != id })
    }

    private static func entryBytes(_ entry: ClipboardEntry) -> Int {
        (try? makeEncoder().encode(entry).count) ?? entry.text.utf8.count
    }

    // MARK: 本地文件

    static func readFile(_ path: String) -> [ClipboardEntry] {
        decode(FileTools.read(path))
    }

    /// 写本地固化文件（原子写）。返回 nil 表示成功，否则是错误描述。
    static func writeFile(_ path: String, entries: [ClipboardEntry]) -> String? {
        FileTools.write(path, encode(entries))
    }

    static func fileSize(_ path: String) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.intValue
    }

    // MARK: Redis

    /// 读整份历史。返回 nil 表示「读不到」（Redis 没起、握手失败…），
    /// 空数组表示 Redis 里确实还没有这份历史。
    static func readRedis(_ target: ClipboardRedisTarget) -> [ClipboardEntry]? {
        guard let client = connectRedis(target) else { return nil }
        defer { client.close() }
        guard let reply = try? client.command(["GET", redisKey]) else { return nil }
        return decode(reply.stringValue ?? "")
    }

    /// 把整份历史写回 Redis，返回一句给人看的说明。
    static func writeRedis(_ target: ClipboardRedisTarget, entries: [ClipboardEntry]) -> String {
        guard let client = connectRedis(target) else {
            return "Redis 没连上（\(target.host):\(target.port)）：只写了本地文件"
        }
        defer { client.close() }
        do {
            let reply = try client.command(["SET", redisKey, encode(entries)])
            return reply.stringValue?.uppercased() == "OK"
                ? "已同步到 Redis（\(redisKey)）"
                : "Redis 回包异常：\(reply.display)"
        } catch {
            return "Redis 写入失败：\(error.localizedDescription)"
        }
    }

    private static func connectRedis(_ target: ClipboardRedisTarget) -> RedisClient? {
        let client = RedisClient(host: target.host, port: target.port, password: target.password,
                                 timeout: 2)
        do {
            try client.connect()
            return client
        } catch {
            return nil
        }
    }

    // MARK: 载入

    /// 载入历史：本地文件打底，Redis（通常更新、也更快）合并进来。
    /// 返回合并后的列表与一句来源说明，交给界面显示。
    static func load(filePath: String, redis: ClipboardRedisTarget?) -> (entries: [ClipboardEntry], note: String) {
        let local = readFile(filePath)
        guard let redis else {
            return (local, "本地文件 \(local.count) 条（未配置 Redis）")
        }
        guard let remote = readRedis(redis) else {
            return (local, "本地文件 \(local.count) 条（Redis 读不到，已跳过）")
        }
        let merged = merge([local, remote])
        return (merged, "本地文件 \(local.count) 条 + Redis \(remote.count) 条 → \(merged.count) 条")
    }
}
