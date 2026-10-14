import SwiftUI

private struct TaskEditor: Identifiable {
    let id = UUID()
    let create: Bool
    var task: RemoteScheduledTask
    var argumentLines: String
}

struct ServerTasksView: View {
    let connection: ServerConnection
    let token: String

    @State private var tasks: [RemoteScheduledTask] = []
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false
    @State private var editorError = ""
    @State private var editor: TaskEditor?
    @State private var pendingDelete: RemoteScheduledTask?
    @State private var logText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("计划任务").font(.title3.weight(.semibold))
                Spacer()
                Button("新建任务") { newTask() }.disabled(working)
                Button("刷新") { Task { await refresh() } }.disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            Text("按小时、每天或每周运行程序。参数逐行填写，服务端不会自动调用 shell；输出保存在 /www/seraphim/logs/tasks。")
                .font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(verbatim: message).font(.callout).foregroundStyle(hasError ? Color.orange : Color.secondary)
            }
            FlexibleScroll {
                VStack(alignment: .leading, spacing: 12) {
                    if tasks.isEmpty && !working && !hasError { EmptyHint(text: "尚无计划任务") }
                    ForEach(tasks) { task in
                        Card(title: task.name) {
                            InfoRow(label: "标识", value: task.id)
                            InfoRow(label: "计划", value: task.scheduleText)
                            InfoRow(label: "程序", value: task.executable)
                            InfoRow(label: "状态", value: task.enabled ? "已启用" : "已停用")
                            if let lastRun = task.lastRun, !lastRun.isEmpty {
                                InfoRow(label: "上次运行", value: "\(lastRun) · \(task.lastResult ?? "")")
                            }
                            HStack {
                                Button("编辑") { edit(task) }.disabled(working)
                                Button(task.enabled ? "停用" : "启用") { toggle(task) }.disabled(working)
                                Button("查看日志") { showLog(task) }.disabled(working)
                                Spacer()
                                Button("删除", role: .destructive) { pendingDelete = task }.disabled(working)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .serverManagementRefresh)) { _ in Task { await refresh() } }
        .sheet(item: $editor) { _ in editorSheet }
        .sheet(isPresented: Binding(get: { logText != nil }, set: { if !$0 { logText = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("任务日志（最近 64 KiB）").font(.title3.weight(.semibold))
                ScrollView {
                    Text(verbatim: logText?.isEmpty == false ? logText! : "暂无执行日志")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("关闭") { logText = nil } }
            }
            .padding(20)
            .frame(width: 720, height: 520)
        }
        .confirmationDialog("删除任务 \(pendingDelete?.name ?? "")？",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            if let task = pendingDelete {
                Button("删除任务", role: .destructive) {
                    pendingDelete = nil
                    remove(task)
                }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("定时器会停用并删除；已有日志将保留在服务器上。")
        }
    }

    private var editorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor?.create == true ? "新建计划任务" : "编辑计划任务").font(.title3.weight(.semibold))
            if editor != nil {
                HStack {
                    Text("标识").frame(width: 90, alignment: .leading)
                    TextField("例如 backup-daily", text: Binding(get: { editor?.task.id ?? "" }, set: { editor?.task.id = $0 }))
                        .disabled(editor?.create == false)
                }
                HStack {
                    Text("名称").frame(width: 90, alignment: .leading)
                    TextField("任务名称", text: Binding(get: { editor?.task.name ?? "" }, set: { editor?.task.name = $0 }))
                }
                HStack {
                    Text("频率").frame(width: 90, alignment: .leading)
                    Picker("", selection: Binding(get: { editor?.task.frequency ?? "daily" }, set: { editor?.task.frequency = $0 })) {
                        Text("每小时").tag("hourly")
                        Text("每天").tag("daily")
                        Text("每周").tag("weekly")
                    }.labelsHidden().frame(width: 140)
                    if editor?.task.frequency == "weekly" {
                        Picker("星期", selection: Binding(get: { editor?.task.weekday ?? "Mon" }, set: { editor?.task.weekday = $0 })) {
                            ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { day in Text(day).tag(day) }
                        }.frame(width: 120)
                    }
                    TextField(editor?.task.frequency == "hourly" ? "分钟 00–59" : "时间 HH:MM",
                              text: Binding(get: { editor?.task.time ?? "" }, set: { editor?.task.time = $0 }))
                        .frame(width: 150)
                }
                HStack {
                    Text("程序路径").frame(width: 90, alignment: .leading)
                    TextField("/usr/bin/python3", text: Binding(get: { editor?.task.executable ?? "" }, set: { editor?.task.executable = $0 }))
                }
                HStack {
                    Text("工作目录").frame(width: 90, alignment: .leading)
                    TextField("/www/seraphim", text: Binding(get: { editor?.task.directory ?? "" }, set: { editor?.task.directory = $0 }))
                }
                HStack(alignment: .top) {
                    Text("参数").frame(width: 90, alignment: .leading)
                    TextEditor(text: Binding(get: { editor?.argumentLines ?? "" }, set: { editor?.argumentLines = $0 }))
                        .font(.system(.callout, design: .monospaced))
                        .frame(height: 95)
                        .border(Color.secondary.opacity(0.3))
                }
                Text("每行一个参数；脚本用程序路径指定解释器，并将脚本路径填为第一个参数。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("启用", isOn: Binding(get: { editor?.task.enabled ?? false }, set: { editor?.task.enabled = $0 }))
                // 校验失败时弹窗会保持打开，错误必须显示在这里，否则看起来像按钮没反应。
                if !editorError.isEmpty {
                    Text(verbatim: editorError).font(.callout).foregroundStyle(Color.orange).lineLimit(3)
                }
                HStack {
                    Spacer()
                    Button("取消") { editor = nil }
                    Button("保存") { saveEditor() }.disabled(working)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 650)
    }

    private func newTask() {
        let task = RemoteScheduledTask(id: "", name: "", frequency: "daily", time: "03:00", weekday: "Mon",
                                       executable: "", arguments: [], directory: "/www/seraphim", enabled: true,
                                       lastRun: nil, lastResult: nil)
        editorError = ""
        editor = TaskEditor(create: true, task: task, argumentLines: "")
    }

    private func edit(_ task: RemoteScheduledTask) {
        editorError = ""
        editor = TaskEditor(create: false, task: task, argumentLines: task.arguments.joined(separator: "\n"))
    }

    private func saveEditor() {
        guard var current = editor else { return }
        current.task.arguments = current.argumentLines.isEmpty ? [] : current.argumentLines.components(separatedBy: "\n")
        // 「每小时」只填分钟：切频率时旧的 HH:MM 会留在输入框里，这里直接挡下并给出人话提示，
        // 而不是把 "03:00" 发给服务端换回一句英文报错。
        let time = current.task.time.trimmingCharacters(in: .whitespacesAndNewlines)
        let timePattern = current.task.frequency == "hourly" ? "^[0-5][0-9]$" : "^([01][0-9]|2[0-3]):[0-5][0-9]$"
        guard time.range(of: timePattern, options: .regularExpression) != nil else {
            editorError = current.task.frequency == "hourly" ? "每小时任务的时间需填 00–59 的分钟数" : "时间需填 HH:MM（24 小时制）"
            return
        }
        current.task.time = time
        guard current.task.id.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil else {
            editorError = "标识须以小写字母开头，只能使用小写字母、数字和连字符，最长 48 位"
            return
        }
        editorError = ""
        editor = nil
        Task { await perform {
            try await ServerTaskAPI.save(connection: connection, token: token, task: current.task, create: current.create)
        } }
    }

    private func toggle(_ task: RemoteScheduledTask) {
        var updated = task
        updated.enabled.toggle()
        Task { await perform { try await ServerTaskAPI.save(connection: connection, token: token, task: updated, create: false) } }
    }

    private func remove(_ task: RemoteScheduledTask) {
        Task { await perform { try await ServerTaskAPI.delete(connection: connection, token: token, id: task.id) } }
    }

    private func showLog(_ task: RemoteScheduledTask) {
        Task {
            working = true
            defer { working = false }
            do { logText = try await ServerTaskAPI.log(connection: connection, token: token, id: task.id) }
            catch { message = error.localizedDescription; hasError = true }
        }
    }

    @MainActor private func perform(_ operation: () async throws -> Void) async {
        working = true
        defer { working = false }
        do {
            try await operation()
            message = "操作已完成"
            hasError = false
            tasks = try await ServerTaskAPI.list(connection: connection, token: token)
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }

    @MainActor private func refresh() async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            tasks = try await ServerTaskAPI.list(connection: connection, token: token)
            hasError = false
            message = ""
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }
}
