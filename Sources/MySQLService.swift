import Foundation

// MARK: - 设置与状态

struct MySQLSettings: Codable {
    var bin = ""          // mysql 客户端
    var serverBin = ""    // mysqld
    var adminBin = ""     // mysqladmin
    var config = ""       // my.cnf
    var datadir = ""
    var logpath = ""
    var socket = ""
    var port = 3306
    var host = "127.0.0.1"
    var adminUser = "root"
    var adminPassword = ""

    init() {}

    /// 宽松解码：缺字段用默认值（同 MongoDB / Redis 的处理）
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bin = try container.decodeIfPresent(String.self, forKey: .bin) ?? bin
        serverBin = try container.decodeIfPresent(String.self, forKey: .serverBin) ?? serverBin
        adminBin = try container.decodeIfPresent(String.self, forKey: .adminBin) ?? adminBin
        config = try container.decodeIfPresent(String.self, forKey: .config) ?? config
        datadir = try container.decodeIfPresent(String.self, forKey: .datadir) ?? datadir
        logpath = try container.decodeIfPresent(String.self, forKey: .logpath) ?? logpath
        socket = try container.decodeIfPresent(String.self, forKey: .socket) ?? socket
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? port
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? host
        adminUser = try container.decodeIfPresent(String.self, forKey: .adminUser) ?? adminUser
        adminPassword = try container.decodeIfPresent(String.self, forKey: .adminPassword) ?? adminPassword
    }
}

struct MySQLStatus {
    var installed = false
    var client = ""
    var server = ""
    var running = false
    var pid: Int32 = 0
    var host = "127.0.0.1"
    var port = 3306
    var confPath = ""
    var dataDir = ""
    var logPath = ""
    var version = ""
    var ping = ""
}

struct MySQLDatabase: Identifiable {
    var name: String
    var sizeBytes: Int64 = 0
    var id: String { name }
    var sizeLabel: String { FileTools.humanBytes(sizeBytes) }
}

struct MySQLTable: Identifiable {
    var name: String
    var rows: Int64 = 0
    var id: String { name }
}

struct MySQLUser: Identifiable {
    var user: String
    var host: String
    var id: String { "\(user)@\(host)" }
    var display: String { "\(user)@\(host)" }
}

// MARK: - 服务

/// MySQL 管理：走 `mysql` / `mysqld` / `mysqladmin` 命令行（brew install mysql 自带）。
/// 密码通过 MYSQL_PWD 环境变量传递，不出现在进程参数里。
final class MySQLService: @unchecked Sendable {
    private(set) var settings: MySQLSettings

    init(settings: MySQLSettings) {
        self.settings = settings
    }

    // MARK: 路径解析

    var client: String? {
        resolve(settings.bin, names: ["mysql"])
    }

    var server: String? {
        resolve(settings.serverBin, names: ["mysqld"])
    }

    var adminTool: String? {
        resolve(settings.adminBin, names: ["mysqladmin"])
    }

    private func resolve(_ configured: String, names: [String]) -> String? {
        let custom = configured.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return FileTools.exists(custom) ? custom : nil }
        for name in names {
            if let found = Paths.which(name) { return found }
        }
        return nil
    }

    var confPath: String {
        let custom = settings.config.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        for candidate in [Paths.brewPrefix + "/etc/my.cnf", "/usr/local/etc/my.cnf",
                          "/etc/my.cnf", Paths.appSupport.appendingPathComponent("my.cnf").path]
        where FileTools.exists(candidate) { return candidate }
        return Paths.appSupport.appendingPathComponent("my.cnf").path
    }

    var dataDir: String {
        let custom = settings.datadir.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        let brewData = Paths.brewPrefix + "/var/mysql"
        return FileTools.isDirectory(brewData) ? brewData : Paths.appSupport.appendingPathComponent("mysql").path
    }

    var logPath: String {
        let custom = settings.logpath.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? Paths.logDir.appendingPathComponent("mysql-error.log").path : custom
    }

    var socketPath: String {
        let custom = settings.socket.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        return Paths.runDir.appendingPathComponent("mysql.sock").path
    }

    var pidFile: String { Paths.runDir.appendingPathComponent("mysql.pid").path }

    var port: Int { settings.port }
    var host: String { settings.host.isEmpty ? "127.0.0.1" : settings.host }
    var adminUser: String { settings.adminUser.isEmpty ? "root" : settings.adminUser }

    // MARK: SQL 执行

    /// 执行一条 SQL。密码走 MYSQL_PWD，避免出现在命令行里。
    @discardableResult
    func runSQL(_ sql: String, database: String? = nil, timeout: TimeInterval = 60,
                passwordOverride: String? = nil) -> CommandResult {
        guard let client else {
            return CommandResult(status: 127, stdout: "",
                                 stderr: "找不到 mysql 客户端。安装方式：brew install mysql；或在「设置」里指定 mysql 路径。")
        }
        var args = [client, "--host=\(host)", "--port=\(port)", "--user=\(adminUser)",
                    "--batch", "--raw", "--skip-column-names"]
        if let database, !database.isEmpty { args.append(database) }
        args += ["-e", sql]

        let password = passwordOverride ?? settings.adminPassword
        var env: [String: String] = [:]
        if !password.isEmpty { env["MYSQL_PWD"] = password }
        return Shell.run(args, timeout: timeout, extraEnv: env)
    }

    /// 把 TSV 输出切成表格
    private func rows(_ output: String) -> [[String]] {
        output.lines.filter { !$0.isEmpty }.map { line in
            line.components(separatedBy: "\t")
        }
    }

    private func authHint(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("access denied") || lower.contains("authentication") {
            return """
            连接被拒绝：多半是「设置」里的管理员用户名/密码不对。
            MySQL 的管理员通常是 root；刚装好（brew install mysql）时 root 没有密码，把密码留空试试。
            """
        }
        if lower.contains("can't connect") || lower.contains("connection refused") {
            return "连不上：确认 MySQL 已经在运行（点上面的「启动」），端口是否是 \(port)。"
        }
        return ""
    }

    // MARK: 状态

    func status() -> MySQLStatus {
        var info = MySQLStatus()
        info.client = client ?? ""
        info.server = server ?? ""
        info.installed = client != nil || server != nil
        info.host = host
        info.port = port
        info.confPath = confPath
        info.dataDir = dataDir
        info.logPath = logPath
        let portIsOpen = PortCheck.isOpen(host: host, port: port)
        info.pid = currentPid()
        info.running = portIsOpen
        if portIsOpen && info.pid == 0 { info.pid = PortCheck.pids(forPort: port).first ?? 0 }

        if let server {
            let version = Shell.run([server, "--version"], timeout: 20)
            if version.ok, let line = version.stdout.lines.first(where: { !$0.isEmpty }) {
                info.version = line.trimmingCharacters(in: .whitespaces)
            }
        } else if let client {
            let version = Shell.run([client, "--version"], timeout: 20)
            if version.ok, let line = version.stdout.lines.first(where: { !$0.isEmpty }) {
                info.version = line.trimmingCharacters(in: .whitespaces)
            }
        }

        if portIsOpen {
            let ping = runSQL("SELECT 1", timeout: 20)
            info.ping = ping.ok ? "ok" : (ping.message.isEmpty ? "连接失败" : ping.message)
        }
        return info
    }

    private func currentPid() -> Int32 {
        let fromPort = ProcUtil.servicePid(port: port, named: "mysqld")
        if fromPort > 0 { return fromPort }
        let fromFile = ProcUtil.readPidFile(pidFile)
        if fromFile > 0, ProcUtil.isProcess(fromFile, named: "mysqld") { return fromFile }
        return 0
    }

    // MARK: 启动 / 停止

    func start() -> ActionResult {
        guard let server else {
            return .failure("找不到 mysqld。安装方式：brew install mysql；装完后点「刷新」，或在「设置」里指定路径。")
        }
        if PortCheck.isOpen(host: host, port: port) {
            let owner = ProcUtil.describePortOwner(port: port)
            if ProcUtil.servicePid(port: port, named: "mysqld") > 0 {
                return .failure("端口 \(port) 已在监听，MySQL 看起来已经在运行")
            }
            return .failure("端口 \(port) 被其它程序占用（\(owner)），不是 MySQL。请先释放端口，或改配置里的 port。")
        }

        // 数据目录必须已经初始化过（有 mysql 系统库）
        if !FileTools.isDirectory(dataDir) || !FileTools.isDirectory(dataDir + "/mysql") {
            return .failure("数据目录看起来还没初始化：\(dataDir)",
                            detail: "首次使用需要初始化，执行（会创建全新的数据目录）：\n"
                                  + "  mkdir -p \(dataDir)\n"
                                  + "  \(server) --initialize-insecure --datadir=\(dataDir)")
        }
        Paths.ensureDirectory(forFile: logPath)
        try? FileManager.default.createDirectory(atPath: Paths.runDir.path, withIntermediateDirectories: true)

        var args = [server, "--daemonize",
                    "--datadir=\(dataDir)",
                    "--port=\(port)",
                    "--bind-address=\(host)",
                    "--socket=\(socketPath)",
                    "--pid-file=\(pidFile)",
                    "--log-error=\(logPath)"]
        // 有配置文件就交给它（命令行的这几项仍会覆盖，保证路径可控）
        if FileTools.exists(confPath) { args.append("--defaults-file=\(confPath)") }

        Diag.log("启动 MySQL：\(server) --daemonize --datadir=\(dataDir)")
        let result = Shell.run(args, timeout: 120)
        guard result.ok else {
            var failure = ActionResult.failure("启动 MySQL 失败：\(result.message)")
            failure.logTail = FileTools.tail(logPath, lines: 25)
            return failure
        }
        guard PortCheck.waitOpen(host: host, port: port, timeout: 30) else {
            var failure = ActionResult.failure("mysqld 已拉起，但端口 \(port) 未就绪")
            failure.logTail = FileTools.tail(logPath, lines: 25)
            return failure
        }
        return ActionResult(ok: true, message: "MySQL 已启动（监听 \(host):\(port)，pid \(currentPid())）")
    }

    func stop() -> ActionResult {
        guard PortCheck.isOpen(host: host, port: port) || ProcUtil.isAlive(currentPid()) else {
            return .failure("MySQL 当前没有在运行")
        }

        // 1) 优先用 mysqladmin shutdown（需要管理员凭据）
        if let adminTool {
            var args = [adminTool, "--host=\(host)", "--port=\(port)", "--user=\(adminUser)", "shutdown"]
            var env: [String: String] = [:]
            if !settings.adminPassword.isEmpty { env["MYSQL_PWD"] = settings.adminPassword }
            let result = Shell.run(args, timeout: 60, extraEnv: env)
            args = []
            if result.ok, PortCheck.waitClosed(host: host, port: port, timeout: 25) {
                return ActionResult(ok: true, message: "MySQL 已优雅停止（mysqladmin shutdown）")
            }
        }

        // 2) pid 文件杀（必须确认是 mysqld）
        let pid = currentPid()
        if pid > 0, ProcUtil.isProcess(pid, named: "mysqld"), ProcUtil.terminate(pid) {
            if PortCheck.waitClosed(host: host, port: port, timeout: 25) {
                return ActionResult(ok: true, message: "MySQL 已停止（SIGTERM pid=\(pid)）")
            }
            _ = ProcUtil.terminate(pid, signal: SIGKILL)
            if PortCheck.waitClosed(host: host, port: port, timeout: 10) {
                return ActionResult(ok: true, message: "MySQL 被强制停止（SIGKILL pid=\(pid)）")
            }
        }
        let owner = ProcUtil.describePortOwner(port: port)
        return .failure("停止失败：端口 \(port) 仍被占用" + (owner.isEmpty ? "" : "（占用者：\(owner)）"),
                        detail: "如果「设置」里的 root 密码不对，mysqladmin shutdown 会失败。")
    }

    func restart() -> ActionResult {
        let stopResult = stop()
        let startResult = start()
        guard startResult.ok else { return startResult }
        return ActionResult(ok: true, message: "重启完成", detail: stopResult.message)
    }

    // MARK: 配置文件（my.cnf：INI 格式）

    func ensureConf() -> (path: String, generated: Bool) {
        let path = confPath
        if FileTools.exists(path) { return (path, false) }
        Paths.ensureDirectory(forFile: path)
        let text = """
        # 由 Seraphim 生成的最小可用配置
        [mysqld]
        port = \(port)
        bind-address = \(host)
        datadir = \(dataDir)
        socket = \(socketPath)
        log-error = \(logPath)
        character-set-server = utf8mb4

        """
        FileTools.write(path, text)
        return (path, true)
    }

    func rawConfigText() -> String {
        let (path, _) = ensureConf()
        return FileTools.read(path)
    }

    func configText() -> String {
        let (path, generated) = ensureConf()
        return "# 文件：\(path)\(generated ? "（由 Seraphim 生成）" : "")\n" + FileTools.read(path)
    }

    func confParams() -> [(spec: ConfStore.KeySpec, value: String)] {
        let text = rawConfigText()
        return ConfStore.mysqlKeys.map { spec in
            let parts = spec.id.split(separator: ".").map(String.init)
            let section = parts.count > 1 ? parts[0] : "mysqld"
            let key = parts.last ?? spec.id
            let value = ConfStore.iniGet(text, section: section, key: key)
            return (spec, value.isEmpty ? spec.placeholder : value)
        }
    }

    func setParam(_ id: String, value: String) -> ActionResult {
        let (path, _) = ensureConf()
        let old = FileTools.read(path)
        let parts = id.split(separator: ".").map(String.init)
        let section = parts.count > 1 ? parts[0] : "mysqld"
        let key = parts.last ?? id
        let new = ConfStore.iniSet(old, section: section, key: key, value: value)
        return commit(path: path, old: old, new: new, verb: "已更新 \(section).\(key) = \(value)")
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
        if status().running { result.detail = "MySQL 正在运行，配置改动需重启后生效" }
        return result
    }

    func logTail(lines: Int = 80) -> String {
        let text = FileTools.tail(logPath, lines: lines)
        return text.isEmpty ? "（日志为空或不存在：\(logPath)）" : text
    }

    // MARK: 数据库

    func databases() -> Outcome<[MySQLDatabase]> {
        let sql = """
        SELECT s.schema_name, IFNULL(t.total, 0)
        FROM information_schema.schemata s
        LEFT JOIN (
          SELECT table_schema, SUM(data_length + index_length) AS total
          FROM information_schema.tables GROUP BY table_schema
        ) t ON t.table_schema = s.schema_name
        ORDER BY s.schema_name
        """
        let result = runSQL(sql)
        guard result.ok else {
            return .failure(result.message + hintSuffix(authHint(result.message)))
        }
        let list = rows(result.stdout).compactMap { fields -> MySQLDatabase? in
            guard let name = fields.first, !name.isEmpty else { return nil }
            let size = fields.count > 1 ? Int64(fields[1]) ?? 0 : 0
            return MySQLDatabase(name: name, sizeBytes: size)
        }
        return .success(list)
    }

    func createDatabase(_ name: String) -> ActionResult {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard Self.isValidName(trimmed) else {
            return .failure("数据库名不合法（只允许字母、数字、下划线、$，且不能以数字开头）")
        }
        let result = runSQL("CREATE DATABASE IF NOT EXISTS `\(trimmed)` "
                            + "CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
        guard result.ok else {
            return .failure("创建数据库失败：\(result.message)", detail: authHint(result.message))
        }
        return ActionResult(ok: true, message: "数据库 \(trimmed) 已创建（字符集 utf8mb4）")
    }

    func dropDatabase(_ name: String) -> ActionResult {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard Self.isValidName(trimmed) else { return .failure("数据库名不合法") }
        let result = runSQL("DROP DATABASE `\(trimmed)`")
        guard result.ok else {
            return .failure("删除数据库失败：\(result.message)", detail: authHint(result.message))
        }
        return ActionResult(ok: true, message: "数据库 \(trimmed) 已删除")
    }

    func tables(in database: String) -> Outcome<[MySQLTable]> {
        let name = database.trimmingCharacters(in: .whitespaces)
        guard Self.isValidName(name) else { return .failure("数据库名不合法") }
        let sql = """
        SELECT table_name, IFNULL(table_rows, 0) FROM information_schema.tables
        WHERE table_schema = \(Self.sqlQuote(name)) ORDER BY table_name
        """
        let result = runSQL(sql)
        guard result.ok else { return .failure(result.message + hintSuffix(authHint(result.message))) }
        let list = rows(result.stdout).compactMap { fields -> MySQLTable? in
            guard let table = fields.first, !table.isEmpty else { return nil }
            return MySQLTable(name: table, rows: fields.count > 1 ? Int64(fields[1]) ?? 0 : 0)
        }
        return .success(list)
    }

    // MARK: 用户

    func users() -> Outcome<[MySQLUser]> {
        let result = runSQL("SELECT user, host FROM mysql.user ORDER BY user, host")
        guard result.ok else {
            return .failure(result.message + hintSuffix(authHint(result.message)))
        }
        let list = rows(result.stdout).compactMap { fields -> MySQLUser? in
            guard let user = fields.first, !user.isEmpty else { return nil }
            return MySQLUser(user: user, host: fields.count > 1 ? fields[1] : "%")
        }
        return .success(list)
    }

    func grants(for user: MySQLUser) -> Outcome<[String]> {
        let result = runSQL("SHOW GRANTS FOR \(Self.sqlQuote(user.user))@\(Self.sqlQuote(user.host))")
        guard result.ok else { return .failure(result.message + hintSuffix(authHint(result.message))) }
        return .success(result.stdout.lines.filter { !$0.isEmpty })
    }

    /// 界面上的权限级别 → MySQL 权限列表
    static func privileges(for level: String, database: String) -> [String] {
        switch level {
        case "read": return ["SELECT"]
        case "readwrite": return ["SELECT", "INSERT", "UPDATE", "DELETE"]
        default: return ["ALL PRIVILEGES"]
        }
    }

    /// 创建用户 / 改密码（可选顺带授权到某个库）。
    func setUserPassword(user: String, host: String, password: String,
                         database: String? = nil, grants: [String] = ["ALL PRIVILEGES"]) -> ActionResult {
        let name = user.trimmingCharacters(in: .whitespaces)
        let hostValue = host.trimmingCharacters(in: .whitespaces).isEmpty ? "%" : host.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .failure("用户名不能为空") }
        guard !password.isEmpty else { return .failure("密码不能为空") }

        let quotedUser = "\(Self.sqlQuote(name))@\(Self.sqlQuote(hostValue))"
        var statements = ["CREATE USER IF NOT EXISTS \(quotedUser) IDENTIFIED BY \(Self.sqlQuote(password))",
                          "ALTER USER \(quotedUser) IDENTIFIED BY \(Self.sqlQuote(password))"]
        var grantedDatabase = ""
        if let database, !database.isEmpty, Self.isValidName(database) {
            let list = grants.isEmpty ? ["ALL PRIVILEGES"] : grants
            statements.append("GRANT \(list.joined(separator: ", ")) ON `\(database)`.* TO \(quotedUser)")
            statements.append("FLUSH PRIVILEGES")
            grantedDatabase = database
        }
        let result = runSQL(statements.joined(separator: ";\n"))
        guard result.ok else {
            return .failure("设置用户失败：\(result.message)", detail: authHint(result.message))
        }
        var message = "用户 \(name)@\(hostValue) 的密码已设置"
        if !grantedDatabase.isEmpty {
            message += "，并已授权访问 \(grantedDatabase)"
        }
        return ActionResult(ok: true, message: message,
                            detail: "连接串示例：mysql://\(name):\(password)@\(host):\(port)/\(grantedDatabase)")
    }

    /// 只改密码（不授权）
    func resetUserPassword(user: String, host: String, newPassword: String) -> ActionResult {
        setUserPassword(user: user, host: host, password: newPassword, database: nil, grants: [])
    }

    // MARK: 工具

    func hintSuffix(_ hint: String) -> String { hint.isEmpty ? "" : "\n\n" + hint }

    /// SQL 字符串字面量：单引号转义（'' 表示一个单引号），反斜杠也转义
    static func sqlQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    /// MySQL 标识符：只允许 ASCII 字母、数字、下划线、$，且首字符不能是数字。
    /// 刻意拒绝中文/空格/横线等：MySQL 虽能建，但容易在文件系统、命令行、转义上出问题。
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        guard let first = name.first, first.isASCII,
              first.isLetter || first == "_" || first == "$" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") }
    }
}
