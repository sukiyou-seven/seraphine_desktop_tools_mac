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

    var id: String { domain }

    private var certificateDirectory: String { keyLength.hasPrefix("ec-") ? "\(home)/\(domain)_ecc" : "\(home)/\(domain)" }
    var keyPath: String { "\(certificateDirectory)/\(domain).key" }
    var fullchainPath: String { "\(certificateDirectory)/fullchain.cer" }
    var certPath: String { "\(certificateDirectory)/\(domain).cer" }
}

// MARK: - 服务

/// Let's Encrypt 证书申请，走 acme.sh。
/// - 阿里云模式：`--dns dns_ali`，凭据通过 Ali_Key / Ali_Secret 环境变量传入（DNS-01 验证）。
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
                    "--keylength", settings.keylength.isEmpty ? "ec-256" : settings.keylength]
        for domain in domains { args += ["-d", domain] }
        let mail = email.trimmingCharacters(in: .whitespaces)
        if !mail.isEmpty { args += ["--accountemail", mail] }
        return args
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
                            detail: "证书目录：\(home)/\(list[0])_ecc/\n\n"
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
                            detail: "证书目录：\(home)/\(list[0])_ecc/")
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
    ///   Main_Domain   KeyLength  SAN_Domains  CA              Created              Renew
    ///   example.com   ec-256     no           LetsEncrypt.org 2026-09-23T...       2026-12-22T...
    static func parseList(_ output: String, home: String) -> [ACMECertificate] {
        var result: [ACMECertificate] = []
        for line in output.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let fields = trimmed
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard fields.count >= 2 else { continue }
            if fields[0] == "Main_Domain" { continue }        // 表头
            result.append(ACMECertificate(domain: fields[0],
                                          keyLength: fields[1],
                                          sanDomains: fields.count > 2 ? fields[2] : "no",
                                          ca: fields.count > 3 ? fields[3] : "",
                                          created: fields.count > 4 ? fields[4] : "",
                                          renewAt: fields.count > 5 ? fields[5] : "",
                                          home: home))
        }
        return result
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

    func renew(domain: String, accessKey: String = "", accessSecret: String = "") -> ActionResult {
        guard let bin else { return .failure("找不到 acme.sh") }
        let name = domain.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return .failure("域名不能为空") }

        // 续期时如果 acme.sh 需要重新做 DNS-01，它得能自己写 TXT 记录，所以凭据一并带上
        var env: [String: String] = [:]
        let key = accessKey.trimmingCharacters(in: .whitespaces)
        let secret = accessSecret.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty, !secret.isEmpty {
            env = ["Ali_Key": key, "Ali_Secret": secret, "Ali_Region": "cn-hangzhou"]
        }

        Diag.log("续期证书：\(name)")
        let result = Shell.run([bin, "--renew", "-d", name, "--server", "letsencrypt"],
                               timeout: 600, extraEnv: env)
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
