import SwiftUI
import AppKit

/// 项目详情与启动自检。
///
/// 以前「启动失败」只有四个字，用户只能自己上服务器翻日志。这里把服务端算好的
/// 自检清单、运行信息、依赖状态和日志放在一屏，能一键修的给出按钮。
struct ProjectDetailSheet: View {
    let connection: ServerConnection
    let token: String
    let project: RemoteProject
    /// 需要页面级动作（编辑项目、打开目录、去环境管理）时回调。
    var onPageAction: (String) -> Void
    /// 项目状态有变化时通知页面刷新列表。
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var detail: RemoteProjectDetail?
    @State private var logText = ""
    @State private var journalText = ""
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false
    @State private var follow = true

    private var current: RemoteProject { detail?.project ?? project }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(hasError ? Color.orange : Color.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    checksSection
                    runtimeSection
                    variableSection
                    dependencySection
                    logSection
                }
            }
        }
        .padding(18)
        .frame(minWidth: 780, minHeight: 640)
        .task { await reload() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            guard follow, !working, detail != nil else { return }
            Task { await reload() }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Text(current.name).font(.title3.weight(.semibold))
            Text(current.stateText)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(stateColor.opacity(0.16)))
                .foregroundStyle(stateColor)
            if current.enabled { Text("开机启动").font(.caption).foregroundStyle(.secondary) }
            if current.restarting || (!current.running && current.failed) {
                Text(current.failureSummary ?? "")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Button("刷新") { Task { await reload() } }.disabled(working)
            Button("关闭") { dismiss() }
        }
    }

    private var stateColor: Color {
        if current.restarting || (!current.running && current.failed) { return .orange }
        return current.running ? .green : .secondary
    }

    // MARK: - 自检清单

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("启动自检").font(.headline)
            if detail == nil {
                Text("正在检查…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(detail?.checks ?? []) { check in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: check))
                        .foregroundStyle(color(for: check))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.label).font(.callout)
                        if let detail = check.detail, !detail.isEmpty {
                            Text(verbatim: detail)
                                .font(.caption)
                                .foregroundStyle(check.isOK ? Color.secondary : Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let hint = check.hint, !hint.isEmpty {
                            Text(verbatim: hint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if let label = actionLabel(check.action) {
                        Button(label) { run(check.action ?? "") }.disabled(working)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.18)))
    }

    private func icon(for check: RemoteProjectCheck) -> String {
        if check.isOK { return "checkmark.circle.fill" }
        return check.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    private func color(for check: RemoteProjectCheck) -> Color {
        if check.isOK { return .green }
        return check.isError ? .red : .orange
    }

    private func actionLabel(_ action: String?) -> String? {
        switch action {
        case "deps": return "安装依赖"
        case "venv": return "创建虚拟环境"
        case "server": return current.serverLabel.map { "安装 \($0)" } ?? "安装启动器"
        case "edit": return "编辑项目"
        case "files": return "打开目录"
        case "runtime": return "环境管理"
        case "variables": return "环境变量管理"
        default: return nil
        }
    }

    // MARK: - 运行信息

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("运行信息").font(.headline)
            InfoRow(label: "systemd 状态", value: "\(current.activeState)\(subStateText)")
            InfoRow(label: "PID", value: current.mainPid.map(String.init) ?? "")
            InfoRow(label: "内存占用", value: current.memoryText ?? "")
            InfoRow(label: "已运行", value: current.uptimeText ?? "")
            InfoRow(label: "重启次数", value: current.restarts.map(String.init) ?? "0")
            InfoRow(label: "上次结果", value: resultText)
            InfoRow(label: "监听端口", value: current.port > 0
                    ? "127.0.0.1:\(current.port)\(current.portBusy == true ? "（已被其他进程占用）" : "")" : "")
            InfoRow(label: "工程目录", value: current.directory)
            InfoRow(label: "启动命令", value: startupDescription)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.18)))
    }

    private var subStateText: String {
        guard let sub = current.subState, !sub.isEmpty, sub != "dead" else { return "" }
        if sub == "auto-restart" { return " · 正在自动重启" }
        return " · \(sub)"
    }

    private var resultText: String {
        var parts: [String] = []
        if let result = current.result, !result.isEmpty { parts.append(result) }
        if let code = current.exitStatus, code > 0 { parts.append("退出码 \(code)") }
        return parts.joined(separator: " · ")
    }

    private var startupDescription: String {
        guard current.runtime == "python" else { return current.entry }
        if let server = current.serverLabel, server != "直接运行" {
            return "\(server) · \(current.pythonCallable ?? "app") · \(current.pythonWorkers ?? 2) 进程"
        }
        return "直接运行 \(current.entry)"
    }

    // MARK: - 环境变量

    /// 回答「我设的 XXX 到底生效了吗」：把加载来的和项目自己填的分开列，
    /// 同名的标出被项目覆盖，免得用户以为变量没生效而反复保存。
    private var variableSection: some View {
        let inherited = detail?.globalVariables ?? []
        let own = current.envEntries
        let overridden = Set(own.map { $0.name })
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("环境变量").font(.headline)
                Spacer()
                Button("环境变量管理…") { run("variables") }.disabled(working)
            }
            if !current.inheritsGlobalEnv {
                Text("这个项目没有加载面板那份公用变量（默认不加载），只用下面项目自己的值。代码也可以直接读服务器上的共用文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !inherited.isEmpty {
                rows(label: "面板", entries: inherited.map {
                    ($0.name, overridden.contains($0.name) ? "\($0.value)　（被项目覆盖）" : $0.value)
                })
            }
            if !own.isEmpty {
                rows(label: "项目", entries: own.map { ($0.name, $0.value) })
            }
            if current.envFile == true {
                Text(verbatim: "另有工程目录下的 .env 文件会被进程加载（它最后加载，同名以 .env 里的值为准）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if inherited.isEmpty && own.isEmpty && current.envFile != true {
                Text("没有自定义环境变量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if current.port > 0 {
                Text(verbatim: "PORT=\(current.port) 由面板按项目写入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.18)))
    }

    private func rows(label: String, entries: [(String, String)]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries, id: \.0) { entry in
                    Text(verbatim: "\(entry.0)=\(entry.1)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }

    // MARK: - 依赖

    private var dependencySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("项目依赖").font(.headline)
            if let dependency = detail?.dependency {
                HStack(spacing: 8) {
                    Text(dependency.title)
                        .font(.system(.callout, design: .monospaced))
                    Text(dependency.summary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if dependency.present, !dependency.installed, let command = dependency.command {
                        Button("安装依赖（\(command)）") { run("deps") }.disabled(working)
                    }
                }
                if (dependency.present && !dependency.installed) && current.running {
                    Text("安装依赖前需要先停止项目。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("正在读取…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.18)))
    }

    // MARK: - 日志

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("项目日志").font(.headline)
                Toggle("自动刷新", isOn: $follow).toggleStyle(.checkbox)
                Spacer()
                Button("刷新") { Task { await reload() } }.disabled(working)
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                    message = "日志已复制"
                    hasError = false
                }
                .disabled(logText.isEmpty)
                Button("清空…") { clear() }.disabled(working || logText.isEmpty)
            }
            ScrollView {
                Text(verbatim: logText.isEmpty ? "暂无日志" : logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 240)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
            if !journalText.isEmpty {
                Text("系统日志（systemd）").font(.headline)
                ScrollView {
                    Text(verbatim: journalText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
                Text("进程还没起来就退出时，项目日志是空的，原因只在系统日志里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.18)))
    }

    // MARK: - 动作

    @MainActor private func reload() async {
        do {
            let result = try await ServerProjectAPI.status(connection: connection, token: token, id: project.id)
            detail = result
            logText = result.log
            journalText = result.journal ?? ""
            hasError = false
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }

    private func clear() {
        working = true
        Task { @MainActor in
            do {
                try await ServerProjectAPI.clearLog(connection: connection, token: token, id: project.id)
                working = false
                await reload()
                message = "日志已清空"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func run(_ action: String) {
        switch action {
        case "edit", "files", "runtime", "variables":
            dismiss()
            // 必须等这次消失落地再切页面/开编辑框：父视图的 sheet 绑定会被
            // dismiss 顺手清成 nil，紧接着设置的 sheet 会被一起清掉。
            DispatchQueue.main.async { onPageAction(action) }
        case "deps", "venv", "server":
            perform(action)
        default:
            break
        }
    }

    private func perform(_ action: String) {
        working = true
        Task { @MainActor in
            do {
                switch action {
                case "deps":
                    try await ServerProjectAPI.installDependencies(connection: connection, token: token, id: project.id)
                    message = "依赖安装完成"
                case "venv":
                    try await ServerProjectAPI.venv(connection: connection, token: token, id: project.id, action: "create")
                    message = "虚拟环境已创建"
                default:
                    try await ServerProjectAPI.venv(connection: connection, token: token, id: project.id, action: "install_server")
                    message = "启动器已安装"
                }
                working = false
                hasError = false
                await reload()
                onChanged()
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
                await reload()
                onChanged()
            }
        }
    }
}
