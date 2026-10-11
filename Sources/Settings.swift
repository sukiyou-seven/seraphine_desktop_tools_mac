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

struct QuickLaunchWorkspace: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var appPaths: [String]

    init(name: String, appPaths: [String] = []) {
        id = UUID().uuidString
        self.name = name
        self.appPaths = appPaths
    }
}

private enum LegacyQuickLaunchKey: String, CodingKey {
    case quickLaunchApps
}

private enum LegacyDockletKey: String, CodingKey {
    case liquidGlassEnabled
}

/// 屏幕顶部「小组件」（刘海条）的配置。
///
/// 刻意只依赖 Foundation：窗口与界面在 `Docklet.swift` / `DockletView.swift` 里，
/// 这份配置则能被无 GUI 的自测程序直接编解码验证。
struct DockletSettings: Codable, Equatable {
    /// 是否在屏幕顶部显示小组件。
    var enabled = true
    /// 用户添加的应用图标（.app 路径，按添加顺序排列）。
    var appPaths: [String] = []
    /// 折叠态（刘海条）宽度，单位为屏幕点。
    var collapsedWidth = 100.0
    /// 0 表示沿用系统菜单栏高度；设置后使用指定的屏幕点数。
    var collapsedHeight = 0.0
    /// 展开态高度，单位为屏幕点。
    var expandedHeight = 420.0
    /// 展开态与屏幕顶边的距离，单位为屏幕点。
    var expandedTopGap = 0.0
    /// 折叠态（顶部那一小条）的不透明度，`opacityRange`。
    var collapsedOpacity = 1.0
    /// 展开态（大盒子）底色的不透明度，`opacityRange`。内容文字/图标始终不透明。
    var expandedOpacity = 1.0
    /// 展开态宽度占屏幕宽度的比例，`widthRatioRange`。
    var expandedWidthRatio = 0.8
    /// 展开态左栏（应用图标）占展开宽度的比例，`appColumnRatioRange`；右栏拿剩下部分。
    var appColumnRatio = 0.8
    /// 两态分别控制系统液态玻璃；旧系统仍显示深色底板。
    var collapsedLiquidGlassEnabled = true
    var expandedLiquidGlassEnabled = true

    // MARK: 各滑块的取值区间

    /// 不透明度下限：留一点点，面板才不会彻底「摸不着」。
    static let minOpacity = 0.05
    static let opacityRange: ClosedRange<Double> = minOpacity...1
    static let collapsedWidthRange: ClosedRange<Double> = 70...500
    static let collapsedHeightRange: ClosedRange<Double> = 20...100
    static let expandedHeightRange: ClosedRange<Double> = 240...850
    static let expandedTopGapRange: ClosedRange<Double> = 0...120
    /// 展开宽度：太窄塞不下两栏，太宽不如直接用主窗口。
    static let widthRatioRange: ClosedRange<Double> = 0.4...1
    /// 左右分栏：两边都得留出能用的宽度。
    static let appColumnRatioRange: ClosedRange<Double> = 0.2...0.8

    /// 把任意数值夹到区间里（设置文件被手改过也不至于让面板消失或挤成一团）。
    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.upperBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func clampOpacity(_ value: Double) -> Double {
        clamp(value, to: opacityRange)
    }

    func expandedWidth(for screenWidth: Double) -> Double {
        min(screenWidth, max(320, screenWidth * Self.clamp(expandedWidthRatio,
                                                            to: Self.widthRatioRange))).rounded()
    }

    func expandedSideGap(for screenWidth: Double) -> Double {
        max(0, (screenWidth - expandedWidth(for: screenWidth)) / 2)
    }

    /// 分栏宽度以展开面板的实际宽度计算；留出分隔线和两栏的最小可用空间。
    static func columnWidthRange(totalWidth: Double) -> ClosedRange<Double> {
        let available = max(2, totalWidth - 1)
        let minLeft = min(160, available / 2)
        let minRight = min(100, available / 2)
        return minLeft...(available - minRight)
    }

    func columnWidths(totalWidth: Double) -> (left: Double, right: Double) {
        let available = max(2, totalWidth - 1)
        let left = Self.clamp(available * Self.clamp(appColumnRatio, to: Self.appColumnRatioRange),
                              to: Self.columnWidthRange(totalWidth: totalWidth))
        return (left, available - left)
    }

    init() {}

    /// 宽松解码：缺字段就用默认值，旧设置文件也能读进来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        appPaths = try container.decodeIfPresent([String].self, forKey: .appPaths) ?? appPaths
        if let value = try container.decodeIfPresent(Double.self, forKey: .collapsedWidth) {
            collapsedWidth = Self.clamp(value, to: Self.collapsedWidthRange)
        }
        if let value = try container.decodeIfPresent(Double.self, forKey: .collapsedHeight) {
            collapsedHeight = value == 0 ? 0 : Self.clamp(value, to: Self.collapsedHeightRange)
        }
        if let value = try container.decodeIfPresent(Double.self, forKey: .expandedHeight) {
            expandedHeight = Self.clamp(value, to: Self.expandedHeightRange)
        }
        if let value = try container.decodeIfPresent(Double.self, forKey: .expandedTopGap) {
            expandedTopGap = Self.clamp(value, to: Self.expandedTopGapRange)
        }
        if let value = try container.decodeIfPresent(Double.self, forKey: .collapsedOpacity) {
            collapsedOpacity = Self.clamp(value, to: Self.opacityRange)
        }
        if let value = try container.decodeIfPresent(Double.self, forKey: .expandedOpacity) {
            expandedOpacity = Self.clamp(value, to: Self.opacityRange)
        }
        if let value = try container.decodeIfPresent(Double.self, forKey: .expandedWidthRatio) {
            expandedWidthRatio = Self.clamp(value, to: Self.widthRatioRange)
        }
        if let value = try container.decodeIfPresent(Double.self, forKey: .appColumnRatio) {
            appColumnRatio = Self.clamp(value, to: Self.appColumnRatioRange)
        }
        let legacy = try decoder.container(keyedBy: LegacyDockletKey.self)
        let previousGlassSetting = try legacy.decodeIfPresent(Bool.self, forKey: .liquidGlassEnabled)
        collapsedLiquidGlassEnabled = try container.decodeIfPresent(Bool.self,
                                                                   forKey: .collapsedLiquidGlassEnabled)
            ?? previousGlassSetting ?? collapsedLiquidGlassEnabled
        expandedLiquidGlassEnabled = try container.decodeIfPresent(Bool.self,
                                                                  forKey: .expandedLiquidGlassEnabled)
            ?? previousGlassSetting ?? expandedLiquidGlassEnabled
    }
}

/// 剪贴板历史的开关。
///
/// 只留一个「记不记」：条数上限、2 MB 文件上限这些都是固定规则（见 `ClipboardHistory`），
/// 不开放给用户乱调 —— 调坏了只会让历史莫名其妙地丢东西。
struct ClipboardSettings: Codable, Equatable {
    /// 是否记录（关掉只是不再记新的，已有历史照常保留）。
    var enabled = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
    }
}

/// 「打开本软件后自动启动」的开关。
///
/// 刻意**不**注册系统级开机自启（不写 LaunchAgent、不进「登录项」）：
/// 只在你打开 Seraphim 之后，按这里的勾选把服务拉起来；已经在运行就跳过。
struct StartupSettings: Codable, Equatable {
    var autoStartMongo = false
    var autoStartRedis = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoStartMongo = try container.decodeIfPresent(Bool.self, forKey: .autoStartMongo) ?? autoStartMongo
        autoStartRedis = try container.decodeIfPresent(Bool.self, forKey: .autoStartRedis) ?? autoStartRedis
    }
}

// MARK: - 服务器运维配置

/// 一套「服务器管理」配置：**一个**阿里云账号 + 一套证书设置。
///
/// 「域名解析」「证书」两页共用同一份配置 —— 顶部切一次配置，
/// 两页一起切（解析用哪个账号、证书用哪个账号，都跟着走）。
struct OpsProfile: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = ""
    /// 阿里云云解析账号（证书的 DNS-01 验证也用它）
    var dns = DNSSettings()
    /// 证书（acme.sh）设置
    var acme = ACMESettings()

    init(id: String = UUID().uuidString, name: String = "",
         dns: DNSSettings = DNSSettings(),
         acme: ACMESettings = ACMESettings()) {
        self.id = id
        self.name = name
        self.dns = dns
        self.acme = acme
    }

    /// 宽松解码：缺字段就用默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        dns = try container.decodeIfPresent(DNSSettings.self, forKey: .dns) ?? dns
        acme = try container.decodeIfPresent(ACMESettings.self, forKey: .acme) ?? acme
    }

    /// 下拉里显示的标签：优先用名字，其次用 AccessKey 后 4 位。
    var label: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        let key = dns.aliKey.trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? "新配置" : "阿里云 ****\(key.suffix(4))"
    }
}

struct AppSettings: Codable {
    var mongo = MongoSettings()
    var redis = RedisSettings()
    var mysql = MySQLSettings()
    var ai = AIDevSettings()
    var review = AIReviewSettings()
    var cloud = AICloudSettings()
    /// 「服务器运维」的配置列表（域名解析 / 证书 / 宝塔面板共用）。
    var opsProfiles: [OpsProfile] = []
    var selectedOpsProfileID = ""
    var quickLaunchWorkspaces = [QuickLaunchWorkspace(name: "默认方案")]
    var selectedQuickLaunchWorkspaceID = ""
    var docklet = DockletSettings()
    var clipboard = ClipboardSettings()
    var startup = StartupSettings()

    init() {
        opsProfiles = [OpsProfile(name: "默认配置")]
        selectedOpsProfileID = opsProfiles[0].id
        selectedQuickLaunchWorkspaceID = quickLaunchWorkspaces[0].id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mongo = try container.decodeIfPresent(MongoSettings.self, forKey: .mongo) ?? mongo
        redis = try container.decodeIfPresent(RedisSettings.self, forKey: .redis) ?? redis
        mysql = try container.decodeIfPresent(MySQLSettings.self, forKey: .mysql) ?? mysql
        ai = try container.decodeIfPresent(AIDevSettings.self, forKey: .ai) ?? ai
        review = try container.decodeIfPresent(AIReviewSettings.self, forKey: .review) ?? review
        cloud = try container.decodeIfPresent(AICloudSettings.self, forKey: .cloud) ?? cloud
        opsProfiles = try container.decodeIfPresent([OpsProfile].self, forKey: .opsProfiles) ?? []
        selectedOpsProfileID = try container.decodeIfPresent(String.self, forKey: .selectedOpsProfileID) ?? ""
        docklet = try container.decodeIfPresent(DockletSettings.self, forKey: .docklet) ?? docklet
        clipboard = try container.decodeIfPresent(ClipboardSettings.self, forKey: .clipboard) ?? clipboard
        startup = try container.decodeIfPresent(StartupSettings.self, forKey: .startup) ?? startup
        if let workspaces = try container.decodeIfPresent([QuickLaunchWorkspace].self,
                                                         forKey: .quickLaunchWorkspaces),
           !workspaces.isEmpty {
            quickLaunchWorkspaces = workspaces
        } else {
            let legacy = try decoder.container(keyedBy: LegacyQuickLaunchKey.self)
            if let paths = try legacy.decodeIfPresent([String].self, forKey: .quickLaunchApps) {
                quickLaunchWorkspaces = [QuickLaunchWorkspace(name: "默认方案", appPaths: paths)]
            }
        }
        let selected = try container.decodeIfPresent(String.self, forKey: .selectedQuickLaunchWorkspaceID)
        if let selected, quickLaunchWorkspaces.contains(where: { $0.id == selected }) {
            selectedQuickLaunchWorkspaceID = selected
        } else {
            selectedQuickLaunchWorkspaceID = quickLaunchWorkspaces[0].id
        }
        // 老版本把域名解析 / 证书 / 宝塔面板各自独立存在 dns / bt / acme 下：
        // 没有新的 opsProfiles 就一次性迁移成「配置」（含 acme 里很老的那份 AccessKey）。
        if opsProfiles.isEmpty {
            opsProfiles = Self.migratedProfiles(from: decoder)
        }
        ensureOpsProfileSelected()
    }

    // MARK: 「服务器运维」当前配置（三个功能页都从这一份读）

    var selectedOpsProfileIndex: Int {
        if let index = opsProfiles.firstIndex(where: { $0.id == selectedOpsProfileID }) {
            return index
        }
        return 0
    }

    var selectedOpsProfile: OpsProfile? {
        opsProfiles.indices.contains(selectedOpsProfileIndex) ? opsProfiles[selectedOpsProfileIndex] : nil
    }

    /// 至少有配置、且选中的 id 有效 —— 读写 `dns` / `bt` / `acme` 前先保证这一点。
    private mutating func ensureOpsProfileSelected() {
        if opsProfiles.isEmpty {
            opsProfiles = [OpsProfile(name: "默认配置")]
        }
        if !opsProfiles.contains(where: { $0.id == selectedOpsProfileID }) {
            selectedOpsProfileID = opsProfiles[0].id
        }
    }

    mutating func addOpsProfile() {
        let profile = OpsProfile(name: "配置 \(opsProfiles.count + 1)")
        opsProfiles.append(profile)
        selectedOpsProfileID = profile.id
    }

    /// 删掉当前配置（至少保留一份）。
    mutating func removeSelectedOpsProfile() {
        guard opsProfiles.count > 1 else {
            ensureOpsProfileSelected()
            return
        }
        let id = selectedOpsProfileID
        opsProfiles.removeAll { $0.id == id }
        selectedOpsProfileID = opsProfiles.first?.id ?? ""
    }

    /// 当前配置的域名解析设置。三个功能页共用：读写都会落到选中的那份配置上。
    var dns: DNSSettings {
        get { selectedOpsProfile?.dns ?? DNSSettings() }
        set {
            ensureOpsProfileSelected()
            opsProfiles[selectedOpsProfileIndex].dns = newValue
        }
    }

    /// 当前配置的证书设置。
    var acme: ACMESettings {
        get { selectedOpsProfile?.acme ?? ACMESettings() }
        set {
            ensureOpsProfileSelected()
            opsProfiles[selectedOpsProfileIndex].acme = newValue
        }
    }
}

// MARK: - 旧设置迁移（dns / acme → opsProfiles）

private enum LegacyOpsKeys: String, CodingKey {
    case dns, acme
}

private struct LegacyDNSCredential: Decodable {
    var name: String?
    var aliKey: String?
    var aliSecret: String?
}

private struct LegacyDNSSettings: Decodable {
    var provider: String?
    var credentials: [LegacyDNSCredential]?
    var aliKey: String?
    var aliSecret: String?
    var pageSize: Int?
    var defaultTTL: Int?
}

private struct LegacyACMESettings: Decodable {
    var bin: String?
    var email: String?
    var keylength: String?
    var aliKey: String?
    var aliSecret: String?
}

extension AppSettings {
    /// 把旧版本各自独立的 `dns` / `acme` 合成「服务器管理」配置（宝塔面板已移除，不再参与）。
    ///
    /// 规则：**每个阿里云账号一份配置**；一个账号都没有时给一份空的「默认配置」。
    static func migratedProfiles(from decoder: Decoder) -> [OpsProfile] {
        guard let legacy = try? decoder.container(keyedBy: LegacyOpsKeys.self) else { return [] }
        let oldDNS = (try? legacy.decodeIfPresent(LegacyDNSSettings.self, forKey: .dns)) ?? nil
        let oldACME = (try? legacy.decodeIfPresent(LegacyACMESettings.self, forKey: .acme)) ?? nil

        // 阿里云账号：新一点的旧版本是账号列表，更老的是单组 aliKey / aliSecret（甚至存在 acme 下）
        var accounts: [(name: String, key: String, secret: String)] = []
        if let list = oldDNS?.credentials, !list.isEmpty {
            accounts = list.map { ($0.name ?? "", $0.aliKey ?? "", $0.aliSecret ?? "") }
        } else if let old = oldDNS,
                  !(old.aliKey ?? "").isEmpty || !(old.aliSecret ?? "").isEmpty {
            accounts = [("", old.aliKey ?? "", old.aliSecret ?? "")]
        }
        if accounts.isEmpty, let old = oldACME,
           !(old.aliKey ?? "").isEmpty || !(old.aliSecret ?? "").isEmpty {
            accounts = [("", old.aliKey ?? "", old.aliSecret ?? "")]
        }

        let provider = oldDNS?.provider ?? "aliyun"
        let pageSize = oldDNS?.pageSize ?? 50
        let defaultTTL = oldDNS?.defaultTTL ?? 600

        // 证书设置以前全局一份，迁移时**复制**给每份配置（切到哪份都是原来的值，再各自调）
        var acme = ACMESettings()
        if let old = oldACME {
            if let value = old.bin { acme.bin = value }
            if let value = old.email { acme.email = value }
            if let value = old.keylength { acme.keylength = value }
        }

        func makeProfile(_ account: (name: String, key: String, secret: String)) -> OpsProfile {
            var profile = OpsProfile(name: account.name.trimmingCharacters(in: .whitespaces))
            profile.dns = DNSSettings(provider: provider,
                                      aliKey: account.key,
                                      aliSecret: account.secret,
                                      pageSize: pageSize,
                                      defaultTTL: defaultTTL)
            profile.acme = acme
            return profile
        }

        // 每个阿里云账号一份配置；没有账号就给一份空的「默认配置」
        if accounts.isEmpty {
            var profile = OpsProfile(name: "默认配置")
            profile.dns = DNSSettings(provider: provider, pageSize: pageSize, defaultTTL: defaultTTL)
            profile.acme = acme
            return [profile]
        }
        return accounts.map(makeProfile)
    }
}

enum SettingsStore {
    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        // 旧设置文件里没有 `opsProfiles`：解码时已把 dns / acme 合并成「服务器管理配置」，
        // 这里顺手落盘，让设置文件里只剩一份明文。
        if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["opsProfiles"] == nil {
            save(settings)
            Diag.log("设置迁移：把域名解析 / 证书合并成「服务器管理配置」")
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
