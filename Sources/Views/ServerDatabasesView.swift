import SwiftUI
import AppKit

private struct DatabaseSecretSheet: Identifiable {
    let id = UUID()
    let title: String
    let username: String
    let password: String
}

struct ServerDatabasesView: View {
    let connection: ServerConnection
    let token: String
    let openStore: () -> Void

    @State private var instances: [RemoteDatabaseInstance] = []
    @State private var selectedID = "mysql"
    @State private var catalog: RemoteDatabaseCatalog?
    @State private var keyValueACL: RemoteKeyValueACL?
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false
    @State private var newDatabase = ""
    @State private var createAccountWithDatabase = true
    @State private var newDatabaseUser = ""
    @State private var newDatabaseLevel = "readwrite"
    @State private var newUser = ""
    @State private var grantDatabase = ""
    @State private var grantUser = ""
    @State private var grantLevel = "readwrite"
    @State private var pendingDelete: (kind: String, name: String)?
    @State private var pendingReset: String?
    @State private var showBootstrap = false
    @State private var showPostgresAccess = false
    @State private var showCredential = false
    @State private var credential = ""
    @State private var showChangeCredential = false
    @State private var currentCredential = ""
    @State private var newCredential = ""
    @State private var keyValueLevel = "readwrite"
    @State private var keyValueCredential = ""
    @State private var showKeyValueCredential = false
    @State private var showEnableKeyValueACL = false
    @State private var keyValuePendingDelete: String?
    @State private var keyValuePendingReset: String?
    @State private var secretSheet: DatabaseSecretSheet?
    /// 密码类弹窗自己的错误信息。不能用主视图的 message：弹窗打开时它被盖住，用户只会看到"点了没反应"。
    @State private var sheetError = ""

    private var selected: RemoteDatabaseInstance? { instances.first(where: { $0.id == selectedID }) }
    private var availableUsers: [RemoteDatabaseUser] {
        catalog?.users.filter { user in
            let protected = ["root", "postgres", "seraphim-postgres", "mysql", "mysql.sys", "mysql.session", "mysql.infoschema"]
            let valid = user.name.range(of: "^[A-Za-z][A-Za-z0-9_]{0,31}$", options: .regularExpression) != nil
            return valid && !protected.contains(user.name.lowercased()) &&
                (selectedID == "postgresql" || user.host == "localhost")
        } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("数据库管理").font(.title3.weight(.semibold))
                Spacer()
                Button("刷新") { Task { await refresh() } }.disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            Text("管理七种数据库实例。MySQL、MariaDB、PostgreSQL 支持数据库与授权；Redis、Valkey 支持持久化 ACL 账户和读写权限。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(hasError ? Color.orange : Color.secondary)
                    .lineLimit(3)
            }
            HStack(alignment: .top, spacing: 16) {
                instanceList
                    .frame(width: 215)
                Divider()
                if let selected {
                    detail(selected)
                } else {
                    EmptyHint(text: "选择数据库实例")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { Task { await refresh() } }
        .onChange(of: selectedID) { _ in
            catalog = nil
            keyValueACL = nil
            message = ""
            Task { await loadCatalog() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .serverManagementRefresh)) { _ in
            Task { await refresh() }
        }
        .confirmationDialog("删除 \(pendingDelete?.name ?? "")？",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            if let deletion = pendingDelete {
                Button(deletion.kind == "database" ? "删除数据库及全部数据" : "删除用户", role: .destructive) {
                    pendingDelete = nil
                    remove(deletion.kind, name: deletion.name)
                }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.kind == "database" ? "数据库及其中的数据将无法从此操作恢复。" : "用户将失去通过该账户连接数据库的能力。")
        }
        .confirmationDialog("重置 \(pendingReset ?? "") 的密码？",
                            isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } })) {
            if let username = pendingReset {
                Button("生成新密码") {
                    pendingReset = nil
                    resetPassword(username)
                }
            }
            Button("取消", role: .cancel) { pendingReset = nil }
        } message: {
            Text("旧密码将立即失效，需要更新使用该账户的项目配置。")
        }
        .confirmationDialog("初始化 MySQL 管理密码？", isPresented: $showBootstrap) {
            Button("生成并设置新密码") { bootstrapMySQL() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将使用安装时生成的一次性密码，为 MySQL root 设置新密码。完成后会显示新密码，并保存在服务器的受限配置文件中。")
        }
        .confirmationDialog("启用 PostgreSQL 本机密码连接？", isPresented: $showPostgresAccess) {
            Button("更新配置并重启") { enablePostgresAccess() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将仅允许服务器本机通过密码连接 PostgreSQL，并保留管理账户的本机认证。服务会重启一次。")
        }
        .sheet(isPresented: $showCredential) { credentialSheet }
        .sheet(isPresented: $showChangeCredential) { changeCredentialSheet }
        .sheet(isPresented: $showKeyValueCredential) { keyValueCredentialSheet }
        .confirmationDialog("启用持久化 ACL 账户管理？", isPresented: $showEnableKeyValueACL) {
            Button("更新配置并重启") { enableKeyValueACL() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("会把现有 ACL 账户写入数据库的数据目录，更新配置并重启服务。")
        }
        .confirmationDialog("删除账户 \(keyValuePendingDelete ?? "")？",
                            isPresented: Binding(get: { keyValuePendingDelete != nil }, set: { if !$0 { keyValuePendingDelete = nil } })) {
            if let name = keyValuePendingDelete {
                Button("删除账户", role: .destructive) { keyValuePendingDelete = nil; deleteKeyValueUser(name) }
            }
            Button("取消", role: .cancel) { keyValuePendingDelete = nil }
        } message: {
            Text("使用该账户的客户端将无法再连接。")
        }
        .confirmationDialog("重置 \(keyValuePendingReset ?? "") 的密码？",
                            isPresented: Binding(get: { keyValuePendingReset != nil }, set: { if !$0 { keyValuePendingReset = nil } })) {
            if let name = keyValuePendingReset {
                Button("生成新密码") { keyValuePendingReset = nil; resetKeyValueUser(name) }
            }
            Button("取消", role: .cancel) { keyValuePendingReset = nil }
        } message: {
            Text("旧密码会立即失效，新密码只显示一次。")
        }
        .sheet(item: $secretSheet) { secret in
            VStack(alignment: .leading, spacing: 15) {
                Text(verbatim: secret.title).font(.title3.weight(.semibold))
                InfoRow(label: "账户", value: secret.username)
                HStack {
                    Text("密码").frame(width: 70, alignment: .leading)
                    Text(verbatim: secret.password)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Button("复制密码") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(secret.password, forType: .string)
                    }
                }
                Text("请将此密码保存到需要连接数据库的应用配置中；关闭窗口后不会再次显示普通用户密码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("完成") { secretSheet = nil }
                }
            }
            .padding(20)
            .frame(width: 620)
        }
    }

    private var instanceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实例").font(.headline)
            FlexibleScroll {
                VStack(spacing: 4) {
                    ForEach(instances) { instance in
                        Button { selectedID = instance.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(instance.name).fontWeight(selectedID == instance.id ? .semibold : .regular)
                                    Text(instance.installed ? (instance.running ? "运行中" : "已停止") : "未安装")
                                        .font(.caption)
                                        .foregroundStyle(instance.running ? Color.green : Color.secondary)
                                }
                                Spacer()
                                if instance.port > 0 { Text(":\(instance.port)").font(.caption).foregroundStyle(.secondary) }
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                            .background(selectedID == instance.id ? Color.accentColor.opacity(0.13) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func detail(_ instance: RemoteDatabaseInstance) -> some View {
        FlexibleScroll {
            VStack(alignment: .leading, spacing: 12) {
                Card(title: "\(instance.name) · \(instance.version)") {
                    HStack {
                        Text(instance.installed ? (instance.running ? "运行中" : "已停止") : "未安装")
                            .foregroundStyle(instance.running ? Color.green : Color.secondary)
                        if instance.port > 0 { Text("本机端口 \(instance.port)").foregroundStyle(.secondary) }
                        Spacer()
                        if !instance.installed {
                            Button("打开软件商店", action: openStore)
                        } else if instance.id != "sqlite" {
                            Button(instance.running ? "停止" : "启动") {
                                service(instance, action: instance.running ? "stop" : "start")
                            }
                            .disabled(working)
                            if instance.running {
                                Button("重启") { service(instance, action: "restart") }.disabled(working)
                            }
                        }
                    }
                }
                if instance.installed && instance.manageUsers && instance.running {
                    if instance.id == "mysql" {
                        HStack {
                            Button("初始化管理密码") { showBootstrap = true }
                                .disabled(working || instance.authState == "configured")
                            Button("设置已有管理密码…") { credential = ""; sheetError = ""; showCredential = true }
                                .disabled(working)
                            Button("查看已保存密码") { revealPassword(engine: "mysql") }.disabled(working)
                            Button("修改管理密码…") { currentCredential = ""; newCredential = ""; sheetError = ""; showChangeCredential = true }.disabled(working)
                            if instance.authState == "initial" {
                                Text("安装时的临时密码尚未初始化").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    if instance.id == "postgresql" && instance.authState != "local_password" {
                        HStack {
                            Text("当前仅支持管理账户的本机认证，普通账户还不能使用密码连接。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("启用本机密码连接…") { showPostgresAccess = true }.disabled(working)
                        }
                    }
                    databaseSection(instance)
                    userSection(instance)
                    grantSection(instance)
                } else if instance.installed && instance.running && ["redis", "valkey"].contains(instance.id) {
                    keyValueSection(instance)
                } else if instance.installed && !instance.manageUsers {
                    Text(instance.id == "sqlite" ? "SQLite 是文件数据库，没有服务器账户。可通过文件管理查看其数据库文件。" :
                         ["redis", "valkey"].contains(instance.id) ? "启动服务后可管理 ACL 账户。" : "该实例的库内操作尚未接入；可在软件管理中控制服务。")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func databaseSection(_ instance: RemoteDatabaseInstance) -> some View {
        Card(title: "数据库") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("新数据库名", text: $newDatabase)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    Toggle("同时创建账户", isOn: $createAccountWithDatabase)
                        .toggleStyle(.checkbox)
                    if createAccountWithDatabase {
                        TextField("账户名（留空则与库同名）", text: $newDatabaseUser)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                        Picker("权限", selection: $newDatabaseLevel) {
                            Text("读写").tag("readwrite")
                            Text("只读").tag("read")
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                    Spacer()
                    Button("创建数据库") { createDatabase() }
                        .disabled(working || newDatabase.isEmpty)
                }
                if createAccountWithDatabase {
                    Text("账户密码由服务端自动生成，创建后直接显示一次；无需再单独建用户。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let catalog {
                ForEach(catalog.databases, id: \.self) { name in
                    HStack {
                        Text(verbatim: name).font(.system(.body, design: .monospaced))
                        Spacer()
                        if !isSystemDatabase(name, engine: instance.id) {
                            Button("删除…", role: .destructive) { pendingDelete = ("database", name) }
                                .disabled(working)
                        } else {
                            Text("系统库").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } else {
                Text("尚未读取数据库列表").foregroundStyle(.secondary)
            }
        }
    }

    private func userSection(_ instance: RemoteDatabaseInstance) -> some View {
        Card(title: "账户") {
            HStack {
                TextField("新用户名", text: $newUser)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Button("创建账户并生成密码") { createUser() }
                    .disabled(working || newUser.isEmpty)
                Spacer()
            }
            if let catalog {
                ForEach(catalog.users) { user in
                    HStack {
                        Text(verbatim: user.name + (user.host.isEmpty ? "" : "@" + user.host))
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        if availableUsers.contains(where: { $0.id == user.id }) {
                            Button("查看密码") { revealPassword(engine: instance.id, user: user.name) }.disabled(working)
                            Button("重置密码…") { pendingReset = user.name }.disabled(working)
                            Button("删除…", role: .destructive) { pendingDelete = ("user", user.name) }
                                .disabled(working)
                        } else {
                            Text("系统或非本机账户").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func grantSection(_ instance: RemoteDatabaseInstance) -> some View {
        Card(title: "授权") {
            if let catalog, !availableUsers.isEmpty,
               !catalog.databases.filter({ !isSystemDatabase($0, engine: instance.id) }).isEmpty {
                HStack {
                    Picker("数据库", selection: $grantDatabase) {
                        ForEach(catalog.databases.filter { !isSystemDatabase($0, engine: instance.id) }, id: \.self) { name in
                            Text(verbatim: name).tag(name)
                        }
                    }
                    .frame(maxWidth: 240)
                    Picker("账户", selection: $grantUser) {
                        ForEach(availableUsers) { user in Text(verbatim: user.name).tag(user.name) }
                    }
                    .frame(maxWidth: 220)
                    Picker("权限", selection: $grantLevel) {
                        Text("只读").tag("read")
                        Text("读写").tag("readwrite")
                    }
                    .frame(width: 130)
                }
                HStack {
                    Button("授权") { grant(revoke: false) }
                        .disabled(working || grantDatabase.isEmpty || grantUser.isEmpty)
                    Button("撤销此库权限", role: .destructive) { grant(revoke: true) }
                        .disabled(working || grantDatabase.isEmpty || grantUser.isEmpty)
                    Spacer()
                }
                Text("授权会增加所选权限；若要从读写改为只读，请先撤销此库权限，再重新授权。PostgreSQL 同时设置 public schema 的现有表和序列权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("先创建普通数据库和账户，再设置授权。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func keyValueSection(_ instance: RemoteDatabaseInstance) -> some View {
        Card(title: "ACL 账户") {
            HStack {
                Text("只允许从服务器本机连接；密码由服务端生成并仅显示一次。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("设置已有管理员密码…") { keyValueCredential = ""; sheetError = ""; showKeyValueCredential = true }
                    .disabled(working)
                Button("查看已保存密码") { revealPassword(engine: instance.id) }.disabled(working)
            }
            if let keyValueACL {
                if !keyValueACL.persistent {
                    HStack {
                        Text("ACL 配置尚未持久化，账户变更会在重启后丢失。")
                            .font(.caption).foregroundStyle(.orange)
                        Button("启用持久化…") { showEnableKeyValueACL = true }.disabled(working)
                    }
                } else {
                    HStack {
                        TextField("新用户名", text: $newUser)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                        Picker("权限", selection: $keyValueLevel) {
                            Text("只读").tag("read")
                            Text("读写").tag("readwrite")
                        }.frame(width: 130)
                        Button("创建账户") { createKeyValueUser() }
                            .disabled(working || newUser.isEmpty)
                        Spacer()
                    }
                }
                ForEach(keyValueACL.users) { user in
                    HStack {
                        Text(verbatim: user.name).font(.system(.body, design: .monospaced))
                        Text(user.enabled ? "已启用" : "已停用")
                            .font(.caption).foregroundStyle(user.enabled ? Color.green : Color.secondary)
                        Text(keyValueLevelText(user.level)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if canManageKeyValueUser(user.name) && keyValueACL.persistent &&
                            ["read", "readwrite"].contains(user.level) {
                            Button("查看密码") { revealPassword(engine: instance.id, user: user.name) }.disabled(working)
                            Button(user.enabled ? "停用" : "启用") {
                                updateKeyValueUser(user, level: user.level, enabled: !user.enabled)
                            }.disabled(working)
                            Button(user.level == "read" ? "设为读写" : "设为只读") {
                                updateKeyValueUser(user, level: user.level == "read" ? "readwrite" : "read", enabled: user.enabled)
                            }.disabled(working)
                            Button("重置密码…") { keyValuePendingReset = user.name }.disabled(working)
                            Button("删除…", role: .destructive) { keyValuePendingDelete = user.name }.disabled(working)
                        } else if user.name == "default" {
                            Text("系统账户").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("自定义账户").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            } else {
                Text("尚未读取 ACL 账户；若默认账户设置了密码，请先保存管理员密码。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func keyValueLevelText(_ level: String) -> String {
        switch level {
        case "read": return "只读"
        case "readwrite": return "读写"
        case "admin": return "管理员"
        default: return "自定义权限"
        }
    }

    private func canManageKeyValueUser(_ name: String) -> Bool {
        guard name.range(of: "^[A-Za-z][A-Za-z0-9_]{0,31}$", options: .regularExpression) != nil else { return false }
        let protected = ["default", "root", "postgres", "seraphim_postgres", "mysql", "mysql_sys", "mysql_session", "mysql_innodb_cluster_metadata"]
        return !protected.contains(name.lowercased()) && !name.lowercased().hasPrefix("pg_")
    }

    private var keyValueCredentialSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置已有默认账户密码").font(.title3.weight(.semibold))
            SecureField("当前密码", text: $keyValueCredential)
                .textFieldStyle(.roundedBorder)
            Text("服务端会先验证密码，再保存到仅 root 可读的文件中。")
                .font(.caption).foregroundStyle(.secondary)
            if !sheetError.isEmpty {
                Text(verbatim: sheetError).font(.callout).foregroundStyle(Color.orange).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("取消") { showKeyValueCredential = false }
                Button("验证并保存") { saveKeyValueCredential() }
                    .disabled(keyValueCredential.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var credentialSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置已有 MySQL root 密码").font(.title3.weight(.semibold))
            SecureField("当前 root 密码", text: $credential)
                .textFieldStyle(.roundedBorder)
            Text("服务端会先验证密码，再保存到仅 root 可读的配置文件；此处不使用 macOS 钥匙串。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !sheetError.isEmpty {
                Text(verbatim: sheetError).font(.callout).foregroundStyle(Color.orange).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("取消") { showCredential = false }
                Button("验证并保存") { saveCredential() }.disabled(credential.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var changeCredentialSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("修改 MySQL root 密码").font(.title3.weight(.semibold))
            SecureField("当前密码（已保存在服务端时可留空）", text: $currentCredential)
            SecureField("新密码（至少 8 位）", text: $newCredential)
            Text("服务端先验证当前密码，再修改数据库中的密码并保存新值；不允许单引号和反斜杠。")
                .font(.caption).foregroundStyle(.secondary)
            if !sheetError.isEmpty {
                Text(verbatim: sheetError).font(.callout).foregroundStyle(Color.orange).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("取消") { showChangeCredential = false }
                Button("修改") { changeCredential() }.disabled(working || newCredential.count < 8)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func isSystemDatabase(_ name: String, engine: String) -> Bool {
        let protected = engine == "postgresql" ? ["postgres", "template0", "template1"]
            : ["mysql", "information_schema", "performance_schema", "sys"]
        return protected.contains(name.lowercased())
    }

    @MainActor private func refresh() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            instances = try await ServerDatabaseAPI.list(connection: connection, token: token)
            if !instances.contains(where: { $0.id == selectedID }) { selectedID = instances.first?.id ?? "mysql" }
            message = ""
            hasError = false
        } catch {
            message = error.localizedDescription
            hasError = true
            return
        }
        await loadCatalogWhileWorking()
    }

    @MainActor private func loadCatalog() async {
        guard !working else { return }
        working = true
        defer { working = false }
        await loadCatalogWhileWorking()
    }

    @MainActor private func loadCatalogWhileWorking() async {
        guard let instance = selected, instance.running else { catalog = nil; keyValueACL = nil; return }
        if ["redis", "valkey"].contains(instance.id) {
            catalog = nil
            do {
                keyValueACL = try await ServerDatabaseAPI.keyValueACL(connection: connection, token: token, engine: instance.id)
                message = ""
                hasError = false
            } catch {
                keyValueACL = nil
                message = error.localizedDescription
                hasError = true
            }
            return
        }
        keyValueACL = nil
        guard instance.manageUsers else { catalog = nil; return }
        do {
            let updated = try await ServerDatabaseAPI.catalog(connection: connection, token: token, engine: instance.id)
            catalog = updated
            let nonSystem = updated.databases.filter { !isSystemDatabase($0, engine: instance.id) }
            if !nonSystem.contains(grantDatabase) { grantDatabase = nonSystem.first ?? "" }
            if !availableUsers.contains(where: { $0.name == grantUser }) { grantUser = availableUsers.first?.name ?? "" }
            message = ""
            hasError = false
        } catch {
            catalog = nil
            message = error.localizedDescription
            hasError = true
        }
    }

    private func service(_ instance: RemoteDatabaseInstance, action: String) {
        working = true
        Task { @MainActor in
            do {
                try await ServerSoftwareAPI.service(connection: connection, token: token, id: instance.id, action: action)
                working = false
                await refresh()
                message = "服务操作已完成"
                hasError = false
            } catch { working = false; message = error.localizedDescription; hasError = true }
        }
    }

    private func createDatabase() {
        let name = newDatabase.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = selectedID
        var account = createAccountWithDatabase ? newDatabaseUser.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if createAccountWithDatabase && account.isEmpty { account = name }
        if !account.isEmpty && account.range(of: "^[A-Za-z][A-Za-z0-9_]{0,31}$", options: .regularExpression) == nil {
            message = "账户名须以字母开头，只能包含字母、数字和下划线，最长 32 位"
            hasError = true
            return
        }
        let level = newDatabaseLevel
        working = true
        Task { @MainActor in
            do {
                let created = try await ServerDatabaseAPI.createDatabase(connection: connection, token: token,
                                                                        engine: engine, name: name, user: account, level: level)
                newDatabase = ""
                newDatabaseUser = ""
                working = false
                await loadCatalog()
                message = account.isEmpty ? "数据库 \(name) 已创建" : "数据库 \(name) 已创建，账户 \(account) 已授权"
                hasError = false
                if let created, !created.password.isEmpty {
                    secretSheet = DatabaseSecretSheet(title: "新账户密码（仅显示一次）", username: created.user, password: created.password)
                }
            } catch { working = false; message = error.localizedDescription; hasError = true }
        }
    }

    private func createUser() {
        let name = newUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = selectedID
        working = true
        Task { @MainActor in
            do {
                let result = try await ServerDatabaseAPI.createUser(connection: connection, token: token, engine: engine, name: name)
                newUser = ""
                working = false
                await loadCatalog()
                secretSheet = DatabaseSecretSheet(title: "账户已创建", username: result.user, password: result.password)
            } catch { working = false; message = error.localizedDescription; hasError = true }
        }
    }

    private func remove(_ kind: String, name: String) {
        let engine = selectedID
        working = true
        Task { @MainActor in
            do {
                if kind == "database" {
                    try await ServerDatabaseAPI.deleteDatabase(connection: connection, token: token, engine: engine, name: name)
                } else {
                    try await ServerDatabaseAPI.deleteUser(connection: connection, token: token, engine: engine, name: name)
                }
                working = false
                await loadCatalog()
                message = "\(name) 已删除"
                hasError = false
            } catch { working = false; message = error.localizedDescription; hasError = true }
        }
    }

    private func resetPassword(_ name: String) {
        let engine = selectedID
        working = true
        Task { @MainActor in
            do {
                let result = try await ServerDatabaseAPI.resetPassword(connection: connection, token: token, engine: engine, name: name)
                working = false
                secretSheet = DatabaseSecretSheet(title: "密码已重置", username: result.user, password: result.password)
            } catch { working = false; message = error.localizedDescription; hasError = true }
        }
    }

    private func grant(revoke: Bool) {
        let engine = selectedID
        let database = grantDatabase
        let user = grantUser
        let level = grantLevel
        working = true
        Task { @MainActor in
            do {
                try await ServerDatabaseAPI.grant(connection: connection, token: token, engine: engine,
                                                  database: database, user: user, level: level, revoke: revoke)
                working = false
                message = revoke ? "已撤销 \(user) 对 \(database) 的权限" : "已为 \(user) 授权 \(database)"
                hasError = false
            } catch { working = false; message = error.localizedDescription; hasError = true }
        }
    }

    private func bootstrapMySQL() {
        working = true
        Task { @MainActor in
            do {
                let result = try await ServerDatabaseAPI.bootstrapMySQL(connection: connection, token: token)
                working = false
                await refresh()
                secretSheet = DatabaseSecretSheet(title: "MySQL 管理密码已初始化", username: result.user, password: result.password)
            } catch { working = false; message = error.localizedDescription; hasError = true }
        }
    }

    private func saveCredential() {
        let password = credential
        working = true
        Task { @MainActor in
            do {
                try await ServerDatabaseAPI.setMySQLCredential(connection: connection, token: token, password: password)
                credential = ""
                showCredential = false
                working = false
                await refresh()
                message = "MySQL 管理密码已验证并保存"
                hasError = false
            } catch { working = false; sheetError = error.localizedDescription; message = error.localizedDescription; hasError = true }
        }
    }

    private func revealPassword(engine: String, user: String? = nil) {
        Task { @MainActor in
            do {
                let result = try await ServerDatabaseAPI.savedPassword(connection: connection, token: token, engine: engine, user: user)
                secretSheet = DatabaseSecretSheet(title: "已保存的密码", username: result.user, password: result.password)
            } catch {
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func changeCredential() {
        let current = currentCredential
        let next = newCredential
        working = true
        Task { @MainActor in
            do {
                try await ServerDatabaseAPI.changeMySQLCredential(connection: connection, token: token,
                                                                 current: current, next: next)
                currentCredential = ""
                newCredential = ""
                showChangeCredential = false
                working = false
                await refresh()
                message = "MySQL 管理密码已修改并保存"
                hasError = false
            } catch { working = false; sheetError = error.localizedDescription; message = error.localizedDescription; hasError = true }
        }
    }

    private func enablePostgresAccess() {
        working = true
        Task { @MainActor in
            do {
                try await ServerDatabaseAPI.enablePostgresLocalAccess(connection: connection, token: token)
                working = false
                await refresh()
                message = "PostgreSQL 已启用本机密码连接"
                hasError = false
            } catch { working = false; message = error.localizedDescription; hasError = true }
        }
    }

    private func enableKeyValueACL() {
        let engine = selectedID
        working = true
        Task { @MainActor in
            do {
                try await ServerDatabaseAPI.enableKeyValueACL(connection: connection, token: token, engine: engine)
                working = false
                await loadCatalog()
                message = "ACL 持久化已启用"
                hasError = false
            } catch { working = false; message = error.localizedDescription; hasError = true }
        }
    }

    private func saveKeyValueCredential() {
        let engine = selectedID
        let password = keyValueCredential
        working = true
        Task { @MainActor in
            do {
                try await ServerDatabaseAPI.setKeyValueCredential(connection: connection, token: token,
                                                                   engine: engine, password: password)
                keyValueCredential = ""
                showKeyValueCredential = false
                working = false
                await loadCatalog()
                message = "管理员密码已验证并保存"
                hasError = false
            } catch { working = false; sheetError = error.localizedDescription; message = error.localizedDescription; hasError = true }
        }
    }

    private func createKeyValueUser() {
        let engine = selectedID
        let name = newUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let level = keyValueLevel
        working = true
        Task { @MainActor in
            do {
                let result = try await ServerDatabaseAPI.createKeyValueUser(connection: connection, token: token,
                                                                              engine: engine, name: name, level: level)
                newUser = ""
                working = false
                await loadCatalog()
                secretSheet = DatabaseSecretSheet(title: "ACL 账户已创建", username: result.user, password: result.password)
            } catch { working = false; message = error.localizedDescription; hasError = true }
        }
    }

    private func resetKeyValueUser(_ name: String) {
        let engine = selectedID
        working = true
        Task { @MainActor in
            do {
                let result = try await ServerDatabaseAPI.resetKeyValueUser(connection: connection, token: token,
                                                                             engine: engine, name: name)
                working = false
                secretSheet = DatabaseSecretSheet(title: "ACL 密码已重置", username: result.user, password: result.password)
            } catch { working = false; message = error.localizedDescription; hasError = true }
        }
    }

    private func updateKeyValueUser(_ user: RemoteKeyValueUser, level: String, enabled: Bool) {
        let engine = selectedID
        working = true
        Task { @MainActor in
            do {
                try await ServerDatabaseAPI.updateKeyValueUser(connection: connection, token: token,
                                                                engine: engine, name: user.name, level: level, enabled: enabled)
                working = false
                await loadCatalog()
                message = "账户权限已更新"
                hasError = false
            } catch { working = false; message = error.localizedDescription; hasError = true }
        }
    }

    private func deleteKeyValueUser(_ name: String) {
        let engine = selectedID
        working = true
        Task { @MainActor in
            do {
                try await ServerDatabaseAPI.deleteKeyValueUser(connection: connection, token: token,
                                                                engine: engine, name: name)
                working = false
                await loadCatalog()
                message = "账户 \(name) 已删除"
                hasError = false
            } catch { working = false; message = error.localizedDescription; hasError = true }
        }
    }
}
