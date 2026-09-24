import Foundation
import SwiftUI

struct ParamRow: Identifiable {
    var id: String
    var label: String
    var value: String
    var placeholder: String
    var options: [ConfStore.KeySpec.Option] = []
}

struct ConsoleEntry: Identifiable {
    let id = UUID()
    var command: String
    var output: String
    var ok: Bool
}

struct Toast: Equatable {
    var text: String
    var ok: Bool
    var detail: String = ""
}

struct AdminForm {
    var user = "admin"
    var password = PasswordGenerator.make()
    var role = "root"
}

/// 「配置」页里重置管理员密码用
struct AdminResetForm {
    var newPassword = ""
}

/// 数据库列表里点「重置密码」时的目标
struct PasswordResetTarget: Identifiable {
    var database: String
    var user: String
    var id: String { "\(database)/\(user)" }
}

struct PasswordForm {
    var database = "admin"
    var user = ""
    var password = ""
    var roles: Set<String> = ["readWrite"]
}

enum RoleCatalog {
    static let all = ["read", "readWrite", "dbAdmin", "dbOwner", "userAdmin",
                      "readAnyDatabase", "readWriteAnyDatabase", "userAdminAnyDatabase",
                      "dbAdminAnyDatabase", "root", "clusterMonitor", "clusterAdmin"]
}

@MainActor
final class AppModel: ObservableObject {

    // 通用
    @Published var settings: AppSettings
    @Published var tab: String = "mongo"
    @Published var busy: String?
    @Published var toast: Toast?
    @Published var settingsMessage = ""

    // 网络代理（IKEv2 VPN）
    @Published var vpnProbe: VPNProbe?
    @Published var vpnStatus = VPNStatus()
    @Published var vpnLog = ""
    @Published var vpnInstallDone = false
    /// 本机已取回的描述文件路径
    @Published var vpnLocalProfile = ""

    // MongoDB
    @Published var mongoStatus = MongoStatus()
    @Published var mongoDatabases: [MongoDatabase] = []
    @Published var mongoDatabaseError: String?
    @Published var mongoParamRows: [ParamRow] = []
    @Published var mongoConfigText = ""
    @Published var mongoConfigFile = ""
    @Published var mongoLog = ""
    @Published var mongoUsers: [MongoUser] = []
    @Published var mongoUserDatabase = "admin"
    @Published var mongoUsersLoaded = false
    @Published var mongoUsersLoadedDatabase = ""
    @Published var newDatabaseName = ""
    @Published var newDbCreateUser = true
    @Published var newDbUsername = ""
    /// 上一次自动同步进来的用户名，用来判断用户是否手动改过。
    private var lastAutoUsername = ""
    @Published var newDbPassword = ""
    @Published var newDbRole = "readWrite"
    @Published var mongoAuthEnabled = false
    @Published var adminForm = AdminForm()
    @Published var adminReset = AdminResetForm()
    /// 非 nil 时弹出「重置密码」输入框
    @Published var passwordResetTarget: PasswordResetTarget?
    /// 工具为各库创建的账号凭据（来自 credentials.json）
    @Published var credentials: [DatabaseCredential] = []
    /// 数据库里真实存在的用户（从 MongoDB 查出来，供列表显示）
    @Published var databaseUsers: [MongoDbUser] = []
    @Published var passwordForm = PasswordForm()

    // Redis
    @Published var redisStatus = RedisStatus()
    @Published var redisParamRows: [ParamRow] = []
    @Published var redisConfigText = ""
    @Published var redisConfigFile = ""
    @Published var redisDatabase = 0
    @Published var redisPattern = "*"
    @Published var redisRows: [RedisKeyRow] = []
    @Published var redisCursor = 0
    @Published var redisScannedAll = true
    @Published var redisTotalKeys = 0
    @Published var redisPage = 0
    @Published var redisSelectedKey: String?
    @Published var redisDetail: RedisValueDetail?
    @Published var redisDetailError: String?
    @Published var redisOverview: RedisOverview?
    @Published var redisOverviewError: String?
    @Published var consoleInput = ""
    @Published var consoleEntries: [ConsoleEntry] = []
    @Published var redisLog = ""

    private var mongo: MongoService
    private var redis: RedisService
    private var mysql: MySQLService
    private var acme: ACMEService
    private var bt: BTPanelService
    private var vpn: VPNService

    init() {
        Diag.log("AppModel 初始化")
        let loaded = SettingsStore.load()
        settings = loaded
        mongo = MongoService(settings: loaded.mongo)
        redis = RedisService(settings: loaded.redis)
        mysql = MySQLService(settings: loaded.mysql)
        acme = ACMEService(settings: loaded.acme)
        bt = BTPanelService(settings: loaded.bt)
        vpn = VPNService(settings: loaded.vpn)
    }

    // MARK: 服务与设置

    private func rebuildServices() {
        mongo = MongoService(settings: settings.mongo)
        redis = RedisService(settings: settings.redis)
        mysql = MySQLService(settings: settings.mysql)
        acme = ACMEService(settings: settings.acme)
        bt = BTPanelService(settings: settings.bt)
        vpn = VPNService(settings: settings.vpn)
    }

    func applySettings() {
        SettingsStore.save(settings)
        rebuildServices()
        settingsMessage = "设置已保存到 \(Paths.settingsFile.path)"
        refreshAll()
    }

    func resetSettings() {
        settings = AppSettings()
        SettingsStore.save(settings)
        rebuildServices()
        settingsMessage = "已恢复默认（全部改为自动探测）"
        refreshAll()
    }

    var discoveredRows: [(String, String)] { Discovered.summary }

    // MARK: 通用执行包装

    private func perform(_ label: String, _ work: @escaping () -> ActionResult,
                         after: (() -> Void)? = nil) {
        busy = label
        Diag.log("▶ \(label)")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                Diag.log("◀ \(label) ok=\(result.ok) message=\(result.message.replacingOccurrences(of: "\n", with: " "))")
                self.busy = nil
                var details: [String] = []
                if !result.detail.isEmpty { details.append(result.detail) }
                if !result.backupPath.isEmpty { details.append("原配置已备份到：\(result.backupPath)") }
                if !result.logTail.isEmpty {
                    // 不要把整段日志塞进提示条：内容过大会盖住整个界面。
                    Diag.log("失败详情（日志尾部）：\n" + result.logTail)
                    details.append("更详细的原因见左侧「日志」页，或 \(Diag.logURL.path)")
                }
                self.toast = Toast(text: result.message, ok: result.ok, detail: details.joined(separator: "\n\n"))
                after?()
            }
        }
    }

    /// 读取类操作：同样要有「进行中」提示，否则用户会以为点了没反应。
    private func load<T>(_ label: String, _ work: @escaping () -> Outcome<T>,
                         into assign: @escaping (T) -> Void,
                         onError: @escaping (String) -> Void) {
        busy = label
        Diag.log("▶ \(label)")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                self.busy = nil
                switch result {
                case .success(let value):
                    Diag.log("◀ \(label) 成功")
                    assign(value)
                case .failure(let message):
                    Diag.log("◀ \(label) 失败：\(message.replacingOccurrences(of: "\n", with: " "))")
                    onError(message)
                }
            }
        }
    }

    func refreshAll() {
        refreshMongoStatus()
        refreshRedisStatus()
    }

    // MARK: MongoDB

    func refreshMongoStatus() {
        let service = mongo
        DispatchQueue.global(qos: .userInitiated).async {
            let status = service.status()
            let auth = service.authorizationEnabled
            DispatchQueue.main.async {
                let wasRunning = self.mongoStatus.running
                self.mongoStatus = status
                self.mongoAuthEnabled = auth
                // 进页面时状态是异步拿到的，loadMongoDatabases 会被「未运行」挡掉；
                // 这里一旦确认服务在运行就补一次加载，否则列表会一直空着。
                if status.running && !wasRunning {
                    self.loadMongoDatabases()
                }
            }
        }
    }

    func startMongo() {
        let service = mongo
        perform("正在启动 MongoDB…") { service.start() } after: { self.refreshMongoStatus() }
    }

    func stopMongo() {
        let service = mongo
        perform("正在停止 MongoDB…") { service.stop() } after: { self.refreshMongoStatus() }
    }

    func restartMongo() {
        let service = mongo
        perform("正在重启 MongoDB…") { service.restart() } after: { self.refreshMongoStatus() }
    }

    func loadMongoDatabases() {
        // 服务没跑就别去连，避免弹一个没意义的连接错误；界面上已有「先启动」的提示。
        guard mongoStatus.running else {
            mongoDatabases = []
            mongoDatabaseError = nil
            return
        }
        let service = mongo
        load("正在读取数据库列表…", { service.databases() },
             into: { list in
                 self.mongoDatabases = list
                 self.mongoDatabaseError = nil
                 self.loadDatabaseUsers()
             },
             onError: { message in
                 self.mongoDatabases = []
                 self.mongoDatabaseError = message
             })
    }

    func createMongoDatabase() {
        guard mongoStatus.running else {
            toast = Toast(text: "MongoDB 未运行：请先点最上方的「启动」", ok: false)
            return
        }
        let service = mongo
        let name = newDatabaseName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            toast = Toast(text: "请先填数据库名", ok: false)
            return
        }

        let shouldCreateUser = newDbCreateUser
        var username = newDbUsername.trimmingCharacters(in: .whitespaces)
        if shouldCreateUser && username.isEmpty { username = name }   // 兜底：与库名一致
        var password = newDbPassword
        if shouldCreateUser && password.isEmpty {
            password = PasswordGenerator.make()
            newDbPassword = password      // 回填，方便用户看到并复制
        }
        let roles = [newDbRole.isEmpty ? "readWrite" : newDbRole]
        let user = username
        let pwd = password

        perform("正在创建数据库…") {
            let created = service.createDatabase(name)
            guard created.ok else { return created }
            guard shouldCreateUser else { return created }

            let userResult = service.setUserPassword(database: name, user: user, password: pwd, roles: roles)
            if userResult.ok {
                // 记下这个库的账号密码，数据库列表里可以直接显示/复制
                CredentialStore.upsert(database: name, user: user, password: pwd)
                return ActionResult(ok: true,
                                    message: "数据库 \(name) 已创建，用户 \(user) 已建立",
                                    detail: [userResult.message, userResult.detail]
                                        .filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            // 库已经建好了，必须说清楚，免得用户重复建库
            return ActionResult(ok: false,
                                message: "数据库 \(name) 已创建，但用户 \(user) 建立失败：\(userResult.message)",
                                detail: userResult.detail)
        } after: {
            self.newDatabaseName = ""
            self.loadMongoDatabases()
            self.reloadCredentials()
            if self.newDbCreateUser { self.loadMongoUsers() }
        }
    }

    /// 库名变化（或勾选建用户）时，让用户名跟着库名走。
    func syncNewDbUsername() {
        let result = UsernameSync.follow(currentUsername: newDbUsername,
                                         lastAutoUsername: lastAutoUsername,
                                         databaseName: newDatabaseName)
        if result.username != newDbUsername { newDbUsername = result.username }
        lastAutoUsername = result.lastAuto
    }

    /// 建库用的角色可选项
    var databaseRoleOptions: [(value: String, label: String)] {
        [("readWrite", "读写 readWrite"),
         ("read", "只读 read"),
         ("dbOwner", "管理员 dbOwner"),
         ("dbAdmin", "库管理 dbAdmin")]
    }

    func dropMongoDatabase(_ name: String) {
        let service = mongo
        perform("正在删除数据库 \(name)…") { service.dropDatabase(name) } after: {
            self.loadMongoDatabases()
            // 库都删了，凭据记录也一起清掉
            self.credentials = CredentialStore.remove(database: name)
        }
    }

    func loadMongoUsers() {
        guard mongoStatus.running else {
            mongoUsers = []
            mongoUsersLoaded = false
            toast = Toast(text: "MongoDB 未运行：请先点最上方的「启动」", ok: false)
            return
        }
        let service = mongo
        let database = mongoUserDatabase
        load("正在读取用户列表…", { service.users(database: database) },
             into: { users in
                 self.mongoUsers = users
                 self.mongoUsersLoaded = true
                 self.mongoUsersLoadedDatabase = database
                 self.toast = Toast(text: users.isEmpty
                                    ? "已加载 \"\(database)\" 库：里面没有用户"
                                    : "已加载 \"\(database)\" 库：\(users.count) 个用户", ok: true)
             },
             onError: { message in
                 self.mongoUsers = []
                 self.mongoUsersLoaded = false
                 self.toast = Toast(text: message, ok: false)
             })
    }

    /// 设置里是否已经填了管理员用户名
    var hasMongoCredentials: Bool {
        !settings.mongo.adminUser.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 开了鉴权但工具没有凭据 —— 这时几乎什么管理操作都做不了，界面要显眼地引导。
    var mongoNeedsCredentials: Bool {
        mongoAuthEnabled && !hasMongoCredentials
    }

    /// 用 localhost exception 创建第一个管理员用户，成功后把凭据写进设置并立即生效。
    func createAdminUser() {
        guard mongoStatus.running else {
            toast = Toast(text: "MongoDB 未运行：请先点最上方的「启动」", ok: false)
            return
        }
        let service = mongo
        let user = adminForm.user.trimmingCharacters(in: .whitespaces)
        let password = adminForm.password
        let role = adminForm.role.isEmpty ? "root" : adminForm.role
        guard !user.isEmpty, !password.isEmpty else {
            toast = Toast(text: "管理员用户名和密码都要填", ok: false)
            return
        }

        busy = "正在创建管理员用户…"
        Diag.log("▶ 创建管理员用户 \(user)（角色 \(role)）")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = service.createAdminUser(user: user, password: password, roles: [role])
            DispatchQueue.main.async {
                self.busy = nil
                Diag.log("◀ 创建管理员用户 ok=\(result.ok) message=\(result.message)")
                self.toast = Toast(text: result.message, ok: result.ok, detail: result.detail)
                guard result.ok else { return }
                self.settings.mongo.adminUser = user
                self.settings.mongo.adminPassword = password
                self.settings.mongo.authSource = "admin"
                SettingsStore.save(self.settings)
                self.rebuildServices()
                self.refreshMongoStatus()
                self.loadMongoDatabases()
                self.loadMongoUsers()
            }
        }
    }

    /// 查某个库的账号凭据（只有本工具创建的库才有记录）
    /// 某个库里真实存在的用户（从数据库查出来的）
    func users(for database: String) -> [String] {
        databaseUsers.filter { $0.database == database }.map(\.user).sorted()
    }

    /// 某用户的密码只可能来自两处：
    /// ① 工具创建时记下的（credentials.json）；② 当前管理员密码。
    /// 否则就是**读不到** —— MongoDB 只存单向哈希，客户端还原不出原密码。
    func password(for database: String, user: String) -> String? {
        if let credential = credentials.first(where: { $0.database == database && $0.user == user }),
           !credential.password.isEmpty {
            return credential.password
        }
        let authSource = settings.mongo.authSource.isEmpty ? "admin" : settings.mongo.authSource
        if database == authSource, user == settings.mongo.adminUser, !settings.mongo.adminPassword.isEmpty {
            return settings.mongo.adminPassword
        }
        return nil
    }

    /// 查出所有库的所有用户（供数据库列表显示），失败就静默置空。
    func loadDatabaseUsers() {
        let service = mongo
        DispatchQueue.global(qos: .userInitiated).async {
            let result = service.allUsers()
            DispatchQueue.main.async {
                switch result {
                case .success(let list):
                    self.databaseUsers = list
                    Diag.log("◀ 读取用户清单成功：\(list.count) 个用户")
                case .failure(let message):
                    self.databaseUsers = []
                    Diag.log("◀ 读取用户清单失败：\(message.replacingOccurrences(of: "\n", with: " "))")
                }
            }
        }
    }

    func credential(for database: String) -> DatabaseCredential? {
        credentials.first { $0.database == database }
    }

    func reloadCredentials() {
        credentials = CredentialStore.load()
    }

    /// 重置某库某用户的密码（用管理员凭据连接），成功后记下新密码并刷新列表。
    func resetUserPassword(target: PasswordResetTarget, newPassword: String) {
        guard mongoStatus.running else {
            toast = Toast(text: "MongoDB 未运行：请先点最上方的「启动」", ok: false)
            return
        }
        guard !newPassword.isEmpty else {
            toast = Toast(text: "新密码不能为空", ok: false)
            return
        }
        let service = mongo
        perform("正在重置 \(target.user) 的密码…") {
            let result = service.resetUserPassword(database: target.database,
                                                  user: target.user,
                                                  newPassword: newPassword)
            if result.ok {
                // 记下新密码，列表里马上就能看到 / 复制
                CredentialStore.upsert(database: target.database, user: target.user, password: newPassword)
            }
            return result
        } after: {
            self.passwordResetTarget = nil
            self.reloadCredentials()
            self.loadDatabaseUsers()
        }
    }

    /// 重置管理员(root)密码：用「当前密码」连上去改，成功后把设置里的密码同步成新的。
    func resetAdminPassword() {
        guard mongoStatus.running else {
            toast = Toast(text: "MongoDB 未运行：请先点最上方的「启动」", ok: false)
            return
        }
        let service = mongo
        let user = settings.mongo.adminUser.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else {
            toast = Toast(text: "先在「设置」里填管理员用户名（例如 admin）", ok: false)
            return
        }
        let oldPassword = settings.mongo.adminPassword
        var newPassword = adminReset.newPassword
        if newPassword.isEmpty {
            newPassword = PasswordGenerator.make()
            adminReset.newPassword = newPassword
        }
        guard oldPassword != newPassword else {
            toast = Toast(text: "新旧密码一样，不需要重置", ok: false)
            return
        }

        busy = "正在重置管理员密码…"
        Diag.log("▶ 重置管理员密码 \(user)")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = service.changeAdminPassword(user: user, oldPassword: oldPassword, newPassword: newPassword)
            DispatchQueue.main.async {
                self.busy = nil
                Diag.log("◀ 重置管理员密码 ok=\(result.ok)")
                self.toast = Toast(text: result.message, ok: result.ok, detail: result.detail)
                guard result.ok else { return }
                // 数据库里的密码已经变了，设置里必须跟着变，否则下次就连不上了
                self.settings.mongo.adminPassword = newPassword
                SettingsStore.save(self.settings)
                self.rebuildServices()
            }
        }
    }

    func applyMongoPassword() {
        let service = mongo
        let form = passwordForm
        perform("正在设置用户密码…") {
            let result = service.setUserPassword(database: form.database, user: form.user,
                                                 password: form.password, roles: Array(form.roles))
            if result.ok {
                // 记下这次的账号密码，数据库列表里就能直接显示 / 复制
                CredentialStore.upsert(database: form.database, user: form.user, password: form.password)
            }
            return result
        } after: {
            self.passwordForm.password = ""
            self.reloadCredentials()
            self.loadMongoUsers()
            self.loadDatabaseUsers()
        }
    }

    func loadMongoConfig() {
        let service = mongo
        DispatchQueue.global(qos: .userInitiated).async {
            service.ensureConf()
            let raw = service.rawConfigText()
            let rows = service.confParams().map {
                ParamRow(id: $0.spec.id, label: $0.spec.label, value: $0.value,
                         placeholder: $0.spec.placeholder, options: $0.spec.options)
            }
            let file = service.confPath
            let auth = service.authorizationEnabled
            DispatchQueue.main.async {
                self.mongoConfigText = raw
                self.mongoParamRows = rows
                self.mongoConfigFile = file
                self.mongoAuthEnabled = auth
            }
        }
    }

    func saveMongoParam(_ row: ParamRow, value: String) {
        let service = mongo
        perform("正在保存 \(row.label)…") { service.setParam(row.id, value: value) } after: {
            self.loadMongoConfig()
        }
    }

    func saveMongoConfigText() {
        let service = mongo
        let text = mongoConfigText
        perform("正在保存配置…") { service.saveConfigText(text) } after: {
            self.loadMongoConfig()
        }
    }

    func loadMongoLog() {
        let service = mongo
        DispatchQueue.global(qos: .userInitiated).async {
            let text = service.logTail()
            DispatchQueue.main.async { self.mongoLog = text }
        }
    }

    var mongoTarget: String { "\(mongoStatus.host):\(mongoStatus.port)" }

    // MARK: Redis

    func refreshRedisStatus() {
        let service = redis
        DispatchQueue.global(qos: .userInitiated).async {
            let status = service.status()
            DispatchQueue.main.async {
                let wasRunning = self.redisStatus.running
                self.redisStatus = status
                // 同 MongoDB：确认在运行后补一次加载，避免进页面时列表空着
                if status.running && !wasRunning {
                    self.scanRedis(reset: true)
                    self.loadRedisOverview()
                }
            }
        }
    }

    func startRedis() {
        let service = redis
        perform("正在启动 Redis…") { service.start() } after: { self.refreshRedisStatus() }
    }

    func stopRedis() {
        let service = redis
        perform("正在停止 Redis…") { service.stop() } after: { self.refreshRedisStatus() }
    }

    func restartRedis() {
        let service = redis
        perform("正在重启 Redis…") { service.restart() } after: { self.refreshRedisStatus() }
    }

    func scanRedis(reset: Bool) {
        guard redisStatus.running else {
            redisRows = []
            redisCursor = 0
            redisScannedAll = true
            redisTotalKeys = 0
            return
        }
        let service = redis
        let pattern = redisPattern.isEmpty ? "*" : redisPattern
        let database = redisDatabase
        let cursor = reset ? 0 : redisCursor
        redisSelectedKey = nil
        redisDetail = nil
        redisDetailError = nil
        load("正在扫描 key…", { service.scanKeys(pattern: pattern, cursor: cursor, count: 200, database: database) },
             into: { page in
                 self.redisRows = page.rows
                 self.redisCursor = page.cursor
                 self.redisScannedAll = page.scannedAll
                 self.redisTotalKeys = page.totalKeys
                 self.redisPage = reset ? 1 : self.redisPage + 1
             },
             onError: { message in
                 self.redisRows = []
                 self.redisCursor = 0
                 self.redisScannedAll = true
                 self.toast = Toast(text: message, ok: false)
             })
    }

    func loadRedisKey(_ key: String) {
        let service = redis
        let database = redisDatabase
        redisSelectedKey = key
        load("正在读取 key 内容…", { service.value(forKey: key, database: database) },
             into: { detail in
                 self.redisDetail = detail
                 self.redisDetailError = nil
             },
             onError: { message in
                 self.redisDetail = nil
                 self.redisDetailError = message
             })
    }

    func loadRedisOverview() {
        guard redisStatus.running else {
            redisOverview = nil
            redisOverviewError = nil
            return
        }
        let service = redis
        let database = redisDatabase
        load("正在读取 Redis 概览…", { service.overview(database: database) },
             into: { overview in
                 self.redisOverview = overview
                 self.redisOverviewError = nil
             },
             onError: { message in
                 self.redisOverview = nil
                 self.redisOverviewError = message
             })
    }

    func runRedisCommand() {
        let service = redis
        let line = consoleInput
        let database = redisDatabase
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        consoleEntries.append(ConsoleEntry(command: line, output: "执行中…", ok: true))
        consoleInput = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let result = service.execute(line, database: database)
            DispatchQueue.main.async {
                switch result {
                case .success(let output):
                    self.replaceLastConsoleEntry(output: output, ok: true)
                case .failure(let message):
                    self.replaceLastConsoleEntry(output: message, ok: false)
                }
                self.scanRedis(reset: true)
            }
        }
    }

    private func replaceLastConsoleEntry(output: String, ok: Bool) {
        guard let last = consoleEntries.last else { return }
        consoleEntries[consoleEntries.count - 1] = ConsoleEntry(command: last.command, output: output, ok: ok)
    }

    func loadRedisConfig() {
        let service = redis
        DispatchQueue.global(qos: .userInitiated).async {
            service.ensureConf()
            let raw = service.rawConfigText()
            let rows = service.confParams().map {
                ParamRow(id: $0.spec.id, label: $0.spec.label, value: $0.value,
                         placeholder: $0.spec.placeholder, options: $0.spec.options)
            }
            let file = service.confPath
            DispatchQueue.main.async {
                self.redisConfigText = raw
                self.redisParamRows = rows
                self.redisConfigFile = file
            }
        }
    }

    func saveRedisParam(_ row: ParamRow, value: String) {
        let service = redis
        perform("正在保存 \(row.label)…") { service.setParam(row.id, value: value) } after: {
            self.loadRedisConfig()
        }
    }

    func saveRedisConfigText() {
        let service = redis
        let text = redisConfigText
        perform("正在保存配置…") { service.saveConfigText(text) } after: {
            self.loadRedisConfig()
        }
    }

    func loadRedisLog() {
        let service = redis
        DispatchQueue.global(qos: .userInitiated).async {
            let text = service.logTail()
            DispatchQueue.main.async { self.redisLog = text }
        }
    }

    var redisTarget: String { "\(redisStatus.host):\(redisStatus.port)" }

    // MARK: MySQL

    @Published var mysqlStatus = MySQLStatus()
    @Published var mysqlDatabases: [MySQLDatabase] = []
    @Published var mysqlDatabaseError: String?
    @Published var mysqlUsers: [MySQLUser] = []
    @Published var mysqlParamRows: [ParamRow] = []
    @Published var mysqlConfigText = ""
    @Published var mysqlConfigFile = ""
    @Published var mysqlLog = ""
    @Published var newMySQLDatabase = ""
    @Published var mysqlCreateUser = true
    @Published var mysqlNewUser = ""
    @Published var mysqlNewUserHost = "%"
    @Published var mysqlNewPassword = ""
    @Published var mysqlNewUserPrivilege = "all"
    @Published var mysqlUserForm = MySQLUserForm()

    /// 「用户与密码」页的表单（只在工具内部用，所以直接嵌在这里）
    struct MySQLUserForm {
        var user = ""
        var host = "%"
        var password = ""
        var database = ""
        var privilege = "all"
    }

    var mysqlTarget: String { "\(mysqlStatus.host):\(mysqlStatus.port)" }

    /// 该库在本工具里记录过的账号（credentials.json）
    func mysqlUsers(for database: String) -> [String] {
        credentials.filter { $0.database == database }.map(\.user).sorted()
    }

    func mysqlPassword(for database: String, user: String) -> String? {
        credentials.first { $0.database == database && $0.user == user }?.password
    }

    func refreshMySQLStatus() {
        let service = mysql
        DispatchQueue.global(qos: .userInitiated).async {
            let status = service.status()
            DispatchQueue.main.async {
                let wasRunning = self.mysqlStatus.running
                self.mysqlStatus = status
                // 第一次确认在运行 → 补一次加载（进页面时状态是异步拿到的）
                if status.running && !wasRunning {
                    self.loadMySQLDatabases()
                    self.loadMySQLUsers()
                }
            }
        }
    }

    func startMySQL() {
        let service = mysql
        perform("正在启动 MySQL…") { service.start() } after: { self.refreshMySQLStatus() }
    }

    func stopMySQL() {
        let service = mysql
        perform("正在停止 MySQL…") { service.stop() } after: { self.refreshMySQLStatus() }
    }

    func restartMySQL() {
        let service = mysql
        perform("正在重启 MySQL…") { service.restart() } after: { self.refreshMySQLStatus() }
    }

    func loadMySQLDatabases() {
        let service = mysql
        DispatchQueue.global(qos: .userInitiated).async {
            // 状态不能依赖异步的 mysqlStatus，这里自己确认一次
            let status = service.status()
            guard status.running else {
                DispatchQueue.main.async {
                    self.mysqlStatus = status
                    self.mysqlDatabases = []
                    self.mysqlDatabaseError = nil
                }
                return
            }
            let result = service.databases()
            DispatchQueue.main.async {
                self.mysqlStatus = status
                switch result {
                case .success(let list):
                    self.mysqlDatabases = list
                    self.mysqlDatabaseError = nil
                    Diag.log("◀ 读取 MySQL 数据库列表成功：\(list.count) 个")
                case .failure(let message):
                    self.mysqlDatabases = []
                    self.mysqlDatabaseError = message
                    Diag.log("◀ 读取 MySQL 数据库列表失败：\(message)")
                }
            }
        }
    }

    func createMySQLDatabase() {
        guard mysqlStatus.running else {
            toast = Toast(text: "MySQL 未运行：请先点最上方的「启动」", ok: false)
            return
        }
        let service = mysql
        let name = newMySQLDatabase.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            toast = Toast(text: "请先填数据库名", ok: false)
            return
        }

        let shouldCreateUser = mysqlCreateUser
        var user = mysqlNewUser.trimmingCharacters(in: .whitespaces)
        if shouldCreateUser && user.isEmpty { user = name }          // 默认与库名相同
        let userHost = mysqlNewUserHost.trimmingCharacters(in: .whitespaces).isEmpty ? "%" : mysqlNewUserHost
        var password = mysqlNewPassword
        if shouldCreateUser && password.isEmpty {
            password = PasswordGenerator.make()
            mysqlNewPassword = password                                  // 回填，方便复制
        }
        let grants = MySQLService.privileges(for: mysqlNewUserPrivilege, database: name)
        let connectionDetail = "连接串示例：mysql://\(user):\(password)@\(service.host):\(service.port)/\(name)"

        perform("正在创建数据库…") {
            let created = service.createDatabase(name)
            guard created.ok else { return created }
            guard shouldCreateUser else { return created }

            let userResult = service.setUserPassword(user: user, host: userHost, password: password,
                                                     database: name, grants: grants)
            if userResult.ok {
                // 记下账号密码，数据库列表里就能直接显示 / 复制
                CredentialStore.upsert(database: name, user: "\(user)@\(userHost)", password: password)
                return ActionResult(ok: true,
                                    message: "数据库 \(name) 已创建，用户 \(user)@\(userHost) 已建立并授权",
                                    detail: connectionDetail)
            }
            return ActionResult(ok: false,
                                message: "数据库 \(name) 已创建，但用户 \(user)@\(userHost) 建立失败：\(userResult.message)",
                                detail: userResult.detail)
        } after: {
            self.newMySQLDatabase = ""
            self.loadMySQLDatabases()
            self.reloadCredentials()
            if self.mysqlCreateUser { self.loadMySQLUsers() }
        }
    }

    func dropMySQLDatabase(_ name: String) {
        let service = mysql
        perform("正在删除数据库 \(name)…") { service.dropDatabase(name) } after: {
            self.loadMySQLDatabases()
            self.credentials = CredentialStore.remove(database: name)
        }
    }

    func loadMySQLUsers() {
        let service = mysql
        DispatchQueue.global(qos: .userInitiated).async {
            let status = service.status()
            guard status.running else {
                DispatchQueue.main.async {
                    self.mysqlStatus = status
                    self.mysqlUsers = []
                }
                return
            }
            let result = service.users()
            DispatchQueue.main.async {
                switch result {
                case .success(let list):
                    self.mysqlUsers = list
                    Diag.log("◀ 读取 MySQL 用户成功：\(list.count) 个")
                case .failure(let message):
                    self.mysqlUsers = []
                    Diag.log("◀ 读取 MySQL 用户失败：\(message)")
                }
            }
        }
    }

    func applyMySQLUserPassword() {
        guard mysqlStatus.running else {
            toast = Toast(text: "MySQL 未运行：请先点最上方的「启动」", ok: false)
            return
        }
        let service = mysql
        let form = mysqlUserForm
        guard !form.user.trimmingCharacters(in: .whitespaces).isEmpty else {
            toast = Toast(text: "用户名不能为空", ok: false)
            return
        }
        guard !form.password.isEmpty else {
            toast = Toast(text: "密码不能为空", ok: false)
            return
        }
        let database = form.database.trimmingCharacters(in: .whitespaces)
        let grants = MySQLService.privileges(for: form.privilege, database: database)
        let credentialUser = "\(form.user)@\(form.host)"

        perform("正在设置 MySQL 用户…") {
            let result = service.setUserPassword(user: form.user, host: form.host, password: form.password,
                                                 database: database.isEmpty ? nil : database, grants: grants)
            if result.ok, !database.isEmpty {
                CredentialStore.upsert(database: database, user: credentialUser, password: form.password)
            }
            return result
        } after: {
            self.mysqlUserForm.password = ""
            self.reloadCredentials()
            self.loadMySQLUsers()
        }
    }

    func loadMySQLConfig() {
        let service = mysql
        DispatchQueue.global(qos: .userInitiated).async {
            _ = service.ensureConf()
            let raw = service.rawConfigText()
            let rows = service.confParams().map {
                ParamRow(id: $0.spec.id, label: $0.spec.label, value: $0.value,
                         placeholder: $0.spec.placeholder, options: $0.spec.options)
            }
            let file = service.confPath
            DispatchQueue.main.async {
                self.mysqlConfigText = raw
                self.mysqlParamRows = rows
                self.mysqlConfigFile = file
            }
        }
    }

    func saveMySQLParam(_ row: ParamRow, value: String) {
        let service = mysql
        perform("正在保存 \(row.label)…") { service.setParam(row.id, value: value) } after: {
            self.loadMySQLConfig()
        }
    }

    func saveMySQLConfigText() {
        let service = mysql
        let text = mysqlConfigText
        perform("正在保存配置…") { service.saveConfigText(text) } after: {
            self.loadMySQLConfig()
        }
    }

    func loadMySQLLog() {
        let service = mysql
        DispatchQueue.global(qos: .userInitiated).async {
            let text = service.logTail()
            DispatchQueue.main.async { self.mysqlLog = text }
        }
    }

    // MARK: 证书（Let's Encrypt / acme.sh）

    @Published var acmeStatus = ACMEStatus()
    @Published var acmeDomains = ""
    /// aliyun（自动 DNS 验证）或 manual（手动加 TXT 记录）
    @Published var acmeMode = "aliyun"
    @Published var acmeChallenges: [ACMEChallenge] = []
    @Published var acmeCertificates: [ACMECertificate] = []
    @Published var acmeCertError: String?
    @Published var acmeDeployDomain = ""
    @Published var acmeDeployKeyPath = ""
    @Published var acmeDeployFullchainPath = ""

    /// 两个安装源都展示给用户（透明）
    var acmeGithubCommand: String { acme.githubInstallCommand }
    var acmeGiteeCommand: String { acme.giteeInstallCommand }

    /// 域名输入：逗号 / 分号 / 空格 / 换行分隔
    var acmeDomainList: [String] {
        acmeDomains
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 把界面上的输入（邮箱 / 阿里云凭据 / 重载命令）落盘，并让服务拿到最新配置
    private func syncACMESettings() {
        SettingsStore.save(settings)
        rebuildServices()
    }

    func refreshACMEStatus() {
        let service = acme
        DispatchQueue.global(qos: .userInitiated).async {
            let status = service.status()
            DispatchQueue.main.async { self.acmeStatus = status }
        }
    }

    func installACME() {
        let service = acme
        perform("正在安装 acme.sh…") { service.install() } after: {
            self.refreshACMEStatus()
        }
    }

    func issueCertificate() {
        syncACMESettings()
        let service = acme
        let domains = acmeDomainList
        let email = settings.acme.email
        guard !domains.isEmpty else {
            toast = Toast(text: "请先填域名", ok: false)
            return
        }
        if acmeMode == "manual" {
            generateChallenges()
            return
        }
        perform("正在申请证书（DNS 自动验证，可能要 1 分钟）…") {
            service.issueWithAliyun(domains: domains, email: email)
        } after: {
            self.loadCertificates()
        }
    }

    /// 手动 DNS 第 1 步：拿到需要自己添加的 TXT 记录
    func generateChallenges() {
        syncACMESettings()
        let service = acme
        let domains = acmeDomainList
        let email = settings.acme.email
        guard !domains.isEmpty else {
            toast = Toast(text: "请先填域名", ok: false)
            return
        }
        load("正在向 Let's Encrypt 申请验证…",
             { service.issueManualStep1(domains: domains, email: email) },
             into: { challenges in
                 self.acmeChallenges = challenges
                 self.toast = Toast(text: "已生成 \(challenges.count) 条 TXT 记录，添加后点第 2 步", ok: true)
             },
             onError: { message in
                 self.acmeChallenges = []
                 self.toast = Toast(text: "生成验证记录失败", ok: false, detail: message)
             })
    }

    /// 手动 DNS 第 2 步：TXT 记录加好后完成签发
    func completeManualIssue() {
        syncACMESettings()
        let service = acme
        let domains = acmeDomainList
        let email = settings.acme.email
        perform("正在完成验证并签发…") {
            service.issueManualStep2(domains: domains, email: email)
        } after: {
            self.loadCertificates()
        }
    }

    func loadCertificates() {
        let service = acme
        DispatchQueue.global(qos: .userInitiated).async {
            let result = service.listCertificates()
            DispatchQueue.main.async {
                switch result {
                case .success(let list):
                    self.acmeCertificates = list
                    self.acmeCertError = nil
                case .failure(let message):
                    self.acmeCertificates = []
                    // 没安装 acme.sh 时不用刷错误提示
                    self.acmeCertError = self.acmeStatus.installed ? message : nil
                }
            }
        }
    }

    func renewCertificate(_ domain: String) {
        syncACMESettings()
        let service = acme
        perform("正在续期 \(domain)…") { service.renew(domain: domain) } after: {
            self.loadCertificates()
        }
    }

    func deployCertificate() {
        syncACMESettings()
        let service = acme
        let domain = acmeDeployDomain
        let keyPath = acmeDeployKeyPath
        let fullchainPath = acmeDeployFullchainPath
        perform("正在部署证书…") {
            service.installCert(domain: domain, keyPath: keyPath, fullchainPath: fullchainPath)
        }
    }

    func installACMECron() {
        let service = acme
        perform("正在安装自动续期任务…") { service.installCron() }
    }

    /// 备份单张证书到 iCloud Drive（acme.sh 会记住目标，续期后自动同步）
    func backupCertificateToICloud(_ domain: String) {
        syncACMESettings()
        let service = acme
        let subdir = settings.acme.icloudSubdir
        perform("正在备份 \(domain) 到 iCloud…") {
            service.exportToICloud(domain: domain, subdir: subdir)
        }
    }

    /// 把所有已签发的证书备份到 iCloud Drive
    func backupAllCertificatesToICloud() {
        syncACMESettings()
        let service = acme
        let subdir = settings.acme.icloudSubdir
        let domains = acmeCertificates.map(\.domain)
        guard !domains.isEmpty else {
            toast = Toast(text: "还没有已签发的证书", ok: false)
            return
        }
        perform("正在备份 \(domains.count) 张证书到 iCloud…") {
            var lines: [String] = []
            var allOK = true
            for domain in domains {
                let result = service.exportToICloud(domain: domain, subdir: subdir)
                allOK = allOK && result.ok
                lines.append("\(domain)：\(result.ok ? "已备份" : result.message)")
            }
            return ActionResult(ok: allOK,
                                message: allOK ? "\(domains.count) 张证书都已备份到 iCloud Drive"
                                               : "有证书备份失败，请看详情",
                                detail: lines.joined(separator: "\n"))
        } after: {
            self.loadCertificates()
        }
    }

    // MARK: 宝塔面板（API）

    struct BTInfoRow: Identifiable {
        var id: String { label }
        var label: String
        var value: String
    }

    @Published var btConnected = false
    @Published var btStatusText = ""
    @Published var btOverview: [BTInfoRow] = []
    @Published var btSites: [BTSite] = []
    @Published var btServices: [BTServiceStatus] = []
    @Published var btDatabases: [BTDatabase] = []
    /// 数据库页当前选中的类型（取值见 BTDatabaseType.all）
    @Published var btDatabaseTypeKey: String = "mongodb"
    @Published var btLastResponse = ""
    @Published var btLastResponseOK = true
    @Published var btDisks: [BTDiskUsage] = []
    @Published var btResources: [BTResourceUsage] = []
    @Published var btDeploySite = ""
    @Published var btDeployDomain = ""

    var btConfigured: Bool { bt.isConfigured }

    /// 面板把请求拦在 IP 白名单之外时，这里能拿到被拦截的出口 IP
    var btBlockedIP: String? { BTPanelService.blockedIP(from: btLastResponse) }

    /// 面板地址/密钥改了就存盘，并让服务拿到最新配置
    // MARK: 网络代理（IKEv2 VPN）

    /// 保存 VPN 设置并重建服务
    private func syncVPNSettings() {
        settings.vpn.host = settings.vpn.host.trimmingCharacters(in: .whitespaces)
        settings.vpn.sshUser = settings.vpn.sshUser.trimmingCharacters(in: .whitespaces)
        SettingsStore.save(settings)
        rebuildServices()
    }

    /// 记录 VPN 操作输出（写进界面与日志前一律脱敏）
    private func recordVPN(_ label: String, _ output: String) {
        let clean = Shell.redactSecrets(output)
        vpnLog = "【\(label)】\n" + (clean.isEmpty ? "（无输出）" : clean)
    }

    /// 测试 SSH 连接并探测服务器环境（系统 / 架构 / 内存 / 是否已装 IKEv2）
    func vpnProbeServer() {
        syncVPNSettings()
        let service = vpn
        perform("正在连接 \(settings.vpn.host)…") {
            let (probe, output) = service.probe()
            self.vpnProbe = probe
            self.recordVPN("探测服务器", output)
            guard !probe.osName.isEmpty else {
                return .failure("SSH 连接失败，请检查地址 / 端口 / 用户名 / 密码",
                                detail: Shell.redactSecrets(output))
            }
            return ActionResult(ok: true,
                                message: "已连上：\(probe.osName)（\(probe.arch)）",
                                detail: Shell.redactSecrets(output))
        }
    }

    /// 检查 UDP 500/4500 是否真的能到达服务器。
    /// 这是区分「云安全组没放行」和「服务端配置问题」最快的一步 ——
    /// 服务器抓不到包就一定是防火墙，不用再折腾服务端。
    func vpnCheckUDP() {
        syncVPNSettings()
        let service = vpn
        perform("正在验证 UDP 500/4500 连通性…") {
            let (reachable, detail) = service.checkUDP()
            self.recordVPN("UDP 连通性", detail)
            if reachable {
                return ActionResult(ok: true, message: "UDP 500/4500 通畅", detail: detail)
            }
            return .failure("UDP 500/4500 不通", detail: detail)
        }
    }

    /// 在服务器上安装 IPsec + IKEv2
    func vpnInstall() {
        syncVPNSettings()
        let service = vpn
        vpnInstallDone = false
        perform("正在服务器上启动 IKEv2 安装…") {
            let result = service.install()
            self.recordVPN("启动安装", result.detail)
            return result
        } after: {
            // 安装要几分钟，自动轮询进度
            self.vpnPollInstallProgress(rounds: 40)
        }
    }

    /// 轮询安装进度（安装耗时几分钟，所以做成可重复调用的）
    func vpnPollInstallProgress(rounds: Int) {
        guard rounds > 0, !vpnInstallDone else { return }
        let service = vpn
        perform("正在安装…（剩余尝试 \(rounds) 次）") {
            let (done, failed, output) = service.installProgress()
            self.recordVPN("安装进度", output)
            if done {
                self.vpnInstallDone = true
                return ActionResult(ok: true, message: "IKEv2 安装完成，可以取回配置了")
            }
            if failed {
                return .failure("安装过程中出现错误", detail: Shell.redactSecrets(output))
            }
            return ActionResult(ok: true, message: "安装进行中…", detail: output)
        } after: {
            if self.vpnInstallDone { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                self.vpnPollInstallProgress(rounds: rounds - 1)
            }
        }
    }

    /// 从服务器取回描述文件（mobileconfig / p12 / sswan）
    func vpnFetchProfile() {
        syncVPNSettings()
        let service = vpn
        let directory = Paths.appSupport.appendingPathComponent("vpn").path
        perform("正在取回描述文件…") {
            let result = service.fetchProfile(into: directory)
            self.vpnLocalProfile = result.backupPath
            self.recordVPN("取回配置", result.detail)
            return result
        }
    }

    /// 打开描述文件 —— 交给系统弹安装向导。
    /// macOS 27 起描述文件必须由用户点「安装」，命令行装不了（profiles install 已被移除）。
    func vpnInstallProfile() {
        guard !vpnLocalProfile.isEmpty, FileTools.exists(vpnLocalProfile) else {
            toast = Toast(text: "还没有取回描述文件", ok: false, detail: "先点「取回配置」")
            return
        }
        let service = vpn
        let path = vpnLocalProfile
        perform("正在打开描述文件…") {
            service.openProfile(at: path)
        } after: {
            self.vpnRefreshStatus()
        }
    }

    /// 把描述文件备份到 iCloud Drive（iPhone 直接取）
    func vpnBackupToICloud() {
        guard !vpnLocalProfile.isEmpty, FileTools.exists(vpnLocalProfile) else {
            toast = Toast(text: "还没有取回描述文件", ok: false, detail: "先点「取回配置」")
            return
        }
        let service = vpn
        let path = vpnLocalProfile
        perform("正在备份到 iCloud…") {
            service.backupToICloud(from: path)
        }
    }

    /// 刷新本机 VPN 状态（描述文件是否装了、有没有可用服务）
    func vpnRefreshStatus() {
        let service = vpn
        load("正在读取本机 VPN 状态…", { .success(service.status()) },
             into: { status in
                 self.vpnStatus = status
             },
             onError: { message in
                 self.toast = Toast(text: "读取 VPN 状态失败", ok: false, detail: message)
             })
    }

    /// 连接 / 断开系统 VPN
    func vpnSetConnected(_ connected: Bool) {
        let service = vpn
        perform(connected ? "正在连接 VPN…" : "正在断开 VPN…") {
            service.setConnected(connected)
        } after: {
            self.vpnRefreshStatus()
        }
    }

    private func syncBTSettings() {
        SettingsStore.save(settings)
        rebuildServices()
    }

    /// 把面板返回原样记下来（面板版本差异时最有用）
    private func recordBT(_ result: BTAPIResult, label: String) {
        // 面板某些接口（如 SSL）会返回私钥明文，展示与记录前统一抹掉
        let raw = BTPanelService.redactSensitive(result.raw)
        btLastResponse = "【\(label)】" + (raw.isEmpty ? result.message : "\n" + raw)
        btLastResponseOK = result.ok
        Diag.log("宝塔 API \(label)：\(result.ok ? "成功" : "失败")")
    }

    func testBTConnection() {
        syncBTSettings()
        let service = bt
        load("正在连接宝塔面板…", { .success(service.ping()) },
             into: { result in
                 self.btConnected = result.ok
                 self.btStatusText = result.ok ? "连接成功" : "连接失败：\(result.message)"
                 self.recordBT(result, label: "测试连接")
                 if result.ok { self.refreshBTOverview() }
             },
             onError: { message in
                 self.btConnected = false
                 self.btStatusText = "连接失败"
                 self.toast = Toast(text: "宝塔面板连接失败", ok: false, detail: message)
             })
    }

    func refreshBTOverview() {
        loadBTResources()
        let service = bt
        load("正在读取面板信息…", { .success(service.systemTotal()) },
             into: { result in
                 self.recordBT(result, label: "系统信息")
                 self.btConnected = result.ok
                 guard let json = result.json else {
                     self.btStatusText = result.message
                     return
                 }
                 self.btStatusText = "连接成功"
                 var rows: [BTInfoRow] = []
                 func field(_ key: String) -> String? {
                     guard let value = json[key], !(value is NSNull) else { return nil }
                     let rendered = (value as? String) ?? String(describing: value)
                     return rendered.isEmpty ? nil : rendered
                 }
                 func add(_ label: String, _ key: String, suffix: String = "") {
                     if let value = field(key) { rows.append(BTInfoRow(label: label, value: value + suffix)) }
                 }
                 add("面板版本", "version")
                 add("操作系统", "system")
                 add("CPU 核心", "cpuNum")
                 add("CPU 使用率", "cpuRealUsed", suffix: " %")
                 // 宝塔 8+ 直接给了可读的内存串（1.8GB / 714.0MB）
                 if let total = field("memNewTotal"), let used = field("memNewRealUsed") {
                     rows.append(BTInfoRow(label: "内存占用", value: "\(used) / \(total)"))
                 } else {
                     add("内存总量", "memTotal", suffix: " MB")
                     add("当前内存占用", "memRealUsed", suffix: " MB")
                 }
                 add("运行时长", "time")
                 self.btOverview = rows
             },
             onError: { message in
                 self.btConnected = false
                 self.btStatusText = message
                 self.btOverview = []
             })
    }

    /// 磁盘信息（宝塔各版本返回格式不统一，这里原样展示，避免猜错字段）
    /// 读取 CPU / 内存与磁盘占用，用于画占用条
    func loadBTResources() {
        let service = bt
        load("正在读取资源占用…", {
            .success((service.resourceUsage(), service.diskUsage()))
        }, into: { bundle in
            self.btResources = bundle.0
            self.btDisks = bundle.1
        }, onError: { message in
            self.btResources = []
            self.btDisks = []
            self.toast = Toast(text: "读取资源占用失败", ok: false, detail: message)
        })
    }

    /// 把一次动作的结果（已写进 toast）同步到「原始响应」区
    private func recordBTFromToast(_ label: String) {
        guard let last = toast else { return }
        btLastResponse = "【\(label)】\n" + (last.detail.isEmpty ? last.text : last.detail)
        btLastResponseOK = last.ok
    }

    func btServiceAction(name: String, type: String) {
        syncBTSettings()
        let service = bt
        let label = "\(btActionLabel(type)) \(name)"
        perform("正在\(btActionLabel(type)) \(name)…") {
            let outcome = service.serviceAdmin(name: name, type: type)
            let raw = outcome.result.raw.isEmpty ? outcome.result.message : outcome.result.raw
            // 面板对不存在的服务名也回「执行成功」，所以 start/stop 用复查到的真实状态判定
            var ok = outcome.result.ok
            var extra = ""
            if let verified = outcome.verified {
                if (type == "start") != verified.running {
                    ok = false
                    extra = "\n\n⚠️ 复查状态仍是「\(verified.statusLabel)」，操作可能没生效。"
                } else {
                    extra = "\n\n复查状态：\(verified.statusLabel)"
                }
            }
            return ActionResult(ok: ok,
                                message: ok ? "\(name) \(self.btActionLabel(type))完成"
                                            : outcome.result.message,
                                detail: raw + extra)
        } after: {
            self.recordBTFromToast(label)
            self.loadBTServices()
        }
    }

    func btActionLabel(_ type: String) -> String {
        switch type {
        case "start": return "启动"
        case "stop": return "停止"
        case "restart": return "重启"
        case "reload": return "重载"
        default: return type
        }
    }

    func loadBTSites() {
        let service = bt
        load("正在读取网站列表…", { .success(service.sitesWithRealStatus()) },
             into: { sites in
                 self.btSites = sites
                 self.btLastResponse = "【网站列表】\n" + sites.map {
                     "\($0.name) [\($0.statusLabel)] \($0.typeLabel)"
                 }.joined(separator: "\n")
                 self.btLastResponseOK = true
             },
             onError: { message in
                 self.btSites = []
                 self.toast = Toast(text: "读取网站列表失败", ok: false, detail: message)
             })
    }

    /// 读取数据库列表（按当前选中的类型）
    func loadBTDatabases() {
        let service = bt
        let type = BTDatabaseType.find(btDatabaseTypeKey)
        load("正在读取 \(type.label) 数据库列表…", { .success(service.databaseList(type: type)) },
             into: { result in
                 self.recordBT(result, label: "\(type.label) 数据库列表")
                 self.btDatabases = BTPanelService.parseDatabases(result, type: type)
             },
             onError: { message in
                 self.btDatabases = []
                 self.toast = Toast(text: "读取 \(type.label) 数据库列表失败", ok: false, detail: message)
             })
    }

    /// 切换数据库类型并重新加载
    func selectBTDatabaseType(_ key: String) {
        guard btDatabaseTypeKey != key else { return }
        btDatabaseTypeKey = key
        btDatabases = []
        loadBTDatabases()
    }

    /// 读取各服务的安装 / 运行状态。
    /// 运行状态**以服务器进程表为准**：一次拉全量进程再比对，比逐个查商店快也更准。
    func loadBTServices() {
        let service = bt
        load("正在读取服务状态…", {
            .success(service.serviceStatuses())
        }, into: { statuses in
            self.btServices = statuses
            let known = statuses.filter { $0.installed }.count
            self.btLastResponse = "【服务状态】\n" + statuses.map {
                "\($0.name) [\($0.statusLabel)] \($0.version)"
            }.joined(separator: "\n")
            self.btLastResponseOK = true
            self.toast = Toast(text: "读到 \(statuses.count) 个服务（\(known) 个已安装）",
                               ok: true, detail: "")
        }, onError: { message in
            self.btServices = []
            self.toast = Toast(text: "读取服务状态失败", ok: false, detail: message)
        })
    }

    /// 待二次确认的服务操作（停止 / 重启 / 重载会中断服务）
    struct BTPendingServiceAction: Identifiable {
        var id: String { "\(serviceName)-\(type)" }
        var serviceName: String
        var serviceLabel: String
        var type: String
    }

    /// 待二次确认的网站操作（停止网站会中断访问）
    struct BTPendingSiteAction: Identifiable {
        var id: String { "\(siteID)-\(start ? "start" : "stop")" }
        var siteID: String
        var siteName: String
        var start: Bool
        /// 站点类型标签（PHP / Python / 反向代理…），用于确认弹窗
        var typeLabel: String = ""
        /// 该类型的启停说明（不同站点类型启停行为不同）
        var note: String = ""
    }

    @Published var btPendingService: BTPendingServiceAction?
    @Published var btPendingSite: BTPendingSiteAction?

    /// 启动属于低风险、且常点的操作 → 直接执行；
    /// 停止 / 重启 / 重载会中断服务 → 先弹确认。
    func requestBTServiceAction(name: String, label: String, type: String) {
        if type == "start" {
            btServiceAction(name: name, type: type)
        } else {
            btPendingService = BTPendingServiceAction(serviceName: name, serviceLabel: label, type: type)
        }
    }

    func confirmBTServiceAction() {
        guard let pending = btPendingService else { return }
        btPendingService = nil
        btServiceAction(name: pending.serviceName, type: pending.type)
    }

    /// 启动网站直接执行；停止网站先确认（确认框会按站点类型给出启停说明）
    func requestBTSiteAction(site: BTSite, start: Bool) {
        if start {
            btSiteAction(site: site, start: true)
        } else {
            btPendingSite = BTPendingSiteAction(siteID: site.id, siteName: site.name, start: false,
                                                typeLabel: site.typeLabel, note: site.restartNote)
        }
    }

    func confirmBTSiteAction() {
        guard let pending = btPendingSite else { return }
        btPendingSite = nil
        if let site = btSites.first(where: { $0.id == pending.siteID }) {
            btSiteAction(site: site, start: pending.start)
        } else {
            btSiteAction(site: BTSite(id: pending.siteID, name: pending.siteName, path: "",
                                      domains: "", status: "1"),
                         start: pending.start)
        }
    }

    func btSiteAction(site: BTSite, start: Bool) {
        syncBTSettings()
        let service = bt
        let label = "\(start ? "启动" : "停止")网站 \(site.name)"
        perform("正在\(start ? "启动" : "停止")网站 \(site.name)…") {
            var ok = false
            var endpoint = ""
            var raw = ""
            var tried: [String] = []
            // Python 项目走宝塔的专用接口，它才能**真正停掉 uwsgi 应用进程**；
            // 站点接口 /site?action=SiteStop 只摘 nginx 转发，进程照旧在跑。
            if site.isPythonProject {
                let outcome = service.pythonProjectAction(site: site, start: start)
                ok = outcome.project.ok
                endpoint = "/project/python/\(start ? "StartProject" : "StopProject")（name=\(site.name)）"
                         + "\n+ /site?action=\(start ? "SiteStart" : "SiteStop")（id=\(site.id)）"
                raw = "项目接口：\(outcome.project.raw.isEmpty ? outcome.project.message : outcome.project.raw)"
                    + "\n站点接口：\(outcome.site.raw.isEmpty ? outcome.site.message : outcome.site.raw)"
                tried = [endpoint]
            } else {
                let outcome = service.setSiteRunning(site, start: start)
                ok = outcome.result.ok
                endpoint = outcome.endpoint
                raw = outcome.result.raw.isEmpty ? outcome.result.message : outcome.result.raw
                tried = outcome.tried
            }
            // 面板回「成功」不算数，复查列表里的真实 status
            var verify = ""
            if ok {
                // 复查用带真实项目状态的列表（Python 项目看项目接口，其它看 sites 表）
                let fresh = service.sitesWithRealStatus().first { $0.id == site.id }
                if let fresh {
                    if fresh.running != start {
                        ok = false
                        verify = "\n\n⚠️ 复查面板列表：该站点现在仍是「\(fresh.statusLabel)」，操作可能没生效。"
                    } else {
                        verify = "\n\n复查面板列表：\(fresh.statusLabel) ✅"
                    }
                } else {
                    verify = "\n\n（复查时没在列表里找到该站点，无法二次确认）"
                }
                // 项目类站点额外核对应用进程 —— 这才区分得出"只停了转发"和"真停了进程"
                let hints = site.processNameHints
                if !hints.isEmpty {
                    let procs = service.processList()
                    let count = procs.filter { row in
                        let procName = ((row["name"] as? String) ?? "").lowercased()
                        return hints.contains { procName.hasPrefix($0) }
                    }.count
                    let label = hints.joined(separator: "/")
                    if start && count == 0 {
                        verify += "\n⚠️ 未检测到 \(label) 进程，启动可能没成功。"
                    } else if !start && count > 0 {
                        verify += "\n⚠️ 服务器上仍有 \(count) 个 \(label) 进程在跑，请到面板确认是否属于本项目。"
                    } else if !start {
                        verify += "\n应用进程（\(label)）也已停止 ✅"
                    }
                }
            }
            let detail = "调用的接口：\n" + tried.joined(separator: "\n")
                       + "\n\n响应：\n" + raw + verify
            return ActionResult(ok: ok,
                                message: ok
                                    ? "\(site.name) 已\(start ? "启动" : "停止")"
                                    : "\(raw)\n（已尝试 \(tried.count) 个接口，详见下方）",
                                detail: detail)
        } after: {
            self.recordBTFromToast(label)
            self.loadBTSites()
        }
    }

    /// 把已签发的证书部署成宝塔某个网站的 SSL（申请 → 部署 一条龙）
    func deployCertificateToBTPanel() {
        syncBTSettings()
        let service = bt
        let siteName = btDeploySite.trimmingCharacters(in: .whitespaces)
        let domain = btDeployDomain.trimmingCharacters(in: .whitespaces)
        guard !siteName.isEmpty else {
            toast = Toast(text: "先选要部署到哪个网站", ok: false)
            return
        }
        guard let certificate = acmeCertificates.first(where: { $0.domain == domain }) else {
            toast = Toast(text: "找不到证书 \(domain)：先在「证书」页申请一张", ok: false)
            return
        }
        let key = FileTools.read(certificate.keyPath)
        let fullchain = FileTools.read(certificate.fullchainPath)
        guard !key.isEmpty, !fullchain.isEmpty else {
            toast = Toast(text: "读不到证书文件",
                          ok: false,
                          detail: "私钥：\(certificate.keyPath)\n证书链：\(certificate.fullchainPath)")
            return
        }

        perform("正在把 \(domain) 的证书部署到网站 \(siteName)…") {
            let r = service.deploySSL(siteName: siteName, privateKey: key, fullchain: fullchain)
            return ActionResult(ok: r.ok, message: r.message,
                                detail: r.raw.isEmpty ? r.message : r.raw)
        } after: {
            self.recordBTFromToast("为 \(siteName) 部署 SSL")
            self.loadBTSites()
        }
    }
}
