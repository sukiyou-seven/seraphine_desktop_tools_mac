import Foundation

// MARK: - 设置模型

struct MongoSettings: Codable {
    var bin = ""
    var shell = ""
    var config = ""
    var dbpath = ""
    var logpath = ""
    var port = 27017
    var bindIp = "127.0.0.1"
    var adminUser = ""
    var adminPassword = ""
    var authSource = "admin"

    init() {}

    /// 宽松解码：缺哪个字段就用默认值。
    /// Swift 合成的解码器要求所有字段都在，手写/旧版的设置文件会导致**整份**设置解不出来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bin = try container.decodeIfPresent(String.self, forKey: .bin) ?? bin
        shell = try container.decodeIfPresent(String.self, forKey: .shell) ?? shell
        config = try container.decodeIfPresent(String.self, forKey: .config) ?? config
        dbpath = try container.decodeIfPresent(String.self, forKey: .dbpath) ?? dbpath
        logpath = try container.decodeIfPresent(String.self, forKey: .logpath) ?? logpath
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? port
        bindIp = try container.decodeIfPresent(String.self, forKey: .bindIp) ?? bindIp
        adminUser = try container.decodeIfPresent(String.self, forKey: .adminUser) ?? adminUser
        adminPassword = try container.decodeIfPresent(String.self, forKey: .adminPassword) ?? adminPassword
        authSource = try container.decodeIfPresent(String.self, forKey: .authSource) ?? authSource
    }
}

struct RedisSettings: Codable {
    var bin = ""
    var cli = ""
    var config = ""
    var dir = ""
    var logfile = ""
    var pidfile = ""
    var port = 6379
    var bind = "127.0.0.1"
    var password = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bin = try container.decodeIfPresent(String.self, forKey: .bin) ?? bin
        cli = try container.decodeIfPresent(String.self, forKey: .cli) ?? cli
        config = try container.decodeIfPresent(String.self, forKey: .config) ?? config
        dir = try container.decodeIfPresent(String.self, forKey: .dir) ?? dir
        logfile = try container.decodeIfPresent(String.self, forKey: .logfile) ?? logfile
        pidfile = try container.decodeIfPresent(String.self, forKey: .pidfile) ?? pidfile
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? port
        bind = try container.decodeIfPresent(String.self, forKey: .bind) ?? bind
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? password
    }
}

struct AppSettings: Codable {
    var mongo = MongoSettings()
    var redis = RedisSettings()
    var mysql = MySQLSettings()
    var acme = ACMESettings()
    var bt = BTSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mongo = try container.decodeIfPresent(MongoSettings.self, forKey: .mongo) ?? mongo
        redis = try container.decodeIfPresent(RedisSettings.self, forKey: .redis) ?? redis
        mysql = try container.decodeIfPresent(MySQLSettings.self, forKey: .mysql) ?? mysql
        acme = try container.decodeIfPresent(ACMESettings.self, forKey: .acme) ?? acme
        bt = try container.decodeIfPresent(BTSettings.self, forKey: .bt) ?? bt
    }
}

enum SettingsStore {
    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    static func save(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: Paths.settingsFile, options: .atomic)
        }
    }
}

// MARK: - 通用结果类型

struct ActionResult {
    let ok: Bool
    let message: String
    var detail: String = ""
    var backupPath: String = ""
    var logTail: String = ""

    static func failure(_ message: String, detail: String = "") -> ActionResult {
        ActionResult(ok: false, message: message, detail: detail)
    }
}

enum Discovered {
    static var brewPrefix: String { Paths.brewPrefix }

    static var summary: [(String, String)] {
        let prefix = Paths.brewPrefix
        let confCandidates = [prefix + "/etc/mongod.conf", "/usr/local/etc/mongod.conf"]
        let redisConfCandidates = [prefix + "/etc/redis.conf", "/usr/local/etc/redis.conf"]
        return [
            ("Homebrew 前缀", prefix),
            ("mongod", Paths.which("mongod") ?? "未找到"),
            ("mongosh", Paths.which("mongosh") ?? Paths.which("mongo") ?? "未找到"),
            ("redis-server", Paths.which("redis-server") ?? "未找到"),
            ("redis-cli", Paths.which("redis-cli") ?? "未找到（本工具不需要它）"),
            ("mongod.conf", confCandidates.first(where: FileTools.exists) ?? "未找到（将使用自动生成的配置）"),
            ("redis.conf", redisConfCandidates.first(where: FileTools.exists) ?? "未找到（将使用自动生成的配置）"),
        ]
    }
}
