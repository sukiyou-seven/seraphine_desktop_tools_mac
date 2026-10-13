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

print("== 家目录开发日志：严格识别与变更保护 ==")
let cleanupRoot = URL(fileURLWithPath: workRoot + "/home-log-fixtures", isDirectory: true)
try? FileManager.default.createDirectory(at: cleanupRoot, withIntermediateDirectories: true)
let oldDate = Date().addingTimeInterval(-48 * 3600)
func fixtureLog(_ name: String, _ content: String) -> URL {
    let url = cleanupRoot.appendingPathComponent(name)
    try? Data(content.utf8).write(to: url)
    try? FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
    return url
}
let buildLog = fixtureLog("_sample_build.log", "Command line invocation:\n    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project LoveApp.xcodeproj -scheme LoveApp build\n")
let installLog = fixtureLog("_sample_install.log", "ERROR: Failed to install (com.apple.dt.CoreDeviceError error 3002)\n")
let unrelatedLog = fixtureLog("database.log", "database startup complete\n")
let freshLog = fixtureLog("_fresh_build.log", "Command line invocation:\n    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project Demo.xcodeproj -scheme Demo build\n")
try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: freshLog.path)
let linkedLog = cleanupRoot.appendingPathComponent("_linked_build.log")
try? FileManager.default.createSymbolicLink(at: linkedLog, withDestinationURL: buildLog)
let cleanupCandidates = HomeLogCleanup.scan(home: cleanupRoot)
check("只识别旧 Xcode 构建与设备日志", Set(cleanupCandidates.map { $0.url.lastPathComponent }) == ["_sample_build.log", "_sample_install.log"])
check("忽略普通日志、新日志和符号链接", cleanupCandidates.count == 2 && FileManager.default.fileExists(atPath: unrelatedLog.path))
try? Data("changed\n".utf8).write(to: installLog)
let changedCleanup = HomeLogCleanup.moveToTrash(cleanupCandidates.filter { $0.url == installLog }, home: cleanupRoot)
check("清理前文件改变则跳过", changedCleanup.moved == 0 && changedCleanup.skipped == 1 && FileManager.default.fileExists(atPath: installLog.path))

print("== 项目管理：多子工程发现与解释器选择 ==")
let projectsRoot = workRoot + "/project-fixtures"
let frontend = projectsRoot + "/apps/frontend"
let backend = projectsRoot + "/services/backend"
let ignoredNode = frontend + "/node_modules/hidden"
let ignoredVenv = backend + "/.venv/bin"
for directory in [frontend, backend, ignoredNode, ignoredVenv] {
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
}
try? Data(#"{"scripts":{"dev":"vite","build":"vite build"},"private":true}"#.utf8)
    .write(to: URL(fileURLWithPath: frontend + "/package.json"))
try? Data(#"{"scripts":{"secret":"echo hidden"}}"#.utf8)
    .write(to: URL(fileURLWithPath: ignoredNode + "/package.json"))
try? Data("print('hello')".utf8).write(to: URL(fileURLWithPath: backend + "/main.py"))
let fakePython = ignoredVenv + "/python"
try? Data("#!/bin/sh\npwd\nprintf '%s\\n' \"$1\"\n".utf8).write(to: URL(fileURLWithPath: fakePython))
try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePython)
let secondRoot = workRoot + "/second-project"
try? FileManager.default.createDirectory(atPath: secondRoot, withIntermediateDirectories: true)
try? Data("print('second')".utf8).write(to: URL(fileURLWithPath: secondRoot + "/main.py"))
try? Data(#"{"appid":"wx-test"}"#.utf8).write(to: URL(fileURLWithPath: secondRoot + "/project.config.json"))
let projectScan = ProjectDiscovery.scan(root: projectsRoot)
check("扫描出两个子工程", projectScan.components.count == 2)
check("Node 脚本从 package.json 获取并排序",
      projectScan.components.first(where: { $0.directory == frontend })?.scripts == ["build", "dev"])
check("Python 工程单独列出",
      projectScan.components.first(where: { $0.directory == backend })?.hasPython == true)
check("忽略 node_modules 中的 package.json",
      !projectScan.components.contains(where: { $0.directory == ignoredNode }))
check("使用对应子工程的 venv",
      ProjectDiscovery.preferredPython(for: backend, root: projectsRoot,
                                       interpreters: projectScan.interpreters) == fakePython)
check("识别微信小程序工程", ProjectDiscovery.scan(root: secondRoot).components.first?.hasWeChat == true)
let miniOnly = workRoot + "/mini-only"
try? FileManager.default.createDirectory(atPath: miniOnly, withIntermediateDirectories: true)
try? Data("{}".utf8).write(to: URL(fileURLWithPath: miniOnly + "/project.config.json"))
check("只有小程序配置也能作为子工程列出",
      ProjectDiscovery.scan(root: miniOnly).components.first?.hasWeChat == true)
let uniApp = workRoot + "/uniapp"
try? FileManager.default.createDirectory(atPath: uniApp, withIntermediateDirectories: true)
try? Data(#"{"scripts":{"dev:mp-weixin":"uni -p mp-weixin"}}"#.utf8)
    .write(to: URL(fileURLWithPath: uniApp + "/package.json"))
check("uni-app 项目在构建前也显示微信入口",
      ProjectDiscovery.scan(root: uniApp).components.first?.hasWeChat == true)
let generatedMini = uniApp + "/dist/dev/mp-weixin"
try? FileManager.default.createDirectory(atPath: generatedMini, withIntermediateDirectories: true)
try? Data("{}".utf8).write(to: URL(fileURLWithPath: generatedMini + "/project.config.json"))
check("微信入口指向 uni-app 生成目录",
      ProjectDiscovery.weChatProjectDirectory(in: uniApp) == generatedMini)
check("从 npm 输出识别本地网页地址",
      ProjectRunner.localURL(in: "Local: http://localhost:5173/\nNetwork: http://192.168.1.2:5173")?.absoluteString
      == "http://localhost:5173/")
check("网页地址只接受 HTTP(S)", ProjectRunner.validWebsiteURL("javascript:alert(1)") == nil)
if let pythonComponent = projectScan.components.first(where: { $0.directory == backend }) {
    let runner = MainActor.assumeIsolated {
        ProjectRunner(catalogURL: URL(fileURLWithPath: workRoot + "/projects.json"))
    }
    MainActor.assumeIsolated {
        runner.add(projectsRoot)
        runner.add(secondRoot)
        runner.setPythonOverride(fakePython, for: backend)
    }
    let scanDeadline = Date().addingTimeInterval(3)
    while Date() < scanDeadline {
        let scanned = MainActor.assumeIsolated {
            runner.scans[projectsRoot] != nil && runner.scans[secondRoot] != nil
        }
        if scanned { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    check("多个工程同时保留在列表",
          MainActor.assumeIsolated { runner.roots.count == 2 })
    check("两个工程的扫描结果同时可见",
          MainActor.assumeIsolated {
              runner.scans[projectsRoot]?.components.count == 2
              && runner.scans[secondRoot]?.components.count == 1
          })
    MainActor.assumeIsolated { runner.startPython(pythonComponent, in: projectsRoot) }
    let runDeadline = Date().addingTimeInterval(3)
    while Date() < runDeadline {
        let finished = MainActor.assumeIsolated {
            runner.runs[runner.pythonID(pythonComponent)]?.running == false
        }
        if finished { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    let state = MainActor.assumeIsolated { runner.runs[runner.pythonID(pythonComponent)] }
    let launchError = MainActor.assumeIsolated { runner.error }
    check("Python 从对应子工程目录启动", state?.output.contains(backend) == true,
          launchError + " / " + (state?.output ?? "无运行状态"))
    check("Python 收到默认 main.py 入口", state?.output.contains(backend + "/main.py") == true,
          launchError + " / " + (state?.output ?? "无运行状态"))
    check("短任务结束后状态更新", state?.running == false && state?.exitCode == 0,
          launchError + " / " + (state?.message ?? "无运行状态"))
    let reloaded = MainActor.assumeIsolated {
        ProjectRunner(catalogURL: URL(fileURLWithPath: workRoot + "/projects.json"))
    }
    check("重启后仍保留全部工程", MainActor.assumeIsolated { reloaded.roots.count == 2 })
    check("手动添加的 Python 解释器会保存", MainActor.assumeIsolated {
        reloaded.pythonOverrides[backend] == fakePython
    })
    MainActor.assumeIsolated { reloaded.toggleCollapsed(projectsRoot) }
    MainActor.assumeIsolated { reloaded.setWebURL("http://localhost:3000", for: frontend) }
    let withURL = MainActor.assumeIsolated {
        ProjectRunner(catalogURL: URL(fileURLWithPath: workRoot + "/projects.json"))
    }
    check("网页地址按子工程保存", MainActor.assumeIsolated {
        withURL.webURLs[frontend] == "http://localhost:3000" && withURL.roots.count == 2
    })
    check("工程折叠状态会保存", MainActor.assumeIsolated {
        withURL.collapsedRoots.contains(projectsRoot)
    })
    let legacyPath = URL(fileURLWithPath: workRoot + "/legacy-projects.json")
    try? JSONEncoder().encode([projectsRoot]).write(to: legacyPath)
    let legacy = MainActor.assumeIsolated { ProjectRunner(catalogURL: legacyPath) }
    check("兼容旧版工程目录列表", MainActor.assumeIsolated { legacy.roots == [projectsRoot] })
}

print("== Python 环境：发现、安装与删除 ==")
let environmentRoot = workRoot + "/python-environment-fixtures"
let virtualRoot = environmentRoot + "/.venv"
let virtualBin = virtualRoot + "/bin"
try? FileManager.default.createDirectory(atPath: virtualBin, withIntermediateDirectories: true)
try? Data("home = /usr/bin\n".utf8).write(to: URL(fileURLWithPath: virtualRoot + "/pyvenv.cfg"))
let virtualPython = virtualBin + "/python"
let fakeEnvironmentPython = """
#!/bin/sh
if [ "$2" = "pip" ] && [ "$3" = "list" ]; then
  printf '[{"name":"pip","version":"1.0"}]\\n'
else
  printf '%s\\n' "$*"
fi
"""
try? Data(fakeEnvironmentPython.utf8).write(to: URL(fileURLWithPath: virtualPython))
try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: virtualPython)
check("能从环境目录找到解释器", PythonEnvironmentDiscovery.pythonPath(at: virtualRoot) == virtualPython)
check("虚拟环境需有 pyvenv.cfg 才可删除",
      PythonEnvironmentDiscovery.deletableDirectory(for: virtualPython) == virtualRoot
      && PythonEnvironmentDiscovery.deletableDirectory(for: "/usr/bin/python3") == nil)
check("工程目录中的环境被发现",
      PythonEnvironmentDiscovery.discover(projectRoots: [environmentRoot], addedPaths: [], createdPaths: [])
          .contains(where: { $0.pythonPath == virtualPython }))
check("pip 源地址验证", PythonEnvironmentManager.validIndexURL("https://example.test/simple")
      && !PythonEnvironmentManager.validIndexURL("javascript:alert(1)"))
let environmentCatalog = URL(fileURLWithPath: workRoot + "/python-environments.json")
let environmentManager = MainActor.assumeIsolated { PythonEnvironmentManager(catalogURL: environmentCatalog) }
MainActor.assumeIsolated {
    environmentManager.add(virtualRoot, projectRoots: [])
    environmentManager.setIndexURL("https://example.test/simple")
}
let environmentDeadline = Date().addingTimeInterval(5)
while Date() < environmentDeadline {
    if MainActor.assumeIsolated({ !environmentManager.environments.isEmpty }) { break }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
check("手动添加的环境显示在列表", MainActor.assumeIsolated {
    environmentManager.environments.contains(where: { $0.pythonPath == virtualPython })
})
MainActor.assumeIsolated {
    environmentManager.packageInput = "requests==2.31.0"
    environmentManager.installPackages()
}
let installDeadline = Date().addingTimeInterval(5)
while Date() < installDeadline {
    if MainActor.assumeIsolated({ environmentManager.busy == nil }) { break }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
check("pip install 使用所选源和包版本", MainActor.assumeIsolated {
    environmentManager.output.contains("--index-url https://example.test/simple requests==2.31.0")
})
let savedEnvironmentManager = MainActor.assumeIsolated {
    PythonEnvironmentManager(catalogURL: environmentCatalog)
}
check("环境与 pip 源保存后可恢复", MainActor.assumeIsolated {
    savedEnvironmentManager.selectedPath == virtualPython
        && savedEnvironmentManager.indexURL == "https://example.test/simple"
})
let deletingEnvironment = MainActor.assumeIsolated {
    environmentManager.environments.first(where: { $0.pythonPath == virtualPython })
}
if let deletingEnvironment {
    MainActor.assumeIsolated {
        environmentManager.removeFromList(deletingEnvironment, projectRoots: [environmentRoot])
    }
    let hiddenDeadline = Date().addingTimeInterval(5)
    while Date() < hiddenDeadline {
        if MainActor.assumeIsolated({ !environmentManager.scanning }) { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    check("从列表移除后不会被工程扫描重新加回", MainActor.assumeIsolated {
        !environmentManager.environments.contains(where: { $0.pythonPath == virtualPython })
    })
    MainActor.assumeIsolated { environmentManager.add(virtualRoot, projectRoots: []) }
    MainActor.assumeIsolated { environmentManager.delete(deletingEnvironment, projectRoots: []) }
    let deleteDeadline = Date().addingTimeInterval(5)
    while Date() < deleteDeadline {
        if MainActor.assumeIsolated({ environmentManager.busy == nil }) { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    check("删除虚拟环境会移除目录", !FileManager.default.fileExists(atPath: virtualRoot))
}
let fakeBasePython = environmentRoot + "/base-python"
let fakeVenvCreator = """
#!/bin/sh
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
  /bin/mkdir -p "$3/bin"
  /bin/cp "$0" "$3/bin/python"
  printf 'home = /usr/bin\\n' > "$3/pyvenv.cfg"
fi
"""
try? Data(fakeVenvCreator.utf8).write(to: URL(fileURLWithPath: fakeBasePython))
try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBasePython)
MainActor.assumeIsolated {
    environmentManager.create(parent: environmentRoot, name: "new-venv",
                              basePython: fakeBasePython, projectRoots: [])
}
let createDeadline = Date().addingTimeInterval(5)
while Date() < createDeadline {
    if MainActor.assumeIsolated({ environmentManager.busy == nil }) { break }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
let createdEnvironment = environmentRoot + "/new-venv"
check("新建环境调用 Python -m venv 并记录解释器",
      FileManager.default.fileExists(atPath: createdEnvironment + "/pyvenv.cfg")
      && MainActor.assumeIsolated({ environmentManager.selectedPath == createdEnvironment + "/bin/python" }))

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
check("RSA 证书目录不使用 _ecc 后缀",
      parsedCerts.last?.fullchainPath == "/Users/x/.acme.sh/api.example.com/fullchain.cer")
check("空输出不崩", ACMEService.parseList("", home: "/tmp").isEmpty)




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

print("== 旧版设置兼容 ==")
let legacySettingsJSON = Data(#"{"mongo":{"adminUser":"existing-user"},"vpn":{"host":"1.2.3.4","sshPassword":"legacy-secret"}}"#.utf8)
let legacySettings = try? JSONDecoder().decode(AppSettings.self, from: legacySettingsJSON)
check("忽略旧版 VPN 配置并保留数据库设置", legacySettings?.mongo.adminUser == "existing-user")
let migratedSettings = legacySettings.flatMap { try? JSONEncoder().encode($0) }
let migratedObject = migratedSettings.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
check("重新保存时移除旧版 VPN 配置", migratedObject != nil && migratedObject?["vpn"] == nil)

print("== 通用日志脱敏 ==")
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

// MARK: AI 开发（codex 无人值守看门狗）

print("== AI：本机代理（scutil --proxy）==")
let scutilSample = """
<dictionary> {
  ExceptionsList : <array> {
    0 : localhost
    1 : 127.0.0.0/8
    2 : ::1
  }
  FTPPassive : 1
  HTTPEnable : 1
  HTTPPort : 10808
  HTTPProxy : 127.0.0.1
  HTTPSEnable : 1
  HTTPSPort : 10808
  HTTPSProxy : 127.0.0.1
  SOCKSEnable : 1
  SOCKSPort : 10808
  SOCKSProxy : 127.0.0.1
}
"""
let aiProxy = AIProxyConfig.parse(scutilOutput: scutilSample)
check("解析出 HTTP 代理", aiProxy.http.url == "http://127.0.0.1:10808", aiProxy.summary)
check("解析出 HTTPS 代理", aiProxy.https.url == "http://127.0.0.1:10808")
check("解析出 SOCKS 代理", aiProxy.socks.url == "http://127.0.0.1:10808")
check("解析出例外列表", aiProxy.exceptions == ["localhost", "127.0.0.0/8", "::1"],
      aiProxy.exceptions.joined(separator: ","))
check("摘要里三类都列出来",
      aiProxy.summary.contains("HTTP 127.0.0.1:10808") && aiProxy.summary.contains("SOCKS 127.0.0.1:10808"),
      aiProxy.summary)
check("空的 scutil 输出 = 没有代理", AIProxyConfig.parse(scutilOutput: "").isEmpty)
let aiProxyOff = AIProxyConfig.parse(scutilOutput: "HTTPEnable : 0\nHTTPProxy : 127.0.0.1\nHTTPPort : 10808")
check("开关为 0 时不算开启", aiProxyOff.isEmpty)
let aiProxyIPv6 = AIProxyConfig.parse(scutilOutput: "HTTPEnable : 1\nHTTPProxy : ::1\nHTTPPort : 10808")
check("IPv6 地址里的冒号不当分隔符", aiProxyIPv6.http.host == "::1", aiProxyIPv6.http.display)

let aiProxyEnv = aiProxy.environment(override: "")
check("注入 HTTP_PROXY", aiProxyEnv["HTTP_PROXY"] == "http://127.0.0.1:10808", aiProxyEnv["HTTP_PROXY"] ?? "")
check("注入 HTTPS_PROXY", aiProxyEnv["HTTPS_PROXY"] == "http://127.0.0.1:10808")
check("SOCKS 走 ALL_PROXY", aiProxyEnv["ALL_PROXY"] == "socks5://127.0.0.1:10808", aiProxyEnv["ALL_PROXY"] ?? "")
check("大小写各写一份（不同客户端认的名字不一样）",
      aiProxyEnv["https_proxy"] == aiProxyEnv["HTTPS_PROXY"] && aiProxyEnv["no_proxy"] == aiProxyEnv["NO_PROXY"])
check("NO_PROXY 带上系统例外", (aiProxyEnv["NO_PROXY"] ?? "").contains("127.0.0.0/8"))
check("NO_PROXY 带上本地地址", (aiProxyEnv["NO_PROXY"] ?? "").contains("localhost"))
check("NO_PROXY 去重（系统例外里已有 localhost 时不重复写）",
      (aiProxyEnv["NO_PROXY"] ?? "").split(separator: ",").filter { $0 == "localhost" }.count == 1,
      aiProxyEnv["NO_PROXY"] ?? "")

let aiProxyOverride = aiProxy.environment(override: "127.0.0.1:10809")
check("手动覆盖优先于自动探测", aiProxyOverride["HTTP_PROXY"] == "http://127.0.0.1:10809",
      aiProxyOverride["HTTP_PROXY"] ?? "")
check("覆盖时 ALL_PROXY 同指一个", aiProxyOverride["ALL_PROXY"] == "http://127.0.0.1:10809")
check("带 scheme 的覆盖原样保留", AIProxyConfig.normalize("socks5://127.0.0.1:1080") == "socks5://127.0.0.1:1080")
check("空覆盖返回 nil（回落到自动探测）", AIProxyConfig.normalize("   ") == nil)
check("不像地址的覆盖忽略", AIProxyConfig.normalize("abcdef") == nil)

print("== AI：限额识别与恢复时间解析 ==")
check("识别 usage limit", AIUsageLimit.looksLikeLimit("You've hit your usage limit for GPT-6."))
check("识别 429", AIUsageLimit.looksLikeLimit("HTTP 429 Too Many Requests"))
check("普通输出不算限额", !AIUsageLimit.looksLikeLimit("tests passed, 12 files changed"))
check("限额文本不算登录致命错误",
      !AIUsageLimit.looksFatal("You've hit your usage limit. Try again at 9:30 PM."))
check("登录类错误算致命", AIUsageLimit.looksFatal("error: not logged in, please run codex login"))
check("非 Git 目录算致命（重试也没用）",
      AIUsageLimit.looksFatal("Error: not inside a git repository, pass --skip-git-repo-check"))
check("普通报错不算致命", !AIUsageLimit.looksFatal("network error: connection reset"))
check("识别「没有可续跑的会话」", AIUsageLimit.looksLikeNoSession("error: no sessions found in this directory"))
check("限额文案不会被当成没有会话",
      !AIUsageLimit.looksLikeNoSession("You've hit your usage limit. Try again at 9:30 PM."))
check("普通输出不会被当成没有会话", !AIUsageLimit.looksLikeNoSession("做了 3 处修改，测试通过"))

var aiCalendar = Calendar(identifier: .gregorian)
aiCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
let aiNow = aiCalendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 12, minute: 0, second: 0))!

// ISO 带时区：按绝对时间解析（不受本机时区影响）
let isoExpected = ISO8601DateFormatter().date(from: "2026-09-26T21:30:00Z")!
let aiISO = AIUsageLimit.parseResetDate(in: "You've hit your usage limit. Try again at 2026-09-26T21:30:00Z",
                                        now: aiNow, calendar: aiCalendar)
check("解析 ISO 时间", aiISO != nil && abs((aiISO ?? .distantPast).timeIntervalSince(isoExpected)) < 1,
      aiISO.map { "\($0)" } ?? "nil")

// 不带时区：按本地时区理解
let localExpected = aiCalendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 21, minute: 30))!
let aiLocal = AIUsageLimit.parseResetDate(in: "resets at 2026-09-26 21:30", now: aiNow, calendar: aiCalendar)
check("解析本地日期时间", aiLocal != nil && abs((aiLocal ?? .distantPast).timeIntervalSince(localExpected)) < 1,
      aiLocal.map { "\($0)" } ?? "nil")

// 只有时间：今天还没到 → 今天；已经过了 → 明天
let todayExpected = aiCalendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 21, minute: 30))!
let aiClock = AIUsageLimit.parseResetDate(in: "usage limit reached, try again at 9:30 PM",
                                          now: aiNow, calendar: aiCalendar)
check("只有时间时按今天算", aiClock != nil && abs((aiClock ?? .distantPast).timeIntervalSince(todayExpected)) < 1,
      aiClock.map { "\($0)" } ?? "nil")
let lateNow = aiCalendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 22, minute: 0))!
let tomorrowExpected = aiCalendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 21, minute: 30))!
let aiClockTomorrow = AIUsageLimit.parseResetDate(in: "try again at 9:30 PM", now: lateNow, calendar: aiCalendar)
check("时间已过则算明天",
      aiClockTomorrow != nil && abs((aiClockTomorrow ?? .distantPast).timeIntervalSince(tomorrowExpected)) < 1,
      aiClockTomorrow.map { "\($0)" } ?? "nil")

let monthExpected = aiCalendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 21, minute: 30))!
let aiMonth = AIUsageLimit.parseResetDate(in: "limit resets at Sep 26, 9:30 PM", now: aiNow, calendar: aiCalendar)
check("解析 Sep 26, 9:30 PM", aiMonth != nil && abs((aiMonth ?? .distantPast).timeIntervalSince(monthExpected)) < 1,
      aiMonth.map { "\($0)" } ?? "nil")
check("没有任何时间信息时返回 nil",
      AIUsageLimit.parseResetDate(in: "you hit your usage limit. upgrade to continue.", now: aiNow, calendar: aiCalendar) == nil)
check("无关文本返回 nil", AIUsageLimit.parseResetDate(in: "all good", now: aiNow, calendar: aiCalendar) == nil)

check("指数退避 300→600→1200→封顶 3600",
      AIUsageLimit.backoffWait(attempt: 1) == 300 && AIUsageLimit.backoffWait(attempt: 2) == 600
      && AIUsageLimit.backoffWait(attempt: 3) == 1200 && AIUsageLimit.backoffWait(attempt: 9) == 3600)
let aiWaitKnown = AIUsageLimit.waitSeconds(resetAt: aiNow.addingTimeInterval(100), now: aiNow, attempt: 1)
check("解析到恢复时间就等到那时（+60 秒缓冲）", aiWaitKnown == 160, "\(aiWaitKnown)")
let aiWaitFar = AIUsageLimit.waitSeconds(resetAt: aiNow.addingTimeInterval(10 * 3600), now: aiNow, attempt: 1)
check("恢复时间太远时封顶 1 小时", aiWaitFar == 3600, "\(aiWaitFar)")
let aiWaitPast = AIUsageLimit.waitSeconds(resetAt: aiNow.addingTimeInterval(-600), now: aiNow, attempt: 2)
check("恢复时间已过则退回指数退避", aiWaitPast == 600, "\(aiWaitPast)")
check("没有恢复时间时用首次退避", AIUsageLimit.waitSeconds(resetAt: nil, now: aiNow, attempt: 1) == 300)
let aiWaitNear = AIUsageLimit.waitSeconds(resetAt: aiNow.addingTimeInterval(5), now: aiNow, attempt: 1)
check("恢复时间马上到也有 60 秒下限（5 秒 + 60 秒缓冲）", aiWaitNear == 65, "\(aiWaitNear)")

print("== AI：codex 命令构造 ==")
var aiSettings = AIDevSettings()
aiSettings.workDir = workRoot + "/ai-work"
aiSettings.model = "gpt-6-astra"
aiSettings.effort = "high"
let aiFirst = AICodexCommand.firstArguments(settings: aiSettings, prompt: "把 README 里的错别字改掉")
check("首轮是 codex exec", aiFirst.first == "exec")
check("首轮带模型", aiFirst.contains("-m") && aiFirst.contains("gpt-6-astra"))
check("首轮带推理强度", aiFirst.contains("model_reasoning_effort=\"high\""))
check("首轮用 workspace-write + 自动审批",
      aiFirst.contains("-s") && aiFirst.contains("workspace-write") && aiFirst.contains("--approve-for-me"))
check("首轮放行非 Git 目录", aiFirst.contains("--skip-git-repo-check"))
check("首轮带工作目录", aiFirst.contains("-C") && aiFirst.contains(aiSettings.workDir))
check("任务描述是最后一个参数", aiFirst.last == "把 README 里的错别字改掉")
check("首轮不是 resume", !aiFirst.contains("resume"))

let aiResume = AICodexCommand.resumeArguments(settings: aiSettings)
check("续跑是 exec resume --last", Array(aiResume.prefix(3)) == ["exec", "resume", "--last"], aiResume.joined(separator: " "))
check("续跑不带 -s（resume 子命令没有这个选项）", !aiResume.contains("-s"))
check("续跑用 -c 传沙箱", aiResume.contains("sandbox_mode=\"workspace-write\""))
check("续跑仍带模型与推理强度",
      aiResume.contains("gpt-6-astra") && aiResume.contains("model_reasoning_effort=\"high\""))
check("续跑下发的是「接着干」指令", (aiResume.last ?? "").contains("继续之前的工作"))

aiSettings.sandbox = AISandbox.bypass.rawValue
check("完全放开：两轮都带 bypass 参数",
      AICodexCommand.firstArguments(settings: aiSettings, prompt: "x").contains("--dangerously-bypass-approvals-and-sandbox")
      && AICodexCommand.resumeArguments(settings: aiSettings).contains("--dangerously-bypass-approvals-and-sandbox"))
aiSettings.sandbox = AISandbox.readOnly.rawValue
check("只读档：首轮 -s read-only",
      AICodexCommand.firstArguments(settings: aiSettings, prompt: "x").contains("read-only"))
aiSettings.sandbox = AISandbox.workspaceWrite.rawValue
aiSettings.model = ""
aiSettings.effort = ""
aiSettings.allowNonGit = false
let aiMinimal = AICodexCommand.firstArguments(settings: aiSettings, prompt: "x")
check("跟随配置时不传 -m", !aiMinimal.contains("-m"))
check("跟随默认时不传推理强度", !aiMinimal.contains { $0.contains("model_reasoning_effort") })
check("关掉后不传非 Git 放行", !aiMinimal.contains("--skip-git-repo-check"))
check("预览命令可直接贴进终端（每个参数带引号）",
      AICodexCommand.previewCommand(settings: aiSettings, resuming: false).hasPrefix("codex 'exec'"))
check("工作目录留空时回落到 HOME", AICodexCommand.workDirectory(AIDevSettings()) == NSHomeDirectory())
check("没填目录时 hasWorkDir 为假", !AIDevSettings().hasWorkDir)
var aiPathSettings = AIDevSettings()
aiPathSettings.workDir = "  ~/proj/../proj2  "
check("填了目录时 hasWorkDir 为真", aiPathSettings.hasWorkDir)
check("任务目录会展开 ~ 并消掉 ..",
      AICodexCommand.workDirectory(aiPathSettings) == NSHomeDirectory() + "/proj2",
      AICodexCommand.workDirectory(aiPathSettings))
check("未知沙箱值回退工作目录档", AISandbox.from("something-else") == .workspaceWrite)
check("沙箱取值稳定（传给 codex 的字符串不能变）",
      AISandbox.workspaceWrite.rawValue == "workspace-write" && AISandbox.readOnly.rawValue == "read-only")

print("== AI：codex 事件流（--json 进度探测）==")
// 样本按 codex 0.157 的真实事件结构手写：顶层 thread/turn/item 事件 + item 的各类别
let aiJSONL = """
{"type":"thread.started","thread_id":"0199abcd-1234-7890-abcd-ef0123456789"}
{"type":"turn.started"}
{"type":"item.started","item":{"id":"i1","type":"reasoning","text":"先看看仓库结构"}}
{"type":"item.completed","item":{"id":"i1","type":"reasoning","text":"先看看仓库结构"}}
{"type":"item.started","item":{"id":"i2","type":"command_execution","command":"rg --files -g '*.swift'"}}
{"type":"item.completed","item":{"id":"i2","type":"command_execution","command":"rg --files -g '*.swift'","aggregated_output":"Sources/App.swift\\nSources/Support.swift","exit_code":0}}
{"type":"item.updated","item":{"id":"i2","type":"command_execution","command":"rg --files","aggregated_output":"Sources/App.swift"}}
{"type":"item.completed","item":{"id":"i3","type":"file_change","changes":[{"path":"Sources/Support.swift","kind":"update"},{"path":"README.md","kind":"add"}]}}
{"type":"item.completed","item":{"id":"i4","type":"todo_list","items":[{"text":"改 Support.swift","completed":true},{"text":"补测试","completed":false}]}}
{"type":"item.completed","item":{"id":"i5","type":"agent_message","text":"改好了：Support.swift 换掉了旧写法，测试待补。"}}
{"type":"turn.completed","usage":{"input_tokens":12345,"cached_input_tokens":1000,"output_tokens":678}}
"""
let aiEvents = aiJSONL.split(separator: "\n").compactMap { CodexEventParser.parse(String($0)) }
check("一行一个事件都能解出来", aiEvents.count == 11, "\(aiEvents.count)")
check("thread.started 带 thread_id",
      aiEvents.first?.kind == .threadStarted && (aiEvents.first?.threadID ?? "").hasPrefix("0199abcd"))
let aiSummary = CodexRoundSummary.merged(from: aiEvents)
check("统计到 1 次命令执行", aiSummary.commands == 1, "\(aiSummary.commands)")
check("统计到 2 个改动文件（含顺序）",
      aiSummary.changedFiles == ["Sources/Support.swift", "README.md"],
      aiSummary.changedFiles.joined(separator: ","))
check("todo 完成度 1/2", aiSummary.completedTodoCount == 1 && aiSummary.todos.count == 2)
check("todo 文案", aiSummary.todoText == "1/2", aiSummary.todoText)
check("取到最后一条 agent 消息", aiSummary.lastMessage.contains("测试待补"), aiSummary.lastMessage)
check("turn.completed 标记与 tokens",
      aiSummary.turnCompleted && aiSummary.inputTokens == 12345 && aiSummary.outputTokens == 678)
check("这一轮算有实质动作（有命令/有改动）", aiSummary.hasSubstantiveAction)
check("事件计数不含未知类型", aiSummary.eventCount == 11, "\(aiSummary.eventCount)")

// 只有消息、没有任何动作的轮次 —— autoContinue 下靠它判断「没活可干了」
let aiIdleJSONL = """
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"当前仓库没有需要改动的地方。"}}
{"type":"turn.completed","usage":{"input_tokens":900,"output_tokens":20}}
"""
let aiIdle = CodexRoundSummary.merged(from: aiIdleJSONL.split(separator: "\n").compactMap { CodexEventParser.parse(String($0)) })
check("只有消息的轮次没有实质动作", !aiIdle.hasSubstantiveAction && aiIdle.eventCount == 3)
check("空转轮次仍记录消息与 tokens",
      aiIdle.lastMessage.contains("没有需要改动") && aiIdle.outputTokens == 20)

// 渲染成日志行
func aiHuman(_ json: String) -> String { CodexEventParser.parse(json).flatMap { CodexEventParser.humanLine($0) } ?? "" }
check("命令开始渲染成 $ 开头",
      aiHuman(#"{"type":"item.started","item":{"type":"command_execution","command":"swift build"}}"#).hasPrefix("$ swift build"))
let aiCommandLine = aiHuman(#"{"type":"item.completed","item":{"type":"command_execution","command":"swift build","aggregated_output":"error: no such file or directory","exit_code":1}}"#)
check("命令结束渲染退出码", aiCommandLine.contains("退出码 1"), aiCommandLine)
check("命令失败时附上输出尾部", aiCommandLine.contains("no such file"), aiCommandLine)
let aiFileChangeLine = aiHuman(#"{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"a/b.swift","kind":"update"}]}}"#)
check("文件改动渲染成人话", aiFileChangeLine.contains("改动文件") && aiFileChangeLine.contains("a/b.swift"), aiFileChangeLine)
let aiTodoLine = aiHuman(#"{"type":"item.completed","item":{"type":"todo_list","items":[{"text":"步骤一","completed":true},{"text":"步骤二","completed":false}]}}"#)
check("todo 渲染出完成度与未完成项",
      aiTodoLine.contains("计划 1/2") && aiTodoLine.contains("步骤二"), aiTodoLine)
check("agent 消息原样写进日志",
      aiHuman(#"{"type":"item.completed","item":{"type":"agent_message","text":"做完了，共改 3 个文件"}}"#) == "做完了，共改 3 个文件")
check("turn.completed 渲染出 tokens",
      aiHuman(#"{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":20}}"#).contains("输入 10"))
check("turn.failed 渲染出失败原因",
      aiHuman(#"{"type":"turn.failed","error":{"message":"stream error"}}"#).contains("stream error"))
check("item.updated 不写日志（流式中间态，避免刷屏）",
      aiHuman(#"{"type":"item.updated","item":{"type":"command_execution","aggregated_output":"部分输出"}}"#).isEmpty)
check("web_search 渲染出来",
      aiHuman(#"{"type":"item.completed","item":{"type":"web_search","query":"swiftui timelineview"}}"#).contains("swiftui timelineview"))

// 宽松性：codex 换字段/加类型时不能把看门狗搞崩
check("非 JSON 行返回 nil（stderr 混进来的告警）", CodexEventParser.parse("WARNING: proceeding anyway") == nil)
check("坏 JSON 返回 nil", CodexEventParser.parse("{oops") == nil)
check("未知事件类型不崩（kind = unknown）",
      CodexEventParser.parse(#"{"type":"something.new"}"#)?.kind == .unknown)
check("缺字段的 item 不崩", CodexEventParser.parse(#"{"type":"item.completed","item":{}}"#) != nil)
check("exit_code 是字符串也能读",
      CodexEventParser.parse(#"{"type":"item.completed","item":{"type":"command_execution","exit_code":"2"}}"#)?.exitCode == 2)
check("没有 changes 时改动为空",
      CodexEventParser.parse(#"{"type":"item.completed","item":{"type":"file_change"}}"#)?.changedFiles.isEmpty == true)
check("未知类型的事件不进汇总", CodexRoundSummary.merged(from: [
    CodexEvent(kind: .unknown), CodexEvent(kind: .turnStarted),
]).eventCount == 1)

check("默认开启事件流", AIDevSettings().jsonEvents)
check("首轮命令带上 --json", aiMinimal.contains("--json"), aiMinimal.joined(separator: " "))
var aiNoJSON = aiSettings
aiNoJSON.jsonEvents = false
check("关掉事件流后不带 --json",
      !AICodexCommand.firstArguments(settings: aiNoJSON, prompt: "x").contains("--json"))

print("== AI：审查者（DeepSeek）与修复队列 ==")
let reviewSettingsDefault = AIReviewSettings()
check("默认模型是 deepseek-v4-flash", reviewSettingsDefault.model == "deepseek-v4-flash")
check("默认接口地址是 DeepSeek 官方", reviewSettingsDefault.baseURL == "https://api.deepseek.com")
check("没填密钥时算未配置", !reviewSettingsDefault.isConfigured)
check("请求地址归一化：裸域名补 /v1/chat/completions",
      reviewSettingsDefault.chatCompletionsURL == "https://api.deepseek.com/v1/chat/completions",
      reviewSettingsDefault.chatCompletionsURL)
var reviewWithV1 = AIReviewSettings()
reviewWithV1.baseURL = "https://api.deepseek.com/v1/"
check("请求地址归一化：已带 /v1 不重复",
      reviewWithV1.chatCompletionsURL == "https://api.deepseek.com/v1/chat/completions",
      reviewWithV1.chatCompletionsURL)
var reviewFullPath = AIReviewSettings()
reviewFullPath.baseURL = "https://example.com/v1/chat/completions"
check("请求地址归一化：完整路径原样",
      reviewFullPath.chatCompletionsURL == "https://example.com/v1/chat/completions")
var reviewConfigured = AIReviewSettings()
reviewConfigured.apiKey = "sk-test"
check("填了密钥就算配置好了", reviewConfigured.isConfigured)

print("== AI：验收命令判定 ==")
check("解析多行验收命令（忽略空行与注释）",
      Acceptance.commands("""
      # 先跑测试
      ./tests/run.sh

      swift build
      """) == ["./tests/run.sh", "swift build"])
check("空文本没有验收命令", Acceptance.commands("   \n\n").isEmpty)
check("全部退出码 0 才算通过",
      Acceptance.allPassed([AcceptanceResult(command: "a", status: 0, outputTail: ""),
                            AcceptanceResult(command: "b", status: 0, outputTail: "")]))
check("有一条失败就不算通过",
      !Acceptance.allPassed([AcceptanceResult(command: "a", status: 0, outputTail: ""),
                             AcceptanceResult(command: "b", status: 1, outputTail: "boom")]))
check("空列表不算通过（没有验收标准 ≠ 通过）", !Acceptance.allPassed([]))
let acceptanceFailure = Acceptance.failureText([
    AcceptanceResult(command: "ok", status: 0, outputTail: ""),
    AcceptanceResult(command: "fail", status: 1, outputTail: "assertion failed at line 12"),
])
check("失败摘要只列失败的那条", acceptanceFailure.contains("fail") && !acceptanceFailure.contains("ok →"))
check("失败摘要带输出尾部", acceptanceFailure.contains("assertion failed"))

print("== AI：审查请求打包 ==")
var sampleRequest = ReviewRequest()
sampleRequest.requirement = "给 Redis 页加一个「导出所有 key」按钮"
sampleRequest.plan = "1. 加按钮 2. 调用 SCAN"
sampleRequest.roundNotes = ["- 第 1 轮：先看现有 UI 代码", "- 第 2 轮：加了按钮"]
sampleRequest.diff = "diff --git a/Foo.swift b/Foo.swift\n+let x = 1"
sampleRequest.diffStat = " Foo.swift | 2 +-"
sampleRequest.acceptance = [AcceptanceResult(command: "./tests/run.sh", status: 1, outputTail: "1 项失败")]
sampleRequest.materialNotes = "diff 太长已截断"
let reviewUser = ReviewRequestBuilder.userPrompt(sampleRequest)
check("审查请求带需求原文", reviewUser.contains("给 Redis 页加一个「导出所有 key」按钮"))
check("审查请求带每轮自我说明", reviewUser.contains("- 第 2 轮：加了按钮"))
check("审查请求带 diff", reviewUser.contains("+let x = 1"))
check("审查请求带验收结果与失败", reviewUser.contains("./tests/run.sh") && reviewUser.contains("失败"))
check("审查请求带材料说明", reviewUser.contains("diff 太长已截断"))
check("审查请求带计划", reviewUser.contains("1. 加按钮 2. 调用 SCAN"))
check("系统提示要求固定 Markdown 结构",
      ReviewRequestBuilder.systemPrompt().contains("## 必修") && ReviewRequestBuilder.systemPrompt().contains("## 存疑"))
check("系统提示强调「只依据材料判断」",
      ReviewRequestBuilder.systemPrompt().contains("不要臆测"))
var noAcceptanceRequest = ReviewRequest()
noAcceptanceRequest.requirement = "改点什么"
check("没配验收命令时明确警告完成判定不可靠",
      ReviewRequestBuilder.userPrompt(noAcceptanceRequest).contains("完成判定不可靠"))
var checkpointRequest = sampleRequest
checkpointRequest.checkpoint = true
check("中途检查模式写明只回答方向问题",
      ReviewRequestBuilder.userPrompt(checkpointRequest).contains("改动方向还在朝需求走吗"))
let truncated = ReviewRequestBuilder.truncatedDiff(String(repeating: "x", count: 5000), limit: 1000)
check("超长 diff 会被截断并标注", truncated.truncated && truncated.text.count == 1000)
check("不超长时不截断", !ReviewRequestBuilder.truncatedDiff("abc", limit: 1000).truncated)

print("== AI：审查报告解析 ==")
let reportMarkdown = """
## 结论
需要修复 2 处

## 必修
### 1. 空指针风险
- 位置：Sources/Foo.swift:120
- 问题：这里 force unwrap 了可选值
- 证据：diff 里 `let x = y!`
- 建议改法：改成 if let 绑定
- 验收方式：./tests/run.sh 全绿

### 2. 改了需求之外的文件
- 位置：Resources/Info.plist
- 问题：需求没要求动这个文件
- 建议改法：还原该文件
- 验收方式：git diff 里不再出现这个文件

## 建议
- 变量名可以更清楚
- 补一条注释

## 存疑
- 要不要兼容旧格式？
"""
let parsedReport = ReviewReportParser.parse(reportMarkdown)
check("报告被识别", parsedReport.parsed)
check("结论行解析正确", parsedReport.verdict == "需要修复 2 处", parsedReport.verdict)
check("必修项 2 条", parsedReport.mustFix.count == 2, "\(parsedReport.mustFix.count)")
check("必修项标题去掉了编号前缀", parsedReport.mustFix.first?.title == "空指针风险", parsedReport.mustFix.first?.title ?? "")
check("抽出「位置」字段", parsedReport.mustFix.first?.location == "Sources/Foo.swift:120")
check("抽出「验收方式」字段", parsedReport.mustFix.first?.verification.contains("./tests/run.sh") == true)
check("第二条必修也解析到了", parsedReport.mustFix.last?.location == "Resources/Info.plist")
check("建议 2 条", parsedReport.suggestions.count == 2, "\(parsedReport.suggestions.count)")
check("存疑 1 条", parsedReport.questions.count == 1)
check("摘要文案", parsedReport.summary == "必修 2 项 · 建议 2 条 · 存疑 1 条", parsedReport.summary)
let emptyMustFixReport = ReviewReportParser.parse("## 结论\n可以交付\n\n## 必修\n\n## 建议\n- 没有\n")
check("没有必修项时也算解析成功", emptyMustFixReport.parsed && emptyMustFixReport.mustFix.isEmpty)
check("结论为「可以交付」", emptyMustFixReport.verdict == "可以交付")
let unparsable = ReviewReportParser.parse("我想了想，这个代码还行吧。")
check("认不出的格式 parsed=false（由人读原文）", !unparsable.parsed && unparsable.mustFix.isEmpty)
check("认不出时保留原文", unparsable.raw.contains("还行吧"))

let fixPrompt = ReviewFinding.fixPrompt(ReviewFinding(index: 2, title: "越界改文件",
                                                      body: "- 位置：X.swift\n- 问题：不该改",
                                                      location: "X.swift", verification: ""),
                                        acceptance: ["./tests/run.sh"])
check("修复指令强调只修这一条", fixPrompt.contains("只修这一条"))
check("修复指令带上条目编号与标题", fixPrompt.contains("2. 越界改文件"))
check("修复指令带上验收命令", fixPrompt.contains("./tests/run.sh"))
check("修复指令要求 DONE / BLOCKED 信号", fixPrompt.contains("DONE") && fixPrompt.contains("BLOCKED"))

print("== AI：审查者接口 ==")
let reviewBody = ReviewClient.requestBody(settings: reviewConfigured, system: "sys", user: "usr")
let reviewBodyJSON = reviewBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
let reviewMessages = reviewBodyJSON?["messages"] as? [[String: String]]
check("请求体用配置里的模型名", reviewBodyJSON?["model"] as? String == "deepseek-v4-flash")
check("请求体是 system + user 两条消息",
      reviewMessages?.count == 2 && reviewMessages?.first?["role"] == "system"
      && reviewMessages?.last?["role"] == "user")
check("请求体关掉流式", reviewBodyJSON?["stream"] as? Bool == false)
let okReply = Data(#"{"choices":[{"message":{"role":"assistant","content":"结论：可以交付"}}]}"#.utf8)
switch ReviewClient.parseReply(okReply) {
case .success(let content): check("解析正常响应", content.contains("可以交付"))
case .failure(let message): check("解析正常响应", false, message)
}
let errorReply = Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)
switch ReviewClient.parseReply(errorReply) {
case .success: check("接口报错要当失败", false)
case .failure(let message): check("接口报错要当失败", message.contains("Invalid API key"), message)
}
switch ReviewClient.parseReply(Data("not json".utf8)) {
case .success: check("非 JSON 响应要当失败", false)
case .failure(let message): check("非 JSON 响应要当失败", message.contains("不是 JSON"), message)
}
switch ReviewClient.parseReply(Data(#"{"choices":[]}"#.utf8)) {
case .success: check("缺 content 要当失败", false)
case .failure: check("缺 content 要当失败", true)
}

print("== AI：中间产物与 git 材料 ==")
let artifactsRoot = workRoot + "/ai-artifacts"
try? FileManager.default.createDirectory(atPath: artifactsRoot, withIntermediateDirectories: true)
_ = FileTools.write(AIArtifacts.roundsPath(artifactsRoot), "")
AIArtifacts.appendRoundNote(artifactsRoot, round: 1, note: "先读代码")
AIArtifacts.appendRoundNote(artifactsRoot, round: 2, note: "")
AIArtifacts.appendRoundNote(artifactsRoot, round: 3, note: "改完了 a 和 b")
let notesBack = AIArtifacts.roundNotes(artifactsRoot)
check("每轮自我说明只记非空的", notesBack.count == 2, "\(notesBack.count)")
check("自我说明带轮次前缀", notesBack.first?.hasPrefix("- 第 1 轮：") == true, notesBack.first ?? "")
check("中间产物都在 .ai 目录下",
      AIArtifacts.roundsPath("/x").hasSuffix("/.ai/rounds.md")
      && AIArtifacts.reviewReportPath("/x").hasSuffix("/.ai/review-report.md"))
AIArtifacts.reset(artifactsRoot)
check("reset 清掉每轮记录", AIArtifacts.roundNotes(artifactsRoot).isEmpty)

let missingGit = GitDiff.collect(workDir: workRoot + "/no-such-dir-xyz", maxChars: 1000)
check("目录不存在时给出明确错误", missingGit.error.contains("不存在"), missingGit.error)
check("拿不到材料时 diff 为空", missingGit.diff.isEmpty)
// 注意不能用 workRoot：它在 db-manager 仓库里，git 会认得（那样测不到「不是仓库」这条）
let notRepo = GitDiff.collect(workDir: NSTemporaryDirectory(), maxChars: 1000)
check("不是 git 仓库时给出明确错误", notRepo.error.contains("不是 git 仓库"), notRepo.error)

let reviewSettingsLegacy = Data(#"{"ai":{"model":"gpt-6-astra"}}"#.utf8)
let decodedReviewLegacy = try? JSONDecoder().decode(AppSettings.self, from: reviewSettingsLegacy)
check("旧设置文件没有 review 字段也能解出默认值",
      decodedReviewLegacy?.review.model == "deepseek-v4-flash"
      && decodedReviewLegacy?.review.isConfigured == false)
let partialReview = Data(#"{"review":{"apiKey":"sk-x"}}"#.utf8)
let decodedPartialReview = try? JSONDecoder().decode(AppSettings.self, from: partialReview)
check("review 只写了密钥时其余用默认",
      decodedPartialReview?.review.isConfigured == true
      && decodedPartialReview?.review.model == "deepseek-v4-flash")

print("== AI：验收命令自动探测 ==")
let detectRoot = workRoot + "/detect-project"
try? FileManager.default.createDirectory(atPath: detectRoot + "/tests", withIntermediateDirectories: true)
_ = FileTools.write(detectRoot + "/tests/run.sh", "#!/bin/sh\nexit 0\n")
let detectedScript = Acceptance.detect(workDir: detectRoot)
check("探测到项目自己的测试脚本", detectedScript.first?.command == "./tests/run.sh",
      detectedScript.first?.command ?? "（空）")
check("候选带「为什么推荐」的理由", detectedScript.first?.reason.contains("tests/run.sh") == true,
      detectedScript.first?.reason ?? "")

let npmRoot = workRoot + "/detect-npm"
try? FileManager.default.createDirectory(atPath: npmRoot, withIntermediateDirectories: true)
_ = FileTools.write(npmRoot + "/package.json", #"{"name":"x","scripts":{"test":"jest --ci","build":"tsc","lint":"eslint ."}}"#)
let detectedNpm = Acceptance.detect(workDir: npmRoot)
check("npm 项目推荐 npm test", detectedNpm.contains { $0.command == "npm test" },
      detectedNpm.map(\.command).joined(separator: ","))
check("npm test 的理由里带上脚本内容", detectedNpm.first?.reason.contains("jest") == true,
      detectedNpm.first?.reason ?? "")
check("也推荐 build 与 lint", detectedNpm.contains { $0.command == "npm run build" }
      && detectedNpm.contains { $0.command == "npm run lint" })

let npmPlaceholderRoot = workRoot + "/detect-npm-placeholder"
try? FileManager.default.createDirectory(atPath: npmPlaceholderRoot, withIntermediateDirectories: true)
_ = FileTools.write(npmPlaceholderRoot + "/package.json",
                    #"{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}"#)
let detectedPlaceholder = Acceptance.detect(workDir: npmPlaceholderRoot)
check("npm 默认的假 test 脚本不被推荐（它永远失败）",
      !detectedPlaceholder.contains { $0.command == "npm test" },
      detectedPlaceholder.map(\.command).joined(separator: ","))

let swiftRoot = workRoot + "/detect-swift"
try? FileManager.default.createDirectory(atPath: swiftRoot + "/Tests", withIntermediateDirectories: true)
_ = FileTools.write(swiftRoot + "/Package.swift", "// swift-tools-version:5.9\n")
let detectedSwift = Acceptance.detect(workDir: swiftRoot)
check("Swift Package 有 Tests/ 时推荐 swift test",
      detectedSwift.contains { $0.command == "swift test" }, detectedSwift.map(\.command).joined(separator: ","))
check("同时给出保底的 swift build", detectedSwift.contains { $0.command == "swift build" })

let emptyRoot = workRoot + "/detect-empty"
try? FileManager.default.createDirectory(atPath: emptyRoot, withIntermediateDirectories: true)
let detectedEmpty = Acceptance.detect(workDir: emptyRoot)
check("空目录只给一条兜底（并要求有实际改动）",
      detectedEmpty.count == 1 && detectedEmpty.first?.command == "git diff --exit-code",
      detectedEmpty.map(\.command).joined(separator: ","))
check("不存在的目录返回空", Acceptance.detect(workDir: workRoot + "/nope-xyz").isEmpty)
check("通用例子不为空", !Acceptance.commonExamples().isEmpty)

let parsedScripts = Acceptance.packageScripts(#"{"scripts":{"test":"jest","build":"tsc"}}"#)
check("解析 package.json 的 scripts", parsedScripts["test"] == "jest" && parsedScripts["build"] == "tsc")
check("坏 JSON 返回空字典", Acceptance.packageScripts("{oops").isEmpty)
check("没有 scripts 字段返回空字典", Acceptance.packageScripts(#"{"name":"x"}"#).isEmpty)
check("识别 npm 默认占位 test 脚本",
      Acceptance.isPlaceholderTestScript(#"echo "Error: no test specified" && exit 1"#))
check("真的 test 脚本不算占位", !Acceptance.isPlaceholderTestScript("jest --coverage"))

print("== AI：云端任务（codex cloud）==")
let cloudJSON = #"""
{"tasks":[
 {"task_id":"4f9a1c2e-1111-2222-3333-444455556666","instructions":"给 Redis 页加导出按钮",
  "task_status":"completed","created_at":1790347065,"environment_id":"env_abc",
  "head_branch":"main","attempts":2},
 {"taskId":"aaaabbbb-cccc-dddd-eeee-ffff00001111","query":"修一下登录跳转",
  "status":"running","createdAt":1790350000}
],"cursor":null}
"""#
let cloudTasks = AICloud.parseTasks(json: cloudJSON)
check("解析出两条云端任务", cloudTasks.count == 2, "\(cloudTasks.count)")
check("首条字段都对", cloudTasks.first?.id.hasPrefix("4f9a1c2e") == true
      && cloudTasks.first?.title == "给 Redis 页加导出按钮"
      && cloudTasks.first?.status == .completed
      && cloudTasks.first?.environmentID == "env_abc"
      && cloudTasks.first?.branch == "main"
      && cloudTasks.first?.attempts == 2,
      cloudTasks.first?.rawJSON.prefix(80).description ?? "")
check("字段名变体也认（taskId / query / status / createdAt）",
      cloudTasks.last?.title == "修一下登录跳转" && cloudTasks.last?.status == .running)
check("短 ID 取前 8 位", cloudTasks.first?.shortID == "4f9a1c2e", cloudTasks.first?.shortID ?? "")
check("unix 时间戳转成可读时间", cloudTasks.first?.displayCreatedAt.contains("-") == true,
      cloudTasks.first?.displayCreatedAt ?? "")
check("空 tasks 返回空数组", AICloud.parseTasks(json: #"{"tasks":[],"cursor":null}"#).isEmpty)
check("坏 JSON 返回空数组", AICloud.parseTasks(json: "{oops").isEmpty)
check("tasks 不是数组时返回空", AICloud.parseTasks(json: #"{"tasks":"x"}"#).isEmpty)
check("没有 id 的任务被跳过",
      AICloud.parseTasks(json: #"{"tasks":[{"instructions":"没有 id"}]}"#).isEmpty)
check("多行需求被压成一行",
      AICloud.parseTasks(json: #"{"tasks":[{"task_id":"a1","instructions":"第一行\n第二行"}]}"#).first?.title == "第一行 第二行")

check("状态归一：completed / succeeded / finished",
      AICloudStatus.from("completed") == .completed && AICloudStatus.from("SUCCEEDED") == .completed
      && AICloudStatus.from("finished") == .completed)
check("状态归一：failed / error", AICloudStatus.from("failed") == .failed && AICloudStatus.from("error") == .failed)
check("状态归一：running / in_progress",
      AICloudStatus.from("running") == .running && AICloudStatus.from("in_progress") == .running)
check("状态归一：pending / queued",
      AICloudStatus.from("pending") == .pending && AICloudStatus.from("queued") == .pending)
check("状态归一：cancelled", AICloudStatus.from("cancelled") == .cancelled)
check("认不出的状态是 unknown", AICloudStatus.from("whatever") == .unknown && AICloudStatus.from("") == .unknown)
check("结束状态判定", AICloudStatus.completed.isTerminal && AICloudStatus.failed.isTerminal
      && !AICloudStatus.running.isTerminal)

check("从输出里提取任务 ID",
      AICloud.extractTaskID(from: "Created task 4f9a1c2e-1111-2222-3333-444455556666 ok")
      == "4f9a1c2e-1111-2222-3333-444455556666")
check("没有 UUID 时返回 nil", AICloud.extractTaskID(from: "submitted successfully") == nil)

var cloudSettings = AICloudSettings()
check("没填环境 ID 时算未配置", !cloudSettings.isConfigured)
cloudSettings.environmentID = "env_x"
check("填了环境 ID 就算配好了", cloudSettings.isConfigured)
cloudSettings.listLimit = 999
cloudSettings.attempts = 99
check("列表条数被夹到 1–20（接口限制）", cloudSettings.clampedLimit == 20, "\(cloudSettings.clampedLimit)")
check("best-of-N 被夹到 1–5", cloudSettings.clampedAttempts == 5, "\(cloudSettings.clampedAttempts)")
cloudSettings.listLimit = 0
cloudSettings.attempts = 0
check("下界也夹住", cloudSettings.clampedLimit == 1 && cloudSettings.clampedAttempts == 1)
check("本地仓库留空时回落 HOME", cloudSettings.resolvedWorkDir == NSHomeDirectory())
check("云端命令的工作目录切到工具自己的日志目录（躲开 codex 的 error.log 污染）",
      FileTools.isDirectory(AICloudClient.cloudWorkingDirectory))
check("那个目录不在工作区里（不会往仓库里丢垃圾）",
      !AICloudClient.cloudWorkingDirectory.hasPrefix(FileManager.default.currentDirectoryPath + "/"),
      AICloudClient.cloudWorkingDirectory)

let cloudLegacy = try? JSONDecoder().decode(AppSettings.self, from: Data(#"{"ai":{"model":"x"}}"#.utf8))
check("旧设置文件没有 cloud 字段也能解出默认值",
      cloudLegacy?.cloud.environmentID == "" && cloudLegacy?.cloud.attempts == 1
      && cloudLegacy?.cloud.listLimit == 20)
let cloudPartial = try? JSONDecoder().decode(AppSettings.self, from: Data(#"{"cloud":{"environmentID":"env_y"}}"#.utf8))
check("cloud 只写了环境 ID 时其余用默认",
      cloudPartial?.cloud.isConfigured == true && cloudPartial?.cloud.clampedLimit == 20)

print("== AI：模型列表 ==")
let aiCatalogJSON = """
{"models":[
 {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","default_reasoning_level":"low",
  "supported_reasoning_levels":[{"effort":"low","description":"快"},{"effort":"high","description":"深"}],
  "visibility":"list"},
 {"slug":"codex-auto-review","display_name":"Codex Auto Review","default_reasoning_level":"medium",
  "supported_reasoning_levels":[{"effort":"medium","description":"内部"}],"visibility":"hide"},
 {"slug":"gpt-5.5","display_name":"GPT-5.5","default_reasoning_level":"medium",
  "supported_reasoning_levels":[{"effort":"medium","description":"均衡"}],"visibility":"list"}
]}
"""
let aiModels = AIModelCatalog.parse(aiCatalogJSON)
check("解析出两个可见模型", aiModels.count == 2, "\(aiModels.count)")
check("隐藏模型不摆给用户选", !aiModels.contains { $0.slug == "codex-auto-review" })
check("读到推理档位", aiModels.first?.efforts.map(\.effort) == ["low", "high"])
check("读到档位说明", aiModels.first?.efforts.first?.detail == "快")
check("读到默认档", aiModels.first?.resolvedDefaultEffort == "low")
check("标签带展示名和 slug", aiModels.first?.label.contains("GPT-6-Astra") == true
      && aiModels.first?.label.contains("gpt-6-astra") == true)
check("坏 JSON 返回空", AIModelCatalog.parse("{oops").isEmpty)
check("没有 models 字段返回空", AIModelCatalog.parse("{}").isEmpty)
check("缺 display_name 时用 slug 当标签",
      AIModelCatalog.parse(#"{"models":[{"slug":"x"}]}"#).first?.label == "x")

let aiConfigSample = """
model = "gpt-6-astra"
model_reasoning_effort = "high"

[mcp_servers.node_repl]
model = "不该取这个"
"""
check("解析 config.toml 的模型", AIModelCatalog.configuredModel(configText: aiConfigSample) == "gpt-6-astra")
check("解析 config.toml 的推理强度", AIModelCatalog.configuredEffort(configText: aiConfigSample) == "high")
check("只有 section 时解析出空", AIModelCatalog.configuredModel(configText: "[desktop]\nmodel = \"x\"") == "")
check("注释掉的 model 不算", AIModelCatalog.configuredModel(configText: "# model = \"x\"") == "")
check("内置兜底模型列表非空", AIModelCatalog.fallback().count >= 5)

print("== AI：设置兼容与时长文案 ==")
let aiLegacySettings = Data(#"{"mongo":{"adminUser":"u"},"redis":{"port":6380}}"#.utf8)
let aiDecodedLegacy = try? JSONDecoder().decode(AppSettings.self, from: aiLegacySettings)
check("旧设置文件没有 ai 字段也能解出默认值",
      aiDecodedLegacy?.ai.sandbox == AISandbox.workspaceWrite.rawValue && aiDecodedLegacy?.ai.useProxy == true)
check("旧设置里的其它字段不受影响", aiDecodedLegacy?.redis.port == 6380)
let aiPartial = Data(#"{"ai":{"model":"gpt-5.5","useProxy":false}}"#.utf8)
let aiDecodedPartial = try? JSONDecoder().decode(AppSettings.self, from: aiPartial)
check("ai 只写了部分字段时其余用默认",
      aiDecodedPartial?.ai.model == "gpt-5.5" && aiDecodedPartial?.ai.useProxy == false
      && aiDecodedPartial?.ai.sandbox == AISandbox.workspaceWrite.rawValue
      && aiDecodedPartial?.ai.continueDelay == 30)
let aiRoundTrip = AppSettings()
let aiEncoded = try? JSONEncoder().encode(aiRoundTrip)
let aiDecoded = aiEncoded.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
check("设置能原样往返", aiDecoded?.ai.allowNonGit == aiRoundTrip.ai.allowNonGit)

print("== 快捷启动：设置兼容与保存 ==")
check("旧设置没有快捷启动方案时建立默认方案",
      aiDecodedLegacy?.quickLaunchWorkspaces.count == 1
      && aiDecodedLegacy?.quickLaunchWorkspaces[0].appPaths.isEmpty == true)
let legacyLaunchData = Data(#"{"quickLaunchApps":["/Applications/Safari.app","/Applications/Utilities/Terminal.app"]}"#.utf8)
let migratedLaunch = try? JSONDecoder().decode(AppSettings.self, from: legacyLaunchData)
check("旧版应用列表迁移到默认方案",
      migratedLaunch?.quickLaunchWorkspaces[0].appPaths.count == 2
      && migratedLaunch?.selectedQuickLaunchWorkspaceID == migratedLaunch?.quickLaunchWorkspaces[0].id)
var launchSettings = AppSettings()
launchSettings.quickLaunchWorkspaces[0].appPaths = ["/Applications/Safari.app"]
launchSettings.quickLaunchWorkspaces.append(
    QuickLaunchWorkspace(name: "开发", appPaths: ["/Applications/Utilities/Terminal.app"]))
launchSettings.selectedQuickLaunchWorkspaceID = launchSettings.quickLaunchWorkspaces[1].id
let launchEncoded = try? JSONEncoder().encode(launchSettings)
let launchDecoded = launchEncoded.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
check("多个方案及各自应用可保存并恢复",
      launchDecoded?.quickLaunchWorkspaces == launchSettings.quickLaunchWorkspaces)
check("重启后仍选择上次方案",
      launchDecoded?.selectedQuickLaunchWorkspaceID == launchSettings.selectedQuickLaunchWorkspaceID)
check("新设置不再写旧版单组应用字段",
      launchEncoded.flatMap { String(data: $0, encoding: .utf8) }?.contains("quickLaunchApps") == false)

print("== 顶部小组件：设置兼容与保存 ==")
check("默认在屏幕顶部显示小组件", AppSettings().docklet.enabled)
check("默认没有添加任何图标", AppSettings().docklet.appPaths.isEmpty)
check("默认完全不透明",
      AppSettings().docklet.collapsedOpacity == 1 && AppSettings().docklet.expandedOpacity == 1)
check("默认展开宽度 80%、左栏 80%",
      AppSettings().docklet.expandedWidthRatio == 0.8 && AppSettings().docklet.appColumnRatio == 0.8)
check("默认折叠宽度、展开高度与液态玻璃",
      AppSettings().docklet.collapsedWidth == 100
      && AppSettings().docklet.collapsedHeight == 0
      && AppSettings().docklet.expandedHeight == 420
      && AppSettings().docklet.expandedTopGap == 0
      && AppSettings().docklet.collapsedLiquidGlassEnabled
      && AppSettings().docklet.expandedLiquidGlassEnabled)
check("旧设置缺 docklet 字段时用默认值",
      aiDecodedLegacy?.docklet.enabled == true && aiDecodedLegacy?.docklet.appPaths.isEmpty == true)
check("旧设置缺不透明度字段时用默认值",
      aiDecodedLegacy?.docklet.collapsedOpacity == 1 && aiDecodedLegacy?.docklet.expandedOpacity == 1)
check("旧设置缺尺寸字段时用默认值",
      aiDecodedLegacy?.docklet.expandedWidthRatio == 0.8
      && aiDecodedLegacy?.docklet.appColumnRatio == 0.8
      && aiDecodedLegacy?.docklet.collapsedWidth == 100
      && aiDecodedLegacy?.docklet.collapsedHeight == 0
      && aiDecodedLegacy?.docklet.expandedHeight == 420
      && aiDecodedLegacy?.docklet.expandedTopGap == 0
      && aiDecodedLegacy?.docklet.collapsedLiquidGlassEnabled == true
      && aiDecodedLegacy?.docklet.expandedLiquidGlassEnabled == true)
let oldGlassSettings = try? JSONDecoder().decode(
    AppSettings.self, from: Data(#"{"docklet":{"liquidGlassEnabled":false}}"#.utf8))
check("旧版玻璃开关迁移到两种状态",
      oldGlassSettings?.docklet.collapsedLiquidGlassEnabled == false
      && oldGlassSettings?.docklet.expandedLiquidGlassEnabled == false)
let mixedGlassSettings = try? JSONDecoder().decode(
    AppSettings.self,
    from: Data(#"{"docklet":{"liquidGlassEnabled":false,"collapsedLiquidGlassEnabled":true}}"#.utf8))
check("新玻璃设置优先于旧开关", mixedGlassSettings?.docklet.collapsedLiquidGlassEnabled == true
      && mixedGlassSettings?.docklet.expandedLiquidGlassEnabled == false)
var dockletSettings = AppSettings()
dockletSettings.docklet.enabled = false
dockletSettings.docklet.collapsedOpacity = 0.35
dockletSettings.docklet.expandedOpacity = 0.7
dockletSettings.docklet.expandedWidthRatio = 0.55
dockletSettings.docklet.appColumnRatio = 0.45
dockletSettings.docklet.collapsedWidth = 180
dockletSettings.docklet.collapsedHeight = 52
dockletSettings.docklet.expandedHeight = 560
dockletSettings.docklet.expandedTopGap = 36
dockletSettings.docklet.collapsedLiquidGlassEnabled = false
dockletSettings.docklet.expandedLiquidGlassEnabled = true
dockletSettings.docklet.appPaths = ["/Applications/Safari.app", "/Applications/Utilities/Terminal.app"]
let dockletEncoded = try? JSONEncoder().encode(dockletSettings)
let dockletDecoded = dockletEncoded.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
check("图标列表与开关可保存并恢复", dockletDecoded?.docklet == dockletSettings.docklet)
check("图标顺序原样保留", dockletDecoded?.docklet.appPaths.first == "/Applications/Safari.app")
check("不透明度可保存并恢复",
      dockletDecoded?.docklet.collapsedOpacity == 0.35 && dockletDecoded?.docklet.expandedOpacity == 0.7)
check("展开宽度与分栏比例可保存并恢复",
      dockletDecoded?.docklet.expandedWidthRatio == 0.55 && dockletDecoded?.docklet.appColumnRatio == 0.45)
check("折叠宽度、展开高度和玻璃开关可保存并恢复",
      dockletDecoded?.docklet.collapsedWidth == 180
      && dockletDecoded?.docklet.collapsedHeight == 52
      && dockletDecoded?.docklet.expandedHeight == 560
      && dockletDecoded?.docklet.expandedTopGap == 36
      && dockletDecoded?.docklet.collapsedLiquidGlassEnabled == false
      && dockletDecoded?.docklet.expandedLiquidGlassEnabled == true)
check("新设置不再写旧玻璃开关字段",
      dockletEncoded.flatMap { String(data: $0, encoding: .utf8) }?
        .contains("\"liquidGlassEnabled\"") == false)
check("docklet 会写进设置文件",
      dockletEncoded.flatMap { String(data: $0, encoding: .utf8) }?.contains("\"docklet\"") == true)
check("越界的不透明度被夹回区间",
      DockletSettings.clampOpacity(9) == 1
      && DockletSettings.clampOpacity(0) == DockletSettings.minOpacity
      && DockletSettings.clampOpacity(-3) == DockletSettings.minOpacity
      && DockletSettings.clampOpacity(.nan) == 1)
check("越界的尺寸比例被夹回区间",
      DockletSettings.clamp(2, to: DockletSettings.widthRatioRange) == 1
      && DockletSettings.clamp(0.1, to: DockletSettings.widthRatioRange) == 0.4
      && DockletSettings.clamp(0.9, to: DockletSettings.appColumnRatioRange) == 0.8
      && DockletSettings.clamp(0, to: DockletSettings.appColumnRatioRange) == 0.2
      && DockletSettings.clamp(.nan, to: DockletSettings.widthRatioRange) == 1)
let columnWidths = dockletSettings.docklet.columnWidths(totalWidth: 600)
check("左右分栏宽度始终填满展开面板并留出分隔线",
      abs(columnWidths.left + columnWidths.right - 599) < 0.001
      && columnWidths.left >= 160 && columnWidths.right >= 100)
var narrowDocklet = DockletSettings()
narrowDocklet.appColumnRatio = 0.8
let narrowColumns = narrowDocklet.columnWidths(totalWidth: 320)
check("窄面板不会把右栏挤没", narrowColumns.right >= 100)
check("展开宽度与左右边缘间隙对应",
      AppSettings().docklet.expandedWidth(for: 1000) == 800
      && AppSettings().docklet.expandedSideGap(for: 1000) == 100)
var fullWidthDocklet = DockletSettings()
fullWidthDocklet.expandedWidthRatio = 1
check("展开占满屏幕时左右间隙为零", fullWidthDocklet.expandedSideGap(for: 1000) == 0)
let handEditedDocklet = try? JSONDecoder().decode(
    AppSettings.self,
    from: Data(#"{"docklet":{"collapsedOpacity":9.5,"expandedOpacity":-2,"expandedWidthRatio":9,"appColumnRatio":0.01,"collapsedWidth":900,"collapsedHeight":300,"expandedHeight":80,"expandedTopGap":300}}"#.utf8))
check("手改设置文件里的越界值也能夹回来",
      handEditedDocklet?.docklet.collapsedOpacity == 1
      && handEditedDocklet?.docklet.expandedOpacity == DockletSettings.minOpacity
      && handEditedDocklet?.docklet.expandedWidthRatio == 1
      && handEditedDocklet?.docklet.appColumnRatio == 0.2
      && handEditedDocklet?.docklet.collapsedWidth == DockletSettings.collapsedWidthRange.upperBound
      && handEditedDocklet?.docklet.collapsedHeight == DockletSettings.collapsedHeightRange.upperBound
      && handEditedDocklet?.docklet.expandedHeight == DockletSettings.expandedHeightRange.lowerBound
      && handEditedDocklet?.docklet.expandedTopGap == DockletSettings.expandedTopGapRange.upperBound)

check("时长文案：59 秒", AIDevRunner.durationText(59) == "59 秒")
check("时长文案：1 分钟", AIDevRunner.durationText(60) == "1 分钟")
check("时长文案：1 小时", AIDevRunner.durationText(3600) == "1 小时")
check("时长文案：1 小时 1 分", AIDevRunner.durationText(3660) == "1 小时 1 分")
check("时长文案不出现负数", AIDevRunner.durationText(-5) == "0 秒")
check("看门狗用固定文件名（豆包脚本的完成标记沿用）",
      AIDevRunner.doneFlagName == ".codex_done" && AIDevRunner.logFileName.hasSuffix(".log"))

print("== 域名解析：阿里云签名 ==")
// 官方「签名方法」文档里的那个例子。参数要按**字典序**排，而且要**编码两次**
// —— 时间戳里的 `:` 第一次变 `%3A`、第二次变 `%253A`，这是最容易搞错的地方。
let signParams = [
    "Format": "XML",
    "AccessKeyId": "testid",
    "Action": "DescribeDomainRecords",
    "SignatureMethod": "HMAC-SHA1",
    "DomainName": "example.com",
    "SignatureNonce": "f59ed6a9-83fc-473b-9cc6-99c95df3856e",
    "SignatureVersion": "1.0",
    "Version": "2015-01-09",
    "Timestamp": "2016-03-24T16:41:54Z",
]
check("percentEncode：空格编成 %20，~ 不动，/ 编成 %2F",
      AliyunDNS.percentEncode("a b~c/d") == "a%20b~c%2Fd")
check("percentEncode：中文按 UTF-8 逐字节编码",
      AliyunDNS.percentEncode("证书") == "%E8%AF%81%E4%B9%A6")
check("规范化查询串按参数名字典序",
      AliyunDNS.canonicalQuery(["b": "2", "a": "1"]) == "a=1&b=2")
check("StringToSign 与官方文档示例完全一致",
      AliyunDNS.stringToSign(params: signParams)
      == "GET&%2F&AccessKeyId%3Dtestid%26Action%3DDescribeDomainRecords%26DomainName%3Dexample.com"
      + "%26Format%3DXML%26SignatureMethod%3DHMAC-SHA1"
      + "%26SignatureNonce%3Df59ed6a9-83fc-473b-9cc6-99c95df3856e%26SignatureVersion%3D1.0"
      + "%26Timestamp%3D2016-03-24T16%253A41%253A54Z%26Version%3D2015-01-09")
// 期望值由 openssl / python 独立算出来，不是拿自己的实现对自己
check("签名 = Base64(HMAC-SHA1(secret + \"&\", StringToSign))",
      AliyunDNS.signature(secret: "testsecret", params: signParams) == "uRpHwaSEt3J+6KQD//svCh/x+pI=")
check("时间戳是 UTC 的 ISO8601",
      AliyunDNS.timestamp(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")

print("== 域名解析：响应解析与本地校验 ==")
let dnsDomainsJSON = Data(#"{"TotalCount":1,"Domains":{"Domain":[{"DomainName":"example.com","DomainId":"123","RecordCount":7,"VersionName":"免费版"}]}}"#.utf8)
let dnsDomainsObject = (try? JSONSerialization.jsonObject(with: dnsDomainsJSON)) as? [String: Any] ?? [:]
let dnsDomains = AliyunDNS.parseDomains(dnsDomainsObject)
check("解析域名列表", dnsDomains.first?.name == "example.com")
check("域名带记录条数与版本名",
      dnsDomains.first?.recordCount == 7 && dnsDomains.first?.versionName == "免费版")

let dnsRecordsJSON = Data(#"{"TotalCount":2,"DomainRecords":{"Record":[{"RecordId":"1","RR":"www","Type":"A","Value":"1.2.3.4","TTL":600,"Line":"default","Status":"ENABLE"},{"RecordId":"2","RR":"_acme-challenge","Type":"TXT","Value":"token-abc","TTL":"600","Line":"default","Status":"DISABLE"}]}}"#.utf8)
let dnsRecordsObject = (try? JSONSerialization.jsonObject(with: dnsRecordsJSON)) as? [String: Any] ?? [:]
let dnsRecords = AliyunDNS.parseRecords(dnsRecordsObject)
check("解析解析记录", dnsRecords.count == 2)
check("字符串型的 TTL 也吃得下", dnsRecords.last?.ttl == 600)
check("DISABLE 算已暂停", dnsRecords.last?.enabled == false)
check("ENABLE 的记录带出类型与值",
      dnsRecords.first?.type == "A" && dnsRecords.first?.value == "1.2.3.4")
check("fqdn 把 @ 还原成主域名",
      DNSRecord(recordId: "1", domainName: "example.com", rr: "@").fqdn == "example.com"
      && DNSRecord(recordId: "1", domainName: "example.com", rr: "ww").fqdn == "ww.example.com")
// 只给了单个对象（不是数组）也要认
let singleRecordJSON = Data(#"{"DomainRecords":{"Record":{"RecordId":"9","RR":"a","Type":"A","Value":"1.1.1.1"}}}"#.utf8)
let singleRecordObject = (try? JSONSerialization.jsonObject(with: singleRecordJSON)) as? [String: Any] ?? [:]
check("只有一条记录（对象而非数组）也能解析",
      AliyunDNS.parseRecords(singleRecordObject).first?.recordId == "9")

let dnsService = DNSService(settings: DNSSettings())
check("A 记录必须是 IPv4",
      dnsService.validate(rr: "www", type: "A", value: "not-an-ip", priority: "") != nil)
check("A 记录的合法值通过",
      dnsService.validate(rr: "www", type: "A", value: "1.2.3.4", priority: "") == nil)
check("A 记录拒绝越界的 IPv4",
      dnsService.validate(rr: "www", type: "A", value: "1.2.3.999", priority: "") != nil)
check("主机记录不能为空",
      dnsService.validate(rr: "   ", type: "A", value: "1.2.3.4", priority: "") != nil)
check("主机记录不许写全域名（只填最左边一段）",
      dnsService.validate(rr: "www.example.com", type: "A", value: "1.2.3.4", priority: "") != nil)
check("下划线开头的验证记录放行",
      dnsService.validate(rr: "_acme-challenge", type: "TXT", value: "token", priority: "") == nil)
check("MX 必须填优先级",
      dnsService.validate(rr: "@", type: "MX", value: "mail.example.com", priority: "") != nil)
check("MX 优先级合法就通过",
      dnsService.validate(rr: "@", type: "MX", value: "mail.example.com", priority: "10") == nil)
check("MX 优先级越界也拦住",
      dnsService.validate(rr: "@", type: "MX", value: "mail.example.com", priority: "99") != nil)
check("TXT 的值可以是任意文本",
      dnsService.validate(rr: "_acme-challenge", type: "TXT", value: "任意 token", priority: "") == nil)

check("只在 MX / SRV 上要优先级",
      DNSRecordTypes.needsPriority("MX") && DNSRecordTypes.needsPriority("SRV")
      && !DNSRecordTypes.needsPriority("A"))

check("签名错误的提示点出 Secret",
      AliyunDNS.describeError(code: "SignatureDoesNotMatch", message: "x").contains("Secret"))
check("权限错误提示挂 DNS 策略",
      AliyunDNS.describeError(code: "Forbidden.RAM", message: "x").contains("AliyunDNSFullAccess"))
let unknownError = AliyunDNS.describeError(code: "SomethingBrandNew", message: "原始细节")
check("认不出的错误码连原始信息一起带上",
      unknownError.contains("SomethingBrandNew") && unknownError.contains("原始细节"))

print("== 服务器管理：旧设置合并成「配置」 ==")
// 很老的版本把阿里云 Key 存在 acme 下（那时它只给证书的 DNS-01 用）
let legacyACMEKey = Data(#"{"acme":{"email":"a@b.c","aliKey":"LTAIold","aliSecret":"secretold"}}"#.utf8)
let acmeMigrated = try? JSONDecoder().decode(AppSettings.self, from: legacyACMEKey)
check("证书页的老 AccessKey 进入配置的阿里云账号",
      acmeMigrated?.dns.aliKey == "LTAIold" && acmeMigrated?.dns.aliSecret == "secretold")
check("搬家不影响证书页其它字段", acmeMigrated?.acme.email == "a@b.c")
check("acme 里已经删掉的字段不再出现（解码不再报错）",
      acmeMigrated?.acme.bin == "" && acmeMigrated?.acme.keylength == "ec-256")

// 旧版多账号 → 每个阿里云账号一份配置（旧设置里的 bt / 宝塔字段直接忽略）
let legacyMulti = Data(#"""
{"dns":{"credentials":[{"id":"d1","name":"金口译言","aliKey":"LTAI-jk","aliSecret":"s-jk"},{"id":"d2","name":"其他","aliKey":"LTAI-other","aliSecret":"s-other"}]},
 "bt":{"panels":[{"id":"p1","name":"金口译言","baseURL":"https://jk","apiKey":"k-jk"}],"selectedPanelID":"p1"},
 "acme":{"email":"ops@example.com"}}
"""#.utf8)
let migrated = try? JSONDecoder().decode(AppSettings.self, from: legacyMulti)
check("旧版多账号 → 每个账号一份配置",
      migrated?.opsProfiles.count == 2
      && migrated?.opsProfiles.first?.dns.aliKey == "LTAI-jk"
      && migrated?.opsProfiles.last?.dns.aliKey == "LTAI-other",
      "\(migrated?.opsProfiles.map { $0.dns.aliKey } ?? [])")
check("账号名沿用为配置名", migrated?.opsProfiles.first?.name == "金口译言",
      migrated?.opsProfiles.first?.name ?? "nil")
check("证书设置复制到每份配置",
      migrated?.opsProfiles.allSatisfy { $0.acme.email == "ops@example.com" } == true)
check("迁移后选中的配置一定存在",
      migrated.map { profiles in
          profiles.opsProfiles.contains(where: { $0.id == profiles.selectedOpsProfileID })
      } == true)

// 老的单账号也能读进来
let legacySingle = Data(#"{"dns":{"aliKey":"old-dns","aliSecret":"old-secret"},"bt":{"baseURL":"https://old-panel","apiKey":"old-api","allowInsecure":false}}"#.utf8)
let single = try? JSONDecoder().decode(AppSettings.self, from: legacySingle)
check("旧单账号进入默认配置",
      single?.dns.aliKey == "old-dns" && single?.dns.aliSecret == "old-secret")

print("== 服务器管理：多配置切换与保存 ==")
var multi = AppSettings()
multi.dns.aliKey = "ali-a"
multi.dns.aliSecret = "sec-a"
multi.addOpsProfile()
multi.dns.aliKey = "ali-b"
multi.dns.aliSecret = "sec-b"
let encodedMulti = try? JSONEncoder().encode(multi)
let restoredMulti = encodedMulti.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
check("多份配置能往返保存", restoredMulti?.opsProfiles.count == 2)
check("每份配置各记着自己的账号",
      restoredMulti?.opsProfiles.first?.dns.aliKey == "ali-a"
          && restoredMulti?.opsProfiles.last?.dns.aliKey == "ali-b")
check("激活的配置也存得下来",
      restoredMulti?.selectedOpsProfileID == restoredMulti?.opsProfiles.last?.id)
var switched = restoredMulti
switched?.selectedOpsProfileID = restoredMulti?.opsProfiles.first?.id ?? ""
check("切配置时域名解析跟着切", switched?.dns.aliKey == "ali-a")
switched?.selectedOpsProfileID = restoredMulti?.opsProfiles.last?.id ?? ""
check("切到另一份又换回来", switched?.dns.aliKey == "ali-b")
switched?.removeSelectedOpsProfile()
check("删掉当前配置后自动选剩下的",
      switched?.opsProfiles.count == 1 && switched?.dns.aliKey == "ali-a")
switched?.removeSelectedOpsProfile()
check("最后一份配置删不掉", switched?.opsProfiles.count == 1)

// 旧格式里失效的 selectedCredentialID、以及旧 bt（宝塔）段，都不再影响解码
let incompleteAccounts = Data(#"{"dns":{"credentials":[{"id":"dns-1","aliKey":"partial"}],"selectedCredentialID":"gone"},"bt":{"panels":[{"id":"bt-1","baseURL":"https://panel"}],"selectedPanelID":"gone"}}"#.utf8)
let incompleteLoaded = try? JSONDecoder().decode(AppSettings.self, from: incompleteAccounts)
check("缺少可选字段的账号仍可加载", incompleteLoaded?.dns.aliKey == "partial")
check("旧 bt（宝塔）段被忽略，只按阿里云账号生成配置",
      incompleteLoaded?.opsProfiles.count == 1)

// MARK: 剪贴板历史

print("== 剪贴板历史：2 MB 裁剪、文本截断与 Redis 固化 ==")

// 单条截断：按 UTF-8 字节切，不会把中文切成半个字
let clipLong = String(repeating: "剪贴板", count: 200)      // 每个字 3 字节
let clipClamped = ClipboardHistory.clampText(clipLong, maxBytes: 10)
check("单条按字节截断", clipClamped.truncated && clipClamped.text.utf8.count <= 10)
check("截断处不切坏多字节字符", clipClamped.text == String(clipLong.prefix(3)))
check("没超上限就不动它", ClipboardHistory.clampText("短文本", maxBytes: 100).text == "短文本")

// 2 MB 上限：条目按「最新在前」，超了从最旧的开始丢
var clipEntries: [ClipboardEntry] = []
for index in 0..<60 {
    clipEntries.append(ClipboardEntry(text: String(repeating: "x", count: 40000) + "#\(index)",
                                      createdAt: Date().addingTimeInterval(Double(-index))))
}
let clipFitted = ClipboardHistory.fit(clipEntries, maxBytes: 1_000_000)
check("超出上限时丢最旧的", clipFitted.count < clipEntries.count
      && clipFitted.first?.id == clipEntries.first?.id, "保留 \(clipFitted.count) 条")
check("裁剪后编码不超过上限",
      ClipboardHistory.encode(clipFitted).utf8.count <= 1_000_000,
      "\(ClipboardHistory.encode(clipFitted).utf8.count) 字节")
check("被丢掉的是末尾那几条", !clipFitted.contains { $0.id == clipEntries.last?.id })
check("默认上限就是 2 MB", ClipboardHistory.maxFileBytes == 2 * 1024 * 1024)

// 去重与顺序
let clipOlder = ClipboardEntry(text: "重复内容", createdAt: Date(timeIntervalSince1970: 100))
let clipNewer = ClipboardEntry(text: "重复内容", createdAt: Date(timeIntervalSince1970: 200))
let clipOther = ClipboardEntry(text: "别的", createdAt: Date(timeIntervalSince1970: 150))
let clipMerged = ClipboardHistory.merge([[clipOlder, clipOther], [clipNewer]])
check("同一段文本只留最新的那条", clipMerged.first?.id == clipNewer.id)
check("合并后按时间倒序", clipMerged.map(\.text) == ["重复内容", "别的"])
let clipAdded = ClipboardHistory.add("  hello  ", to: [ClipboardEntry(text: "hello", createdAt: clipOlder.createdAt)])
check("重复内容顶到最前且不重复", clipAdded.count == 1 && clipAdded.first?.text == "hello")
check("纯空白不记", ClipboardHistory.add("  \n\t ", to: []) == [])

// 编解码与文件
let clipRoundTrip = ClipboardHistory.decode(ClipboardHistory.encode(Array(clipEntries.prefix(3))))
check("编码解码能往返", clipRoundTrip.count == 3 && clipRoundTrip.first?.text == clipEntries.first?.text)
let clipDelta = abs((clipRoundTrip.first?.createdAt.timeIntervalSince1970 ?? 0)
                    - (clipEntries.first?.createdAt.timeIntervalSince1970 ?? 0))
check("时间戳精度到毫秒", clipDelta < 0.001, "\(clipDelta)")
check("被截断/改成一行一条的文件也能救回来",
      ClipboardHistory.decode("{\"text\":\"a\"}\n{\"text\":\"b\"}").count == 2)
check("空文件读出空历史", ClipboardHistory.decode("").isEmpty)

let clipPath = workRoot + "/clipboard.json"
try? Data(ClipboardHistory.encode(Array(clipEntries.prefix(5))).utf8).write(to: URL(fileURLWithPath: clipPath))
check("从固化文件读回 5 条", ClipboardHistory.readFile(clipPath).count == 5)

// Redis：读写往返（读得快的那一层），以及「Redis 挂了只用文件」的兜底
// 前面的假服务器在中途就 stop 掉了（它还要验证「停止后端口关闭」），这里另起一个。
let clipFake = FakeRedisServer(port: 0)
do {
    try clipFake.start()
} catch {
    print("无法启动剪贴板用例的假 Redis：\(error.localizedDescription)")
    exit(2)
}
let clipPort = clipFake.boundPort
Thread.sleep(forTimeInterval: 0.3)
let clipTarget = ClipboardRedisTarget(host: "127.0.0.1", port: clipPort, password: "")
let clipRedisEntries = Array(clipEntries.prefix(5))
let clipWriteNote = ClipboardHistory.writeRedis(clipTarget, entries: clipRedisEntries)
check("整份历史写进 Redis", clipWriteNote.contains("已同步"), clipWriteNote)
let clipFromRedis = ClipboardHistory.readRedis(clipTarget)
check("从 Redis 读回（读得快就是读它）",
      clipFromRedis?.count == 5 && clipFromRedis?.first?.id == clipRedisEntries.first?.id)
let clipLoad = ClipboardHistory.load(filePath: clipPath, redis: clipTarget)
check("载入时文件与 Redis 合并去重", clipLoad.entries.count == 5, clipLoad.note)
let clipOffline = ClipboardHistory.load(filePath: clipPath,
                                       redis: ClipboardRedisTarget(host: "127.0.0.1", port: 1, password: ""))
check("Redis 连不上时只用本地文件", clipOffline.entries.count == 5 && clipOffline.note.contains("读不到"))
check("没有历史时也能干净往返",
      ClipboardHistory.writeRedis(clipTarget, entries: []).contains("已同步")
      && ClipboardHistory.readRedis(clipTarget)?.isEmpty == true)
clipFake.stop()

// 设置项：旧配置文件（没有这两个键）要能读出来
let clipLegacy = Data(#"{"mongo":{"port":27017}}"#.utf8)
let clipLegacyLoaded = try? JSONDecoder().decode(AppSettings.self, from: clipLegacy)
check("旧设置文件默认开启剪贴板记录", clipLegacyLoaded?.clipboard.enabled == true)
check("旧设置文件默认不自动启动服务",
      clipLegacyLoaded?.startup.autoStartMongo == false && clipLegacyLoaded?.startup.autoStartRedis == false)
check("开关能往返保存", {
    var settings = AppSettings()
    settings.clipboard.enabled = false
    settings.startup.autoStartRedis = true
    guard let data = try? JSONEncoder().encode(settings),
          let restored = try? JSONDecoder().decode(AppSettings.self, from: data) else { return false }
    return restored.clipboard.enabled == false && restored.startup.autoStartRedis
        && restored.startup.autoStartMongo == false
}())

print("")
print(failures == 0 ? "全部通过：\(checks) 项" : "失败 \(failures)/\(checks) 项")
exit(failures == 0 ? 0 : 1)
