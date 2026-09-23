import SwiftUI

struct CertificateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ACMEStatusCard()

                if model.acmeStatus.installed {
                    ACMEIssueCard()
                    if model.acmeMode == "manual" {
                        ACMManualCard()
                    }
                    ACMEDeployCard()
                    ACMEICloudCard()
                    ACMECertificatesCard()
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .navigationTitle("证书")
        .onAppear {
            model.refreshACMEStatus()
            model.loadCertificates()
        }
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
            }

            if model.acmeStatus.installed {
                InfoRow(label: "acme.sh 路径", value: model.acmeStatus.bin)
                InfoRow(label: "证书目录", value: model.acmeStatus.home)
            } else {
                Text(verbatim: "申请 Let's Encrypt 证书需要 acme.sh。它是单文件 shell 脚本，零依赖，"
                     + "并且内置阿里云 DNS 插件（DNS-01 验证就靠它）。")
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
                    Text(verbatim: "多个用逗号分隔；泛域名写 *.example.com")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    Text(verbatim: "手动 DNS（自己加 TXT 记录）").tag("manual")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if model.acmeMode == "aliyun" {
                    Text(verbatim: "填阿里云 AccessKey 后，工具会自动在 _acme-challenge 下添加 TXT 记录、等验证通过、再删掉记录，全程无需人工。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Text("AccessKey ID")
                            .font(.callout)
                            .frame(width: 120, alignment: .leading)
                        TextField("LTAI...", text: $model.settings.acme.aliKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                    }
                    SettingSecureField(label: "AccessKey Secret", text: $model.settings.acme.aliSecret)
                    Text(verbatim: "提示：凭据保存在工具的设置文件里（明文），请用只有 DNS 权限的 RAM 子账号。")
                        .font(.caption)
                        .foregroundStyle(.orange)

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

// MARK: - 部署

private struct ACMEDeployCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "把证书复制到指定位置（可选）") {
            Text(verbatim: "申请好的证书在 acme.sh 的目录里；要让 Nginx 等直接读，可以复制一份过去，并在续期后自动重载。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("域名").font(.callout).frame(width: 90, alignment: .leading)
                TextField("example.com", text: $model.acmeDeployDomain)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Text("重载命令").font(.callout)
                TextField("可选，例如 nginx -s reload", text: $model.settings.acme.reloadCmd)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            SettingField(label: "key 目标路径", placeholder: "/etc/nginx/ssl/example.com.key",
                         text: $model.acmeDeployKeyPath)
            SettingField(label: "fullchain 目标路径", placeholder: "/etc/nginx/ssl/example.com.fullchain.pem",
                         text: $model.acmeDeployFullchainPath)
            HStack {
                Button("复制证书") { model.deployCertificate() }
                    .disabled(model.acmeDeployDomain.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.acmeDeployKeyPath.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.acmeDeployFullchainPath.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("安装自动续期任务") { model.installACMECron() }
                Text(verbatim: "续期任务由 acme.sh 的 cron 负责，装一次即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - iCloud 备份

private struct ACMEICloudCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "备份到 iCloud Drive") {
            Text(verbatim: "把证书复制一份到 iCloud 云盘，多台设备都能取用。"
                 + "这里用的是 acme.sh 的「证书安装」能力，所以它会在每次续期后自动更新 iCloud 里的副本 —— 备份一次就够了。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text("iCloud 子目录").font(.callout).frame(width: 130, alignment: .leading)
                TextField("DBManager/certs", text: $model.settings.acme.icloudSubdir)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: 300)
                Text(verbatim: "证书会放在「iCloud 云盘 / <子目录> / <域名> /」下")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let iCloud = ACMEService.iCloudDrivePath {
                InfoRow(label: "iCloud Drive", value: iCloud)
            } else {
                Text(verbatim: "没有检测到 iCloud Drive：请在「系统设置 → Apple 账户 → iCloud」里打开「iCloud 云盘」。")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("备份所有证书到 iCloud") { model.backupAllCertificatesToICloud() }
                    .disabled(!model.acmeStatus.installed || model.acmeCertificates.isEmpty)
                Text(verbatim: "每张证书目录里会有 privkey.pem（私钥）和 fullchain.pem（证书链）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(verbatim: "⚠️ 私钥会随 iCloud 同步到你所有 Apple 设备。证书本身是公开信息，私钥才是要害 —— 不放心就别用这个功能。")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 已签发的证书

private struct ACMECertificatesCard: View {
    @EnvironmentObject var model: AppModel

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
                        Text("类型").font(.caption).frame(width: 80, alignment: .leading)
                        Text("下次续期").font(.caption).frame(width: 200, alignment: .leading)
                        Text("证书路径").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        Spacer().frame(width: 70)
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

                            Text(verbatim: certificate.keyLength)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Text(verbatim: certificate.renewAt.isEmpty ? "—" : String(certificate.renewAt.prefix(16)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 200, alignment: .leading)
                            CopyableText(text: certificate.fullchainPath, monospaced: false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("续期") { model.renewCertificate(certificate.domain) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .frame(width: 70)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
        }
    }
}
