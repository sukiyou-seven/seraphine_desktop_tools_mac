import Foundation

// MARK: - 设置

/// 「审查者」的设置：一个独立的云端模型（默认 DeepSeek），只负责在交付后复核，
/// 不参与开发。所以它有自己的 baseURL / 模型名 / 密钥，跟 codex 完全分开。
struct AIReviewSettings: Codable {
    var baseURL = "https://api.deepseek.com"
    var model = "deepseek-v4-flash"
    /// 明文存在 settings.json（和工具里其它凭据一致）
    var apiKey = ""
    /// 走本机代理。DeepSeek 国内直连通常更快，所以默认不开。
    var useProxy = false
    /// 一次审查最多带多少字符的 diff；超了就截断并在报告里标注（避免超上下文）
    var maxDiffChars = 60_000
    /// 「审查 → 修复」最多来几轮，防止无限循环
    var maxFixRounds = 2
    /// 单次审查请求的超时（秒）。大 diff 的推理会慢。
    var timeoutSeconds = 600

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? model
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? apiKey
        useProxy = try container.decodeIfPresent(Bool.self, forKey: .useProxy) ?? useProxy
        maxDiffChars = try container.decodeIfPresent(Int.self, forKey: .maxDiffChars) ?? maxDiffChars
        maxFixRounds = try container.decodeIfPresent(Int.self, forKey: .maxFixRounds) ?? maxFixRounds
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? timeoutSeconds
    }

    var isConfigured: Bool { !apiKey.isEmpty && !model.isEmpty && !baseURL.isEmpty }

    /// 归一化后的 chat/completions 地址。
    var chatCompletionsURL: String {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return "" }
        if base.hasSuffix("/chat/completions") { return base }
        if base.hasSuffix("/v1") { return base + "/chat/completions" }
        return base + "/v1/chat/completions"
    }
}

// MARK: - 验收

/// 一条验收命令的执行结果。
struct AcceptanceResult: Equatable {
    var command: String
    var status: Int32
    var outputTail: String
    /// 是不是"本来就失败"（基线就红）——用于区分"没修好"和"项目本来就是红的"
    var baselineFailed = false

    var ok: Bool { status == 0 }

    var summary: String {
        "\(command) → 退出码 \(status)" + (ok ? " ✅" : " ❌")
    }
}

enum Acceptance {
    /// 把多行文本解析成命令列表：忽略空行与 `#` 注释。
    static func commands(_ raw: String) -> [String] {
        raw.lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// 所有命令都通过才算通过。空列表 = 没有验收标准（调用方要明确警告）。
    static func allPassed(_ results: [AcceptanceResult]) -> Bool {
        !results.isEmpty && results.allSatisfy(\.ok)
    }

    /// 真跑验收命令（跑测试可能很久，所以超时可配）。
    static func run(_ commands: [String], cwd: String, timeout: TimeInterval) -> [AcceptanceResult] {
        commands.map { command in
            let result = Shell.run(["/bin/sh", "-c", command], timeout: timeout, cwd: cwd)
            let output = result.stdout + "\n" + result.stderr
            return AcceptanceResult(command: command,
                                    status: result.status,
                                    outputTail: tail(output, limit: 2000))
        }
    }

    /// 失败命令的摘要行（给报告和推进提示用）。
    static func failureText(_ results: [AcceptanceResult]) -> String {
        let failed = results.filter { !$0.ok }
        guard !failed.isEmpty else { return "全部通过" }
        return failed.map { result in
            "\(result.command) → 退出码 \(result.status)\n" + tail(result.outputTail, limit: 600)
        }.joined(separator: "\n\n")
    }

    /// 输出尾部裁剪（给报告和推进提示用）。
    static func tail(_ text: String, limit: Int) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return "…" + String(flat.suffix(limit))
    }

    // MARK: 自动探测验收命令

    /// 探测出来的候选验收命令。
    struct Candidate: Equatable {
        var command: String
        /// 为什么推荐它（依据哪个文件/脚本），界面里直接显示，让人能判断
        var reason: String
        var score: Int
    }

    /// 看项目里有什么，给出可用的验收命令候选（按推荐度排序）。
    ///
    /// 「验收命令」其实就一句话：**能自动回答"这次改动做完了没有"的命令**。
    /// 所以这里优先找现成的测试入口，其次退到"至少能保证没写坏"的构建命令。
    /// 全都没有时返回空数组，界面会给通用例子让人参考。
    static func detect(workDir: String) -> [Candidate] {
        guard FileTools.isDirectory(workDir) else { return [] }
        var candidates: [Candidate] = []
        func add(_ command: String, _ reason: String, _ score: Int) {
            guard !candidates.contains(where: { $0.command == command }) else { return }
            candidates.append(Candidate(command: command, reason: reason, score: score))
        }
        let exists: (String) -> Bool = { FileTools.exists(workDir + "/" + $0) }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: workDir)) ?? []

        // ① 项目自己的测试脚本最可信
        for script in ["tests/run.sh", "test.sh", "run_tests.sh", "scripts/test.sh", "ci/test.sh"] {
            if exists(script) { add("./" + script, "项目里有 \(script)", 100) }
        }
        if exists("Makefile") {
            let makefile = FileTools.read(workDir + "/Makefile")
            for target in ["test", "check", "verify"] where makefile.lines.contains(where: { $0.hasPrefix(target + ":") }) {
                add("make \(target)", "Makefile 里有 \(target) target", 85)
            }
        }

        // ② 各语言生态的标准入口
        if exists("Package.swift") {
            if FileTools.isDirectory(workDir + "/Tests") {
                add("swift test", "Swift Package（有 Tests/）", 95)
            }
            add("swift build", "Swift Package：至少确认还能编译", 70)
        }
        if let project = entries.first(where: { $0.hasSuffix(".xcodeproj") }) {
            let scheme = String(project.dropLast(".xcodeproj".count))
            add("xcodebuild -project \(project) -scheme \(scheme) build",
                "Xcode 工程 \(project)（scheme 若不同请改成实际的）", 75)
        } else if let workspace = entries.first(where: { $0.hasSuffix(".xcworkspace") }) {
            let scheme = String(workspace.dropLast(".xcworkspace".count))
            add("xcodebuild -workspace \(workspace) -scheme \(scheme) build",
                "Xcode workspace \(workspace)", 75)
        }
        if exists("package.json") {
            let scripts = packageScripts(FileTools.read(workDir + "/package.json"))
            if let test = scripts["test"], !isPlaceholderTestScript(test) {
                add("npm test", "package.json 里的 test 脚本：\(tail(test, limit: 60))", 95)
            }
            if scripts["build"] != nil {
                add("npm run build", "package.json 里的 build 脚本", 70)
            }
            if scripts["lint"] != nil {
                add("npm run lint", "package.json 里的 lint 脚本", 50)
            }
            if scripts["test"] == nil, scripts["build"] == nil {
                add("npm test", "package.json（会用它的默认 test 脚本）", 40)
            }
        }
        if exists("Cargo.toml") {
            add("cargo test", "Rust 项目", 95)
            add("cargo build", "Rust 项目：至少确认还能编译", 65)
        }
        if exists("go.mod") {
            add("go build ./...", "Go 项目：编译所有包", 80)
            if entries.contains("_test.go") || FileTools.isDirectory(workDir + "/internal") {
                add("go test ./...", "Go 项目：跑测试", 85)
            }
        }
        if exists("pyproject.toml") || exists("pytest.ini") || exists("setup.cfg") || exists("requirements.txt") {
            add("python3 -m pytest -q", "Python 项目（需要装了 pytest）", 85)
        }
        if exists("pom.xml") { add("mvn -q test", "Maven 项目", 85) }
        if exists("build.gradle") || exists("build.gradle.kts") { add("./gradlew test", "Gradle 项目", 85) }
        if exists("CMakeLists.txt") {
            add("cmake -S . -B build && cmake --build build", "CMake 项目：配置并编译", 70)
        }

        // ③ 兜底：至少让 AI 说清"改了哪些文件"，避免它自称改完了其实没动
        if candidates.isEmpty {
            add("git diff --exit-code", "兜底：要求有实际改动（没改动就失败）——最好还是补一条真正的测试命令", 10)
        }
        return candidates.sorted { $0.score > $1.score }
    }

    /// 解析 package.json 的 scripts 字段（纯函数，方便自测）。
    static func packageScripts(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let scripts = root["scripts"] as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in scripts {
            if let text = value as? String { result[key] = text }
        }
        return result
    }

    /// npm init 默认的 test 脚本是**故意失败**的（`echo "Error: no test specified" && exit 1`），
    /// 拿它当验收命令会永远红 —— 要能识别出来并拒掉。
    static func isPlaceholderTestScript(_ script: String) -> Bool {
        let lower = script.lowercased()
        if lower.contains("no test specified") || lower.contains("no tests yet") { return true }
        if lower.contains("exit 1"), lower.contains("echo") { return true }
        return false
    }

    /// 探测不到时给的通用参考（界面展示用）。
    static func commonExamples() -> [(command: String, note: String)] {
        [
            ("swift build", "Swift：确认还能编译"),
            ("npm test", "Node：跑 package.json 的 test 脚本"),
            ("python3 -m pytest -q", "Python：跑 pytest"),
            ("go build ./...", "Go：编译所有包"),
            ("cargo test", "Rust：跑测试"),
            ("make test", "有 Makefile 且带 test target"),
        ]
    }
}

// MARK: - 审查请求

/// 打包给审查者的全部材料。**需求原文必须是最初那份**，不能被开发过程中
/// 模型自己重写的版本替代，否则审查基准就漂了（这是这种流程最常见的失效）。
struct ReviewRequest: Equatable {
    var requirement = ""
    var plan = ""
    /// 每轮"它说它做了什么"（来自事件流的 agent_message）
    var roundNotes: [String] = []
    var diff = ""
    var diffStat = ""
    var diffTruncated = false
    var acceptance: [AcceptanceResult] = []
    var deliveryReport = ""
    /// 材料收集过程中的问题（不是 git 仓库 / 没有提交 / diff 被截断…），审查者需要知道
    var materialNotes: String = ""
    /// 卡住检查点（中途审查）时只关心方向，不用带上全部材料
    var checkpoint = false

    var changedFiles: [String] {
        diffStat.lines.compactMap { line in
            let parts = line.split(separator: "|")
            guard let first = parts.first else { return nil }
            let path = first.trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : path
        }
    }
}

enum ReviewRequestBuilder {
    static func systemPrompt() -> String {
        """
        你是一名严格的代码审查者，审查另一个 AI 在**无人值守**模式下完成的一次开发交付。
        你只能依据下面给出的材料判断，不要臆测没有提供的代码。

        输出必须是 Markdown，结构固定（标题文字要一模一样）：

        ## 结论
        <一句话：可以交付 / 需要修复 N 处>

        ## 必修
        ### 1. <一句话标题>
        - 位置：<文件:行>
        - 问题：<具体说明错在哪>
        - 证据：<来自 diff 或验收结果的依据>
        - 建议改法：<具体到函数与行为>
        - 验收方式：<怎么确认修好了>

        ## 建议
        - <不阻塞交付的改进，最多 5 条>

        ## 存疑
        - <你无法判断、需要人决定的问题>

        规则：
        1. 「必修」只列真正影响正确性的问题：功能错误、逻辑漏洞、边界条件、越界改动（改了需求之外的
           文件）、与验收结果矛盾的地方。风格/命名一律放「建议」。
        2. 每条必修必须给出「位置」和「验收方式」，否则不要写进来。
        3. 拿不准的放「存疑」，不要编造。没有必修项就写「## 必修」下面留空。
        4. 不要复述 diff，不要写客套话，直接给结论和清单。
        """
    }

    /// 发给审查者的 user 内容。
    static func userPrompt(_ request: ReviewRequest) -> String {
        var parts: [String] = []

        parts.append("# 需求（唯一验收基准）\n" + (request.requirement.isEmpty ? "（未提供）" : request.requirement))

        if !request.plan.isEmpty {
            parts.append("# 开发者自己写的计划\n" + request.plan)
        }
        if !request.roundNotes.isEmpty {
            parts.append("# 开发过程中每轮的自我说明\n" + request.roundNotes.joined(separator: "\n"))
        }

        var acceptanceText = "（没有配置验收命令——**完成判定不可靠**，请重点检查功能正确性）"
        if !request.acceptance.isEmpty {
            acceptanceText = request.acceptance.map { result in
                let flag = result.ok ? "通过" : "失败"
                let baseline = result.baselineFailed ? "（开工前就是失败的）" : ""
                return "命令：\(result.command)\n结果：\(flag)\(baseline)，退出码 \(result.status)\n输出尾部：\n" +
                       Acceptance.tail(result.outputTail, limit: 1200)
            }.joined(separator: "\n\n")
        }
        parts.append("# 验收结果\n" + acceptanceText)

        if !request.diffStat.isEmpty {
            parts.append("# 改动的文件（diff --stat）\n" + request.diffStat)
        }
        var diffSection = "# 完整改动（git diff）\n"
        if request.diff.isEmpty {
            diffSection += "（没有 diff：可能没改任何文件）"
        } else {
            diffSection += request.diffTruncated
                ? "⚠️ diff 过长已截断，只给出前一部分\n\n" + request.diff
                : request.diff
        }
        parts.append(diffSection)

        if !request.deliveryReport.isEmpty {
            parts.append("# 开发者自己的交付说明（可能夸大，仅供参考）\n" + request.deliveryReport)
        }
        if !request.materialNotes.isEmpty {
            parts.append("# 材料说明（收集时的限制）\n" + request.materialNotes)
        }
        if request.checkpoint {
            parts.append("# 这次是中途检查\n只回答一个问题：**它现在的改动方向还在朝需求走吗？**\n" +
                         "如果方向已经偏了，在「必修」里明确写出来并要求纠正方向。")
        }
        return parts.joined(separator: "\n\n---\n\n")
    }

    /// 落盘的审查请求（人也能读）。
    static func markdown(_ request: ReviewRequest) -> String {
        "# 审查请求\n\n" + userPrompt(request) + "\n"
    }

    /// 把 diff 截断到设置的上限（超长时保留头部 + 标注）。
    static func truncatedDiff(_ diff: String, limit: Int) -> (text: String, truncated: Bool) {
        guard limit > 0, diff.count > limit else { return (diff, false) }
        return (String(diff.prefix(limit)), true)
    }
}

// MARK: - 审查报告

struct ReviewFinding: Equatable {
    var index: Int
    var title: String
    var body: String
    /// 从 body 里抽出来的「位置：xxx」
    var location: String
    var verification: String

    /// 变成给 codex 的修复指令（**只修这一条**）。
    static func fixPrompt(_ finding: ReviewFinding, acceptance: [String]) -> String {
        var lines: [String] = []
        lines.append("审查者发现了下面这个问题，请**只修这一条**，其它任何改动都不要做（不要顺手重构、不要改无关文件）。")
        lines.append("")
        lines.append("## \(finding.index). \(finding.title)")
        lines.append(finding.body.trimmingCharacters(in: .whitespacesAndNewlines))
        if !acceptance.isEmpty {
            lines.append("")
            lines.append("改完之后运行验收命令，确认没有把别的功能弄坏：")
            for command in acceptance { lines.append("- `\(command)`") }
        }
        lines.append("")
        lines.append("最后一行：修好了输出 DONE；如果做不到或判断这条不该修，输出 BLOCKED: <原因>。")
        return lines.joined(separator: "\n")
    }
}

struct ReviewReport: Equatable {
    var verdict = ""
    var mustFix: [ReviewFinding] = []
    var suggestions: [String] = []
    var questions: [String] = []
    var raw = ""
    var parsed = false

    var summary: String {
        guard parsed else { return "报告格式未识别，请人工阅读原文" }
        return "必修 \(mustFix.count) 项 · 建议 \(suggestions.count) 条 · 存疑 \(questions.count) 条"
    }
}

enum ReviewReportParser {
    /// 解析审查者返回的 Markdown。
    /// 宽松优先：节标题用「包含」匹配，认不出来就保留 raw、parsed=false，由人看原文。
    static func parse(_ markdown: String) -> ReviewReport {
        var report = ReviewReport()
        report.raw = markdown
        let lines = markdown.lines

        enum Section { case none, verdict, mustFix, suggestions, questions }
        var section = Section.none
        var currentTitle: String?
        var currentBody: [String] = []

        func flushFinding() {
            guard let title = currentTitle else { return }
            let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            report.mustFix.append(ReviewFinding(index: report.mustFix.count + 1,
                                                title: title,
                                                body: body,
                                                location: field("位置", in: body),
                                                verification: field("验收方式", in: body)))
            currentTitle = nil
            currentBody = []
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flushFinding()
                let heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if heading.contains("必修") { section = .mustFix }
                else if heading.contains("建议") { section = .suggestions }
                else if heading.contains("存疑") || heading.contains("需要人") { section = .questions }
                else if heading.contains("结论") { section = .verdict }
                else { section = .none }
                continue
            }
            switch section {
            case .verdict:
                if !line.isEmpty { report.verdict = line }
            case .mustFix:
                if line.hasPrefix("### ") {
                    flushFinding()
                    // 去掉「### 1. 」这类前缀
                    var title = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    if let dot = title.firstIndex(of: "."), title[title.startIndex..<dot].allSatisfy(\.isNumber) {
                        title = String(title[title.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
                    }
                    currentTitle = title.isEmpty ? "（未命名）" : title
                } else if currentTitle != nil, !line.isEmpty {
                    currentBody.append(line)
                }
            case .suggestions:
                if let item = bullet(line) { report.suggestions.append(item) }
            case .questions:
                if let item = bullet(line) { report.questions.append(item) }
            case .none:
                break
            }
        }
        flushFinding()

        report.parsed = !report.verdict.isEmpty || !report.mustFix.isEmpty
            || !report.suggestions.isEmpty || !report.questions.isEmpty
        return report
    }

    /// 从正文里抽 `- 位置：xxx` 这种字段值。
    static func field(_ name: String, in body: String) -> String {
        for rawLine in body.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let stripped = line.hasPrefix("-") ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
            for separator in ["：", ":"] {
                let prefix = name + separator
                if stripped.hasPrefix(prefix) {
                    return String(stripped.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return ""
    }

    private static func bullet(_ line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

// MARK: - 审查者客户端（OpenAI 兼容接口）

enum ReviewClient {
    /// 请求体（纯函数，方便自测）。
    static func requestBody(settings: AIReviewSettings, system: String, user: String) -> Data? {
        let payload: [String: Any] = [
            "model": settings.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.2,
            "stream": false,
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    /// 解析响应体（纯函数）：取 choices[0].message.content，失败时给出可读的报错。
    static func parseReply(_ data: Data) -> Outcome<String> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8) ?? ""
            return .failure("响应不是 JSON：\(text.prefix(300))")
        }
        if let error = root["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "未知错误"
            return .failure("审查者接口报错：\(message)")
        }
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            let text = String(data: data, encoding: .utf8) ?? ""
            return .failure("响应里没有 choices[0].message.content：\(text.prefix(300))")
        }
        return .success(content)
    }

    /// 真发请求（薄的一层，逻辑都在上面两个纯函数里）。
    static func review(settings: AIReviewSettings, request: ReviewRequest) -> Outcome<ReviewReport> {
        guard settings.isConfigured else {
            return .failure("还没配审查者：填好 baseURL / 模型名 / 密钥（默认 DeepSeek）")
        }
        guard let url = URL(string: settings.chatCompletionsURL) else {
            return .failure("baseURL 不合法：\(settings.baseURL)")
        }
        guard let body = requestBody(settings: settings, system: ReviewRequestBuilder.systemPrompt(),
                                     user: ReviewRequestBuilder.userPrompt(request)) else {
            return .failure("构造请求体失败")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = TimeInterval(max(30, settings.timeoutSeconds))
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(max(30, settings.timeoutSeconds))
        configuration.timeoutIntervalForResource = TimeInterval(max(60, settings.timeoutSeconds + 60))
        if settings.useProxy, let proxy = Self.proxyDictionary() {
            configuration.connectionProxyDictionary = proxy
        }
        let session = URLSession(configuration: configuration)

        var outcome: Outcome<String> = .failure("未执行")
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: urlRequest) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure("请求失败：\(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure("没有 HTTP 响应")
                return
            }
            let data = data ?? Data()
            guard (200..<300).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                outcome = .failure("HTTP \(http.statusCode)：\(text.prefix(300))")
                return
            }
            outcome = parseReply(data)
        }.resume()

        let deadline = TimeInterval(max(60, settings.timeoutSeconds + 60))
        if semaphore.wait(timeout: .now() + deadline) == .timedOut {
            session.invalidateAndCancel()
            return .failure("审查请求超时（\(settings.timeoutSeconds) 秒）。可以调大超时，或把「diff 上限」调小一点再试。")
        }
        // 每次审查都新建 session（配置不同），用完主动收掉，别攒着连接
        session.finishTasksAndInvalidate()

        switch outcome {
        case .failure(let message): return .failure(message)
        case .success(let content): return .success(ReviewReportParser.parse(content))
        }
    }

    /// 复用工具里那套本机代理探测（scutil --proxy）给 URLSession 用。
    static func proxyDictionary() -> [AnyHashable: Any]? {
        let config = AIProxyConfig.detect()
        var dictionary: [AnyHashable: Any] = [:]
        let httpHost = config.http.host
        if !httpHost.isEmpty, config.http.port > 0 {
            dictionary[kCFNetworkProxiesHTTPEnable] = 1
            dictionary[kCFNetworkProxiesHTTPProxy] = httpHost
            dictionary[kCFNetworkProxiesHTTPPort] = config.http.port
        }
        let httpsHost = config.https.host
        if !httpsHost.isEmpty, config.https.port > 0 {
            dictionary[kCFNetworkProxiesHTTPSEnable] = 1
            dictionary[kCFNetworkProxiesHTTPSProxy] = httpsHost
            dictionary[kCFNetworkProxiesHTTPSPort] = config.https.port
        }
        let socksHost = config.socks.host
        if !socksHost.isEmpty, config.socks.port > 0 {
            dictionary[kCFNetworkProxiesSOCKSEnable] = 1
            dictionary[kCFNetworkProxiesSOCKSProxy] = socksHost
            dictionary[kCFNetworkProxiesSOCKSPort] = config.socks.port
        }
        let exceptions = config.exceptions + ["localhost", "127.0.0.1", "::1"]
        dictionary[kCFNetworkProxiesExceptionsList] = Array(Set(exceptions)).sorted()
        return dictionary.isEmpty ? nil : dictionary
    }
}

// MARK: - 任务目录里的中间产物（.ai/）

/// 无人值守过程留下的东西统一放 `<任务目录>/.ai/`：每轮的自我说明、审查请求、审查报告。
/// 用子目录是为了不污染项目根，也方便一眼看出哪些是工具产生的。
enum AIArtifacts {
    static let directoryName = ".ai"

    static func directory(_ workDir: String) -> String { workDir + "/" + directoryName }
    static func roundsPath(_ workDir: String) -> String { directory(workDir) + "/rounds.md" }
    static func reviewRequestPath(_ workDir: String) -> String { directory(workDir) + "/review-request.md" }
    static func reviewReportPath(_ workDir: String) -> String { directory(workDir) + "/review-report.md" }

    /// 记一条「这轮它说自己做了什么」。
    /// 审查时要用：**意图 vs 实际改动的落差**最容易暴露问题（它说修了 A，diff 里改的是 B）。
    static func appendRoundNote(_ workDir: String, round: Int, note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let path = roundsPath(workDir)
        Paths.ensureDirectory(forFile: path)
        if !FileTools.exists(path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        let line = "- 第 \(round) 轮：\(Acceptance.tail(trimmed, limit: 500))\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// 读回每轮的自我说明（每行一条，已带「第 N 轮」前缀）。
    static func roundNotes(_ workDir: String) -> [String] {
        FileTools.read(roundsPath(workDir)).lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func reset(_ workDir: String) {
        try? FileManager.default.removeItem(atPath: roundsPath(workDir))
    }
}

// MARK: - 收集 git 改动

/// 审查的原料：完整 diff + 变更清单 + 未跟踪新文件的内容。
///
/// 注意 `git diff` **不包含未跟踪的新文件** —— 而"它新建了什么"恰恰最需要人看，
/// 所以未跟踪文件要单独把内容带上。
enum GitDiff {
    struct Snapshot: Equatable {
        var diff = ""
        var stat = ""
        var changedFiles: [String] = []
        var untracked: [String] = []
        var truncated = false
        var error = ""
    }

    static func collect(workDir: String, maxChars: Int) -> Snapshot {
        var snapshot = Snapshot()
        guard FileTools.isDirectory(workDir) else {
            snapshot.error = "任务目录不存在：\(workDir)"
            return snapshot
        }
        let inside = Shell.run(["git", "-C", workDir, "rev-parse", "--is-inside-work-tree"], timeout: 20)
        guard inside.ok, inside.stdout.contains("true") else {
            snapshot.error = "任务目录不是 git 仓库，拿不到 diff（审查会缺材料）"
            return snapshot
        }
        let head = Shell.run(["git", "-C", workDir, "rev-parse", "--verify", "HEAD"], timeout: 20)
        guard head.ok else {
            snapshot.error = "仓库还没有任何提交：先提交一次基线，否则无法区分「codex 改了什么」"
            return snapshot
        }

        snapshot.stat = Shell.run(["git", "-C", workDir, "diff", "--stat", "HEAD"], timeout: 60).stdout
        var text = Shell.run(["git", "-C", workDir, "diff", "HEAD"], timeout: 120).stdout

        let status = Shell.run(["git", "-C", workDir, "status", "--porcelain"], timeout: 60)
        for rawLine in status.stdout.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count > 3 else { continue }
            let path = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            snapshot.changedFiles.append(path)
            guard line.hasPrefix("?? ") else { continue }
            snapshot.untracked.append(path)
            let content = FileTools.read(workDir + "/" + path)
            guard !content.isEmpty else { continue }
            text += "\n--- 新建文件：\(path) ---\n" + Acceptance.tail(content, limit: 20_000) + "\n"
        }

        let truncated = ReviewRequestBuilder.truncatedDiff(text, limit: maxChars)
        snapshot.diff = truncated.text
        snapshot.truncated = truncated.truncated
        return snapshot
    }
}

// MARK: - 审查页状态

struct AIReviewState {
    /// 最近一次打包出来的审查请求（可以直接复制给别人看）
    var requestText = ""
    var requestPath = ""
    /// 最近一次审查报告
    var report = ReviewReport()
    var reportPath = ""
    var reviewedAt: Date?
    var error = ""
    /// 收集材料时的问题（例如不是 git 仓库、没有提交）
    var materialError = ""
    /// 修复队列进度说明
    var fixProgress = ""
}
