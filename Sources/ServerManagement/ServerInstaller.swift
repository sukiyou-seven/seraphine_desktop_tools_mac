import Foundation
import CryptoKit

struct ServerInstallResult: Decodable {
    let endpoint: String
    let token: String
    let fingerprint: String
}

struct SSHInstallOptions {
    let host: String
    let port: Int
    let user: String
    let address: String
    let password: String
    let keyPath: String
    let sudoPassword: String
    let useKey: Bool
}

struct SSHHostKeyChange {
    let hostIdentifier: String
    let oldFingerprint: String
    let newFingerprint: String
    let algorithm: String
    let publicKey: String
}

enum ServerInstallError: LocalizedError {
    case invalid(String)
    case command(String)
    case hostKeyChanged

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .command(let message): return message
        case .hostKeyChanged: return "SSH 主机密钥与上次记录不同，请在安装窗口中确认后继续。"
        }
    }
}

enum ServerInstaller {
    // 测试可使用临时文件；正式应用独立保存 SSH 主机公钥，不修改用户的 ~/.ssh/known_hosts。
    static var knownHostsFileOverride: URL?

    private static func knownHostsFile() throws -> URL {
        if let knownHostsFileOverride { return knownHostsFileOverride }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent("Seraphim/server-management", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory.appendingPathComponent("ssh_known_hosts")
    }

    private static func hostIdentifier(_ options: SSHInstallOptions) -> String {
        options.port == 22 ? options.host : "[\(options.host)]:\(options.port)"
    }

    static func bundledBinary(architecture: String) throws -> URL {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("sera-linux-\(architecture)"),
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw ServerInstallError.invalid("应用未内置 \(architecture) 的 Linux 安装文件，请重新构建应用")
        }
        return url
    }

    static func validate(_ options: SSHInstallOptions) throws {
        let host = options.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = options.address.trimmingCharacters(in: .whitespacesAndNewlines)
        for (name, value) in [("SSH 主机", host), ("HTTPS 连接地址", address)] {
            guard !value.isEmpty, value.count <= 253,
                  value.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil,
                  !value.contains(".."), !value.hasSuffix("."), !value.hasSuffix("-") else {
                throw ServerInstallError.invalid("\(name)须填写 IPv4 地址或域名，不含端口")
            }
        }
        guard options.port > 0 && options.port <= 65535 else {
            throw ServerInstallError.invalid("SSH 端口须在 1–65535 之间")
        }
        guard options.user.range(of: "^[a-zA-Z_][a-zA-Z0-9_-]*$", options: .regularExpression) != nil else {
            throw ServerInstallError.invalid("SSH 用户名格式无效")
        }
        if options.useKey {
            guard !options.keyPath.isEmpty, FileManager.default.isReadableFile(atPath: options.keyPath) else {
                throw ServerInstallError.invalid("请选择可读取的 SSH 私钥文件")
            }
        } else if options.password.isEmpty {
            throw ServerInstallError.invalid("请输入 SSH 密码")
        }
    }

    static func install(_ options: SSHInstallOptions, approvedKey: SSHHostKeyChange? = nil) throws -> ServerInstallResult {
        try validate(options)
        let knownHosts = try knownHostsFile()
        if let approvedKey {
            guard approvedKey.hostIdentifier == hostIdentifier(options) else {
                throw ServerInstallError.invalid("待确认的主机与当前 SSH 地址不一致")
            }
            try replaceKnownHost(approvedKey, file: knownHosts)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sera-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        var environment = ProcessInfo.processInfo.environment
        var common = ["-o", "StrictHostKeyChecking=\(approvedKey == nil ? "accept-new" : "yes")",
                      "-o", "UserKnownHostsFile=\(knownHosts.path)",
                      "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UpdateHostKeys=no",
                      "-o", "HashKnownHosts=no", "-o", "ConnectTimeout=15",
                      "-o", "NumberOfPasswordPrompts=1"]
        if let approvedKey {
            let algorithms = approvedKey.algorithm == "ssh-rsa"
                ? "rsa-sha2-512,rsa-sha2-256,ssh-rsa" : approvedKey.algorithm
            common += ["-o", "HostKeyAlgorithms=\(algorithms)"]
        }
        if options.useKey {
            common += ["-i", options.keyPath, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes"]
        } else {
            let askpass = directory.appendingPathComponent("askpass")
            try Data("#!/bin/sh\nprintf '%s\\n' \"$SERA_SSH_PASSWORD\"\n".utf8).write(to: askpass)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
            environment["SSH_ASKPASS"] = askpass.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "Seraphim:0"
            environment["SERA_SSH_PASSWORD"] = options.password
            common += ["-o", "PreferredAuthentications=password,keyboard-interactive",
                       "-o", "PubkeyAuthentication=no"]
        }

        let destination = "\(options.user)@\(options.host)"
        let ssh = "/usr/bin/ssh"
        let scp = "/usr/bin/scp"
        let archOutput = try run(ssh, common + ["-p", String(options.port), destination, "uname -m"],
                                 environment: environment)
        if FileManager.default.fileExists(atPath: knownHosts.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHosts.path)
        }
        let rawArch = archOutput.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { ["x86_64", "amd64", "aarch64", "arm64"].contains($0) }
            ?? archOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let architecture: String
        switch rawArch {
        case "x86_64", "amd64": architecture = "amd64"
        case "aarch64", "arm64": architecture = "arm64"
        default: throw ServerInstallError.invalid("不支持的服务器架构：\(rawArch)")
        }
        let binary = try bundledBinary(architecture: architecture)
        let remotePath = "/tmp/sera-install-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        defer { _ = try? run(ssh, common + ["-p", String(options.port), destination, "rm -f \(remotePath)"], environment: environment) }
        _ = try run(scp, common + ["-P", String(options.port), binary.path, "\(destination):\(remotePath)"],
                    environment: environment)

        let sudo = options.user == "root" ? "" : options.sudoPassword.isEmpty ? "sudo -n " : "sudo -S -p '' "
        let command = "\(sudo)\(remotePath) install -host \(options.address) -json"
        let input = options.user != "root" && !options.sudoPassword.isEmpty
            ? options.sudoPassword + "\n" : nil
        let output = try run(ssh, common + ["-p", String(options.port), destination, command],
                             environment: environment, input: input)
        let resultLine = output.split(separator: "\n").last { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        guard let resultLine, let data = String(resultLine).data(using: .utf8),
              let result = try? JSONDecoder().decode(ServerInstallResult.self, from: data) else {
            throw ServerInstallError.command("安装已执行，但无法读取连接信息。请到服务器运行 sudo cat /www/seraphim/server/config/token 并检查证书指纹。")
        }
        return result
    }

    static func inspectHostKeyChange(_ options: SSHInstallOptions) throws -> SSHHostKeyChange {
        try validate(options)
        let identifier = hostIdentifier(options)
        let file = try knownHostsFile()
        let environment = ProcessInfo.processInfo.environment
        let stored = (try? run("/usr/bin/ssh-keygen", ["-F", identifier, "-f", file.path],
                               environment: environment)) ?? ""
        let oldKeys = parseHostKeys(stored)
        let scanned = try run("/usr/bin/ssh-keyscan", ["-T", "10", "-p", String(options.port),
                                                       "-t", "ed25519,ecdsa,rsa", options.host],
                              environment: environment)
        let newKeys = parseHostKeys(scanned)
        guard let selected = newKeys.first(where: { key in oldKeys.contains(where: { $0.algorithm == key.algorithm }) })
                ?? newKeys.first else {
            throw ServerInstallError.command("无法读取服务器当前的 SSH 主机密钥，请检查地址和 SSH 端口。")
        }
        let old = oldKeys.first(where: { $0.algorithm == selected.algorithm }) ?? oldKeys.first
        return SSHHostKeyChange(hostIdentifier: identifier,
                                oldFingerprint: old.map { fingerprint($0.publicKey) } ?? "未记录",
                                newFingerprint: fingerprint(selected.publicKey),
                                algorithm: selected.algorithm, publicKey: selected.publicKey)
    }

    private static func parseHostKeys(_ output: String) -> [(algorithm: String, publicKey: String)] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3, !parts[0].hasPrefix("#"),
                  parts[1].hasPrefix("ssh-") || parts[1].hasPrefix("ecdsa-") else { return nil }
            let algorithm = String(parts[1])
            let publicKey = String(parts[2])
            guard Data(base64Encoded: publicKey) != nil else { return nil }
            return (algorithm, publicKey)
        }
    }

    private static func fingerprint(_ publicKey: String) -> String {
        guard let bytes = Data(base64Encoded: publicKey) else { return "无效密钥" }
        return "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    private static func replaceKnownHost(_ key: SSHHostKeyChange, file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        _ = try run("/usr/bin/ssh-keygen", ["-R", key.hostIdentifier, "-f", file.path],
                    environment: ProcessInfo.processInfo.environment)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(key.hostIdentifier) \(key.algorithm) \(key.publicKey)\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func run(_ executable: String, _ arguments: [String],
                            environment: [String: String], input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        if let input {
            let standardInput = Pipe()
            process.standardInput = standardInput
            try process.run()
            standardInput.fileHandleForWriting.write(Data(input.utf8))
            try? standardInput.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            if message.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || message.contains("Host key verification failed") {
                throw ServerInstallError.hostKeyChanged
            }
            throw ServerInstallError.command(message.isEmpty ? "SSH 命令失败（\(process.terminationStatus)）" : message)
        }
        return message
    }
}
