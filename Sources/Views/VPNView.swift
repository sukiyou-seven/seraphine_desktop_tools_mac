import SwiftUI
import AppKit

/// 「网络代理」页面：在一台远程服务器上自动搭建 IKEv2 VPN，并把生成的描述文件
/// 装进 macOS —— 装好后是**整机全局**生效，所有 App 都走这条路（不只是本工具）。
struct VPNView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                serverCard
                udpCard
                installCard
                profileCard
                localCard
                logCard
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.vpnRefreshStatus() }
    }

    // MARK: 服务器

    private var serverCard: some View {
        Card(title: "服务器") {
            Text(verbatim: "工具会通过 SSH 登上去，自动安装配置 IKEv2 VPN。密码只保存在本机设置里（600），日志中会脱敏。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    field("服务器地址", text: $model.settings.vpn.host, width: 220,
                          placeholder: "例如 1.2.3.4")
                    field("SSH 端口", text: Binding(
                        get: { String(model.settings.vpn.sshPort) },
                        set: { model.settings.vpn.sshPort = Int($0) ?? 22 }), width: 90)
                }
                HStack(spacing: 10) {
                    field("SSH 用户名", text: $model.settings.vpn.sshUser, width: 160)
                    secureField("SSH 密码", text: $model.settings.vpn.sshPassword, width: 220)
                    field("客户端名", text: $model.settings.vpn.clientName, width: 140)
                }
            }

            HStack(spacing: 10) {
                Button("测试连接并探测") { model.vpnProbeServer() }
                if let probe = model.vpnProbe, !probe.osName.isEmpty {
                    Text(verbatim: "\(probe.osName) · \(probe.arch) · 内存 \(probe.memoryMB)MB"
                         + (probe.ikev2Installed ? " · 已装 IKEv2" : " · 未装 IKEv2"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: UDP 连通性

    private var udpCard: some View {
        Card(title: "第 1 步：确认 UDP 500/4500 能通") {
            Text(verbatim: "服务器在 NAT 后面时（阿里云、腾讯云等），云平台安全组必须放行 UDP 500 和 4500，"
                 + "否则 IKE 包根本到不了服务器 —— 这是「VPN 连不上」最常见的原因。\n"
                 + "这个检查会让服务器抓包、同时本机发包：抓到包说明通，抓不到就一定是防火墙。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("检查 UDP 连通性") { model.vpnCheckUDP() }
                Text(verbatim: "需要服务器装有 tcpdump（通常自带；缺就 apt install tcpdump）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 安装

    private var installCard: some View {
        Card(title: "第 2 步：在服务器上安装 IKEv2") {
            Text(verbatim: "用 hwdsl2/setup-ipsec-vpn 一键脚本：先装 IPsec 基础（Libreswan），再自动配置 IKEv2，"
                 + "最后在服务器上生成客户端描述文件。整个过程在服务器后台跑，避免 SSH 中途断开把安装打断。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("开始安装") { model.vpnInstall() }
                    .disabled(model.settings.vpn.host.isEmpty)
                if model.vpnInstallDone {
                    Label("安装完成", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    // MARK: 客户端配置

    private var profileCard: some View {
        Card(title: "第 3 步：把描述文件装进系统") {
            Text(verbatim: "描述文件里含 CA 证书和客户端证书，装好后 VPN 出现在「系统设置 → VPN」，"
                 + "点连接即**全局**生效。\n"
                 + "注意：macOS 27 起描述文件必须由你在系统弹窗里点「安装」，命令行无法代替 —— "
                 + "所以这一步工具只能帮你把文件打开。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.vpnLocalProfile.isEmpty {
                Text(verbatim: "本地文件：\(model.vpnLocalProfile)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("取回配置") { model.vpnFetchProfile() }
                    .disabled(!model.vpnInstallDone && model.vpnLocalProfile.isEmpty)
                Button("打开并安装描述文件") { model.vpnInstallProfile() }
                    .disabled(model.vpnLocalProfile.isEmpty)
                Button("备份到 iCloud（手机用）") { model.vpnBackupToICloud() }
                    .disabled(model.vpnLocalProfile.isEmpty)
            }
        }
    }

    // MARK: 本机状态

    private var localCard: some View {
        Card(title: "本机状态") {
            HStack(spacing: 10) {
                Button("刷新状态") { model.vpnRefreshStatus() }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.vpnStatus.profileInstalled ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 10, height: 10)
                    Text(verbatim: model.vpnStatus.profileInstalled
                         ? "描述文件已安装" : "描述文件还没安装")
                        .font(.callout)
                }
                if !model.vpnStatus.services.isEmpty {
                    Text(verbatim: "可用服务：" + model.vpnStatus.services.joined(separator: "、"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "系统里暂时读不到 VPN 服务（可能还没安装，或当前环境看不到用户级配置）。"
                         + "只要「系统设置 → VPN」里能看到，就说明配置是好的。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button("连接 VPN") { model.vpnSetConnected(true) }
                    Button("断开 VPN") { model.vpnSetConnected(false) }
                }
                .disabled(model.vpnStatus.services.isEmpty)
            }
        }
    }

    // MARK: 日志

    private var logCard: some View {
        Card(title: "最近一次操作输出") {
            Text(verbatim: "命令输出在这里原样保留（密码类字段已脱敏），方便排查。")
                .font(.caption)
                .foregroundStyle(.secondary)
            ReadonlyText(text: model.vpnLog, minHeight: 160)
        }
    }

    // MARK: 小控件

    private func field(_ label: String, text: Binding<String>, width: CGFloat,
                       placeholder: String = "") -> some View {
        HStack(spacing: 6) {
            Text(verbatim: label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }

    private func secureField(_ label: String, text: Binding<String>, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: label).font(.caption).foregroundStyle(.secondary)
            SecureField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }
}
