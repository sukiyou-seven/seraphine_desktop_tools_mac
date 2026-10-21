import SwiftUI

struct CertificateView: View {
    @EnvironmentObject var model: AppModel
    var embedded = false

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                FlexibleScroll { content }
            }
        }
        .onAppear {
            model.refreshACMEStatus()
            model.loadCertificates()
        }
        // 从解析记录挑证书域名
        .sheet(isPresented: $model.acmePickerVisible) {
            ACMEDomainPicker()
                .environmentObject(model)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            ACMEStatusCard()

            if model.acmeStatus.installed {
                ACMEIssueCard()
                if model.acmeMode == "manual" {
                    ACMManualCard()
                }
                ACMECertificatesCard()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - acme.sh 状态

private struct ACMEStatusCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "acme.sh（ACME 客户端）") {
            HStack(spacing: 10) {
                StatusDot(running: model.acmeStatus.installed)
                Text(verbatim: model.acmeStatus.installed ? "已就绪" : "未安装")
                    .font(.title3.weight(.semibold))
                if !model.acmeStatus.version.isEmpty {
                    Text(verbatim: model.acmeStatus.version)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新") { model.refreshACMEStatus() }
                if model.acmeStatus.installed {
                    Button("安装自动续期任务") { model.installACMECron() }
                }
            }

            if model.acmeStatus.installed {
                InfoRow(label: "acme.sh 路径", value: model.acmeStatus.bin)
                InfoRow(label: "证书目录", value: model.acmeStatus.home)
            } else {
                Text(verbatim: "申请 Let's Encrypt 证书需要 acme.sh。它是单文件 shell 脚本，零依赖，"
                     + "申请时会自动补齐阿里云 / 腾讯云 DNS 插件（DNS-01 验证就靠它）。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "点下面的按钮会先试官方源；如果下载失败（国内直连 GitHub 常超时），"
                     + "会自动改用 Gitee 镜像重试。也可以自己在终端执行：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "官方（GitHub）")
                        .font(.caption2).foregroundStyle(.secondary)
                    CopyableText(text: model.acmeGithubCommand, monospaced: true)
                    Text(verbatim: "国内镜像（Gitee，acme.sh 官方文档推荐）")
                        .font(.caption2).foregroundStyle(.secondary)
                    CopyableText(text: model.acmeGiteeCommand, monospaced: true)
                }
                HStack {
                    Button("安装 acme.sh") { model.installACME() }
                    Text(verbatim: "官方源失败会自动回退到镜像，两个都失败才报错")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 申请

private struct ACMEIssueCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "申请证书（Let's Encrypt）") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("域名")
                        .font(.callout)
                        .frame(width: 90, alignment: .leading)
                    TextField("example.com 或 example.com, *.example.com", text: $model.acmeDomains)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    Button("从解析记录选…") { model.acmeOpenDomainPicker() }
                        .disabled(!model.settings.dns.isConfigured)
                        .help(model.settings.dns.isConfigured
                              ? "从阿里云解析记录里挑一个已经有解析的域名"
                              : "先在「域名解析」页填好阿里云 AccessKey，才能从解析记录里选")
                }
                Text(verbatim: "多个用逗号分隔；泛域名写 *.example.com（解析记录里没有，只能手打）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 100)
                HStack(spacing: 10) {
                    Text("邮箱")
                        .font(.callout)
                        .frame(width: 90, alignment: .leading)
                    TextField("you@example.com（到期提醒用）", text: $model.settings.acme.email)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    Picker("", selection: $model.settings.acme.keylength) {
                        Text(verbatim: "ECC（ec-256，推荐）").tag("ec-256")
                        Text(verbatim: "RSA 2048").tag("2048")
                        Text(verbatim: "RSA 4096").tag("4096")
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                Divider()

                Picker("", selection: $model.acmeMode) {
                    Text(verbatim: "阿里云域名解析（自动完成 DNS 验证）").tag("aliyun")
                    Text(verbatim: "腾讯云域名解析（自动完成 DNS 验证）").tag("tencent")
                    Text(verbatim: "手动 DNS（自己加 TXT 记录）").tag("manual")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if model.acmeMode == "aliyun" {
                    Text(verbatim: "工具会自动在 _acme-challenge 下添加 TXT 记录、等验证通过、再删掉记录，全程无需人工。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // 阿里云账号由页面顶部的「配置」统一管理，这里只显示当前用的是哪个
                    HStack(spacing: 10) {
                        Text("阿里云账号")
                            .font(.callout)
                            .frame(width: 120, alignment: .leading)
                        Text(verbatim: model.dnsCredentialSummary)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(model.settings.dns.hasCredentials ? Color.secondary : Color.orange)
                        Spacer(minLength: 0)
                    }
                    Text(verbatim: "使用当前配置的阿里云账号申请和手动续期；换账号请在页面顶部切换配置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("申请证书") { model.issueCertificate() }
                            .disabled(model.acmeDomains.trimmingCharacters(in: .whitespaces).isEmpty)
                        Text(verbatim: "会自动完成 DNS 验证并签发（首次约 30 秒～2 分钟）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if model.acmeMode == "tencent" {
                    Text(verbatim: "工具会通过腾讯云 DNSPod 接口自动添加 _acme-challenge TXT 记录，"
                         + "验证通过后删掉记录，全程无需人工。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Text("SecretId")
                            .font(.callout)
                            .frame(width: 120, alignment: .leading)
                        TextField("AKID...", text: $model.settings.dns.tencentSecretId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: 320)
                            .onChange(of: model.settings.dns.tencentSecretId) { _ in
                                model.persistSettings()
                            }
                        Text(verbatim: model.tencentCredentialSummary)
                            .font(.caption)
                            .foregroundStyle(model.settings.dns.hasTencentCredentials
                                             ? Color.secondary : Color.orange)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 10) {
                        Text("SecretKey")
                            .font(.callout)
                            .frame(width: 120, alignment: .leading)
                        SecureField("腾讯云控制台 → 访问管理 → API 密钥管理",
                                    text: $model.settings.dns.tencentSecretKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: 320)
                            .onChange(of: model.settings.dns.tencentSecretKey) { _ in
                                model.persistSettings()
                            }
                        Spacer(minLength: 0)
                    }
                    Text(verbatim: "⚠️ 密钥明文保存在设置文件里，建议用只有 DNSPod 权限的子账号；"
                         + "凭据随顶部配置保存，续期时继续使用。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("申请证书") { model.issueCertificate() }
                            .disabled(model.acmeDomains.trimmingCharacters(in: .whitespaces).isEmpty)
                        Text(verbatim: "会自动完成 DNS 验证并签发（首次约 30 秒～2 分钟）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(verbatim: "点第 1 步生成验证记录，把 TXT 记录加到你的域名解析里；生效后点第 2 步完成签发。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("1) 生成验证记录") { model.generateChallenges() }
                            .disabled(model.acmeDomains.trimmingCharacters(in: .whitespaces).isEmpty)
                        Text(verbatim: "会调用 acme.sh 创建订单，但不会真正签发")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - 从解析记录里挑证书域名

/// 证书要签给「能解析到服务器」的域名，所以从阿里云解析记录里挑比手打可靠：
/// 列出主域名下已有的记录，勾中的拼成完整域名（`@` 就是主域名本身）填进输入框。
///
/// 手打入口**必须保留** —— 泛域名 `*.example.com` 在解析记录里是没有的。
private struct ACMEDomainPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(verbatim: "从解析记录里选域名").font(.headline)
                if model.busy != nil {
                    ProgressView().controlSize(.small)
                    Text(verbatim: model.busy ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text(verbatim: "域名").font(.callout)
                Picker("", selection: Binding(
                    get: { model.acmePickerDomain ?? "" },
                    set: { model.acmePickDomain($0) })) {
                        ForEach(model.acmePickerDomains) { domain in
                            Text(verbatim: domain.name).tag(domain.name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                Button("刷新") { model.acmeOpenDomainPicker() }
                    .disabled(model.busy != nil)
                Spacer(minLength: 0)
            }

            if !model.acmePickerError.isEmpty {
                Text(verbatim: model.acmePickerError)
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    // 限宽：长报错不许把弹窗的最小宽度撑大
                    .frame(maxWidth: 560, alignment: .leading)
            }

            FlexibleScroll {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.acmePickerRecords) { record in
                        pickerRow(record)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18)))

            HStack(spacing: 8) {
                Text(verbatim: pickedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
                Spacer(minLength: 0)
                Button("取消") { model.acmeClosePicker() }
                Button("添加选中的") { model.acmeConfirmPick() }
                    .disabled(model.acmePickerSelected.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 660, height: 540)
    }

    private var pickedSummary: String {
        let picked = model.acmePickerPicked
        if picked.isEmpty {
            return "勾选要签进证书的域名（@ 表示主域名本身）；已有的不会重复添加"
        }
        return "将添加：" + picked.joined(separator: "、")
    }

    private func pickerRow(_ record: DNSRecord) -> some View {
        let checked = model.acmePickerSelected.contains(record.recordId)
        return Button {
            model.acmeTogglePick(record)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                Text(verbatim: record.fqdn)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: record.type)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                Text(verbatim: record.value)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .leading)
                    .help(record.value)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(checked ? Color.accentColor.opacity(0.10) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 手动 DNS 两步

private struct ACMManualCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "手动 DNS 验证") {
            if model.acmeChallenges.isEmpty {
                Text(verbatim: "还没有生成验证记录。先点上面的「1) 生成验证记录」。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: "到你的域名解析处添加下面这些 TXT 记录（DNS 生效通常要等 1–10 分钟）：")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.acmeChallenges) { challenge in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(verbatim: "记录名").font(.caption)
                                    .frame(width: 60, alignment: .leading)
                                CopyableText(text: challenge.recordName)
                            }
                            HStack(spacing: 8) {
                                Text(verbatim: "记录值").font(.caption)
                                    .frame(width: 60, alignment: .leading)
                                CopyableText(text: challenge.recordValue)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    }
                }
                HStack {
                    Button("2) 我已添加，完成验证并签发") { model.completeManualIssue() }
                    Button("重新生成") { model.generateChallenges() }
                    Text(verbatim: "记录类型选 TXT，主机记录通常填 _acme-challenge")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 已签发的证书

private struct ACMECertificatesCard: View {
    @EnvironmentObject var model: AppModel
    @State private var deployingCertificate: ACMECertificate?

    var body: some View {
        Card(title: "已签发的证书") {
            HStack {
                Button("刷新列表") { model.loadCertificates() }
                if let error = model.acmeCertError {
                    Text(verbatim: error).font(.caption).foregroundStyle(.orange)
                }
            }
            if model.acmeCertificates.isEmpty {
                EmptyHint(text: "还没有签发的证书")
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("域名").font(.caption).frame(width: 200, alignment: .leading)
                        Text("类型").font(.caption).frame(width: 96, alignment: .leading)
                        Text("下次续期").font(.caption).frame(width: 200, alignment: .leading)
                        Text("证书路径").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        Spacer().frame(width: 150)
                    }
                    .padding(.vertical, 4)
                    Divider()
                    ForEach(model.acmeCertificates) { certificate in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: certificate.domain)
                                    .font(.system(.callout, design: .monospaced))
                                if certificate.sanDomains != "no" && !certificate.sanDomains.isEmpty {
                                    Text(verbatim: "附加：\(certificate.sanDomains)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 200, alignment: .leading)

                            Text(verbatim: certificate.keyLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                            Text(verbatim: certificate.renewAt.isEmpty ? "—" : String(certificate.renewAt.prefix(16)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 200, alignment: .leading)
                            CopyableText(text: certificate.fullchainPath, monospaced: false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("续期") {
                                model.renewCertificate(certificate.domain, ecc: certificate.isECC)
                            }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            Button("部署到网站") { deployingCertificate = certificate }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
        }
        .sheet(item: $deployingCertificate) { certificate in
            CertificateDeploymentSheet(certificate: certificate)
        }
    }
}

private struct CertificateDeploymentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let certificate: ACMECertificate
    @State private var connections = ServerConnectionStore.load().filter { !$0.endpoint.isEmpty }
    @State private var connectionID = ServerConnectionStore.selectedID
    @State private var sites: [RemoteSite] = []
    @State private var siteID = ""
    @State private var working = false
    @State private var message = ""

    private var connection: ServerConnection? { connections.first { $0.id == connectionID } }
    private var selectedSite: RemoteSite? { sites.first { $0.uniqueID == siteID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("部署证书到网站").font(.title3.weight(.semibold))
            Text(verbatim: certificate.domain).font(.system(.body, design: .monospaced))
            Picker("服务器", selection: $connectionID) {
                ForEach(connections) { entry in Text(entry.label).tag(entry.id) }
            }
            Picker("网站", selection: $siteID) {
                ForEach(sites) { site in Text("\(site.domains.joined(separator: ", ")) · \(site.provider)").tag(site.uniqueID) }
            }
            Text("部署会验证证书覆盖网站所有域名，并启用该网站的 HTTPS 443 端口。续期后需要再次部署新证书。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(verbatim: message).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("部署") { Task { await deploy() } }.disabled(working || selectedSite == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await loadSites() }
        .onChange(of: connectionID) { _ in Task { await loadSites() } }
    }

    @MainActor private func loadSites() async {
        guard let connection else { sites = []; return }
        let token = ServerConnectionStore.token(for: connectionID)
        guard !token.isEmpty else { message = "此服务器没有连接令牌"; sites = []; return }
        working = true
        defer { working = false }
        do {
            sites = try await ServerSiteAPI.list(connection: connection, token: token).items.filter(\.enabled)
            siteID = sites.first?.uniqueID ?? ""
            message = sites.isEmpty ? "此服务器没有已启用的网站" : ""
        } catch { message = error.localizedDescription; sites = [] }
    }

    @MainActor private func deploy() async {
        guard let connection, let site = selectedSite else { return }
        working = true
        defer { working = false }
        do {
            let files = try certificate.readDeploymentFiles()
            try await ServerSiteAPI.deployCertificate(connection: connection,
                                                      token: ServerConnectionStore.token(for: connectionID),
                                                      site: site, certificate: files.certificate,
                                                      privateKey: files.privateKey)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
