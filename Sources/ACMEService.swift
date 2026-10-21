import Foundation

// MARK: - 设置与数据结构

struct ACMESettings: Codable, Equatable {
    var bin = ""              // acme.sh 路径（留空自动探测）
    var email = ""            // 账户邮箱（到期提醒）
    var keylength = "ec-256"  // ec-256（ECC）或 2048（RSA）

    // 阿里云 AccessKey 曾经存在这里（aliKey / aliSecret），现在归 DNSSettings 管：
    // SettingsStore.load() 会把老配置一次性搬过去，所以这里不再保留这两个字段。

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bin = try container.decodeIfPresent(String.self, forKey: .bin) ?? bin
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? email
        keylength = try container.decodeIfPresent(String.self, forKey: .keylength) ?? keylength
    }
}

struct ACMEStatus {
    var installed = false
    var bin = ""
    var home = ""
    var version = ""
    var accountEmail = ""
}

/// 手动 DNS 模式需要添加的一条 TXT 记录
struct ACMEChallenge: Identifiable {
    var recordName: String
    var recordValue: String
    var id: String { recordName + "|" + recordValue }
}

struct ACMECertificate: Identifiable {
    var domain: String            // 主域名
    var keyLength: String
    var sanDomains: String        // 附加域名（no 或逗号分隔）
    var ca: String
    var created: String
    var renewAt: String
    var home: String = ""

    /// 同一个域名可能同时有 RSA 和 ECC 两份证书（目录不同），id 得带上算法才不会撞。
    var id: String { "\(domain)|\(keyLength)" }

    /// acme.sh 的判据：密钥长度不是 1024/2048/3072/4096/8192 就算 ECC。
    var isECC: Bool { ACMECertificate.isECCKeyLength(keyLength) }

    var keyLabel: String { "\(isECC ? "ECC" : "RSA") \(keyLength)" }

    static func isECCKeyLength(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return false }
        return !["1024", "2048", "3072", "4096", "8192"].contains(text)
    }

    /// acme.sh 按密钥算法分目录：ECDSA 放 `<域名>_ecc`，RSA 放 `<域名>`。
    /// 一般按算法判定就够；但算法字段来自 `--list` 的文本输出、目录也可能被人手工搬过，
    /// 所以**磁盘上只存在哪一个就以哪一个为准**——acme.sh 自己也是这个回退顺序。
    private var certificateDirectory: String {
        let ecc = "\(home)/\(domain)_ecc"
        let plain = "\(home)/\(domain)"
        let hasECC = FileManager.default.fileExists(atPath: ecc)
        let hasPlain = FileManager.default.fileExists(atPath: plain)
        if hasECC != hasPlain { return hasECC ? ecc : plain }
        return isECC ? ecc : plain
    }

    var keyPath: String { "\(certificateDirectory)/\(domain).key" }
    var fullchainPath: String { "\(certificateDirectory)/fullchain.cer" }
    var certPath: String { "\(certificateDirectory)/\(domain).cer" }

    /// 读出部署要用的两个文件。失败时把**具体路径**报出来，
    /// 因为这里最容易踩的坑就是 ECC 证书的 `_ecc` 目录没拼上。
    func readDeploymentFiles() throws -> (certificate: String, privateKey: String) {
        func read(_ path: String) throws -> String {
            do {
                return try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw ACMEFileError.unreadable(path: path)
            }
        }
        return (try read(fullchainPath), try read(keyPath))
    }
}

enum ACMEFileError: LocalizedError {
    case unreadable(path: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path):
            return "读不到证书文件：\(path)\n"
                 + "证书可能已被删除，或 acme.sh 的目录与预期不一致"
                 + "（ECC 证书在「<域名>_ecc」目录，RSA 在「<域名>」目录）。\n"
                 + "可在「证书」页点「刷新」重新读取列表，再试一次。"
        }
    }
}

// MARK: - 服务

/// Let's Encrypt 证书申请，走 acme.sh。
/// - 阿里云模式：`--dns dns_ali`，凭据通过 Ali_Key / Ali_Secret 环境变量传入（DNS-01 验证）。
/// - 腾讯云模式：`--dns dns_tencent`，凭据通过 Tencent_SecretId / Tencent_SecretKey
///   环境变量传入，调用腾讯云 DNSPod 接口写 TXT 记录。
/// - 手动模式：acme.sh 的手动 DNS 两段式 —— 先拿到 TXT 记录，用户自行添加，再完成验证。
final class ACMEService: @unchecked Sendable {
    private(set) var settings: ACMESettings

    init(settings: ACMESettings) {
        self.settings = settings
    }

    // MARK: 路径

    var bin: String? {
        let custom = settings.bin.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return FileTools.exists(custom) ? custom : nil }
        let homeDir = NSHomeDirectory()
        let candidates = [
            homeDir + "/.acme.sh/acme.sh",
            Paths.brewPrefix + "/bin/acme.sh",
            "/usr/local/bin/acme.sh",
            homeDir + "/.local/bin/acme.sh",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return Paths.which("acme.sh")
    }

    var home: String {
        let custom = settings.bin.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return (custom as NSString).deletingLastPathComponent }
        return NSHomeDirectory() + "/.acme.sh"
    }

    /// 官方安装命令（走 GitHub，国内网络常失败）
    var githubInstallCommand: String {
        let email = settings.email.trimmingCharacters(in: .whitespaces)
        return email.isEmpty
            ? "curl -s https://get.acme.sh | sh"
            : "curl -s https://get.acme.sh | sh -s email=\(Shell.shellQuote(email))"
    }

    /// 国内镜像安装命令（Gitee 上作者自己的仓库，官方文档「Install-in-China」推荐的方式）。
    /// acme.sh 是单文件脚本，所以直接下这一个文件就够。
    var giteeInstallCommand: String {
        let dir = home
        let file = "\(dir)/acme.sh"
        return "mkdir -p \(Shell.shellQuote(dir)) && curl -sL --max-time 90 -o \(Shell.shellQuote(file)) "
             + "https://gitee.com/neilpang/acme.sh/raw/master/acme.sh && chmod +x \(Shell.shellQuote(file))"
    }

    // MARK: 状态 / 安装

    func status() -> ACMEStatus {
        var info = ACMEStatus()
        info.bin = bin ?? ""
        info.home = home
        info.installed = bin != nil
        info.accountEmail = settings.email
        guard let bin else { return info }
        let version = Shell.run([bin, "--version"], timeout: 30)
        if version.ok, let line = version.stdout.lines.first(where: { !$0.isEmpty }) {
            info.version = line.trimmingCharacters(in: .whitespaces)
        }
        return info
    }

    /// 安装 acme.sh：先试官方源，失败**自动改用 Gitee 镜像**（国内直连 GitHub 常超时）。
    func install() -> ActionResult {
        let sources: [(name: String, command: String)] = [
            ("官方（GitHub）", githubInstallCommand),
            ("国内镜像（Gitee）", giteeInstallCommand),
        ]
        var failures: [String] = []
        for source in sources {
            Diag.log("安装 acme.sh（\(source.name)）：\(source.command)")
            let result = Shell.run(["/bin/sh", "-c", source.command], timeout: 300)
            if result.ok, bin != nil {
                return ActionResult(ok: true, message: "acme.sh 已安装（\(source.name)）",
                                    detail: "位置：\(bin ?? "")")
            }
            failures.append("【\(source.name)】"
                            + (result.ok ? "命令执行完了，但没找到 acme.sh" : result.message))
        }
        return .failure("acme.sh 安装失败（官方源和国内镜像都试过了）",
                        detail: failures.joined(separator: "\n\n")
                              + "\n\n也可以在终端自己执行：\n\(giteeInstallCommand)")
    }

    // MARK: 申请

    private func normalizedDomains(_ domains: [String]) -> [String] {
        domains
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func baseArgs(_ domains: [String], email: String) -> [String] {
        var args = ["--issue", "--server", "letsencrypt",
                    "--keylength", issueKeyLength]
        for domain in domains { args += ["-d", domain] }
        let mail = email.trimmingCharacters(in: .whitespaces)
        if !mail.isEmpty { args += ["--accountemail", mail] }
        return args
    }

    /// 申请时用的密钥算法，默认 ECDSA P-256（acme.sh 3.x 的默认值）。
    private var issueKeyLength: String {
        settings.keylength.trimmingCharacters(in: .whitespaces).isEmpty ? "ec-256" : settings.keylength
    }

    /// 申请完成后证书落在哪个目录：ECDSA 是 `<域名>_ecc`，RSA 是 `<域名>`。
    /// 提示里直接拼这个后缀，免得文案与实际目录对不上。
    private var issueDirectorySuffix: String {
        ACMECertificate.isECCKeyLength(issueKeyLength) ? "_ecc" : ""
    }

    /// acme.sh 的 DNS 插件（`dnsapi/*.sh`）不一定会跟主脚本一起装上（通过 Gitee
    /// 镜像只装了单文件），缺失时 acme.sh 会悄悄退回「手动模式」，只把 TXT 记录
    /// 打印出来而不去写解析，最后表现为验证失败。申请前先把插件补齐。
    private static let dnsAPIMirrors = [
        "https://cdn.jsdelivr.net/gh/acmesh-official/acme.sh@master/dnsapi",
        "https://gitee.com/neilpang/acme.sh/raw/master/dnsapi",
        "https://raw.githubusercontent.com/acmesh-official/acme.sh/master/dnsapi",
    ]

    /// 确保 `dnsapi/<name>.sh` 存在；成功返回 nil，失败返回可直接展示的说明。
    func ensureDNSAPI(_ name: String) -> String? {
        let directory = home + "/dnsapi"
        let target = directory + "/" + name + ".sh"
        if let text = try? String(contentsOfFile: target, encoding: .utf8),
           text.contains("\(name)_add") {
            return nil
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let temporary = directory + "/.\(name).sh.download"
        var failures: [String] = []
        for mirror in Self.dnsAPIMirrors {
            _ = try? FileManager.default.removeItem(atPath: temporary)
            let url = "\(mirror)/\(name).sh"
            let result = Shell.run(["/usr/bin/curl", "-fsSL", "--max-time", "30",
                                    "-o", temporary, url], timeout: 45)
            guard result.ok,
                  let text = try? String(contentsOfFile: temporary, encoding: .utf8),
                  text.contains("\(name)_add") else {
                failures.append("\(mirror)：\(result.ok ? "下载到的内容不完整" : result.message)")
                continue
            }
            _ = try? FileManager.default.removeItem(atPath: target)
            guard (try? FileManager.default.moveItem(atPath: temporary, toPath: target)) != nil else {
                failures.append("\(mirror)：写入 \(target) 失败")
                continue
            }
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: target)
            Diag.log("已补齐 acme.sh DNS 插件：\(target)")
            return nil
        }
        _ = try? FileManager.default.removeItem(atPath: temporary)
        return "缺少 acme.sh 的 \(name) 插件，自动下载失败。\n"
             + "可以手动把 \(name).sh 放到 \(directory)/ 后重试。\n\n"
             + failures.joined(separator: "\n")
    }

    /// 阿里云 DNS 自动验证（DNS-01）：acme.sh 自动写 TXT 记录、验证、再删掉。
    /// 凭据来自「域名解析」页那份统一配置（不再用证书页自己的字段）。
    func issueWithAliyun(domains: [String], email: String,
                         accessKey: String, accessSecret: String) -> ActionResult {
        guard let bin else {
            return .failure("找不到 acme.sh。可以点上面的「安装 acme.sh」，或在「设置」里指定路径。")
        }
        let list = normalizedDomains(domains)
        guard !list.isEmpty else { return .failure("至少要填一个域名") }
        let key = accessKey.trimmingCharacters(in: .whitespaces)
        let secret = accessSecret.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !secret.isEmpty else {
            return .failure("阿里云方式需要 AccessKey —— 在「域名解析」页里填一次，"
                            + "这里和那边共用同一份凭据。")
        }
        if let error = ensureDNSAPI("dns_ali") {
            return .failure("阿里云 DNS 插件不可用", detail: error)
        }

        var args = baseArgs(list, email: email)
        args += ["--dns", "dns_ali"]
        let env = ["Ali_Key": key, "Ali_Secret": secret, "Ali_Region": "cn-hangzhou"]

        Diag.log("申请证书（阿里云 DNS）：\(list.joined(separator: ", "))")
        let result = Shell.run([bin] + args, timeout: 600, extraEnv: env)
        guard result.ok else {
            return .failure("申请失败：\(result.message)", detail: String(result.stdout.suffix(800)))
        }
        return ActionResult(ok: true,
                            message: "证书已签发：\(list.joined(separator: ", "))",
                            detail: "证书目录：\(home)/\(list[0])\(issueDirectorySuffix)/\n\n"
                                  + String(result.stdout.suffix(400)))
    }

    /// 腾讯云 DNS 自动验证（DNS-01）：走 acme.sh 的 `dns_tencent` 插件
    /// （腾讯云 DNSPod API，不是 DNSPod 的独立 Token），自动写/删 TXT 记录。
    /// 凭据与阿里云一样存在当前「服务器运维」配置里，续期时继续复用。
    func issueWithTencent(domains: [String], email: String,
                          secretId: String, secretKey: String) -> ActionResult {
        guard let bin else {
            return .failure("找不到 acme.sh。可以点上面的「安装 acme.sh」，或在「设置」里指定路径。")
        }
        let list = normalizedDomains(domains)
        guard !list.isEmpty else { return .failure("至少要填一个域名") }
        let id = secretId.trimmingCharacters(in: .whitespaces)
        let key = secretKey.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !key.isEmpty else {
            return .failure("腾讯云方式需要 SecretId / SecretKey —— 在下方填一次，"
                            + "会随当前配置保存，续期时继续使用。")
        }
        if let error = ensureDNSAPI("dns_tencent") {
            return .failure("腾讯云 DNS 插件不可用", detail: error)
        }

        var args = baseArgs(list, email: email)
        args += ["--dns", "dns_tencent"]
        let env = ["Tencent_SecretId": id, "Tencent_SecretKey": key]

        Diag.log("申请证书（腾讯云 DNS）：\(list.joined(separator: ", "))")
        let result = Shell.run([bin] + args, timeout: 600, extraEnv: env)
        guard result.ok else {
            return .failure("申请失败：\(result.message)", detail: String(result.stdout.suffix(800)))
        }
        return ActionResult(ok: true,
                            message: "证书已签发：\(list.joined(separator: ", "))",
                            detail: "证书目录：\(home)/\(list[0])\(issueDirectorySuffix)/\n\n"
                                  + String(result.stdout.suffix(400)))
    }

    /// 手动 DNS 第一步：让 acme.sh 生成挑战，从输出里解析出需要手动添加的 TXT 记录。
    func issueManualStep1(domains: [String], email: String) -> Outcome<[ACMEChallenge]> {
        guard let bin else {
            return .failure("找不到 acme.sh。可以点上面的「安装 acme.sh」，或在「设置」里指定路径。")
        }
        let list = normalizedDomains(domains)
        guard !list.isEmpty else { return .failure("至少要填一个域名") }

        var args = baseArgs(list, email: email)
        args += ["--dns", "--yes-I-know-dns-manual-mode-enough-go-ahead-please"]

        Diag.log("申请证书（手动 DNS 第一步）：\(list.joined(separator: ", "))")
        let result = Shell.run([bin] + args, timeout: 300)
        let combined = result.stdout + "\n" + result.stderr
        let challenges = Self.parseManualChallenges(combined)
        guard !challenges.isEmpty else {
            return .failure("没能从 acme.sh 的输出里解析出 TXT 记录。\n\n原始输出：\n" + String(combined.suffix(900)))
        }
        return .success(challenges)
    }

    /// 手动 DNS 第二步：TXT 记录加好后重新验证并签发。
    func issueManualStep2(domains: [String], email: String) -> ActionResult {
        guard let bin else { return .failure("找不到 acme.sh") }
        let list = normalizedDomains(domains)
        guard !list.isEmpty else { return .failure("至少要填一个域名") }

        var args = ["--renew", "--server", "letsencrypt"]
        for domain in list { args += ["-d", domain] }
        args += ["--yes-I-know-dns-manual-mode-enough-go-ahead-please"]

        Diag.log("申请证书（手动 DNS 第二步）")
        let result = Shell.run([bin] + args, timeout: 600)
        guard result.ok else {
            return .failure("验证失败：\(result.message)",
                            detail: String(result.stdout.suffix(700))
                                  + "\n\n提示：DNS 记录生效需要时间（通常 1–10 分钟），稍等再点一次即可。")
        }
        return ActionResult(ok: true, message: "证书已签发：\(list.joined(separator: ", "))",
                            detail: "证书目录：\(home)/\(list[0])\(issueDirectorySuffix)/")
    }

    // MARK: 已签发的证书

    func listCertificates() -> Outcome<[ACMECertificate]> {
        guard let bin else {
            return .failure("找不到 acme.sh。可以点上面的「安装 acme.sh」，或在「设置」里指定路径。")
        }
        let result = Shell.run([bin, "--list"], timeout: 60)
        guard result.ok else {
            return .failure("读取证书列表失败：\(result.message)")
        }
        return .success(Self.parseList(result.stdout, home: home))
    }

    /// 解析 `acme.sh --list` 的输出。它是「空格/制表符对齐」的表：
    ///   Main_Domain  KeyLength  SAN_Domains  Profile  CA  Created  Renew
    ///   example.com  "ec-256"   no                   LetsEncrypt.org  2026-09-23T...  2026-12-22T...
    ///
    /// 有两个坑（acme.sh 3.1.x 起）：
    ///   1. KeyLength 会带引号（`"ec-256"`）。不剥掉的话「是不是 ECC」判定就会失败，
    ///      拼出来的证书路径少一层 `_ecc`，部署时读不到文件。
    ///   2. 表头多了 `Profile` 列，这一列有值时后面的字段会整体右移，
    ///      所以 Created/Renew 用 ISO 时间戳定位，CA 取它前面那个字段，不能写死下标。
    static func parseList(_ output: String, home: String) -> [ACMECertificate] {
        var result: [ACMECertificate] = []
        for line in output.lines {
            let fields = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { unquoted(String($0)) }
                .filter { !$0.isEmpty }
            guard fields.count >= 2, fields[0] != "Main_Domain" else { continue }
            let stamps = fields.indices.filter { isTimestamp(fields[$0]) }
            let createdIndex = stamps.first
            let caIndex = createdIndex.map { $0 - 1 } ?? -1
            result.append(ACMECertificate(domain: fields[0],
                                          keyLength: fields[1],
                                          sanDomains: fields.count > 2 && caIndex > 2 ? fields[2] : "no",
                                          ca: caIndex >= 3 && caIndex < fields.count ? fields[caIndex] : "",
                                          created: createdIndex.map { fields[$0] } ?? "",
                                          renewAt: stamps.count > 1 ? fields[stamps[1]] : "",
                                          home: home))
        }
        return result
    }

    /// 去掉 acme.sh 输出里给字符串字段加的引号（`"ec-256"` → `ec-256`）。
    private static func unquoted(_ value: String) -> String {
        var text = value
        while text.count >= 2, let first = text.first, let last = text.last {
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                text = String(text.dropFirst().dropLast())
            } else {
                break
            }
        }
        return text
    }

    /// acme.sh 的时间列长这样：`2026-09-23T10:00:00Z`。
    private static func isTimestamp(_ value: String) -> Bool {
        guard value.count >= 20, value.hasSuffix("Z") else { return false }
        let chars = Array(value)
        return chars[4] == "-" && chars[7] == "-" && chars[10] == "T" && chars[13] == ":"
    }

    /// 从 acme.sh 手动模式输出里解析 TXT 记录：
    ///   Domain: '_acme-challenge.example.com'
    ///   TXT value: 'xxxxx'
    static func parseManualChallenges(_ text: String) -> [ACMEChallenge] {
        var result: [ACMEChallenge] = []
        var pendingName: String?
        let trimSet = CharacterSet(charactersIn: "'\"` ")
        for line in text.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: "Domain: ") {
                pendingName = String(trimmed[range.upperBound...]).trimmingCharacters(in: trimSet)
            } else if let range = trimmed.range(of: "TXT value: ") {
                let value = String(trimmed[range.upperBound...]).trimmingCharacters(in: trimSet)
                if let name = pendingName, !name.isEmpty, !value.isEmpty {
                    result.append(ACMEChallenge(recordName: name, recordValue: value))
                    pendingName = nil
                }
            }
        }
        return result
    }

    func renew(domain: String, ecc: Bool = false,
               accessKey: String = "", accessSecret: String = "",
               tencentSecretId: String = "", tencentSecretKey: String = "") -> ActionResult {
        guard let bin else { return .failure("找不到 acme.sh") }
        let name = domain.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .failure("域名不能为空") }

        // 续期时如果 acme.sh 需要重新做 DNS-01，它得能自己写 TXT 记录，所以凭据一并带上。
        // 阿里云和腾讯云的键同时传没有副作用：acme.sh 只读证书对应的那个插件需要的变量。
        var env: [String: String] = [:]
        let key = accessKey.trimmingCharacters(in: .whitespaces)
        let secret = accessSecret.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty, !secret.isEmpty {
            env["Ali_Key"] = key
            env["Ali_Secret"] = secret
            env["Ali_Region"] = "cn-hangzhou"
            if let error = ensureDNSAPI("dns_ali") {
                return .failure("阿里云 DNS 插件不可用", detail: error)
            }
        }
        let tencentID = tencentSecretId.trimmingCharacters(in: .whitespaces)
        let tencentKey = tencentSecretKey.trimmingCharacters(in: .whitespaces)
        if !tencentID.isEmpty, !tencentKey.isEmpty {
            env["Tencent_SecretId"] = tencentID
            env["Tencent_SecretKey"] = tencentKey
            if let error = ensureDNSAPI("dns_tencent") {
                return .failure("腾讯云 DNS 插件不可用", detail: error)
            }
        }

        // ECC 证书必须显式带 --ecc，否则 acme.sh 可能去找 RSA 目录（`<域名>` 而不是 `<域名>_ecc`）。
        // RSA 与 ECC 两份证书同时存在时，不带 --ecc 会续错那一份。
        var args = [bin, "--renew", "-d", name, "--server", "letsencrypt"]
        if ecc { args.append("--ecc") }

        Diag.log("续期证书：\(name)\(ecc ? "（ECC）" : "（RSA）")")
        let result = Shell.run(args, timeout: 600, extraEnv: env)
        guard result.ok else {
            return .failure("续期失败：\(result.message)", detail: String(result.stdout.suffix(700)))
        }
        return ActionResult(ok: true, message: "\(name) 已续期", detail: String(result.stdout.suffix(400)))
    }

    /// 让 acme.sh 装好自动续期的定时任务（幂等）
    func installCron() -> ActionResult {
        guard let bin else { return .failure("找不到 acme.sh") }
        let result = Shell.run([bin, "--install-cronjob"], timeout: 60)
        guard result.ok else {
            return .failure("安装续期任务失败：\(result.message)", detail: String(result.stdout.suffix(400)))
        }
        return ActionResult(ok: true, message: "已安装自动续期任务（acme.sh 每天检查，到期前 30 天自动续）")
    }
}
