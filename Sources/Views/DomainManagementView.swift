import SwiftUI

/// 阿里云解析和 acme.sh 证书共用域名与运维配置。
struct DomainManagementView: View {
    @EnvironmentObject var model: AppModel
    @State private var pane = 0

    var body: some View {
        GeometryReader { geometry in
            FlexibleScroll {
                VStack(alignment: .leading, spacing: 12) {
                    OpsProfileBar(showDNSCredentials: true)

                    Card(title: "域名工作区") {
                        HStack(spacing: 10) {
                            Text("当前域名").frame(width: 90, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { model.dnsState.selectedDomain ?? "" },
                                set: { value in if !value.isEmpty { model.dnsSelectDomain(value) } }
                            )) {
                                if model.dnsState.domains.isEmpty { Text("暂无域名").tag("") }
                                ForEach(model.dnsState.domains) { domain in
                                    Text(verbatim: domain.name).tag(domain.name)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260)
                            Button("管理解析") { pane = 0 }
                            Button("为此域名申请证书") {
                                if let domain = model.dnsState.selectedDomain { model.acmeDomains = domain }
                                pane = 1
                            }
                            .disabled(model.dnsState.selectedDomain == nil)
                            Spacer(minLength: 0)
                        }
                        Text("先确认域名解析，再申请或续期证书。泛域名和多个证书域名可在申请表单中直接填写。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)

                    Picker("", selection: $pane) {
                        Text("解析记录").tag(0)
                        Text("申请与续期").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)

                    if pane == 0 {
                        DNSView()
                            .frame(height: max(460, geometry.size.height - 320))
                    } else {
                        CertificateView(embedded: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, 12)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .serverManagementRefresh)) { _ in
            if pane == 0 { model.dnsRefreshDomains() } else { model.loadCertificates() }
        }
    }
}
