import Foundation
import SwiftUI
import AppKit

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
    @Published var toast: Toast? {
        didSet {
            // 顺手发一条**系统级通知**（右上角横幅）；没授权就只留界面里的 toast
            if let toast {
                SystemNotice.post(title: toast.ok ? "完成" : "出错了", body: toast.text)
            }
        }
    }
    @Published var settingsMessage = ""

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
    private var dns: DNSService
    let projectRunner = ProjectRunner()
    let pythonEnvironments = PythonEnvironmentManager()
    /// 顶部「刘海」小组件（窗口 + 展开状态）。图标列表存在 `settings.docklet` 里。
    let docklet = DockletController()
    /// 剪贴板历史（轮询系统剪贴板 → 内存 + Redis + 本地文件，只记文本）。
    let clipboard = ClipboardService()
    /// 「AI 开发」的看门狗（跑在后台线程，状态经 onChange 回到主线程）
    private let aiRunner = AIDevRunner()

    init() {
        Diag.log("AppModel 初始化")
        let loaded = SettingsStore.load()
        settings = loaded
        mongo = MongoService(settings: loaded.mongo)
        redis = RedisService(settings: loaded.redis)
        mysql = MySQLService(settings: loaded.mysql)
        acme = ACMEService(settings: loaded.acme)
        dns = DNSService(settings: loaded.dns)
        pythonEnvironments.refresh(projectRoots: projectRunner.roots)
        // 剪贴板历史：Redis 连接参数每次现取（设置里改了端口/密码立刻生效）。
        clipboard.redisTarget = { [weak self] in self?.clipboardRedisTarget }
        clipboard.start(recording: loaded.clipboard.enabled)
        aiRunner.onChange = { [weak self] snapshot in
            self?.aiDev = snapshot
            if !snapshot.running, !snapshot.message.isEmpty {
                self?.aiDevMessage = snapshot.message
            }
        }
        // 「仅 App 内运行」的看门狗：App 一退出就把 codex 子进程收掉，
        // 否则会留下一个没人管的进程在后台继续跑。
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // 回调队列就是主队列，但编译器不知道，这里直接声明主 actor 上下文
            MainActor.assumeIsolated {
                self?.aiStopTask()
                self?.projectRunner.stopAll()
                self?.pythonEnvironments.stop()
            }
        }
    }

    // MARK: 服务与设置

    private func rebuildServices() {
        mongo = MongoService(settings: settings.mongo)
        redis = RedisService(settings: settings.redis)
        mysql = MySQLService(settings: settings.mysql)
        acme = ACMEService(settings: settings.acme)
        dns = DNSService(settings: settings.dns)
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

    /// 只落盘：开关类的小改动用它，别顺手把服务重建、状态刷新那一大串也带着跑。
    func persistSettings() {
        SettingsStore.save(settings)
    }

    var discoveredRows: [(String, String)] { Discovered.summary }

    // MARK: 打开软件后的自动启动

    private var didAutoStart = false

    /// 「打开本软件后自动启动」：按设置里的勾选，把 MongoDB / Redis 拉起来。
    ///
    /// 刻意不做系统级开机自启（不写 LaunchAgent）—— 只在 App 启动后跑一次，用本工具自己的启动逻辑，
    /// 所以「页面里点启动」和「自动启动」走的是同一条路（同一份配置、同一套失败提示）。
    func autoStartServicesIfNeeded() {
        guard !didAutoStart else { return }
        didAutoStart = true
        if settings.startup.autoStartMongo { autoStart(mongo: true) }
        if settings.startup.autoStartRedis { autoStart(mongo: false) }
    }

    /// 先探一次状态：已经在跑就不动它（不重启、不报错），没在跑才启动。
    private func autoStart(mongo isMongo: Bool) {
        Diag.log("自动启动：\(isMongo ? "MongoDB" : "Redis")（「设置」页的开关）")
        if isMongo {
            let service = mongo
            DispatchQueue.global(qos: .userInitiated).async {
                let status = service.status()
                let auth = service.authorizationEnabled
                DispatchQueue.main.async {
                    self.mongoStatus = status
                    self.mongoAuthEnabled = auth
                    guard !status.running else {
                        Diag.log("自动启动：MongoDB 已在运行，跳过")
                        self.loadMongoDatabases()
                        return
                    }
                    guard status.installed else {
                        self.toast = Toast(text: "自动启动 MongoDB 失败：找不到 mongod", ok: false,
                                           detail: "在「设置」里指定 mongod 路径，或先 brew install mongodb-community。")
                        return
                    }
                    self.perform("正在自动启动 MongoDB…") { service.start() } after: {
                        self.refreshMongoStatus()
                    }
                }
            }
            return
        }
        let service = redis
        DispatchQueue.global(qos: .userInitiated).async {
            let status = service.status()
            DispatchQueue.main.async {
                self.redisStatus = status
                guard !status.running else {
                    Diag.log("自动启动：Redis 已在运行，跳过")
                    self.scanRedis(reset: true)
                    self.loadRedisOverview()
                    return
                }
                guard status.installed else {
                    self.toast = Toast(text: "自动启动 Redis 失败：找不到 redis-server", ok: false,
                                       detail: "在「设置」里指定路径，或先 brew install redis。")
                    return
                }
                self.perform("正在自动启动 Redis…") { service.start() } after: {
                    self.refreshRedisStatus()
                }
            }
        }
    }

    /// 剪贴板同步用的 Redis 连接参数（值类型，可以安全地带进后台线程）。
    var clipboardRedisTarget: ClipboardRedisTarget {
        ClipboardRedisTarget(host: redis.host, port: redis.port, password: redis.password)
    }

    /// 剪贴板记录开关（同时落盘）。
    func setClipboardRecording(_ on: Bool) {
        settings.clipboard.enabled = on
        persistSettings()
        clipboard.setRecording(on)
    }

    // MARK: 顶部小组件

    /// 往顶部小组件里添加图标：去重、保持添加顺序。面板里点「＋」或拖进来都走这里。
    func addDockletApps(_ paths: [String]) {
        var added = 0
        for path in paths where !settings.docklet.appPaths.contains(path) {
            settings.docklet.appPaths.append(path)
            added += 1
        }
        guard added > 0 else { return }
        SettingsStore.save(settings)
        Diag.log("顶部小组件：新增 \(added) 个图标")
    }

    /// 从顶部小组件里移除图标（只是不再显示，不碰应用本身）。
    func removeDockletApp(_ path: String) {
        guard settings.docklet.appPaths.contains(path) else { return }
        settings.docklet.appPaths.removeAll { $0 == path }
        SettingsStore.save(settings)
        Diag.log("顶部小组件：移除图标 \(path)")
    }

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

    /// 把界面上的输入（邮箱 / 阿里云凭据）落盘，并让服务拿到最新配置
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
        // 凭据统一从「域名解析」那份配置里拿（先在主线程取出来，闭包跑在后台）
        let accessKey = settings.dns.aliKey
        let accessSecret = settings.dns.aliSecret
        guard !domains.isEmpty else {
            toast = Toast(text: "请先填域名", ok: false)
            return
        }
        if acmeMode == "manual" {
            generateChallenges()
            return
        }
        perform("正在申请证书（DNS 自动验证，可能要 1 分钟）…") {
            service.issueWithAliyun(domains: domains, email: email,
                                    accessKey: accessKey, accessSecret: accessSecret)
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

    /// - Parameter ecc: ECC 证书要带 `--ecc`，否则 acme.sh 会去续同名的 RSA 证书。
    func renewCertificate(_ domain: String, ecc: Bool = false) {
        syncACMESettings()
        let service = acme
        let accessKey = settings.dns.aliKey
        let accessSecret = settings.dns.aliSecret
        perform("正在续期 \(domain)…") {
            service.renew(domain: domain, ecc: ecc, accessKey: accessKey, accessSecret: accessSecret)
        } after: {
            self.loadCertificates()
        }
    }

    func installACMECron() {
        let service = acme
        perform("正在安装自动续期任务…") { service.installCron() }
    }

    // MARK: 证书域名选择器（从阿里云解析记录里挑）

    @Published var acmePickerVisible = false
    @Published var acmePickerDomains: [DNSDomain] = []
    @Published var acmePickerDomain: String?
    @Published var acmePickerRecords: [DNSRecord] = []
    /// 勾中的记录的 RecordId
    @Published var acmePickerSelected: Set<String> = []
    @Published var acmePickerError = ""

    /// 打开选择器：先拉域名列表，再自动选中第一个域名
    func acmeOpenDomainPicker() {
        acmePickerVisible = true
        acmePickerSelected = []
        acmePickerError = ""
        guard settings.dns.isConfigured else {
            acmePickerDomains = []
            acmePickerRecords = []
            acmePickerError = "先在「域名解析」页配好阿里云 AccessKey，才能从解析记录里选域名。"
            return
        }
        syncDNSSettings()
        let service = dns
        load("正在拉取域名列表…", { service.domains() },
             into: { domains in
                 self.acmePickerDomains = domains
                 // 之前选过的域名还在就刷新它，否则落到第一个
                 if let current = self.acmePickerDomain,
                    domains.contains(where: { $0.name == current }) {
                     self.acmePickDomain(current)
                 } else if let first = domains.first {
                     self.acmePickDomain(first.name)
                 } else {
                     self.acmePickerDomain = nil
                     self.acmePickerRecords = []
                     self.acmePickerError = "这个账号下没有域名"
                 }
             },
             onError: { message in
                 self.acmePickerDomains = []
                 self.acmePickerRecords = []
                 self.acmePickerError = message
             })
    }

    func acmePickDomain(_ name: String) {
        acmePickerDomain = name
        acmePickerRecords = []
        acmePickerError = ""
        let service = dns
        load("正在读取 \(name) 的解析记录…", { service.records(domain: name) },
             into: { records in
                 // `_` 开头的是验证记录（_acme-challenge 之类），不是能给证书用的主机名
                 self.acmePickerRecords = records.filter { !$0.rr.hasPrefix("_") }
                 if self.acmePickerRecords.isEmpty {
                     self.acmePickerError = "\(name) 下没有可用的解析记录（只有验证记录）"
                 }
             },
             onError: { message in
                 self.acmePickerRecords = []
                 self.acmePickerError = message
             })
    }

    func acmeTogglePick(_ record: DNSRecord) {
        if acmePickerSelected.contains(record.recordId) {
            acmePickerSelected.remove(record.recordId)
        } else {
            acmePickerSelected.insert(record.recordId)
        }
    }

    /// 勾中的记录换算成域名（`@` 就是主域名本身）
    var acmePickerPicked: [String] {
        acmePickerRecords
            .filter { acmePickerSelected.contains($0.recordId) }
            .map { $0.fqdn }
    }

    /// 追加到域名输入框（已有的不重复加，所以可以分几次挑）
    func acmeConfirmPick() {
        let picked = acmePickerPicked
        if !picked.isEmpty {
            var current = acmeDomainList
            for domain in picked where !current.contains(domain) {
                current.append(domain)
            }
            acmeDomains = current.joined(separator: ", ")
        }
        acmeClosePicker()
    }

    func acmeClosePicker() {
        acmePickerVisible = false
        acmePickerSelected = []
    }

    // MARK: 服务器运维配置（域名解析 / 证书 / 宝塔面板共用）

    /// 切到另一份配置：三页的数据一起换（服务重建 + 运行时状态清空）。
    func opsProfileChanged() {
        persistSettings()
        rebuildServices()
        // 上一套配置的数据不该留在界面上
        dnsState = DNSState()
        acmeChallenges = []
        acmeCertificates = []
        acmeCertError = nil
        acmePickerDomains = []
        acmePickerRecords = []
        acmePickerDomain = nil
        if dnsConfigured { dnsRefreshDomains() }
        refreshACMEStatus()
    }

    func opsAddProfile() {
        settings.addOpsProfile()
        opsProfileChanged()
    }

    func opsRemoveProfile() {
        settings.removeSelectedOpsProfile()
        opsProfileChanged()
    }

    // MARK: 域名解析（阿里云 DNS）

    @Published var dnsState = DNSState()

    /// 凭据是否配好 —— 界面用它决定是显示表单还是先让填 Key
    var dnsConfigured: Bool { settings.dns.isConfigured }

    /// 给别的页面显示用（证书页）：只露 AccessKey 后 4 位，别的地方一律不亮明文
    var dnsCredentialSummary: String {
        guard settings.dns.hasCredentials else { return "未配置" }
        let key = settings.dns.aliKey.trimmingCharacters(in: .whitespaces)
        let label = settings.selectedOpsProfile?.label ?? "阿里云"
        return key.count > 4 ? "\(label)（****\(key.suffix(4))）" : label
    }

    /// 保存设置并让服务拿到最新配置（和证书页一个套路）
    private func syncDNSSettings() {
        SettingsStore.save(settings)
        rebuildServices()
    }

    func dnsRefreshDomains() {
        syncDNSSettings()
        let service = dns
        dnsState.error = ""
        load("正在拉取域名列表…", { service.domains() },
             into: { domains in
                 self.dnsState.domains = domains
                 self.dnsState.loadedAt = Date()
                 self.dnsState.message = domains.isEmpty ? "这个账号下没有域名" : "共 \(domains.count) 个域名"
                 // 选中的域名不在了（换过账号 / 删过域名）就清掉
                 if let selected = self.dnsState.selectedDomain,
                    !domains.contains(where: { $0.name == selected }) {
                     self.dnsState.selectedDomain = nil
                     self.dnsState.records = []
                 }
                 if self.dnsState.selectedDomain == nil, let first = domains.first {
                     self.dnsSelectDomain(first.name)
                 }
             },
             onError: { message in
                 self.dnsState.domains = []
                 self.dnsState.records = []
                 self.dnsState.message = ""
                 self.dnsState.error = message
             })
    }

    func dnsSelectDomain(_ name: String) {
        dnsState.selectedDomain = name
        dnsState.records = []
        dnsState.error = ""
        dnsCancelEdit()
        dnsLoadRecords()
    }

    func dnsLoadRecords() {
        guard let domain = dnsState.selectedDomain else { return }
        let service = dns
        load("正在读取 \(domain) 的解析记录…", { service.records(domain: domain) },
             into: { records in
                 self.dnsState.records = records
                 self.dnsState.loadedAt = Date()
                 self.dnsState.message = records.isEmpty
                     ? "\(domain) 还没有解析记录"
                     : "\(domain)：\(records.count) 条记录"
                 self.dnsState.error = ""
             },
             onError: { message in
                 self.dnsState.records = []
                 self.dnsState.message = ""
                 self.dnsState.error = message
             })
    }

    /// 把某条已有记录填进表单开始改（`editingRecordId` 非空就表示"正在改"）
    func dnsEditRecord(_ record: DNSRecord) {
        dnsState.editingRecordId = record.recordId
        dnsState.editor = DNSRecordDraft.from(record, defaultTTL: settings.dns.clampedTTL)
    }

    func dnsCancelEdit() {
        dnsState.editingRecordId = nil
        dnsState.editor.clear(defaultTTL: settings.dns.clampedTTL)
    }

    /// 提交表单：正在编辑就更新，否则新增
    func dnsSaveRecord() {
        guard let domain = dnsState.selectedDomain else {
            toast = Toast(text: "先在上面选一个域名", ok: false)
            return
        }
        syncDNSSettings()
        let service = dns
        let draft = dnsState.editor
        // 手误抢救：填了 `www.example.com` 就剥成 `www`；`account.admin` 这种
        // 多级子域名不以域名结尾，原样保留
        let rr = DNSService.normalizeRR(draft.rr, domain: domain)
        let value = draft.value.trimmingCharacters(in: .whitespaces)
        let ttl = Int(draft.ttl.trimmingCharacters(in: .whitespaces)) ?? settings.dns.clampedTTL

        // 本地先校验一道：阿里云的报错文案不好懂，来回一趟也慢
        if let problem = service.validate(rr: rr, type: draft.type, value: value, priority: draft.priority) {
            toast = Toast(text: problem, ok: false)
            return
        }

        if let recordId = dnsState.editingRecordId {
            dnsWrite("正在保存解析记录…") {
                service.updateRecord(recordId: recordId, domain: domain, rr: rr, type: draft.type,
                                     value: value, ttl: ttl, priority: draft.priority)
            } after: {
                self.dnsCancelEdit()
                self.dnsLoadRecords()
            }
        } else {
            dnsWrite("正在添加解析记录…") {
                service.addRecord(domain: domain, rr: rr, type: draft.type,
                                  value: value, ttl: ttl, priority: draft.priority)
            } after: {
                // 清空表单，但保留 TTL（连着加几条时不用重填）
                let ttlText = self.dnsState.editor.ttl
                self.dnsState.editor.clear(defaultTTL: Int(ttlText) ?? self.settings.dns.clampedTTL)
                self.dnsLoadRecords()
            }
        }
    }

    /// 删除是破坏性的，先弹个确认框
    func dnsDeleteRecord(_ record: DNSRecord) {
        let alert = NSAlert()
        alert.messageText = "删除这条解析记录？"
        alert.informativeText = "\(record.fqdn)\n\(record.type)　\(record.value)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        syncDNSSettings()
        let service = dns
        let recordId = record.recordId
        dnsWrite("正在删除解析记录…") {
            service.deleteRecord(recordId: recordId)
        } after: {
            if self.dnsState.editingRecordId == recordId { self.dnsCancelEdit() }
            self.dnsLoadRecords()
        }
    }

    /// 写操作用它包一层：`Outcome<String>` 转成 `ActionResult`，好复用通用的提示条
    private func dnsWrite(_ label: String, _ work: @escaping () -> Outcome<String>,
                          after: (() -> Void)? = nil) {
        perform(label, {
            switch work() {
            case .success(let message): return ActionResult(ok: true, message: message)
            case .failure(let message): return ActionResult(ok: false, message: message)
            }
        }, after: after)
    }

    // MARK: AI 开发（无人值守）

    /// 看门狗状态：轮次、阶段、倒计时、日志尾部
    @Published var aiDev = AIDevSnapshot()
    /// codex 环境自检结果：路径、版本、登录态、可用模型、本机代理
    @Published var aiEnv = AIEnvironmentReport()
    /// 最近一次结束的结论（正常结束 / 限额等待 / 已停止…）
    @Published var aiDevMessage = ""
    /// 工作目录里是否已经有完成标记
    @Published var aiDoneFlagExists = false
    /// 「审查者」（默认 DeepSeek）的状态：打包出来的请求、拿回来的报告、错误
    @Published var aiReview = AIReviewState()
    /// 「云端任务」（codex cloud）：任务列表、选中的任务、详情文本
    @Published var aiCloud = AICloudState()

    // MARK: AI 开发（无人值守）

    // MARK: AI 开发（无人值守）

    /// AI 页面改了设置就立刻存盘（模型/推理强度/代理这些下次开 App 还在）
    func syncAISettings() {
        SettingsStore.save(settings)
    }

    /// 重新检测 codex 环境：可执行文件、版本、登录状态、可用模型、本机代理
    func aiInspectEnvironment() {
        load("正在检测 codex 环境…", { .success(AIEnvironment.inspect()) },
             into: { report in
                 self.aiEnv = report
                 var notes: [String] = []
                 if report.codexPath.isEmpty { notes.append("找不到 codex 命令，先装 Codex CLI") }
                 if !report.loggedIn { notes.append("还没登录，先在终端跑一次 codex login") }
                 self.toast = Toast(text: notes.isEmpty ? "codex 环境正常" : notes.joined(separator: "；"),
                                    ok: notes.isEmpty,
                                    detail: "codex：\(report.codexPath.isEmpty ? "未找到" : report.codexPath)"
                                          + "\n版本：\(report.version.isEmpty ? "未知" : report.version)"
                                          + "\n模型来源：\(report.modelsSource)（\(report.models.count) 个）"
                                          + "\n本机代理：\(report.proxy.summary)")
             },
             onError: { message in
                 self.toast = Toast(text: "检测 codex 环境失败", ok: false, detail: message)
             })
    }

    /// 开始跑任务。`resume` = true 时跳过任务描述，直接续跑工作目录里最近的会话。
    func aiStartTask(resume: Bool) {
        let workDir = settings.ai.resolvedWorkDir
        guard let codex = Paths.which("codex") else {
            toast = Toast(text: "找不到 codex 命令", ok: false,
                          detail: "先装好 Codex CLI（npm i -g @openai/codex 或 brew install codex）并登录。")
            return
        }
        guard FileTools.exists(AIEnvironment.authPath) else {
            toast = Toast(text: "codex 还没登录", ok: false,
                          detail: "先在终端跑一次 codex login —— 本工具直接复用 ~/.codex 里的登录态。")
            return
        }
        guard settings.ai.hasWorkDir else {
            toast = Toast(text: "先填「任务目录」", ok: false,
                          detail: "codex 会在那个目录里干活；resume 也按目录找会话，换了目录就等于换了任务。")
            return
        }
        guard FileTools.isDirectory(workDir) else {
            toast = Toast(text: "任务目录不存在：\(workDir)", ok: false)
            return
        }
        if !resume, settings.ai.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            toast = Toast(text: "先写「任务描述」", ok: false,
                          detail: "新建会话必须有任务描述；只想接着上次跑，请点「续跑最近会话」。")
            return
        }
        SettingsStore.save(settings)
        aiDevMessage = ""
        refreshAIDoneFlag()
        aiRunner.start(settings: settings.ai, resume: resume, codexPath: codex)
        toast = Toast(text: resume ? "已开始续跑最近的会话" : "已开始执行任务", ok: true,
                      detail: "看门狗会一直盯着；碰到 5 小时限额会等到恢复时间再自动续跑，随时可以停。")
    }

    /// 停：先给 codex 发 SIGTERM，3 秒不退再 SIGKILL
    func aiStopTask() {
        guard aiDev.running else { return }
        aiRunner.stop()
        aiDevMessage = "已请求停止，等 codex 退出…"
    }

    /// 标记任务完成：在任务目录放一个 `.codex_done`，看门狗下一轮开始前就会退出
    func aiMarkTaskDone() {
        let workDir = settings.ai.resolvedWorkDir
        guard settings.ai.hasWorkDir, FileTools.isDirectory(workDir) else {
            toast = Toast(text: "任务目录无效，标记失败", ok: false)
            return
        }
        let flag = workDir + "/" + AIDevRunner.doneFlagName
        if let error = FileTools.write(flag, "done \(Date())\n") {
            toast = Toast(text: "写完成标记失败", ok: false, detail: error)
            return
        }
        refreshAIDoneFlag()
        toast = Toast(text: "已标记完成", ok: true,
                      detail: "看门狗会在下一轮开始前退出；想再跑一次，点「删除完成标记」。")
    }

    func aiClearDoneFlag() {
        let workDir = settings.ai.resolvedWorkDir
        guard settings.ai.hasWorkDir else { return }
        try? FileManager.default.removeItem(atPath: workDir + "/" + AIDevRunner.doneFlagName)
        refreshAIDoneFlag()
        toast = Toast(text: "已删除完成标记", ok: true)
    }

    private func refreshAIDoneFlag() {
        let workDir = settings.ai.resolvedWorkDir
        aiDoneFlagExists = settings.ai.hasWorkDir && FileTools.exists(workDir + "/" + AIDevRunner.doneFlagName)
    }

    // MARK: 审查与修复（另一位云端模型当审查者）

    /// 一次审查的产物（打包好的请求 + 拿回来的报告 + 落盘路径）。
    private struct ReviewRunResult {
        var requestText = ""
        var requestPath = ""
        var report = ReviewReport()
        var reportPath = ""
        var notes = ""
    }

    /// 收集审查材料：需求原文 + 每轮自我说明 + git 改动 + 验收结果。
    /// 静态函数，方便直接在后台线程跑（不碰 self 状态）。
    private static func collectReviewRequest(workDir: String,
                                             aiSettings: AIDevSettings,
                                             reviewSettings: AIReviewSettings) -> Outcome<ReviewRequest> {
        var request = ReviewRequest()
        request.requirement = aiSettings.prompt
        request.plan = FileTools.read(AIArtifacts.directory(workDir) + "/plan.md")
        request.roundNotes = AIArtifacts.roundNotes(workDir)

        var notes: [String] = []
        let commands = Acceptance.commands(aiSettings.acceptanceCommands)
        if commands.isEmpty {
            notes.append("没有配置验收命令：完成判定只能靠模型自己说，请重点检查功能正确性。")
        } else {
            request.acceptance = Acceptance.run(commands, cwd: workDir,
                                                timeout: TimeInterval(max(30, aiSettings.acceptanceTimeout)))
        }

        let snapshot = GitDiff.collect(workDir: workDir,
                                       maxChars: max(4000, reviewSettings.maxDiffChars))
        request.diff = snapshot.diff
        request.diffStat = snapshot.stat
        request.diffTruncated = snapshot.truncated
        if !snapshot.error.isEmpty { notes.append(snapshot.error) }
        if snapshot.truncated { notes.append("diff 太长已截断，只送去了前一部分。") }
        if !snapshot.untracked.isEmpty {
            notes.append("新建的文件（未跟踪）：" + snapshot.untracked.joined(separator: "、")
                         + "——内容已附在 diff 末尾。")
        }
        request.materialNotes = notes.joined(separator: "\n")

        if request.diff.isEmpty, snapshot.error.isEmpty, request.roundNotes.isEmpty {
            return .failure("拿不到任何材料：这个目录里既没有 git 改动，也没有跑过任务。先让 codex 干一轮再来审查。")
        }
        return .success(request)
    }

    /// 打包 + 调用审查者（整条链都在后台线程跑）。
    private static func performReview(workDir: String, aiSettings: AIDevSettings,
                                      reviewSettings: AIReviewSettings,
                                      callReviewer: Bool) -> Outcome<ReviewRunResult> {
        switch collectReviewRequest(workDir: workDir, aiSettings: aiSettings, reviewSettings: reviewSettings) {
        case .failure(let message):
            return .failure(message)
        case .success(let request):
            let text = ReviewRequestBuilder.markdown(request)
            let requestPath = AIArtifacts.reviewRequestPath(workDir)
            if let error = FileTools.write(requestPath, text) { return .failure(error) }
            var result = ReviewRunResult(requestText: text, requestPath: requestPath, notes: request.materialNotes)
            guard callReviewer else { return .success(result) }
            switch ReviewClient.review(settings: reviewSettings, request: request) {
            case .failure(let message):
                return .failure(message)
            case .success(let report):
                let reportPath = AIArtifacts.reviewReportPath(workDir)
                _ = FileTools.write(reportPath, report.raw)
                result.report = report
                result.reportPath = reportPath
                return .success(result)
            }
        }
    }

    /// 只打包、不调用审查者：把请求写成 `.ai/review-request.md`，
    /// 你可以直接复制给别人看，也可以先确认材料齐不齐。
    func aiPrepareReview() {
        let workDir = settings.ai.resolvedWorkDir
        guard settings.ai.hasWorkDir, FileTools.isDirectory(workDir) else {
            toast = Toast(text: "先填有效的任务目录", ok: false)
            return
        }
        SettingsStore.save(settings)
        let aiSettings = settings.ai
        let reviewSettings = settings.review
        load("正在打包审查材料…",
             { AppModel.performReview(workDir: workDir, aiSettings: aiSettings,
                                      reviewSettings: reviewSettings, callReviewer: false) },
             into: { result in
                 self.aiReview.requestText = result.requestText
                 self.aiReview.requestPath = result.requestPath
                 self.aiReview.materialError = result.notes
                 self.aiReview.error = ""
                 self.toast = Toast(text: "审查材料已打包（\(result.requestText.count) 字符）", ok: true,
                                    detail: "已写到 \(result.requestPath)\n\n\(result.notes)")
             },
             onError: { message in
                 self.aiReview.error = message
                 self.toast = Toast(text: "打包审查材料失败", ok: false, detail: message)
             })
    }

    /// 调审查者（默认 DeepSeek）复核这份交付，拿回结构化的必修复清单。
    func aiRunReview() {
        let workDir = settings.ai.resolvedWorkDir
        guard settings.ai.hasWorkDir, FileTools.isDirectory(workDir) else {
            toast = Toast(text: "先填有效的任务目录", ok: false)
            return
        }
        guard settings.review.isConfigured else {
            toast = Toast(text: "还没配审查者", ok: false,
                          detail: "在「审查与修复」标签页填 baseURL / 模型名 / API 密钥（默认 DeepSeek）。")
            return
        }
        SettingsStore.save(settings)
        let aiSettings = settings.ai
        let reviewSettings = settings.review
        load("正在请 \(reviewSettings.model) 审查…",
             { AppModel.performReview(workDir: workDir, aiSettings: aiSettings,
                                      reviewSettings: reviewSettings, callReviewer: true) },
             into: { result in
                 self.aiReview.requestText = result.requestText
                 self.aiReview.requestPath = result.requestPath
                 self.aiReview.report = result.report
                 self.aiReview.reportPath = result.reportPath
                 self.aiReview.reviewedAt = Date()
                 self.aiReview.materialError = result.notes
                 self.aiReview.error = ""
                 let mustFix = result.report.mustFix.count
                 self.toast = Toast(text: mustFix == 0 ? "审查完成：没有必修项" : "审查完成：必修 \(mustFix) 项",
                                    ok: result.report.parsed,
                                    detail: result.report.summary + "\n\n报告已写到 \(result.reportPath)")
             },
             onError: { message in
                 self.aiReview.error = message
                 self.toast = Toast(text: "审查失败", ok: false, detail: message)
             })
    }

    /// 按审查报告的「必修」清单逐条修：每轮只修一条，修完跑验收，通过才下一条。
    func aiStartFixQueue() {
        let workDir = settings.ai.resolvedWorkDir
        let findings = aiReview.report.mustFix
        guard !findings.isEmpty else {
            toast = Toast(text: "报告里没有必修项，不用修", ok: false)
            return
        }
        guard let codex = Paths.which("codex") else {
            toast = Toast(text: "找不到 codex 命令", ok: false)
            return
        }
        guard settings.ai.hasWorkDir, FileTools.isDirectory(workDir) else {
            toast = Toast(text: "先填有效的任务目录", ok: false)
            return
        }
        if Acceptance.commands(settings.ai.acceptanceCommands).isEmpty {
            toast = Toast(text: "修复队列需要有验收命令", ok: false,
                          detail: "没有验收命令就没法判断某一条到底修好没有。先在「任务」页填一条（例如 ./tests/run.sh）。")
            return
        }
        SettingsStore.save(settings)
        aiDevMessage = ""
        aiReview.fixProgress = "0/\(findings.count)"
        aiRunner.start(settings: settings.ai, resume: true, codexPath: codex, fixQueue: findings)
        toast = Toast(text: "开始按报告逐条修复（\(findings.count) 条）", ok: true,
                      detail: "每条修完会跑验收命令，通过才进入下一条；某条连续两轮都修不好就停下等你。")
    }

    // MARK: 云端任务（codex cloud）

    /// 拉任务列表。这一页是「丢需求 → 云端自己干 → 回来看 diff → apply」那条路。
    func aiCloudRefresh() {
        let cloudSettings = settings.cloud
        load("正在拉取云端任务…", { AICloudClient.list(settings: cloudSettings) },
             into: { tasks in
                 self.aiCloud.tasks = tasks
                 self.aiCloud.loadedAt = Date()
                 self.aiCloud.error = ""
                 self.aiCloud.message = tasks.isEmpty ? "云端还没有任务" : "共 \(tasks.count) 条任务"
                 if let selected = self.aiCloud.selectedID,
                    !tasks.contains(where: { $0.id == selected }) {
                     self.aiCloud.selectedID = nil
                     self.aiCloud.detail = ""
                     self.aiCloud.detailKind = ""
                 }
             },
             onError: { message in
                 self.aiCloud.error = message
                 self.aiCloud.message = ""
             })
    }

    /// 把需求派到云端。这是整套流程的起点，之后关掉 App 也不影响它跑。
    func aiCloudSubmit() {
        let query = aiCloud.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            toast = Toast(text: "先写需求", ok: false)
            return
        }
        guard settings.cloud.isConfigured else {
            toast = Toast(text: "先填云端环境 ID", ok: false,
                          detail: "在终端跑 `codex cloud` 可以浏览/创建云端环境（是一份带仓库的沙箱）。")
            return
        }
        SettingsStore.save(settings)
        aiCloud.message = ""
        aiCloud.error = ""
        let cloudSettings = settings.cloud
        load("正在派发云端任务…", { AICloudClient.exec(query: query, settings: cloudSettings) },
             into: { result in
                 self.aiCloud.query = ""
                 self.aiCloud.message = result.taskID.isEmpty
                     ? "已派发（没从输出里认出任务 ID，刷新列表就能看到）"
                     : "已派发：\(String(result.taskID.prefix(8)))"
                 self.aiCloud.detail = result.output
                 self.aiCloud.detailKind = "派发结果"
                 self.toast = Toast(text: self.aiCloud.message, ok: true, detail: result.output)
                 self.aiCloudRefresh()
             },
             onError: { message in
                 self.aiCloud.error = message
                 self.toast = Toast(text: "派发失败", ok: false, detail: message)
             })
    }

    /// 取选中任务的状态（原始文本，界面直接显示）。
    func aiCloudLoadStatus() {
        guard let task = aiCloud.selectedTask else {
            toast = Toast(text: "先在列表里选一条任务", ok: false)
            return
        }
        let taskID = task.id
        load("正在取任务状态…", { AICloudClient.status(taskID: taskID) },
             into: { text in
                 self.aiCloud.detail = text
                 self.aiCloud.detailKind = "任务状态"
                 self.aiCloud.error = ""
             },
             onError: { message in
                 self.aiCloud.error = message
                 self.toast = Toast(text: "取任务状态失败", ok: false, detail: message)
             })
    }

    /// 取选中任务的改动（unified diff）。
    func aiCloudLoadDiff() {
        guard let task = aiCloud.selectedTask else {
            toast = Toast(text: "先在列表里选一条任务", ok: false)
            return
        }
        let taskID = task.id
        load("正在取云端改动…", { AICloudClient.diff(taskID: taskID, attempt: 1) },
             into: { text in
                 self.aiCloud.detail = text.isEmpty ? "（这条任务没有产生改动）" : text
                 self.aiCloud.detailKind = "改动（diff）"
                 self.aiCloud.error = ""
             },
             onError: { message in
                 self.aiCloud.error = message
                 self.toast = Toast(text: "取改动失败", ok: false, detail: message)
             })
    }

    /// 把选中任务的改动 apply 到本地仓库目录（会改本地文件，所以结果要说清）。
    func aiCloudApply() {
        guard let task = aiCloud.selectedTask else {
            toast = Toast(text: "先在列表里选一条任务", ok: false)
            return
        }
        guard settings.cloud.hasWorkDir else {
            toast = Toast(text: "先填「本地仓库路径」", ok: false,
                          detail: "apply 会把这条任务的 diff 打到那个目录里（它就是云端环境对应的本地仓库）。")
            return
        }
        let taskID = task.id
        let workDir = settings.cloud.resolvedWorkDir
        SettingsStore.save(settings)
        load("正在把云端改动应用到本地…", { AICloudClient.apply(taskID: taskID, attempt: 1, workDir: workDir) },
             into: { text in
                 self.aiCloud.detail = text
                 self.aiCloud.detailKind = "apply 结果"
                 self.toast = Toast(text: "已应用到 \(workDir)", ok: true,
                                    detail: text.isEmpty ? "（codex 没输出内容，去目录里看 git status）" : text)
             },
             onError: { message in
                 self.aiCloud.error = message
                 self.toast = Toast(text: "应用失败", ok: false, detail: message)
             })
    }
}
