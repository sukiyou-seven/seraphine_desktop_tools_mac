import SwiftUI

extension Notification.Name {
    static let serverManagementRefresh = Notification.Name("serverManagementRefresh")
}

struct ServerManagementView: View {
    @State private var connections = ServerConnectionStore.load()
    @State private var selectedID = ServerConnectionStore.selectedID
    @State private var token = ""
    @State private var section = 0
    @State private var snapshot: ServerSnapshot?
    @State private var message = ""
    @State private var hasError = false
    @State private var loading = false
    @State private var isVisible = false
    @State private var fileStartPath = "/www/seraphim"
    @State private var showServerInstaller = false
    @State private var showConnectionEditor = false

    private struct Module: Identifiable {
        let id: Int
        let title: String
        let symbol: String
    }

    private let moduleGroups: [(String, [Module])] = [
        ("概览", [Module(id: 0, title: "服务器状态", symbol: "gauge.with.dots.needle.67percent")]),
        ("站点与数据", [
            Module(id: 1, title: "文件管理", symbol: "folder"),
            Module(id: 4, title: "域名管理", symbol: "globe"),
            Module(id: 5, title: "网站管理", symbol: "network"),
            Module(id: 6, title: "项目管理", symbol: "square.stack.3d.up"),
            Module(id: 7, title: "数据库管理", symbol: "externaldrive")
        ]),
        ("运行与安全", [
            Module(id: 2, title: "软件管理", symbol: "gearshape.2"),
            Module(id: 3, title: "环境管理", symbol: "terminal"),
            // 环境管理管的是运行时版本，环境变量管理管的是那份公用变量表，两者是邻居但不相干。
            Module(id: 11, title: "环境变量管理", symbol: "key"),
            Module(id: 10, title: "软件商店", symbol: "shippingbox"),
            Module(id: 8, title: "防火墙", symbol: "shield"),
            Module(id: 9, title: "计划任务", symbol: "calendar.badge.clock"),
            // API 设置与「连接设置」不是一回事：那里填客户端怎么连，这里给的是
            // 让脚本和 AI 客户端接进来的地址、key 与接口清单。
            Module(id: 12, title: "API 设置", symbol: "curlybraces")
        ])
    ]

    private var selectedIndex: Int? {
        connections.firstIndex(where: { $0.id == selectedID })
    }

    var body: some View {
        HStack(spacing: 0) {
            navigationRail
            Divider()
            VStack(spacing: 0) {
                serverHeader
                Divider()
                GeometryReader { geometry in
                    moduleContent
                        .frame(width: geometry.size.width, height: geometry.size.height,
                               alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("服务器管理")
        .sheet(isPresented: $showConnectionEditor) { connectionEditor }
        .sheet(isPresented: $showServerInstaller) {
            ServerInstallView(onInstalled: saveInstalledServer)
        }
        .onAppear {
            isVisible = true
            token = ServerConnectionStore.token(for: selectedID)
            if section == 0 && savedConnection != nil && !token.isEmpty {
                Task { await refresh() }
            }
        }
        .onDisappear { isVisible = false }
        .onChange(of: selectedID) { newID in
            do { try ServerConnectionStore.select(newID) }
            catch { message = "保存所选服务器失败：\(error.localizedDescription)"; hasError = true }
            token = ServerConnectionStore.token(for: newID)
            snapshot = nil
            if section == 0 && savedConnection != nil && !token.isEmpty { Task { await refresh() } }
        }
        .onChange(of: connections) { _ in
            if selectedConnection != savedConnection {
                snapshot = nil
                message = "连接配置尚未保存"
                hasError = false
            }
        }
        .onChange(of: section) { newSection in
            if newSection == 0 && savedConnection != nil && !ServerConnectionStore.token(for: selectedID).isEmpty {
                Task { await refresh() }
            }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if isVisible && section == 0 && selectedConnection == savedConnection
                && savedConnection != nil && !ServerConnectionStore.token(for: selectedID).isEmpty {
                Task { await refresh() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .serverManagementRefresh)) { _ in
            if isVisible && section == 0 { Task { await refresh() } }
        }
    }

    private var navigationRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(moduleGroups.indices, id: \.self) { groupIndex in
                    let group = moduleGroups[groupIndex]
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.0)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 11)
                        ForEach(group.1) { module in
                            Button { section = module.id } label: {
                                Label(module.title, systemImage: module.symbol)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(section == module.id ? Color.accentColor.opacity(0.18) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(section == module.id ? Color.accentColor : Color.primary)
                            .accessibilityAddTraits(section == module.id ? [.isSelected] : [])
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 170)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private var serverHeader: some View {
        HStack(spacing: 10) {
            if section == 4 {
                Text("DNS 与证书配置")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("服务器", selection: $selectedID) {
                    ForEach(connections) { connection in
                        Text(verbatim: connection.label).tag(connection.id)
                    }
                }
                .frame(maxWidth: 285)
                if selectedConnection != savedConnection {
                    Text("配置未保存").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Button { showConnectionEditor = true } label: {
                Label("连接设置", systemImage: "gearshape")
            }
            Button { showServerInstaller = true } label: {
                Label("安装服务端", systemImage: "square.and.arrow.down")
            }
            if section == 0 {
                Button { Task { await refresh() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(loading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var moduleContent: some View {
        switch section {
        case 1:
            connectedContent { connection, savedToken in
                ServerFilesView(connection: connection, token: savedToken, startPath: fileStartPath)
                    .id(selectedID + fileStartPath)
            }
        case 2:
            connectedContent { connection, savedToken in
                ServerServicesView(connection: connection, token: savedToken,
                                   openStore: { section = 10 },
                                   openEnvironments: { section = 3 })
                    .id(selectedID)
            }
        case 3:
            connectedContent { connection, savedToken in
                ServerEnvironmentsView(connection: connection, token: savedToken,
                                       openFiles: { path in fileStartPath = path; section = 1 })
                    .id(selectedID)
            }
        case 4:
            DomainManagementView()
        case 5:
            connectedContent { connection, savedToken in
                ServerSitesView(connection: connection, token: savedToken,
                                openFiles: { path in fileStartPath = path; section = 1 },
                                openStore: { section = 10 },
                                openDomains: { section = 4 })
                    .id(selectedID)
            }
        case 6:
            connectedContent { connection, savedToken in
                ServerProjectsView(connection: connection, token: savedToken,
                                   openFiles: { path in fileStartPath = path; section = 1 },
                                   openEnvironments: { section = 3 },
                                   openVariables: { section = 11 })
                    .id(selectedID)
            }
        case 7:
            connectedContent { connection, savedToken in
                ServerDatabasesView(connection: connection, token: savedToken,
                                    openStore: { section = 10 })
                    .id(selectedID)
            }
        case 8:
            connectedContent { connection, savedToken in
                ServerFirewallView(connection: connection, token: savedToken).id(selectedID)
            }
        case 9:
            connectedContent { connection, savedToken in
                ServerTasksView(connection: connection, token: savedToken).id(selectedID)
            }
        case 10:
            connectedContent { connection, savedToken in
                ServerSoftwareStoreView(connection: connection, token: savedToken,
                                        openManagement: { section = 2 },
                                        openEnvironments: { section = 3 })
                    .id(selectedID)
            }
        case 11:
            connectedContent { connection, savedToken in
                ServerVariablesView(connection: connection, token: savedToken).id(selectedID)
            }
        case 12:
            connectedContent { connection, savedToken in
                ServerAPIAccessView(connection: connection, token: savedToken).id(selectedID)
            }
        default:
            statusAndPlaceholders
        }
    }

    @ViewBuilder private func connectedContent<Content: View>(
        @ViewBuilder _ content: (ServerConnection, String) -> Content
    ) -> some View {
        if let connection = savedConnection {
            content(connection, ServerConnectionStore.token(for: selectedID))
        } else {
            EmptyHint(text: "请在「连接设置」中保存服务器地址和令牌")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var connectionEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接设置").font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                Picker("服务器", selection: $selectedID) {
                    ForEach(connections) { connection in
                        Text(verbatim: connection.label).tag(connection.id)
                    }
                }
                .frame(maxWidth: 360)
                Button("添加") { addConnection() }
                Button("删除") { removeConnection() }
                    .disabled(connections.count <= 1)
                Spacer()
            }
            Divider()
            if let index = selectedIndex {
                LabeledContent("名称") {
                    TextField("例如：测试服务器", text: $connections[index].name)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("HTTPS 地址") {
                    TextField("https://1.2.3.4:27520", text: $connections[index].endpoint)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("API 令牌") {
                    SecureField("服务端生成的连接令牌", text: $token)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("证书指纹") {
                    TextField("自签证书填写 SHA-256 指纹", text: $connections[index].fingerprint)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                }
            }
            Text("自签证书填写 SHA-256 指纹；受系统信任的证书可留空。令牌保存在本机应用数据目录。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(hasError ? Color.orange : Color.secondary)
                    .lineLimit(3)
            }
            HStack {
                Spacer()
                Button("取消") { discardConnectionChanges(); showConnectionEditor = false }
                Button("保存并连接") { saveAndRefresh() }
                    .disabled(loading)
                    .keyboardShortcut(.defaultAction)
                if loading { ProgressView().controlSize(.small) }
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private func discardConnectionChanges() {
        connections = ServerConnectionStore.load()
        token = ServerConnectionStore.token(for: selectedID)
        message = ""
        hasError = false
    }

    private var statusAndPlaceholders: some View {
        FlexibleScroll {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("实时状态").font(.headline)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                    if !message.isEmpty {
                        Text(verbatim: message)
                            .font(.caption)
                            .foregroundStyle(hasError ? Color.orange : Color.secondary)
                            .lineLimit(1)
                    }
                }

                if let snapshot {
                    Card(title: "主机") {
                        InfoRow(label: "主机名", value: snapshot.host.hostname)
                        InfoRow(label: "系统", value: snapshot.host.os)
                        InfoRow(label: "内核", value: snapshot.host.kernel)
                        InfoRow(label: "架构", value: snapshot.host.architecture)
                        InfoRow(label: "运行时间", value: formatUptime(snapshot.host.uptimeSeconds))
                        InfoRow(label: "采集时间", value: snapshot.timestamp)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        Card(title: "CPU") {
                            metric("使用率", percentText(snapshot.cpu.usagePercent), snapshot.cpu.usagePercent)
                            InfoRow(label: "逻辑核心", value: "\(snapshot.cpu.logicalCores)")
                            InfoRow(label: "负载 1 / 5 / 15 分钟",
                                    value: String(format: "%.2f / %.2f / %.2f", snapshot.cpu.load1M,
                                                  snapshot.cpu.load5M, snapshot.cpu.load15M))
                        }
                        Card(title: "内存") {
                            metric("使用率", percentText(snapshot.memory.usagePercent), snapshot.memory.usagePercent)
                            InfoRow(label: "已用 / 总量", value: "\(bytes(snapshot.memory.usedBytes)) / \(bytes(snapshot.memory.totalBytes))")
                            InfoRow(label: "可用", value: bytes(snapshot.memory.availableBytes))
                            InfoRow(label: "交换空间", value: "\(bytes(snapshot.swap.usedBytes)) / \(bytes(snapshot.swap.totalBytes))")
                        }
                    }
                    Card(title: "磁盘") {
                        if snapshot.disks.isEmpty {
                            Text("未找到可读取的磁盘挂载点").foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.disks, id: \.mountpoint) { disk in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(verbatim: disk.mountpoint)
                                        .font(.system(.callout, design: .monospaced))
                                    Spacer()
                                    Text("\(bytes(disk.usedBytes)) / \(bytes(disk.totalBytes)) · \(percentText(disk.usagePercent))")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                ProgressView(value: progressValue(disk.usagePercent), total: 100)
                                Text(verbatim: "\(disk.device) · \(disk.filesystem) · 可用 \(bytes(disk.availableBytes))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    Card(title: "网络") {
                        if snapshot.network.isEmpty {
                            Text("未找到非回环网卡").foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.network, id: \.name) { item in
                            InfoRow(label: item.name,
                                    value: "↓ \(bytes(item.rxBytesPerSecond))/s  ↑ \(bytes(item.txBytesPerSecond))/s")
                        }
                    }
                } else {
                    EmptyHint(text: "选择服务器并在「连接设置」中保存地址和令牌，即可查看实时状态")
                }
            }
            .padding(16)
        }
    }

    private var savedConnection: ServerConnection? {
        ServerConnectionStore.load().first(where: { $0.id == selectedID && !$0.endpoint.isEmpty })
    }

    private var selectedConnection: ServerConnection? {
        connections.first(where: { $0.id == selectedID && !$0.endpoint.isEmpty })
    }

    private func addConnection() {
        let connection = ServerConnection(name: "服务器 \(connections.count + 1)")
        let updated = connections + [connection]
        do {
            try ServerConnectionStore.save(updated, selectedID: connection.id)
            connections = updated
            selectedID = connection.id
            token = ""
            snapshot = nil
        } catch {
            message = "保存连接配置失败：\(error.localizedDescription)"
            hasError = true
        }
    }

    private func saveInstalledServer(_ result: ServerInstallResult, host: String) throws {
        var updated = connections
        let connection: ServerConnection
        if let index = updated.firstIndex(where: { $0.endpoint == result.endpoint }) {
            updated[index].fingerprint = result.fingerprint
            connection = updated[index]
        } else {
            connection = ServerConnection(name: host, endpoint: result.endpoint,
                                          fingerprint: result.fingerprint)
            updated.append(connection)
        }
        try ServerConnectionStore.save(updated, selectedID: connection.id, token: result.token)
        connections = updated
        selectedID = connection.id
        token = result.token
        snapshot = nil
        message = "连接配置已保存；正在验证 HTTPS…"
        hasError = false
        Task { await refresh() }
    }

    private func removeConnection() {
        guard connections.count > 1 else { return }
        let updated = connections.filter { $0.id != selectedID }
        let nextID = updated[0].id
        do {
            try ServerConnectionStore.save(updated, selectedID: nextID)
            connections = updated
            selectedID = nextID
            token = ServerConnectionStore.token(for: nextID)
            snapshot = nil
        } catch {
            message = "删除连接配置失败：\(error.localizedDescription)"
            hasError = true
        }
    }

    private func saveAndRefresh() {
        guard !loading, let index = selectedIndex else { return }
        let connectionID = selectedID
        let proposedToken = token
        var proposed = connections[index]
        proposed.endpoint = proposed.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try ServerStatusAPI.statusURL(proposed.endpoint)
            proposed.fingerprint = try ServerStatusAPI.normalizedFingerprint(proposed.fingerprint)
            guard !proposedToken.isEmpty else {
                message = "请输入 API 令牌"
                hasError = true
                return
            }
        } catch {
            message = error.localizedDescription
            hasError = true
            return
        }
        loading = true
        Task { @MainActor in
            defer { loading = false }
            do {
                let result = try await ServerStatusAPI.fetch(endpoint: proposed.endpoint,
                                                              token: proposedToken,
                                                              fingerprint: proposed.fingerprint)
                guard selectedID == connectionID,
                      let currentIndex = selectedIndex,
                      connections[currentIndex].id == proposed.id else { return }
                var updated = connections
                updated[currentIndex] = proposed
                try ServerConnectionStore.save(updated, selectedID: connectionID, token: proposedToken)
                connections = updated
                snapshot = result
                message = "已连接 · 每 5 秒自动刷新"
                hasError = false
                showConnectionEditor = false
            } catch {
                guard selectedID == connectionID else { return }
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    @MainActor
    private func refresh() async {
        guard !loading else { return }
        guard selectedConnection == savedConnection else {
            message = "请先保存连接配置"
            hasError = true
            return
        }
        guard let connection = savedConnection else {
            message = "请先保存服务器连接配置"
            hasError = true
            return
        }
        let connectionID = selectedID
        let savedToken = ServerConnectionStore.token(for: connectionID)
        guard !savedToken.isEmpty else {
            message = "请先保存 API 令牌"
            hasError = true
            return
        }
        loading = true
        defer { loading = false }
        do {
            let result = try await ServerStatusAPI.fetch(endpoint: connection.endpoint,
                                                         token: savedToken,
                                                         fingerprint: connection.fingerprint)
            guard selectedID == connectionID else { return }
            snapshot = result
            message = "已连接 · 每 5 秒自动刷新"
            hasError = false
        } catch {
            guard selectedID == connectionID else { return }
            message = snapshot == nil ? error.localizedDescription : "连接失败，以下为上次采集数据：\(error.localizedDescription)"
            hasError = true
        }
    }

    private func metric(_ label: String, _ value: String, _ percentage: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            InfoRow(label: label, value: value)
            ProgressView(value: progressValue(percentage), total: 100)
        }
    }

    private func progressValue(_ value: Double) -> Double {
        value.isFinite ? min(100, max(0, value)) : 0
    }

    private func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private func formatUptime(_ seconds: UInt64) -> String {
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3_600
        let minutes = seconds % 3_600 / 60
        return "\(days) 天 \(hours) 小时 \(minutes) 分钟"
    }
}
