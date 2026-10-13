import SwiftUI

private struct SoftwareLogSheet: Identifiable {
    let id: String
    let title: String
    let content: String
}

private enum SoftwareStoreFilter: String, CaseIterable {
    case all = "全部"
    case available = "可安装"
    case installed = "已安装"
}

struct ServerSoftwareStoreView: View {
    let connection: ServerConnection
    let token: String

    @State private var items: [RemoteSoftware] = []
    @State private var jobs: [RemoteSoftwareJob] = []
    @State private var pendingAction: (id: String, action: String)?
    @State private var logSheet: SoftwareLogSheet?
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false
    @State private var searchText = ""
    @State private var filter: SoftwareStoreFilter = .all
    @State private var selectedCategory = "全部分类"

    private var categories: [String] {
        items.reduce(into: ["全部分类"]) { result, item in
            if !result.contains(item.categoryText) { result.append(item.categoryText) }
        }
    }

    private var visibleItems: [RemoteSoftware] {
        items.filter { item in
            let matchesSearch = searchText.isEmpty ||
                [item.name, item.version, item.description, item.categoryText].contains {
                    $0.localizedStandardContains(searchText)
                }
            let matchesCategory = selectedCategory == "全部分类" || item.categoryText == selectedCategory
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .available: matchesFilter = item.canInstall && item.supported &&
                (item.state == "not_installed" || item.state == "failed" || item.state == "cancelled")
            case .installed: matchesFilter = item.isInstalled
            }
            return matchesSearch && matchesCategory && matchesFilter
        }
    }

    private var visibleCategories: [String] {
        categories.dropFirst().filter { category in
            visibleItems.contains { $0.categoryText == category }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("软件商店")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("刷新") { Task { await refresh() } }.disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            Text("浏览、安装和卸载软件；常用运行操作可直接使用，开机启动等设置在「软件管理」。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(hasError ? Color.orange : Color.secondary)
                    .lineLimit(3)
            }

            if !jobs.isEmpty {
                DisclosureGroup("任务列表 · \(jobs.filter { ["queued", "installing", "uninstalling", "cancelling"].contains($0.state) }.count) 进行中") {
                    ForEach(jobs) { job in
                        HStack {
                            Text(items.first(where: { $0.id == job.id })?.name ?? job.id).fontWeight(.medium)
                            Text(job.operation == "install" ? "安装" : "卸载")
                            Text(job.state == "queued" ? "排队中" : job.state == "installing" ? "安装中" : job.state == "uninstalling" ? "卸载中" : job.state == "cancelling" ? "停止中" : job.state == "cancelled" ? "已停止" : job.state == "installed" || job.state == "not_installed" ? "已完成" : "失败")
                                .foregroundStyle(.secondary)
                            Text(verbatim: job.message).font(.caption).lineLimit(1)
                            Spacer()
                            if ["queued", "installing", "uninstalling"].contains(job.state) {
                                Button("停止任务") { Task { await cancel(job.id) } }.disabled(working)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                TextField("搜索软件", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Picker("分类", selection: $selectedCategory) {
                    ForEach(categories, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
                .frame(width: 140)
                Picker("状态", selection: $filter) {
                    ForEach(SoftwareStoreFilter.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .frame(width: 125)
                Spacer(minLength: 0)
                Text("共 \(items.count) 款 · 已开放 \(items.filter(\.canInstall).count) 款")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            FlexibleScroll {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleCategories, id: \.self) { category in
                        Text("\(category) · \(visibleItems.filter { $0.categoryText == category }.count)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(visibleItems.filter { $0.categoryText == category }) { item in
                            softwareRow(item)
                            Divider()
                        }
                    }
                    if items.isEmpty && !working && !hasError {
                        EmptyHint(text: "尚未获取到软件目录")
                    } else if visibleItems.isEmpty && !working {
                        EmptyHint(text: "没有符合条件的软件")
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { Task { await refresh() } }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            if jobs.contains(where: { ["queued", "installing", "uninstalling", "cancelling"].contains($0.state) }) && !working {
                Task { await refresh() }
            }
        }
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
                        perform((selected.id, "uninstall_backup"))
                    }
                    Button("彻底卸载", role: .destructive) {
                        let selected = pendingAction
                        self.pendingAction = nil
                        perform((selected.id, "uninstall_purge"))
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
            if pendingAction?.action == "install" {
                Text(installNote(for: pendingAction?.id ?? ""))
            } else if pendingAction?.action == "uninstall" {
                Text("会先停止并禁用服务。备份选项将完整安装目录移到 /www/seraphim/backup/software，仍占用磁盘空间；彻底卸载会删除目录内的程序、配置和数据。系统依赖包、下载缓存及共享日志保留。")
            }
        }
        .sheet(item: $logSheet) { sheet in
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: sheet.title).font(.headline)
                ScrollView {
                    Text(verbatim: sheet.content.isEmpty ? "暂无安装日志" : sheet.content)
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

    private var confirmTitle: String {
        guard let pendingAction else { return "确认操作" }
        let name = items.first(where: { $0.id == pendingAction.id })?.name ?? pendingAction.id
        if pendingAction.action == "uninstall" { return "卸载 \(name)？" }
        return "确定对 \(name) 执行\(actionLabel(pendingAction.action))？"
    }

    private func actionLabel(_ action: String) -> String {
        switch action {
        case "install": return "安装"
        case "uninstall": return "卸载"
        case "start": return "启动"
        case "stop": return "停止"
        case "restart": return "重启"
        default: return "操作"
        }
    }

    private func installNote(for id: String) -> String {
        switch id {
        case "mysql": return "MySQL 会下载官方安装包并初始化数据库，安装可能需要较长时间。"
        case "nginx": return "Nginx 将从官方源码编译，所需编译依赖会由系统包管理器安装。"
        case "redis": return "Redis 将从官方源码编译，安装完成后仅监听本机。"
        case "php": return "PHP-FPM 将从官方源码单线程编译；安装可能需要较长时间，完成后仍需配置网站的 FastCGI 转发。"
        case "node": return "Node.js 将从官方二进制包安装，包含 npm；它是运行环境，无需启动常驻服务。"
        case "go": return "Go 将从官方二进制包安装；它是工具链，无需启动常驻服务。"
        case "docker": return "Docker 安装到 /www/seraphim/server/docker。安装后不会自动启动；数据和本机套接字均位于该目录。"
        case "podman": return "Podman 会从源码编译，所需容器运行依赖由系统包管理器安装；它无需常驻服务。"
        case "rabbitmq": return "RabbitMQ 会同时编译 Erlang/OTP，安装可能需要较长时间。服务仅监听本机。"
        case "kafka": return "Kafka 会安装所需 JDK 并初始化单节点存储，服务仅监听本机。"
        case "elasticsearch", "opensearch": return "搜索服务安装包较大，启动需要足够内存，并可能需要提高 vm.max_map_count。服务仅监听本机。"
        case "grafana": return "Grafana 的初始管理员密码会保存到安装目录中的 initial-admin-password，仅监听本机。"
        case "minio": return "MinIO 会从官方源码编译，初始管理密码会保存到安装目录中的 initial-root-password，仅监听本机。"
        default: return "将从已验证的官方来源安装到 /www/seraphim/server。"
        }
    }

    private func softwareRow(_ item: RemoteSoftware) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.version.isEmpty ? item.name : "\(item.name) · \(item.version)")
                    .font(.headline)
                Text(verbatim: item.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !item.message.isEmpty {
                    Text(verbatim: item.message)
                        .font(.caption)
                        .foregroundStyle(item.state == "failed" || item.state == "needs_attention" || item.message.hasPrefix("卸载失败")
                                         ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text(item.storeStateText)
                    .font(.callout)
                if item.isInstalled && item.hasService {
                    Text(item.runningText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if item.canInstall && !item.supported {
                    Text("当前系统不支持")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 85, alignment: .trailing)

            if item.canInstall && (item.state == "not_installed" || item.state == "failed" || item.state == "cancelled") {
                Button("安装") { pendingAction = (item.id, "install") }
                    .disabled(working || !item.supported)
            }
            if ["queued", "installing", "uninstalling"].contains(item.state) {
                Button("停止") { Task { await cancel(item.id) } }.disabled(working)
            }
            if item.isInstalled && item.hasService {
                Menu("运行操作") {
                    Button("启动") { pendingAction = (item.id, "start") }
                        .disabled(item.isRunning)
                    Button("停止") { pendingAction = (item.id, "stop") }
                        .disabled(!item.isRunning)
                    Button("重启") { pendingAction = (item.id, "restart") }
                }
                .disabled(working)
            }
            if item.canUninstall {
                Button("卸载") { pendingAction = (item.id, "uninstall") }
                    .disabled(working)
            }
            if item.canInstall {
                Button("日志") { Task { await showLog(item) } }
                    .disabled(working || item.state == "not_installed")
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
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
            items = try await ServerSoftwareAPI.list(connection: connection, token: token)
            jobs = try await ServerSoftwareAPI.jobs(connection: connection, token: token)
            message = ""
            hasError = false
        } catch {
            message = error.localizedDescription
            hasError = true
        }
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

    private func perform(_ selected: (id: String, action: String)) {
        guard !working else { return }
        working = true
        Task {
            do {
                if selected.action == "install" {
                    try await ServerSoftwareAPI.install(connection: connection, token: token, id: selected.id)
                } else if selected.action == "uninstall_backup" || selected.action == "uninstall_purge" {
                    try await ServerSoftwareAPI.uninstall(connection: connection, token: token,
                                                          id: selected.id,
                                                          mode: selected.action == "uninstall_backup" ? .backup : .purge)
                } else {
                    try await ServerSoftwareAPI.service(connection: connection, token: token,
                                                        id: selected.id, action: selected.action)
                }
                working = false
                await refresh()
                if !hasError {
                    if selected.action == "install" {
                        message = "安装任务已开始"
                    } else if selected.action.hasPrefix("uninstall_") {
                        message = "卸载任务已开始，完成后请查看操作日志"
                    } else {
                        message = "操作完成"
                    }
                }
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    @MainActor private func showLog(_ item: RemoteSoftware) async {
        do {
            let content = try await ServerSoftwareAPI.log(connection: connection, token: token, id: item.id)
            logSheet = SoftwareLogSheet(id: item.id, title: "\(item.name) 操作日志", content: content)
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }

}
