import SwiftUI
import AppKit

private struct EnvironmentLogSheet: Identifiable {
    let id: String
    let title: String
    let content: String
}

struct ServerEnvironmentsView: View {
    let connection: ServerConnection
    let token: String
    let openFiles: (String) -> Void

    @State private var items: [RemoteEnvironment] = []
    @State private var checkedTools: [String: [RemoteEnvironmentTool]] = [:]
    @State private var expandedInstallations: Set<String> = []
    @State private var releaseVersions: [String: [String]] = [:]
    @State private var releaseErrors: [String: String] = [:]
    @State private var loadingVersions: Set<String> = []
    @State private var selectedVersions: [String: String] = [:]
    @State private var pendingAction: (id: String, action: String, version: String?)?
    @State private var logSheet: EnvironmentLogSheet?
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false

    private var installedCount: Int { items.filter(\.installed).count }
    private var installedVersionCount: Int {
        items.reduce(0) { $0 + $1.displayInstallations.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("环境管理").font(.title3.weight(.semibold))
                Spacer()
                Text("已安装 \(installedCount) 类 · \(installedVersionCount) 个版本")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("刷新") { Task { await refresh(releases: true) } }.disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            Text("从发布源获取可安装版本。各版本独立存放，安装后可逐个验证、使用或卸载。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(hasError ? Color.orange : Color.secondary)
                    .lineLimit(3)
            }
            FlexibleScroll {
                VStack(alignment: .leading, spacing: 10) {
                    if items.isEmpty && !working { EmptyHint(text: "尚未获取运行环境列表") }
                    ForEach(items) { item in environmentCard(item) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { Task { await refresh() } }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            if items.contains(where: { $0.state == "installing" || $0.state == "uninstalling" }) && !working {
                Task { await refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .serverManagementRefresh)) { _ in
            Task { await refresh() }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
        )) {
            if let pendingAction {
                if pendingAction.action == "uninstall" || pendingAction.action == "uninstallVersion" {
                    Button("卸载并备份原目录", role: .destructive) {
                        let id = pendingAction.id
                        self.pendingAction = nil
                        perform(id: id, action: "backup", version: pendingAction.version)
                    }
                    Button("彻底卸载", role: .destructive) {
                        let id = pendingAction.id
                        self.pendingAction = nil
                        perform(id: id, action: "purge", version: pendingAction.version)
                    }
                } else {
                    Button("安装") {
                        let id = pendingAction.id
                        let version = pendingAction.version
                        self.pendingAction = nil
                        perform(id: id, action: "install", version: version)
                    }
                }
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: {
            if pendingAction?.action == "uninstall" || pendingAction?.action == "uninstallVersion" {
                Text("卸载运行环境可能使依赖它的项目无法启动。备份会保留完整安装目录并继续占用磁盘；彻底卸载会删除该目录。")
            } else {
                Text("所选版本会安装在独立目录，不会覆盖已有版本，也不会自动加入系统 PATH。")
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

    private func environmentCard(_ item: RemoteEnvironment) -> some View {
        Card(title: item.name) {
            let installedVersions = Set(item.displayInstallations.map(\.version))
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.stateText)
                    .foregroundStyle(item.installed ? Color.green : Color.secondary)
                if item.installed { Text("已安装 \(item.displayInstallations.count) 个版本").foregroundStyle(.secondary) }
                if item.hasService && item.installed {
                    Text(item.running ? "PHP-FPM 运行中" : "PHP-FPM 已停止")
                        .foregroundStyle(.secondary)
                }
                if !item.supported && !item.installed {
                    Text("当前系统不支持安装")
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let versions = releaseVersions[item.id], !versions.isEmpty {
                    Picker("安装版本", selection: Binding(
                        get: { selectedVersions[item.id] ?? versions[0] },
                        set: { selectedVersions[item.id] = $0 }
                    )) {
                        ForEach(versions, id: \.self) { version in
                            Text(verbatim: installedVersions.contains(version) ? "\(version) · 已安装" : version)
                                .tag(version)
                        }
                    }
                    .frame(width: 190)
                    .disabled(working || !item.supported)
                    let selectedVersion = selectedVersions[item.id] ?? versions[0]
                    Button(installedVersions.contains(selectedVersion) ? "已安装" : "安装") {
                        pendingAction = (item.id, "install", selectedVersions[item.id] ?? versions[0])
                    }
                    .disabled(working || !item.supported || installedVersions.contains(selectedVersion)
                              || item.state == "installing" || item.state == "uninstalling")
                } else {
                    Text(releaseErrors[item.id] ?? "正在获取发布版本…")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("重试") { Task { await loadVersions(item.id, force: true) } }
                        .disabled(working || loadingVersions.contains(item.id))
                }
                Button("日志") { Task { await showLog(item) } }
                    .disabled(working || item.state == "not_installed")
            }
            ForEach(item.displayInstallations) { installation in
                installationRow(item, installation: installation)
            }
            if !item.message.isEmpty && item.message != "安装完成" {
                Text(verbatim: item.message)
                    .font(.caption)
                    .foregroundStyle(item.state == "failed" || item.state == "needs_attention" ? Color.orange : Color.secondary)
            }
        }
        .task(id: item.id) { await loadVersions(item.id) }
    }

    private func installationRow(_ item: RemoteEnvironment, installation: RemoteEnvironmentInstallation) -> some View {
        let expanded = expandedInstallations.contains(installation.path)
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 10) {
                Text(verbatim: installation.version).fontWeight(.medium)
                if installation.legacy {
                    Text("旧版路径").font(.caption).foregroundStyle(.secondary)
                }
                if item.hasService {
                    let running = installation.legacy ? item.running : installation.serviceState == "active"
                    Text(running ? "FPM 运行中" : "FPM 已停止")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("验证") { Task { await check(item, installation: installation) } }
                    .disabled(working)
                Button(expanded ? "收起" : "详情") {
                    if expanded {
                        expandedInstallations.remove(installation.path)
                    } else {
                        expandedInstallations.insert(installation.path)
                    }
                }
                Menu("更多") {
                    Button("打开目录") { openFiles(installation.path) }
                    Button("复制路径") { copyPath(installation.path) }
                    if item.hasService {
                        Divider()
                        let running = installation.legacy ? item.running : installation.serviceState == "active"
                        Button(running ? "停止 FPM" : "启动 FPM") {
                            if installation.legacy {
                                service(item, action: running ? "stop" : "start")
                            } else {
                                serviceVersion(item, installation: installation, action: running ? "stop" : "start")
                            }
                        }
                    }
                    Divider()
                    Button("卸载…", role: .destructive) {
                        pendingAction = (item.id, installation.legacy ? "uninstall" : "uninstallVersion", installation.legacy ? nil : installation.version)
                    }
                }
                .disabled(working)
            }
            if expanded {
                InfoRow(label: "安装目录", value: installation.path)
                ForEach(checkedTools[installation.path] ?? installation.tools) { tool in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(tool.name).fontWeight(.medium)
                            Text(verbatim: tool.version.isEmpty ? (tool.available ? "可执行文件存在" : "文件缺失") : tool.version)
                                .foregroundStyle(tool.available ? Color.secondary : Color.orange)
                        }
                        Text(verbatim: tool.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !tool.error.isEmpty {
                            Text(verbatim: tool.error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var confirmTitle: String {
        guard let pendingAction else { return "确认操作" }
        let name = items.first(where: { $0.id == pendingAction.id })?.name ?? pendingAction.id
        return pendingAction.action == "uninstall" || pendingAction.action == "uninstallVersion"
            ? "卸载 \(name) \(pendingAction.version ?? "")？" : "安装 \(name) \(pendingAction.version ?? "")？"
    }

    @MainActor private func refresh(releases: Bool = false) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            items = try await ServerEnvironmentAPI.list(connection: connection, token: token)
            if releases {
                releaseVersions.removeAll()
                releaseErrors.removeAll()
                for id in items.map(\.id) { Task { await loadVersions(id, force: true) } }
            }
            let activePaths = Set(items.flatMap { $0.displayInstallations.map(\.path) })
            checkedTools = checkedTools.filter { activePaths.contains($0.key) }
            expandedInstallations.formIntersection(activePaths)
            message = ""
            hasError = false
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }

    @MainActor private func loadVersions(_ id: String, force: Bool = false) async {
        if loadingVersions.contains(id) || (!force && releaseVersions[id] != nil) { return }
        loadingVersions.insert(id)
        defer { loadingVersions.remove(id) }
        do {
            let versions = try await ServerEnvironmentAPI.versions(connection: connection, token: token, id: id)
            releaseVersions[id] = versions
            releaseErrors[id] = nil
            if let selected = selectedVersions[id], versions.contains(selected) { return }
            selectedVersions[id] = versions.first
        } catch {
            releaseErrors[id] = error.localizedDescription
        }
    }

    @MainActor private func check(_ item: RemoteEnvironment, installation: RemoteEnvironmentInstallation) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let tools: [RemoteEnvironmentTool]
            if installation.legacy {
                tools = try await ServerEnvironmentAPI.check(connection: connection, token: token, id: item.id).tools
            } else {
                tools = try await ServerEnvironmentAPI.checkVersion(connection: connection, token: token,
                                                                    id: item.id, version: installation.version).tools
            }
            checkedTools[installation.path] = tools
            expandedInstallations.insert(installation.path)
            let failures = tools.filter { !$0.error.isEmpty }
            message = failures.isEmpty ? "\(item.name) \(installation.version) 验证通过" : "\(item.name) 有 \(failures.count) 个工具验证失败"
            hasError = !failures.isEmpty
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }

    private func perform(id: String, action: String, version: String? = nil) {
        guard !working else { return }
        working = true
        Task { @MainActor in
            do {
                if action == "install" {
                    guard let version else { throw ServerEnvironmentError.invalidResponse }
                    try await ServerEnvironmentAPI.install(connection: connection, token: token,
                                                           id: id, version: version)
                } else if let version {
                    try await ServerEnvironmentAPI.uninstall(connection: connection, token: token,
                                                             id: id, version: version,
                                                             mode: action == "backup" ? "backup" : "purge")
                } else {
                    try await ServerSoftwareAPI.uninstall(connection: connection, token: token,
                                                          id: id, mode: action == "backup" ? .backup : .purge)
                }
                checkedTools.removeAll()
                working = false
                await refresh()
                message = action == "install" ? "安装任务已开始" : "卸载任务已开始"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func service(_ item: RemoteEnvironment, action: String) {
        guard !working else { return }
        working = true
        Task { @MainActor in
            do {
                try await ServerSoftwareAPI.service(connection: connection, token: token,
                                                    id: item.id, action: action)
                working = false
                await refresh()
                message = action == "start" ? "PHP-FPM 已启动" : "PHP-FPM 已停止"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func serviceVersion(_ item: RemoteEnvironment, installation: RemoteEnvironmentInstallation,
                                action: String) {
        guard !working else { return }
        working = true
        Task { @MainActor in
            do {
                try await ServerEnvironmentAPI.serviceVersion(connection: connection, token: token,
                                                              id: item.id, version: installation.version,
                                                              action: action)
                working = false
                await refresh()
                message = action == "start" ? "PHP-FPM 已启动" : "PHP-FPM 已停止"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    @MainActor private func showLog(_ item: RemoteEnvironment) async {
        do {
            let content = try await ServerSoftwareAPI.log(connection: connection, token: token, id: item.id)
            logSheet = EnvironmentLogSheet(id: item.id, title: "\(item.name) 操作日志", content: content)
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        message = "安装目录已复制"
        hasError = false
    }
}
