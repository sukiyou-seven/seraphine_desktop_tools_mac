import SwiftUI
import AppKit

struct ServerInstallView: View {
    let onInstalled: (ServerInstallResult, String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var method = 0
    @State private var host = ""
    @State private var address = ""
    @State private var port = "22"
    @State private var username = "root"
    @State private var password = ""
    @State private var sudoPassword = ""
    @State private var keyPath = ""
    @State private var useKey = false
    @State private var architecture = "amd64"
    @State private var installing = false
    @State private var message = ""
    @State private var result: ServerInstallResult?
    @State private var connectionSaved = false
    @State private var changedHostKey: SSHHostKeyChange?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("安装 Seraphim 服务端").font(.title2).bold()
                Spacer()
                Button("关闭") { dismiss() }
            }
            Text("服务端安装到 /www/seraphim，通过 HTTPS 27520 提供接口。再次安装会覆盖升级程序，并保留令牌、证书、服务配置和业务数据。")
                .font(.callout).foregroundStyle(.secondary)
            Picker("安装方式", selection: $method) {
                Text("命令行安装").tag(0)
                Text("填写 SSH 信息安装").tag(1)
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if method == 0 { commandLinePane } else { sshPane }
                    if !message.isEmpty {
                        Text(verbatim: message)
                            .font(.callout)
                            .foregroundStyle(result == nil ? Color.orange : Color.secondary)
                            .textSelection(.enabled)
                    }
                    if let changedHostKey {
                        Card(title: "服务器身份已变化") {
                            Text("这个 SSH 地址的主机密钥与上次安装时记录的不同。如果服务器刚重装过，可以在这里更新记录并继续。")
                                .font(.callout)
                            InfoRow(label: "此前记录", value: changedHostKey.oldFingerprint)
                            InfoRow(label: "当前服务器", value: changedHostKey.newFingerprint)
                            HStack {
                                Button("更新密钥并继续安装") { startInstall(approvedKey: changedHostKey) }
                                    .disabled(installing)
                                Button("取消") { self.changedHostKey = nil; message = "已取消安装" }
                                    .disabled(installing)
                            }
                        }
                    }
                    if let result {
                        Card(title: connectionSaved ? "安装或升级成功 · 连接信息已保存" : "服务端已安装或升级 · 请保存连接信息") {
                            InfoRow(label: "HTTPS 地址", value: result.endpoint)
                            InfoRow(label: "API 令牌", value: result.token)
                            InfoRow(label: "证书指纹", value: result.fingerprint)
                            Text("覆盖升级会沿用原有令牌和证书。首次安装后请保存连接信息，并在服务器防火墙或云安全组中放行 TCP 27520。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 580)
    }

    private var commandLinePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. 选择服务器架构并导出安装文件").font(.headline)
            HStack {
                Picker("架构", selection: $architecture) {
                    Text("x86_64 / amd64").tag("amd64")
                    Text("aarch64 / arm64").tag("arm64")
                }
                .frame(width: 260)
                Button("导出 sera 安装文件…") { exportBinary() }
            }
            Text("在服务器上运行 uname -m 可查看架构。服务器无需安装 Go 或 Docker。")
                .font(.caption).foregroundStyle(.secondary)

            Text("2. 将文件上传至服务器的 /tmp/sera-install").font(.headline)
            Text("可用 scp 或其他文件传输方式。示例：")
                .font(.caption).foregroundStyle(.secondary)
            commandBlock("scp ./sera-linux-\(architecture) root@服务器地址:/tmp/sera-install")

            Text("3. 在服务器终端执行").font(.headline)
            HStack {
                Text("连接地址").frame(width: 80, alignment: .leading)
                TextField("服务器公网 IP 或域名", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
            }
            commandBlock("sudo chmod 755 /tmp/sera-install && sudo /tmp/sera-install install -host \(shellQuoted(address.isEmpty ? "服务器地址" : address))")
            Text("首次安装会生成连接信息；再次执行同一命令会覆盖升级服务端并保留连接信息。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sshPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("填写 SSH 信息后，应用会识别架构、上传内置文件并安装或覆盖升级服务端。SSH 只用于安装和升级；日常管理使用 HTTPS API。")
                .font(.callout).foregroundStyle(.secondary)
            field("SSH 主机", placeholder: "192.168.0.103", value: $host)
            field("HTTPS 地址", placeholder: "服务器 IP 或绑定的域名", value: $address)
            field("SSH 端口", placeholder: "22", value: $port)
            field("SSH 用户", placeholder: "root", value: $username)
            Toggle("使用 SSH 私钥", isOn: $useKey)
            if useKey {
                HStack {
                    Text("私钥文件").frame(width: 100, alignment: .leading)
                    TextField("~/.ssh/id_ed25519", text: $keyPath).textFieldStyle(.roundedBorder)
                    Button("选择…") { chooseKey() }
                }
            } else {
                HStack {
                    Text("SSH 密码").frame(width: 100, alignment: .leading)
                    SecureField("仅本次安装使用", text: $password).textFieldStyle(.roundedBorder)
                }
            }
            if username != "root" {
                HStack {
                    Text("sudo 密码").frame(width: 100, alignment: .leading)
                    SecureField("如已配置免密 sudo，可留空", text: $sudoPassword)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text("首次连接由应用记录 SSH 主机密钥；以后密钥变化时会在这里提示。SSH 密码不会保存到连接配置。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("安装或升级并保存连接") { startInstall() }
                    .disabled(installing)
                if installing { ProgressView().controlSize(.small); Text("正在通过 SSH 安装…") }
            }
        }
        .onChange(of: host) { value in if address.isEmpty { address = value } }
    }

    private func field(_ title: String, placeholder: String, value: Binding<String>) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            TextField(placeholder, text: value).textFieldStyle(.roundedBorder)
        }
    }

    private func commandBlock(_ value: String) -> some View {
        HStack(alignment: .top) {
            Text(verbatim: value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func exportBinary() {
        do {
            let source = try ServerInstaller.bundledBinary(architecture: architecture)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "sera-linux-\(architecture)"
            guard panel.runModal() == .OK, let target = panel.url else { return }
            try FileManager.default.copyItem(at: source, to: target)
            message = "已导出到 \(target.path)"
        } catch {
            message = error.localizedDescription
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK { keyPath = panel.url?.path ?? "" }
    }

    private func startInstall(approvedKey: SSHHostKeyChange? = nil) {
        guard !installing else { return }
        let options = SSHInstallOptions(host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                                        port: Int(port) ?? 0, user: username.trimmingCharacters(in: .whitespacesAndNewlines),
                                        address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                                        password: password, keyPath: keyPath, sudoPassword: sudoPassword, useKey: useKey)
        do { try ServerInstaller.validate(options) }
        catch { message = error.localizedDescription; return }
        installing = true
        result = nil
        connectionSaved = false
        changedHostKey = nil
        message = ""
        Task { @MainActor in
            defer { installing = false }
            do {
                let installed = try await Task.detached(priority: .userInitiated) {
                    try ServerInstaller.install(options, approvedKey: approvedKey)
                }.value
                result = installed
                try onInstalled(installed, options.host)
                connectionSaved = true
                message = "服务端已安装或升级，连接配置已保存。"
                password = ""
                sudoPassword = ""
            } catch ServerInstallError.hostKeyChanged {
                do {
                    changedHostKey = try await Task.detached(priority: .userInitiated) {
                        try ServerInstaller.inspectHostKeyChange(options)
                    }.value
                    message = "主机密钥发生变化，请确认服务器地址后再继续。"
                } catch {
                    message = "主机密钥发生变化，但未能读取当前指纹：\(error.localizedDescription)"
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
