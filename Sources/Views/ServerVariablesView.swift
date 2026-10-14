import SwiftUI
import AppKit

/// 环境变量编辑用的行。
struct SharedVariableRow: Identifiable, Hashable {
    let id = UUID()
    var name = ""
    var value = ""
}

/// 「环境变量管理」：面板统一保管的一份公用变量。
///
/// 它**不是**某个项目的设置。面板只负责存这一份值，项目读不读、读哪几个由项目
/// 和代码自己决定，取用有两条路：
///
///   - 项目在配置里勾上「加载面板环境变量」，值由 systemd 写进它的进程环境；
///   - 变量表同时导出成服务器上的一个共用文件，脚本 `.` 一下、代码直接读都行，
///     项目一个字都不用改。
///
/// 计划任务执行时也会带上同一份值。`PROJECT_RUNTIME=dev / prod` 这类开关改一处
/// 就够，不必逐个项目去改。
struct ServerVariablesView: View {
    let connection: ServerConnection
    let token: String

    @State private var rows: [SharedVariableRow] = []
    @State private var filePath = ""
    @State private var consumers: [String] = []
    @State private var updatedAt = ""
    @State private var loaded = false
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text("面板统一保管的一份公用变量，不属于哪个项目。项目勾上「加载面板环境变量」才会写进它的进程环境；不想动项目配置的，让脚本或代码直接读下面这个共用文件即可。端口、PATH、虚拟环境这类由面板按项目分配，不能定义在这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(hasError ? Color.orange : Color.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlexibleScroll {
                VStack(alignment: .leading, spacing: 10) {
                    usageCard
                    editorCard
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { Task { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .serverManagementRefresh)) { _ in
            Task { await reload() }
        }
    }

    private var header: some View {
        HStack {
            Text("环境变量管理").font(.title3.weight(.semibold))
            Spacer()
            if working { ProgressView().controlSize(.small) }
            Button("刷新") { Task { await reload() } }.disabled(working)
            Button("添加变量") { addRow() }.disabled(working || rows.count >= 128)
            Button("保存") { save() }.disabled(working || !loaded)
        }
    }

    // MARK: - 取用方式

    private var usageCard: some View {
        Card(title: "怎么取用") {
            VStack(alignment: .leading, spacing: 8) {
                usageRow("项目读取", "在项目里勾上「加载面板环境变量」，值会写进它的 systemd 单元。同名时以项目自己填的为准；不勾就完全不碰这个项目。")
                HStack(alignment: .top, spacing: 8) {
                    Text("代码读取")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        if filePath.isEmpty {
                            Text("正在获取文件路径…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            CopyableText(text: filePath)
                            Text("每行一个 KEY=VALUE，# 开头是注释；shell 里 `. \(filePath)` 就能用，任何语言逐行读也行。文件权限 0640、属组 sera：项目进程与 Web 服务能读，其他本地用户读不到。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                usageRow("计划任务", "执行命令时会带上同一份值，脚本和常驻服务看到的东西一致。")
                if !consumers.isEmpty {
                    usageRow("当前会被谁取用", "保存后会同步给勾了加载的项目；勾上的项目会被重启一次，内容没变的项目不会被动到。")
                }
            }
        }
    }

    private func usageRow(_ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(verbatim: text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 变量表

    private var editorCard: some View {
        Card(title: "变量") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("名称").font(.caption).foregroundStyle(.secondary).frame(width: 230, alignment: .leading)
                    Text("值").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if rows.isEmpty {
                    if loaded {
                        Text("还没有变量。点右上角「添加变量」，例如 PROJECT_RUNTIME = dev。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("正在读取…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                ForEach($rows) { $row in
                    HStack(spacing: 8) {
                        TextField("例如 PROJECT_RUNTIME", text: $row.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(width: 230)
                        Text("=").foregroundStyle(.secondary)
                        TextField("例如 dev", text: $row.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                        Button {
                            rows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("删除这一项")
                    }
                }
                HStack {
                    Text("共 \(countedRows) 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !updatedAt.isEmpty {
                        Text(verbatim: "· 最后更新 \(updatedAt)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("添加变量") { addRow() }
                        .disabled(working || rows.count >= 128)
                    Button("保存") { save() }
                        .disabled(working || !loaded)
                }
            }
        }
    }

    private var countedRows: Int {
        rows.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    // MARK: - 数据

    private func addRow() {
        guard rows.count < 128 else { return }
        rows.append(SharedVariableRow())
    }

    @MainActor private func reload() async {
        guard !working else { return }
        working = true
        do {
            let listing = try await ServerProjectAPI.variables(connection: connection, token: token)
            rows = listing.items.map { SharedVariableRow(name: $0.name, value: $0.value) }
            filePath = listing.file ?? ""
            consumers = listing.consumers ?? []
            updatedAt = listing.updatedAt ?? ""
            loaded = true
            message = ""
            hasError = false
        } catch {
            message = error.localizedDescription
            hasError = true
        }
        working = false
    }

    private func save() {
        var items: [RemoteGlobalVariable] = []
        var seen = Set<String>()
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty && row.value.isEmpty { continue }
            guard !name.isEmpty else {
                message = "有一行只填了值、没填名称"
                hasError = true
                return
            }
            guard !name.contains("=") else {
                message = "变量名 \(name) 不能包含等号"
                hasError = true
                return
            }
            guard seen.insert(name).inserted else {
                message = "变量 \(name) 重复了"
                hasError = true
                return
            }
            items.append(RemoteGlobalVariable(name: name, value: row.value))
        }
        working = true
        hasError = false
        Task { @MainActor in
            do {
                let result = try await ServerProjectAPI.saveVariables(connection: connection, token: token,
                                                                     variables: items)
                // 空行在服务端会被规范掉，这里用返回的列表重建，界面和实际存的内容才一致。
                rows = (result.variables ?? []).map { SharedVariableRow(name: $0.name, value: $0.value) }
                if let file = result.file, !file.isEmpty { filePath = file }
                updatedAt = result.updatedAt ?? updatedAt
                let applied = result.appliedProjects
                if applied.isEmpty {
                    message = items.isEmpty
                        ? "已清空，共用文件也同步清空了"
                        : "已保存 \(items.count) 项，并写入共用文件；没有项目勾选加载，所以没有项目被同步"
                } else {
                    message = "已保存 \(items.count) 项，并同步到 \(applied.count) 个项目：" + applied.joined(separator: "、")
                }
                hasError = false
                working = false
            } catch {
                message = error.localizedDescription
                hasError = true
                working = false
            }
        }
    }
}
