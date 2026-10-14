import SwiftUI
import AppKit

private struct SoftwareManagementAction {
    let name: String
    let id: String
    let action: String
}

/// 软件管理页的筛选条件。运行环境没有常驻服务，"运行中/已停止" 对它没有意义，因此单列一类。
private enum SoftwareManagementFilter: String, CaseIterable {
    case all = "全部"
    case running = "运行中"
    case stopped = "已停止"
    case runtime = "运行环境"
}

private struct SoftwareManagementLogSheet: Identifiable {
    let id: String
    let title: String
    let content: String
}

/// 软件管理页只做一件事：管理已经装好的软件。
/// 安装、卸载之外的"装"归软件商店，运行环境的版本归环境管理。
struct ServerServicesView: View {
    let connection: ServerConnection
    let token: String
    let openStore: () -> Void
    let openEnvironments: () -> Void

    @State private var software: [RemoteSoftware] = []
    @State private var jobs: [RemoteSoftwareJob] = []
    @State private var softwareLoadFailed = false
    @State private var pendingAction: SoftwareManagementAction?
    @State private var logSheet: SoftwareManagementLogSheet?
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false
    @State private var searchText = ""
    @State private var filter: SoftwareManagementFilter = .all

    /// 本页只关心卸载进度。安装进度属于软件商店，不在这里重复展示。
    private var uninstallJobs: [RemoteSoftwareJob] {
        jobs.filter { $0.operation == "uninstall" }
    }

    private var activeJobCount: Int {
        uninstallJobs.filter { ["queued", "uninstalling", "cancelling"].contains($0.state) }.count
    }

    private var visibleSoftware: [RemoteSoftware] {
        software.filter { item in
            let matchesSearch = searchText.isEmpty ||
                [item.name, item.version, item.installPath].contains {
                    $0.localizedStandardContains(searchText)
                }
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .running: matchesFilter = item.hasService && item.isRunning
            case .stopped: matchesFilter = item.hasService && !item.isRunning
            case .runtime: matchesFilter = item.isRuntime
            }
            return matchesSearch && matchesFilter
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("软件管理")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("去软件商店安装") { openStore() }.disabled(working)
                Button("刷新") { Task { await refresh() } }.disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            Text("只管理已经装好的软件：运行状态、开机启动、日志和卸载。安装新软件到「软件商店」，运行环境的版本到「环境管理」。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(hasError ? Color.orange : Color.secondary)
                    .lineLimit(3)
            }

            if !uninstallJobs.isEmpty {
                DisclosureGroup("卸载任务 · \(activeJobCount) 进行中") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(uninstallJobs) { job in
                            HStack(spacing: 8) {
                                Text(software.first(where: { $0.id == job.id })?.name ?? job.id)
                                    .fontWeight(.medium)
                                Text(jobStateText(job.state))
                                    .foregroundStyle(.secondary)
                                Text(verbatim: job.message).font(.caption).lineLimit(1)
                                Spacer(minLength: 0)
                                if ["queued", "uninstalling"].contains(job.state) {
                                    Button("停止任务") { Task { await cancel(job.id) } }.disabled(working)
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }

            HStack(spacing: 12) {
                TextField("搜索已安装软件", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Picker("状态", selection: $filter) {
                    ForEach(SoftwareManagementFilter.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .frame(width: 125)
                Spacer(minLength: 0)
                Text("已安装 \(software.count) 款")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            FlexibleScroll {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(visibleSoftware) { item in
                        softwareCard(item)
                    }
                    if software.isEmpty && !working && !softwareLoadFailed {
                        VStack(alignment: .leading, spacing: 10) {
                            EmptyHint(text: "这台服务器上还没有已安装的软件。")
                            Button("去软件商店安装") { openStore() }
                        }
                    } else if visibleSoftware.isEmpty && !working {
                        EmptyHint(text: "没有符合条件的软件")
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .serverManagementRefresh)) { _ in
            Task { await refresh() }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )) {
            if let pendingAction {
                if pendingAction.action == "uninstall" {
                    Button("卸载并备份原目录", role: .destructive) {
                        let selected = pendingAction
                        self.pendingAction = nil
                        perform(selected, uninstallMode: .backup)
                    }
                    Button("彻底卸载", role: .destructive) {
                        let selected = pendingAction
                        self.pendingAction = nil
                        perform(selected, uninstallMode: .purge)
                    }
                } else {
                    Button(actionLabel(pendingAction.action), role: pendingAction.action == "stop" ? .destructive : nil) {
                        let selected = pendingAction
                        self.pendingAction = nil
                        perform(selected)
                    }
                }
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: {
            if pendingAction?.action == "uninstall" {
                Text("会先停止并禁用服务。备份选项将完整安装目录移到 /www/seraphim/backup/software，仍占用磁盘空间；彻底卸载会删除目录内的程序、配置和数据。系统依赖包、下载缓存及共享日志保留。")
            }
        }
        .sheet(item: $logSheet) { sheet in
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: sheet.title).font(.headline)
                ScrollView {
                    Text(verbatim: sheet.content.isEmpty ? "暂无操作日志" : sheet.content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("关闭") { logSheet = nil }
            }
            .padding(16)
            .frame(minWidth: 650, minHeight: 400)
        }
    }

    private func softwareCard(_ item: RemoteSoftware) -> some View {
        Card(title: "\(item.name) · \(item.version)") {
            InfoRow(label: "程序目录", value: item.installPath)
            if item.hasService {
                InfoRow(label: "运行状态", value: item.runningText)
                InfoRow(label: "开机启动", value: item.enabled ? "已启用" : "未启用")
            } else {
                Text("没有常驻服务；运行环境的版本在「环境管理」中切换")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !item.message.isEmpty {
                Text(verbatim: item.message)
                    .font(.callout)
                    .foregroundStyle(item.message.hasPrefix("卸载失败") ? Color.orange : Color.secondary)
            }
            HStack(spacing: 8) {
                if item.hasService {
                    Button("启动") { select(item.id, name: item.name, action: "start") }
                        .disabled(working || item.isRunning)
                    Button("停止") { select(item.id, name: item.name, action: "stop") }
                        .disabled(working || !item.isRunning)
                    Button("重启") { select(item.id, name: item.name, action: "restart") }
                        .disabled(working)
                    Divider().frame(height: 20)
                    Button(item.enabled ? "取消开机启用" : "开机启用") {
                        select(item.id, name: item.name, action: item.enabled ? "disable" : "enable")
                    }
                    .disabled(working)
                    if !item.credentialPath.isEmpty {
                        Button("下载初始密码") { downloadInitialPassword(item) }
                            .disabled(working)
                    }
                }
                Button(item.hasService ? "日志" : "安装日志") { Task { await showLog(item) } }
                    .disabled(working)
                if !item.hasService && item.isRuntime {
                    Button("管理版本") { openEnvironments() }
                        .disabled(working)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            HStack {
                Spacer()
                Button("卸载…", role: .destructive) {
                    select(item.id, name: item.name, action: "uninstall")
                }
                .disabled(working)
            }
            .padding(.top, 6)
        }
    }

    private func select(_ id: String, name: String, action: String) {
        pendingAction = SoftwareManagementAction(name: name, id: id, action: action)
    }

    private var confirmTitle: String {
        guard let pendingAction else { return "确认操作" }
        if pendingAction.action == "uninstall" { return "卸载 \(pendingAction.name)？" }
        return "确定对 \(pendingAction.name) 执行\(actionLabel(pendingAction.action))？"
    }

    private func actionLabel(_ action: String) -> String {
        switch action {
        case "start": return "启动"
        case "stop": return "停止"
        case "restart": return "重启"
        case "enable": return "开机启用"
        case "disable": return "取消开机启用"
        case "uninstall": return "卸载"
        default: return "操作"
        }
    }

    private func jobStateText(_ state: String) -> String {
        switch state {
        case "queued": return "排队中"
        case "installing": return "安装中"
        case "uninstalling": return "卸载中"
        case "cancelling": return "停止中"
        case "cancelled": return "已停止"
        case "installed", "not_installed": return "已完成"
        default: return "失败"
        }
    }

    @MainActor private func refresh() async {
        guard !working else { return }
        guard !token.isEmpty else {
            message = "请先在「服务器状态」保存连接令牌"
            hasError = true
            return
        }
        working = true
        defer { working = false }
        do {
            software = try await ServerSoftwareAPI.list(connection: connection, token: token)
                .filter(\.isInstalled)
            softwareLoadFailed = false
        } catch {
            software = []
            softwareLoadFailed = true
            message = error.localizedDescription
            hasError = true
            return
        }
        do {
            jobs = try await ServerSoftwareAPI.jobs(connection: connection, token: token)
        } catch {
            // 任务列表拿不到不影响软件列表的使用，不再单独报错。
            jobs = []
        }
        message = ""
        hasError = false
    }

    @MainActor private func cancel(_ id: String) async {
        do {
            try await ServerSoftwareAPI.cancel(connection: connection, token: token, id: id)
            await refresh()
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }

    @MainActor private func showLog(_ item: RemoteSoftware) async {
        do {
            let content = try await ServerSoftwareAPI.log(connection: connection, token: token, id: item.id)
            logSheet = SoftwareManagementLogSheet(id: item.id, title: "\(item.name) 操作日志", content: content)
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }

    private func perform(_ selected: SoftwareManagementAction,
                         uninstallMode: RemoteSoftwareUninstallMode? = nil) {
        guard !working else { return }
        working = true
        Task {
            do {
                if let uninstallMode {
                    try await ServerSoftwareAPI.uninstall(connection: connection, token: token,
                                                          id: selected.id, mode: uninstallMode)
                } else {
                    try await ServerSoftwareAPI.service(connection: connection, token: token,
                                                        id: selected.id, action: selected.action)
                }
                working = false
                await refresh()
                if !hasError {
                    message = uninstallMode == nil
                        ? "已执行\(actionLabel(selected.action))"
                        : "卸载任务已开始，进度显示在本页上方的「卸载任务」中"
                }
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func downloadInitialPassword(_ item: RemoteSoftware) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(item.id)-initial-password.txt"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        working = true
        Task {
            do {
                try await ServerFileAPI.download(connection: connection, token: token,
                                                 remotePath: item.credentialPath, saveTo: destination)
                message = "初始密码已下载，请登录后尽快修改"
                hasError = false
            } catch {
                message = error.localizedDescription
                hasError = true
            }
            working = false
        }
    }
}
