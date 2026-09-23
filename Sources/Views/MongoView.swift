import SwiftUI

struct MongoView: View {
    @EnvironmentObject var model: AppModel
    @State private var section = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MongoHeader()
            if model.mongoNeedsCredentials {
                MongoAuthGuideCard()
            }
            Picker("", selection: $section) {
                Text("数据库").tag(0)
                Text("配置").tag(1)
                Text("用户与密码").tag(2)
                Text("日志").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                switch section {
                case 1: MongoConfigSection()
                case 2: MongoUsersSection()
                case 3: MongoLogSection()
                default: MongoDatabasesSection()
                }
            }
        }
        // 占满可用空间、从顶部排；内容再长也不撑大窗口（各页自己负责滚动）
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .navigationTitle("MongoDB")
        .onAppear {
            model.refreshMongoStatus()
            model.loadMongoDatabases()
        }
    }
}

// MARK: - 顶部状态与操作

private struct MongoHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "MongoDB") {
            HStack(spacing: 10) {
                StatusDot(running: model.mongoStatus.running)
                Text(verbatim: model.mongoStatus.running ? "运行中" : "已停止")
                    .font(.title3.weight(.semibold))
                Text(verbatim: model.mongoTarget)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("启动") { model.startMongo() }.disabled(model.mongoStatus.running)
                Button("停止") { model.stopMongo() }.disabled(!model.mongoStatus.running)
                Button("重启") { model.restartMongo() }.disabled(!model.mongoStatus.running)
                Button("刷新") { model.refreshMongoStatus() }
            }

            if !model.mongoStatus.installed {
                Text(verbatim: "未检测到 mongod。安装方式：brew install mongodb-community；装完后点「刷新」，或在设置里手动指定路径。")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// 已开启鉴权但工具没有管理员凭据时的自助指引（含 localhost exception 建第一个用户）
private struct MongoAuthGuideCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "已开启鉴权，但工具没有管理员凭据") {
            Text(verbatim: "mongod.conf 里 security.authorization 是 enabled，所以未认证的连接看不到数据库列表（返回空属于正常现象），也建不了库、改不了用户。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "两种处理：① 已经有管理员账号 → 到「设置」填用户名/密码（authSource 一般是 admin）；② 还没建过任何用户 → 用下面的一键创建，MongoDB 允许在库里没有任何用户时本地创建第一个。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 10) {
                Text("用户名").font(.callout).frame(width: 70, alignment: .leading)
                TextField("admin", text: $model.adminForm.user)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Picker("", selection: $model.adminForm.role) {
                    Text(verbatim: "root（全权限）").tag("root")
                    Text(verbatim: "userAdminAnyDatabase（只管用户）").tag("userAdminAnyDatabase")
                }
                .labelsHidden()
                .frame(width: 250)
            }
            PasswordField(label: "密码", placeholder: "可点「生成」", labelWidth: 70,
                          text: $model.adminForm.password)
            HStack {
                Button("创建管理员用户并填入设置") { model.createAdminUser() }
                    .disabled(model.adminForm.user.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.adminForm.password.isEmpty)
                Button("已有管理员，去设置里填") { model.tab = "settings" }
            }
        }
    }
}

// MARK: - 数据库

private struct MongoDatabasesSection: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingDelete: MongoDatabase?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "新建数据库") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("数据库名，例如 myapp", text: $model.newDatabaseName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                            .onChange(of: model.newDatabaseName) { _ in
                                model.syncNewDbUsername()
                            }
                        Button("创建") { model.createMongoDatabase() }
                            .disabled(model.newDatabaseName.trimmingCharacters(in: .whitespaces).isEmpty
                                      || !model.mongoStatus.running)
                        Text(verbatim: "惰性建库：会写入一个 _bootstrap 集合让它立刻可见。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Toggle("同时为这个库创建用户", isOn: $model.newDbCreateUser)
                        .disabled(!model.mongoStatus.running)
                        .onChange(of: model.newDbCreateUser) { _ in
                            model.syncNewDbUsername()
                        }

                    if model.newDbCreateUser {
                        HStack(spacing: 10) {
                            Text("用户名")
                                .font(.callout)
                                .frame(width: 200, alignment: .leading)
                            TextField("默认与数据库名相同", text: $model.newDbUsername)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                            Text(verbatim: "跟随库名，可手改")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        PasswordField(label: "密码", placeholder: "留空则自动生成一个", text: $model.newDbPassword)
                        HStack(spacing: 10) {
                            Text("角色（作用于该库）")
                                .font(.callout)
                                .frame(width: 200, alignment: .leading)
                            Picker("", selection: $model.newDbRole) {
                                ForEach(model.databaseRoleOptions, id: \.value) { option in
                                    Text(verbatim: option.label).tag(option.value)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                        Text(verbatim: model.mongoAuthEnabled
                             ? "实例已开启鉴权：这个密码就是该用户以后登录用的密码，请务必记牢（建好后可以直接复制）。"
                             : "实例当前未开启鉴权：先把用户建好，等把「是否开启鉴权」改成开启并重启后就生效。")
                            .font(.caption)
                            .foregroundStyle(model.mongoAuthEnabled ? Color.orange : Color.secondary)
                    }
                }
            }

            Card(title: "数据库列表") {
                HStack {
                    Button("刷新列表") { model.loadMongoDatabases() }
                        .disabled(!model.mongoStatus.running)
                    if !model.mongoStatus.running {
                        Text(verbatim: "服务未运行，先启动 MongoDB 再刷新。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = model.mongoDatabaseError {
                    Text(verbatim: error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                if model.mongoDatabases.isEmpty {
                    if model.mongoNeedsCredentials {
                        EmptyHint(text: "已开启鉴权但未提供凭据：未认证连接看不到任何库（MongoDB 的正常行为），请先按上面的指引填好凭据")
                    } else {
                        EmptyHint(text: "还没有读到数据库")
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("名称").font(.caption).frame(width: 150, alignment: .leading)
                            Text("占用").font(.caption).frame(width: 70, alignment: .leading)
                            Text("用户与密码").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            Spacer().frame(width: 56)
                        }
                        .padding(.vertical, 4)
                        Divider()
                        ForEach(model.mongoDatabases) { database in
                            HStack(alignment: .top, spacing: 8) {
                                Text(verbatim: database.name)
                                    .font(.system(.callout, design: .monospaced))
                                    .frame(width: 150, alignment: .leading)
                                Text(verbatim: database.sizeLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .leading)

                                VStack(alignment: .leading, spacing: 4) {
                                    let users = model.users(for: database.name)
                                    if users.isEmpty {
                                        Text(verbatim: "（没有用户）")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(users, id: \.self) { user in
                                            HStack(spacing: 10) {
                                                CopyableText(text: user)
                                                    .frame(width: 150, alignment: .leading)
                                                if let password = model.password(for: database.name, user: user) {
                                                    SecretCell(secret: password)
                                                } else {
                                                    Text(verbatim: "密码读不到（MongoDB 只存哈希）")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Button("重置密码") {
                                                    model.passwordResetTarget = PasswordResetTarget(
                                                        database: database.name, user: user)
                                                }
                                                .buttonStyle(.borderless)
                                                .font(.caption)
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Button("删除") { pendingDelete = database }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red)
                                    .frame(width: 56)
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                }
            }
            Card(title: "运行状态详情") {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "监听地址", value: model.mongoTarget)
                    InfoRow(label: "版本", value: model.mongoStatus.version)
                    InfoRow(label: "可执行文件", value: model.mongoStatus.binary)
                    InfoRow(label: "mongosh", value: model.mongoStatus.shell)
                    InfoRow(label: "进程 PID", value: model.mongoStatus.pid > 0 ? String(model.mongoStatus.pid) : "")
                    InfoRow(label: "配置文件", value: model.mongoStatus.confPath)
                    InfoRow(label: "数据目录", value: model.mongoStatus.dbPath)
                    InfoRow(label: "连通性", value: model.mongoStatus.ping)
                }
            }
        }
        .alert(item: $pendingDelete) { database in
            Alert(title: Text("删除数据库？"),
                  message: Text(verbatim: "将永久删除 \(database.name) 及其全部数据，无法恢复。"),
                  primaryButton: .destructive(Text("删除")) { model.dropMongoDatabase(database.name) },
                  secondaryButton: .cancel(Text("取消")))
        }
        .sheet(item: $model.passwordResetTarget) { target in
            PasswordResetSheet(target: target)
                .environmentObject(model)
        }
    }
}

// MARK: - 配置

private struct MongoConfigSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "配置文件") {
                InfoRow(label: "文件路径", value: model.mongoConfigFile)
                Text(verbatim: "保存时会先把原文件备份成 .bak，再写入新内容。服务运行中修改需要重启生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                if model.mongoParamRows.isEmpty { model.loadMongoConfig() }
            }

            Card(title: "管理员密码（root）") {
                InfoRow(label: "管理员用户名",
                        value: model.settings.mongo.adminUser.isEmpty ? "（未设置）" : model.settings.mongo.adminUser)
                InfoRow(label: "authSource", value: model.settings.mongo.authSource)
                PasswordField(label: "当前密码", placeholder: "用于连接数据库", text: $model.settings.mongo.adminPassword)
                PasswordField(label: "新密码", placeholder: "点「生成」或手动填一个", text: $model.adminReset.newPassword)
                HStack(spacing: 10) {
                    Button("重置密码") { model.resetAdminPassword() }
                        .disabled(!model.mongoStatus.running || model.adminReset.newPassword.isEmpty)
                    Button("把当前密码存进设置") { model.applySettings() }
                    Text(verbatim: "「重置密码」会用上面的「当前密码」连上去改，改完自动同步到设置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Card(title: "常用配置项") {
                if model.mongoParamRows.isEmpty {
                    EmptyHint(text: "点下面的按钮加载配置项")
                } else {
                    ForEach(model.mongoParamRows) { row in
                        ParamEditor(row: row) { newValue in
                            model.saveMongoParam(row, value: newValue)
                        }
                    }
                }
                Button("加载 / 重新读取") { model.loadMongoConfig() }
            }

            Card(title: "配置文件全文") {
                TextEditor(text: $model.mongoConfigText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 260)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25)))
                HStack {
                    Button("读取当前文件") { model.loadMongoConfig() }
                    Button("保存") { model.saveMongoConfigText() }
                    Text(verbatim: "YAML 格式，注意缩进用两个空格。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 用户与密码

private struct MongoUsersSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "查看用户") {
                HStack(spacing: 10) {
                    TextField("数据库名，例如 admin", text: $model.mongoUserDatabase)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Button("加载用户") { model.loadMongoUsers() }
                        .disabled(!model.mongoStatus.running)
                    Text(verbatim: "管理用户一般在 admin 库，业务用户建在业务库里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !model.mongoStatus.running {
                    Text(verbatim: "MongoDB 未运行：先点最上方的「启动」，再回来加载用户。")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                if model.mongoUsers.isEmpty {
                    if !model.mongoStatus.running {
                        EmptyHint(text: "服务未运行，加载不了")
                    } else if model.mongoUsersLoaded {
                        EmptyHint(text: "「\(model.mongoUsersLoadedDatabase)」库里没有任何用户")
                    } else {
                        EmptyHint(text: "还没加载：确认库名后点「加载用户」")
                    }
                } else {
                    ForEach(model.mongoUsers) { user in
                        HStack {
                            Text(verbatim: user.user)
                                .font(.system(.callout, design: .monospaced))
                                .frame(width: 220, alignment: .leading)
                            Text(verbatim: user.roles.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        Divider()
                    }
                }
            }

            Card(title: "创建用户 / 修改密码") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("数据库").font(.callout).frame(width: 70, alignment: .leading)
                        TextField("admin", text: $model.passwordForm.database)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    HStack(spacing: 10) {
                        Text("用户名").font(.callout).frame(width: 70, alignment: .leading)
                        TextField("例如 app_user", text: $model.passwordForm.user)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    PasswordField(label: "新密码", placeholder: "必填，可点「生成」", labelWidth: 70,
                                  text: $model.passwordForm.password)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("角色（作用于该库）").font(.callout)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], alignment: .leading, spacing: 4) {
                            ForEach(RoleCatalog.all, id: \.self) { role in
                                Toggle(role, isOn: Binding(
                                    get: { model.passwordForm.roles.contains(role) },
                                    set: { isOn in
                                        if isOn { model.passwordForm.roles.insert(role) }
                                        else { model.passwordForm.roles.remove(role) }
                                    }))
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    HStack {
                        Button("创建 / 更新用户") { model.applyMongoPassword() }
                            .disabled(model.passwordForm.user.trimmingCharacters(in: .whitespaces).isEmpty
                                      || model.passwordForm.password.isEmpty
                                      || !model.mongoStatus.running)
                        Text(verbatim: "用户名填成已存在的 → 改密码并覆盖角色；填新的 → 新建用户。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: "提示：若 mongod.conf 里 security.authorization 仍是 disabled，密码不会生效；启用鉴权后需要重启，并建议同时在「设置」里填好管理员账号以便本工具继续操作。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - 日志

private struct MongoLogSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "日志尾部") {
            HStack {
                Button("刷新日志") { model.loadMongoLog() }
                InfoRow(label: "日志文件", value: model.mongoStatus.logPath)
            }
            ReadonlyText(text: model.mongoLog, minHeight: 320)
        }
        .onAppear { model.loadMongoLog() }
    }
}
