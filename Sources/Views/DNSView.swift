import SwiftUI

/// 「域名解析」页：把阿里云云解析（AliDNS）的 OpenAPI 包成界面。
///
/// 只做「看和改解析记录」这一件事。以后要加别的服务商，就在 `DNSSettings.provider`
/// 上加分支、给 `DNSService` 添一个实现，页面本身不用大改。
///
/// 布局规矩跟「云端任务」页一样（踩过同样的坑）：
/// 中间那一列是唯一的弹性区，顶部凭据栏和底部表单都不许被长内容顶出去；
/// 记录值一律**限宽 + 中间截断**（TXT 记录能有几百个字符，不限宽会把整页撑爆）。
struct DNSView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            mainArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .onAppear {
            if model.dnsState.loadedAt == nil, model.dnsConfigured { model.dnsRefreshDomains() }
        }
    }

    // MARK: 主体（域名 + 解析记录）

    private var mainArea: some View {
        Group {
            if !model.dnsConfigured {
                EmptyHint(text: "先填好阿里云 AccessKey（只要 DNS 权限就够），就能在这里管解析记录了")
            } else if model.dnsState.domains.isEmpty {
                EmptyHint(text: model.dnsState.error.isEmpty
                          ? "还没有域名：在上方配置中点「保存并刷新域名」"
                          : "域名列表拉取失败，见上面的错误信息")
            } else {
                HStack(spacing: 0) {
                    domainList
                        .frame(width: 260)
                    Divider()
                    recordPane
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18)))
    }

    private var domainList: some View {
        // 用 FlexibleScroll：域名一多，普通 ScrollView 会把整页的最小高度一起顶上去
        FlexibleScroll {
            LazyVStack(spacing: 0) {
                ForEach(model.dnsState.domains) { domain in
                    domainRow(domain)
                }
            }
        }
    }

    private func domainRow(_ domain: DNSDomain) -> some View {
        let selected = model.dnsState.selectedDomain == domain.name
        return Button {
            model.dnsSelectDomain(domain.name)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: domain.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(verbatim: "\(domain.recordCount) 条记录")
                    if !domain.versionName.isEmpty {
                        Text(verbatim: domain.versionName)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var recordPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            recordHeader
            Divider()
            recordList
            Divider()
            editorForm
        }
        .padding(.bottom, 10)
    }

    private var recordHeader: some View {
        HStack(spacing: 8) {
            if let domain = model.dnsState.selectedDomainObject {
                Text(verbatim: domain.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !model.dnsState.message.isEmpty {
                Text(verbatim: model.dnsState.message)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                model.dnsLoadRecords()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.busy != nil)
            .help("重新拉取这个域名的解析记录")
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private var recordList: some View {
        // 同上：记录条数不设上限（一个域名几十上百条很常见），必须让它自己滚
        FlexibleScroll {
            LazyVStack(spacing: 0) {
                if model.dnsState.records.isEmpty {
                    EmptyHint(text: "这个域名下还没有解析记录，用下面的表单加一条")
                } else {
                    ForEach(model.dnsState.records) { record in
                        recordRow(record)
                    }
                }
            }
        }
    }

    private func recordRow(_ record: DNSRecord) -> some View {
        let editing = model.dnsState.editingRecordId == record.recordId
        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(record.enabled ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: record.displayRR)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(verbatim: record.type)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                    if !record.enabled {
                        Text(verbatim: "已暂停").font(.caption2).foregroundStyle(.orange)
                    }
                    if !record.priority.isEmpty {
                        Text(verbatim: "优先级 \(record.priority)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                // TXT 记录动辄几百个字符，不限宽会把整页一起撑宽
                Text(verbatim: record.value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420, alignment: .leading)
                    .help(record.value)
                Text(verbatim: "TTL \(record.ttl)　线路 \(record.line)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("改") { model.dnsEditRecord(record) }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(model.busy != nil)
            Button("删") { model.dnsDeleteRecord(record) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.red)
                .disabled(model.busy != nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(editing ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    // MARK: 新增 / 修改表单

    private var editorForm: some View {
        let editing = model.dnsState.editingRecordId != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: editing ? "修改解析记录" : "新增解析记录")
                    .font(.callout).bold()
                if editing {
                    Text(verbatim: "改完点「保存」").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                labeledField("主机记录", placeholder: "www、account.admin 或 @", width: 150,
                             text: $model.dnsState.editor.rr)
                Text(verbatim: "类型").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $model.dnsState.editor.type) {
                    ForEach(DNSRecordTypes.all, id: \.self) { type in
                        Text(verbatim: type).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 92)
                labeledField("记录值", placeholder: valuePlaceholder, width: nil,
                             text: $model.dnsState.editor.value)
            }

            HStack(spacing: 8) {
                labeledField("TTL", placeholder: "600", width: 74,
                             text: $model.dnsState.editor.ttl)
                if DNSRecordTypes.needsPriority(model.dnsState.editor.type) {
                    labeledField("优先级", placeholder: "10", width: 56,
                                 text: $model.dnsState.editor.priority)
                }
                Spacer(minLength: 8)
                if editing {
                    Button("取消") { model.dnsCancelEdit() }
                }
                Button(editing ? "保存" : "添加") { model.dnsSaveRecord() }
                    .disabled(model.busy != nil)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18)))
        .padding(.horizontal, 10)
    }

    private func labeledField(_ label: String, placeholder: String, width: CGFloat?,
                              text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: label)
                .font(.caption).foregroundStyle(.secondary)
            if let width {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: width)
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
            }
        }
    }

    /// 按记录类型给个像样的占位符，省得不知道要填什么
    private var valuePlaceholder: String {
        switch model.dnsState.editor.type {
        case "A": return "1.2.3.4"
        case "AAAA": return "2400:3200::1"
        case "CNAME": return "target.example.com"
        case "TXT": return "任意文本（证书验证就往这儿填）"
        case "MX": return "mail.example.com"
        case "NS": return "ns1.example.com"
        case "SRV": return "0 5 443 target.example.com"
        case "CAA": return "0 issue \"letsencrypt.org\""
        default: return "记录值"
        }
    }
}
