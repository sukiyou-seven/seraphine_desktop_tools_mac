import SwiftUI

struct BTPanelView: View {
    @EnvironmentObject var model: AppModel
    @State private var section = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BTConnectionCard()

            if model.btConfigured {
                Picker("", selection: $section) {
                    Text("概览").tag(0)
                    Text("服务").tag(1)
                    Text("网站与 SSL").tag(2)
                    Text("数据库").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ScrollView {
                    switch section {
                    case 1: BTServicesSection()
                    case 2: BTSitesSection()
                    case 3: BTDatabaseSection()
                    default: BTOverviewSection()
                    }
                }
            } else {
                Text(verbatim: "填好面板地址和 API 密钥后即可使用。密钥在面板「设置 → API 接口」里开启并生成。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .navigationTitle("宝塔面板")
    }
}

// MARK: - 连接配置

private struct BTConnectionCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "面板连接") {
            HStack(spacing: 10) {
                Text("面板地址").font(.callout).frame(width: 90, alignment: .leading)
                TextField("http://1.2.3.4:8888", text: $model.settings.bt.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: 320)
                Text(verbatim: "含协议和端口，例如 http://1.2.3.4:8888 或 https://panel.example.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("API 密钥").font(.callout).frame(width: 90, alignment: .leading)
                SecureField("面板设置里生成的 api_sk", text: $model.settings.bt.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: 320)
                Toggle("忽略 HTTPS 证书校验", isOn: $model.settings.bt.allowInsecure)
                    .help("面板用自签证书时勾上")
            }
            HStack(spacing: 10) {
                Button("测试连接") { model.testBTConnection() }
                if !model.btStatusText.isEmpty {
                    Text(verbatim: model.btStatusText)
                        .font(.callout)
                        .foregroundStyle(model.btConnected ? Color.green : Color.orange)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: "密钥保存在工具设置文件里（明文），建议只在本机使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let ip = model.btBlockedIP {
                Divider()
                Text(verbatim: "面板的 API 开了 IP 白名单，当前出口 IP 不在名单里：")
                    .font(.callout)
                    .foregroundStyle(.orange)
                CopyableText(text: ip)
                Text(verbatim: "到「面板设置 → API 接口 → IP 白名单」把这个 IP 加进去（或清空白名单）。"
                     + "注意家用宽带的出口 IP 会变，变了要重新加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 概览

private struct BTOverviewSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "面板与系统") {
                HStack {
                    Button("刷新") { model.refreshBTOverview() }
                    Text(verbatim: "数据来自面板 API（/system?action=GetSystemTotal）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.btOverview.isEmpty {
                    EmptyHint(text: model.btConnected ? "还没有读到面板信息" : "先在上面点「测试连接」")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.btOverview) { row in
                            InfoRow(label: row.label, value: row.value)
                        }
                    }
                }
            }

            Card(title: "资源占用") {
                HStack {
                    Button("刷新") { model.refreshBTOverview() }
                    Text(verbatim: "数据来自 /system?action=GetSystemTotal 与 GetDiskInfo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.btResources.isEmpty && model.btDisks.isEmpty {
                    EmptyHint(text: model.btConnected ? "还没有读到资源信息" : "先在上面点「测试连接」")
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.btResources) { item in
                            UsageBar(label: item.label, detail: item.detail, fraction: item.fraction)
                        }
                        if !model.btResources.isEmpty && !model.btDisks.isEmpty {
                            Divider()
                        }
                        ForEach(model.btDisks) { disk in
                            UsageBar(label: disk.path,
                                     detail: "\(disk.usedText) / \(disk.totalText)　可用 \(disk.availText)",
                                     fraction: disk.fraction)
                        }
                    }
                }
            }

            Card(title: "最近一次 API 响应") {
                Text(verbatim: "面板版本不同时，接口名或参数可能有差异 —— 这里保留原始返回，方便对照排查。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ReadonlyText(text: model.btLastResponse, minHeight: 160)
            }
        }
    }
}

// MARK: - 服务

private struct BTServicesSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "服务管理") {
            Text(verbatim: "对应面板的 /system?action=ServiceAdmin。服务名要和面板里的保持一致（例如 php 是 php-fpm-74 这种）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("刷新服务状态") { model.loadBTServices() }
                if model.btServices.isEmpty {
                    Text(verbatim: "状态来自面板的软件列表接口，拿不到就显示「未知」（不瞎猜）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "已读到 \(model.btServices.count) 个软件/服务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                ForEach(BTServiceEntry.common) { service in
                    HStack(spacing: 8) {
                        Text(verbatim: service.label)
                            .font(.callout)
                            .frame(width: 110, alignment: .leading)
                        Text(verbatim: service.name)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)

                        // 状态三态：运行中 / 已停止 / 未安装（以服务器进程表为准）
                        let status = model.btServices.first { $0.name == service.name }
                        StatusDot(running: status?.running ?? false)
                        Text(verbatim: status?.statusLabel ?? "读取中…")
                            .font(.caption)
                            .foregroundStyle(statusColor(status))
                            .frame(width: 58, alignment: .leading)
                        Text(verbatim: (status?.processCount ?? 0) > 0
                             ? "\(status?.processCount ?? 0) 进程" : (status?.version ?? ""))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 76, alignment: .leading)

                        Spacer()
                        // 没装的不给启停；已运行的不给点「启动」，已停止的不给点「停止」。
                        // 颜色按可用性给：显式 foregroundStyle 会盖掉 .disabled 的默认灰化
                        let notInstalled = status != nil && status?.installed == false
                        let isRunning = status?.running == true
                        let canStart = !notInstalled && !isRunning
                        let canManage = !notInstalled && isRunning
                        let off = Color.secondary.opacity(0.45)
                        Group {
                            Button("启动") {
                                model.requestBTServiceAction(name: service.name, label: service.label, type: "start")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(canStart ? Color.green : off)
                            .disabled(!canStart)
                            Button("停止") {
                                model.requestBTServiceAction(name: service.name, label: service.label, type: "stop")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(canManage ? Color.red : off)
                            .disabled(!canManage)
                            Button("重启") {
                                model.requestBTServiceAction(name: service.name, label: service.label, type: "restart")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(canManage ? Color.orange : off)
                            .disabled(!canManage)
                            Button("重载") {
                                model.requestBTServiceAction(name: service.name, label: service.label, type: "reload")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(canManage ? Color.blue : off)
                            .disabled(!canManage)
                        }
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            }
        }
        .onAppear {
            if model.btServices.isEmpty { model.loadBTServices() }
        }
        .alert(item: $model.btPendingService) { pending in
            Alert(title: Text(verbatim: "\(model.btActionLabel(pending.type)) \(pending.serviceLabel)？"),
                  message: Text(verbatim: pending.type == "stop"
                                ? "停止后，依赖它的网站会立即不可用。"
                                : "\(model.btActionLabel(pending.type))会让该服务短暂中断。"),
                  primaryButton: .destructive(Text(verbatim: model.btActionLabel(pending.type))) {
                      model.confirmBTServiceAction()
                  },
                  secondaryButton: .cancel(Text("取消")))
        }
    }

    /// 服务状态颜色：运行中=绿、已停止=灰、未安装=橙（提示"没装就没得管"）
    private func statusColor(_ status: BTServiceStatus?) -> Color {
        guard let status else { return .secondary }
        if !status.installed { return .orange }
        guard let running = status.running else { return .orange }
        return running ? .green : .secondary
    }
}

// MARK: - 网站与 SSL

private struct BTSitesSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "把证书部署为网站 SSL") {
                Text(verbatim: "选一个已签发的证书 + 一个网站，工具会把证书内容提交给面板的 /site?action=SetSSL，自动配好 HTTPS。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("网站").font(.callout).frame(width: 70, alignment: .leading)
                    if model.btSites.isEmpty {
                        TextField("网站名（先刷新网站列表）", text: $model.btDeploySite)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    } else {
                        Picker("", selection: $model.btDeploySite) {
                            Text(verbatim: "请选择").tag("")
                            ForEach(model.btSites) { site in
                                Text(verbatim: site.name).tag(site.name)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    Text("证书").font(.callout)
                    if model.acmeCertificates.isEmpty {
                        Text(verbatim: "还没有证书：先去「证书」页申请")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Picker("", selection: $model.btDeployDomain) {
                            Text(verbatim: "请选择").tag("")
                            ForEach(model.acmeCertificates) { certificate in
                                Text(verbatim: certificate.domain).tag(certificate.domain)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    Button("部署证书") { model.deployCertificateToBTPanel() }
                        .disabled(model.btDeploySite.isEmpty || model.btDeployDomain.isEmpty)
                }
            }

            Card(title: "网站列表") {
                HStack {
                    Button("刷新") { model.loadBTSites() }
                    Text(verbatim: "来自面板 /data?action=getData&table=sites")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.btSites.isEmpty {
                    EmptyHint(text: "还没有网站，或还没刷新")
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Text("网站名").font(.caption).frame(width: 190, alignment: .leading)
                            Text("状态").font(.caption).frame(width: 60, alignment: .leading)
                            Text("类型").font(.caption).frame(width: 90, alignment: .leading)
                            Text("SSL").font(.caption).frame(width: 70, alignment: .leading)
                            Text("主域名").font(.caption).frame(width: 170, alignment: .leading)
                            Text("目录").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            Spacer().frame(width: 110)
                        }
                        .padding(.vertical, 4)
                        Divider()
                        ForEach(model.btSites) { site in
                            HStack(spacing: 8) {
                                Text(verbatim: site.name)
                                    .font(.system(.callout, design: .monospaced))
                                    .lineLimit(1)
                                    .frame(width: 190, alignment: .leading)
                                Text(verbatim: site.statusLabel)
                                    .font(.caption)
                                    .foregroundStyle(site.running ? Color.green : Color.secondary)
                                    .frame(width: 60, alignment: .leading)
                                Text(verbatim: site.typeLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .leading)
                                Text(verbatim: site.sslLabel)
                                    .font(.caption)
                                    .foregroundStyle(site.sslState == "已开启" ? Color.green
                                                     : (site.sslState == "未开启" ? Color.secondary : Color.orange))
                                    .frame(width: 70, alignment: .leading)
                                Text(verbatim: site.primaryDomain)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(width: 170, alignment: .leading)
                                Text(verbatim: site.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                // 不能点的按钮要**真的置灰**：显式 foregroundStyle 会盖掉
                                // .disabled 的默认灰化效果，所以这里自己按状态给颜色。
                                Button("启动") { model.requestBTSiteAction(site: site, start: true) }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                    .foregroundStyle(site.running ? Color.secondary.opacity(0.45) : Color.green)
                                    .disabled(site.running)
                                Button("停止") { model.requestBTSiteAction(site: site, start: false) }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                    .foregroundStyle(site.running ? Color.red : Color.secondary.opacity(0.45))
                                    .disabled(!site.running)
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                }
            }

            Card(title: "不同站点的启停方式") {
                Text(verbatim: "• PHP / 静态 HTML / 反向代理：由 nginx 直接服务，启停 = 切换该站点的 nginx 配置（工具调用 /site?action=SiteStart|SiteStop）。")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "• Python / Node / Java 等项目类：除了 nginx 配置还牵扯应用进程，宝塔内部处理方式不同 —— 如果启停后状态不对，请到面板里操作对应项目。")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "列表里的「类型」列就是按这个区分的；停站前的确认框也会按类型给出提示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if model.btSites.isEmpty { model.loadBTSites() }
        }
        .alert(item: $model.btPendingSite) { pending in
            Alert(title: Text(verbatim: "停止网站 \(pending.siteName)？"
                              + (pending.typeLabel.isEmpty || pending.typeLabel == "—"
                                 ? "" : "（\(pending.typeLabel)）")),
                  message: Text(verbatim: "停止后该网站的访问会立即中断。\n\n" + pending.note),
                  primaryButton: .destructive(Text("停止")) { model.confirmBTSiteAction() },
                  secondaryButton: .cancel(Text("取消")))
        }
    }
}

// MARK: - 数据库

private struct BTDatabaseSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "数据库列表") {
            HStack(spacing: 10) {
                // 类型切换：实测每种类型走各自的接口，返回字段也不一样
                Picker("", selection: Binding(
                    get: { model.btDatabaseTypeKey },
                    set: { model.selectBTDatabaseType($0) })) {
                    ForEach(BTDatabaseType.all) { t in
                        Text(verbatim: t.label).tag(t.key)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 560)
                Button("刷新") { model.loadBTDatabases() }
                Text(verbatim: "来自面板 /database/<类型>/get_list")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.btDatabases.isEmpty {
                let type = BTDatabaseType.find(model.btDatabaseTypeKey)
                EmptyHint(text: "没有读到 \(type.label) 的库。\n"
                              + "该类型没装、没有库，或面板这个版本不支持，都会是空的。")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("库名").font(.caption).frame(width: 170, alignment: .leading)
                        Text("用户名").font(.caption).frame(width: 150, alignment: .leading)
                        Text("密码").font(.caption).frame(width: 170, alignment: .leading)
                        Text("访问来源").font(.caption).frame(width: 100, alignment: .leading)
                        Text("键数量 / 添加时间").font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                    Divider()
                    ForEach(model.btDatabases) { database in
                        HStack(spacing: 8) {
                            Text(verbatim: database.name)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .frame(width: 170, alignment: .leading)
                            Text(verbatim: database.username.isEmpty ? "—" : database.username)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(database.username.isEmpty ? Color.secondary : Color.primary)
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            // 面板会给明文密码 —— 默认打码，要看/要复制再点
                            SecretCell(secret: database.password)
                                .frame(width: 170, alignment: .leading)
                            Text(verbatim: database.accept.isEmpty ? "—" : database.accept)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 100, alignment: .leading)
                            // Redis 给的是键数量，没有添加时间
                            Text(verbatim: database.keynum > 0
                                 ? "\(database.keynum) 个键"
                                 : (database.addtime.isEmpty ? "—" : database.addtime))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
        }
        .onAppear {
            if model.btDatabases.isEmpty { model.loadBTDatabases() }
        }
    }
}
