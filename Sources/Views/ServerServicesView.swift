import SwiftUI
import AppKit

private struct SoftwareManagementAction {
    let name: String
    let id: String
    let action: String
    let isFirewall: Bool
}

struct ServerServicesView: View {
    let connection: ServerConnection
    let token: String

    @State private var firewall: RemoteService?
    @State private var software: [RemoteSoftware] = []
    @State private var softwareLoadFailed = false
    @State private var pendingAction: SoftwareManagementAction?
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("软件管理")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("刷新") { Task { await refresh() } }.disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            Text("管理已安装软件的运行状态、开机启动和卸载，以及服务器防火墙服务。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(hasError ? Color.orange : Color.secondary)
                    .lineLimit(3)
            }

            FlexibleScroll {
                VStack(alignment: .leading, spacing: 14) {
                    if let firewall {
                        firewallCard(firewall)
                    } else if !working && !hasError {
                        EmptyHint(text: "此服务器没有找到受支持的防火墙服务")
                    }

                    Text("已安装软件")
                        .font(.headline)
                        .padding(.top, 4)
                    if software.isEmpty && !working && !softwareLoadFailed {
                        EmptyHint(text: "尚未安装软件，请到「软件商店」安装")
                    }
                    ForEach(software) { item in
                        softwareCard(item)
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
            if pendingAction?.isFirewall == true &&
                (pendingAction?.action == "start" || pendingAction?.action == "enable") {
                Text("请先确保防火墙允许 TCP 27520，否则可能中断 Seraphim 连接。")
            } else if pendingAction?.action == "uninstall" {
                Text("会先停止并禁用服务。备份选项将完整安装目录移到 /www/seraphim/backup/software，仍占用磁盘空间；彻底卸载会删除目录内的程序、配置和数据。系统依赖包、下载缓存及共享日志保留。")
            }
        }
    }

    private func firewallCard(_ service: RemoteService) -> some View {
        Card(title: "防火墙") {
            InfoRow(label: "服务单元", value: service.name)
            InfoRow(label: "运行状态", value: service.runningText)
            InfoRow(label: "开机启动", value: service.startupText)
            HStack(spacing: 8) {
                Button("启动") { select(service.name, name: "防火墙", action: "start", isFirewall: true) }
                    .disabled(working || service.isActive)
                Button("停止") { select(service.name, name: "防火墙", action: "stop", isFirewall: true) }
                    .disabled(working || !service.isActive)
                Button("重启") { select(service.name, name: "防火墙", action: "restart", isFirewall: true) }
                    .disabled(working)
                Divider().frame(height: 20)
                Button("开机启用") { select(service.name, name: "防火墙", action: "enable", isFirewall: true) }
                    .disabled(working || service.unitState != "disabled")
                Button("取消开机启用") { select(service.name, name: "防火墙", action: "disable", isFirewall: true) }
                    .disabled(working || !service.isEnabled)
            }
            .padding(.top, 6)
        }
    }

    private func softwareCard(_ item: RemoteSoftware) -> some View {
        Card(title: "\(item.name) · \(item.version)") {
            InfoRow(label: "程序目录", value: item.installPath)
            if item.hasService {
                InfoRow(label: "运行状态", value: item.runningText)
                InfoRow(label: "开机启动", value: item.enabled ? "已启用" : "未启用")
            } else {
                Text("运行环境，无常驻服务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !item.message.isEmpty {
                Text(verbatim: item.message)
                    .font(.callout)
                    .foregroundStyle(item.message.hasPrefix("卸载失败") ? Color.orange : Color.secondary)
            }
            if item.hasService {
                HStack(spacing: 8) {
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
                Spacer(minLength: 0)
                }
                .padding(.top, 6)
            }
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

    private func select(_ id: String, name: String, action: String, isFirewall: Bool = false) {
        pendingAction = SoftwareManagementAction(name: name, id: id, action: action, isFirewall: isFirewall)
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

    @MainActor private func refresh() async {
        guard !working else { return }
        guard !token.isEmpty else {
            message = "请先在「服务器状态」保存连接令牌"
            hasError = true
            return
        }
        working = true
        defer { working = false }
        var errors: [String] = []
        do {
            firewall = try await ServerServiceAPI.list(connection: connection, token: token).first
        } catch {
            firewall = nil
            errors.append("防火墙：\(error.localizedDescription)")
        }
        do {
            software = try await ServerSoftwareAPI.list(connection: connection, token: token)
                .filter(\.isInstalled)
            softwareLoadFailed = false
        } catch {
            software = []
            softwareLoadFailed = true
            errors.append("已安装软件：\(error.localizedDescription)")
        }
        hasError = !errors.isEmpty
        message = errors.joined(separator: "；")
    }

    private func perform(_ selected: SoftwareManagementAction,
                         uninstallMode: RemoteSoftwareUninstallMode? = nil) {
        guard !working else { return }
        working = true
        Task {
            do {
                if selected.isFirewall {
                    try await ServerServiceAPI.perform(connection: connection, token: token,
                                                       name: selected.id, action: selected.action)
                } else if let uninstallMode {
                    try await ServerSoftwareAPI.uninstall(connection: connection, token: token,
                                                          id: selected.id, mode: uninstallMode)
                } else {
                    try await ServerSoftwareAPI.service(connection: connection, token: token,
                                                        id: selected.id, action: selected.action)
                }
                working = false
                await refresh()
                if !hasError {
                    message = uninstallMode == nil ? "已执行\(actionLabel(selected.action))" : "卸载任务已开始，请到「软件商店」查看进度"
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
