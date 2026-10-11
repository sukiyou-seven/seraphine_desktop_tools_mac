import Foundation

// MARK: - 设置

/// 「AI 开发」页面的设置，落在 settings.json 的 `ai` 字段里。
struct AIDevSettings: Codable {
    /// 任务的工作目录。既是 codex 的 cwd，也是 resume 定位会话的依据（resume 按目录过滤）。
    var workDir = ""
    /// 首次下发的任务描述。
    var prompt = ""
    /// 模型 slug；空 = 跟随 Codex 自己的配置（~/.codex/config.toml 的 model）。
    var model = ""
    /// 推理强度；空 = 跟随该模型的默认档。
    var effort = ""
    /// 沙箱策略，见 AISandbox。
    var sandbox = AISandbox.workspaceWrite.rawValue
    /// 是否给 codex 注入本机代理。
    var useProxy = true
    /// 手动代理地址（`host:port` 或完整 URL）；空 = 用 scutil 探测到的系统代理。
    var proxyOverride = ""
    /// 一轮正常结束（exit 0）后是否自动 resume 继续。
    var autoContinue = false
    /// 自动续跑前的等待秒数。
    var continueDelay = 30
    /// 允许在非 Git 目录里跑（加 --skip-git-repo-check）。
    var allowNonGit = true
    /// 用 `--json` 事件流拿结构化进度（命令数、改动文件、todo 完成度），
    /// 看门狗据此识别「一直在空转」并收工。关掉就退回纯文本输出。
    var jsonEvents = true
    /// 验收命令（一行一条，`#` 开头忽略）。
    ///
    /// **这是「开发完成」唯一的客观判据**：全部退出码为 0 才算完成；
    /// 留空则退回「模型声明完成 + 连续无动作」的启发式，可靠性明显下降。
    var acceptanceCommands = ""
    /// 单条验收命令的超时（秒）。跑测试可能很久。
    var acceptanceTimeout = 900
    /// 最多跑几轮；0 = 不限。
    var maxRounds = 0

    init() {}

    /// 宽松解码：缺哪个字段就用默认值（同上，避免旧设置文件让整份设置解不出来）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workDir = try container.decodeIfPresent(String.self, forKey: .workDir) ?? workDir
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? prompt
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? model
        effort = try container.decodeIfPresent(String.self, forKey: .effort) ?? effort
        sandbox = try container.decodeIfPresent(String.self, forKey: .sandbox) ?? sandbox
        useProxy = try container.decodeIfPresent(Bool.self, forKey: .useProxy) ?? useProxy
        proxyOverride = try container.decodeIfPresent(String.self, forKey: .proxyOverride) ?? proxyOverride
        autoContinue = try container.decodeIfPresent(Bool.self, forKey: .autoContinue) ?? autoContinue
        continueDelay = try container.decodeIfPresent(Int.self, forKey: .continueDelay) ?? continueDelay
        allowNonGit = try container.decodeIfPresent(Bool.self, forKey: .allowNonGit) ?? allowNonGit
        jsonEvents = try container.decodeIfPresent(Bool.self, forKey: .jsonEvents) ?? jsonEvents
        acceptanceCommands = try container.decodeIfPresent(String.self, forKey: .acceptanceCommands) ?? acceptanceCommands
        acceptanceTimeout = try container.decodeIfPresent(Int.self, forKey: .acceptanceTimeout) ?? acceptanceTimeout
        maxRounds = try container.decodeIfPresent(Int.self, forKey: .maxRounds) ?? maxRounds
    }
}

extension AIDevSettings {
    /// 用户是否真的填了任务目录（没填就不让开始，免得 codex 在 HOME 里乱改）。
    var hasWorkDir: Bool {
        !workDir.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 规范化后的任务目录：展开 `~`、消掉 `..`。没填时回落到 HOME（只作为兜底）。
    var resolvedWorkDir: String {
        let raw = workDir.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return NSHomeDirectory() }
        return (raw as NSString).standardizingPath
    }
}

// MARK: - 沙箱策略
/// 无人值守时给 `codex exec` 的权限档位。
///
/// 注意：豆包那份脚本用的 `--full-auto` 在 codex 0.157 已经**不存在**了
/// （实测报 `unexpected argument '--full-auto'`），所以这里换成当前版本的等价参数。
enum AISandbox: String, CaseIterable {
    /// 只在工作目录内读写；越界命令交给自动审批（`--approve-for-me`）判定，不会停下来等人。
    case workspaceWrite = "workspace-write"
    /// 完全放开：任意路径读写、任意命令。真正无人值守，但风险最高。
    case bypass = "bypass"
    /// 只读：模型只分析、给建议，不改任何文件。
    case readOnly = "read-only"

    static func from(_ raw: String) -> AISandbox {
        AISandbox(rawValue: raw) ?? .workspaceWrite
    }

    var label: String {
        switch self {
        case .workspaceWrite: return "工作目录内 + 自动审批"
        case .bypass: return "完全放开（危险）"
        case .readOnly: return "只读"
        }
    }

    var detail: String {
        switch self {
        case .workspaceWrite:
            return "-s workspace-write --approve-for-me：只能在任务目录里读写，越界命令由自动审批决定（拒绝而不是卡住等人工确认）。"
        case .bypass:
            return "--dangerously-bypass-approvals-and-sandbox：任意路径读写、任意命令，无人值守最省心，但等于把机器交给模型，风险最高。"
        case .readOnly:
            return "-s read-only：模型只读代码、给方案，不会改任何文件。"
        }
    }
}

// MARK: - 模型目录

struct AIEffortOption: Equatable {
    var effort: String
    var detail: String

    var label: String { effort }
}

struct AIModelOption: Equatable {
    var slug: String
    var displayName: String
    var defaultEffort: String
    var efforts: [AIEffortOption]

    var label: String { displayName.isEmpty ? slug : "\(displayName)  (\(slug))" }

    /// 该模型默认的推理档位（读不到就用列表第一项）。
    var resolvedDefaultEffort: String {
        if !defaultEffort.isEmpty { return defaultEffort }
        return efforts.first?.effort ?? ""
    }
}

/// 模型列表来源：优先 `codex debug models`（官方输出），其次 `~/.codex/models_cache.json`，
/// 最后回退到内置的一份。不硬编码，账号升级模型后界面自动跟上。
enum AIModelCatalog {
    /// 这个 slug 表示「跟随 Codex 自己的配置」。
    static let followConfigSlug = ""

    static func parse(_ json: String) -> [AIModelOption] {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = root["models"] as? [[String: Any]] else { return [] }
        var models: [AIModelOption] = []
        for item in raw {
            guard let slug = (item["slug"] as? String)?.trimmingCharacters(in: .whitespaces), !slug.isEmpty else { continue }
            // visibility=hide 的是内部模型（如 codex-auto-review），不摆给用户选
            if let visibility = item["visibility"] as? String, visibility.lowercased() == "hide" { continue }
            let efforts = (item["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { level -> AIEffortOption? in
                guard let effort = (level["effort"] as? String)?.trimmingCharacters(in: .whitespaces), !effort.isEmpty else { return nil }
                return AIEffortOption(effort: effort, detail: (level["description"] as? String) ?? "")
            }
            models.append(AIModelOption(slug: slug,
                                        displayName: (item["display_name"] as? String) ?? "",
                                        defaultEffort: (item["default_reasoning_level"] as? String) ?? "",
                                        efforts: efforts))
        }
        return models
    }

    /// 从 config.toml 文本里取顶层 `model = "xxx"`（只看第一个 section 之前的内容，
    /// 否则会把 `[mcp_servers.xxx]` 段里的 model 当成主模型）。
    static func configuredModel(configText: String) -> String {
        for rawLine in configText.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            if line.hasPrefix("#") { continue }
            guard line.hasPrefix("model"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "model" else { continue }
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return cleaned
        }
        return ""
    }

    /// config.toml 里配的推理强度（展示用）。
    static func configuredEffort(configText: String) -> String {
        for rawLine in configText.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            if line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "model_reasoning_effort" else { continue }
            return line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return ""
    }

    static func fallback() -> [AIModelOption] {
        let efforts = [
            AIEffortOption(effort: "low", detail: "轻推理，响应快"),
            AIEffortOption(effort: "medium", detail: "速度与深度平衡"),
            AIEffortOption(effort: "high", detail: "更深的推理"),
            AIEffortOption(effort: "xhigh", detail: "更高的推理深度"),
            AIEffortOption(effort: "max", detail: "最难的活儿用"),
            AIEffortOption(effort: "ultra", detail: "最高推理 + 自动委派子任务"),
        ]
        return [
            AIModelOption(slug: "gpt-6-astra", displayName: "GPT-6-Astra", defaultEffort: "low", efforts: efforts),
            AIModelOption(slug: "gpt-6-sol", displayName: "GPT-6-Sol", defaultEffort: "medium", efforts: efforts),
            AIModelOption(slug: "gpt-6-luna", displayName: "GPT-6-Luna", defaultEffort: "medium", efforts: efforts),
            AIModelOption(slug: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", defaultEffort: "low", efforts: efforts),
            AIModelOption(slug: "gpt-5.6-terra", displayName: "GPT-5.6-Terra", defaultEffort: "medium", efforts: efforts),
            AIModelOption(slug: "gpt-5.6-luna", displayName: "GPT-5.6-Luna", defaultEffort: "medium", efforts: efforts),
            AIModelOption(slug: "gpt-5.5", displayName: "GPT-5.5", defaultEffort: "medium", efforts: efforts),
        ]
    }

    /// 拿模型列表：`codex debug models` → 本地缓存文件 → 内置默认。
    static func load(codexPath: String?, cacheFile: String? = nil) -> (models: [AIModelOption], source: String) {
        let cache = cacheFile ?? (NSHomeDirectory() + "/.codex/models_cache.json")
        if let codexPath {
            let result = Shell.run([codexPath, "debug", "models"], timeout: 90)
            if result.ok {
                let models = parse(result.stdout)
                if !models.isEmpty { return (models, "codex debug models") }
            }
        }
        if let text = try? String(contentsOfFile: cache, encoding: .utf8) {
            let models = parse(text)
            if !models.isEmpty { return (models, "models_cache.json") }
        }
        return (fallback(), "内置默认列表")
    }
}

// MARK: - 本机代理

struct AIProxyEndpoint: Equatable {
    var enabled = false
    var host = ""
    var port = 0

    /// 形如 `http://127.0.0.1:10808`；没开或没填全返回 nil。
    var url: String? {
        guard enabled, !host.isEmpty, port > 0 else { return nil }
        return "http://\(host):\(port)"
    }

    var display: String {
        guard enabled, !host.isEmpty, port > 0 else { return "未开启" }
        return "\(host):\(port)"
    }
}

/// 从 `scutil --proxy` 读出来的本机代理（macOS 系统设置里的那份）。
struct AIProxyConfig: Equatable {
    var http = AIProxyEndpoint()
    var https = AIProxyEndpoint()
    var socks = AIProxyEndpoint()
    var exceptions: [String] = []

    var isEmpty: Bool { http.url == nil && https.url == nil && socks.url == nil }

    /// 一行摘要，给界面显示用。
    var summary: String {
        var parts: [String] = []
        if http.url != nil { parts.append("HTTP \(http.display)") }
        if https.url != nil { parts.append("HTTPS \(https.display)") }
        if socks.url != nil { parts.append("SOCKS \(socks.display)") }
        return parts.isEmpty ? "本机没检测到代理" : parts.joined(separator: " · ")
    }

    /// 解析 scutil --proxy 的输出。
    ///
    /// 输出长这样（注意键值之间是 " : "，IPv6 地址里的冒号不能当分隔符）：
    /// ```
    /// <dictionary> {
    ///   HTTPEnable : 1
    ///   HTTPPort : 10808
    ///   HTTPProxy : 127.0.0.1
    ///   ExceptionsList : <array> {
    ///     0 : localhost
    ///   }
    /// }
    /// ```
    static func parse(scutilOutput: String) -> AIProxyConfig {
        var config = AIProxyConfig()
        var values: [String: String] = [:]
        for rawLine in scutilOutput.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("<"), line != "}" else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            if Int(key) != nil {                      // ExceptionsList 里的 `0 : localhost`
                if !value.isEmpty { config.exceptions.append(value) }
                continue
            }
            values[key] = value
        }

        func enabled(_ key: String) -> Bool { values[key] == "1" }
        func endpoint(_ enableKey: String, _ hostKey: String, _ portKey: String) -> AIProxyEndpoint {
            AIProxyEndpoint(enabled: enabled(enableKey),
                            host: values[hostKey] ?? "",
                            port: Int(values[portKey] ?? "") ?? 0)
        }
        config.http = endpoint("HTTPEnable", "HTTPProxy", "HTTPPort")
        config.https = endpoint("HTTPSEnable", "HTTPSProxy", "HTTPSPort")
        config.socks = endpoint("SOCKSEnable", "SOCKSProxy", "SOCKSPort")
        return config
    }

    static func detect() -> AIProxyConfig {
        let result = Shell.run(["/usr/sbin/scutil", "--proxy"], timeout: 10)
        guard result.ok else { return AIProxyConfig() }
        return parse(scutilOutput: result.stdout)
    }

    /// 手动填的地址归一化：`127.0.0.1:10809` → `http://127.0.0.1:10809`；带 scheme 的原样返回。
    static func normalize(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.contains("://") { return text }
        guard text.contains(":") else { return nil }
        return "http://" + text
    }

    /// 注入给 codex 子进程的代理环境变量。
    ///
    /// 手动填了 `override` 就以它为准（HTTP/HTTPS/ALL_PROXY 都指过去）；
    /// 否则用探测到的系统代理。大小写各写一份 —— 不同 HTTP 客户端认的变量名不一样。
    func environment(override: String) -> [String: String] {
        var env: [String: String] = [:]
        var httpURL: String?
        var httpsURL: String?

        if let manual = AIProxyConfig.normalize(override) {
            // 手动覆盖：HTTP / HTTPS / ALL_PROXY 全指过去
            httpURL = manual
            httpsURL = manual
            env["ALL_PROXY"] = manual
            env["all_proxy"] = manual
        } else {
            httpURL = http.url
            httpsURL = https.url ?? http.url
            if let socksURL = socks.url {
                let hostPort = socksURL.replacingOccurrences(of: "http://", with: "")
                let all = "socks5://" + hostPort
                env["ALL_PROXY"] = all
                env["all_proxy"] = all
            }
        }
        if let httpURL {
            env["HTTP_PROXY"] = httpURL
            env["http_proxy"] = httpURL
        }
        if let httpsURL {
            env["HTTPS_PROXY"] = httpsURL
            env["https_proxy"] = httpsURL
        }

        // 例外列表去重：系统例外里往往已经有 localhost，没必要再写一遍
        var seen = Set<String>()
        let noProxy = (exceptions + ["localhost", "127.0.0.1", "::1"]).filter { seen.insert($0).inserted }
        env["NO_PROXY"] = noProxy.joined(separator: ",")
        env["no_proxy"] = env["NO_PROXY"]
        return env
    }
}

// MARK: - 限额 / 重试判据

/// 5 小时用量窗口相关的判断与等待时间计算（全是纯函数，方便自测）。
enum AIUsageLimit {
    /// 出现这些词就别再重试了：不是限额，是登录/配置问题，机器上等不出来。
    static let fatalKeywords = [
        "not logged in", "not authenticated", "unauthorized", "authentication failed",
        "invalid api key", "missing api key", "please run codex login", "codex login",
        // 目录不是 Git 仓库时 codex 会直接拒绝，重试多少次都一样（页面里有开关可放行）
        "not inside a git repository", "not a git repository", "skip-git-repo-check",
    ]

    /// 「没有可续跑的会话」—— 多半是误点了「续跑最近会话」。
    /// 这种情况盲目退避重试只会白等，应该立刻告诉用户改用「开始执行任务」。
    static let noSessionKeywords = [
        "no sessions found", "no session found", "session not found", "no rollout",
        "nothing to resume", "no recorded session", "no conversations found",
        "could not find session",
    ]

    static func looksLikeNoSession(_ text: String) -> Bool {
        let lower = text.lowercased()
        return noSessionKeywords.contains { lower.contains($0) }
    }

    /// 出现这些词说明是限额/限流，值得等下一轮。
    static let limitKeywords = [
        "usage limit", "rate limit", "rate_limit", "429", "too many requests",
        "quota", "hit your limit", "hit the limit", "limit reached", "usage_limit",
    ]

    static func looksLikeLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        return limitKeywords.contains { lower.contains($0) }
    }

    /// 只在这三种情况停下：明确的登录/鉴权错误，或者「输出里既没有限额迹象、退出码也不是超时/被杀」。
    /// 后者交给调用方判断，这里只判断登录类错误。
    static func looksFatal(_ text: String) -> Bool {
        let lower = text.lowercased()
        // 限额提示里也常出现 "login"/"account"，所以先排除限额，避免把限额误判成致命错误。
        if looksLikeLimit(lower) { return false }
        return fatalKeywords.contains { lower.contains($0) }
    }

    /// 从输出里找「什么时候恢复」并解析成时间点。
    /// codex 的文案是 `You've hit your usage limit ... resets at 9:30 PM` 一类，
    /// 具体格式各版本不一，所以这里按「短语 + 候选格式」逐个尝试。
    static func parseResetDate(in text: String, now: Date = Date(),
                               calendar: Calendar = .current) -> Date? {
        for fragment in resetFragments(in: text) {
            if let date = parse(fragment: fragment, now: now, calendar: calendar) { return date }
        }
        return nil
    }

    /// 抓出 `resets at …` / `try again at …` 后面那段。
    static func resetFragments(in text: String) -> [String] {
        let pattern = "(?i)(?:resets? at|reset at|try again at|try again after|available at|available again at|retry at|resumes? at)\\s*([^\\n]{2,80})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespaces)
        }
    }

    /// 从一段片段里尽力解析出时间点。片段可能是：
    /// `2026-09-26T21:30:00Z`、`2026-09-26 21:30`、`Sep 26, 9:30 PM`、`9:30 PM`、`1758910200`…
    static func parse(fragment: String, now: Date, calendar: Calendar) -> Date? {
        let text = fragment.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        // 1) 先试带/不带时区的完整格式
        for formatter in absoluteFormatters(now: now, calendar: calendar) {
            if let date = formatter.date(from: text) { return date }
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }

        // 2) 从片段里抽日期与时间再组合
        let datePart = firstMatch(in: text, pattern: "\\d{4}-\\d{1,2}-\\d{1,2}")
        let monthPart = firstMatch(in: text, pattern: "(?i)\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?\\s+\\d{1,2}(?:,?\\s*\\d{4})?\\b")
        let timePart = firstMatch(in: text, pattern: "(?i)\\d{1,2}:\\d{2}(?::\\d{2})?\\s*(?:a\\.?m\\.?|p\\.?m\\.?)?")
        let epoch = firstMatch(in: text, pattern: "\\b\\d{10}\\b")

        if let epoch, let seconds = TimeInterval(epoch) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let datePart {
            let withTime = timePart.map { datePart + " " + $0 } ?? datePart
            for formatter in dayFormatters(now: now, calendar: calendar) {
                if let date = formatter.date(from: withTime) { return date }
            }
        }
        if let monthPart {
            let withTime = timePart.map { monthPart + " " + $0 } ?? monthPart
            for formatter in monthFormatters(now: now, calendar: calendar) {
                if let date = formatter.date(from: withTime) { return date }
            }
        }
        // 3) 只有时间：按「今天还没到就是今天，已经过了就是明天」处理
        if let timePart, let clock = clockComponents(timePart) {
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = clock.hour
            components.minute = clock.minute
            components.second = clock.second
            components.timeZone = calendar.timeZone
            guard let today = calendar.date(from: components) else { return nil }
            // 只差几分钟（说明就是刚刚那个时刻）也算今天
            if today.timeIntervalSince(now) >= -300 { return today }
            return calendar.date(byAdding: .day, value: 1, to: today)
        }
        return nil
    }

    static func clockComponents(_ text: String) -> (hour: Int, minute: Int, second: Int)? {
        let parts = text.trimmingCharacters(in: .whitespaces)
        let lower = parts.lowercased()
        guard let match = firstMatch(in: lower, pattern: "^\\d{1,2}:\\d{2}(?::\\d{2})?") else { return nil }
        let numbers = match.split(separator: ":").compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        var hour = numbers[0]
        let minute = numbers[1]
        let second = numbers.count > 2 ? numbers[2] : 0
        let isPM = lower.contains("p.m") || lower.contains("pm")
        let isAM = lower.contains("a.m") || lower.contains("am")
        if isPM, hour < 12 { hour += 12 }
        if isAM, hour == 12 { hour = 0 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute, second)
    }

    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text) else { return nil }
        return String(text[r])
    }

    /// 解析器工厂。
    ///
    /// `defaultDate` 很关键：像 `Sep 26, 9:30 PM` 这种没有年份的文案，
    /// DateFormatter 会拿它补缺失字段 —— 默认是 **2000-01-01**，
    /// 于是「几点恢复」会被算成 2000 年。必须显式补上当前时间。
    private static func formatter(_ format: String, defaultDate: Date? = nil,
                                  timeZone: TimeZone? = nil) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if let timeZone { formatter.timeZone = timeZone }
        if let defaultDate { formatter.defaultDate = defaultDate }
        return formatter
    }

    /// 带日期（ISO / 年-月-日）的格式，先按本地时区解，解不出来再按 UTC。
    private static func absoluteFormatters(now: Date, calendar: Calendar) -> [DateFormatter] {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        ]
        var formatters = formats.map { formatter($0, defaultDate: now, timeZone: calendar.timeZone) }
        for format in formats {
            let utc = formatter(format, defaultDate: now)
            utc.timeZone = TimeZone(identifier: "UTC")
            formatters.append(utc)
        }
        return formatters
    }

    private static func dayFormatters(now: Date, calendar: Calendar) -> [DateFormatter] {
        ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"].map {
            formatter($0, defaultDate: now, timeZone: calendar.timeZone)
        }
    }

    private static func monthFormatters(now: Date, calendar: Calendar) -> [DateFormatter] {
        ["MMM d, yyyy h:mm a", "MMM d yyyy h:mm a", "MMM d, h:mm a", "MMM d h:mm a",
         "MMM d, yyyy", "MMM d yyyy", "MMM d", "MMMM d, h:mm a", "MMMM d h:mm a"].map {
            formatter($0, defaultDate: now, timeZone: calendar.timeZone)
        }
    }

    /// 指数退避：300s 起，每失败一次翻倍，封顶 1 小时（滚动窗口会自己恢复，不必盲等太久）。
    static func backoffWait(attempt: Int, initial: Int = 300, maxWait: Int = 3600) -> TimeInterval {
        guard attempt > 0 else { return TimeInterval(initial) }
        var wait = initial
        for _ in 1..<attempt {
            if wait >= maxWait { break }
            wait *= 2
        }
        return TimeInterval(min(wait, maxWait))
    }

    /// 最终等待秒数：解析到重置时间就等到那之后（+60s 缓冲），否则用指数退避。
    /// 下限 60s（避免限额提示刚出现就又去撞），上限走 maxWait。
    static func waitSeconds(resetAt: Date?, now: Date = Date(), attempt: Int,
                            initial: Int = 300, maxWait: Int = 3600,
                            buffer: TimeInterval = 60) -> TimeInterval {
        if let resetAt {
            let seconds = resetAt.addingTimeInterval(buffer).timeIntervalSince(now)
            if seconds > 0 { return min(max(seconds, 60), TimeInterval(maxWait)) }
        }
        return backoffWait(attempt: attempt, initial: initial, maxWait: maxWait)
    }
}

// MARK: - codex 事件流（`codex exec --json`）

/// 顶层事件类型。
///
/// 名字不是猜的：codex 0.157 的二进制里就带着 `ThreadEvent` 的定义
/// （`ThreadStarted/TurnStarted/TurnCompleted/TurnFailed/ItemStarted/ItemUpdated/ItemCompleted`
/// 对应 `thread.started`/`turn.started`/`turn.completed`/`turn.failed`/`item.started`/`item.updated`/`item.completed`），
/// `item.type` 的取值是 `agent_message`/`reasoning`/`command_execution`/`file_change`/
/// `mcp_tool_call`/`web_search`/`todo_list`，命令项字段为 `command`/`aggregated_output`/`exit_code`。
enum CodexEventKind: String {
    case threadStarted = "thread.started"
    case turnStarted = "turn.started"
    case turnCompleted = "turn.completed"
    case turnFailed = "turn.failed"
    case itemStarted = "item.started"
    case itemUpdated = "item.updated"
    case itemCompleted = "item.completed"
    case unknown = ""

    var isItemEvent: Bool { self == .itemStarted || self == .itemUpdated || self == .itemCompleted }
}

/// `todo_list` 里的一条待办。
struct CodexTodoItem: Equatable {
    var text: String
    var completed: Bool
}

/// 一条事件里我们关心的字段（其余一律忽略）。
struct CodexEvent: Equatable {
    var kind: CodexEventKind = .unknown
    var threadID = ""
    /// item 的类别，见 `CodexEventKind` 注释
    var itemType = ""
    var text = ""
    var command = ""
    var output = ""
    var exitCode: Int?
    var changedFiles: [String] = []
    var todos: [CodexTodoItem] = []
    var inputTokens = 0
    var outputTokens = 0
    var errorMessage = ""
}

/// JSONL 解析 + 渲染成人能看的日志行。**全部是纯函数**，所以可以直接拿真实事件样本自测。
///
/// 解析一律「宽松优先」：字段缺、类型不对、不是 JSON —— 统统返回 nil 或空值，
/// 绝不因为 codex 换了字段名就把看门狗搞崩（event 流只是加分项，不是命脉）。
enum CodexEventParser {
    /// 把 stdout 的一行解析成事件；不是合法事件就返回 nil。
    static func parse(_ line: String) -> CodexEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawType = root["type"] as? String else { return nil }

        var event = CodexEvent()
        event.kind = CodexEventKind(rawValue: rawType) ?? .unknown
        event.threadID = (root["thread_id"] as? String) ?? (root["threadId"] as? String) ?? ""

        if let item = root["item"] as? [String: Any] {
            event.itemType = (item["type"] as? String) ?? ""
            event.text = firstString(item, ["text", "content", "message", "query"])
            event.command = firstString(item, ["command", "parsed_cmd", "script_path"])
            event.output = firstString(item, ["aggregated_output", "stdout", "output"])
            event.exitCode = intValue(item["exit_code"])
            event.changedFiles = changedFiles(in: item)
            event.todos = todos(in: item)
            if event.errorMessage.isEmpty {
                event.errorMessage = firstString(item, ["error", "error_message"])
            }
        }

        let usage = (root["usage"] as? [String: Any]) ?? (root["info"] as? [String: Any]) ?? [:]
        event.inputTokens = intValue(usage["input_tokens"]) ?? 0
        event.outputTokens = intValue(usage["output_tokens"]) ?? 0

        if let error = root["error"] as? [String: Any] {
            event.errorMessage = firstString(error, ["message", "error", "detail"])
        } else if let error = root["error"] as? String {
            event.errorMessage = error
        }
        if event.errorMessage.isEmpty {
            event.errorMessage = firstString(root, ["message", "error_message"])
        }
        return event
    }

    /// 把事件渲染成日志里的一行；返回 nil 表示这条不值得写（比如流式的中间态）。
    static func humanLine(_ event: CodexEvent) -> String? {
        switch event.kind {
        case .threadStarted:
            guard !event.threadID.isEmpty else { return nil }
            return "▶ 会话 \(String(event.threadID.prefix(8)))"
        case .turnStarted:
            return "▶ 本轮开始"
        case .turnCompleted:
            var text = "✔ 本轮结束"
            if event.inputTokens > 0 || event.outputTokens > 0 {
                text += "（tokens：输入 \(event.inputTokens) / 输出 \(event.outputTokens)）"
            }
            return text
        case .turnFailed:
            return "✘ 本轮失败：" + (event.errorMessage.isEmpty ? "（codex 没给错误信息）" : event.errorMessage)
        case .itemStarted, .itemCompleted:
            let finished = event.kind == .itemCompleted
            let type = event.itemType.lowercased()
            if type.contains("command") {
                if !finished { return "$ " + (event.command.isEmpty ? "（执行命令）" : event.command) }
                var line = "↳ 退出码 \(event.exitCode.map(String.init) ?? "?")"
                let tail = outputTail(event.output)
                if !tail.isEmpty { line += "\n" + tail }
                return line
            }
            if type.contains("file_change") || type.contains("filechange") {
                guard finished, !event.changedFiles.isEmpty else { return nil }
                return "✎ 改动文件：" + event.changedFiles.joined(separator: "、")
            }
            if type.contains("agent_message") || type.contains("agentmessage") {
                guard finished, !event.text.isEmpty else { return nil }
                return event.text
            }
            if type.contains("reasoning") {
                guard finished, !event.text.isEmpty else { return nil }
                return "（思考）" + truncate(event.text, limit: 200)
            }
            if type.contains("todo") || type.contains("plan") {
                guard finished, !event.todos.isEmpty else { return nil }
                let done = event.todos.filter(\.completed).count
                var line = "☐ 计划 \(done)/\(event.todos.count) 完成"
                let pending = event.todos.filter { !$0.completed }.prefix(5).map { "   · " + truncate($0.text, limit: 80) }
                if !pending.isEmpty { line += "\n" + pending.joined(separator: "\n") }
                return line
            }
            if type.contains("web_search") || type.contains("websearch") {
                guard finished else { return nil }
                let query = firstNonEmpty([event.text, event.command])
                return "🔍 搜索：" + truncate(query, limit: 120)
            }
            if type.contains("mcp") {
                guard finished else { return nil }
                return "⚙ 工具调用：" + truncate(firstNonEmpty([event.text, event.itemType]), limit: 120)
            }
            if type.contains("error") {
                return "✘ " + truncate(firstNonEmpty([event.errorMessage, event.text]), limit: 200)
            }
            return nil
        case .itemUpdated, .unknown:
            // item.updated 是流式中间态：量大、会刷屏，只累计不写日志
            return nil
        }
    }

    // MARK: 取值助手

    private static func firstString(_ dict: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    private static func firstNonEmpty(_ values: [String]) -> String {
        values.first { !$0.isEmpty } ?? ""
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// `changes` 里每一项都可能是 `{"path": …}` 或 `{"kind": "add", "path": …}`，取路径即可。
    private static func changedFiles(in item: [String: Any]) -> [String] {
        guard let changes = item["changes"] as? [[String: Any]] else {
            if let path = item["path"] as? String, !path.isEmpty { return [path] }
            return []
        }
        return changes.compactMap { entry in
            let path = firstString(entry, ["path", "file", "file_path"])
            return path.isEmpty ? nil : path
        }
    }

    private static func todos(in item: [String: Any]) -> [CodexTodoItem] {
        guard let entries = item["items"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            let text = firstString(entry, ["text", "content", "title", "step"])
            guard !text.isEmpty else { return nil }
            let status = firstString(entry, ["status", "state"]).lowercased()
            let completed = (entry["completed"] as? Bool) ?? (status == "completed" || status == "done")
            return CodexTodoItem(text: text, completed: completed)
        }
    }

    private static func outputTail(_ output: String, limit: Int = 400) -> String {
        let lines = output.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return "" }
        let text = lines.suffix(6).joined(separator: "\n")
        return truncate(text, limit: limit)
    }

    static func truncate(_ text: String, limit: Int) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}

/// 一轮 codex 的汇总：从事件流里攒出来的「它到底干了什么」。
struct CodexRoundSummary: Equatable {
    var commands = 0
    var changedFiles: [String] = []
    var todos: [CodexTodoItem] = []
    var lastMessage = ""
    var turnCompleted = false
    var turnFailed = false
    var errorMessage = ""
    var inputTokens = 0
    var outputTokens = 0
    var eventCount = 0

    /// 这一轮有没有**实质动作**（跑过命令或改过文件）。
    /// 只有 agent_message 的轮次基本等于「它没活可干了」，是判断空转/收工的依据。
    var hasSubstantiveAction: Bool { commands > 0 || !changedFiles.isEmpty }

    var completedTodoCount: Int { todos.filter(\.completed).count }

    var todoText: String {
        todos.isEmpty ? "" : "\(completedTodoCount)/\(todos.count)"
    }

    mutating func absorb(_ event: CodexEvent) {
        guard event.kind != .unknown else { return }
        eventCount += 1
        switch event.kind {
        case .turnCompleted:
            turnCompleted = true
            inputTokens = event.inputTokens
            outputTokens = event.outputTokens
        case .turnFailed:
            turnFailed = true
            errorMessage = event.errorMessage
        case .itemCompleted:
            let type = event.itemType.lowercased()
            if type.contains("command") {
                commands += 1
            } else if type.contains("file_change") || type.contains("filechange") {
                for path in event.changedFiles where !changedFiles.contains(path) {
                    changedFiles.append(path)
                }
            } else if type.contains("agent_message") || type.contains("agentmessage") {
                if !event.text.isEmpty { lastMessage = event.text }
            } else if type.contains("todo") || type.contains("plan") {
                if !event.todos.isEmpty { todos = event.todos }
            }
            if !event.errorMessage.isEmpty, errorMessage.isEmpty { errorMessage = event.errorMessage }
        default:
            break
        }
    }

    static func merged(from events: [CodexEvent]) -> CodexRoundSummary {
        var summary = CodexRoundSummary()
        for event in events { summary.absorb(event) }
        return summary
    }
}

// MARK: - codex 命令构造

enum AICodexCommand {
    /// 每轮 resume 时下发的「接着干」指令（沿用豆包那份的措辞，实测够用）。
    static let resumeHint = "继续之前的工作：先检查当前代码/文件/git 状态，找出上次中断的位置，然后接着完成整个任务，不要重复已完成的部分。"

    /// 首轮：在当前目录新建会话。
    static func firstArguments(settings: AIDevSettings, prompt: String) -> [String] {
        var args = ["exec"]
        args += commonArguments(settings: settings, sandboxFlags: sandboxFlags(settings.sandbox, resuming: false))
        args += ["-C", workDirectory(settings)]
        args.append(prompt)
        return args
    }

    /// 之后每轮：resume 最近的会话（resume 按 cwd 过滤，所以进程必须跑在任务目录里）。
    /// `prompt` 为空时用默认的「接着干」指令；修复队列模式下由调用方逐条给出指令。
    static func resumeArguments(settings: AIDevSettings, prompt: String? = nil) -> [String] {
        var args = ["exec", "resume", "--last"]
        args += commonArguments(settings: settings, sandboxFlags: sandboxFlags(settings.sandbox, resuming: true))
        args.append(prompt ?? resumeHint)
        return args
    }

    static func workDirectory(_ settings: AIDevSettings) -> String {
        settings.resolvedWorkDir
    }

    /// 两轮共用的部分：模型、推理强度、事件流、非 Git 目录放行。
    static func commonArguments(settings: AIDevSettings, sandboxFlags: [String]) -> [String] {
        var args: [String] = []
        if !settings.model.isEmpty { args += ["-m", settings.model] }
        if !settings.effort.isEmpty { args += ["-c", "model_reasoning_effort=\"\(settings.effort)\""] }
        args += sandboxFlags
        // --json：stdout 变成 JSONL 事件流，看门狗据此统计「跑了什么命令 / 改了什么文件 / todo 完成度」
        if settings.jsonEvents { args.append("--json") }
        if settings.allowNonGit { args.append("--skip-git-repo-check") }
        return args
    }

    /// 沙箱参数。
    ///
    /// `codex exec resume` **不支持 `-s` / `--approve-for-me`**（只有 `--dangerously-bypass-...`），
    /// 所以 resume 轮用 `-c sandbox_mode=...` 覆盖；会话本身也记着首轮的沙箱设置，
    /// 万一这个 key 不被识别，行为仍与首轮一致。
    static func sandboxFlags(_ raw: String, resuming: Bool) -> [String] {
        switch AISandbox.from(raw) {
        case .workspaceWrite:
            return resuming ? ["-c", "sandbox_mode=\"workspace-write\""]
                            : ["-s", "workspace-write", "--approve-for-me"]
        case .readOnly:
            return resuming ? ["-c", "sandbox_mode=\"read-only\""] : ["-s", "read-only"]
        case .bypass:
            return ["--dangerously-bypass-approvals-and-sandbox"]
        }
    }

    /// 界面上预览用的完整命令行。
    static func previewCommand(settings: AIDevSettings, resuming: Bool) -> String {
        let args = resuming ? resumeArguments(settings: settings)
                            : firstArguments(settings: settings, prompt: "<任务描述>")
        return "codex " + args.map(Shell.shellQuote).joined(separator: " ")
    }
}

// MARK: - 环境自检

struct AIEnvironmentReport {
    var codexPath = ""
    var version = ""
    var loggedIn = false
    var configPath = ""
    var configuredModel = ""
    var configuredEffort = ""
    var models: [AIModelOption] = []
    var modelsSource = ""
    var proxy = AIProxyConfig()
    var checked = false

    var ready: Bool { !codexPath.isEmpty && loggedIn }
}

enum AIEnvironment {
    static var configPath: String { NSHomeDirectory() + "/.codex/config.toml" }
    static var authPath: String { NSHomeDirectory() + "/.codex/auth.json" }

    static func inspect() -> AIEnvironmentReport {
        var report = AIEnvironmentReport()
        report.codexPath = Paths.which("codex") ?? ""
        report.configPath = configPath
        report.loggedIn = FileTools.exists(authPath)
        if !report.codexPath.isEmpty {
            let result = Shell.run([report.codexPath, "--version"], timeout: 60)
            report.version = (result.stdout + result.stderr).lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.lowercased().contains("codex") } ?? ""
        }
        let configText = FileTools.read(configPath)
        report.configuredModel = AIModelCatalog.configuredModel(configText: configText)
        report.configuredEffort = AIModelCatalog.configuredEffort(configText: configText)
        let loaded = AIModelCatalog.load(codexPath: report.codexPath.isEmpty ? nil : report.codexPath)
        report.models = loaded.models
        report.modelsSource = loaded.source
        report.proxy = AIProxyConfig.detect()
        report.checked = true
        return report
    }
}

// MARK: - 看门狗状态

/// 回传给界面的状态快照（值类型，方便直接放进 @Published）。
struct AIDevSnapshot: Equatable {
    var running = false
    var round = 0
    var phase = "空闲"
    var lastExit: Int32?
    var waitingUntil: Date?
    var resetAt: Date?
    var logPath = ""
    var logTail = ""
    var workDir = ""
    var message = ""
    /// 本轮从事件流里统计出来的动作（命令数、改动文件、todo 完成度）
    var summary = CodexRoundSummary()
    /// 连续多少轮「没有任何命令执行或文件改动」
    var idleRounds = 0
    /// 最近一次验收结果（空 = 没配验收命令 / 还没跑）
    var acceptance: [AcceptanceResult] = []
    /// 验收是否已经跑过（区分"没配"和"跑了但全绿"）
    var acceptanceRan = false
    /// 修复队列进度：0/0 表示不在修复模式
    var fixQueueTotal = 0
    var fixQueueIndex = 0
    /// 当前正在修的那条审查问题标题
    var currentFinding = ""
}

// MARK: - 看门狗

/// 一轮运行中在读取线程之间传递的进度盒子（stdout 解析、stderr 透传都要用）。
private final class RoundProgress: @unchecked Sendable {
    let lock = NSLock()
    /// 要不要把 stdout 当 JSONL 事件流解析
    var parseEvents = true
    /// 本轮原始输出尾部（限额/登录错误关键词就靠它判断）
    var tail = ""
    /// stdout 按行缓冲（事件是一行一个 JSON）
    var pendingLine = ""
    var summary = CodexRoundSummary()
}

/// 在 App 里跑的看门狗：循环执行 `codex exec`，被 5 小时限额打断后自动 resume 续跑。
///
/// 与豆包脚本相比的几处改进：
/// - 参数按当前 codex 版本生成（`--full-auto` 已不存在）；
/// - 能从限额文案里解析「几点恢复」，等到那个时间点再重试，而不是一路指数退避到 1 小时；
/// - 登录/鉴权类错误直接停下并提示，不会拿着死配置无限重试；
/// - 每轮输出实时落盘 + 尾部回传界面，随时能看到跑到哪了。
final class AIDevRunner: @unchecked Sendable {
    static let doneFlagName = ".codex_done"
    static let logFileName = ".dbm-ai-watchdog.log"

    /// 状态变化回调（主线程）。
    var onChange: ((AIDevSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "dbmanager.aidev.watchdog")
    private let lock = NSLock()
    private var snapshot = AIDevSnapshot()
    private var process: Process?
    private var stopRequested = false
    private var logHandle: FileHandle?
    private var tailLines: [String] = []
    private var pendingTail = ""
    private var lastNotify = Date.distantPast
    private var doneFlagPath = ""

    private static let tailLimit = 400

    var current: AIDevSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    // MARK: 对外控制

    /// 开始跑任务。
    ///
    /// - `resume` = true：直接续跑工作目录里最近的会话（跳过首轮）。
    /// - `fixQueue` 非空：进入「按审查报告修复」模式 —— 每轮只处理一条必修项，
    ///   修完跑验收，通过才下一条。
    func start(settings: AIDevSettings, resume: Bool, codexPath: String,
               fixQueue: [ReviewFinding] = []) {
        lock.lock()
        if snapshot.running { lock.unlock(); return }
        stopRequested = false
        let workDir = AICodexCommand.workDirectory(settings)
        let phase = fixQueue.isEmpty
            ? (resume ? "准备续跑…" : "准备启动…")
            : "准备按审查报告修复 \(fixQueue.count) 条…"
        snapshot = AIDevSnapshot(running: true, round: 0, phase: phase,
                                 logPath: workDir + "/" + AIDevRunner.logFileName, workDir: workDir,
                                 fixQueueTotal: fixQueue.count)
        lock.unlock()

        queue.async { [weak self] in
            self?.loop(settings: settings, resume: resume, codexPath: codexPath, fixQueue: fixQueue)
        }
    }

    /// 请求停止：先 SIGTERM，3 秒还赖着就 SIGKILL。
    func stop() {
        lock.lock()
        stopRequested = true
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }
        Diag.log("AI 看门狗：请求停止（pid \(running.processIdentifier)）")
        running.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }

    // MARK: 主循环

    private func loop(settings: AIDevSettings, resume: Bool, codexPath: String,
                      fixQueue: [ReviewFinding]) {
        let workDir = AICodexCommand.workDirectory(settings)
        Paths.ensureDirectory(forFile: workDir + "/placeholder")
        let logPath = workDir + "/" + AIDevRunner.logFileName
        doneFlagPath = workDir + "/" + AIDevRunner.doneFlagName
        openLog(logPath)
        writeLog("=== AI 看门狗启动 \(timestamp()) ===")
        writeLog("工作目录：\(workDir)")
        writeLog("codex：\(codexPath)")
        writeLog("沙箱：\(AISandbox.from(settings.sandbox).label)　模型：\(settings.model.isEmpty ? "跟随 Codex 配置" : settings.model)　推理强度：\(settings.effort.isEmpty ? "跟随模型默认" : settings.effort)")
        writeLog("代理：\(settings.useProxy ? (AIProxyConfig.normalize(settings.proxyOverride) ?? "本机系统代理") : "不使用")")
        if !fixQueue.isEmpty {
            writeLog("模式：按审查报告修复 \(fixQueue.count) 条必修项（每条修完跑验收，通过才下一条）")
        }

        let acceptanceCommands = Acceptance.commands(settings.acceptanceCommands)
        if acceptanceCommands.isEmpty {
            writeLog("⚠️ 没有配置验收命令：完成判定只能靠「模型声明完成 + 连续无动作」的启发式，不可靠。")
        } else {
            writeLog("验收命令：")
            for command in acceptanceCommands { writeLog("  - \(command)") }
        }

        // 开工前跑一次验收基线。
        //
        // 基线红**不拦人**：需求本身就可能是「让这个失败的测试通过」（TDD 式），
        // 这时正确判据是「从红变绿」而不是「本来就绿」。所以这里只记录 + 提示。
        // 真正防死循环的是后面的「连续 3 轮验收结果没变化就停下」。
        if !acceptanceCommands.isEmpty {
            update { $0.phase = "正在跑验收基线…" }
            let baseline = runAcceptance(acceptanceCommands, cwd: workDir, settings: settings).map { result in
                var copy = result
                copy.baselineFailed = !result.ok
                return copy
            }
            update { $0.acceptance = baseline; $0.acceptanceRan = true }
            writeLog("--- 验收基线 ---")
            for result in baseline { writeLog("  \(result.summary)") }
            let failed = baseline.filter { !$0.ok }
            if !failed.isEmpty {
                let list = failed.map(\.command).joined(separator: "、")
                writeLog("⚠️ 开工前就是失败的验收命令：\(list)")
                writeLog("   这是允许的（需求可能就是「让失败的测试通过」），完成判据是这些命令全部变绿。")
                writeLog("   但如果是命令本身写错了，它会一直修不好 —— 连续 3 轮验收结果没变化时会自动停下。")
                update { $0.phase = "注意：有验收命令开工前就是红的，会一直跑到它变绿" }
            }
        }

        var useResume = resume
        var attempt = 0
        var round = 0
        var idleRounds = 0
        var queueIndex = 0
        var itemAttempts = 0
        var lastFailureText = ""
        var lastAcceptanceSignature = ""
        var stuckRounds = 0
        var lastSummary = CodexRoundSummary()
        let isFixMode = !fixQueue.isEmpty
        if isFixMode { update { $0.fixQueueTotal = fixQueue.count; $0.fixQueueIndex = 0 } }

        while true {
            if stopRequestedNow() { finish("已手动停止"); return }
            if FileTools.exists(doneFlagPath) { finish("检测到完成标记 \(AIDevRunner.doneFlagName)，看门狗退出"); return }
            if settings.maxRounds > 0, round >= settings.maxRounds {
                finish("已达到设定的最大轮次 \(settings.maxRounds)"); return
            }
            round += 1
            let prompt: String
            let banner: String
            if isFixMode {
                // 修复队列：每轮都用「当前这一条」的指令，跟 resume 标志无关
                let finding = fixQueue[min(queueIndex, fixQueue.count - 1)]
                prompt = ReviewFinding.fixPrompt(finding, acceptance: acceptanceCommands)
                    + (lastFailureText.isEmpty ? "" : "\n\n上一次尝试后验收仍然失败：\n" + Acceptance.tail(lastFailureText, limit: 1500))
                banner = "按审查报告修复第 \(queueIndex + 1)/\(fixQueue.count) 条：\(finding.title)"
            } else if useResume {
                prompt = developmentPrompt(settings: settings, summary: lastSummary,
                                           acceptanceFailure: lastFailureText)
                banner = "resume 续跑最近的会话"
            } else {
                prompt = settings.prompt
                banner = "新建会话执行任务"
            }
            // 修复模式一律走 resume：要接着开发那个会话修，而不是另开一个（会话不存在时它会报错，也看得见）
            let args = (useResume || isFixMode)
                ? AICodexCommand.resumeArguments(settings: settings, prompt: prompt)
                : AICodexCommand.firstArguments(settings: settings, prompt: prompt)
            update {
                $0.running = true
                $0.round = round
                $0.phase = "第 \(round) 轮：\(banner)"
                $0.fixQueueIndex = isFixMode ? queueIndex : 0
                $0.currentFinding = isFixMode ? fixQueue[min(queueIndex, fixQueue.count - 1)].title : ""
            }
            writeLog("\n--- 第 \(round) 轮 \(timestamp())（\(banner)）---")
            if isFixMode {
                writeLog("给 codex 的指令：\n\(prompt)")
            }
            writeLog("$ codex " + args.map(Shell.shellQuote).joined(separator: " "))

            let outcome = runProcess(codexPath: codexPath, args: args,
                                     cwd: workDir, settings: settings)
            let status = outcome.status
            let recentOutput = outcome.tailText
            lock.lock(); process = nil; lock.unlock()
            // 之后都要 resume：首轮建好的会话才有上下文
            useResume = true
            logRoundSummary(outcome.summary)
            // 记下「这轮它说自己做了什么」，交付审查时要用（意图 vs 实际改动的落差最暴露问题）
            AIArtifacts.appendRoundNote(workDir, round: round, note: outcome.summary.lastMessage)
            update { $0.lastExit = status; $0.summary = outcome.summary }

            if stopRequestedNow() { finish("已手动停止（退出码 \(status)）"); return }
            if FileTools.exists(doneFlagPath) { finish("检测到完成标记 \(AIDevRunner.doneFlagName)，看门狗退出"); return }

            if status == 0 {
                attempt = 0
                lastSummary = outcome.summary

                // ① 配了验收命令：以它为准判定「做完了没有」。
                //    全绿 = 完成（这是唯一的客观完成判据）；失败就把失败原文带回下一轮，
                //    一直修到绿、或者卡住、或者撞到轮次上限。
                if !acceptanceCommands.isEmpty {
                    update { $0.phase = "第 \(round) 轮结束，正在跑验收命令…" }
                    let results = runAcceptance(acceptanceCommands, cwd: workDir, settings: settings)
                    update { $0.acceptance = results; $0.acceptanceRan = true }
                    writeLog("--- 第 \(round) 轮验收 ---")
                    for result in results { writeLog("  \(result.summary)") }

                    if Acceptance.allPassed(results) {
                        if isFixMode {
                            queueIndex += 1
                            itemAttempts = 0
                            lastFailureText = ""
                            update { $0.fixQueueIndex = queueIndex }
                            if queueIndex >= fixQueue.count {
                                finish("审查报告里 \(fixQueue.count) 条必修项全部修完，验收命令也全绿。可以交付了")
                                return
                            }
                            writeLog("第 \(queueIndex) 条已通过验收，继续下一条。")
                            continue
                        }
                        finish("验收命令全部通过，判定任务完成（第 \(round) 轮）。可以交付了")
                        return
                    }

                    lastFailureText = Acceptance.failureText(results)

                    if isFixMode {
                        itemAttempts += 1
                        let finding = fixQueue[min(queueIndex, fixQueue.count - 1)]
                        if itemAttempts >= 2 {
                            finish("第 \(queueIndex + 1) 条「\(finding.title)」试了 \(itemAttempts) 轮，验收仍然失败，停下等你处理")
                            return
                        }
                        writeLog("第 \(queueIndex + 1) 条（\(finding.title)）第 \(itemAttempts) 次尝试后验收仍未通过，把失败原文带回去重试。")
                        continue
                    }

                    // 卡住检测：连续几轮验收结果一模一样，说明它在原地打转，别再烧额度
                    let signature = results.map { "\($0.command)=\($0.status)" }.joined(separator: " | ")
                    if signature == lastAcceptanceSignature { stuckRounds += 1 } else { stuckRounds = 0 }
                    lastAcceptanceSignature = signature
                    if stuckRounds >= 2 {
                        writeLog("连续 3 轮验收结果完全没变（\(signature)），判定卡住。")
                        finish("连续 3 轮验收失败项完全一样，判定卡住了，停下等你处理（每轮的失败原文都在日志里）")
                        return
                    }

                    let delay = max(5, settings.continueDelay)
                    update { $0.phase = "验收未通过（同一结果已 \(stuckRounds + 1) 轮），\(delay) 秒后继续修" }
                    writeLog("验收未通过，\(delay) 秒后带着失败原文继续。")
                    if waitInterruptibly(TimeInterval(delay), base: "验收失败后重试前等待") { return }
                    continue
                }

                // ② 没配验收命令：退回启发式（空转判定）
                // 「整轮只有消息、没有任何命令执行和文件改动」= 这轮它没干活。
                // 连续出现就说明模型认为没活可干了 —— 靠这个避免无限空转烧额度。
                // （只在开了 --json 且确实收到过事件时才判断，解析不到就别乱停）
                let idle = settings.jsonEvents
                    && outcome.summary.eventCount > 0
                    && !outcome.summary.hasSubstantiveAction
                if idle { idleRounds += 1 } else { idleRounds = 0 }
                update { $0.idleRounds = idleRounds }

                if settings.autoContinue {
                    if idleRounds >= 2 {
                        writeLog("连续 \(idleRounds) 轮只有消息、没有命令执行和文件改动，判断已无活可干。")
                        finish("连续 \(idleRounds) 轮没有实质动作，看门狗收工（模型大概率认为做完了）。要它接着干就点「续跑最近会话」")
                        return
                    }
                    let delay = max(5, settings.continueDelay)
                    let note = idle ? "［本轮没有实质动作］" : ""
                    update { $0.phase = "本轮正常结束（exit 0）\(note)，\(delay) 秒后自动续跑" }
                    writeLog("本轮正常结束（exit 0）\(note)，\(delay) 秒后自动 resume。")
                    if waitInterruptibly(TimeInterval(delay), base: "自动续跑前等待") { return }
                    continue
                }
                let note = idle ? "本轮没有任何命令执行或文件改动，模型可能已经认为做完了。" : ""
                finish("本轮正常结束（exit 0）。\(note)若任务还没完，点「续跑最近会话」接着跑")
                return
            }

            if AIUsageLimit.looksLikeNoSession(recentOutput) {
                writeLog("这个目录里没有可续跑的会话，停止重试。输出尾部：\n\(recentOutput)")
                finish("这个目录里没有可续跑的会话——点「开始执行任务」新建一个")
                return
            }

            if AIUsageLimit.looksFatal(recentOutput) {
                writeLog("疑似登录/鉴权或目录配置问题，停止重试。输出尾部：\n\(recentOutput)")
                finish("codex 报的是登录/配置类错误（不是限额），已停止，请先跑一次 codex login 或检查设置")
                return
            }

            attempt += 1
            let now = Date()
            let resetAt = AIUsageLimit.parseResetDate(in: recentOutput, now: now)
            let wait = AIUsageLimit.waitSeconds(resetAt: resetAt, now: now, attempt: attempt)
            let reason = resetAt != nil ? "疑似额度用尽（已解析到恢复时间）" : "异常退出（疑似限额/网络问题）"
            writeLog("\(reason)：exit=\(status)，等待 \(Int(wait)) 秒后重试第 \(attempt) 次。")
            update {
                $0.resetAt = resetAt
                $0.waitingUntil = Date().addingTimeInterval(wait)
                $0.phase = "\(reason)，等待 \(AIDevRunner.durationText(wait)) 后重试"
            }
            if waitInterruptibly(wait, base: "限额等待") { return }
            update { $0.waitingUntil = nil }
        }
    }

    /// 可打断的等待：每 0.5 秒看一眼是否要停、或是否出现了完成标记。
    /// 返回值 true 表示循环应该退出（已请求停止 / 出现完成标记）。
    private func waitInterruptibly(_ seconds: TimeInterval, base: String) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var lastSecond = Int.max
        while true {
            if stopRequestedNow() { finish("已手动停止"); return true }
            if !doneFlagPath.isEmpty, FileTools.exists(doneFlagPath) {
                finish("检测到完成标记 \(AIDevRunner.doneFlagName)，看门狗退出")
                return true
            }
            let remain = deadline.timeIntervalSinceNow
            if remain <= 0 { return false }
            let whole = Int(remain.rounded(.up))
            if whole != lastSecond {
                lastSecond = whole
                let remainText = AIDevRunner.durationText(TimeInterval(whole))
                update { $0.phase = "\(base)中，还剩 \(remainText)" }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func finish(_ message: String) {
        writeLog("=== 结束：\(message) ===")
        update {
            $0.running = false
            $0.phase = message
            $0.waitingUntil = nil
            $0.message = message
        }
        closeLog()
    }

    // MARK: 跑一轮 codex

    /// 一轮的产出：退出码、原始输出尾部（关键词判断用）、事件流汇总。
    private struct RoundOutcome {
        var status: Int32
        var tailText: String
        var summary: CodexRoundSummary
    }

    private func runProcess(codexPath: String, args: [String], cwd: String,
                            settings: AIDevSettings) -> RoundOutcome {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: codexPath)
        task.arguments = args
        task.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.searchPaths.joined(separator: ":")
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        if settings.useProxy {
            for (key, value) in AIProxyConfig.detect().environment(override: settings.proxyOverride) {
                env[key] = value
            }
        } else {
            for key in ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy",
                        "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy"] {
                env.removeValue(forKey: key)
            }
        }
        task.environment = env

        // stdout 与 stderr 分开接：json 模式下 stdout 是事件流，stderr 一般是告警/进度，不能混着解析
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.standardInput = FileHandle.nullDevice

        let progress = RoundProgress()
        progress.parseEvents = settings.jsonEvents

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            self?.absorbStdout(text, into: progress)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            self?.recordTail(text, into: progress)
            self?.appendOutput(text)
        }

        do {
            try task.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let message = "启动 codex 失败：\(error.localizedDescription)"
            writeLog(message)
            return RoundOutcome(status: 126, tailText: message, summary: CodexRoundSummary())
        }
        lock.lock(); process = task; lock.unlock()
        task.waitUntilExit()
        // 让最后一批输出落进来
        Thread.sleep(forTimeInterval: 0.2)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        // 收尾：处理最后一行（可能没有换行符）
        progress.lock.lock()
        let leftover = progress.pendingLine
        progress.pendingLine = ""
        progress.lock.unlock()
        if !leftover.isEmpty { handleEventLine(leftover, into: progress) }

        progress.lock.lock()
        let summary = progress.summary
        let tail = progress.tail
        progress.lock.unlock()

        writeLog("（本轮 codex 退出码 \(task.terminationStatus)）")
        return RoundOutcome(status: task.terminationStatus,
                            tailText: String(tail.suffix(8000)),
                            summary: summary)
    }

    /// stdout：json 模式按行解析事件，否则原样透传（和以前一样）。
    private func absorbStdout(_ text: String, into progress: RoundProgress) {
        recordTail(text, into: progress)
        guard progress.parseEvents else {
            appendOutput(text)
            return
        }
        progress.lock.lock()
        progress.pendingLine += text
        var lines: [String] = []
        while let index = progress.pendingLine.firstIndex(of: "\n") {
            lines.append(String(progress.pendingLine[progress.pendingLine.startIndex..<index]))
            progress.pendingLine = String(progress.pendingLine[progress.pendingLine.index(after: index)...])
        }
        // 病态长行（比如整段 reasoning 挤在一行里）不无限攒着
        if progress.pendingLine.count > 1_000_000 { progress.pendingLine = "" }
        progress.lock.unlock()
        for line in lines { handleEventLine(line, into: progress) }
    }

    private func recordTail(_ text: String, into progress: RoundProgress) {
        progress.lock.lock()
        progress.tail += text
        if progress.tail.count > 40_000 { progress.tail = String(progress.tail.suffix(20_000)) }
        progress.lock.unlock()
    }

    /// 一行事件：解析成功后累计进度并把人类可读的渲染写进日志；
    /// 解析不出来的（比如 codex 自己打的告警）就原样记下来。
    private func handleEventLine(_ line: String, into progress: RoundProgress) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let event = CodexEventParser.parse(trimmed) else {
            appendOutput(line + "\n")
            return
        }
        progress.lock.lock()
        progress.summary.absorb(event)
        progress.lock.unlock()
        if let human = CodexEventParser.humanLine(event) { appendOutput(human + "\n") }
    }

    /// 把本轮汇总写进日志，方便回看「它到底干了什么」。
    private func logRoundSummary(_ summary: CodexRoundSummary) {
        guard summary.eventCount > 0 else { return }
        var parts = ["命令 \(summary.commands) 次",
                     "改动文件 \(summary.changedFiles.count) 个"]
        if !summary.todos.isEmpty { parts.append("todo \(summary.completedTodoCount)/\(summary.todos.count)") }
        if summary.inputTokens > 0 || summary.outputTokens > 0 {
            parts.append("tokens 输入 \(summary.inputTokens) / 输出 \(summary.outputTokens)")
        }
        writeLog("—— 本轮汇总：" + parts.joined(separator: "　"))
        if !summary.changedFiles.isEmpty {
            writeLog("   改动：" + summary.changedFiles.joined(separator: "、"))
        }
        if !summary.hasSubstantiveAction {
            writeLog("   ⚠️ 本轮没有命令执行、也没有文件改动")
        }
        if summary.turnFailed, !summary.errorMessage.isEmpty {
            writeLog("   失败原因：" + summary.errorMessage)
        }
    }

    // MARK: 验收与推进提示

    /// 跑验收命令，逐条返回结果（含输出尾部）。
    ///
    /// 这是整套无人值守里唯一"能判定完成"的东西 —— 所以它必须能被打断（`Shell.run` 带超时），
    /// 也必须把输出尾部留下来（失败原文要回灌给模型，不能指望它自己回忆）。
    private func runAcceptance(_ commands: [String], cwd: String, settings: AIDevSettings) -> [AcceptanceResult] {
        let timeout = TimeInterval(max(30, settings.acceptanceTimeout))
        for command in commands {
            writeLog("$ \(command)    （验收命令，超时 \(Int(timeout)) 秒）")
        }
        return Acceptance.run(commands, cwd: cwd, timeout: timeout)
    }

    /// 开发模式下的续跑提示。
    ///
    /// 三个刻意的设计：
    /// - **目标全文每轮重放**（长会话里模型会漂移，重放是最便宜的纠偏）；
    /// - **未完成项来自事件流的 todo**，不是让它自己回忆；
    /// - **验收失败原文回灌**，并要求它用 DONE / NEXT 明确表态。
    private func developmentPrompt(settings: AIDevSettings, summary: CodexRoundSummary,
                                   acceptanceFailure: String) -> String {
        var lines: [String] = []
        lines.append("【目标】" + (settings.prompt.isEmpty ? "（未提供任务描述）" : settings.prompt))
        if summary.eventCount > 0 {
            var stat = "【上轮】执行 \(summary.commands) 条命令"
            if !summary.changedFiles.isEmpty {
                stat += "；改动文件：" + summary.changedFiles.prefix(20).joined(separator: "、")
            }
            if !summary.todos.isEmpty {
                stat += "；todo \(summary.completedTodoCount)/\(summary.todos.count)"
            }
            lines.append(stat)
            let pending = summary.todos.filter { !$0.completed }.map(\.text)
            if !pending.isEmpty {
                lines.append("【还没做】")
                for (index, item) in pending.enumerated() { lines.append("  \(index + 1). \(item)") }
            }
        }
        if !acceptanceFailure.isEmpty {
            lines.append("【验收现状】还没通过，失败原文：\n" + Acceptance.tail(acceptanceFailure, limit: 2000))
        }
        lines.append("【要求】只处理上面未完成的部分；不要扩大范围；不要动与目标无关的文件。")
        lines.append("最后一行：全部完成输出 DONE；否则输出 NEXT: <你下一步要做什么>。")
        return lines.joined(separator: "\n")
    }

    // MARK: 日志与状态

    private func openLog(_ path: String) {
        Paths.ensureDirectory(forFile: path)
        if !FileTools.exists(path) { FileManager.default.createFile(atPath: path, contents: nil) }
        logHandle = FileHandle(forWritingAtPath: path)
        if logHandle == nil {
            // 日志写不进去不影响干活（页面照样实时显示输出），但值得记一笔
            Diag.log("AI 看门狗：日志文件打不开（\(path)），本轮输出只显示在界面上")
        }
        _ = try? logHandle?.seekToEnd()
    }

    private func closeLog() {
        lock.lock()
        let handle = logHandle
        logHandle = nil
        lock.unlock()
        try? handle?.close()
    }

    private func writeLog(_ text: String) {
        let line = text.hasSuffix("\n") ? text : text + "\n"
        lock.lock()
        let handle = logHandle
        lock.unlock()
        try? handle?.write(contentsOf: Data(line.utf8))
    }

    private func appendOutput(_ text: String) {
        writeLog(text.hasSuffix("\n") ? String(text.dropLast()) : text)
        lock.lock()
        pendingTail += text
        while let index = pendingTail.firstIndex(of: "\n") {
            tailLines.append(String(pendingTail[pendingTail.startIndex..<index]))
            pendingTail = String(pendingTail[pendingTail.index(after: index)...])
        }
        if tailLines.count > AIDevRunner.tailLimit {
            tailLines.removeFirst(tailLines.count - AIDevRunner.tailLimit)
        }
        let tail = (tailLines + (pendingTail.isEmpty ? [] : [pendingTail])).joined(separator: "\n")
        let shouldNotify = Date().timeIntervalSince(lastNotify) > 0.4
        if shouldNotify { lastNotify = Date() }
        snapshot.logTail = tail
        let snapshotCopy = snapshot
        lock.unlock()
        if shouldNotify { notify(snapshotCopy) }
    }

    private func update(_ change: (inout AIDevSnapshot) -> Void) {
        lock.lock()
        change(&snapshot)
        let copy = snapshot
        lock.unlock()
        notify(copy)
    }

    private func notify(_ snapshot: AIDevSnapshot) {
        guard let onChange else { return }
        DispatchQueue.main.async { onChange(snapshot) }
    }

    private func stopRequestedNow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) 秒" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        let restMinutes = minutes % 60
        return restMinutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(restMinutes) 分"
    }
}
