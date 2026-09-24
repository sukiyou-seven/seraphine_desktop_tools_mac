import Foundation
import Darwin

// DBManager 核心逻辑自测：不依赖 GUI，也不需要本机真的装 MongoDB / Redis。
// 运行方式：./tests/run.sh

setvbuf(stdout, nil, _IONBF, 0)

var checks = 0
var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

let workRoot = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory() + "dbm-selftest"
try? FileManager.default.createDirectory(atPath: workRoot, withIntermediateDirectories: true)

// MARK: ConfStore —— mongod.conf

print("== ConfStore: mongod.conf ==")
var mongoConf = ConfStore.generateMongodConf(dbPath: workRoot + "/db", logPath: workRoot + "/mongod.log",
                                            port: 27017, bindIp: "127.0.0.1", auth: false)
check("读取 net.port", ConfStore.mongoGet(mongoConf, path: ["net", "port"]) == "27017")
check("读取 storage.dbPath", ConfStore.mongoGet(mongoConf, path: ["storage", "dbPath"]) == workRoot + "/db")
check("读取 security.authorization", ConfStore.mongoGet(mongoConf, path: ["security", "authorization"]) == "disabled")

mongoConf = ConfStore.mongoSet(mongoConf, path: ["net", "port"], value: "27019")
check("修改 net.port", ConfStore.mongoGet(mongoConf, path: ["net", "port"]) == "27019")
check("修改不影响 dbPath", ConfStore.mongoGet(mongoConf, path: ["storage", "dbPath"]) == workRoot + "/db")

mongoConf = ConfStore.mongoSet(mongoConf, path: ["security", "authorization"], value: "enabled")
check("启用鉴权", ConfStore.mongoGet(mongoConf, path: ["security", "authorization"]) == "enabled")

mongoConf = ConfStore.mongoSet(mongoConf, path: ["operationProfiling", "mode"], value: "slowOp")
check("新增不存在的 section", ConfStore.mongoGet(mongoConf, path: ["operationProfiling", "mode"]) == "slowOp")
check("新增 section 后原有内容仍在", mongoConf.contains("dbPath: \(workRoot)/db"))

let commented = """
# 手工写的配置
net:
  bindIp: 127.0.0.1   # 只监听本机
  port: 27017
"""
check("注释行不被当成配置", ConfStore.mongoGet(commented, path: ["net", "bindIp"]) == "127.0.0.1")
let commentedEdited = ConfStore.mongoSet(commented, path: ["net", "bindIp"], value: "0.0.0.0")
check("修改保留行内注释", commentedEdited.contains("# 只监听本机"))
check("修改保留文件头注释", commentedEdited.contains("# 手工写的配置"))
check("修改值正确", ConfStore.mongoGet(commentedEdited, path: ["net", "bindIp"]) == "0.0.0.0")

print("== ConfStore: redis.conf ==")
var redisConf = ConfStore.generateRedisConf(port: 6379, bind: "127.0.0.1", dir: workRoot + "/redis",
                                            logFile: workRoot + "/redis.log", pidFile: workRoot + "/redis.pid",
                                            password: "")
check("默认无 requirepass", ConfStore.redisGet(redisConf, key: "requirepass").isEmpty)
check("读取 port", ConfStore.redisGet(redisConf, key: "port") == "6379")

redisConf = ConfStore.redisSet(redisConf, key: "requirepass", value: "s3cret")
check("设置 requirepass", ConfStore.redisGet(redisConf, key: "requirepass") == "s3cret")
redisConf = ConfStore.redisSet(redisConf, key: "maxmemory", value: "512mb")
check("追加 maxmemory 项", ConfStore.redisGet(redisConf, key: "maxmemory") == "512mb")
redisConf = ConfStore.redisUnset(redisConf, key: "requirepass")
check("注释掉 requirepass", ConfStore.redisGet(redisConf, key: "requirepass").isEmpty)

let stockRedisConf = """
# Redis 配置
save 3600 1
# requirepass foobared
appendonly no
"""
let enabledConf = ConfStore.redisSet(stockRedisConf, key: "requirepass", value: "newpass")
check("就地启用被注释的默认项", ConfStore.redisGet(enabledConf, key: "requirepass") == "newpass")
check("启用后其它配置未受影响", enabledConf.contains("save 3600 1") && enabledConf.contains("# Redis 配置"))

print("== 换行与命令解析 ==")
check("CRLF 文本能正确分行", "a\r\nb\r\nc".lines.count == 3)
check("LF 文本能正确分行", "a\nb\nc".lines.count == 3)
check("识别 CRLF 风格", "a\r\nb".dominantNewline == "\r\n")
check("普通参数", RedisService.splitCommandLine("GET user:1") == ["GET", "user:1"])
check("双引号参数", RedisService.splitCommandLine("SET k \"a b\"") == ["SET", "k", "a b"])
check("单引号参数", RedisService.splitCommandLine("SET k 'a b'") == ["SET", "k", "a b"])
check("引号不配对返回 nil", RedisService.splitCommandLine("SET k \"oops") == nil)
check("多余空格被忽略", RedisService.splitCommandLine("  INFO   memory ") == ["INFO", "memory"])

// MARK: RedisService —— 对接进程内假服务器

let requestedPort = Int(ProcessInfo.processInfo.environment["FAKE_REDIS_PORT"] ?? "0") ?? 0
let fake = FakeRedisServer(port: requestedPort)
do {
    try fake.start()
} catch {
    print("无法启动假 Redis 服务器：\(error.localizedDescription)")
    exit(2)
}
let redisPort = fake.boundPort
Thread.sleep(forTimeInterval: 0.3)

print("== RedisService 对接假服务器（127.0.0.1:\(redisPort)）==")
var redisSettings = RedisSettings()
redisSettings.config = workRoot + "/redis.conf"
redisSettings.dir = workRoot + "/redis"
redisSettings.logfile = workRoot + "/redis.log"
redisSettings.pidfile = workRoot + "/redis.pid"
redisSettings.port = redisPort
let redisService = RedisService(settings: redisSettings)

let redisStatus = redisService.status()
check("识别为运行中", redisStatus.running)
check("协议握手成功（含 CRLF 的 INFO 解析）", redisStatus.ping == "ok", redisStatus.ping)
check("从 INFO 读到 keyspace", redisStatus.keys.contains("keys=5"), redisStatus.keys)
check("读到版本信息", redisStatus.version.lowercased().contains("redis"), redisStatus.version)

switch redisService.scanKeys(pattern: "*", cursor: 0, count: 100, database: 0) {
case .success(let page):
    check("SCAN 返回 5 个 key", page.rows.count == 5, "实际 \(page.rows.count)")
    check("标记为已扫完", page.scannedAll)
    check("类型识别为字符串", page.rows.first { $0.key == "user:1" }?.typeLabel == "字符串")
    check("key 列表有序", page.rows.map(\.key) == page.rows.map(\.key).sorted())
case .failure(let message):
    check("SCAN 成功", false, message)
}

switch redisService.value(forKey: "user:1", database: 0) {
case .success(let detail):
    check("字符串值正确", detail.text == "hello world", detail.text ?? "nil")
    check("TTL 显示为永久", detail.ttlLabel == "永久", detail.ttlLabel)
    check("类型标签为中文", detail.typeLabel == "字符串")
case .failure(let message):
    check("读取字符串成功", false, message)
}

switch redisService.value(forKey: "cart:1", database: 0) {
case .success(let detail):
    check("哈希元素数量为 2", detail.count == 2, "实际 \(String(describing: detail.count))")
    check("哈希字段成对解析", detail.rows.count == 2)
    check("哈希字段值正确", detail.rows.first { $0.label == "banana" }?.value == "5")
case .failure(let message):
    check("读取哈希成功", false, message)
}

switch redisService.value(forKey: "queue:jobs", database: 0) {
case .success(let detail):
    check("列表长度 3", detail.count == 3)
    check("列表元素带下标", detail.rows.first?.label == "[0]")
case .failure(let message):
    check("读取列表成功", false, message)
}

switch redisService.value(forKey: "no:such:key", database: 0) {
case .success:
    check("不存在的 key 应当报错", false)
case .failure(let message):
    check("不存在的 key 提示清晰", message.contains("key 不存在"), message)
}

switch redisService.execute("GET counter", database: 0) {
case .success(let output):
    check("控制台执行 GET", output == "42", output)
case .failure(let message):
    check("控制台执行成功", false, message)
}

switch redisService.execute("NOSUCHCMD", database: 0) {
case .success:
    check("未知命令应返回错误", false)
case .failure(let message):
    check("未知命令错误透传", message.contains("unknown command"), message)
}

switch redisService.overview(database: 0) {
case .success(let overview):
    check("概览版本号", overview.version == "7.2.0", overview.version)
    check("概览命中率计算", overview.hitRate == "83.3%", overview.hitRate)
    check("概览 keyspace", overview.keyspace.first?.0 == "db0", String(describing: overview.keyspace))
    check("概览 key 总数", overview.keys == 5, String(overview.keys))
case .failure(let message):
    check("概览读取成功", false, message)
}

switch redisService.execute("SET greeting \"hello world\"", database: 0) {
case .success(let output):
    check("带引号的写命令可执行", output == "OK", output)
    switch redisService.execute("GET greeting", database: 0) {
    case .success(let value):
        check("写入的值可读回", value == "hello world", value)
    case .failure(let message):
        check("写入的值可读回", false, message)
    }
case .failure(let message):
    check("带引号的写命令可执行", false, message)
}

// MARK: MongoService —— 未安装 mongod 时的降级行为

print("== MongoService（本机未安装 mongod 时的表现）==")
var mongoSettings = MongoSettings()
// 故意指向一个不存在的二进制：只验证“缺少依赖时的降级行为”，避免自测真的去启动本机数据库
mongoSettings.bin = workRoot + "/no-such-mongod"
mongoSettings.config = workRoot + "/mongod.conf"
mongoSettings.dbpath = workRoot + "/mongo-db"
mongoSettings.logpath = workRoot + "/mongod.log"
mongoSettings.port = 27099

let mongoService = MongoService(settings: mongoSettings)
let mongoStatus = mongoService.status(probePing: false)
check("未安装时不报错", !mongoStatus.installed)
check("未运行时 running=false", !mongoStatus.running)
check("自动生成配置文件", FileTools.exists(workRoot + "/mongod.conf"))
check("生成的配置端口正确", ConfStore.mongoGet(mongoService.rawConfigText(), path: ["net", "port"]) == "27099")

let startResult = mongoService.start()
check("缺少 mongod 时给出可读提示", !startResult.ok && startResult.message.contains("mongod"), startResult.message)
let stopResult = mongoService.stop()
check("未运行时停止给出可读提示", !stopResult.ok, stopResult.message)

print("== 生成的 mongosh 脚本（防回归：不依赖会返回游标的 shell 辅助方法）==")
let usersJS = MongoService.usersScript(database: "admin")
check("查用户用 usersInfo 命令", usersJS.contains("usersInfo"))
check("不再调用 getUsers()", !usersJS.contains("getUsers()"))
let passwordJS = MongoService.passwordScript(database: "app", user: "o'brien", password: "p\"w", roles: ["readWrite"])
check("建用户/改密码用 createUser 命令", passwordJS.contains("createUser: userName"))
check("改密码用 updateUser 命令", passwordJS.contains("updateUser: userName"))
check("不再调用 getUsers()", !passwordJS.contains("getUsers()"))
check("用户名里的单引号被安全转义", passwordJS.contains("\"o'brien\"") || passwordJS.contains("\\u0027"))
check("密码里的双引号被转义", !passwordJS.contains("\"p\"w\""))
let dropJS = MongoService.dropDatabaseScript("app")
check("删库用 dropDatabase 命令", dropJS.contains("dropDatabase: 1"))
let adminJS = MongoService.createAdminUserScript(user: "admin", password: "p\"w", roles: ["root"])
check("建管理员用 createUser 命令", adminJS.contains("createUser: \"admin\""))
check("管理员角色带 db: admin", adminJS.contains("db: \"admin\""))
check("管理员脚本不含 getUsers()", !adminJS.contains("getUsers()"))
let changePWJS = MongoService.changePasswordScript(database: "admin", user: "admin", newPassword: "N3w!pass")
check("改密码用 updateUser 命令", changePWJS.contains("updateUser: \"admin\""))
check("改密码脚本带上了新密码", changePWJS.contains("N3w!pass"))
check("改密码脚本不含 getUsers()", !changePWJS.contains("getUsers()"))
let allUsersJS = MongoService.allUsersScript()
check("一次查所有库的用户用 usersInfo forAllDBs", allUsersJS.contains("forAllDBs: true"))
check("用户清单脚本不含 getUsers()", !allUsersJS.contains("getUsers()"))

// MARK: 配置写入 / 备份

print("== 配置写入与备份 ==")
let confPath = workRoot + "/mongod.conf"
let backupPath = confPath + ".bak"
let saveResult = mongoService.setParam("net.port", value: "27100")
check("保存配置项成功", saveResult.ok, saveResult.message)
check("生成 .bak 备份", FileTools.exists(backupPath))
check("新配置已落盘", ConfStore.mongoGet(FileTools.read(confPath), path: ["net", "port"]) == "27100")
let noChange = mongoService.setParam("net.port", value: "27100")
check("相同值保存时提示无变化", !noChange.ok && noChange.message.contains("没有变化"), noChange.message)

// MARK: 配置项类型（布尔 / 枚举改下拉）

print("== 配置项类型 ==")
let choiceKeys = ConfStore.mongoKeys.filter { $0.isChoice }
check("Mongo 至少 3 项是选择型", choiceKeys.count >= 3, "实际 \(choiceKeys.count)")
check("鉴权项是选择型", ConfStore.mongoKeys.first { $0.id == "security.authorization" }?.isChoice == true)
check("鉴权选项为 disabled / enabled",
      ConfStore.mongoKeys.first { $0.id == "security.authorization" }?.options.map(\.value) == ["disabled", "enabled"])
check("fork 是选择型", ConfStore.mongoKeys.first { $0.id == "processManagement.fork" }?.isChoice == true)
check("慢查询剖析是选择型（3 个选项）",
      ConfStore.mongoKeys.first { $0.id == "operationProfiling.mode" }?.options.count == 3)
check("端口等仍是文本型", ConfStore.mongoKeys.first { $0.id == "net.port" }?.isChoice == false)
let redisChoices = ConfStore.redisKeys.filter { $0.isChoice }
check("Redis 至少 4 项是选择型", redisChoices.count >= 4, "实际 \(redisChoices.count)")
check("淘汰策略有 8 个选项",
      ConfStore.redisKeys.first { $0.id == "maxmemory-policy" }?.options.count == 8)

print("== 进程归属校验（防误杀）==")
check("pid=0 不算目标进程", !ProcUtil.isProcess(0, named: "mongod"))
check("不存在的 pid 不算目标进程", !ProcUtil.isProcess(999_999, named: "mongod"))
check("当前进程不是 mongod", !ProcUtil.isProcess(Int32(ProcessInfo.processInfo.processIdentifier), named: "mongod"))
check("未监听的端口没有占用者", ProcUtil.describePortOwner(port: 27099).isEmpty)
check("未监听的端口查不到服务 pid", ProcUtil.servicePid(port: 27099, named: "mongod") == 0)

print("== MySQL：my.cnf（INI）读写 ==")
let mycnf = """
# 注释
[mysqld]
port = 3306
datadir = /opt/homebrew/var/mysql   # 数据目录

[client]
port = 3306
"""
check("读取 [mysqld] 下的值", ConfStore.iniGet(mycnf, section: "mysqld", key: "port") == "3306")
check("读取时忽略行尾注释",
      ConfStore.iniGet(mycnf, section: "mysqld", key: "datadir") == "/opt/homebrew/var/mysql",
      ConfStore.iniGet(mycnf, section: "mysqld", key: "datadir"))
let mycnfEdited = ConfStore.iniSet(mycnf, section: "mysqld", key: "port", value: "3307")
check("修改后新值生效", ConfStore.iniGet(mycnfEdited, section: "mysqld", key: "port") == "3307")
check("[client] 段同名 key 不被改坏",
      ConfStore.iniGet(mycnfEdited, section: "client", key: "port") == "3306")
check("文件头注释保留", mycnfEdited.contains("# 注释"))
let mycnfAdded = ConfStore.iniSet(mycnf, section: "mysqld", key: "max_connections", value: "200")
check("新增 key 写进对应 section",
      ConfStore.iniGet(mycnfAdded, section: "mysqld", key: "max_connections") == "200")
check("新增不会串到别的 section",
      ConfStore.iniGet(mycnfAdded, section: "client", key: "max_connections").isEmpty)
let mycnfNewSection = ConfStore.iniSet(mycnf, section: "mysqldump", key: "quick", value: "ON")
check("section 不存在时新建",
      ConfStore.iniGet(mycnfNewSection, section: "mysqldump", key: "quick") == "ON")
check("MySQL 选择型配置项齐全", ConfStore.mysqlKeys.filter { $0.isChoice }.count >= 4,
      "实际 \(ConfStore.mysqlKeys.filter { $0.isChoice }.count)")
check("MySQL 配置项都是 section.key 形式", ConfStore.mysqlKeys.allSatisfy { $0.id.contains(".") })

print("== MySQL：SQL 生成安全性 ==")
check("SQL 字符串转义单引号", MySQLService.sqlQuote("o'brien") == "'o''brien'",
      MySQLService.sqlQuote("o'brien"))
check("SQL 字符串转义反斜杠", MySQLService.sqlQuote("a\\b") == "'a\\\\b'",
      MySQLService.sqlQuote("a\\b"))
check("库名：正常名通过", MySQLService.isValidName("myapp_2") && MySQLService.isValidName("$db"))
check("库名：拒绝空格/横线/中文",
      !MySQLService.isValidName("a b") && !MySQLService.isValidName("a-b") && !MySQLService.isValidName("我的库"))
check("库名：拒绝数字开头", !MySQLService.isValidName("2db"))
check("库名：拒绝空名", !MySQLService.isValidName(""))
check("权限级别 → 只读", MySQLService.privileges(for: "read", database: "x") == ["SELECT"])
check("权限级别 → 读写",
      MySQLService.privileges(for: "readwrite", database: "x") == ["SELECT", "INSERT", "UPDATE", "DELETE"])
check("权限级别 → 全部", MySQLService.privileges(for: "all", database: "x") == ["ALL PRIVILEGES"])

print("== 证书：acme.sh 输出解析 ==")
let manualOutput = """
Add the following TXT record:
Domain: '_acme-challenge.example.com'
TXT value: 'abc123xyz'

Please deploy a DNS TXT record under the name
_acme-challenge.api.example.com with the following value:

Add the following TXT record:
Domain: '_acme-challenge.api.example.com'
TXT value: 'def456uvw'
"""
let manualChallenges = ACMEService.parseManualChallenges(manualOutput)
check("解析出手动 TXT 记录", manualChallenges.count == 2, "实际 \(manualChallenges.count)")
check("记录名正确", manualChallenges.first?.recordName == "_acme-challenge.example.com",
      manualChallenges.first?.recordName ?? "nil")
check("记录值去掉了引号", manualChallenges.first?.recordValue == "abc123xyz",
      manualChallenges.first?.recordValue ?? "nil")
check("第二条记录也对", manualChallenges.last?.recordValue == "def456uvw")

let listOutput = """
Main_Domain	KeyLength	SAN_Domains	CA	Created	Renew
example.com	ec-256	no	LetsEncrypt.org	2026-09-23T10:00:00Z	2026-12-22T10:00:00Z
api.example.com	2048	*.api.example.com	LetsEncrypt.org	2026-09-20T10:00:00Z	2026-12-19T10:00:00Z
"""
let parsedCerts = ACMEService.parseList(listOutput, home: "/Users/x/.acme.sh")
check("证书列表跳过表头", parsedCerts.count == 2, "实际 \(parsedCerts.count)")
check("域名与密钥算法解析正确",
      parsedCerts.first?.domain == "example.com" && parsedCerts.first?.keyLength == "ec-256")
check("下次续期时间解析", parsedCerts.first?.renewAt.hasPrefix("2026-12-22") == true,
      parsedCerts.first?.renewAt ?? "")
check("附加域名解析", parsedCerts.last?.sanDomains == "*.api.example.com")
check("证书路径拼接正确",
      parsedCerts.first?.fullchainPath == "/Users/x/.acme.sh/example.com_ecc/fullchain.cer",
      parsedCerts.first?.fullchainPath ?? "")
check("空输出不崩", ACMEService.parseList("", home: "/tmp").isEmpty)

print("== 证书：iCloud 备份路径 ==")
check("iCloud 证书目录拼接",
      ACMEService.iCloudCertDirectory(
        base: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs",
        subdir: "DBManager/certs", domain: "example.com")
      == "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/DBManager/certs/example.com",
      ACMEService.iCloudCertDirectory(base: "/b", subdir: "DBManager/certs", domain: "example.com"))
check("子目录留空时回退到默认值",
      ACMEService.iCloudCertDirectory(base: "/base", subdir: "   ", domain: "a.com")
      == "/base/DBManager/certs/a.com")
check("域名两侧空格被去掉",
      ACMEService.iCloudCertDirectory(base: "/base", subdir: "d", domain: " a.com ")
      == "/base/d/a.com")

print("== 宝塔面板：签名算法与响应解析 ==")
check("MD5 实现正确（已知向量）",
      BTPanelService.md5("hello") == "5d41402abc4b2a76b9719d911017c592",
      BTPanelService.md5("hello"))
check("MD5 空串", BTPanelService.md5("") == "d41d8cd98f00b204e9800998ecf8427e")
let btToken = BTPanelService.requestToken(apiKey: "test-key", requestTime: "1700000000")
check("签名 = md5(request_time + md5(api_sk))",
      btToken == BTPanelService.md5("1700000000" + BTPanelService.md5("test-key")), btToken)
check("签名是 32 位小写十六进制",
      btToken.count == 32 && btToken == btToken.lowercased(), btToken)
check("备选签名与标准签名不同",
      btToken != BTPanelService.requestTokenVariant(apiKey: "test-key", requestTime: "1700000000"))
check("成功响应：status=true", BTPanelService.isSuccess(["status": true]))
check("成功响应：status=1（Int）", BTPanelService.isSuccess(["status": 1]))
check("失败响应：status=false", !BTPanelService.isSuccess(["status": false]))
check("失败响应：有 error 字段", !BTPanelService.isSuccess(["error": "签名错误"]))
check("成功响应：有 data", BTPanelService.isSuccess(["data": []]))
check("提示文案优先取 msg",
      BTPanelService.describe(["msg": "指定网站不存在", "status": false]) == "指定网站不存在",
      BTPanelService.describe(["msg": "指定网站不存在", "status": false]))
check("纯文本 true 视为成功", BTPanelService.interpret("true").ok)
check("纯文本错误视为失败", !BTPanelService.interpret("签名错误").ok)
check("空响应给出可读提示",
      BTPanelService.interpret("").message.contains("没有返回内容"),
      BTPanelService.interpret("").message)

let btJSON = #"{"status":true,"data":[{"id":"1","name":"a.com","path":"/www/wwwroot/a.com","domain":"a.com www.a.com","status":"1"},{"id":"2","name":"b.com","path":"/www/wwwroot/b.com","domain":"b.com","status":"0"}]}"#
let btParsed = BTPanelService.interpret(btJSON)
check("网站列表 JSON 解析成功", btParsed.ok && btParsed.dataRows.count == 2,
      "rows=\(btParsed.dataRows.count)")
let btSites = BTPanelService.parseSites(btParsed)
check("网站解析出 2 条", btSites.count == 2, "实际 \(btSites.count)")
check("网站名与主域名正确",
      btSites.first?.name == "a.com" && btSites.first?.primaryDomain == "a.com",
      btSites.first?.primaryDomain ?? "nil")
check("多个域名时取第一个", btSites.first?.domains == "a.com www.a.com")
check("运行状态识别", btSites.first?.running == true && btSites.last?.running == false)
check("状态文案", btSites.last?.statusLabel == "已停止", btSites.last?.statusLabel ?? "")
check("数据库列表解析", BTPanelService.parseDatabases(
        BTPanelService.interpret(#"{"status":true,"data":[{"id":"1","name":"db1","type":"MySQL","size":"2 MB"}]}"#),
        type: BTDatabaseType.find("mysql")
      ).first?.name == "db1")

print("== 宝塔面板：IP 白名单提示 ==")
let ipBlockedRaw = #"{"status": false, "msg": "IP校验失败,您的访问IP为[203.0.113.45]"}"#
let ipBlockedResult = BTPanelService.interpret(ipBlockedRaw)
check("IP 校验失败被判为失败", !ipBlockedResult.ok)
check("提取出被拦截的出口 IP",
      BTPanelService.blockedIP(from: ipBlockedRaw) == "203.0.113.45",
      BTPanelService.blockedIP(from: ipBlockedRaw) ?? "nil")
check("识别出这是 IP 白名单问题", BTPanelService.isIPBlocked(ipBlockedRaw))
check("提示里带了处理办法", ipBlockedResult.message.contains("IP 白名单"), ipBlockedResult.message)
check("提示里带了那个 IP", ipBlockedResult.message.contains("203.0.113.45"))
check("签名错误不会被误判成 IP 问题",
      !BTPanelService.isIPBlocked(#"{"status":false,"msg":"签名错误"}"#))
check("没有 IP 时解析返回 nil", BTPanelService.blockedIP(from: "{}") == nil)
check("带空格的写法也能解析",
      BTPanelService.blockedIP(from: #"{"msg":"IP校验失败,您的访问 IP 为[1.2.3.4]"}"#) == "1.2.3.4",
      BTPanelService.blockedIP(from: #"{"msg":"IP校验失败,您的访问 IP 为[1.2.3.4]"}"#) ?? "nil")

print("== 宝塔面板：真实响应回归 ==")
// 真实面板 /system?action=GetSystemTotal 的返回：既没有 status 也没有 data
let realSystemTotal = #"{"memTotal": 1870, "memFree": 854, "memBuffers": 15, "memCached": 287, "memAvailable": 1007, "memShared": 1, "memRealUsed": 714, "memNewTotalList": ["1.8", "GB"], "memNewRealUsedList": ["714.0", "MB"], "memNewRealUsed": "714.0MB", "memNewTotal": "1.8GB", "cpuNum": 2, "cpuRealUsed": 2.0, "time": "21天", "system": "Alibaba Cloud  3 (OpenAnolis Edition) x86_64(Py3.13.14)", "isuser": 0, "isport": true, "version": "13.1.0"}"#
let realResult = BTPanelService.interpret(realSystemTotal)
check("无 status/data 的数据响应应判为成功（真实响应回归）", realResult.ok, realResult.message)
check("能读出面板版本", (realResult.json?["version"] as? String) == "13.1.0")
check("能读出 CPU 核心数", (realResult.json?["cpuNum"] as? Int) == 2)
check("能读出可读内存串", (realResult.json?["memNewRealUsed"] as? String) == "714.0MB")
check("只有 msg 的响应仍判为失败",
      !BTPanelService.interpret(#"{"msg":"指定网站不存在"}"#).ok)
check("status=false 优先于其它字段",
      !BTPanelService.interpret(#"{"status":false,"version":"1.0"}"#).ok)
check("空对象判为失败", !BTPanelService.interpret("{}").ok)

print("== 宝塔面板：网站类型 / SSL 状态 ==")
let sitesJSON = #"{"status":true,"data":[{"id":"1","name":"a.com","path":"/www/wwwroot/a","domain":"a.com","status":"1","project_type":"PHP"},{"id":"2","name":"b.com","path":"/www/wwwroot/b","domain":"b.com","status":"0","project_type":"Python","ssl":"1"},{"id":"3","name":"c.com","path":"/www/wwwroot/c","domain":"c.com","status":"1","project_type":"Proxy","ssl":"0"},{"id":"4","name":"d.com","path":"/www/wwwroot/d","domain":"d.com","status":"1","type_id":"1"},{"id":"5","name":"e.com","path":"/www/wwwroot/e","domain":"e.com","status":"1"}]}"#
let parsedSites = BTPanelService.parseSites(BTPanelService.interpret(sitesJSON))
check("解析出 5 个网站", parsedSites.count == 5, "实际 \(parsedSites.count)")
check("PHP 类型识别", parsedSites[0].typeLabel == "PHP", parsedSites[0].typeLabel)
check("Python 类型识别", parsedSites[1].typeLabel == "Python", parsedSites[1].typeLabel)
check("反向代理识别", parsedSites[2].typeLabel == "反向代理", parsedSites[2].typeLabel)
check("老版本 type_id 回退为静态 HTML", parsedSites[3].typeLabel == "静态 HTML", parsedSites[3].typeLabel)
check("没有类型字段时显示 —", parsedSites[4].typeLabel == "—", parsedSites[4].typeLabel)
check("SSL 开启识别", parsedSites[1].sslState == "已开启", parsedSites[1].sslState)
check("SSL 未开启识别", parsedSites[2].sslState == "未开启", parsedSites[2].sslState)
check("SSL 字段缺失显示未知", parsedSites[0].sslState == "未知", parsedSites[0].sslState)
check("列表文案：已部署", parsedSites[1].sslLabel == "已部署", parsedSites[1].sslLabel)
check("列表文案：未部署", parsedSites[2].sslLabel == "未部署", parsedSites[2].sslLabel)
check("读不到时列表显示 —", parsedSites[0].sslLabel == "—", parsedSites[0].sslLabel)
check("其它字段不受影响", parsedSites[2].running && parsedSites[2].name == "c.com")
check("ssl_enabled 这类别名也能识别",
      BTPanelService.sslValue(in: ["ssl_enabled": "true"]) == "true")

print("== 宝塔面板：13.x 真实字段（ssl / project_type）==")
let realFieldsJSON = BTPanelService.interpret("""
{"data": [
  {"id": "1", "name": "no-ssl", "ssl": "-1", "project_type": "html", "status": "1"},
  {"id": "2", "name": "has-ssl", "project_type": "Python", "status": "1",
   "ssl": "{'issuer': 'YE1', 'issuer_O': \\"Let's Encrypt\\", 'notAfter': '2026-11-30', 'endtime': 67}"},
  {"id": "3", "name": "no-field", "project_type": "proxy", "status": "1"}
]}
""")
let realSites = BTPanelService.parseSites(realFieldsJSON)
check("网站数解析正确", realSites.count == 3, "\(realSites.count)")
check("ssl=-1 → 未部署", realSites[0].sslLabel == "未部署", realSites[0].sslLabel)
check("ssl 是证书字典 → 已部署", realSites[1].sslLabel == "已部署", realSites[1].sslLabel)
check("从 ssl 字段取出到期日", realSites[1].sslNotAfter == "2026-11-30", realSites[1].sslNotAfter)
check("ssl 字段缺失 → —", realSites[2].sslLabel == "—", realSites[2].sslLabel)
check("project_type=html → 静态 HTML", realSites[0].typeLabel == "静态 HTML", realSites[0].typeLabel)
check("project_type=Python → 项目类", realSites[1].isProjectSite)
// 实测：Python 项目有专用接口 /project/python/StopProject，能真正停掉 uwsgi 进程
// （F12 抓包 + API 验证：uwsgi 进程数 12 → 6）。
check("Python 项目被单独认出来（走专用启停接口）", realSites[1].isPythonProject)
check("PHP / 静态站不算 Python 项目", !realSites[0].isPythonProject)
check("proxy 站不算 Python 项目", !realSites[2].isPythonProject)
check("Python 的进程名候选含 uwsgi", realSites[1].processNameHints.contains("uwsgi"),
      realSites[1].processNameHints.joined(separator: ","))
check("PHP 站没有应用进程候选", realSites[0].processNameHints.isEmpty)
check("proxy 站没有应用进程候选", realSites[2].processNameHints.isEmpty)
check("Python 的启停说明点明会连进程一起停",
      realSites[1].restartNote.contains("uwsgi 应用进程一起停掉"), realSites[1].restartNote)
check("非 Python 的项目类站点不夸大（说明进程可能要另外停）",
      !realSites[1].restartNote.contains("需要到宝塔面板"))

print("== 宝塔面板：用项目真实状态校正网站列表 ==")
// 实测：面板的 Python 项目启停只调 /project/python/...，不改 sites 表，
// 所以 sites.status 会错位；项目接口的 status 才是真的。
let corrected = BTPanelService.applyProjectStatus(
    realSites,
    projects: [
        ["name": "has-ssl", "status": 0],      // 对应 realSites[1]（Python，sites 表里是 1）
        ["name": "no-field", "status": 1],     // proxy 站，不该被项目状态覆盖
    ])
check("Python 项目的状态被项目接口校正（1 → 0）",
      !corrected[1].running, corrected[1].statusLabel)
check("校正后显示为已停止", corrected[1].statusLabel == "已停止", corrected[1].statusLabel)
check("非 Python 站点不受项目状态影响",
      corrected[2].running == realSites[2].running, corrected[2].statusLabel)
check("项目里没有的站点保持原值", corrected[0].running == realSites[0].running)
check("项目列表为空时原样返回",
      BTPanelService.applyProjectStatus(realSites, projects: []).count == realSites.count)

print("== 宝塔面板：多类型数据库（实测每种类型各有接口）==")
let wantKeys: Set<String> = ["mysql", "mongodb", "redis", "pgsql", "sqlserver", "sqlite"]
check("类型列表覆盖用户要的几种",
      wantKeys.isSubset(of: Set(BTDatabaseType.all.map { $0.key })),
      BTDatabaseType.all.map { $0.key }.joined(separator: ","))
check("MySQL 不是裸数组（它走 /data）", !BTDatabaseType.find("mysql").arrayStyle)
check("Redis 是裸数组结构", BTDatabaseType.find("redis").arrayStyle)
check("SQLite 是裸数组结构", BTDatabaseType.find("sqlite").arrayStyle)
check("MongoDB / PostgreSQL 是 {data:[…]} 结构",
      !BTDatabaseType.find("mongodb").arrayStyle && !BTDatabaseType.find("pgsql").arrayStyle)
check("未知类型回落到 MongoDB", BTDatabaseType.find("nope").key == "mongodb")
// Redis 返回裸数组，字段只有 id/name/keynum
let redisJSON = BTPanelService.interpret(
    #"[{"id":0,"name":"DB0","keynum":3},{"id":1,"name":"DB1","keynum":0}]"#)
let redisDBs = BTPanelService.parseDatabases(redisJSON, type: BTDatabaseType.find("redis"))
check("Redis 裸数组解析出 2 个 DB", redisDBs.count == 2, "\(redisDBs.count)")
check("Redis 库名 / 键数解析", redisDBs[0].name == "DB0" && redisDBs[0].keynum == 3)
check("Redis 条目标注了类型", redisDBs[0].type == "Redis", redisDBs[0].type)
check("Redis 没有密码字段时留空", redisDBs[0].password.isEmpty)
check("PostgreSQL 的空 data 不崩",
      BTPanelService.parseDatabases(BTPanelService.interpret(#"{"data":[]}"#),
                                    type: BTDatabaseType.find("pgsql")).isEmpty)
check("SQLite 空数组不崩",
      BTPanelService.parseDatabases(BTPanelService.interpret("[]"),
                                    type: BTDatabaseType.find("sqlite")).isEmpty)

print("== 宝塔面板：MongoDB 数据库列表解析 ==")
// 用假密码（真实值不写进仓库）
let dbJSON = BTPanelService.interpret("""
{"where":"lower(type) = lower('mongodb')","data":[
  {"id":2,"name":"ai_tool_db","username":"ai_tool_db","password":"pwd-1",
   "accept":"127.0.0.1","type":"MongoDB","addtime":"2026-09-02 05:53:20"},
  {"id":1,"name":"demo_db","username":"demo_db","password":"pwd-2",
   "accept":"127.0.0.1","type":"MongoDB","addtime":"2026-09-02 00:22:26"}
]}
""")
let dbs = BTPanelService.parseDatabases(dbJSON, type: BTDatabaseType.find("mongodb"))
check("解析出 2 个数据库", dbs.count == 2, "\(dbs.count)")
check("库名正确", dbs[0].name == "ai_tool_db", dbs[0].name)
check("用户名解析", dbs[1].username == "demo_db", dbs[1].username)
check("类型按所选类型标注", dbs[0].type == "MongoDB", dbs[0].type)
check("访问来源解析", dbs[0].accept == "127.0.0.1", dbs[0].accept)
check("添加时间解析", dbs[1].addtime == "2026-09-02 00:22:26", dbs[1].addtime)
check("密码字段读到了（展示时走 SecretCell 打码）", dbs[0].password == "pwd-1")
check("空 data 不崩",
      BTPanelService.parseDatabases(BTPanelService.interpret(#"{"data":[]}"#),
                                    type: BTDatabaseType.find("mongodb")).isEmpty)
check("无 data 字段也不崩",
      BTPanelService.parseDatabases(BTPanelService.interpret(#"{"status":true}"#),
                                    type: BTDatabaseType.find("mongodb")).isEmpty)

print("== 宝塔面板：敏感字段脱敏（MongoDB 接口会明文返回密码）==")
let leaky = #"{"data":[{"name":"demo_db","username":"demo_db","password":"sample-pwd-xyz"}]}"#
let cleaned = BTPanelService.redactSensitive(leaky)
check("password 被脱敏", !cleaned.contains("sample-pwd-xyz"), cleaned)
check("库名/用户名不受影响（不是敏感字段）", cleaned.contains("demo_db"))
check("证书类字段仍然脱敏",
      !BTPanelService.redactSensitive(#"{"private_key":"abc123","cert":"def456"}"#).contains("abc123"))
check("api_sk / secret 也脱敏",
      !BTPanelService.redactSensitive(#"{"api_sk":"sk-value","secret":"sec-value"}"#).contains("sk-value"))
check("连接串里的密码也遮掉",
      !BTPanelService.redactSensitive("mongodb://user:secret@127.0.0.1:27017").contains("secret"))

print("== 宝塔面板：磁盘 / 资源占用（用于画占用条）==")
// 实测结构：GetDiskInfo 的 size = [总量, 已用, 可用, 使用率, 保留]
let diskSample = BTDiskUsage(path: "/", filesystem: "/dev/vda3",
                             totalText: "39.0 GB", usedText: "11.5 GB",
                             availText: "25.7 GB", percentText: "30.99%")
check("磁盘使用率解析（30.99% → 0.3099）",
      abs(diskSample.fraction - 0.3099) < 0.0001, "\(diskSample.fraction)")
check("缺百分比字段时归零不崩",
      BTDiskUsage(path: "/", filesystem: "x", totalText: "1", usedText: "1",
                  availText: "0", percentText: "").fraction == 0)
check("使用率被夹在 0…1 之间",
      BTDiskUsage(path: "/", filesystem: "x", totalText: "1", usedText: "1",
                  availText: "0", percentText: "150%").fraction == 1)
check("资源占用结构可用",
      BTResourceUsage(label: "内存", detail: "550MB / 1.87GB", fraction: 0.294).fraction == 0.294)
check("数字解析：Int", BTPanelService.doubleValue(550) == 550)
check("数字解析：Double", BTPanelService.doubleValue(1.5) == 1.5)
check("数字解析：String", BTPanelService.doubleValue("30.99") == 30.99)
check("数字解析：nil", BTPanelService.doubleValue(nil) == nil)
check("project_type=proxy → 反向代理", realSites[2].typeLabel == "反向代理", realSites[2].typeLabel)
check("proxy 站不算项目类", !realSites[2].isProjectSite)

print("== 宝塔面板：服务状态解析（13.x 真实结构 list.data[]）==")
let softJSON = BTPanelService.interpret("""
{"list": {"page": "<div>共288条</div>", "data": [
  {"name": "nginx", "title": "Nginx", "status": true, "version": "1.28.3"},
  {"name": "redis", "title": "Redis", "status": false, "version": "8.0.5"},
  {"name": "btwaf", "title": "Nginx防火墙", "status": false, "version": ""}
]}}
""")
let nginxStatus = BTPanelService.parseService(name: "nginx", from: softJSON)
check("服务名精确匹配", nginxStatus.name == "nginx")
check("商店里的版本能读到", nginxStatus.version == "1.28.3", nginxStatus.version)
let wafStatus = BTPanelService.parseService(name: "btwaf", from: softJSON)
check("商店没登记版本 → 未安装", wafStatus.statusLabel == "未安装", wafStatus.statusLabel)
// 关键回归：查不到的名字绝不能拿列表第一项顶上
let missing = BTPanelService.parseService(name: "php-fpm-74", from: softJSON)
check("查不到的服务不会拿别人的状态顶上",
      missing.name == "php-fpm-74" && !missing.installed, "\(missing.name)/\(missing.statusLabel)")
check("非 JSON 响应不崩",
      BTPanelService.parseService(name: "x", from: BTAPIResult.failure("boom")).installed == false)
check("空 list 也不崩",
      BTPanelService.parseService(name: "x", from: BTPanelService.interpret(#"{"list":{}}"#)).installed == false)

print("== 宝塔面板：运行状态以进程表为准（实测 redis 被商店误判成未运行）==")
func svc(_ n: String, _ v: String, _ running: Bool?, _ procs: Int) -> BTServiceStatus {
    BTServiceStatus(name: n, title: n, version: v, running: running, processCount: procs)
}
check("有进程 → 运行中", svc("redis", "8.0.5", false, 1).statusLabel == "运行中",
      svc("redis", "8.0.5", false, 1).statusLabel)
check("进程数压过商店的 status 字段（redis 实测场景）",
      svc("redis", "8.0.5", false, 2).statusLabel == "运行中")
check("无进程但商店有版本 → 已停止", svc("x", "1.0", false, 0).statusLabel == "已停止")
check("无进程无版本 → 未安装", svc("y", "", nil, 0).statusLabel == "未安装")
check("进程数展示", svc("nginx", "1.28.3", true, 4).detailLabel == "4 个进程",
      svc("nginx", "1.28.3", true, 4).detailLabel)
check("无进程时展示商店登记信息", svc("x", "1.0", false, 0).detailLabel == "商店已登记")
check("PHP 站不算项目类", !parsedSites[0].isProjectSite)
check("Python 站算项目类", parsedSites[1].isProjectSite)
check("反向代理站不算项目类", !parsedSites[2].isProjectSite)
check("项目类的启停说明点出应用进程",
      parsedSites[1].restartNote.contains("应用进程"), parsedSites[1].restartNote)
check("反向代理的说明说明后端不受影响",
      parsedSites[2].restartNote.contains("后端服务本身不受影响"), parsedSites[2].restartNote)
check("PHP 的说明点出 nginx 配置",
      parsedSites[0].restartNote.contains("nginx 配置"), parsedSites[0].restartNote)

print("== 宝塔面板：服务状态 ==")
check("布尔兼容：字符串 \"1\"", BTPanelService.parseBool("1") == true)
check("布尔兼容：\"stopped\"", BTPanelService.parseBool("stopped") == false)
check("布尔兼容：int 0", BTPanelService.parseBool(0) == false)
check("布尔兼容：nil", BTPanelService.parseBool(nil) == nil)

print("== 宝塔面板：敏感字段脱敏 ==")
let sslRaw = #"{"status":true,"key":"-----BEGIN PRIVATE KEY-----\nSECRET","csr":"-----BEGIN CERTIFICATE-----\nCERT","siteName":"a.com"}"#
let redacted = BTPanelService.redactSensitive(sslRaw)
check("私钥内容被抹掉", !redacted.contains("SECRET"), redacted)
check("证书内容被抹掉", !redacted.contains("BEGIN CERTIFICATE"))
check("非敏感字段保留", redacted.contains("a.com"))
check("空串不崩", BTPanelService.redactSensitive("") == "")

print("== 宝塔面板：接口不存在（404）的处理 ==")
let notFoundHTML = "<html><head><title>404 Not Found</title></head><body><center><h1>404 Not Found</h1></center><hr><center>nginx</center></body></html>"
check("识别 nginx 的 404 页面", BTPanelService.looksLikeNotFound(notFoundHTML))
check("404 响应判为失败", !BTPanelService.interpret(notFoundHTML).ok)
check("404 被解析成可读提示",
      BTPanelService.interpret(notFoundHTML).message.contains("不存在"),
      BTPanelService.interpret(notFoundHTML).message)
check("「参数无效」被识别为参数问题（应继续试别的组合）",
      BTPanelService.looksLikeBadParams(#"{"status": false, "msg": "指定参数无效!"}"#))
check("参数错误的中文别名也能识别",
      BTPanelService.looksLikeBadParams(#"{"status":false,"msg":"参数有误"}"#))
check("正常响应不算参数问题", !BTPanelService.looksLikeBadParams(#"{"status":true}"#))
check("404 不算参数问题",
      !BTPanelService.looksLikeBadParams("<html>404 Not Found nginx</html>"))
check("普通 HTML 不误判", !BTPanelService.looksLikeNotFound("<html><body>hello</body></html>"))
check("正常 JSON 不受影响", BTPanelService.interpret(#"{"status":true}"#).ok)
check("真实面板版本号这类响应仍算成功",
      BTPanelService.interpret(#"{"version":"13.1.0"}"#).ok)

print("== Redis 客户端：SHUTDOWN 这类会断连的命令 ==")
// 之前"停止失败"的根因：客户端只把「关闭了连接」这一种错误当成功，
// 换成连接重置/EOF/超时就被判成失败。现在任何连接层异常都不再抛出，
// 由调用方用端口状态判定是否真的停了。
let freshRedis = RedisClient(host: "127.0.0.1", port: 6399, password: "")
check("未连接时断连类命令不抛错（返回 false 表示未能确认）",
      (try? freshRedis.commandAllowingDisconnect(["SHUTDOWN", "SAVE"])) == false)

print("== ProcUtil：进程名判定（macOS 的 ps -o comm= 返回完整路径）==")
// 回归：`ps -o comm=` 输出的是**完整路径**（/opt/homebrew/bin/redis-server），
// 早前写成 `== name` 精确比较永远为假，导致「确认是某服务才动手」的保护全部失效
// —— 表现就是停止 Redis 时 SIGTERM 兜底被静默跳过。
// 这里测纯函数：沙箱里 ps / pgrep 不可用，测不了真实进程。
check("完整路径能匹配到短名",
      ProcUtil.processNameMatches("/opt/homebrew/bin/redis-server", "redis-server"))
check("直接给短名也能匹配", ProcUtil.processNameMatches("redis-server", "redis-server"))
check("不同服务不能误匹配",
      !ProcUtil.processNameMatches("/usr/sbin/httpd", "redis-server"))
check("mongod 不会被误认成 redis-server",
      !ProcUtil.processNameMatches("/opt/homebrew/bin/mongod", "redis-server"))
check("空输出不匹配", !ProcUtil.processNameMatches("", "redis-server"))
check("有前后空白也能匹配",
      ProcUtil.processNameMatches("  /opt/homebrew/bin/redis-server\n", "redis-server"))

print("== 网络代理：设置与随机凭据 ==")
var vpnSettings = VPNSettings()
check("默认客户端名", vpnSettings.clientName == "seraphine", vpnSettings.clientName)
check("默认远端描述文件以 .mobileconfig 结尾",
      vpnSettings.remoteProfilePath.hasSuffix(".mobileconfig"), vpnSettings.remoteProfilePath)
check("默认备份到 iCloud", vpnSettings.icloudBackup)
check("默认 SSH 端口 22", vpnSettings.sshPort == 22)
// 随机串只含字母数字：安装脚本对特殊字符有忌讳，会破坏它生成的配置
let vpnSecret = VPNService.randomSecret(32)
check("随机串长度正确", vpnSecret.count == 32, "\(vpnSecret.count)")
check("随机串只含字母数字",
      vpnSecret.allSatisfy { $0.isLetter || $0.isNumber }, vpnSecret)
check("两次生成不相同", VPNService.randomSecret(32) != VPNService.randomSecret(32))
// 新增 vpn 段后：老设置文件（没有该段 / 只有部分字段）仍要能解码
let vpnSettingsJSON = Data(#"{"vpn":{"host":"1.2.3.4"}}"#.utf8)
check("只有部分字段的 vpn 段也能解码",
      (try? JSONDecoder().decode(AppSettings.self, from: vpnSettingsJSON))?.vpn.host == "1.2.3.4")
check("未给的字段回落到默认值",
      (try? JSONDecoder().decode(AppSettings.self, from: vpnSettingsJSON))?.vpn.sshPort == 22)
check("完全没有 vpn 段时用默认值",
      (try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)))?.vpn.clientName == "seraphine")

print("== 网络代理：日志脱敏（VPN 凭据绝不能落盘）==")
check("VPN_IPSEC_PSK 被遮掉",
      !Shell.redactSecrets("env VPN_IPSEC_PSK='abc123secret' bash x").contains("abc123secret"))
check("VPN_PASSWORD 被遮掉",
      !Shell.redactSecrets("env VPN_PASSWORD='pw123456' bash x").contains("pw123456"))
check("DBM_SSH_PASSWORD 被遮掉",
      !Shell.redactSecrets("DBM_SSH_PASSWORD=topsecret ssh x").contains("topsecret"))
check("连接串里的密码仍被遮掉",
      !Shell.redactSecrets("mongodb://user:secret@127.0.0.1:27017").contains("secret"))
check("JSON 里的 password 仍被遮掉",
      !Shell.redactSecrets(#"{"password":"hunter2"}"#).contains("hunter2"))
check("非敏感文本原样保留",
      Shell.redactSecrets("hello world") == "hello world", Shell.redactSecrets("hello world"))

print("== 设置文件的宽松解码 ==")
let partialSettings = Data("{\"mongo\":{\"adminUser\":\"u1\",\"adminPassword\":\"p1\"}}".utf8)
let decodedSettings = try? JSONDecoder().decode(AppSettings.self, from: partialSettings)
check("缺字段的设置文件也能解码", decodedSettings != nil)
check("读到了给的字段", decodedSettings?.mongo.adminUser == "u1", decodedSettings?.mongo.adminUser ?? "nil")
check("没给的字段用默认值", decodedSettings?.mongo.port == 27017 && decodedSettings?.redis.port == 6379)
check("连 mongo 段都没有时也能解码",
      (try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))) != nil)
check("新增的 bt 段缺字段也能解码",
      (try? JSONDecoder().decode(AppSettings.self,
                                 from: Data("{\"bt\":{\"baseURL\":\"http://x:8888\"}}".utf8)))?.bt.baseURL
      == "http://x:8888")

print("== 日志脱敏 ==")
check("连接串里的密码被替换成 ***",
      Shell.redactSecrets("mongosh mongodb://admin:secret123@127.0.0.1:27017/admin")
      == "mongosh mongodb://admin:***@127.0.0.1:27017/admin",
      Shell.redactSecrets("mongosh mongodb://admin:secret123@127.0.0.1:27017/admin"))
check("不含凭据的 URL 原样保留",
      Shell.redactSecrets("mongodb://127.0.0.1:27017/admin") == "mongodb://127.0.0.1:27017/admin")
check("URL 编码过的特殊字符密码也被脱敏",
      Shell.redactSecrets("mongodb://u:a%40b%2Fc@host:27017/db?authSource=db")
      == "mongodb://u:***@host:27017/db?authSource=db",
      Shell.redactSecrets("mongodb://u:a%40b%2Fc@host:27017/db?authSource=db"))

print("== 建库时的用户名同步 ==")
let syncEmpty = UsernameSync.follow(currentUsername: "", lastAutoUsername: "", databaseName: "  myapp ")
check("空用户名跟随库名（去掉首尾空格）", syncEmpty.username == "myapp", syncEmpty.username)
check("首次同步记录 lastAuto", syncEmpty.lastAuto == "myapp", syncEmpty.lastAuto)
let syncFollow = UsernameSync.follow(currentUsername: "myapp", lastAutoUsername: "myapp", databaseName: "myapp2")
check("没手动改过时继续跟随新库名", syncFollow.username == "myapp2", syncFollow.username)
let syncManual = UsernameSync.follow(currentUsername: "my_user", lastAutoUsername: "myapp", databaseName: "myapp2")
check("手动改过之后不再被覆盖", syncManual.username == "my_user", syncManual.username)
check("手动改过时 lastAuto 不动", syncManual.lastAuto == "myapp", syncManual.lastAuto)

print("== 密码生成 ==")
let pwd = PasswordGenerator.make()
check("默认长度 20", pwd.count == 20, pwd)
check("含字母", pwd.contains { $0.isLetter })
check("含数字", pwd.contains { $0.isNumber })
check("含符号", pwd.contains { !$0.isLetter && !$0.isNumber })
check("不含难认字符 l/I/O/0",
      !pwd.contains("l") && !pwd.contains("I") && !pwd.contains("O") && !pwd.contains("0"), pwd)
check("不含会破坏连接串/URL 的字符（@ : / # ? & = % 空格）",
      !pwd.contains("@") && !pwd.contains(":") && !pwd.contains("/") && !pwd.contains("#")
      && !pwd.contains("?") && !pwd.contains("&") && !pwd.contains("=") && !pwd.contains("%")
      && !pwd.contains(" "), pwd)
check("不含会引起转义麻烦的字符（双引号 反斜杠 单引号）",
      !pwd.contains("\"") && !pwd.contains("\\") && !pwd.contains("'"), pwd)
check("字符都在允许集合内",
      pwd.allSatisfy { "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!$^*._-~".contains($0) }, pwd)
// 单次可能碰巧通过，这里多生成几轮确认字符集真的收紧了
let allowedSet = Set("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!$^*._-~")
let generated = (0..<200).map { _ in PasswordGenerator.make() }
check("200 次生成都只用允许字符", generated.allSatisfy { $0.allSatisfy { allowedSet.contains($0) } },
      generated.first { !$0.allSatisfy { allowedSet.contains($0) } } ?? "")
check("200 次生成长度都是 20", generated.allSatisfy { $0.count == 20 })
check("两次生成不相同", PasswordGenerator.make() != PasswordGenerator.make())
check("指定过短长度时兜底为 8", PasswordGenerator.make(length: 4).count == 8)

// MARK: 用 mongosh 的桩执行真实生成的脚本（本机没装 mongosh 就跳过）

if let mongosh = Paths.which("mongosh") {
    print("== 用 mongosh 真实执行生成的脚本（桩代替 db）==")
    let stub = """
    const __calls = [];
    const __stub = {
      getSiblingDB: (name) => ({
        runCommand: (cmd) => {
          __calls.push({ db: name, cmd: cmd });
          if (Object.prototype.hasOwnProperty.call(cmd, 'usersInfo')) { return { users: [] }; }
          return { ok: 1 };
        }
      })
    };
    """
    func wrap(_ label: String, _ script: String) -> String {
        """
        print('--- \(label) ---');
        (function (db) {
        \(script)
        })(__stub);

        """
    }
    var js = stub + "\n"
    js += wrap("users", MongoService.usersScript(database: "admin"))
    js += wrap("password", MongoService.passwordScript(database: "app", user: "o'brien\"x",
                                                       password: "p@ss\"w0rd\\end", roles: ["readWrite"]))
    js += wrap("drop", MongoService.dropDatabaseScript("app"))
    js += wrap("admin", MongoService.createAdminUserScript(user: "admin", password: "pwd123", roles: ["root"]))
    js += wrap("changePassword", MongoService.changePasswordScript(database: "admin", user: "admin", newPassword: "N3w!pass"))
    js += "print(JSON.stringify(__calls));\n"

    let jsPath = workRoot + "/generated-scripts.js"
    let writeError = FileTools.write(jsPath, js)
    if writeError != nil {
        check("写出生成的脚本", false, writeError ?? "")
    } else {
        let run = Shell.run([mongosh, "--nodb", "--quiet", "--file", jsPath], timeout: 60)
        check("mongosh 能解析并执行生成的脚本", run.ok, run.message)
        check("查用户脚本输出空数组", run.stdout.contains("--- users ---\n[]"), run.stdout)
        check("建用户脚本返回 created", run.stdout.contains("\"action\":\"created\""), run.stdout)
        check("删库脚本返回 ok=1", run.stdout.contains("\"dropped\":\"app\",\"ok\":1"), run.stdout)
        check("建管理员脚本返回 created-admin", run.stdout.contains("\"action\":\"created-admin\""), run.stdout)
        check("改密码脚本返回 password-updated", run.stdout.contains("\"action\":\"password-updated\""), run.stdout)
        // 有用户时的输出格式（确认能被我们的 JSON 解析吃下）
        let stubWithUsers = stub.replacingOccurrences(of: "return { users: [] };",
                                                      with: "return { users: [{user: 'alice', roles: [{role: 'readWrite'}]}, {user: 'bob', roles: []}] };")
        let js2 = stubWithUsers + "\n" + wrap("users", MongoService.usersScript(database: "app"))
        let jsPath2 = workRoot + "/generated-scripts-with-users.js"
        if FileTools.write(jsPath2, js2) == nil {
            let run2 = Shell.run([mongosh, "--nodb", "--quiet", "--file", jsPath2], timeout: 60)
            let trimmed = run2.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let jsonLine = trimmed.split(separator: "\n").last { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
                .map { String($0) } ?? ""
            let parsed = (try? JSONSerialization.jsonObject(with: Data(jsonLine.utf8))) as? [[String: Any]]
            check("有用户时输出可被解析", (parsed?.count ?? 0) == 2, trimmed)
            check("解析出用户名与角色", (parsed?.first?["user"] as? String) == "alice"
                  && (parsed?.first?["roles"] as? [String]) == ["readWrite"], trimmed)
        }

        check("调用序列为 usersInfo → createUser → dropDatabase",
              run.stdout.contains("{\"db\":\"app\",\"cmd\":{\"usersInfo\":\"o'brien\\\"x\"}}")
              && run.stdout.contains("{\"createUser\":\"o'brien\\\"x\"")
              && run.stdout.contains("{\"dropDatabase\":1}"), run.stdout)
    }
} else {
    print("== 跳过 mongosh 脚本执行验证（本机没装 mongosh）==")
}

fake.stop()

print("")
print(failures == 0 ? "全部通过：\(checks) 项" : "失败 \(failures)/\(checks) 项")
exit(failures == 0 ? 0 : 1)
