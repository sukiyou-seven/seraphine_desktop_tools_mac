import Foundation
import CryptoKit

// MARK: - 设置

/// 「域名解析」页的设置。
///
/// 只走阿里云云解析（AliDNS）的 OpenAPI，先支持阿里云一家；
/// `provider` 字段留着，以后加 Cloudflare / DNSPod 时不用再动设置文件的结构。
///
/// ⚠️ AccessKey 明文存在工具的设置文件里，建议用只有 `AliyunDNSFullAccess` 的 RAM 子账号。
/// 一份「服务器运维」配置（`OpsProfile`）只对应**一个**阿里云账号。
///
/// 以前这里是一个账号数组（`DNSCredential`），现在多账号请建多份配置 ——
/// 切配置就同时换了阿里云账号、宝塔面板和证书设置。
struct DNSSettings: Codable, Equatable {
    var provider = "aliyun"
    var aliKey = ""
    var aliSecret = ""
    /// 每次拉取解析记录的条数（阿里云接口上限 100）
    var pageSize = 50
    /// 记录列表默认的 TTL（阿里云默认 600，范围 ≤ 86400）
    var defaultTTL = 600

    init() {}

    init(provider: String = "aliyun", aliKey: String = "", aliSecret: String = "",
         pageSize: Int = 50, defaultTTL: Int = 600) {
        self.provider = provider
        self.aliKey = aliKey
        self.aliSecret = aliSecret
        self.pageSize = pageSize
        self.defaultTTL = defaultTTL
    }

    /// 宽松解码：缺哪个字段就用默认值。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? provider
        aliKey = try container.decodeIfPresent(String.self, forKey: .aliKey) ?? aliKey
        aliSecret = try container.decodeIfPresent(String.self, forKey: .aliSecret) ?? aliSecret
        pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? pageSize
        defaultTTL = try container.decodeIfPresent(Int.self, forKey: .defaultTTL) ?? defaultTTL
    }

    var hasCredentials: Bool {
        !aliKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !aliSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }
    var isConfigured: Bool { provider == "aliyun" && hasCredentials }

    var providerLabel: String {
        switch provider {
        case "aliyun": return "阿里云"
        default: return provider.isEmpty ? "未选" : provider
        }
    }

    var clampedPageSize: Int { min(max(pageSize, 10), 100) }
    var clampedTTL: Int { min(max(defaultTTL, 60), 86400) }
}

// MARK: - 数据结构

struct DNSDomain: Identifiable, Equatable {
    var name = ""
    var domainId = ""
    var recordCount = 0
    /// 云解析版本名（免费版 / 个人版 …），拿不到就留空
    var versionName = ""

    var id: String { domainId.isEmpty ? name : domainId }
}

struct DNSRecord: Identifiable, Equatable {
    var recordId = ""
    var domainName = ""
    /// 主机记录（`@` 表示主域名本身）
    var rr = ""
    var type = "A"
    var value = ""
    var ttl = 600
    /// 解析线路（默认 default）
    var line = "default"
    /// ENABLE / DISABLE
    var status = "ENABLE"
    /// MX / SRV 才有
    var priority = ""

    var id: String { recordId }

    var displayRR: String { rr.isEmpty ? "@" : rr }

    /// 完整主机名，对照 acme.sh 生成的 `_acme-challenge` 记录时直接用这个
    var fqdn: String {
        let host = rr.isEmpty ? "@" : rr
        return host == "@" ? domainName : "\(host).\(domainName)"
    }

    var enabled: Bool { status.uppercased() != "DISABLE" }
}

/// 界面下拉里给的记录类型（阿里云支持的常见几种）
enum DNSRecordTypes {
    static let all = ["A", "AAAA", "CNAME", "TXT", "MX", "NS", "SRV", "CAA"]
    /// 需要填优先级的类型
    static func needsPriority(_ type: String) -> Bool { type == "MX" || type == "SRV" }
}

// MARK: - 阿里云签名（纯函数，可直接自测）

/// 阿里云 RPC 风格接口的签名。
///
/// 规则（官方「签名方法」文档）：
/// 1. 所有参数（含公共参数，**不含 `Signature` 自身**）按参数名**字典序**排序；
/// 2. 每个 k、v 各做一次 percentEncode，再用 `&` 拼成规范化查询串；
/// 3. `StringToSign = GET + "&" + percentEncode("/") + "&" + percentEncode(规范化查询串)`
///    —— 注意这里是**二次编码**，所以时间戳的 `:` 会变成 `%253A`；
/// 4. `Signature = Base64(HMAC-SHA1(AccessKeySecret + "&", StringToSign))`。
enum AliyunDNS {
    static let endpoint = "https://alidns.aliyuncs.com"
    static let version = "2015-01-09"

    /// 阿里云的 percentEncode：`A-Za-z0-9` 与 `-_.~` 原样保留，其余按 UTF-8 逐字节编码成 `%XY`（大写十六进制）。
    /// 空格编成 `%20` 而不是 `+`（这是它和 `urlencode` 的差别）。
    static func percentEncode(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x7E:
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// 规范化查询串：按参数名字典序，k/v 各自编码后 `k=v` 用 `&` 连接。
    static func canonicalQuery(_ params: [String: String]) -> String {
        params.keys.sorted()
            .map { "\(percentEncode($0))=\(percentEncode(params[$0] ?? ""))" }
            .joined(separator: "&")
    }

    /// `GET&%2F&<二次编码的规范化查询串>`
    static func stringToSign(method: String = "GET", params: [String: String]) -> String {
        "\(method)&\(percentEncode("/"))&\(percentEncode(canonicalQuery(params)))"
    }

    static func signature(secret: String, method: String = "GET", params: [String: String]) -> String {
        let key = SymmetricKey(data: Data((secret + "&").utf8))
        let message = Data(stringToSign(method: method, params: params).utf8)
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key)
        return Data(code).base64EncodedString()
    }

    /// ISO8601 UTC，形如 `2016-03-24T16:41:54Z`（服务端只容忍 15 分钟偏差）
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    // MARK: 响应解析（同样宽松：字段名/类型变了也不崩）

    /// 取 `root[key][innerKey]`，容忍三种形态：数组 / 包一层的字典 / 单个对象。
    static func list(_ root: [String: Any], _ key: String, _ innerKey: String) -> [[String: Any]] {
        if let direct = root[key] as? [[String: Any]] { return direct }
        guard let dict = root[key] as? [String: Any] else { return [] }
        if let many = dict[innerKey] as? [[String: Any]] { return many }
        if let one = dict[innerKey] as? [String: Any] { return [one] }
        return []
    }

    static func text(_ dict: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let value = dict[key] as? Int { return String(value) }
            if let value = dict[key] as? Double { return String(value) }
            if let value = dict[key] as? Bool { return value ? "true" : "false" }
        }
        return ""
    }

    static func number(_ dict: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let value = dict[key] as? Int { return value }
            if let value = dict[key] as? Double { return Int(value) }
            if let value = dict[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    static func parseDomains(_ json: [String: Any]) -> [DNSDomain] {
        list(json, "Domains", "Domain").compactMap { item in
            let name = text(item, ["DomainName", "domainName"])
            guard !name.isEmpty else { return nil }
            var domain = DNSDomain(name: name)
            domain.domainId = text(item, ["DomainId", "domainId"])
            domain.recordCount = number(item, ["RecordCount", "recordCount"]) ?? 0
            domain.versionName = text(item, ["VersionName", "versionName"])
            return domain
        }
    }

    static func parseRecords(_ json: [String: Any]) -> [DNSRecord] {
        list(json, "DomainRecords", "Record").compactMap { item in
            let recordId = text(item, ["RecordId", "recordId"])
            guard !recordId.isEmpty else { return nil }
            var record = DNSRecord(recordId: recordId)
            record.domainName = text(item, ["DomainName", "domainName"])
            record.rr = text(item, ["RR", "rr"])
            record.type = text(item, ["Type", "type"])
            record.value = text(item, ["Value", "value"])
            record.ttl = number(item, ["TTL", "ttl"]) ?? 600
            record.line = text(item, ["Line", "line"])
            record.status = text(item, ["Status", "status"])
            record.priority = text(item, ["Priority", "priority"])
            return record
        }
    }

    /// 把阿里云的错误码翻译成人能看懂的话（认不出来的原样显示）。
    static func describeError(code: String, message: String) -> String {
        let hint: String
        switch code {
        case "InvalidAccessKeyId.NotFound":
            hint = "AccessKey ID 不存在，检查有没有复制错。"
        case "SignatureDoesNotMatch":
            hint = "签名不匹配 —— AccessKey Secret 填错了（或者里面有空格）。"
        case "Forbidden.RAM", "Forbidden", "NoPermission":
            hint = "这个 AccessKey 没有解析权限。给它挂 AliyunDNSFullAccess（或只读 + 解析管理的自定义策略）。"
        case "DomainRecordDuplicate":
            hint = "已经有一条一模一样的记录（相同主机记录 + 类型 + 值）。"
        case "DomainRecordNotBelongToUser", "InvalidDomainName.NoExist":
            hint = "域名不在这个账号下，或者域名拼错了。"
        case "DomainRecordOperatingLimit":
            hint = "操作太频繁，等几秒再试。"
        default:
            hint = "阿里云返回：\(message.isEmpty ? "（没有附带说明）" : message)"
        }
        return "[\(code)] \(hint)"
    }
}

// MARK: - 客户端

/// 阿里云云解析的调用封装。
///
/// 走 `curl` + 手写签名（和「宝塔面板」那页一样，不引第三方库）。
/// 全部是 GET + query string，响应一律 JSON。
final class DNSService: @unchecked Sendable {
    private(set) var settings: DNSSettings

    init(settings: DNSSettings) {
        self.settings = settings
    }

    var isConfigured: Bool { settings.isConfigured }

    /// 调用一次 OpenAPI。`params` 是业务参数（公共参数与签名在这里自动补）。
    func call(_ action: String, params: [String: String] = [:]) -> Outcome<[String: Any]> {
        guard settings.isConfigured else {
            return .failure("还没配阿里云 AccessKey。在「域名解析」页顶上填 AccessKey ID / Secret 后就能用了。")
        }
        let key = settings.aliKey.trimmingCharacters(in: .whitespaces)
        let secret = settings.aliSecret.trimmingCharacters(in: .whitespaces)

        var all: [String: String] = [
            "Action": action,
            "Format": "JSON",
            "Version": AliyunDNS.version,
            "AccessKeyId": key,
            "SignatureMethod": "HMAC-SHA1",
            "SignatureVersion": "1.0",
            "SignatureNonce": UUID().uuidString,
            "Timestamp": AliyunDNS.timestamp(),
        ]
        for (name, value) in params { all[name] = value }
        // 签名必须在「补上 Signature 之前」算，且不包含 Signature 自己。
        all["Signature"] = AliyunDNS.signature(secret: secret, params: all)

        let url = AliyunDNS.endpoint + "/?" + AliyunDNS.canonicalQuery(all)
        let result = Shell.run(["curl", "-s", "-S", "--max-time", "30", url], timeout: 45)
        let body = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return .failure("请求失败（没收到响应）：\(result.message)")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else {
            return .failure("返回的不是 JSON：\n\(body.prefix(400))")
        }
        if let code = json["Code"] as? String, !code.isEmpty {
            return .failure(AliyunDNS.describeError(code: code, message: json["Message"] as? String ?? ""))
        }
        return .success(json)
    }

    // MARK: 读

    func domains() -> Outcome<[DNSDomain]> {
        let params = ["PageNumber": "1", "PageSize": String(settings.clampedPageSize)]
        return call("DescribeDomains", params: params).map(AliyunDNS.parseDomains)
    }

    func records(domain: String) -> Outcome<[DNSRecord]> {
        let params = ["DomainName": domain,
                      "PageNumber": "1",
                      "PageSize": String(settings.clampedPageSize)]
        return call("DescribeDomainRecords", params: params).map(AliyunDNS.parseRecords)
    }

    // MARK: 写

    /// 返回一句给人看的成功说明（顺带带上新记录的 RecordId）
    func addRecord(domain: String, rr: String, type: String, value: String,
                   ttl: Int, priority: String) -> Outcome<String> {
        let host = Self.normalizeRR(rr, domain: domain)
        if let message = validate(rr: host, type: type, value: value, priority: priority) {
            return .failure(message)
        }

        var params = ["DomainName": domain,
                      "RR": host,
                      "Type": type,
                      "Value": value,
                      "TTL": String(min(max(ttl, 60), 86400))]
        // Priority 只对 MX / SRV 有意义；别的类型带上它阿里云会挑刺
        if DNSRecordTypes.needsPriority(type) {
            let pri = priority.trimmingCharacters(in: .whitespaces)
            if !pri.isEmpty { params["Priority"] = pri }
        }
        return call("AddDomainRecord", params: params).map { json in
            let id = AliyunDNS.text(json, ["RecordId", "recordId"])
            return "已添加（RecordId \(id.isEmpty ? "未知" : id)）"
        }
    }

    func updateRecord(recordId: String, domain: String, rr: String, type: String, value: String,
                      ttl: Int, priority: String) -> Outcome<String> {
        let host = Self.normalizeRR(rr, domain: domain)
        if let message = validate(rr: host, type: type, value: value, priority: priority) {
            return .failure(message)
        }

        var params = ["RecordId": recordId,
                      "RR": host,
                      "Type": type,
                      "Value": value,
                      "TTL": String(min(max(ttl, 60), 86400))]
        if DNSRecordTypes.needsPriority(type) {
            let pri = priority.trimmingCharacters(in: .whitespaces)
            if !pri.isEmpty { params["Priority"] = pri }
        }
        return call("UpdateDomainRecord", params: params).map { _ in "已保存修改。" }
    }

    func deleteRecord(recordId: String) -> Outcome<String> {
        call("DeleteDomainRecord", params: ["RecordId": recordId]).map { _ in "已删除。" }
    }

    /// 本地先挡一道：阿里云对这些的报错文案不算好懂，而且来回一趟也慢。
    ///
    /// `rr` 应该是已经过 `normalizeRR` 的值（或者本来就只填子域名部分）。
    /// 多级子域名（`account.admin`）是合法写法，阿里云原样接受；
    /// 这里只管格式，不再把「带点」一律当成误填了整个域名。
    func validate(rr: String, type: String, value: String, priority: String) -> String? {
        if let message = Self.validateRR(rr) { return message }
        let recordValue = value.trimmingCharacters(in: .whitespaces)
        if recordValue.isEmpty { return "记录值不能为空" }
        let upper = type.uppercased()
        if upper == "A" {
            let parts = recordValue.split(separator: ".")
            let isIPv4 = parts.count == 4 && parts.allSatisfy { Int($0).map { 0...255 ~= $0 } ?? false }
            if !isIPv4 { return "A 记录的值要是一个 IPv4 地址，比如 1.2.3.4" }
        }
        if DNSRecordTypes.needsPriority(upper) {
            let pri = priority.trimmingCharacters(in: .whitespaces)
            guard let level = Int(pri), (1...50).contains(level) else {
                return "\(upper) 记录要填优先级（1–50，越小越优先）"
            }
        }
        return nil
    }

    /// 主机记录的手误抢救：最常见的是把整个域名（`www.example.com`）填进主机记录。
    /// 已知域名时剥掉这个后缀，让 `www.example.com` 落成 `www`，而不是报错卡住。
    /// 真正的多级子域名（`account.admin`）不以域名结尾，原样保留。
    static func normalizeRR(_ rr: String, domain: String) -> String {
        var host = rr.trimmingCharacters(in: .whitespaces)
        let base = domain.trimmingCharacters(in: .whitespaces)
        if !base.isEmpty, host.lowercased().hasSuffix("." + base.lowercased()) {
            host = String(host.dropLast(base.count + 1))
        }
        return host
    }

    /// 主机记录的格式校验：`@`（主域名）与 `*`（泛解析）直接放行；
    /// 其余按 DNS 标签来——每段 1–63 字符，字母/数字/下划线开头结尾，中间可带连字符
    /// （`_acme-challenge` 这类下划线开头的保留标签也因此放行）。
    static func validateRR(_ rr: String) -> String? {
        let host = rr.trimmingCharacters(in: .whitespaces)
        if host.isEmpty { return "主机记录不能为空（主域名本身请填 @）" }
        if host.contains(" ") { return "主机记录里有空格" }
        if host == "@" || host == "*" { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.contains(where: { $0.isEmpty }) {
            return "主机记录里有连续或多余的点（比如 a..b）"
        }
        for label in labels {
            if label.count > 63 { return "主机记录每段最长 63 个字符" }
            let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
            let isInner: (Character) -> Bool = { isWord($0) || $0 == "-" }
            if !isWord(label.first!) || !isWord(label.last!) {
                return "主机记录每段要以字母、数字或下划线开头结尾（比如 account.admin、_acme-challenge）"
            }
            if !label.allSatisfy(isInner) {
                return "主机记录只能包含字母、数字、连字符和下划线"
            }
        }
        return nil
    }
}

// MARK: - 页面状态

struct DNSState {
    var domains: [DNSDomain] = []
    var selectedDomain: String?
    var records: [DNSRecord] = []
    /// 正在编辑/新增时表单里填的内容
    var editor = DNSRecordDraft()
    /// 有值表示正在改这条记录（nil = 新增）
    var editingRecordId: String?
    var detail = ""
    var detailKind = ""
    var loadedAt: Date?
    var message = ""
    var error = ""

    var selectedDomainObject: DNSDomain? {
        guard let selectedDomain else { return nil }
        return domains.first { $0.name == selectedDomain }
    }
}

/// 表单里的草稿。和 `DNSRecord` 分开：这里全是字符串，方便直接绑 TextField。
struct DNSRecordDraft: Equatable {
    var rr = ""
    var type = "A"
    var value = ""
    var ttl = "600"
    var priority = ""

    var isBlank: Bool {
        rr.trimmingCharacters(in: .whitespaces).isEmpty
            && value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    mutating func clear(defaultTTL: Int) {
        rr = ""
        type = "A"
        value = ""
        ttl = String(defaultTTL)
        priority = ""
    }

    static func from(_ record: DNSRecord, defaultTTL: Int) -> DNSRecordDraft {
        DNSRecordDraft(rr: record.rr,
                       type: record.type.isEmpty ? "A" : record.type,
                       value: record.value,
                       ttl: String(record.ttl > 0 ? record.ttl : defaultTTL),
                       priority: record.priority)
    }
}
