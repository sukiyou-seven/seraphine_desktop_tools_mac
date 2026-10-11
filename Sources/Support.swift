import Foundation
import Darwin

// MARK: - 命令执行结果

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }

    var message: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "退出码 \(status)" : out
    }
}

// MARK: - 路径与命令

enum Paths {
    /// GUI App 的 PATH 很有限，必须显式补上 Homebrew 等目录。
    static var searchPaths: [String] {
        [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/opt/homebrew/opt/mongodb-community/bin",
            "/opt/homebrew/opt/redis/bin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            NSHomeDirectory() + "/bin",
        ]
    }

    static var brewPrefix: String {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            if FileManager.default.isExecutableFile(atPath: prefix + "/bin/brew") { return prefix }
        }
        return "/opt/homebrew"
    }

    /// iCloud Drive 的「文稿」目录 —— 放这儿，iPhone 的「文件」App 能直接取到。
    /// 没开 iCloud 云盘时返回空串。
    static var iCloudDocuments: String {
        let path = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/Documents"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return "" }
        return path
    }

    static func which(_ name: String) -> String? {
        // 已经给了绝对路径
        if name.contains("/"), FileManager.default.isExecutableFile(atPath: name) { return name }
        for dir in searchPaths {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("DBManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var confDir: URL { ensure(appSupport.appendingPathComponent("conf", isDirectory: true)) }
    static var logDir: URL { ensure(appSupport.appendingPathComponent("log", isDirectory: true)) }
    static var runDir: URL { ensure(appSupport.appendingPathComponent("run", isDirectory: true)) }
    static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    /// 剪贴板历史的固化文件（只存文本，上限 2 MB，见 `ClipboardHistory`）。
    static var clipboardFile: URL { appSupport.appendingPathComponent("clipboard.json") }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func ensureDirectory(forFile path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty, dir != "/" {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }
}

enum Shell {
    /// 同步执行外部命令（带超时），不抛异常。
    /// extraEnv 用于传敏感值（例如 MySQL 的 MYSQL_PWD），避免密码出现在命令行参数里。
    static func run(_ args: [String], timeout: TimeInterval = 60, cwd: String? = nil,
                    extraEnv: [String: String] = [:]) -> CommandResult {
        guard let executable = Paths.which(args[0]) ?? (args[0].hasPrefix("/") ? args[0] : nil) else {
            return CommandResult(status: 127, stdout: "", stderr: "找不到可执行文件：\(args[0])")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(args.dropFirst())

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.searchPaths.joined(separator: ":")
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        for (key, value) in extraEnv { env[key] = value }
        process.environment = env
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return CommandResult(status: 126, stdout: "", stderr: error.localizedDescription)
        }

        let done = DispatchSemaphore(value: 0)
        var timedOut = false
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
            done.signal()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        _ = done.wait(timeout: .now() + 0.1)

        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        if timedOut {
            return CommandResult(status: 124, stdout: out,
                                 stderr: err.isEmpty ? "执行超时（\(Int(timeout)) 秒）" : err)
        }
        let commandLine = "\(executable) \(process.arguments?.joined(separator: " ") ?? "")"
        Diag.log("$ \(redactSecrets(commandLine)) → rc=\(process.terminationStatus)")

        return CommandResult(status: process.terminationStatus, stdout: out, stderr: err)
    }

    /// 日志脱敏：连接串里的密码一律替换成 ***（工具会执行带凭据的 mongodb:// 命令）。
    /// 把要写进日志的命令/输出里的敏感值遮掉。
    /// 覆盖三类：URL 里的 `user:pass@`、环境变量式赋值（`VPN_IPSEC_PSK=…`、`VPN_PASSWORD=…`、
    /// `DBM_SSH_PASSWORD=…`）、以及 JSON 里的 password 一类字段。
    /// 保留旧版环境变量凭据的遮罩规则，避免历史命令中的敏感值泄漏。
    static func redactSecrets(_ text: String) -> String {
        var result = text
        let rules: [(pattern: String, template: String)] = [
            ("://([^:/@\\s]+):([^@\\s]+)@", "://$1:***@"),
            ("(?i)(VPN_IPSEC_PSK|VPN_PASSWORD|DBM_SSH_PASSWORD)=(\\'?)([^\\'\\s]+)", "$1=$2***"),
            ("(?i)\\b(password|passwd|pwd)=(\\'?)([^\\'\\s]+)", "$1=$2***"),
            ("(?i)(\"(password|passwd|pwd|api_sk|secret)\"\\s*:\\s*\")[^\"]*(\")", "$1***$3"),
        ]
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range,
                                                    withTemplate: rule.template)
        }
        return result
    }

    /// 把一段文本安全地包成 shell 单引号参数。
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 派生一个后台常驻进程（不等待、与 App 生命周期解耦），输出追加到日志文件。
    ///
    /// MongoDB 8 起在 macOS 上禁用了 `--fork`/`processManagement.fork`
    /// （BadValue: Server fork+exec ... is incompatible with macOS），
    /// 所以守护进程必须由我们自己在后台拉起。
    static func spawnBackground(executable: String, arguments: [String], logPath: String,
                                pidFile: String? = nil) -> (pid: Int32, error: String?) {
        Paths.ensureDirectory(forFile: logPath)
        if !FileTools.exists(logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let parts = ([executable] + arguments).map(shellQuote).joined(separator: " ")
        // nohup：忽略 SIGHUP，避免工具退出时把数据库一起带走
        var script = "nohup \(parts) >> \(shellQuote(logPath)) 2>&1 < /dev/null & echo $!"
        if let pidFile {
            Paths.ensureDirectory(forFile: pidFile)
            script += " > \(shellQuote(pidFile))"
        }
        let result = run(["/bin/sh", "-c", script], timeout: 15)
        guard result.ok else { return (0, result.message) }
        guard let pidFile else { return (0, nil) }
        let pid = ProcUtil.readPidFile(pidFile)
        return (pid, nil)
    }

}

// MARK: - 端口 / 进程

enum PortCheck {
    static func isOpen(host: String, port: Int, timeout: TimeInterval = 0.6) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr(host.isEmpty ? "127.0.0.1" : host)

        let rc = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    static func waitOpen(host: String, port: Int, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isOpen(host: host, port: port) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return isOpen(host: host, port: port)
    }

    static func waitClosed(host: String, port: Int, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isOpen(host: host, port: port) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return !isOpen(host: host, port: port)
    }

    /// 监听该端口的进程号（依赖 /usr/sbin/lsof）。
    static func pids(forPort port: Int) -> [Int32] {
        let lsof = FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") ? "/usr/sbin/lsof" : "lsof"
        let result = Shell.run([lsof, "-nP", "-tiTCP:\(port)", "-sTCP:LISTEN"], timeout: 10)
        guard result.ok else { return [] }
        return result.stdout.lines.compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}

enum ProcUtil {
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func terminate(_ pid: Int32, signal: Int32 = SIGTERM) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, signal) == 0
    }

    /// 取 pid 对应的可执行文件名（取不到返回空串）。
    static func processName(_ pid: Int32) -> String {
        guard pid > 0 else { return "" }
        let result = Shell.run(["/bin/ps", "-p", String(pid), "-o", "comm="], timeout: 5)
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name as NSString).lastPathComponent
    }

    /// 该 pid 是否就是名为 name 的进程。
    /// 用于防止两种事故：pid 文件残留 + pid 被系统复用；端口被别人占用时误杀无辜进程。
    /// 判断 `ps -o comm=` 的输出是否就是某个进程。
    ///
    /// ⚠️ macOS 上这个输出是**完整路径**（例如 `/opt/homebrew/bin/redis-server`），
    /// 所以必须按 basename 比较。之前直接写 `viaPs == name`，永远为假 ——
    /// 于是「确认是某服务才动手」的保护全部失效，表现就是停止 Redis 时
    /// SIGTERM 兜底被静默跳过（日志里 ps 明明查到了进程，之后却什么也没做）。
    ///
    /// 抽成纯函数也是为了能测：沙箱里 `ps` / `pgrep` 不可用，测不了真实进程。
    static func processNameMatches(_ raw: String, _ name: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !name.isEmpty else { return false }
        return (text as NSString).lastPathComponent == name || text == name
    }

    static func isProcess(_ pid: Int32, named name: String) -> Bool {
        guard pid > 0, isAlive(pid) else { return false }
        let viaPs = processName(pid)
        if !viaPs.isEmpty { return processNameMatches(viaPs, name) }
        // ps 不可用时退回 pgrep -x
        let result = Shell.run(["/usr/bin/pgrep", "-x", name], timeout: 5)
        return result.stdout.lines
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .contains(pid)
    }

    /// 占用该端口的进程里，属于 name 的那个 pid（没有则返回 0）。
    static func servicePid(port: Int, named name: String) -> Int32 {
        for pid in PortCheck.pids(forPort: port) where isProcess(pid, named: name) {
            return pid
        }
        return 0
    }

    /// 端口被谁占着（用于给出「不是 MongoDB 占用的」这类提示）。
    static func describePortOwner(port: Int) -> String {
        let pids = PortCheck.pids(forPort: port)
        guard !pids.isEmpty else { return "" }
        return pids.map { pid -> String in
            let name = processName(pid)
            return name.isEmpty ? "pid \(pid)" : "\(name)(pid \(pid))"
        }.joined(separator: "、")
    }

    static func readPidFile(_ path: String) -> Int32 {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let first = text.lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let pid = Int32(first.trimmingCharacters(in: .whitespaces)) else { return 0 }
        return pid
    }
}

// MARK: - 文件工具

extension String {
    /// 按行切分。必须自定义：Swift 里 CRLF 是**一个** Character（字形簇），
    /// 直接用 split(separator: "\n") 处理 Redis / 某些工具输出的 CRLF 文本会一行都切不开。
    /// 与 split(omittingEmptySubsequences: false) 语义一致：保留空行与末尾空元素。
    var lines: [String] {
        var result: [String] = []
        var current = ""
        for character in self {
            if character.isNewline {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }

    /// 原文本使用的换行风格，用于写回时保持一致。
    var dominantNewline: String { contains("\r\n") ? "\r\n" : "\n" }
}

enum FileTools {
    static func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    @discardableResult
    static func write(_ path: String, _ text: String) -> String? {
        Paths.ensureDirectory(forFile: path)
        let data = Data(text.utf8)
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return nil
        } catch {
            // 某些受限环境下原子写（临时文件 + 替换）会被拒绝，退回普通写入。
            do {
                try data.write(to: URL(fileURLWithPath: path))
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    /// 写入前把原文备份到 xxx.bak；返回 (备份路径, 错误信息)。
    static func writeWithBackup(_ path: String, old: String, new: String) -> (backup: String?, error: String?) {
        let backup = path + ".bak"
        if let error = write(backup, old) { return (nil, error) }
        if let error = write(path, new) { return (nil, error) }
        return (backup, nil)
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// 读取文件末尾若干行（最多读最后 256KB）。
    static func tail(_ path: String, lines: Int = 60) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 256 * 1024
        let offset = size > chunk ? size - chunk : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.lines.suffix(lines).joined(separator: "\n")
    }

    static func humanBytes(_ value: Int64) -> String {
        var num = Double(value)
        for unit in ["B", "KB", "MB", "GB", "TB"] {
            if abs(num) < 1024 || unit == "TB" {
                return unit == "B" ? "\(Int(num))B" : String(format: "%.1f%@", num, unit)
            }
            num /= 1024
        }
        return String(format: "%.1fTB", num)
    }
}

// MARK: - 建库时的用户名同步

enum UsernameSync {
    /// 用户名默认与数据库名保持一致。
    /// 一旦用户手动改过用户名（当前值与上次自动填的值不同），就不再自动覆盖。
    static func follow(currentUsername: String, lastAutoUsername: String,
                       databaseName: String) -> (username: String, lastAuto: String) {
        let name = databaseName.trimmingCharacters(in: .whitespaces)
        if currentUsername.isEmpty || currentUsername == lastAutoUsername {
            return (name, name)
        }
        return (currentUsername, lastAutoUsername)
    }
}

// MARK: - 密码生成

enum PasswordGenerator {
    // 刻意排除三类字符：
    // ① 容易看错：l I 1 O 0
    // ② 会破坏连接串/URL 的：@ : / # ? & = % 空格
    // ③ 会引起 shell / 配置转义麻烦的：" \ '
    // 这样生成的密码可以直接贴进 mongodb://user:pwd@host/db 而不用编码。
    private static let letters = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let digits = Array("23456789")
    private static let symbols = Array("!$^*._-~")

    /// 生成强密码：保证至少含字母、数字、符号各一个。
    static func make(length: Int = 20) -> String {
        let target = max(8, length)
        var pool = letters + digits + symbols
        var characters: [Character] = [
            letters.randomElement()!,
            digits.randomElement()!,
            symbols.randomElement()!,
        ]
        while characters.count < target {
            characters.append(pool.randomElement()!)
        }
        characters.shuffle()
        _ = pool.popLast()
        return String(characters)
    }
}

// MARK: - JS 字面量（避免引号注入）

enum JSLiteral {
    static func string(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - 轻量结果类型

/// 只区分“成功带值”和“失败带一句人话”，避免到处写 Result<T, Error>。
enum Outcome<T> {
    case success(T)
    case failure(String)

    /// 只映射成功值，失败原样透传（`Result` 那套 map 的等价物）。
    func map<U>(_ transform: (T) -> U) -> Outcome<U> {
        switch self {
        case .success(let value): return .success(transform(value))
        case .failure(let message): return .failure(message)
        }
    }
}
