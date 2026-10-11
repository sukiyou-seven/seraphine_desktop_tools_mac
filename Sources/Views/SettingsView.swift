import SwiftUI

/// 设置页：按模块分标签，不再是一整条长表单。
///
/// 「打开软件时自动启动」默认**关闭**（`StartupSettings` 默认 false）。
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                Text("常规").tag(0)
                Text("MongoDB").tag(1)
                Text("Redis").tag(2)
                Text("MySQL").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case 1: mongoSettings
                    case 2: redisSettings
                    case 3: mysqlSettings
                    default: generalSettings
                    }
                }
                .padding(.bottom, 8)
            }
        }
        // 占满可用空间：长表单不再把窗口撑大（不然连侧边栏都会被顶到屏幕外）
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .navigationTitle("设置")
    }

    // MARK: 常规（诊断 / 探测 / 自动启动）

    @ViewBuilder
    private var generalSettings: some View {
        Text(verbatim: "所有路径留空表示自动探测（Homebrew 默认位置 → PATH）。只有需要自定义时才填写。密码保存在 \(Paths.settingsFile.path)。")
            .font(.caption)
            .foregroundStyle(.secondary)

        Card(title: "诊断") {
            InfoRow(label: "运行日志", value: Diag.logURL.path)
            InfoRow(label: "崩溃记录", value: Diag.crashURL.path)
            InfoRow(label: "设置文件", value: Paths.settingsFile.path)
            HStack {
                Button("打开日志文件夹") { NSWorkspace.shared.open(Paths.logDir) }
                Button("打开设置文件") { NSWorkspace.shared.open(Paths.settingsFile) }
                Text(verbatim: "点「启动」没反应时，先看运行日志里最后几行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Card(title: "自动探测结果") {
            ForEach(model.discoveredRows, id: \.0) { row in
                InfoRow(label: row.0, value: row.1)
            }
            Button("重新探测（清空自定义设置）") { model.resetSettings() }
        }

        Card(title: "打开软件时自动启动") {
            Toggle("打开 Seraphim 时自动启动 MongoDB", isOn: Binding(
                get: { model.settings.startup.autoStartMongo },
                set: { value in
                    model.settings.startup.autoStartMongo = value
                    model.persistSettings()
                }))
            .toggleStyle(.checkbox)
            Toggle("打开 Seraphim 时自动启动 Redis", isOn: Binding(
                get: { model.settings.startup.autoStartRedis },
                set: { value in
                    model.settings.startup.autoStartRedis = value
                    model.persistSettings()
                }))
            .toggleStyle(.checkbox)
            Text(verbatim: "两个开关**默认关闭**。本工具不注册系统级开机自启（不写 LaunchAgent、不进「登录项」）：只在你打开本软件后，按这里勾选的开关把服务拉起来 —— 已经在运行就跳过，失败会在界面提示。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        saveRow
    }

    // MARK: MongoDB

    private var mongoSettings: some View {
        Card(title: "MongoDB 设置") {
            SettingField(label: "mongod 路径", placeholder: "留空自动探测", text: $model.settings.mongo.bin)
            SettingField(label: "mongosh 路径", placeholder: "留空自动探测（建库/密码需要）", text: $model.settings.mongo.shell)
            SettingField(label: "mongod.conf", placeholder: "留空自动探测", text: $model.settings.mongo.config)
            SettingField(label: "数据目录 dbPath", placeholder: "留空自动探测", text: $model.settings.mongo.dbpath)
            SettingField(label: "日志文件", placeholder: "留空使用工具目录", text: $model.settings.mongo.logpath)
            HStack(spacing: 10) {
                Text("端口").font(.callout).frame(width: 200, alignment: .leading)
                TextField("27017", value: $model.settings.mongo.port, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            SettingField(label: "监听地址 bindIp", placeholder: "127.0.0.1", text: $model.settings.mongo.bindIp)
            Divider()
            Text(verbatim: "以下管理员账号用于「建库 / 用户密码」等需要鉴权的操作（实例未开启鉴权时可留空）")
                .font(.caption)
                .foregroundStyle(.secondary)
            SettingField(label: "管理员用户名", placeholder: "留空 = 无鉴权直连", text: $model.settings.mongo.adminUser)
            SettingSecureField(label: "管理员密码", text: $model.settings.mongo.adminPassword)
            SettingField(label: "authSource", placeholder: "admin", text: $model.settings.mongo.authSource)
            saveRow
        }
    }

    // MARK: Redis

    private var redisSettings: some View {
        Card(title: "Redis 设置") {
            SettingField(label: "redis-server 路径", placeholder: "留空自动探测", text: $model.settings.redis.bin)
            SettingField(label: "redis-cli 路径", placeholder: "留空自动探测（本工具不需要）", text: $model.settings.redis.cli)
            SettingField(label: "redis.conf", placeholder: "留空自动探测", text: $model.settings.redis.config)
            SettingField(label: "工作目录 dir", placeholder: "留空自动探测", text: $model.settings.redis.dir)
            SettingField(label: "日志文件", placeholder: "留空使用工具目录", text: $model.settings.redis.logfile)
            SettingField(label: "PID 文件", placeholder: "留空使用工具目录", text: $model.settings.redis.pidfile)
            HStack(spacing: 10) {
                Text("端口").font(.callout).frame(width: 200, alignment: .leading)
                TextField("6379", value: $model.settings.redis.port, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            SettingField(label: "监听地址 bind", placeholder: "127.0.0.1", text: $model.settings.redis.bind)
            SettingSecureField(label: "密码 requirepass", text: $model.settings.redis.password)
            saveRow
        }
    }

    // MARK: MySQL

    private var mysqlSettings: some View {
        Card(title: "MySQL 设置") {
            SettingField(label: "mysql 客户端路径", placeholder: "留空自动探测", text: $model.settings.mysql.bin)
            SettingField(label: "mysqld 路径", placeholder: "留空自动探测", text: $model.settings.mysql.serverBin)
            SettingField(label: "mysqladmin 路径", placeholder: "留空自动探测", text: $model.settings.mysql.adminBin)
            SettingField(label: "my.cnf", placeholder: "留空自动探测", text: $model.settings.mysql.config)
            SettingField(label: "数据目录 datadir", placeholder: "留空自动探测", text: $model.settings.mysql.datadir)
            SettingField(label: "错误日志", placeholder: "留空使用工具目录", text: $model.settings.mysql.logpath)
            SettingField(label: "socket 文件", placeholder: "留空使用工具目录", text: $model.settings.mysql.socket)
            HStack(spacing: 10) {
                Text("端口").font(.callout).frame(width: 200, alignment: .leading)
                TextField("3306", value: $model.settings.mysql.port, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            SettingField(label: "监听地址", placeholder: "127.0.0.1", text: $model.settings.mysql.host)
            Divider()
            Text(verbatim: "下面两项用于连接、执行管理 SQL（刚装好时 root 通常没有密码，留空即可）")
                .font(.caption)
                .foregroundStyle(.secondary)
            SettingField(label: "管理员用户名", placeholder: "root", text: $model.settings.mysql.adminUser)
            SettingSecureField(label: "管理员密码", text: $model.settings.mysql.adminPassword)
            saveRow
        }
    }

    // MARK: 保存行

    private var saveRow: some View {
        HStack(spacing: 10) {
            Button("保存设置") { model.applySettings() }
            Button("恢复默认") { model.resetSettings() }
            if !model.settingsMessage.isEmpty {
                Text(verbatim: model.settingsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 通用表单行（设置页与证书页共用）
struct SettingField: View {
    var label: String
    var placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).frame(width: 200, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
        }
    }
}

struct SettingSecureField: View {
    var label: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).frame(width: 200, alignment: .leading)
            SecureField("密码（明文保存在设置文件里）", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
        }
    }
}

/// 百分比滑块：拖动即时改值（由 `value` 的 setter 负责），松手时回调 `onCommit` 落盘。
struct SettingSlider: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var onCommit: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).frame(width: 200, alignment: .leading)
            Slider(value: $value, in: range, step: 0.01) { editing in
                if !editing { onCommit() }
            }
            Text(verbatim: "\(Int((value * 100).rounded()))%")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
