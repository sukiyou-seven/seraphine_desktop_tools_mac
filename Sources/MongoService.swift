import Foundation

struct MongoStatus {
    var installed = false
    var binary = ""
    var shell = ""
    var running = false
    var pid: Int32 = 0
    var host = "127.0.0.1"
    var port = 27017
    var confPath = ""
    var confExists = false
    var dbPath = ""
    var logPath = ""
    var version = ""
    var ping = ""
}

struct MongoDatabase: Identifiable {
    var id: String { name }
    var name: String
    var sizeBytes: Int64
    var sizeLabel: String { FileTools.humanBytes(sizeBytes) }
}

struct MongoUser: Identifiable {
    var id: String { user }
    var user: String
    var roles: [String]
}

/// 数据库里真实存在的用户（一次查出所有库的）
struct MongoDbUser: Identifiable {
    var database: String
    var user: String
    var id: String { "\(database)/\(user)" }
}

/// 只持有值类型的设置，本身无状态，可在后台线程安全使用。
final class MongoService: @unchecked Sendable {
    private(set) var settings: MongoSettings

    init(settings: MongoSettings) {
        self.settings = settings
    }

    // MARK: 路径解析

    var binary: String? {
        let custom = settings.bin.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return FileTools.exists(custom) ? custom : nil }
        return Paths.which("mongod")
    }

    var shellPath: String? {
        let custom = settings.shell.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return FileTools.exists(custom) ? custom : nil }
        return Paths.which("mongosh") ?? Paths.which("mongo")
    }

    var confPath: String {
        let custom = settings.config.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        for candidate in [Paths.brewPrefix + "/etc/mongod.conf", "/usr/local/etc/mongod.conf"]
        where FileTools.exists(candidate) { return candidate }
        return Paths.confDir.appendingPathComponent("mongod.conf").path
    }

    var defaultDbPath: String {
        let custom = settings.dbpath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        for candidate in [Paths.brewPrefix + "/var/mongodb", Paths.brewPrefix + "/var/db/mongodb"]
        where FileTools.isDirectory(candidate) { return candidate }
        return Paths.appSupport.appendingPathComponent("mongodb").path
    }

    var defaultLogPath: String {
        let custom = settings.logpath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        return Paths.logDir.appendingPathComponent("mongod.log").path
    }

    var host: String {
        let raw = settings.bindIp.trimmingCharacters(in: .whitespaces)
        let first = raw.split(separator: ",").first.map(String.init) ?? "127.0.0.1"
        return first.isEmpty ? "127.0.0.1" : first
    }

    var port: Int { settings.port }

    // MARK: 配置文件

    @discardableResult
    func ensureConf() -> (path: String, generated: Bool) {
        let path = confPath
        if FileTools.exists(path) { return (path, false) }
        Paths.ensureDirectory(forFile: path)
        // 只能用 defaultDbPath / defaultLogPath：effectiveXxx 需要先读配置文件，
        // 而读配置文件又要求它先存在，会无限递归导致栈溢出。
        let text = ConfStore.generateMongodConf(dbPath: defaultDbPath, logPath: defaultLogPath,
                                                port: port,
                                                bindIp: settings.bindIp.isEmpty ? "127.0.0.1" : settings.bindIp,
                                                auth: false)
        FileTools.write(path, text)
        return (path, true)
    }

    var effectiveDbPath: String {
        let configured = ConfStore.mongoGet(rawConfigText(), path: ["storage", "dbPath"])
        return configured.isEmpty ? defaultDbPath : configured
    }

    var effectiveLogPath: String {
        let configured = ConfStore.mongoGet(rawConfigText(), path: ["systemLog", "path"])
        return configured.isEmpty ? defaultLogPath : configured
    }

    /// 配置里是否开启了鉴权（决定建库时是否必须设密码、以及提示文案）。
    var authorizationEnabled: Bool {
        ConfStore.mongoGet(rawConfigText(), path: ["security", "authorization"]).lowercased() == "enabled"
    }

    func rawConfigText() -> String {
        let (path, _) = ensureConf()
        return FileTools.read(path)
    }

    func configText() -> String {
        let (path, generated) = ensureConf()
        let header = "# 文件：\(path)\(generated ? "（由 DBManager 生成）" : "")\n"
        return header + FileTools.read(path)
    }

    func confParams() -> [(spec: ConfStore.KeySpec, value: String)] {
        let text = rawConfigText()
        return ConfStore.mongoKeys.map { spec in
            let path = spec.id.split(separator: ".").map(String.init)
            let value = ConfStore.mongoGet(text, path: path)
            return (spec, value.isEmpty ? spec.placeholder : value)
        }
    }

    func setParam(_ id: String, value: String) -> ActionResult {
        let (path, _) = ensureConf()
        let old = FileTools.read(path)
        let parts = id.split(separator: ".").map(String.init)
        let new = ConfStore.mongoSet(old, path: parts, value: value)
        return commit(path: path, old: old, new: new, verb: "已更新 \(id) = \(value)")
    }

    func saveConfigText(_ new: String) -> ActionResult {
        let (path, _) = ensureConf()
        let old = FileTools.read(path)
        return commit(path: path, old: old, new: new, verb: "配置已保存")
    }

    private func commit(path: String, old: String, new: String, verb: String) -> ActionResult {
        guard old != new else { return ActionResult(ok: false, message: "内容没有变化") }
        let (backup, error) = FileTools.writeWithBackup(path, old: old, new: new)
        if let error { return .failure("写入失败：\(error)") }
        var result = ActionResult(ok: true, message: verb)
        result.backupPath = backup ?? ""
        if status().running {
            result.detail = "服务正在运行，配置改动需重启后生效"
        }
        return result
    }

    func logTail(lines: Int = 80) -> String {
        let text = FileTools.tail(effectiveLogPath, lines: lines)
        return text.isEmpty ? "（日志为空或不存在：\(effectiveLogPath)）" : text
    }

    // MARK: 状态

    func status(probePing: Bool = true) -> MongoStatus {
        let (conf, _) = ensureConf()
        var info = MongoStatus()
        info.binary = binary ?? ""
        info.shell = shellPath ?? ""
        info.installed = binary != nil
        info.confPath = conf
        info.confExists = FileTools.exists(conf)
        info.dbPath = effectiveDbPath
        info.logPath = effectiveLogPath
        info.host = host
        info.port = port
        // 「是否运行」只认端口：pid 文件可能残留，pid 也可能被系统复用。
        let portIsOpen = PortCheck.isOpen(host: host, port: port)
        info.running = portIsOpen
        info.pid = currentPid()
        if portIsOpen && info.pid == 0 { info.pid = PortCheck.pids(forPort: port).first ?? 0 }

        if let binary {
            let version = Shell.run([binary, "--version"], timeout: 20)
            if version.ok, let line = version.stdout.lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                info.version = line.trimmingCharacters(in: .whitespaces)
            }
        }
        if info.running && probePing {
            if shellPath == nil {
                info.ping = "端口在监听（未找到 mongosh，无法验证登录）"
            } else {
                let result = mongoshEval("print(db.runCommand({ping:1}).ok)")
                let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                info.ping = value.hasSuffix("1") ? "ok" : (result.message.isEmpty ? "未知" : result.message)
            }
        }
        return info
    }

    /// 只返回「确实是 mongod」的 pid：以端口占用者优先，其次才看 pid 文件（且必须进程名匹配）。
    private func currentPid() -> Int32 {
        // 端口占用者也必须确认是 mongod：端口可能被别的程序占着，绝不能对无关进程动手。
        let fromPort = ProcUtil.servicePid(port: port, named: "mongod")
        if fromPort > 0 { return fromPort }

        var candidates: [Int32] = []
        let fromConfig = ConfStore.mongoGet(rawConfigText(), path: ["processManagement", "pidFilePath"])
        if !fromConfig.isEmpty { candidates.append(ProcUtil.readPidFile(fromConfig)) }
        candidates.append(ProcUtil.readPidFile(Paths.runDir.appendingPathComponent("mongod.pid").path))

        for candidate in candidates where ProcUtil.isProcess(candidate, named: "mongod") {
            return candidate
        }
        return 0
    }

    // MARK: 启动 / 停止

    func start() -> ActionResult {
        guard let binary else {
            return .failure("找不到 mongod。请先安装（brew install mongodb-community），或在「设置」里手动指定路径。")
        }
        if PortCheck.isOpen(host: host, port: port) {
            let owner = ProcUtil.describePortOwner(port: port)
            if ProcUtil.servicePid(port: port, named: "mongod") > 0 {
                return .failure("端口 \(port) 已在监听，MongoDB 看起来已经在运行")
            }
            return .failure("端口 \(port) 被其它程序占用（\(owner)），不是 MongoDB。请先释放端口，或改配置文件里的 net.port。")
        }

        let (conf, generated) = ensureConf()
        var notes: [String] = []
        if generated { notes.append("使用新生成的配置：\(conf)") }

        // MongoDB 8 起在 macOS 上禁用了 fork，配置里若写了 fork 必须去掉，否则拒绝启动。
        let text = FileTools.read(conf)
        if ConfStore.mongoGet(text, path: ["processManagement", "fork"]).lowercased() == "true" {
            let updated = ConfStore.mongoSet(text, path: ["processManagement", "fork"], value: "false")
            let (backup, error) = FileTools.writeWithBackup(conf, old: text, new: updated)
            if error == nil {
                notes.append("已把 processManagement.fork 改为 false：MongoDB 8 起 macOS 上不支持 fork（原文件备份到 \(backup ?? "")）")
            }
        }

        let confText = FileTools.read(conf)
        let dbPath = ConfStore.mongoGet(confText, path: ["storage", "dbPath"])
        let logPath = ConfStore.mongoGet(confText, path: ["systemLog", "path"])
        let resolvedDbPath = dbPath.isEmpty ? defaultDbPath : dbPath
        let resolvedLogPath = logPath.isEmpty ? defaultLogPath : logPath

        do {
            try FileManager.default.createDirectory(atPath: resolvedDbPath, withIntermediateDirectories: true)
        } catch {
            return .failure("无法创建数据目录 \(resolvedDbPath)：\(error.localizedDescription)")
        }
        Paths.ensureDirectory(forFile: resolvedLogPath)

        // 在后台拉起 mongod（不用 --fork），App 退出后它继续运行，端口就绪即算成功。
        let pidFile = Paths.runDir.appendingPathComponent("mongod.pid").path
        Diag.log("启动 MongoDB：\(binary) --config \(conf)")
        let launch = Shell.spawnBackground(executable: binary,
                                           arguments: ["--config", conf],
                                           logPath: resolvedLogPath,
                                           pidFile: pidFile)
        if let error = launch.error {
            return .failure("启动 mongod 失败：\(error)")
        }

        // 端口就绪即成功；进程若提前退出就立刻报错，不让用户干等。
        var ready = PortCheck.isOpen(host: host, port: port)
        let deadline = Date().addingTimeInterval(30)
        while !ready && Date() < deadline {
            if launch.pid > 0 && !ProcUtil.isAlive(launch.pid) {
                break
            }
            Thread.sleep(forTimeInterval: 0.4)
            ready = PortCheck.isOpen(host: host, port: port)
        }
        guard ready else {
            var failure = ActionResult.failure("mongod 没能启动（端口 \(port) 未就绪，进程已退出）。")
            let tail = FileTools.tail(resolvedLogPath, lines: 20)
            failure.logTail = tail.isEmpty ? "（日志为空：\(resolvedLogPath)）" : tail
            return failure
        }

        var success = ActionResult(ok: true, message: "MongoDB 已启动（监听 \(host):\(port)，pid \(currentPid())）")
        success.detail = notes.joined(separator: "\n")
        return success
    }

    func stop() -> ActionResult {
        guard let binary else { return .failure("找不到 mongod 可执行文件") }
        guard PortCheck.isOpen(host: host, port: port) || ProcUtil.isAlive(currentPid()) else {
            return .failure("MongoDB 当前没有在运行")
        }

        let (conf, _) = ensureConf()
        let shutdown = Shell.run([binary, "--config", conf, "--shutdown"], timeout: 90)
        if shutdown.ok && PortCheck.waitClosed(host: host, port: port, timeout: 20) {
            return ActionResult(ok: true, message: "MongoDB 已优雅停止")
        }

        // 最后一道保险：只有确认是 mongod 才发信号
        let pid = currentPid()
        if ProcUtil.isAlive(pid), ProcUtil.isProcess(pid, named: "mongod"), ProcUtil.terminate(pid) {
            if PortCheck.waitClosed(host: host, port: port, timeout: 25) {
                return ActionResult(ok: true, message: "MongoDB 已停止（SIGTERM pid=\(pid)）")
            }
            _ = ProcUtil.terminate(pid, signal: SIGKILL)
            if PortCheck.waitClosed(host: host, port: port, timeout: 10) {
                return ActionResult(ok: true, message: "MongoDB 被强制停止（SIGKILL pid=\(pid)）")
            }
        }
        let owner = ProcUtil.describePortOwner(port: port)
        return .failure("停止失败：\(shutdown.message)"
                        + (owner.isEmpty ? "" : "\n当前占用端口 \(port) 的是：\(owner)"))
    }

    func restart() -> ActionResult {
        let stopResult = stop()
        let startResult = start()
        guard startResult.ok else { return startResult }
        return ActionResult(ok: true, message: "重启完成", detail: stopResult.message)
    }

    // MARK: mongosh 操作

    private func uri(_ database: String, passwordOverride: String? = nil) -> String {
        let user = settings.adminUser.trimmingCharacters(in: .whitespaces)
        if user.isEmpty { return "mongodb://\(host):\(port)/\(database)" }
        let rawPassword = passwordOverride ?? settings.adminPassword
        let password = rawPassword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let encodedUser = user.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? user
        let source = settings.authSource.isEmpty ? "admin" : settings.authSource
        return "mongodb://\(encodedUser):\(password)@\(host):\(port)/\(database)?authSource=\(source)"
    }

    @discardableResult
    func mongoshEval(_ js: String, database: String = "admin", timeout: TimeInterval = 45,
                     passwordOverride: String? = nil) -> CommandResult {
        guard let shellPath else {
            return CommandResult(status: 127, stdout: "",
                                 stderr: "找不到 mongosh（brew install mongodb-community 自带），无法执行该操作")
        }
        return Shell.run([shellPath, uri(database, passwordOverride: passwordOverride), "--quiet", "--eval", js],
                         timeout: timeout)
    }

    private func authHint(_ message: String) -> String {
        let lower = message.lowercased()
        let needsAuth = lower.contains("not authorized") || lower.contains("unauthorized")
            || lower.contains("authentication failed") || lower.contains("requires authentication")
        guard needsAuth else { return "" }
        return """
        该实例已开启鉴权（security.authorization: enabled），这个操作需要管理员权限：
        ① 到「设置」填入管理员用户名/密码（authSource 一般是 admin）；
        ② 如果还没建过管理员用户，用 MongoDB 页顶部的「创建管理员用户」——
        库里一个用户都没有时，MongoDB 允许本地创建第一个（localhost exception）。
        """
    }

    private func jsonLine(from output: String, prefix: Character) -> String? {
        output.lines.reversed().first { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix(String(prefix))
        }.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 库里还没有任何用户时，MongoDB 允许本地连接创建第一个用户（localhost exception）。
    /// 这是「开了鉴权但没建管理员」把自己锁在外面时的自救路径。
    static func createAdminUserScript(user: String, password: String, roles: [String]) -> String {
        let rolesJS = roles
            .map { "[{role: \(JSLiteral.string($0)), db: \"admin\"}]" }
            .joined()
        return """
        const admin = db.getSiblingDB("admin");
        admin.runCommand({createUser: \(JSLiteral.string(user)), pwd: \(JSLiteral.string(password)), roles: \(rolesJS)});
        print(JSON.stringify({action: "created-admin", user: \(JSLiteral.string(user))}));
        """
    }

    func createAdminUser(user: String, password: String, roles: [String] = ["root"]) -> ActionResult {
        let trimmed = user.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure("管理员用户名不能为空") }
        guard !password.isEmpty else { return .failure("管理员密码不能为空") }
        let roleList = roles.isEmpty ? ["root"] : roles

        let result = mongoshEval(Self.createAdminUserScript(user: trimmed, password: password, roles: roleList),
                                 database: "admin")
        guard result.ok else {
            let message = result.message
            if message.lowercased().contains("unauthorized") {
                return .failure("创建管理员失败：这个实例里已经有用户了，localhost exception 不再生效。请改用已有管理员账号，在「设置」里填好凭据。",
                                detail: message)
            }
            return .failure("创建管理员失败：\(message)", detail: authHint(message))
        }
        return ActionResult(ok: true,
                            message: "管理员用户 \(trimmed) 已创建（角色 \(roleList.joined(separator: ", "))）",
                            detail: "凭据已自动填入「设置」，接下来的操作就可以用了。")
    }

    /// 用当前（旧）密码连接，把某个用户的密码改成新值。
    static func changePasswordScript(database: String, user: String, newPassword: String) -> String {
        let db = database.isEmpty ? "admin" : database
        return """
        const target = db.getSiblingDB(\(JSLiteral.string(db)));
        target.runCommand({updateUser: \(JSLiteral.string(user)), pwd: \(JSLiteral.string(newPassword))});
        print(JSON.stringify({action: "password-updated", db: \(JSLiteral.string(db)), user: \(JSLiteral.string(user))}));
        """
    }

    /// 重置管理员密码：用旧密码连上去改，成功了调用方再把设置里的密码同步成新的。
    func changeAdminPassword(user: String, oldPassword: String, newPassword: String,
                             database: String = "admin") -> ActionResult {
        let trimmed = user.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure("管理员用户名不能为空（先在「设置」里填）") }
        guard !newPassword.isEmpty else { return .failure("新密码不能为空") }

        let result = mongoshEval(Self.changePasswordScript(database: database, user: trimmed, newPassword: newPassword),
                                 database: database, passwordOverride: oldPassword)
        guard result.ok else {
            return .failure("重置密码失败：\(result.message)", detail: authHint(result.message))
        }
        return ActionResult(ok: true,
                            message: "管理员 \(trimmed) 的密码已重置（数据库与工具设置都已同步）")
    }

    /// 重置**任意库**里某个用户的密码：用「设置」里的管理员凭据连接，再改目标用户的密码。
    func resetUserPassword(database: String, user: String, newPassword: String) -> ActionResult {
        let db = database.trimmingCharacters(in: .whitespaces)
        let name = user.trimmingCharacters(in: .whitespaces)
        guard !db.isEmpty, !name.isEmpty else { return .failure("库名和用户名都不能为空") }
        guard !newPassword.isEmpty else { return .failure("新密码不能为空") }

        let result = mongoshEval(Self.changePasswordScript(database: db, user: name, newPassword: newPassword),
                                 database: db)
        guard result.ok else {
            return .failure("重置 \(db) 库用户 \(name) 的密码失败：\(result.message)",
                            detail: authHint(result.message))
        }
        return ActionResult(ok: true, message: "\(db) 库的用户 \(name) 密码已重置")
    }

    func databases() -> Outcome<[MongoDatabase]> {
        let js = """
        const r = db.adminCommand({listDatabases:1});
        print(JSON.stringify(r.databases.map(d => ({name: d.name, size: d.sizeOnDisk}))));
        """
        let result = mongoshEval(js)
        guard result.ok else {
            return .failure(result.message + hintSuffix(authHint(result.message)))
        }
        guard let line = jsonLine(from: result.stdout, prefix: "["),
              let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .failure("无法解析 mongosh 返回：\(result.stdout.isEmpty ? result.message : result.stdout)")
        }
        let list = raw.map { item in
            MongoDatabase(name: item["name"] as? String ?? "?",
                          sizeBytes: (item["sizeOnDisk"] as? NSNumber)?.int64Value ?? 0)
        }.sorted { $0.name < $1.name }
        return .success(list)
    }

    func createDatabase(_ name: String) -> ActionResult {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure("数据库名不能为空") }
        guard Self.isValidName(trimmed) else { return .failure("数据库名包含不允许的字符（空格 / \\ . \" $ * < > : | ?）") }

        let js = """
        const n = \(JSLiteral.string(trimmed));
        const d = db.getSiblingDB(n);
        let names = d.getCollectionNames();
        if (names && typeof names.toArray === 'function') { names = names.toArray(); }
        const existed = names.length > 0;
        if (!existed) { d.createCollection('_bootstrap'); }
        let finalNames = d.getCollectionNames();
        if (finalNames && typeof finalNames.toArray === 'function') { finalNames = finalNames.toArray(); }
        print(JSON.stringify({created: !existed, name: n, collections: finalNames}));
        """
        let result = mongoshEval(js)
        guard result.ok else { return .failure(result.message + hintSuffix(authHint(result.message))) }
        if let line = jsonLine(from: result.stdout, prefix: "{"), let data = line.data(using: .utf8),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let created = info["created"] as? Bool ?? false
            if created { return ActionResult(ok: true, message: "数据库 \(trimmed) 已创建") }
            let collections = (info["collections"] as? [String]) ?? []
            return ActionResult(ok: true,
                                message: "数据库 \(trimmed) 已存在，未做改动",
                                detail: "现有集合：\(collections.isEmpty ? "（空）" : collections.joined(separator: ", "))")
        }
        return ActionResult(ok: true, message: "已执行：\(result.stdout.isEmpty ? result.message : result.stdout)")
    }

    /// 同样走 dropDatabase 命令，不依赖 shell 方法。
    static func dropDatabaseScript(_ name: String) -> String {
        """
        const result = db.getSiblingDB(\(JSLiteral.string(name))).runCommand({dropDatabase: 1});
        print(JSON.stringify({dropped: \(JSLiteral.string(name)), ok: result.ok}));
        """
    }

    func dropDatabase(_ name: String) -> ActionResult {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard Self.isValidName(trimmed) else { return .failure("数据库名无效") }
        let result = mongoshEval(Self.dropDatabaseScript(trimmed))
        guard result.ok else { return .failure(result.message + hintSuffix(authHint(result.message))) }
        return ActionResult(ok: true, message: "数据库 \(trimmed) 已删除")
    }

    /// 注意：mongosh 里 `db.getUsers()` 返回的是**游标**（没有 map/some），
    /// 必须走 `usersInfo` 命令拿普通数组。
    static func usersScript(database: String) -> String {
        """
        const r = db.getSiblingDB(\(JSLiteral.string(database))).runCommand({usersInfo: 1});
        print(JSON.stringify((r.users || []).map(u => ({user: u.user, roles: ((u.roles || []).map(x => x.role))}))));
        """
    }

    /// 一次取出所有库的所有用户（`usersInfo: {forAllDBs: true}`，需要管理员权限）。
    /// 注意：**密码读不到** —— MongoDB 只存单向哈希，任何客户端都无法还原。
    static func allUsersScript() -> String {
        """
        const r = db.adminCommand({usersInfo: {forAllDBs: true}});
        print(JSON.stringify((r.users || []).map(u => ({db: u.db, user: u.user}))));
        """
    }

    func allUsers() -> Outcome<[MongoDbUser]> {
        let result = mongoshEval(Self.allUsersScript())
        guard result.ok else {
            return .failure(result.message + hintSuffix(authHint(result.message)))
        }
        guard let line = jsonLine(from: result.stdout, prefix: "["), let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            let output = result.stdout.isEmpty ? result.message : result.stdout
            return .failure("无法解析用户清单：\(output.prefix(300))")
        }
        return .success(raw.compactMap { item in
            guard let db = item["db"] as? String, let user = item["user"] as? String else { return nil }
            return MongoDbUser(database: db, user: user)
        })
    }

    func users(database: String) -> Outcome<[MongoUser]> {
        let name = database.trimmingCharacters(in: .whitespaces).isEmpty ? "admin" : database
        let result = mongoshEval(Self.usersScript(database: name), database: name)
        guard result.ok else { return .failure(result.message + hintSuffix(authHint(result.message))) }
        guard let line = jsonLine(from: result.stdout, prefix: "["), let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // 解析不出来就说清楚，不能静默当成「没有用户」
            let output = result.stdout.isEmpty ? result.message : result.stdout
            return .failure("无法解析用户列表（mongosh 输出：\(output.prefix(300))）")
        }
        return .success(raw.map { MongoUser(user: $0["user"] as? String ?? "?",
                                            roles: ($0["roles"] as? [String]) ?? []) })
    }

    /// 同样不依赖 shell 辅助方法：USERSINFO 判存在，再走 createUser / updateUser 命令。
    static func passwordScript(database: String, user: String, password: String, roles: [String]) -> String {
        let rolesJS = roles
            .map { "[{role: \(JSLiteral.string($0)), db: \(JSLiteral.string(database))}]" }
            .joined()
        return """
        const dbName = \(JSLiteral.string(database)), userName = \(JSLiteral.string(user));
        const pwd = \(JSLiteral.string(password)), roles = \(rolesJS);
        const target = db.getSiblingDB(dbName);
        let existed = false;
        try { existed = ((target.runCommand({usersInfo: userName}).users) || []).length > 0; } catch (e) { existed = false; }
        if (existed) {
          target.runCommand({updateUser: userName, pwd: pwd, roles: roles});
        } else {
          target.runCommand({createUser: userName, pwd: pwd, roles: roles});
        }
        print(JSON.stringify({action: existed ? 'updated' : 'created', db: dbName, user: userName, roles: roles}));
        """
    }

    func setUserPassword(database: String, user: String, password: String, roles: [String]) -> ActionResult {
        let db = database.trimmingCharacters(in: .whitespaces).isEmpty ? "admin" : database
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        guard !trimmedUser.isEmpty else { return .failure("用户名不能为空") }
        guard !password.isEmpty else { return .failure("密码不能为空") }
        guard Self.isValidName(db), !trimmedUser.contains("\\"), !trimmedUser.contains("\"") else {
            return .failure("库名或用户名包含不允许的字符")
        }
        let roleList = roles.isEmpty ? ["readWrite"] : roles
        let result = mongoshEval(Self.passwordScript(database: db, user: trimmedUser,
                                                     password: password, roles: roleList),
                                 database: db)
        guard result.ok else { return .failure(result.message + hintSuffix(authHint(result.message))) }

        let uri = "mongodb://\(urlEncoded(trimmedUser)):\(urlEncoded(password))@\(host):\(port)/\(db)?authSource=\(db)"
        if let line = jsonLine(from: result.stdout, prefix: "{"), let data = line.data(using: .utf8),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let action = (info["action"] as? String) == "created" ? "已创建用户并设置密码" : "已修改密码与角色"
            var message = "\(action)：\(trimmedUser)@\(db)"
            let appliedRoles = (info["roles"] as? [[String: String]])?.compactMap { $0["role"] } ?? roleList
            message += "（角色 \(appliedRoles.joined(separator: ", "))）"
            return ActionResult(ok: true, message: message, detail: "连接串：\(uri)")
        }
        return ActionResult(ok: true, message: "已执行", detail: uri)
    }

    private func urlEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func hintSuffix(_ hint: String) -> String { hint.isEmpty ? "" : "\n\n" + hint }

    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let forbidden = CharacterSet(charactersIn: " /\\\".$*<>:|?")
        return name.rangeOfCharacter(from: forbidden) == nil
    }
}
