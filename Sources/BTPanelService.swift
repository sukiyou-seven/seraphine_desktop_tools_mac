import Foundation
import CryptoKit

// MARK: - 设置与数据结构

struct BTSettings: Codable {
    var baseURL = ""            // 面板地址，例如 http://1.2.3.4:8888
    var apiKey = ""             // 面板「设置 → API 接口」里生成的密钥
    var allowInsecure = true    // https 自签证书时忽略校验
    var timeout = 30

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? apiKey
        allowInsecure = try container.decodeIfPresent(Bool.self, forKey: .allowInsecure) ?? allowInsecure
        timeout = try container.decodeIfPresent(Int.self, forKey: .timeout) ?? timeout
    }
}

/// 一次 API 调用的结果。raw 一定保留，方便排查（面板版本差异时最有用）。
struct BTAPIResult {
    var ok: Bool
    var message: String
    var raw: String
    var json: [String: Any]?

    var dataRows: [[String: Any]] {
        guard let json else { return [] }
        if let rows = json["data"] as? [[String: Any]] { return rows }
        // 有的接口把数据放在 message 里（宝塔有时这样）
        if let nested = json["message"] as? [String: Any], let rows = nested["data"] as? [[String: Any]] {
            return rows
        }
        return []
    }

    static func failure(_ message: String) -> BTAPIResult {
        BTAPIResult(ok: false, message: message, raw: "", json: nil)
    }
}

/// 可以被启停的常见服务（宝塔内部的服务名 + 用于比对的进程名前缀）。
/// 实测：宝塔商店的 `status` 只表示"商店是否托管它"，**不能当运行状态用**
/// （手动装的 redis 会被判成未运行），所以运行状态一律看服务器进程表。
struct BTServiceEntry: Identifiable {
    var name: String
    var label: String
    /// 进程表里用于匹配的进程名前缀（nginx / mysqld / redis / mongod …）
    var processName: String
    var id: String { name }

    static let common: [BTServiceEntry] = [
        BTServiceEntry(name: "nginx", label: "Nginx", processName: "nginx"),
        BTServiceEntry(name: "apache", label: "Apache", processName: "httpd"),
        BTServiceEntry(name: "openresty", label: "OpenResty", processName: "openresty"),
        BTServiceEntry(name: "mysql", label: "MySQL", processName: "mysqld"),
        BTServiceEntry(name: "mariadb", label: "MariaDB", processName: "mysqld"),
        BTServiceEntry(name: "redis", label: "Redis", processName: "redis"),
        BTServiceEntry(name: "mongodb", label: "MongoDB", processName: "mongod"),
        BTServiceEntry(name: "pure-ftpd", label: "Pure-Ftpd", processName: "pure-ftpd"),
        BTServiceEntry(name: "memcached", label: "Memcached", processName: "memcached"),
        BTServiceEntry(name: "php-fpm-74", label: "PHP 7.4", processName: "php-fpm"),
        BTServiceEntry(name: "php-fpm-80", label: "PHP 8.0", processName: "php-fpm"),
        BTServiceEntry(name: "php-fpm-82", label: "PHP 8.2", processName: "php-fpm"),
        BTServiceEntry(name: "docker", label: "Docker", processName: "dockerd"),
    ]
}

struct BTSite: Identifiable {
    var id: String
    var name: String
    var path: String
    var domains: String
    var status: String
    /// 站点类型（宝塔 8+ 用 project_type；老版本用 type_id）
    var projectType: String = ""
    var typeID: String = ""
    /// SSL 原始值（面板不同版本字段不一致，一律容错）
    var ssl: String = ""

    var running: Bool { status == "1" || status.lowercased() == "true" }
    var statusLabel: String { running ? "运行中" : "已停止" }

    /// 站点类型的中文标签
    var typeLabel: String {
        let raw = (projectType.isEmpty ? typeID : projectType).lowercased()
        switch raw {
        case "": return "—"
        case "php", "0": return "PHP"
        case "static", "html", "1": return "静态 HTML"
        case "python", "2": return "Python"
        case "node", "nodejs", "node.js": return "Node.js"
        case "proxy", "proxy_pass", "reverse", "reverseproxy": return "反向代理"
        case "java", "3": return "Java"
        case "go", "golang": return "Go"
        case "other": return "其它"
        default: return projectType.isEmpty ? typeID : projectType
        }
    }

    /// SSL 状态。宝塔 13.x 的 `ssl` 字段实际是：
    ///   `-1` → 没配证书
    ///   含 `issuer` / `notAfter` 的字典字面量（Python 风格、单引号）→ 已部署
    var sslState: String {
        let raw = ssl.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return "未知" }
        if raw == "-1" || raw == "0" || raw.lowercased() == "false" { return "未开启" }
        if raw.contains("issuer") || raw.contains("notAfter")
            || raw == "1" || raw.lowercased() == "true" { return "已开启" }
        return "未知"
    }

    /// 证书到期日（面板的 ssl 字段里带 notAfter，例如 2026-11-30；取不到就为空）
    var sslNotAfter: String {
        guard let range = ssl.range(of: "notAfter") else { return "" }
        let rest = ssl[range.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return "" }
        let value = rest[rest.index(after: colon)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\",}"))
        return String(value.prefix(10))
    }

    /// 列表里只显示两种状态：已部署 / 未部署（认不出来显示 —，不误导）
    var sslLabel: String {
        switch sslState {
        case "已开启": return "已部署"
        case "未开启": return "未部署"
        default: return "—"
        }
    }

    /// 是否是「项目类」站点（Python / Node / Java / Go…）。
    /// 这类站点除了 nginx 配置，还牵扯应用进程，启停行为和 PHP / 静态站不一样。
    var isProjectSite: Bool {
        let raw = (projectType.isEmpty ? typeID : projectType).lowercased()
        return ["python", "node", "nodejs", "node.js", "java", "go", "golang", "2", "3"].contains(raw)
    }

    /// 是不是 Python 项目。宝塔为它提供了专用接口 `/project/python/StartProject|StopProject`，
    /// 能**真正停掉 uwsgi 应用进程**（实测有效），所以要单独认出来。
    var isPythonProject: Bool { projectType.lowercased() == "python" }

    /// 该项目对应的应用进程名（用于停站后核对进程是否真的停掉了）。
    /// Python 用 uwsgi（宝塔默认）也可能用 gunicorn，所以给一组候选。
    var processNameHints: [String] {
        switch projectType.lowercased() {
        case "python": return ["uwsgi", "gunicorn"]
        case "node", "nodejs", "node.js": return ["node"]
        case "java": return ["java"]
        case "go", "golang": return ["go"]
        default: return []
        }
    }

    /// 启停方式的说明（按站点类型区分，用于确认弹窗）。
    /// 实测结论：Python 项目走 `/project/python/StartProject|StopProject` 能**连进程一起停**；
    /// 其它项目类型只测到站点接口，故如实说明其局限。
    var restartNote: String {
        if isPythonProject {
            return "这是「Python」项目：会调用宝塔专用的 /project/python 启停接口，"
                 + "停站时 uwsgi 应用进程一起停掉（已实测有效），启动时重新拉起。"
        }
        if isProjectSite {
            return "这是「\(typeLabel)」项目类站点：停站会停掉 nginx 里的转发配置；"
                 + "若应用进程（node / java 等）仍在运行，需要到宝塔面板里停对应项目。"
        }
        switch typeLabel {
        case "反向代理":
            return "反向代理站点：启停只切换 nginx 里的代理配置，后端服务本身不受影响。"
        case "PHP", "静态 HTML":
            return "由 nginx 直接服务：启停即切换该站点的 nginx 配置。"
        default:
            return "启停会切换该站点的运行状态。"
        }
    }

    /// 主域名（面板里 domain 可能是 "a.com b.com" 或 JSON 数组字符串）
    var primaryDomain: String {
        let cleaned = domains
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\"", with: "")
        return cleaned
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}

/// 面板里某个服务的安装 / 运行状态。
/// 实测（宝塔 13.x）：`/plugin?action=get_soft_list&query=<name>` 的 `list.data[]` 里，
/// `version` 非空 = 已安装，`status` = 是否正在运行。
struct BTServiceStatus: Identifiable {
    var name: String            // 面板内部名，如 nginx
    var title: String           // 显示名
    var version: String = ""    // 商店登记的版本（手装的服务可能为空）
    /// 商店登记的运行状态（**不单独采信**，见 processCount）
    var running: Bool?
    /// 进程表里匹配到的进程数：>0 就是确实在跑
    var processCount: Int = 0

    var id: String { name }

    /// 有没有装：进程在跑，或商店登记过版本
    var installed: Bool { processCount > 0 || !version.isEmpty }

    /// 三态：运行中 / 已停止 / 未安装（**以进程表为准**）
    var statusLabel: String {
        if processCount > 0 { return "运行中" }
        if installed { return "已停止" }
        if running == true { return "运行中" }
        return "未安装"
    }

    /// 状态旁的补充说明（例如「4 个进程」）
    var detailLabel: String {
        if processCount > 0 { return "\(processCount) 个进程" }
        return version.isEmpty ? "" : "商店已登记"
    }
}

/// 一块磁盘/分区的占用情况（实测接口 `/system?action=GetDiskInfo`）
struct BTDiskUsage: Identifiable {
    var path: String            // "/"
    var filesystem: String      // "/dev/vda3"
    var totalText: String       // "39.0 GB"
    var usedText: String        // "11.5 GB"
    var availText: String       // "25.7 GB"
    var percentText: String     // "30.99%"

    var id: String { path + "|" + filesystem }

    /// 使用率 0…1。面板直接给了百分比字符串，优先用它
    /// （它按"可用容量"当分母，比拿字节数自己除更准）。
    var fraction: Double {
        let raw = percentText.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
        guard let value = Double(raw) else { return 0 }
        return min(max(value / 100, 0), 1)
    }
}

/// 一条资源占用（CPU / 内存），用于画进度条
struct BTResourceUsage: Identifiable {
    var label: String           // "CPU" / "内存"
    var detail: String          // "550.0MB / 1.8GB"
    var fraction: Double        // 0…1

    var id: String { label }
}

/// 面板支持的数据库类型。实测：每种走 `POST /database/<key>/get_list`，参数 `data` = JSON 字符串；
/// **MySQL 是例外**（面板内置，走 /data 通用接口，且被固定过滤成 MySQL）。
struct BTDatabaseType: Identifiable {
    var key: String             // 接口路径里的类型名，如 mongodb
    var label: String           // 显示名
    /// 该类型的返回是**裸数组**而不是 `{page, data:[...]}`（实测 redis / sqlite 是裸数组）
    var arrayStyle: Bool = false
    var id: String { key }

    static let all: [BTDatabaseType] = [
        BTDatabaseType(key: "mysql", label: "MySQL"),
        BTDatabaseType(key: "mongodb", label: "MongoDB"),
        BTDatabaseType(key: "redis", label: "Redis", arrayStyle: true),
        BTDatabaseType(key: "pgsql", label: "PostgreSQL"),
        BTDatabaseType(key: "sqlserver", label: "SQL Server"),
        BTDatabaseType(key: "sqlite", label: "SQLite", arrayStyle: true),
    ]

    static func find(_ key: String) -> BTDatabaseType {
        all.first { $0.key == key } ?? all[1]
    }
}

/// 面板里的数据库条目（实测来自 `/database/<类型>/get_list`）。
/// ⚠️ 面板会在响应里**明文返回 `password`**，展示时必须走 SecretCell、写日志前必须脱敏。
struct BTDatabase: Identifiable {
    var id: String
    var name: String
    var type: String            // "MongoDB" / "Redis" …
    var size: String = ""
    var username: String = ""
    var password: String = ""
    var accept: String = ""     // 允许的访问来源，如 127.0.0.1
    var addtime: String = ""
    var keynum: Int = 0         // Redis 的键数量（其它类型为 0）
}

// MARK: - 服务

/// 宝塔 / aaPanel 面板 API 客户端。
///
/// 签名规则（宝塔官方）：`request_token = md5(request_time + md5(api_sk))`，
/// 参数以 `application/x-www-form-urlencoded` 提交。
/// 由于不同面板版本的插件接口偶有差异，这里做了两件事：
/// ① 返回「签名错误」时自动用备选算法重试；② 每次都保留原始响应，方便排查。
final class BTPanelService: @unchecked Sendable {
    private(set) var settings: BTSettings

    init(settings: BTSettings) {
        self.settings = settings
    }

    // MARK: 基础

    var baseURL: String {
        var url = settings.baseURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    var apiKey: String { settings.apiKey.trimmingCharacters(in: .whitespaces) }

    var isConfigured: Bool { !baseURL.isEmpty && !apiKey.isEmpty }

    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 宝塔标准签名
    static func requestToken(apiKey: String, requestTime: String) -> String {
        md5(requestTime + md5(apiKey))
    }

    /// 备选签名（个别插件按未哈希的密钥计算），仅在标准签名被拒时使用
    static func requestTokenVariant(apiKey: String, requestTime: String) -> String {
        md5(requestTime + apiKey)
    }

    // MARK: 调用

    func call(_ path: String, params: [String: String] = [:], timeout: TimeInterval? = nil) -> BTAPIResult {
        guard isConfigured else {
            return .failure("还没配置面板地址或 API 密钥。面板里「设置 → API 接口」可以开启并生成密钥。")
        }
        let first = perform(path: path, params: params, variant: false, timeout: timeout)
        if first.ok { return first }

        // 签名相关报错 → 换一种算法重试
        let lower = first.raw.lowercased()
        if lower.contains("签名") || lower.contains("token") || lower.contains("sign") {
            let second = perform(path: path, params: params, variant: true, timeout: timeout)
            if second.ok { return second }
            return BTAPIResult(ok: false,
                               message: first.message + "\n（备选签名也没通过：" + second.message + "）",
                               raw: second.raw.isEmpty ? first.raw : second.raw,
                               json: second.json ?? first.json)
        }
        return first
    }

    private func perform(path: String, params: [String: String], variant: Bool,
                         timeout: TimeInterval?) -> BTAPIResult {
        let seconds = Int(timeout ?? Double(settings.timeout))
        let stamp = String(Int(Date().timeIntervalSince1970))
        let token = variant
            ? Self.requestTokenVariant(apiKey: apiKey, requestTime: stamp)
            : Self.requestToken(apiKey: apiKey, requestTime: stamp)

        var args = ["curl", "-s", "-S", "--max-time", String(seconds)]
        if settings.allowInsecure { args.append("-k") }
        args += ["-X", "POST", baseURL + path,
                 "-d", "request_time=\(stamp)",
                 "-d", "request_token=\(token)"]
        for (name, value) in params.sorted(by: { $0.key < $1.key }) {
            args += ["--data-urlencode", "\(name)=\(value)"]
        }

        let result = Shell.run(args, timeout: Double(seconds) + 10)
        let raw = result.stdout
        if raw.isEmpty && !result.ok {
            return .failure("请求失败：\(result.message)\n（地址：\(baseURL + path)）")
        }
        return Self.interpret(raw)
    }

    /// 面板没有这个接口时，nginx 会回一个 404 HTML 页面（说明接口路径在当前版本不存在）
    static func looksLikeNotFound(_ raw: String) -> Bool {
        raw.contains("404 Not Found")
            || (raw.lowercased().contains("<html") && raw.contains("nginx") && raw.contains("404"))
    }

    /// 解析面板返回（JSON / 纯文本 true|false / 错误文本 / nginx 的 404 页面）
    static func interpret(_ raw: String) -> BTAPIResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeNotFound(text) {
            return BTAPIResult(ok: false,
                               message: "该接口在当前面板版本不存在（面板返回 404）",
                               raw: raw, json: nil)
        }
        if let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
            return BTAPIResult(ok: isSuccess(json), message: describe(json), raw: raw, json: json)
        }
        if let array = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] {
            return BTAPIResult(ok: true, message: "成功（返回 \(array.count) 条）", raw: raw,
                               json: ["data": array])
        }
        let lower = text.lowercased()
        let ok = lower == "true" || lower == "1" || lower.contains("success")
        let message = text.isEmpty ? "面板没有返回内容（检查地址/端口/密钥）" : String(text.prefix(400))
        return BTAPIResult(ok: ok, message: message, raw: raw, json: nil)
    }

    static func isSuccess(_ json: [String: Any]) -> Bool {
        // 1) 显式 status（失败响应通常是 {"status": false, "msg": "..."}）
        if let value = json["status"] as? Bool { return value }
        if let value = json["status"] as? Int { return value == 1 }
        if let value = json["status"] as? String { return value == "true" || value == "1" }
        // 2) 显式错误字段
        if let error = json["error"] as? String, !error.isEmpty { return false }
        // 3) 列表类接口
        if json["data"] != nil { return true }
        // 4) 宝塔很多「读取类」接口直接返回数据对象，既没有 status 也没有 data
        //    （例如 /system?action=GetSystemTotal 直接返回 memTotal/version/... ），
        //    这种情况只要不是「只有一句提示信息」，就算成功。
        let hintKeys = ["msg", "message", "error"]
        let payloadKeys = json.keys.filter { !hintKeys.contains($0) }
        if payloadKeys.isEmpty { return false }
        return !json.isEmpty
    }

    /// 从「IP 校验失败」的响应里提取被拦截的访问 IP（宝塔 API 可以配 IP 白名单）
    static func blockedIP(from raw: String) -> String? {
        guard let marker = raw.range(of: "访问IP为[") ?? raw.range(of: "访问 IP 为[") else { return nil }
        let rest = raw[marker.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return nil }
        let ip = String(rest[rest.startIndex..<end]).trimmingCharacters(in: .whitespaces)
        return ip.isEmpty ? nil : ip
    }

    static func isIPBlocked(_ raw: String) -> Bool {
        raw.contains("IP校验失败") || raw.contains("IP校验") || blockedIP(from: raw) != nil
    }

    static func describe(_ json: [String: Any]) -> String {
        for key in ["msg", "message", "error"] {
            if let value = json[key] as? String, !value.isEmpty, value != "True" {
                if value.contains("IP校验") {
                    let ip = blockedIP(from: value).map { "（\($0)）" } ?? ""
                    return value + "\n\n→ 面板的 API 开了 IP 白名单\(ip)。"
                         + "请到「面板设置 → API 接口 → IP 白名单」把这个 IP 加进去，或清空白名单。"
                         + "注意家用宽带的出口 IP 会变，变了要重新加。"
                }
                return value
            }
        }
        return isSuccess(json) ? "成功" : "失败"
    }

    // MARK: 具体接口

    /// 面板与系统概览
    func systemTotal() -> BTAPIResult {
        call("/system", params: ["action": "GetSystemTotal"])
    }

    /// 磁盘占用（实测接口 `/system?action=GetDiskInfo`）。
    /// 返回的是 **JSON 数组**（不是对象），每项形如：
    /// `{"path":"/", "filesystem":"/dev/vda3", "type":"ext4",
    ///   "size":["39.0 GB","11.5 GB","25.7 GB","30.99%"]}`
    /// → size 依次是 总量 / 已用 / 可用 / 使用率。
    func diskUsage() -> [BTDiskUsage] {
        let result = call("/system", params: ["action": "GetDiskInfo"], timeout: 25)
        guard let data = result.raw.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            let sizes = (row["size"] as? [String]) ?? []
            guard sizes.count >= 3 else { return nil }
            return BTDiskUsage(path: (row["path"] as? String) ?? "/",
                               filesystem: (row["filesystem"] as? String) ?? "",
                               totalText: sizes[0],
                               usedText: sizes[1],
                               availText: sizes[2],
                               percentText: sizes.count > 3 ? sizes[3] : "")
        }
    }

    /// CPU / 内存占用（实测接口 `/system?action=GetSystemTotal`）。
    /// 面板已给出可直接用的值：`cpuRealUsed`（百分比）、`memNewRealUsed`/`memNewTotal`。
    func resourceUsage() -> [BTResourceUsage] {
        let result = call("/system", params: ["action": "GetSystemTotal"], timeout: 25)
        guard let json = result.json else { return [] }
        var out: [BTResourceUsage] = []

        if let cpu = Self.doubleValue(json["cpuRealUsed"]) {
            let cores = Self.doubleValue(json["cpuNum"]) ?? 0
            out.append(BTResourceUsage(label: "CPU",
                                       detail: cores > 0 ? "\(num(cpu))%  ·  \(Int(cores)) 核" : "\(num(cpu))%",
                                       fraction: min(max(cpu / 100, 0), 1)))
        }
        let usedText = (json["memNewRealUsed"] as? String) ?? ""
        let totalText = (json["memNewTotal"] as? String) ?? ""
        if let usedMB = Self.doubleValue(json["memRealUsed"]),
           let totalMB = Self.doubleValue(json["memTotal"]), totalMB > 0 {
            out.append(BTResourceUsage(label: "内存",
                                       detail: !usedText.isEmpty && !totalText.isEmpty
                                           ? "\(usedText) / \(totalText)"
                                           : "\(num(usedMB))MB / \(num(totalMB))MB",
                                       fraction: min(max(usedMB / totalMB, 0), 1)))
        }
        return out
    }

    /// JSON 里的数字可能是 Int / Double / String，统一取出来
    static func doubleValue(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// 去掉多余小数（1.5 → "1.5"，550.0 → "550"）
    private func num(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// 测试连接：顺带把面板版本带回来
    func ping() -> BTAPIResult {
        call("/system", params: ["action": "GetSystemTotal"], timeout: 15)
    }

    /// 服务启停：type = start / stop / restart / reload。
    /// ⚠️ 实测：面板对**不存在的服务名也回「执行成功」**，所以 start/stop 之后
    /// 重新查一次状态来验证，不能只信响应文本。
    func serviceAdmin(name: String, type: String) -> (result: BTAPIResult, verified: BTServiceStatus?) {
        let result = call("/system", params: ["action": "ServiceAdmin", "name": name, "type": type])
        var verified: BTServiceStatus?
        if type == "start" || type == "stop" {
            // 复查也走进程表，和列表口径保持一致
            verified = serviceStatuses().first { $0.name == name }
        }
        return (result, verified)
    }

    /// 网站列表（宝塔通用数据接口）
    func siteList(page: Int = 1, limit: Int = 200) -> BTAPIResult {
        call("/data", params: ["action": "getData", "table": "sites",
                               "p": String(page), "limit": String(limit),
                               "type": "-1", "order": "id desc"])
    }

    /// Python 项目列表（实测接口：`/project/python/GetProjectList`）。
    /// 每项含 `status`（项目真实运行状态）、`pids`（进程号）、`listen`、`cpu`、`mem`。
    func projectList() -> [[String: Any]] {
        let result = call("/project/python/GetProjectList", params: [:], timeout: 30)
        if let json = result.json {
            for key in ["data", "list"] {
                if let rows = json[key] as? [[String: Any]] { return rows }
            }
        }
        return []
    }

    /// 网站列表 + **Python 项目的真实状态**。
    /// 实测：面板的 Python 项目启停只调 `/project/python/...`，**不改 sites 表**，
    /// 所以一旦从别处改过状态，`sites.status` 就会和实际错位；
    /// 项目接口返回的 status 才是真的，这里用它校正。
    func sitesWithRealStatus() -> [BTSite] {
        Self.applyProjectStatus(Self.parseSites(siteList()), projects: projectList())
    }

    /// 用 Python 项目的真实状态校正站点列表（抽成纯函数，便于测试）。
    /// 只覆盖 Python 项目的 status，其它类型仍以 sites 表为准。
    static func applyProjectStatus(_ sites: [BTSite], projects: [[String: Any]]) -> [BTSite] {
        guard !projects.isEmpty else { return sites }
        var realStatus: [String: Bool] = [:]
        for row in projects {
            guard let name = row["name"] as? String else { continue }
            realStatus[name] = parseBool(row["status"])
        }
        var result = sites
        for index in result.indices where result[index].isPythonProject {
            if let real = realStatus[result[index].name] {
                result[index].status = real ? "1" : "0"
            }
        }
        return result
    }

    /// 按类型取数据库列表。实测规律（F12 抓包 + 逐类型验证）：
    /// `POST /database/<类型>/get_list`，参数是**一个叫 `data` 的字段、值为 JSON 字符串**：
    /// `{"p":1,"limit":100,"tables":"databases","search":""}`
    /// **MySQL 例外**：它是面板内置的，走 `/data?action=getData&table=databases`
    /// （该接口被面板固定过滤成 MySQL，所以只能拿来查 MySQL）。
    func databaseList(type: BTDatabaseType, page: Int = 1, limit: Int = 100) -> BTAPIResult {
        if type.key == "mysql" {
            return call("/data", params: ["action": "getData", "table": "databases",
                                          "p": String(page), "limit": String(limit),
                                          "type": "-1", "order": "id desc"], timeout: 30)
        }
        let payload = "{\"p\":\(page),\"limit\":\(limit),\"tables\":\"databases\",\"search\":\"\"}"
        return call("/database/\(type.key)/get_list", params: ["data": payload], timeout: 30)
    }

    /// 「指定参数无效」这类错误 → 说明接口找对了，但参数名/组合不对，应继续试别的组合
    static func looksLikeBadParams(_ raw: String) -> Bool {
        raw.contains("参数无效") || raw.contains("参数错误") || raw.contains("参数有误")
            || raw.lowercased().contains("invalid parameter")
    }

    /// Python 项目启停。实测（F12 抓包 + API 验证）宝塔把它拆成了**两个**接口：
    /// - `POST /project/python/StartProject|StopProject`（form: `name=<项目名>`）
    ///   → 真正起 / 停 **uwsgi 应用进程**（实测进程数 6 ⇄ 12），**不改 sites 表状态**
    /// - `POST /site?action=SiteStart|SiteStop`（`id` + `name`）
    ///   → 更新 sites 表状态 + nginx 配置，**不动应用进程**
    /// 面板自己只调前者，于是出现"面板看是运行中、工具看是已停止"的错位。
    /// 这里**两个都调**，让进程和状态保持一致。
    func pythonProjectAction(site: BTSite, start: Bool)
        -> (project: BTAPIResult, site: BTAPIResult) {
        let project = call("/project/python/\(start ? "StartProject" : "StopProject")",
                           params: ["name": site.name], timeout: 40)
        let siteResult = call("/site", params: ["action": start ? "SiteStart" : "SiteStop",
                                                "id": site.id, "name": site.name], timeout: 30)
        return (project, siteResult)
    }

    /// 网站启停（PHP / 静态 / 反代等）。宝塔各版本的接口和参数名都不一样，
    /// 所以**依次尝试候选组合**：
    /// - 404 → 接口不存在，换下一个
    /// - 「参数无效」→ 接口对了参数不对，也换下一个
    /// - 其它有意义的响应（成功 / 业务错误）→ 停下并返回
    func setSiteRunning(_ site: BTSite, start: Bool)
        -> (result: BTAPIResult, endpoint: String, tried: [String]) {
        let status = start ? "1" : "0"
        let action = start ? "SiteStart" : "SiteStop"
        // 顺序很重要：第一条是宝塔 13.x **实测可用**的组合
        // （id 和 name 必须同时传：只传 id 会 404，只传 name 会「参数错误」）；
        // 后面几条是各版本兼容候选。
        let candidates: [(path: String, params: [String: String])] = [
            ("/site", ["action": action, "id": site.id, "name": site.name]),
            ("/site", ["action": action, "id": site.id]),
            ("/site", ["action": action, "name": site.name]),
            ("/data", ["action": "setSiteStatus", "table": "sites", "id": site.id, "status": status]),
            ("/data", ["action": "setSiteStatus", "table": "sites", "ids": site.id, "status": status]),
        ]
        var tried: [String] = []
        var last: (result: BTAPIResult, endpoint: String, tried: [String]) =
            (BTAPIResult.failure("所有候选接口都不可用"), "", [])
        for candidate in candidates {
            let result = call(candidate.path, params: candidate.params, timeout: 20)
            let endpoint = candidate.path + "?" + candidate.params
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "&")
            tried.append(endpoint)
            if result.ok { return (result, endpoint, tried) }
            let retryable = Self.looksLikeNotFound(result.raw) || Self.looksLikeBadParams(result.raw)
            if !retryable { return (result, endpoint, tried) }
            last = (result, endpoint, tried)
        }
        return last
    }

    /// 把证书部署成某网站的 SSL（key = 私钥，csr = 证书链）
    func deploySSL(siteName: String, privateKey: String, fullchain: String) -> BTAPIResult {
        call("/site", params: ["action": "SetSSL",
                               "siteName": siteName,
                               "key": privateKey,
                               "csr": fullchain])
    }

    // MARK: 结果解析

    static func parseSites(_ result: BTAPIResult) -> [BTSite] {
        result.dataRows.compactMap { row in
            let name = (row["name"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            return BTSite(id: String(describing: row["id"] ?? name),
                          name: name,
                          path: (row["path"] as? String) ?? "",
                          domains: (row["domain"] as? String) ?? (row["domains"] as? String) ?? "",
                          status: String(describing: row["status"] ?? "1"),
                          projectType: (row["project_type"] as? String) ?? "",
                          typeID: row["type_id"].map { String(describing: $0) } ?? "",
                          ssl: sslValue(in: row))
        }
    }

    /// 面板不同版本把 SSL 状态放在不同字段，挨个试（拿不到就留空 = 未知）
    static func sslValue(in row: [String: Any]) -> String {
        for key in ["ssl", "ssl_enabled", "ssl_status", "is_ssl", "https"] {
            guard let value = row[key], !(value is NSNull) else { continue }
            let text = (value as? String) ?? String(describing: value)
            if !text.isEmpty { return text }
        }
        return ""
    }

    /// 查一个服务的安装 / 运行状态。
    /// 实测（宝塔 13.x）：`/plugin?action=get_soft_list&query=<name>` 的
    /// `list.data[]` 里带 `status`（是否正在运行）和 `version`（非空 = 已安装）。
    /// 服务器进程表（实测接口：`/ajax?action=GetProcessList`）。
    /// **运行状态以它为准** —— 商店的 `status` 只表示"商店是否托管"，不可靠。
    /// 注意：这个接口直接返回一个**数组**（不是 JSON 对象），所以用原始文本解析，
    /// 不能走 `json` 字段（它是字典类型，强转数组永远失败）。
    func processList() -> [[String: Any]] {
        let result = call("/ajax", params: ["action": "GetProcessList"], timeout: 25)
        if let data = result.raw.data(using: .utf8),
           let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            return rows
        }
        return []
    }

    /// 批量查服务状态：**一次**拉进程表 + 一次拉商店列表，然后逐个比对。
    func serviceStatuses(entries: [BTServiceEntry]? = nil) -> [BTServiceStatus] {
        let list = entries ?? BTServiceEntry.common
        let processes = processList()
        let shop = shopStatuses()
        return list.map { entry in
            let key = entry.processName.lowercased()
            let count = processes.filter { row in
                let procName = ((row["name"] as? String) ?? "").lowercased()
                return !key.isEmpty && procName.hasPrefix(key)
            }.count
            let registered = shop[entry.name]
            return BTServiceStatus(name: entry.name,
                                   title: entry.label,
                                   version: registered?.version ?? "",
                                   running: count > 0 ? true : (registered == nil ? nil : false),
                                   processCount: count)
        }
    }

    /// 商店里各软件登记的版本（查不到 = 没登记，不代表没装）
    func shopStatuses() -> [String: BTServiceStatus] {
        let result = call("/plugin", params: ["action": "get_soft_list", "p": "1",
                                              "limit": "100", "type": "0"], timeout: 25)
        var out: [String: BTServiceStatus] = [:]
        guard let json = result.json,
              let list = json["list"] as? [String: Any],
              let items = list["data"] as? [[String: Any]] else { return out }
        for row in items {
            guard let name = row["name"] as? String else { continue }
            let version = (row["version"] as? String) ?? ""
            guard !version.isEmpty else { continue }
            out[name] = BTServiceStatus(name: name,
                                        title: (row["title"] as? String) ?? name,
                                        version: version,
                                        running: Self.parseBool(row["status"]))
        }
        return out
    }

    /// 从软件列表响应里挑出目标服务的状态；认不出来给「未知」，不硬说已停止。
    static func parseService(name: String, from result: BTAPIResult) -> BTServiceStatus {
        let unknown = BTServiceStatus(name: name, title: name, version: "", running: nil)
        guard let json = result.json,
              let list = json["list"] as? [String: Any],
              let items = list["data"] as? [[String: Any]] else {
            return unknown
        }
        // query 是模糊匹配，必须精确对上 name；对不上就返回未知，
        // 绝不能退而取列表第一项（那会把 A 的状态显示成 B 的）。
        guard let row = items.first(where: { ($0["name"] as? String) == name }) else {
            return unknown
        }
        return BTServiceStatus(name: name,
                               title: (row["title"] as? String) ?? name,
                               version: (row["version"] as? String) ?? "",
                               running: parseBool(row["status"]))
    }

    /// 面板里布尔写法不统一（true / 1 / "1" / "running" / "stopped" …）
    static func parseBool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int != 0 }
        if let string = value as? String {
            switch string.lowercased() {
            case "1", "true", "on", "yes", "running", "start", "started", "enabled": return true
            case "0", "false", "off", "no", "stopped", "stop", "disabled": return false
            default: return nil
            }
        }
        return nil
    }

    /// 面板的 SSL 类接口会返回私钥明文 —— 展示 / 记录前先抹掉（本工具不需要私钥明文）
    /// 把响应里的敏感值替换成占位符（写进日志 / 显示给用户之前必须过一遍）。
    /// ⚠️ 实测：`/database/mongodb/get_list` 会在响应里**明文返回数据库密码**，
    /// 所以 password 这一族必须一起脱敏（之前只覆盖了证书类字段，是个漏洞）。
    static func redactSensitive(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var text = raw
        if let regex = try? NSRegularExpression(
            pattern: "\"(key|csr|private_key|privateKey|privkey|pkey|cert|fullchain|password|passwd|pwd|api_sk|secret)\"\\s*:\\s*\"[^\"]*\"",
            options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range,
                                                  withTemplate: "\"$1\": \"***（已隐藏）\"")
        }
        // 连接串里的 user:pass@host 也一并遮掉
        if let regex = try? NSRegularExpression(pattern: "://([^:/@\\s]+):([^@\\s]+)@") {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range,
                                                  withTemplate: "://$1:***@")
        }
        return text
    }

    /// 解析数据库列表。实测结构（`/database/mongodb/get_list`）：
    /// `{"where":"…","page":"…","data":[{"id":1,"name":"demo_db","username":"demo_db",
    ///   "password":"明文","accept":"127.0.0.1","type":"MongoDB","addtime":"…"}]}`
    /// ⚠️ password 是明文，展示必须走 SecretCell。
    static func parseDatabases(_ result: BTAPIResult, type: BTDatabaseType) -> [BTDatabase] {
        var rows: [[String: Any]] = []
        // 裸数组型：实测 redis / sqlite 直接返回数组，没有 {page, data:[...]} 包装
        if type.arrayStyle, let data = result.raw.data(using: .utf8),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            rows = list
        }
        if rows.isEmpty { rows = result.dataRows }
        if rows.isEmpty, let json = result.json,
           let list = json["data"] as? [[String: Any]] {
            rows = list
        }
        return rows.compactMap { row in
            // 各类型字段不同：MongoDB 有 username/password/accept/addtime，
            // Redis 只有 {id, name, keynum} —— 统一映射，没有的留空
            let name = (row["name"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            return BTDatabase(id: String(describing: row["id"] ?? name),
                              name: name,
                              type: type.label,
                              size: (row["size"] as? String) ?? "",
                              username: (row["username"] as? String) ?? "",
                              password: (row["password"] as? String) ?? "",
                              accept: (row["accept"] as? String) ?? "",
                              addtime: (row["addtime"] as? String) ?? "",
                              keynum: (row["keynum"] as? Int) ?? 0)
        }
    }
}
