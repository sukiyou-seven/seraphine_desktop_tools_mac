import SwiftUI

struct ServerFirewallView: View {
    let connection: ServerConnection
    let token: String

    @State private var snapshot: RemoteFirewallSnapshot?
    @State private var newPort = ""
    @State private var newProtocol = "tcp"
    @State private var pendingRemove: RemoteFirewallPort?
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("防火墙").font(.title3.weight(.semibold))
                Spacer()
                Button("刷新") { Task { await refresh() } }.disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            Text("管理当前防火墙区域的 TCP/UDP 入站端口。服务启停在「软件管理」中操作；云服务器还需要配置云平台安全组。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(verbatim: message).font(.callout).foregroundStyle(hasError ? Color.orange : Color.secondary)
            }
            if let snapshot {
                Card(title: "当前后端") {
                    InfoRow(label: "防火墙", value: snapshot.backend == "none" ? "未发现运行中的 firewalld 或 ufw" : snapshot.backend)
                    if !snapshot.zone.isEmpty { InfoRow(label: "区域", value: snapshot.zone) }
                }
                if snapshot.backend != "none" {
                    Card(title: "添加入站端口") {
                        HStack(spacing: 8) {
                            TextField("端口 1–65535", text: $newPort)
                                .textFieldStyle(.roundedBorder).frame(width: 160)
                            Picker("协议", selection: $newProtocol) {
                                Text("TCP").tag("tcp")
                                Text("UDP").tag("udp")
                            }.frame(width: 120)
                            Button("添加规则") { add() }
                                .disabled(working || Int(newPort) == nil)
                        }
                    }
                    FlexibleScroll {
                        VStack(alignment: .leading, spacing: 10) {
                            if snapshot.rules.isEmpty { EmptyHint(text: "当前没有直接开放的端口规则") }
                            ForEach(snapshot.rules) { rule in
                                Card(title: "\(rule.port)/\(rule.protocol.uppercased())") {
                                    HStack {
                                        Text(verbatim: rule.source)
                                            .font(.callout).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("删除规则", role: .destructive) { pendingRemove = rule }
                                            .disabled(working || rule.port == 22 || rule.port == 27520 ||
                                                      (snapshot.backend == "ufw" && rule.source != "Anywhere"))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .serverManagementRefresh)) { _ in Task { await refresh() } }
        .confirmationDialog("删除 \(pendingRemove?.port ?? 0)/\(pendingRemove?.protocol.uppercased() ?? "") 入站规则？",
                            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })) {
            if let rule = pendingRemove {
                Button("删除规则", role: .destructive) {
                    pendingRemove = nil
                    Task { await change("remove", port: rule.port, protocolName: rule.protocol) }
                }
            }
            Button("取消", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("应用可能无法再从该端口连接。请确认服务器还有其他管理入口。")
        }
    }

    private func add() {
        guard let port = Int(newPort), (1...65535).contains(port) else {
            message = "端口必须是 1 到 65535 的整数"; hasError = true; return
        }
        Task { await change("add", port: port, protocolName: newProtocol) }
    }

    @MainActor private func change(_ action: String, port: Int, protocolName: String) async {
        working = true
        defer { working = false }
        do {
            try await ServerFirewallAPI.change(connection: connection, token: token,
                                                action: action, port: port, protocolName: protocolName)
            snapshot = try await ServerFirewallAPI.snapshot(connection: connection, token: token)
            newPort = ""
            hasError = false
            message = "规则已更新"
        } catch {
            hasError = true
            message = error.localizedDescription
        }
    }

    @MainActor private func refresh() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            snapshot = try await ServerFirewallAPI.snapshot(connection: connection, token: token)
            hasError = false
            message = ""
        } catch {
            snapshot = nil
            hasError = true
            message = error.localizedDescription
        }
    }
}
