import SwiftUI

struct ServerSitesView: View {
    let connection: ServerConnection
    let token: String
    let openFiles: (String) -> Void
    let openStore: () -> Void
    let openDomains: () -> Void

    @State private var listing = RemoteSiteListing(items: [], providers: [], phpVersions: [])
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false
    @State private var editing: RemoteSite?
    @State private var sheet: SiteSheet?
    @State private var pendingDelete: RemoteSite?
    @State private var provider = "nginx"
    @State private var domainInput = ""
    @State private var kind = "static"
    @State private var upstream = ""
    @State private var phpVersion = ""
    @State private var enabled = true

    /// 同一个视图上挂多个 sheet 会互相顶掉，编辑与部署证书共用一个。
    private enum SiteSheet: Identifiable {
        case editor
        case certificate(RemoteSite)

        var id: String {
            switch self {
            case .editor: return "editor"
            case .certificate(let site): return "certificate:" + site.uniqueID
            }
        }
    }

    private var installedProviders: [RemoteSiteProvider] {
        listing.providers.filter(\.installed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("网站管理").font(.title3.weight(.semibold))
                Spacer()
                Button("刷新") { Task { await refresh() } }.disabled(working)
                Button("新建网站") { beginCreate() }
                    .disabled(working || installedProviders.isEmpty)
                if working { ProgressView().controlSize(.small) }
            }
            Text("管理 Nginx、Apache 和 OpenResty 的静态、PHP 与反向代理网站。网站文件在 /www/seraphim/web，日志在 /www/seraphim/logs。证书在「域名管理」申请后可就地部署到网站，启用 443 的 HTTPS。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(hasError ? Color.orange : Color.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 12) {
                ForEach(listing.providers) { webServer in
                    HStack(spacing: 6) {
                        Text(webServer.name).fontWeight(.medium)
                        Text(webServer.installed ? (webServer.running ? "运行中" : "已停止") : "未安装")
                            .foregroundStyle(webServer.installed ? Color.secondary : Color.orange)
                        Text(":\(webServer.port)").foregroundStyle(.secondary)
                        if webServer.installed && !webServer.running {
                            Button("启动") { start(webServer) }.disabled(working)
                                .buttonStyle(.link)
                        }
                    }
                    .font(.caption)
                }
                Spacer(minLength: 0)
            }
            if installedProviders.isEmpty {
                HStack {
                    Text("请先安装 Nginx、Apache 或 OpenResty。")
                        .foregroundStyle(.secondary)
                    Button("打开软件商店", action: openStore)
                }
            }
            FlexibleScroll {
                VStack(alignment: .leading, spacing: 0) {
                    if listing.items.isEmpty && !working {
                        EmptyHint(text: "暂无网站，安装 Web 服务后可新建")
                    }
                    ForEach(listing.items, id: \.uniqueID) { site in
                        siteRow(site)
                        Divider()
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
        .sheet(item: $sheet) { entry in
            switch entry {
            case .editor:
                editor
            case .certificate(let site):
                SiteCertificateSheet(site: site, connection: connection, token: token,
                                     openDomains: openDomains,
                                     onDeployed: {
                                         message = "证书已部署，\(site.primaryDomain) 已启用 HTTPS"
                                         hasError = false
                                         Task { await refresh() }
                                     })
            }
        }
        .confirmationDialog("删除网站 \(pendingDelete?.primaryDomain ?? "")？",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } })) {
            if let site = pendingDelete {
                Button("删除网站配置", role: .destructive) {
                    pendingDelete = nil
                    remove(site)
                }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("将删除 Web 服务中的网站配置；网站文件仍保留在 /www/seraphim/web，可到文件管理中处理。")
        }
    }

    private func siteRow(_ site: RemoteSite) -> some View {
        let webServer = listing.providers.first(where: { $0.id == site.provider })
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: site.domains.joined(separator: "、"))
                    .font(.headline)
                    .lineLimit(1)
                Text(verbatim: site.kind == "proxy" ? "代理至 \(site.upstream)" :
                     site.kind == "php" ? "PHP \(site.phpVersion ?? "") · \(site.root)" : site.root)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(webServer?.name ?? site.providerLabel) · :\(webServer?.port ?? 80)")
                    .font(.callout)
                Text(site.enabled ? "已启用" : "已停用")
                    .font(.caption)
                    .foregroundStyle(site.enabled ? Color.green : Color.secondary)
                Text(tlsStatus(site))
                    .font(.caption)
                    .foregroundStyle(site.tlsEnabled ? Color.green : Color.orange)
            }
            .frame(width: 175, alignment: .trailing)
            if site.kind != "proxy" {
                Button("文件") { openFiles(site.root) }
            }
            Button(site.tlsEnabled ? "更换证书" : "部署证书") { sheet = .certificate(site) }
                .disabled(working || !site.enabled || webServer?.installed != true)
                .help(site.enabled
                      ? "从本机已签发的证书里挑一张部署到该网站，启用 443 的 HTTPS"
                      : "网站已停用，先启用再部署证书")
            Button("编辑") { beginEdit(site) }
                .disabled(working || webServer?.installed != true)
            Button(site.enabled ? "停用" : "启用") { toggle(site) }
                .disabled(working || webServer?.installed != true)
            Button("删除…", role: .destructive) { pendingDelete = site }.disabled(working)
        }
        .padding(.vertical, 12)
    }

    /// 行内显示的 HTTPS 状态。证书文件读得到时带上到期日期，续期前一眼能看出来。
    private func tlsStatus(_ site: RemoteSite) -> String {
        guard site.tlsEnabled else { return "HTTPS 未部署" }
        guard let expiry = site.tlsExpiryDate else { return "HTTPS 443" }
        return "HTTPS 至 \(expiry)"
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing == nil ? "新建网站" : "编辑网站")
                .font(.title3.weight(.semibold))
            Form {
                Picker("Web 服务", selection: $provider) {
                    ForEach(installedProviders) { entry in
                        Text("\(entry.name) · :\(entry.port)").tag(entry.id)
                    }
                }
                .disabled(editing != nil)
                TextField("域名（多个用逗号或空格分隔）", text: $domainInput)
                    .textFieldStyle(.roundedBorder)
                Picker("网站类型", selection: $kind) {
                    Text("静态站点").tag("static")
                    Text("PHP 网站").tag("php")
                    Text("反向代理").tag("proxy")
                }
                .pickerStyle(.segmented)
                if kind == "php" {
                    Picker("PHP 版本", selection: $phpVersion) {
                        ForEach(listing.phpVersions ?? [], id: \.self) { version in
                            Text(version).tag(version)
                        }
                    }
                    if (listing.phpVersions ?? []).isEmpty {
                        Text("请先到环境管理安装 PHP；启用网站时会自动启动对应的 PHP-FPM。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if kind == "proxy" {
                    TextField("上游地址，例如 http://127.0.0.1:3000", text: $upstream)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("启用网站", isOn: $enabled)
            }
            .formStyle(.grouped)
            Text(verbatim: editing?.root ?? "/www/seraphim/web/\(provider)/\(parsedDomains.first ?? "域名")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if hasError && !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
            HStack {
                Spacer()
                Button("取消") { sheet = nil }.disabled(working)
                Button("保存网站") { save() }.disabled(working)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
    }

    private var parsedDomains: [String] {
        domainInput.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }).map(String.init)
    }

    private func beginCreate() {
        message = ""
        hasError = false
        editing = nil
        provider = installedProviders.first?.id ?? "nginx"
        domainInput = ""
        kind = "static"
        upstream = ""
        phpVersion = listing.phpVersions?.first ?? ""
        enabled = true
        sheet = .editor
    }

    private func beginEdit(_ site: RemoteSite) {
        message = ""
        hasError = false
        editing = site
        provider = site.provider
        domainInput = site.domains.joined(separator: ", ")
        kind = site.kind
        upstream = site.upstream
        phpVersion = site.phpVersion ?? listing.phpVersions?.first ?? ""
        enabled = site.enabled
        sheet = .editor
    }

    @MainActor private func refresh() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            listing = try await ServerSiteAPI.list(connection: connection, token: token)
            message = ""
            hasError = false
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }

    private func save() {
        let domains = parsedDomains
        guard !domains.isEmpty else {
            message = "请填写至少一个域名"
            hasError = true
            return
        }
        if kind == "php" && phpVersion.isEmpty {
            message = "请先安装 PHP 运行环境"
            hasError = true
            return
        }
        let payload = RemoteSitePayload(provider: provider, domains: domains,
                                        kind: kind, upstream: upstream.trimmingCharacters(in: .whitespacesAndNewlines),
                                        phpVersion: kind == "php" ? phpVersion : nil,
                                        enabled: enabled)
        let existing = editing
        working = true
        Task { @MainActor in
            do {
                if let existing {
                    try await ServerSiteAPI.update(connection: connection, token: token,
                                                   site: existing, payload: payload)
                } else {
                    _ = try await ServerSiteAPI.create(connection: connection, token: token,
                                                       payload: payload)
                }
                working = false
                sheet = nil
                await refresh()
                message = "网站配置已保存"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func toggle(_ site: RemoteSite) {
        let payload = RemoteSitePayload(provider: site.provider, domains: site.domains,
                                        kind: site.kind, upstream: site.upstream,
                                        phpVersion: site.phpVersion, enabled: !site.enabled)
        working = true
        Task { @MainActor in
            do {
                try await ServerSiteAPI.update(connection: connection, token: token,
                                               site: site, payload: payload)
                working = false
                await refresh()
                message = site.enabled ? "网站已停用" : "网站已启用"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func remove(_ site: RemoteSite) {
        working = true
        Task { @MainActor in
            do {
                try await ServerSiteAPI.delete(connection: connection, token: token, site: site)
                working = false
                await refresh()
                message = "网站配置已删除；网站文件已保留"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func start(_ webServer: RemoteSiteProvider) {
        working = true
        Task { @MainActor in
            do {
                try await ServerSoftwareAPI.service(connection: connection, token: token,
                                                    id: webServer.id, action: "start")
                working = false
                await refresh()
                message = "\(webServer.name) 已启动"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }
}
