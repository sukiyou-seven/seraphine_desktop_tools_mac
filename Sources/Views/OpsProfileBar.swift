import SwiftUI

/// 「服务器管理」各页共用的**配置栏**：顶部切一次配置，域名解析与证书一起切。
///
/// `showDNSCredentials` 为真时，额外把阿里云 AccessKey 字段直接摆出来，
/// 省得为了改账号再切到别的页。
struct OpsProfileBar: View {
    @EnvironmentObject var model: AppModel
    var showDNSCredentials: Bool = false

    var body: some View {
        Card(title: "配置") {
            HStack(spacing: 10) {
                Text("切换配置").font(.callout).frame(width: 70, alignment: .leading)
                Picker("", selection: $model.settings.selectedOpsProfileID) {
                    ForEach(model.settings.opsProfiles) { profile in
                        Text(verbatim: profile.label).tag(profile.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .disabled(model.busy != nil)
                .onChange(of: model.settings.selectedOpsProfileID) { _ in model.opsProfileChanged() }
                Button("添加") { model.opsAddProfile() }
                    .disabled(model.busy != nil)
                Button("删除") { model.opsRemoveProfile() }
                    .disabled(model.settings.opsProfiles.count <= 1 || model.busy != nil)
                Spacer(minLength: 0)
            }

            if let index = model.settings.opsProfiles.firstIndex(where: { $0.id == model.settings.selectedOpsProfileID }) {
                HStack(spacing: 10) {
                    Text("配置名称").font(.callout).frame(width: 70, alignment: .leading)
                    TextField("例如：生产服务器", text: $model.settings.opsProfiles[index].name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onChange(of: model.settings.opsProfiles[index].name) { _ in model.persistSettings() }
                    Text(verbatim: "一份配置 = 一个云账号（阿里云 / 腾讯云）+ 一套证书设置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            if showDNSCredentials {
                Divider()
                HStack(spacing: 10) {
                    Text("AccessKey ID").font(.callout).frame(width: 70, alignment: .leading)
                    TextField("LTAI...", text: $model.settings.dns.aliKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: 320)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Text("AccessKey Secret").font(.callout).frame(width: 70, alignment: .leading)
                    SecureField("阿里云控制台 → RAM 访问控制 → 创建 AccessKey",
                                text: $model.settings.dns.aliSecret)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: 320)
                    Button("保存并刷新") { model.dnsRefreshDomains() }
                        .disabled(model.busy != nil)
                    Spacer(minLength: 0)
                }
                Text(verbatim: "⚠️ AccessKey 明文保存在设置文件里，建议用只有 AliyunDNSFullAccess 权限的 RAM 子账号。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
    }
}
