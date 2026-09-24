import Foundation
import Darwin

/// 服务器探测结果
struct VPNProbe {
    var osName = ""
    var arch = ""
    var kernel = ""
    var memoryMB = 0
    /// 是否已经装好 IPsec/IKEv2（有 ipsec 命令）
    var ikev2Installed = false
    /// UDP 500/4500 是否真的能到达（服务器抓包 + 本机发包验证）
    var udpReachable = false
    var udpDetail = ""
}

/// 本机 VPN 状态快照
struct VPNStatus {
    /// 描述文件是否已安装（看 com.apple.vpn.managed 是否在已装列表里）
    var profileInstalled = false
    /// 系统里可用的 VPN 服务名（scutil --nc list）
    var services: [String] = []
    /// 描述文件里配置的服务器地址
    var configuredHost = ""

    var hasService: Bool { !services.isEmpty }
}

/// 「网络代理」：通过 SSH 在远程服务器上自动搭建 IKEv2 VPN，
/// 把生成的 `.mobileconfig` 描述文件装进 macOS，实现**整机全局**代理
/// （所有 App 生效，而不只是 db-manager）。
///
/// 这里的关键做法都是实机验证过的，不要想当然改：
/// - **密码登录**用 `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force`，密码经**环境变量**传给辅助脚本，
///   不出现在命令行参数里（`ps` 看不到）。比 expect 干净，也不需要装 sshpass。
/// - **安装**走 `hwdsl2/setup-ipsec-vpn`：`vpnsetup.sh` 装好 IPsec 基础并**自动配置 IKEv2**，
///   产出 `/root/vpnclient.mobileconfig`。注意**必须先装 vpnsetup.sh**，
///   单独跑 `ikev2.sh` 会报 "must first set up the IPsec VPN server"。
/// - 官方站点 `get.vpnsetup.net` 有时被 Cloudflare 拦（返回挑战页），
///   所以优先从 GitHub raw / jsDelivr 取脚本。
/// - **描述文件必须由用户在系统设置里点「安装」**：macOS 27 已移除 `profiles install`，
///   命令行无法代劳。工具能做的是生成并 `open` 它。
/// - 服务器在 NAT 后（例如阿里云）时，**安全组必须放行 UDP 500 和 4500**，
///   否则 IKE 包根本到不了服务器 —— `checkUDP` 就是用来验证这一点的。
final class VPNService: @unchecked Sendable {
    private(set) var settings: VPNSettings

    private static let githubScript =
        "https://raw.githubusercontent.com/hwdsl2/setup-ipsec-vpn/master/vpnsetup.sh"
    private static let jsdelivrScript =
        "https://cdn.jsdelivr.net/gh/hwdsl2/setup-ipsec-vpn@master/vpnsetup.sh"

    init(settings: VPNSettings) {
        self.settings = settings
    }

    /// 生成只含字母数字的随机串。安装脚本对特殊字符有忌讳（会破坏它生成的配置），
    /// 而且这些串要直接填进客户端，所以不引入符号。
    static func randomSecret(_ length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var out = ""
        for _ in 0..<length { out.append(alphabet[Int.random(in: 0..<alphabet.count)]) }
        return out
    }

    // MARK: - SSH 基础

    /// 写一个 SSH_ASKPASS 辅助脚本（0700），只从环境变量读密码。
    ///
    /// 两个踩过的坑：
    /// 1. 不能放 `NSTemporaryDirectory()` —— 受限环境下不可写。
    /// 2. 必须用 `atomically: false` —— 原子写入会先在**系统临时目录**落临时文件再改名，
    ///    而那一步同样会被拦（表现为"无法创建 SSH 辅助脚本"）。
    private func makeAskpass() -> String? {
        guard !settings.sshPassword.isEmpty else { return nil }
        let directory = Paths.appSupport.appendingPathComponent("run").path
        Paths.ensureDirectory(forFile: directory + "/placeholder")
        let path = directory + "/askpass-\(UUID().uuidString).sh"
        let script = "#!/bin/sh\nprintf '%s\\n' \"$DBM_SSH_PASSWORD\"\n"
        do {
            try script.write(toFile: path, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            return path
        } catch {
            return nil
        }
    }

    private func sshEnv(askpass: String) -> [String: String] {
        [
            "SSH_ASKPASS": askpass,
            "SSH_ASKPASS_REQUIRE": "force",
            "DBM_SSH_PASSWORD": settings.sshPassword,
            "DISPLAY": ":0",
        ]
    }

    private var commonOptions: [String] {
        [
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=15",
            "-o", "PreferredAuthentications=password",
            "-o", "PubkeyAuthentication=no",
            "-o", "NumberOfPasswordPrompts=1",
        ]
    }

    private var target: String { "\(settings.sshUser)@\(settings.host)" }

    private func preconditionError() -> String? {
        if settings.host.isEmpty { return "还没填服务器地址" }
        if settings.sshUser.isEmpty { return "还没填 SSH 用户名" }
        if settings.sshPassword.isEmpty { return "还没填 SSH 密码" }
        return nil
    }

    /// 在服务器上执行命令
    func run(_ command: String, timeout: TimeInterval = 90) -> (ok: Bool, output: String) {
        if let error = preconditionError() { return (false, error) }
        guard let askpass = makeAskpass() else { return (false, "无法创建 SSH 辅助脚本") }
        defer { try? FileManager.default.removeItem(atPath: askpass) }

        let result = Shell.run(["/usr/bin/ssh"] + commonOptions
                               + ["-p", String(settings.sshPort), target, command],
                               timeout: timeout,
                               extraEnv: sshEnv(askpass: askpass))
        let output = [result.stdout, result.stderr]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        return (result.status == 0, output)
    }

    /// 从服务器取回文件（scp 用大写 -P 指定端口）
    func fetch(remotePath: String, localPath: String) -> (ok: Bool, output: String) {
        if let error = preconditionError() { return (false, error) }
        guard let askpass = makeAskpass() else { return (false, "无法创建 SSH 辅助脚本") }
        defer { try? FileManager.default.removeItem(atPath: askpass) }
        Paths.ensureDirectory(forFile: localPath)

        let result = Shell.run(["/usr/bin/scp"] + commonOptions
                               + ["-P", String(settings.sshPort), target + ":" + remotePath, localPath],
                               timeout: 150,
                               extraEnv: sshEnv(askpass: askpass))
        let output = [result.stdout, result.stderr]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        return (result.status == 0, output)
    }

    // MARK: - 探测

    /// 测试 SSH 能不能登进去，并顺带把服务器环境带回来。
    func probe() -> (probe: VPNProbe, output: String) {
        var probe = VPNProbe()
        let script = """
        cat /etc/os-release 2>/dev/null | grep -E '^PRETTY_NAME' | cut -d= -f2 | tr -d '"'
        uname -m
        uname -r
        awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null
        command -v ipsec >/dev/null 2>&1 && echo HAVE_IPSEC || echo NO_IPSEC
        """
        let (ok, output) = run(script, timeout: 40)
        guard ok else { return (probe, output) }

        let lines = output.lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let first = lines.first { probe.osName = first }
        if lines.count > 1 { probe.arch = lines[1] }
        if lines.count > 2 { probe.kernel = lines[2] }
        if lines.count > 3 { probe.memoryMB = Int(lines[3]) ?? 0 }
        probe.ikev2Installed = output.contains("HAVE_IPSEC")
        return (probe, output)
    }

    /// 验证 UDP 500/4500 是否真的能到达服务器。
    ///
    /// 做法：让服务器后台抓包，本机同一时间往这两个端口发几个 UDP 包，
    /// 再回来看抓到了几个 —— **0 个就说明包在到达服务器前被拦了**（云安全组）。
    /// 这是区分「安全组没放行」和「服务端配置问题」最快、也最确定的办法。
    func checkUDP() -> (reachable: Bool, detail: String) {
        let remoteCapture = "setsid nohup timeout 12 tcpdump -n -i any 'udp port 500 or udp port 4500' "
                          + "-c 20 > /tmp/dbmgr_ike_cap.txt 2>&1 < /dev/null & sleep 2; echo CAP_STARTED"

        let (started, startOutput) = run(remoteCapture, timeout: 40)
        guard started, startOutput.contains("CAP_STARTED") else {
            return (false, "无法在服务器上启动抓包（tcpdump 可能未安装）：\n" + startOutput)
        }

        // 本机发包
        for index in 1...3 {
            for port in [500, 4500] {
                _ = Shell.run(["/usr/bin/nc", "-u", "-w", "1", settings.host, String(port)],
                              timeout: 6)
                _ = index
            }
        }
        Thread.sleep(forTimeInterval: 4)

        let (ok, output) = run("grep -cE ' > ' /tmp/dbmgr_ike_cap.txt 2>/dev/null || echo 0", timeout: 40)
        guard ok else { return (false, "读取抓包结果失败：" + output) }
        let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        if count > 0 {
            return (true, "抓到 \(count) 个 UDP 包 —— 端口是通的，网络层没问题。")
        }
        return (false, """
        服务器一个包都没抓到（tcpdump 在跑，但 500/4500 的流量没到达）。
        这几乎一定是**云平台安全组/防火墙没放行**：
          · 入方向放行 UDP 500/4500（授权对象 0.0.0.0/0）
          · 注意是 UDP 协议，不是 TCP
        阿里云：ECS → 安全组 → 配置规则 → 入方向 → 手动添加。
        """)
    }

    // MARK: - 安装

    /// 在服务器上安装 IPsec + IKEv2，并生成客户端描述文件。
    /// 后台执行 + 轮询，避免 SSH 中途断开把安装打断（实测踩过这个坑）。
    func install() -> ActionResult {
        // 1) 取安装脚本（官方源可能被 Cloudflare 拦，用 GitHub raw / jsDelivr 兜底）
        let download = """
        if curl -fsSL --max-time 40 -o /tmp/vpnsetup.sh \(Self.githubScript) \\
           && [ "$(wc -c < /tmp/vpnsetup.sh)" -gt 5000 ]; then echo DOWNLOAD=githuib
        else curl -fsSL --max-time 40 -o /tmp/vpnsetup.sh \(Self.jsdelivrScript) \\
             && echo DOWNLOAD=jsdelivr; fi
        wc -c < /tmp/vpnsetup.sh
        head -2 /tmp/vpnsetup.sh
        """
        let (downloaded, downloadOutput) = run(download, timeout: 90)
        guard downloaded, downloadOutput.contains("DOWNLOAD=") else {
            return .failure("下载安装脚本失败", detail: downloadOutput)
        }
        guard downloadOutput.contains("Script for automatic setup") else {
            // 拿到的大概率是 Cloudflare 挑战页
            return .failure("下载到的不是安装脚本（可能被 CDN 拦截）",
                            detail: downloadOutput.prefix(400).description)
        }

        // 2) 后台启动安装。
        // ⚠️ VPN 凭据**独立生成**，绝不复用 SSH 密码（那样等于把登录密码散播到 VPN 侧）。
        // 这些命令会进运行日志，所以 Shell.redactSecrets 专门加了
        // VPN_IPSEC_PSK / VPN_PASSWORD 的遮罩规则。
        let psk = Self.randomSecret(32)
        let vpnPassword = Self.randomSecret(20)
        let install = """
        cd /tmp && setsid env VPN_IPSEC_PSK='\(psk)' \
          VPN_USER='\(settings.clientName)' VPN_PASSWORD='\(vpnPassword)' \
          nohup bash /tmp/vpnsetup.sh > /tmp/vpn_install.log 2>&1 < /dev/null &
        sleep 6; echo INSTALL_STARTED; tail -5 /tmp/vpn_install.log
        """
        let (started, startOutput) = run(install, timeout: 60)
        guard started, startOutput.contains("INSTALL_STARTED") else {
            return .failure("启动安装失败", detail: startOutput)
        }
        return ActionResult(ok: true, message: "安装已在服务器后台开始",
                            detail: startOutput)
    }

    /// 轮询安装进度（安装要几分钟，所以拆成可重复调用的一步）。
    func installProgress() -> (done: Bool, failed: Bool, log: String) {
        let (ok, output) = run("tail -30 /tmp/vpn_install.log 2>/dev/null; "
                             + "echo ---SIGN---; "
                             + "grep -cE 'IKEv2 setup successful|Installation successful' /tmp/vpn_install.log 2>/dev/null || echo 0; "
                             + "echo ---BUSY---; "
                             + "pgrep -c -f 'make|vpn.sh|vpnsetup' 2>/dev/null || echo 0",
                             timeout: 60)
        guard ok else { return (false, false, output) }

        let done = output.contains("IKEv2 setup successful") || output.contains("Installation successful")
        let failed = output.contains("Error:") && !done
        let busy = output.lines.last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "0"
        let stillRunning = (Int(busy) ?? 0) > 0
        return (done, failed && !stillRunning, output)
    }

    // MARK: - 描述文件

    /// 从服务器取回描述文件（以及 p12 / sswan 备用格式）
    func fetchProfile(into directory: String) -> ActionResult {
        Paths.ensureDirectory(forFile: directory + "/x")
        let base = settings.remoteProfilePath
        let stem = (base as NSString).deletingPathExtension
        var saved: [String] = []
        var messages: [String] = []

        for ext in ["mobileconfig", "p12", "sswan"] {
            let remote = stem + "." + ext
            let local = directory + "/vpnclient." + ext
            let (ok, output) = fetch(remotePath: remote, localPath: local)
            if ok, FileTools.exists(local) {
                saved.append(local)
            } else {
                messages.append("\(ext)：\(output.prefix(200))")
            }
        }
        guard !saved.isEmpty else {
            return .failure("没能取回描述文件", detail: messages.joined(separator: "\n"))
        }
        var result = ActionResult(ok: true, message: "已取回 \(saved.count) 个客户端配置")
        result.detail = saved.joined(separator: "\n")
        result.backupPath = saved.first ?? ""
        return result
    }

    /// 打开描述文件，交给系统弹出安装向导。
    /// macOS 27 起 `profiles install` 已被移除，只能由用户点「安装」。
    func openProfile(at path: String) -> ActionResult {
        guard FileTools.exists(path) else {
            return .failure("描述文件不存在：\(path)")
        }
        let result = Shell.run(["/usr/bin/open", path], timeout: 20)
        guard result.status == 0 else {
            return .failure("打开描述文件失败", detail: result.stderr)
        }
        return ActionResult(ok: true, message: "已打开描述文件 —— 请在系统弹窗里点「安装」",
                            detail: "安装位置：系统设置 → 通用 → 设备管理（或 VPN 与设备管理）. "
                                  + "装完后 VPN 会出现在「系统设置 → VPN」，点连接即可全局生效。")
    }

    /// 复制一份描述文件到 iCloud Drive（iPhone 上直接取用）
    func backupToICloud(from path: String) -> ActionResult {
        guard FileTools.exists(path) else { return .failure("描述文件不存在：\(path)") }
        let folder = Paths.iCloudDocuments
        guard !folder.isEmpty else {
            return .failure("找不到 iCloud Drive（可能没开启 iCloud 云盘）")
        }
        let name = "seraphine-vpn-\(settings.host).mobileconfig"
        let target = folder + "/" + name
        do {
            if FileTools.exists(target) { try FileManager.default.removeItem(atPath: target) }
            try FileManager.default.copyItem(atPath: path, toPath: target)
        } catch {
            return .failure("复制到 iCloud 失败：\(error.localizedDescription)")
        }
        var result = ActionResult(ok: true, message: "已备份到 iCloud 文稿")
        result.backupPath = target
        result.detail = "iPhone：文件 → iCloud 云盘 → 文稿 → \(name)，点它安装描述文件。"
        return result
    }

    // MARK: - 本机 VPN 状态

    /// 读本机 VPN 状态。
    /// 注意：`scutil --nc list` 在某些受限环境（例如沙箱）里看不到任何服务，
    /// 所以这里只把它当参考，描述文件是否存在单独判断。
    func status() -> VPNStatus {
        var status = VPNStatus()
        status.configuredHost = settings.host

        // 描述文件：看系统里有没有 com.apple.vpn.managed（我们生成的那个 identifier 前缀）
        let profiles = Shell.run(["/usr/bin/profiles", "list", "-type=configuration"], timeout: 30)
        status.profileInstalled = profiles.stdout.contains("com.apple.vpn.managed")

        // VPN 服务列表
        let ncList = Shell.run(["/usr/sbin/scutil", "--nc", "list"], timeout: 25)
        status.services = ncList.stdout.lines.compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("*") || text.contains("IKEv2") || text.contains("VPN") else { return nil }
            // 形如：* (Disconnected)  "名称" [IPSec ...]
            guard let first = text.range(of: "\""), let last = text.range(of: "\"", options: .backwards),
                  first.upperBound < last.lowerBound else { return nil }
            return String(text[first.upperBound..<last.lowerBound])
        }
        return status
    }

    /// 连接/断开系统 VPN（用 scutil 控制，装好描述文件后就能用）
    func setConnected(_ connected: Bool) -> ActionResult {
        let status = status()
        guard let name = status.services.first else {
            return .failure("系统里还没有可用的 VPN 服务",
                            detail: "请先在「系统设置 → VPN」里确认 \(settings.host) 已出现；"
                                  + "若没有，重新安装描述文件。")
        }
        let verb = connected ? "start" : "stop"
        let result = Shell.run(["/usr/sbin/scutil", "--nc", verb, name], timeout: 45)
        if result.status != 0, !result.stderr.isEmpty {
            return .failure("\(connected ? "连接" : "断开")失败", detail: result.stderr)
        }
        return ActionResult(ok: true,
                            message: "\(name) \(connected ? "连接中…" : "已断开")")
    }
}
