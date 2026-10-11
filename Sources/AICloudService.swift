import Foundation

// MARK: - 设置

/// 「云端任务」页的设置。
///
/// 这一页是把 `codex cloud` 这套官方云端任务包装成界面：
/// 需求丢上去 → 云端沙箱里自己干 → 回来看 diff → 满意就 apply 到本地。
/// 所以它和本地看门狗是两条独立的路，各自有自己的配置。
struct AICloudSettings: Codable {
    /// 云端环境 ID（`codex cloud exec --env` 要的那个）。
    /// 只能在终端跑 `codex cloud` 浏览/创建，接口里没有列环境的命令。
    var environmentID = ""
    /// 本地仓库路径：`apply` 会把云端 diff 打到这个目录
    var workDir = ""
    /// 云端跑在哪个分支上（空 = 用云端的默认）
    var branch = ""
    /// best-of-N：同一个需求让云端跑几次，取最好的一次
    var attempts = 1
    /// 列表拉多少条（接口限制 1–20）
    var listLimit = 20

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environmentID = try container.decodeIfPresent(String.self, forKey: .environmentID) ?? environmentID
        workDir = try container.decodeIfPresent(String.self, forKey: .workDir) ?? workDir
        branch = try container.decodeIfPresent(String.self, forKey: .branch) ?? branch
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? attempts
        listLimit = try container.decodeIfPresent(Int.self, forKey: .listLimit) ?? listLimit
    }

    var isConfigured: Bool { !environmentID.isEmpty }

    /// 命令行里用的条数（接口只接受 1–20）。
    var clampedLimit: Int { min(max(listLimit, 1), 20) }

    var clampedAttempts: Int { min(max(attempts, 1), 5) }

    var hasWorkDir: Bool { !workDir.trimmingCharacters(in: .whitespaces).isEmpty }

    var resolvedWorkDir: String {
        let raw = workDir.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return NSHomeDirectory() }
        return (raw as NSString).standardizingPath
    }
}

// MARK: - 任务

/// 云端任务的归一化状态（接口给的是字符串，写法不确定，所以宽松匹配）。
enum AICloudStatus: String {
    case pending, running, completed, failed, cancelled, unknown

    static func from(_ raw: String) -> AICloudStatus {
        let text = raw.lowercased()
        guard !text.isEmpty else { return .unknown }
        if text.contains("cancel") { return .cancelled }
        if text.contains("fail") || text.contains("error") || text.contains("reject") { return .failed }
        if text.contains("complete") || text.contains("success") || text.contains("succeed")
            || text.contains("done") || text.contains("finish") || text.contains("merged") { return .completed }
        if text.contains("run") || text.contains("progress") || text.contains("active")
            || text.contains("working") || text.contains("execut") { return .running }
        if text.contains("pend") || text.contains("queue") || text.contains("wait")
            || text.contains("init") || text.contains("new") { return .pending }
        return .unknown
    }

    var label: String {
        switch self {
        case .pending: return "排队中"
        case .running: return "进行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .unknown: return "未知"
        }
    }

    /// 已经结束（不用再等）的状态。
    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

struct AICloudTask: Identifiable, Equatable {
    var id = ""
    /// 需求原文（接口里叫 instructions 或 title/query，宽松取）
    var title = ""
    /// 接口给的原始状态串
    var statusText = ""
    var status: AICloudStatus = .unknown
    var createdAt = ""
    var environmentID = ""
    var branch = ""
    var attempts = 1
    /// 原始 JSON（界面里可展开看，解析不准时靠它）
    var rawJSON = ""

    var shortID: String { id.count > 8 ? String(id.prefix(8)) : id }

    var displayTitle: String {
        title.isEmpty ? "（这条任务没带描述）" : title
    }

    /// 时间戳是 unix 秒/毫秒时转成可读文本；否则原样。
    var displayCreatedAt: String {
        guard let value = Double(createdAt), value > 0 else { return createdAt }
        let seconds = value > 4_000_000_000 ? value / 1000 : value
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}

// MARK: - 解析

enum AICloud {
    /// 解析 `codex cloud list --json`（实测结构：`{"tasks":[…],"cursor":null}`）。
    /// 字段名一律用候选列表宽松匹配 —— 不同版本字段命名可能变，认不出就留空，不崩。
    static func parseTasks(json: String) -> [AICloudTask] {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = root["tasks"] as? [[String: Any]] else { return [] }
        return raw.compactMap { parseTask($0) }
    }

    static func parseTask(_ object: [String: Any]) -> AICloudTask? {
        let id = firstString(object, ["task_id", "taskId", "id"])
        guard !id.isEmpty else { return nil }
        var task = AICloudTask(id: id)
        task.title = firstString(object, ["instructions", "title", "query", "prompt", "description", "name"])
            .replacingOccurrences(of: "\n", with: " ")
        task.statusText = firstString(object, ["task_status", "status", "state", "lifecycle_status"])
        task.status = AICloudStatus.from(task.statusText)
        task.createdAt = firstScalarString(object, ["created_at", "createdAt", "created"])
        task.environmentID = firstString(object, ["environment_id", "environmentId", "env_id", "environment"])
        task.branch = firstString(object, ["head_branch", "branch"])
        task.attempts = firstInt(object, ["attempts", "attempt_count", "best_of"]) ?? 1
        if let data = try? JSONSerialization.data(withJSONObject: object,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            task.rawJSON = text
        }
        return task
    }

    /// 从命令输出里找任务 ID（只认 UUID 形态，宁缺勿错）。
    static func extractTaskID(from output: String) -> String? {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let found = Range(match.range, in: output) else { return nil }
        return String(output[found])
    }

    private static func firstString(_ dict: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    /// 有些字段（比如 unix 时间戳）接口给的是数字，也要吃得下。
    private static func firstScalarString(_ dict: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let value = dict[key] as? Int { return String(value) }
            if let value = dict[key] as? Double { return String(value) }
        }
        return ""
    }

    private static func firstInt(_ dict: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let value = dict[key] as? Int { return value }
            if let value = dict[key] as? Double { return Int(value) }
            if let value = dict[key] as? String, let number = Int(value) { return number }
        }
        return nil
    }
}

// MARK: - 客户端

/// 包装 `codex cloud` 的子命令。
///
/// 只有 `list` 支持 `--json`（实测），所以列表走 JSON 解析，
/// `status` / `diff` / `apply` / `exec` 一律把原始文本交给界面显示 ——
/// 这样即便 codex 换了文案也不会把工具搞崩（顶多是不好看）。
enum AICloudClient {
    static func codexPath() -> String? { Paths.which("codex") }

    /// codex cloud 每跑一次都会往**当前工作目录**写一个 `error.log`
    /// （名字叫 error，内容其实是 startup / auth / http 的调试日志）。
    /// 所以除了 `apply`（必须在目标仓库里跑，git 要有上下文），其余命令都切到工具自己的日志目录，
    /// 免得把垃圾丢进用户的仓库或项目里。
    static var cloudWorkingDirectory: String {
        let dir = Paths.logDir.path
        Paths.ensureDirectory(forFile: dir + "/placeholder")
        return dir
    }

    static func list(settings: AICloudSettings) -> Outcome<[AICloudTask]> {
        guard let codex = codexPath() else { return .failure("找不到 codex 命令") }
        var args = ["cloud", "list", "--json", "--limit", String(settings.clampedLimit)]
        if !settings.environmentID.isEmpty { args += ["--env", settings.environmentID] }
        let result = Shell.run([codex] + args, timeout: 120, cwd: cloudWorkingDirectory)
        guard result.ok else {
            return .failure("拉取云端任务失败：\(message(result))")
        }
        let tasks = AICloud.parseTasks(json: result.stdout)
        // 输出不是预期 JSON（比如登录过期返回了别的文本）时要看得见
        if tasks.isEmpty, !result.stdout.contains("\"tasks\"") {
            return .failure("云端返回的内容不是预期的 JSON：\n\(result.stdout.prefix(400))")
        }
        return .success(tasks)
    }

    static func status(taskID: String) -> Outcome<String> {
        guard let codex = codexPath() else { return .failure("找不到 codex 命令") }
        let result = Shell.run([codex, "cloud", "status", taskID], timeout: 120, cwd: cloudWorkingDirectory)
        return result.ok ? .success(clean(result.stdout + result.stderr)) : .failure(message(result))
    }

    static func diff(taskID: String, attempt: Int) -> Outcome<String> {
        guard let codex = codexPath() else { return .failure("找不到 codex 命令") }
        var args = ["cloud", "diff", taskID]
        if attempt > 0 { args += ["--attempt", String(attempt)] }
        let result = Shell.run([codex] + args, timeout: 180, cwd: cloudWorkingDirectory)
        return result.ok ? .success(clean(result.stdout)) : .failure(message(result))
    }

    static func apply(taskID: String, attempt: Int, workDir: String) -> Outcome<String> {
        guard let codex = codexPath() else { return .failure("找不到 codex 命令") }
        guard FileTools.isDirectory(workDir) else {
            return .failure("本地仓库路径不存在：\(workDir)")
        }
        var args = ["cloud", "apply", taskID]
        if attempt > 0 { args += ["--attempt", String(attempt)] }
        // apply 必须在这个仓库里跑（git apply 的语义），所以它躲不开 error.log：
        // 记下运行前的状态，跑完把**新出现**的那个文件收掉，别让它留在用户仓库里。
        let strayLog = workDir + "/error.log"
        let existedBefore = FileTools.exists(strayLog)
        let result = Shell.run([codex] + args, timeout: 300, cwd: workDir)
        var cleaned = false
        if !existedBefore, FileTools.exists(strayLog) {
            try? FileManager.default.removeItem(atPath: strayLog)
            cleaned = true
        }
        guard result.ok else { return .failure(message(result)) }
        var text = clean(result.stdout + result.stderr)
        if cleaned { text += "\n\n（已顺手清掉 codex 在这个目录里留下的 error.log）" }
        return .success(text)
    }

    /// 派任务的结果：能认出任务 ID 就带上（认不出也不影响，刷新列表可见）。
    struct AICloudSubmitResult: Equatable {
        var taskID = ""
        var output = ""
    }

    /// 派任务。输出里如果能认出 UUID，就当作新任务 ID 一起返回。
    static func exec(query: String, settings: AICloudSettings) -> Outcome<AICloudSubmitResult> {
        guard let codex = codexPath() else { return .failure("找不到 codex 命令") }
        guard settings.isConfigured else {
            return .failure("先填云端环境 ID（在终端跑 `codex cloud` 可以浏览/创建环境）")
        }
        var args = ["cloud", "exec", "--env", settings.environmentID]
        if settings.clampedAttempts > 1 { args += ["--attempts", String(settings.clampedAttempts)] }
        if !settings.branch.isEmpty { args += ["--branch", settings.branch] }
        args.append(query)
        let result = Shell.run([codex] + args, timeout: 300,
                               cwd: settings.hasWorkDir ? settings.resolvedWorkDir : cloudWorkingDirectory)
        let output = clean(result.stdout + result.stderr)
        guard result.ok else { return .failure(message(result)) }
        return .success(AICloudSubmitResult(taskID: AICloud.extractTaskID(from: output) ?? "",
                                            output: output))
    }

    // MARK: 输出整理

    private static func clean(_ text: String) -> String {
        text.lines
            .filter { !$0.contains("could not create PATH aliases") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func message(_ result: CommandResult) -> String {
        let text = clean(result.stderr.isEmpty ? result.stdout : result.stderr)
        return text.isEmpty ? "退出码 \(result.status)" : text
    }
}

// MARK: - 页面状态

struct AICloudState {
    var tasks: [AICloudTask] = []
    var selectedID: String?
    /// 详情区文本（status 或 diff 的原文）
    var detail = ""
    var detailKind = ""
    var loadedAt: Date?
    var message = ""
    var error = ""
    /// 派任务用的输入
    var query = ""

    var selectedTask: AICloudTask? {
        guard let selectedID else { return nil }
        return tasks.first { $0.id == selectedID }
    }

    var runningCount: Int { tasks.filter { $0.status == .running || $0.status == .pending }.count }
}
