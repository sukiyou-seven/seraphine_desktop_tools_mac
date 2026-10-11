import SwiftUI

struct ServerSitesView: View {
    let connection: ServerConnection
    let token: String
    let openFiles: (String) -> Void
    let openStore: () -> Void

    @State private var listing = RemoteSiteListing(items: [], providers: [])
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false
    @State private var editing: RemoteSite?
    @State private var showingEditor = false
    @State private var pendingDelete: RemoteSite?
    @State private var provider = "nginx"
    @State private var domainInput = ""
    @State private var kind = "static"
    @State private var upstream = ""
    @State private var enabled = true

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
            Text("管理 Nginx、Apache 和 OpenResty 的静态站点与反向代理。网站文件在 /www/seraphim/web，日志在 /www/seraphim/logs。")
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
        .sheet(isPresented: $showingEditor) { editor }
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
                Text(verbatim: site.kind == "static" ? site.root : "代理至 \(site.upstream)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(webServer?.name ?? site.provider) · :\(webServer?.port ?? 80)")
                    .font(.callout)
                Text(site.enabled ? "已启用" : "已停用")
                    .font(.caption)
                    .foregroundStyle(site.enabled ? Color.green : Color.secondary)
            }
            .frame(width: 155, alignment: .trailing)
            if site.kind == "static" {
                Button("文件") { openFiles(site.root) }
            }
            Button("编辑") { beginEdit(site) }
                .disabled(working || webServer?.installed != true)
            Button(site.enabled ? "停用" : "启用") { toggle(site) }
                .disabled(working || webServer?.installed != true)
            Button("删除…", role: .destructive) { pendingDelete = site }.disabled(working)
        }
        .padding(.vertical, 12)
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
                    Text("反向代理").tag("proxy")
                }
                .pickerStyle(.segmented)
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
                Button("取消") { showingEditor = false }.disabled(working)
                Button("保存网站") { save() }.disabled(working)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 430)
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
        enabled = true
        showingEditor = true
    }

    private func beginEdit(_ site: RemoteSite) {
        message = ""
        hasError = false
        editing = site
        provider = site.provider
        domainInput = site.domains.joined(separator: ", ")
        kind = site.kind
        upstream = site.upstream
        enabled = site.enabled
        showingEditor = true
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
        let payload = RemoteSitePayload(provider: provider, domains: domains,
                                        kind: kind, upstream: upstream.trimmingCharacters(in: .whitespacesAndNewlines),
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
                showingEditor = false
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
                                        kind: site.kind, upstream: site.upstream, enabled: !site.enabled)
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
