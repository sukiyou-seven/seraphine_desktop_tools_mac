import SwiftUI
import AppKit

/// 「云端任务」页：把 `codex cloud` 包装成界面。
///
/// 这才是「丢个需求 → 无人值守 → 拿结果」最直接的形态：
/// 任务在云端的沙箱里跑，本机可以关掉；回来只看状态、看 diff，满意就 apply 到本地仓库。
/// 和「AI 开发」页（本地 codex 看门狗）是两条互不影响的路。
///
/// 布局上有三条硬规矩（踩过坑）：
/// 1. **顶部必须有明确的高度上限**：窗口高度不够时，顶部内容不许把下面的列表顶出去；
/// 2. **不用 `HSplitView`**：它要求父容器给足高度，塞在 VStack 里会把整页撑爆导致内容看不见；
/// 3. **只读文本框必须是弹性的（`ReadonlyText(flexible: true)`），状态文本必须限宽**：
///    否则一段长 diff / 长报错会让整页的**最小尺寸**跟着内容涨，窗口被撑到屏幕外，
///    顶部那两行（派任务 + 云端环境）直接被顶出窗口上沿 —— 看着就是"东西被顶上去了"。
struct AICloudView: View {
    @EnvironmentObject var model: AppModel
    /// 云端环境配置默认收起（配好了就不用天天看它）
    @State private var showSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            submitBar
            setupBar
            mainArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .navigationTitle("云端任务")
        .onAppear {
            if model.aiCloud.loadedAt == nil { model.aiCloudRefresh() }
            if !model.settings.cloud.isConfigured { showSetup = true }
        }
    }

    // MARK: 派任务（常驻一行）

    private var submitBar: some View {
        HStack(spacing: 8) {
            TextField("丢一句需求，例如：给 Redis 页的 key 列表加「导出 CSV」", text: $model.aiCloud.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.aiCloudSubmit() }
            Button("派到云端") { model.aiCloudSubmit() }
                .disabled(model.busy != nil || !model.settings.cloud.isConfigured)
            Button {
                model.aiCloudRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.busy != nil)
            .help("刷新任务列表")
            if !model.aiCloud.message.isEmpty {
                Text(verbatim: model.aiCloud.message)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 限宽：否则一句长状态消息会把整页最小宽度撑到几千点，窗口横向被顶出屏幕。
                    .frame(maxWidth: 240, alignment: .leading)
                    .help(model.aiCloud.message)
            }
        }
    }

    // MARK: 云端环境（可折叠）

    private var setupBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showSetup.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showSetup ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text(verbatim: "云端环境").font(.callout).bold()
                    Text(verbatim: setupSummary)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !model.settings.cloud.isConfigured {
                        Text(verbatim: "必填").font(.caption).foregroundStyle(.orange)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showSetup { setupFields }

            if !model.aiCloud.error.isEmpty {
                Text(verbatim: model.aiCloud.error)
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    // 只给上限、不写死宽度：宽窗口里照样铺满，但最小宽度被钉住，
                    // 否则一段长报错会把窗口最小宽度撑到几千点，整页横向被顶出屏幕。
                    .frame(maxWidth: 900, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18)))
    }

    /// 展开时也**不许无限变高**：内容超过上限就在自己内部滚，保证列表永远看得见。
    private var setupFields: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                field("环境 ID") {
                    TextField("在终端跑 `codex cloud` 里浏览/创建", text: $model.settings.cloud.environmentID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .onSubmit { model.syncAISettings() }
                }
                field("本地仓库") {
                    HStack(spacing: 6) {
                        TextField("~/code/your-project（apply 打到这）", text: $model.settings.cloud.workDir)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .onSubmit { model.syncAISettings() }
                        Button("选择…") { pickLocalRepo() }
                    }
                }
                field("分支") {
                    TextField("留空 = 云端默认", text: $model.settings.cloud.branch)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: 200)
                        .onSubmit { model.syncAISettings() }
                }
                HStack(spacing: 8) {
                    Text("跑几次").font(.caption).foregroundStyle(.secondary)
                    TextField("1", value: $model.settings.cloud.attempts, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        .help("best-of-N：同一需求让云端跑几次，取最好的一次")
                        .onSubmit { model.syncAISettings() }
                    Text("列表条数").font(.caption).foregroundStyle(.secondary)
                    TextField("20", value: $model.settings.cloud.listLimit, formatter: NumberFormatter())
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        .onSubmit { model.syncAISettings() }
                    Spacer()
                }
                Text(verbatim: "环境就是「一份带仓库的云端沙箱」。CLI 里没有列环境的命令，所以这个 ID 要在终端跑 `codex cloud` 里看一眼。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: 190)
    }

    private var setupSummary: String {
        var parts: [String] = []
        parts.append(model.settings.cloud.isConfigured
                     ? "环境 \(model.settings.cloud.environmentID.prefix(14))"
                     : "还没配")
        if model.settings.cloud.hasWorkDir {
            parts.append("本地仓库 \((model.settings.cloud.resolvedWorkDir as NSString).lastPathComponent)")
        }
        return parts.joined(separator: " · ")
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            content()
        }
    }

    // MARK: 主体（列表 + 详情）

    private var mainArea: some View {
        Group {
            if model.aiCloud.tasks.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    // FlexibleScroll：任务列表可能几十条，普通 ScrollView 会把整页最小高度顶上去
                    FlexibleScroll {
                        LazyVStack(spacing: 0) {
                            ForEach(model.aiCloud.tasks) { task in
                                taskRow(task)
                            }
                        }
                    }
                    .frame(width: 330)

                    Divider()

                    detailPane
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18)))
    }

    private func taskRow(_ task: AICloudTask) -> some View {
        let selected = model.aiCloud.selectedID == task.id
        return Button {
            model.aiCloud.selectedID = task.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(statusColor(task.status))
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: task.displayTitle)
                        .font(.callout)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(verbatim: task.shortID)
                            .font(.system(size: 11, design: .monospaced))
                        Text(verbatim: task.status.label)
                            .font(.caption2)
                            .foregroundStyle(statusColor(task.status))
                        Text(verbatim: task.displayCreatedAt)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let task = model.aiCloud.selectedTask {
                Text(verbatim: task.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                HStack(spacing: 8) {
                    Button("刷新状态") { model.aiCloudLoadStatus() }
                        .disabled(model.busy != nil)
                    Button("看改动（diff）") { model.aiCloudLoadDiff() }
                        .disabled(model.busy != nil)
                    Button("应用到本地") { model.aiCloudApply() }
                        .disabled(model.busy != nil || !model.settings.cloud.hasWorkDir)
                        .help("把这条任务的 diff 打到「本地仓库」那个目录")
                    Button("复制任务 ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(task.id, forType: .string)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                Text(verbatim: "\(task.id)\(task.attempts > 1 ? "　best-of-\(task.attempts)" : "")\(model.aiCloud.detailKind.isEmpty ? "" : "　\(model.aiCloud.detailKind)")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                ReadonlyText(text: model.aiCloud.detail.isEmpty
                             ? "（点「刷新状态」看它跑到哪了，点「看改动」看它改了什么）"
                             : model.aiCloud.detail,
                             minHeight: 160,
                             flexible: true)
                    .padding(.horizontal, 10)
                if !task.rawJSON.isEmpty {
                    DisclosureGroup("原始 JSON") {
                        ReadonlyText(text: task.rawJSON, minHeight: 80, flexible: true)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                }
                Spacer(minLength: 0)
            } else {
                EmptyHint(text: "左边选一条任务")
            }
        }
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            EmptyHint(text: model.aiCloud.error.isEmpty
                      ? "还没有任务：上面写一句需求，点「派到云端」"
                      : "列表拉取失败，见上面的错误信息")
            if model.settings.cloud.isConfigured {
                Text(verbatim: "也可以直接在终端 `codex cloud` 里用，这个页面只是把同一套东西搬进来。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 小工具

    private func statusColor(_ status: AICloudStatus) -> Color {
        switch status {
        case .completed: return .green
        case .running: return .blue
        case .pending: return .orange
        case .failed: return .red
        case .cancelled: return .secondary
        case .unknown: return .secondary
        }
    }

    private func pickLocalRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择云端环境对应的本地仓库目录（apply 会打到这里）"
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: FileTools.isDirectory(model.settings.cloud.resolvedWorkDir)
                                 ? model.settings.cloud.resolvedWorkDir : NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.cloud.workDir = url.path
            model.syncAISettings()
        }
    }
}
