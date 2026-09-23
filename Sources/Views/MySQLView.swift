import SwiftUI

struct MySQLView: View {
    @EnvironmentObject var model: AppModel
    @State private var section = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MySQLHeader()
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
                case 1: MySQLConfigSection()
                case 2: MySQLUsersSection()
                case 3: MySQLLogSection()
                default: MySQLDatabasesSection()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .navigationTitle("MySQL")
        .onAppear {
            model.refreshMySQLStatus()
            model.loadMySQLDatabases()
        }
    }
}

// MARK: - 顶部状态

private struct MySQLHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "MySQL") {
            HStack(spacing: 10) {
                StatusDot(running: model.mysqlStatus.running)
                Text(verbatim: model.mysqlStatus.running ? "运行中" : "已停止")
                    .font(.title3.weight(.semibold))
                Text(verbatim: model.mysqlTarget)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("启动") { model.startMySQL() }.disabled(model.mysqlStatus.running)
                Button("停止") { model.stopMySQL() }.disabled(!model.mysqlStatus.running)
                Button("重启") { model.restartMySQL() }.disabled(!model.mysqlStatus.running)
                Button("刷新") { model.refreshMySQLStatus() }
            }

            if !model.mysqlStatus.installed {
                Text(verbatim: "未检测到 MySQL。安装方式：brew install mysql；装完后点「刷新」，或在「设置」里手动指定路径。")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - 数据库

private struct MySQLDatabasesSection: View {
    @EnvironmentObject var model: AppModel
    @State private var pendingDelete: MySQLDatabase?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "新建数据库") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("数据库名，例如 myapp", text: $model.newMySQLDatabase)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                        Button("创建") { model.createMySQLDatabase() }
                            .disabled(model.newMySQLDatabase.trimmingCharacters(in: .whitespaces).isEmpty
                                      || !model.mysqlStatus.running)
                        Text(verbatim: "字符集固定 utf8mb4。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Toggle("同时为这个库创建用户并授权", isOn: $model.mysqlCreateUser)

                    if model.mysqlCreateUser {
                        HStack(spacing: 10) {
                            Text("用户名")
                                .font(.callout)
                                .frame(width: 200, alignment: .leading)
                            TextField("默认与数据库名相同", text: $model.mysqlNewUser)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 240)
                            Text("允许来源")
                                .font(.callout)
                            TextField("%", text: $model.mysqlNewUserHost)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }
                        PasswordField(label: "密码", placeholder: "留空则自动生成一个", text: $model.mysqlNewPassword)
                        HStack(spacing: 10) {
                            Text("权限")
                                .font(.callout)
                                .frame(width: 200, alignment: .leading)
                            Picker("", selection: $model.mysqlNewUserPrivilege) {
                                Text(verbatim: "ALL PRIVILEGES（该库全部权限）").tag("all")
                                Text(verbatim: "读写（SELECT/INSERT/UPDATE/DELETE）").tag("readwrite")
                                Text(verbatim: "只读（SELECT）").tag("read")
                            }
                            .labelsHidden()
                            .frame(width: 300)
                        }
                        Text(verbatim: "「允许来源」填 % 表示任意主机，localhost 表示只允许本机。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Card(title: "数据库列表") {
                HStack {
                    Button("刷新列表") { model.loadMySQLDatabases() }
                        .disabled(!model.mysqlStatus.running)
                    if !model.mysqlStatus.running {
                        Text(verbatim: "服务未运行，先启动 MySQL 再刷新。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = model.mysqlDatabaseError {
                    Text(verbatim: error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                if model.mysqlDatabases.isEmpty {
                    EmptyHint(text: model.mysqlStatus.running ? "还没有读到数据库" : "服务未运行")
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
                        ForEach(model.mysqlDatabases) { database in
                            HStack(alignment: .top, spacing: 8) {
                                Text(verbatim: database.name)
                                    .font(.system(.callout, design: .monospaced))
                                    .frame(width: 150, alignment: .leading)
                                Text(verbatim: database.sizeLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .leading)

                                VStack(alignment: .leading, spacing: 4) {
                                    let users = model.mysqlUsers(for: database.name)
                                    if users.isEmpty {
                                        Text(verbatim: "（没有本工具创建的账号）")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(users, id: \.self) { user in
                                            HStack(spacing: 10) {
                                                CopyableText(text: user)
                                                    .frame(width: 190, alignment: .leading)
                                                if let password = model.mysqlPassword(for: database.name, user: user) {
                                                    SecretCell(secret: password)
                                                } else {
                                                    Text(verbatim: "密码读不到（MySQL 只存哈希）")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
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
        }
        .alert(item: $pendingDelete) { database in
            Alert(title: Text("删除数据库？"),
                  message: Text(verbatim: "将永久删除 \(database.name) 及其全部数据表，无法恢复。"),
                  primaryButton: .destructive(Text("删除")) { model.dropMySQLDatabase(database.name) },
                  secondaryButton: .cancel(Text("取消")))
        }
    }
}

// MARK: - 配置

private struct MySQLConfigSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "配置文件（my.cnf）") {
                InfoRow(label: "文件路径", value: model.mysqlConfigFile)
                Text(verbatim: "保存时会先备份成 .bak。改动需要重启 MySQL 才生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                if model.mysqlParamRows.isEmpty { model.loadMySQLConfig() }
            }

            Card(title: "常用配置项") {
                if model.mysqlParamRows.isEmpty {
                    EmptyHint(text: "点下面的按钮加载配置项")
                } else {
                    ForEach(model.mysqlParamRows) { row in
                        ParamEditor(row: row) { newValue in
                            model.saveMySQLParam(row, value: newValue)
                        }
                    }
                }
                Button("加载 / 重新读取") { model.loadMySQLConfig() }
            }

            Card(title: "配置文件全文") {
                TextEditor(text: $model.mysqlConfigText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 240)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25)))
                HStack {
                    Button("读取当前文件") { model.loadMySQLConfig() }
                    Button("保存") { model.saveMySQLConfigText() }
                }
            }
        }
        .onAppear {
            if model.mysqlParamRows.isEmpty { model.loadMySQLConfig() }
        }
    }
}

// MARK: - 用户与密码

private struct MySQLUsersSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "已有用户") {
                HStack {
                    Button("刷新列表") { model.loadMySQLUsers() }
                        .disabled(!model.mysqlStatus.running)
                    Text(verbatim: "MySQL 的用户是「用户名 + 允许来源」的组合。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.mysqlUsers.isEmpty {
                    EmptyHint(text: model.mysqlStatus.running ? "没有读到用户" : "服务未运行")
                } else {
                    ForEach(model.mysqlUsers) { user in
                        HStack(spacing: 10) {
                            CopyableText(text: user.display)
                                .frame(width: 220, alignment: .leading)
                            Spacer()
                        }
                        Divider()
                    }
                }
            }

            Card(title: "创建用户 / 修改密码") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("用户名").font(.callout).frame(width: 90, alignment: .leading)
                        TextField("例如 myapp", text: $model.mysqlUserForm.user)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        Text("允许来源").font(.callout)
                        TextField("%", text: $model.mysqlUserForm.host)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    }
                    PasswordField(label: "密码", placeholder: "必填，可点「生成」", labelWidth: 90,
                                  text: $model.mysqlUserForm.password)
                    HStack(spacing: 10) {
                        Text("授权到库").font(.callout).frame(width: 90, alignment: .leading)
                        TextField("可留空（不授权）", text: $model.mysqlUserForm.database)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        Picker("", selection: $model.mysqlUserForm.privilege) {
                            Text(verbatim: "ALL PRIVILEGES").tag("all")
                            Text(verbatim: "读写").tag("readwrite")
                            Text(verbatim: "只读").tag("read")
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    HStack {
                        Button("创建 / 改密码") { model.applyMySQLUserPassword() }
                            .disabled(model.mysqlUserForm.user.trimmingCharacters(in: .whitespaces).isEmpty
                                      || model.mysqlUserForm.password.isEmpty
                                      || !model.mysqlStatus.running)
                        Text(verbatim: "用户已存在 → 改密码；不存在 → 新建。填了「授权到库」就一并授权。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { model.loadMySQLUsers() }
    }
}

// MARK: - 日志

private struct MySQLLogSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "错误日志尾部") {
            HStack {
                Button("刷新日志") { model.loadMySQLLog() }
                InfoRow(label: "日志文件", value: model.mysqlStatus.logPath)
            }
            ReadonlyText(text: model.mysqlLog, minHeight: 320)
        }
        .onAppear { model.loadMySQLLog() }
    }
}
