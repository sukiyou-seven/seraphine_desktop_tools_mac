import SwiftUI

/// 在网站管理里直接部署证书。
///
/// 证书文件在本机（acme.sh 的产物），部署动作是把 PEM 内容通过 API 送到服务器，
/// 所以这里只需要挑证书，不必再挑服务器——服务器就是当前网站所在的那台。
/// 服务器会自己校验证书是否覆盖网站的全部域名、是否在有效期、443 是否已被别的网站占用，
/// 因此本机的匹配判断只用来提示，不代替服务端的判断。
struct SiteCertificateSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let site: RemoteSite
    let connection: ServerConnection
    let token: String
    var openDomains: () -> Void = {}
    var onDeployed: () -> Void = {}

    @State private var certificateID = ""
    @State private var working = false
    @State private var message = ""

    /// 覆盖本站域名的证书排在前面，选不中的一眼能看出原因。
    private var certificates: [ACMECertificate] {
        model.acmeCertificates.sorted { left, right in
            if coversSite(left) != coversSite(right) { return coversSite(left) }
            return left.domain.localizedStandardCompare(right.domain) == .orderedAscending
        }
    }

    /// 证书列表是异步加载的，所以选中项在没被手动改过时始终跟着「第一张可用的证书」走。
    private var selection: Binding<String> {
        Binding(get: { certificateID.isEmpty ? defaultCertificateID : certificateID },
                set: { certificateID = $0 })
    }

    private var defaultCertificateID: String {
        certificates.first(where: coversSite)?.id ?? certificates.first?.id ?? ""
    }

    private var selectedCertificate: ACMECertificate? {
        certificates.first { $0.id == selection.wrappedValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("部署 HTTPS 证书").font(.title3.weight(.semibold))
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            InfoRow(label: "网站", value: site.domains.joined(separator: "、"))
            InfoRow(label: "Web 服务", value: "\(site.providerLabel) · \(site.root)")
            InfoRow(label: "当前状态", value: statusText)

            Divider()

            if certificates.isEmpty {
                emptyState
            } else {
                picker
            }

            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
                    .frame(maxWidth: 560, alignment: .leading)
            }

            HStack {
                if !certificates.isEmpty {
                    Button("刷新证书列表") { model.loadCertificates() }.disabled(working)
                }
                Spacer()
                Button("取消") { dismiss() }.disabled(working)
                Button("部署") { Task { await deploy() } }
                    .disabled(working || selectedCertificate == nil || !site.enabled)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task {
            // 网站管理页平时不碰证书，进这个弹窗时才去读本机 acme.sh 的列表。
            model.refreshACMEStatus()
            model.loadCertificates()
        }
    }

    private var statusText: String {
        guard site.tlsEnabled else { return "未部署证书，仅 HTTP" }
        guard let expiry = site.tlsExpiryDate else { return "已启用 HTTPS" }
        return "已启用 HTTPS · 证书到期 \(expiry)"
    }

    @ViewBuilder private var picker: some View {
        Picker("证书", selection: selection) {
            ForEach(certificates) { certificate in
                Text(verbatim: label(certificate)).tag(certificate.id)
            }
        }
        .disabled(working)

        if let certificate = selectedCertificate {
            InfoRow(label: "证书路径", value: certificate.fullchainPath)
            if !coversSite(certificate) {
                Text(verbatim: "此证书只覆盖 \(certificateNames(certificate).joined(separator: "、"))，"
                     + "没有覆盖本网站的 \(missingDomains(certificate).joined(separator: "、"))，服务器会拒绝部署。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
            }
        }
        if !site.enabled {
            Text(verbatim: "网站当前已停用，请先在列表里启用它；服务端要求网站处于启用状态才能部署证书。")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
        }
        Text(verbatim: "部署后该网站启用 443 的 HTTPS。同一个 Web 服务下的多个网站可以各自部署证书，按域名（SNI）区分；"
             + "但 443 只能由一个 Web 服务占用，Nginx、Apache、OpenResty 里已经有别的服务在用 443 时会被拒绝。"
             + "证书续期后需要重新部署一次。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder private var emptyState: some View {
        Text(verbatim: "本机还没有已签发的证书。证书由 acme.sh 在本机申请，申请完再回到这里部署到网站。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560, alignment: .leading)
        InfoRow(label: "acme.sh", value: model.acmeStatus.installed ? "已就绪" : "未安装")
        if !model.acmeStatus.installed {
            Text(verbatim: "先装好 acme.sh，再到「域名管理 → 申请与续期」填写域名申请证书。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            if !model.acmeStatus.installed {
                Button("安装 acme.sh") { model.installACME() }
            }
            Button("打开域名管理申请证书") { dismiss(); openDomains() }
            Spacer()
        }
    }

    // MARK: - 证书是否覆盖网站域名

    /// 证书里出现过的域名：主域名加附加域名（acme.sh 用 `no` 表示没有附加域名）。
    private func certificateNames(_ certificate: ACMECertificate) -> [String] {
        var names = [certificate.domain]
        let extra = certificate.sanDomains.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty && extra.lowercased() != "no" {
            names.append(contentsOf: extra.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
        }
        return names.filter { !$0.isEmpty }
    }

    /// 判断站点域名是否被某个证书域名覆盖。只支持精确匹配与单层通配（`*.example.com`）。
    private func host(_ host: String, matches pattern: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let rule = pattern.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if name == rule { return true }
        guard rule.hasPrefix("*.") else { return false }
        let suffix = String(rule.dropFirst())          // ".example.com"
        guard name.hasSuffix(suffix) else { return false }
        let label = String(name.dropLast(suffix.count))
        return !label.isEmpty && !label.contains(".")
    }

    private func coversSite(_ certificate: ACMECertificate) -> Bool {
        missingDomains(certificate).isEmpty
    }

    private func missingDomains(_ certificate: ACMECertificate) -> [String] {
        let names = certificateNames(certificate)
        return site.domains.filter { domain in
            !names.contains { host(domain, matches: $0) }
        }
    }

    private func label(_ certificate: ACMECertificate) -> String {
        // 同一域名可能有 RSA 与 ECC 两份证书，只写域名会让两个选项看起来一模一样。
        var parts = [certificate.domain, certificate.keyLabel]
        if certificate.renewAt.count >= 10 {
            parts.append("续期 \(certificate.renewAt.prefix(10))")
        }
        if !coversSite(certificate) {
            parts.append("未覆盖本站域名")
        }
        return parts.joined(separator: " · ")
    }

    @MainActor private func deploy() async {
        guard let certificate = selectedCertificate else { return }
        guard site.enabled else { message = "请先在网站列表里启用该网站"; return }
        working = true
        message = ""
        defer { working = false }
        do {
            let files = try certificate.readDeploymentFiles()
            try await ServerSiteAPI.deployCertificate(connection: connection, token: token,
                                                      site: site, certificate: files.certificate,
                                                      privateKey: files.privateKey)
            onDeployed()
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
