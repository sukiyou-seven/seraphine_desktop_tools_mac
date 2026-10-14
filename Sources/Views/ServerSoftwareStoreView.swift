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

/// 软件商店只做一件事：安装。
/// 已安装软件的启停、开机启动、日志和卸载都在「软件管理」，运行环境的版本在「环境管理」。
struct ServerSoftwareStoreView: View {
    let connection: ServerConnection
    let token: String
    let openManagement: () -> Void
    let openEnvironments: () -> Void

    @State private var items: [RemoteSoftware] = []
    @State private var jobs: [RemoteSoftwareJob] = []
    @State private var pendingInstallID: String?
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

    /// 本页只关心安装进度；卸载进度属于「软件管理」，不在这里重复展示。
    private var installJobs: [RemoteSoftwareJob] {
        jobs.filter { $0.operation == "install" }
    }

    private var activeInstallJobCount: Int {
        installJobs.filter { ["queued", "installing", "cancelling"].contains($0.state) }.count
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
            Text("浏览软件目录并安装。安装完成后请到「软件管理」控制运行状态、开机启动和卸载；运行环境请到「环境管理」按版本安装。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(hasError ? Color.orange : Color.secondary)
                    .lineLimit(3)
            }

            if !installJobs.isEmpty {
                DisclosureGroup("安装任务 · \(activeInstallJobCount) 进行中") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(installJobs) { job in
                            HStack(spacing: 8) {
                                Text(items.first(where: { $0.id == job.id })?.name ?? job.id)
                                    .fontWeight(.medium)
                                Text(jobStateText(job.state))
                                    .foregroundStyle(.secondary)
                                Text(verbatim: job.message).font(.caption).lineLimit(1)
                                Spacer(minLength: 0)
                                if ["queued", "installing"].contains(job.state) {
                                    Button("停止任务") { Task { await cancel(job.id) } }.disabled(working)
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
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
            get: { pendingInstallID != nil },
            set: { if !$0 { pendingInstallID = nil } }
        )) {
            Button("安装") {
                let selected = pendingInstallID
                pendingInstallID = nil
                if let selected { performInstall(selected) }
            }
            Button("取消", role: .cancel) { pendingInstallID = nil }
        } message: {
            if let pendingInstallID {
                Text(installNote(for: pendingInstallID))
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
        guard let pendingInstallID else { return "确认操作" }
        let name = items.first(where: { $0.id == pendingInstallID })?.name ?? pendingInstallID
        return "安装 \(name)？"
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

            if !item.isRuntime && item.canInstall &&
                (item.state == "not_installed" || item.state == "failed" || item.state == "cancelled") {
                Button("安装") { pendingInstallID = item.id }
                    .disabled(working || !item.supported)
            }
            if ["queued", "installing"].contains(item.state) {
                Button("停止") { Task { await cancel(item.id) } }.disabled(working)
            }
            if item.isInstalled {
                // 装好之后的一切操作都在「软件管理」，这里不再重复。
                Button("去管理") { openManagement() }.disabled(working)
            } else if item.isRuntime {
                // 运行环境没有"默认版本"这回事，必须去「环境管理」挑具体版本。
                Button("选择版本…") { openEnvironments() }.disabled(working)
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

    private func performInstall(_ id: String) {
        guard !working else { return }
        working = true
        Task {
            do {
                try await ServerSoftwareAPI.install(connection: connection, token: token, id: id)
                working = false
                await refresh()
                if !hasError {
                    message = "安装任务已开始，可在上方「安装任务」查看进度"
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
