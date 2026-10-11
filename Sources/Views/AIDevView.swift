import SwiftUI
import AppKit

/// 「AI 开发」页：把 codex CLI 当成一个无人值守的开发工人。
///
/// 页面按「任务 / 模型与权限 / 代理与环境 / 日志」分成几个标签页；
/// 运行状态和开始·停止这类主操作常驻在顶部（不跟着标签页翻走），
/// 看门狗逻辑本身在 `AIDevRunner` 里。
struct AIDevView: View {
    @EnvironmentObject var model: AppModel
    @State private var section = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            runBar

            Picker("", selection: $section) {
                Text("任务").tag(0)
                Text("模型与权限").tag(1)
                Text("代理与环境").tag(2)
                Text("审查与修复").tag(3)
                Text("日志").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                switch section {
                case 1: AIDevModelSection()
                case 2: AIDevEnvironmentSection()
                case 3: AIDevReviewSection()
                case 4: AIDevLogSection()
                default: AIDevTaskSection()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .navigationTitle("AI 开发")
        .onAppear {
            if !model.aiEnv.checked { model.aiInspectEnvironment() }
        }
    }

    // MARK: 常驻操作条

    private var runBar: some View {
        Card(title: "运行") {
            HStack(spacing: 10) {
                Button("开始执行任务") { model.aiStartTask(resume: false) }
                    .disabled(model.aiDev.running)
                Button("续跑最近会话") { model.aiStartTask(resume: true) }
                    .disabled(model.aiDev.running)
                    .help("跳过任务描述，直接 resume 该目录里最近的 codex 会话")
                Button("停止") { model.aiStopTask() }
                    .disabled(!model.aiDev.running)

                Divider().frame(height: 16)

                if model.aiDoneFlagExists {
                    Label("已标记完成", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                    Button("删除完成标记") { model.aiClearDoneFlag() }
                } else {
                    Button("标记任务完成") { model.aiMarkTaskDone() }
                        .help("在任务目录里放一个 .codex_done，看门狗下一轮开始前就会退出")
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                StatusDot(running: model.aiDev.running)
                Text(verbatim: model.aiDev.phase)
                    .font(.callout)
                if let waiting = model.aiDev.waitingUntil, model.aiDev.running {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(verbatim: "（还剩 \(AIDevRunner.durationText(waiting.timeIntervalSinceNow))）")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                if !model.aiDevMessage.isEmpty {
                    Text(verbatim: model.aiDevMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 14) {
                if model.aiDev.round > 0 {
                    Text(verbatim: "第 \(model.aiDev.round) 轮")
                }
                if let exit = model.aiDev.lastExit {
                    Text(verbatim: "上次退出码 \(exit)")
                }
                if !roundSummaryText.isEmpty {
                    Text(verbatim: roundSummaryText)
                        .lineLimit(1)
                }
                if model.aiDev.idleRounds >= 2 {
                    Text(verbatim: "连续 \(model.aiDev.idleRounds) 轮无动作")
                        .foregroundStyle(.orange)
                }
                if let resetAt = model.aiDev.resetAt {
                    Text(verbatim: "额度恢复：\(timeText(resetAt))")
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// 常驻条上那行「本轮：命令 3 次 · 改动 2 个文件 · todo 1/5」。
    private var roundSummaryText: String {
        let summary = model.aiDev.summary
        guard summary.eventCount > 0 else { return "" }
        var parts: [String] = []
        parts.append("命令 \(summary.commands) 次")
        parts.append("改动 \(summary.changedFiles.count) 个文件")
        if !summary.todos.isEmpty {
            parts.append("todo \(summary.completedTodoCount)/\(summary.todos.count)")
        }
        if summary.outputTokens > 0 {
            parts.append("输出 tokens \(summary.outputTokens)")
        }
        return "本轮：" + parts.joined(separator: " · ")
    }
}

// MARK: - 任务

private struct AIDevTaskSection: View {
    @EnvironmentObject var model: AppModel
    /// 「自动探测」出来的验收命令候选（空 = 还没探测过）
    @State private var detected: [Acceptance.Candidate] = []
    /// 探测过但什么都没探到 → 给通用例子
    @State private var showedExamples = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "任务") {
                HStack(spacing: 10) {
                    Text("任务目录").font(.callout).frame(width: 200, alignment: .leading)
                    TextField("~/code/your-project", text: $model.settings.ai.workDir)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .onSubmit { model.syncAISettings() }
                    Button("选择…") { pickDirectory() }
                    Button("打开") { aiOpen(workDir) }
                        .disabled(!model.settings.ai.hasWorkDir || !FileTools.isDirectory(workDir))
                }
                Text(verbatim: "codex 在这里读写文件；resume 也是按目录找最近的会话，所以同一个目录＝同一个任务。支持 ~ 开头的路径。")
                    .font(.caption).foregroundStyle(.secondary)

                Text(verbatim: "任务描述（新建会话时下发给 codex 的指令；续跑时不用填）")
                    .font(.callout)
                TextEditor(text: $model.settings.ai.prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25)))
                    .onChange(of: model.settings.ai.prompt) { _ in model.syncAISettings() }

                Toggle("允许在非 Git 目录里跑（加 --skip-git-repo-check）", isOn: $model.settings.ai.allowNonGit)
                    .onChange(of: model.settings.ai.allowNonGit) { _ in model.syncAISettings() }
                Toggle("用 --json 事件流统计进度（推荐）", isOn: $model.settings.ai.jsonEvents)
                    .onChange(of: model.settings.ai.jsonEvents) { _ in model.syncAISettings() }
                Text(verbatim: "打开后看门狗能知道每轮跑了多少命令、改了哪些文件、todo 完成到几分之几，并在「连续两轮没有任何实质动作」时自动收工（否则 autoContinue 会无限空转烧额度）。关掉就退回原始文本输出，一切照旧只是看不到进度。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card(title: "跑法与上限") {
                Text(verbatim: "验收命令 = 一句能自动回答「这次改动做完了没有」的命令。每跑完一轮 codex 都会执行它，全部返回 0 才算「开发完成」——模型说自己做完了不算数。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "没有现成的自动化测试也没关系：先用构建命令（如 swift build / npm run build）也能保证「没把代码写坏」。可以写多行，全部通过才算完成。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Text("验收命令").font(.callout)
                    Button("自动探测") { detectAcceptance() }
                        .disabled(!model.settings.ai.hasWorkDir)
                        .help("看任务目录里有什么测试/构建入口，给出可用的命令")
                    if !model.settings.ai.hasWorkDir {
                        Text(verbatim: "（先在「任务」页上方填任务目录）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                TextEditor(text: $model.settings.ai.acceptanceCommands)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25)))
                    .onChange(of: model.settings.ai.acceptanceCommands) { _ in model.syncAISettings() }

                if !detected.isEmpty {
                    Text(verbatim: "探测到这些（点「填入」即可）：").font(.caption).foregroundStyle(.secondary)
                    ForEach(detected, id: \.command) { candidate in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Button("填入") { use(candidate.command) }
                                .buttonStyle(.borderless)
                            Text(verbatim: candidate.command)
                                .font(.system(size: 12, design: .monospaced))
                            Text(verbatim: candidate.reason)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                } else if showedExamples {
                    Text(verbatim: "这个目录里没探测到现成的测试入口。下面是常见写法，按你的项目改一条填进去：")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Acceptance.commonExamples(), id: \.command) { example in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Button("填入") { use(example.command) }
                                .buttonStyle(.borderless)
                            Text(verbatim: example.command)
                                .font(.system(size: 12, design: .monospaced))
                            Text(verbatim: example.note)
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                }

                if Acceptance.commands(model.settings.ai.acceptanceCommands).isEmpty {
                    Label("没填验收命令：完成判定只能靠「模型说自己做完了」+ 连续无动作的启发式，可靠性明显下降；审查和逐条修复也会失去判据。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(verbatim: "开工前会先跑一次基线。如果它现在是红的也没关系（需求可能就是「让失败的测试通过」），完成判据是全部变绿；要是命令本身写错了，连续 3 轮验收结果没变化会自动停下。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("一轮正常结束（exit 0）后自动续跑", isOn: $model.settings.ai.autoContinue)
                    .onChange(of: model.settings.ai.autoContinue) { _ in model.syncAISettings() }
                Text(verbatim: "不加这个开关时，exit 0 就停下来等你决定——一次 codex 正常退出往往只是「这一轮做完了」，不代表整个任务做完。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Text("自动续跑间隔").font(.callout).frame(width: 200, alignment: .leading)
                    TextField("30", value: $model.settings.ai.continueDelay, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { model.syncAISettings() }
                    Text(verbatim: "秒（最少 5 秒）").font(.callout)
                }
                HStack(spacing: 10) {
                    Text("最多轮次").font(.callout).frame(width: 200, alignment: .leading)
                    TextField("0", value: $model.settings.ai.maxRounds, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { model.syncAISettings() }
                    Text(verbatim: "轮（0 = 不限）").font(.callout)
                }
                Text(verbatim: "碰到 5 小时用量上限时会一直等到额度恢复再自动续跑；看门狗跑在本 App 内，关掉 App 会一并把 codex 停下来。上面两个开关只限制「正常结束」和「总共跑几轮」。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var workDir: String { model.settings.ai.resolvedWorkDir }

    /// 探测任务目录里的测试/构建入口，给出可用的验收命令候选。
    private func detectAcceptance() {
        detected = Acceptance.detect(workDir: workDir)
        showedExamples = detected.isEmpty
    }

    /// 把候选**追加**进输入框（不覆盖你可能已经手写的那条）。
    private func use(_ command: String) {
        var current = Acceptance.commands(model.settings.ai.acceptanceCommands)
        guard !current.contains(command) else { return }
        current.append(command)
        model.settings.ai.acceptanceCommands = current.joined(separator: "\n")
        model.syncAISettings()
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 codex 干活的任务目录"
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: FileTools.isDirectory(workDir) ? workDir : NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.ai.workDir = url.path
            model.syncAISettings()
        }
    }
}

// MARK: - 模型与权限

private struct AIDevModelSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "模型") {
                HStack(spacing: 10) {
                    Text("模型").font(.callout).frame(width: 200, alignment: .leading)
                    Picker("", selection: $model.settings.ai.model) {
                        Text(verbatim: followConfigLabel).tag(AIModelCatalog.followConfigSlug)
                        ForEach(model.aiEnv.models, id: \.slug) { option in
                            Text(verbatim: option.label).tag(option.slug)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 320)
                    .onChange(of: model.settings.ai.model) { _ in
                        resetEffortIfNeeded()
                        model.syncAISettings()
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("推理强度").font(.callout).frame(width: 200, alignment: .leading)
                    Picker("", selection: $model.settings.ai.effort) {
                        ForEach(currentEfforts, id: \.effort) { option in
                            Text(verbatim: option.effort).tag(option.effort)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .onChange(of: model.settings.ai.effort) { _ in model.syncAISettings() }
                    Text(verbatim: currentEffortDetail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(verbatim: "模型列表来自 codex 自己（codex debug models），账号能用的模型变了这里会自动跟上；档位按所选模型实际支持的范围给。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card(title: "权限") {
                HStack(spacing: 10) {
                    Text("权限档位").font(.callout).frame(width: 200, alignment: .leading)
                    Picker("", selection: $model.settings.ai.sandbox) {
                        ForEach(AISandbox.allCases, id: \.rawValue) { sandbox in
                            Text(verbatim: sandbox.label).tag(sandbox.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                    .onChange(of: model.settings.ai.sandbox) { _ in model.syncAISettings() }
                }
                Text(verbatim: AISandbox.from(model.settings.ai.sandbox).detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                Text(verbatim: "将要执行的命令（第一轮）").font(.caption).foregroundStyle(.secondary)
                ReadonlyText(text: AICodexCommand.previewCommand(settings: model.settings.ai, resuming: false),
                             minHeight: 44)
                Text(verbatim: "实际运行时会把「<任务描述>」换成任务页里的正文；后续每轮用 `resume --last` 接着同一个会话跑。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var followConfigLabel: String {
        let configured = model.aiEnv.configuredModel
        return configured.isEmpty ? "跟随 Codex 配置" : "跟随 Codex 配置（\(configured)）"
    }

    /// 当前该显示哪些推理档位：优先用所选模型的；选了「跟随配置」就用配置里那个模型的。
    private var currentEfforts: [AIEffortOption] {
        let models = model.aiEnv.models
        if let selected = models.first(where: { $0.slug == model.settings.ai.model }), !selected.efforts.isEmpty {
            return selected.efforts
        }
        if let configured = models.first(where: { $0.slug == model.aiEnv.configuredModel }), !configured.efforts.isEmpty {
            return configured.efforts
        }
        var seen = Set<String>()
        var merged: [AIEffortOption] = []
        for item in models {
            for effort in item.efforts where !seen.contains(effort.effort) {
                seen.insert(effort.effort)
                merged.append(effort)
            }
        }
        if !merged.isEmpty { return merged }
        return AIModelCatalog.fallback().first?.efforts ?? []
    }

    private var currentEffortDetail: String {
        currentEfforts.first { $0.effort == model.settings.ai.effort }?.detail ?? "跟随模型默认档"
    }

    /// 换了模型之后，原来的档位可能不被支持（比如某模型没有 ultra），落回它的默认档。
    private func resetEffortIfNeeded() {
        let efforts = currentEfforts.map(\.effort)
        let chosen = model.settings.ai.effort
        guard !efforts.isEmpty, !chosen.isEmpty else { return }
        if !efforts.contains(chosen) {
            let fallback = model.aiEnv.models.first { $0.slug == model.settings.ai.model }?.resolvedDefaultEffort
            model.settings.ai.effort = fallback.flatMap { efforts.contains($0) ? $0 : nil } ?? efforts[0]
        }
    }
}

// MARK: - 代理与环境

private struct AIDevEnvironmentSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "本机代理") {
                Toggle("使用本机代理（注入 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY 给 codex）",
                       isOn: $model.settings.ai.useProxy)
                    .onChange(of: model.settings.ai.useProxy) { _ in model.syncAISettings() }

                InfoRow(label: "探测到的代理", value: model.aiEnv.proxy.summary)
                InfoRow(label: "例外（NO_PROXY）", value: model.aiEnv.proxy.exceptions.joined(separator: ", "))

                HStack(spacing: 10) {
                    Text("手动覆盖").font(.callout).frame(width: 200, alignment: .leading)
                    TextField("留空 = 用上面探测到的本机代理，例如 127.0.0.1:10809", text: $model.settings.ai.proxyOverride)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .onSubmit { model.syncAISettings() }
                    Button("重新探测") { model.aiInspectEnvironment() }
                }

                if model.settings.ai.useProxy {
                    Text(verbatim: "本次会注入：" + proxyEnvPreview)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(verbatim: "已关闭：会把继承来的代理变量从 codex 的环境里摘掉，走直连。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Card(title: "运行环境") {
                InfoRow(label: "codex", value: model.aiEnv.codexPath)
                InfoRow(label: "版本", value: model.aiEnv.version)
                InfoRow(label: "登录状态", value: model.aiEnv.checked
                        ? (model.aiEnv.loggedIn ? "已登录（复用 ~/.codex 的登录态）" : "未登录：先在终端跑 codex login")
                        : "检测中…")
                InfoRow(label: "Codex 配置的模型", value: configModelText)
                InfoRow(label: "模型列表", value: model.aiEnv.checked
                        ? "\(model.aiEnv.models.count) 个（来源：\(model.aiEnv.modelsSource)）" : "检测中…")
                HStack {
                    Button("重新检测") { model.aiInspectEnvironment() }
                    Button("打开 ~/.codex 目录") {
                        aiOpen(NSHomeDirectory() + "/.codex")
                    }
                    Text(verbatim: "模型列表来自 codex 自己（codex debug models），读不到时退回 ~/.codex/models_cache.json，再退回内置列表。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var configModelText: String {
        guard !model.aiEnv.configuredModel.isEmpty else { return "未配置（用 codex 的默认模型）" }
        let effort = model.aiEnv.configuredEffort
        return effort.isEmpty ? model.aiEnv.configuredModel : "\(model.aiEnv.configuredModel)（推理强度 \(effort)）"
    }

    private var proxyEnvPreview: String {
        let env = model.aiEnv.proxy.environment(override: model.settings.ai.proxyOverride)
        if env.isEmpty { return "（本机没检测到代理，等于直连）" }
        return env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "　")
    }
}

// MARK: - 审查与修复

/// 「开发完之后请另一位模型整体复核一次」——审查者不参与开发，只输出必修复清单，
/// 修不修由人决定；确认要修就逐条驱动 codex 修，每条修完跑验收。
private struct AIDevReviewSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            reviewerCard
            reviewCard
            fixCard
        }
    }

    private var reviewerCard: some View {
        Card(title: "审查者（独立于 codex 的另一位模型）") {
            Text(verbatim: "开发跑完之后请它整体复核一次，只产出「必修复清单」。它不碰代码，只给判断。密钥明文保存在工具的设置文件里（和工具里其它凭据一致）。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text("接口地址").font(.callout).frame(width: 200, alignment: .leading)
                TextField("https://api.deepseek.com", text: $model.settings.review.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit { model.syncAISettings() }
            }
            HStack(spacing: 10) {
                Text("模型").font(.callout).frame(width: 200, alignment: .leading)
                TextField("deepseek-v4-flash", text: $model.settings.review.model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit { model.syncAISettings() }
            }
            HStack(spacing: 10) {
                Text("API 密钥").font(.callout).frame(width: 200, alignment: .leading)
                SecureField("sk-…", text: $model.settings.review.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit { model.syncAISettings() }
                Text(verbatim: model.settings.review.isConfigured ? "已配置" : "还没配好")
                    .font(.caption)
                    .foregroundStyle(model.settings.review.isConfigured ? Color.green : Color.orange)
            }
            HStack(spacing: 10) {
                Toggle("走本机代理", isOn: $model.settings.review.useProxy)
                    .onChange(of: model.settings.review.useProxy) { _ in model.syncAISettings() }
                Text("diff 上限").font(.callout)
                TextField("60000", value: $model.settings.review.maxDiffChars, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit { model.syncAISettings() }
                Text("字符").font(.callout)
                Text("超时").font(.callout)
                TextField("600", value: $model.settings.review.timeoutSeconds, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { model.syncAISettings() }
                Text("秒").font(.callout)
            }
            Text(verbatim: "实际请求地址：" + model.settings.review.chatCompletionsURL)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var reviewCard: some View {
        Card(title: "审查") {
            HStack(spacing: 10) {
                Button("只打包材料") { model.aiPrepareReview() }
                    .disabled(model.busy != nil || !model.settings.ai.hasWorkDir)
                    .help("生成 .ai/review-request.md，先自己看材料齐不齐（不调用审查者）")
                Button("让 \(model.settings.review.model) 审查") { model.aiRunReview() }
                    .disabled(model.busy != nil || !model.settings.ai.hasWorkDir)
                if let reviewedAt = model.aiReview.reviewedAt {
                    Text(verbatim: "上次审查：\(timeText(reviewedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !model.settings.ai.hasWorkDir {
                Label("先在「任务」页填任务目录", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !model.aiReview.materialError.isEmpty {
                Text(verbatim: "材料说明：" + model.aiReview.materialError)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.aiReview.error.isEmpty {
                Text(verbatim: model.aiReview.error)
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            InfoRow(label: "审查请求", value: model.aiReview.requestPath)
            InfoRow(label: "审查报告", value: model.aiReview.reportPath)
            HStack {
                Button("打开审查请求") { aiOpen(model.aiReview.requestPath) }
                    .disabled(model.aiReview.requestPath.isEmpty)
                Button("打开审查报告") { aiOpen(model.aiReview.reportPath) }
                    .disabled(model.aiReview.reportPath.isEmpty)
                Text(verbatim: "报告原文也贴在下面：万一它的格式没被识别，直接读原文。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.aiReview.report.parsed {
                Divider()
                Text(verbatim: "结论：" + (model.aiReview.report.verdict.isEmpty ? "（未给出）" : model.aiReview.report.verdict))
                    .font(.callout)
                Text(verbatim: model.aiReview.report.summary)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.aiReview.report.raw.isEmpty {
                ReadonlyText(text: model.aiReview.report.raw, minHeight: 240)
            }
        }
    }

    private var fixCard: some View {
        Card(title: "必修项（逐条修）") {
            if model.aiReview.report.mustFix.isEmpty {
                Text(verbatim: "还没有必修项：先跑一次审查。如果审查者认为可以直接交付，这里就是空的。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Button("按报告逐条修复") { model.aiStartFixQueue() }
                        .disabled(model.aiDev.running || model.busy != nil)
                    if model.aiDev.fixQueueTotal > 0 {
                        Text(verbatim: "进度 \(model.aiDev.fixQueueIndex)/\(model.aiDev.fixQueueTotal)"
                             + (model.aiDev.currentFinding.isEmpty ? "" : "　当前：\(model.aiDev.currentFinding)"))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                Text(verbatim: "每轮只修一条（范围小、成功率高、失败能精确定位），改完跑验收命令，通过才进入下一条；某条连续两轮都修不好就停下等你。所以「任务」页必须填验收命令。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                ForEach(model.aiReview.report.mustFix, id: \.index) { finding in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "\(finding.index). \(finding.title)")
                            .font(.callout).bold()
                        if !finding.location.isEmpty {
                            Text(verbatim: "位置：" + finding.location)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: finding.body)
                            .font(.system(size: 12, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// MARK: - 日志

private struct AIDevLogSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "本轮进度（来自 --json 事件流）") {
                if summary.eventCount == 0 {
                    Text(verbatim: model.settings.ai.jsonEvents
                         ? "还没收到事件：任务还没开始跑，或者这一轮还没产生任何事件。"
                         : "已关闭 --json 事件流，看不到结构化进度；打开它就能看到命令数、改动文件和 todo 完成度。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    InfoRow(label: "命令执行", value: "\(summary.commands) 次")
                    InfoRow(label: "改动文件",
                            value: summary.changedFiles.isEmpty ? "无" : summary.changedFiles.joined(separator: "、"))
                    if !summary.todos.isEmpty {
                        InfoRow(label: "todo 完成度", value: "\(summary.completedTodoCount)/\(summary.todos.count)")
                        ForEach(Array(summary.todos.enumerated()), id: \.offset) { _, todo in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(todo.completed ? Color.green : Color.secondary)
                                Text(verbatim: todo.text)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    InfoRow(label: "token", value: "输入 \(summary.inputTokens) / 输出 \(summary.outputTokens)")
                    InfoRow(label: "本轮结论", value: summary.turnFailed
                            ? "失败：\(summary.errorMessage.isEmpty ? "（没有错误信息）" : summary.errorMessage)"
                            : (summary.turnCompleted ? "正常结束" : "—"))
                    if !summary.hasSubstantiveAction {
                        Label("本轮没有任何命令执行或文件改动（模型可能已经认为做完了）",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Card(title: "日志") {
                InfoRow(label: "日志文件", value: model.settings.ai.hasWorkDir
                        ? workDir + "/" + AIDevRunner.logFileName
                        : model.aiDev.logPath)
                HStack {
                    Button("打开日志文件") { aiOpen(logFilePath) }
                        .disabled(!FileTools.exists(logFilePath))
                    Button("打开任务目录") { aiOpen(workDir) }
                        .disabled(!model.settings.ai.hasWorkDir || !FileTools.isDirectory(workDir))
                    Text(verbatim: "codex 的完整输出都写在这个文件里；下面只显示最后几百行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ReadonlyText(text: model.aiDev.logTail, minHeight: 460)
            }
        }
    }

    private var summary: CodexRoundSummary { model.aiDev.summary }

    private var workDir: String { model.settings.ai.resolvedWorkDir }

    private var logFilePath: String {
        model.aiDev.logPath.isEmpty ? workDir + "/" + AIDevRunner.logFileName : model.aiDev.logPath
    }
}

// MARK: - 小工具

private func aiOpen(_ path: String) {
    guard !path.isEmpty else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}
