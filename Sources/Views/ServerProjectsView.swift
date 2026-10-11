import SwiftUI
import AppKit

private enum ProjectPathSelection: String, Identifiable {
    case directory, entry
    var id: String { rawValue }
}

struct ServerProjectsView: View {
    let connection: ServerConnection
    let token: String
    let openFiles: (String) -> Void
    let openEnvironments: () -> Void

    @State private var listing = RemoteProjectListing(items: [], runtimes: [])
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false
    @State private var editing: RemoteProject?
    @State private var showingEditor = false
    @State private var pendingDelete: RemoteProject?
    @State private var logProject: RemoteProject?
    @State private var logText = ""
    @State private var idInput = ""
    @State private var nameInput = ""
    @State private var runtimeInput = "python"
    @State private var runtimeVersionInput = ""
    @State private var useVenvInput = true
    @State private var entryInput = "main.py"
    @State private var portInput = "3000"
    @State private var directoryInput = ""
    @State private var pathSelection: ProjectPathSelection?

    private var installedRuntimes: [RemoteProjectRuntime] { listing.runtimes.filter(\.installed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("项目管理").font(.title3.weight(.semibold))
                Spacer()
                Button("刷新") { Task { await refresh() } }.disabled(working)
                Button("新建项目") { beginCreate() }.disabled(working)
                if working { ProgressView().controlSize(.small) }
            }
            Text("使用服务器上已安装的 Python、Node.js、Go、Java、.NET、Ruby、Bun 或 Deno 运行项目。工程目录可指定服务器路径；默认在 /www/seraphim/projects。服务日志放在 /www/seraphim/logs/projects。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if installedRuntimes.isEmpty {
                HStack {
                    Text("可先创建项目配置并上传文件；启动前需要安装运行环境，再编辑项目选择已安装版本。")
                        .foregroundStyle(.secondary)
                    Button("打开环境管理", action: openEnvironments)
                }
            }
            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(hasError ? Color.orange : Color.secondary)
                    .lineLimit(3)
            }
            FlexibleScroll {
                VStack(alignment: .leading, spacing: 10) {
                    if listing.items.isEmpty && !working {
                        EmptyHint(text: "暂无服务器项目；新建后可到文件管理上传入口和项目文件")
                    }
                    ForEach(listing.items) { project in projectCard(project) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { Task { await refresh() } }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            if !working && !showingEditor && logProject == nil { Task { await refresh(silent: true) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .serverManagementRefresh)) { _ in
            Task { await refresh() }
        }
        .sheet(isPresented: $showingEditor) { editor }
        .sheet(item: $logProject) { project in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(project.name) · 运行日志").font(.headline)
                    Spacer()
                    Button("刷新") { Task { await readLog(project) } }
                    Button("关闭") { logProject = nil }
                }
                ScrollView {
                    Text(verbatim: logText.isEmpty ? "暂无日志" : logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(minWidth: 680, minHeight: 440)
        }
        .confirmationDialog("删除项目 \(pendingDelete?.name ?? "")？",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } })) {
            if let project = pendingDelete {
                Button("删除项目配置", role: .destructive) {
                    pendingDelete = nil
                    remove(project)
                }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("将停止项目并删除服务配置；项目文件和日志保留在服务器上，可用文件管理删除。")
        }
    }

    private func projectCard(_ project: RemoteProject) -> some View {
        Card(title: project.name) {
            HStack(spacing: 12) {
                Text(project.stateText)
                    .foregroundStyle(project.running ? Color.green : project.activeState == "failed" ? Color.orange : Color.secondary)
                Text(project.enabled ? "开机启动" : "不开机启动")
                    .foregroundStyle(.secondary)
                Text((listing.runtimes.first(where: { $0.id == project.runtime })?.name ?? project.runtime)
                     + (project.runtimeVersion?.isEmpty == false ? " \(project.runtimeVersion!)" : ""))
                    .foregroundStyle(.secondary)
                if !project.runtimeReady { Text("运行环境缺失").foregroundStyle(.orange) }
                if project.usesVenv && !project.hasReadyVenv { Text("虚拟环境未就绪").foregroundStyle(.orange) }
                Spacer()
                Button("文件") { openFiles(project.directory) }
                Button("日志") {
                    logText = ""
                    logProject = project
                    Task { await readLog(project) }
                }
                Button("编辑") { beginEdit(project) }.disabled(working)
                if project.running {
                    Button("重启") { action(project, "restart") }
                        .disabled(working || !project.runtimeReady || (project.usesVenv && !project.hasReadyVenv))
                    Button("停止") { action(project, "stop") }.disabled(working)
                } else {
                    Button("启动") { action(project, "start") }
                        .disabled(working || !project.runtimeReady || (project.usesVenv && !project.hasReadyVenv))
                }
                Button(project.enabled ? "取消自启" : "开机自启") {
                    action(project, project.enabled ? "disable" : "enable")
                }
                .disabled(working || ((!project.runtimeReady || (project.usesVenv && !project.hasReadyVenv)) && !project.enabled))
                Button("删除…", role: .destructive) { pendingDelete = project }.disabled(working)
            }
            InfoRow(label: "目录", value: project.directory)
            InfoRow(label: "入口", value: project.entry)
            if project.usesVenv {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "Python 虚拟环境", value: "/www/seraphim/projects/\(project.id)/data/venv")
                    HStack {
                        Text(project.hasReadyVenv ? "已就绪" : "未创建或版本不匹配")
                            .foregroundStyle(project.hasReadyVenv ? Color.green : Color.orange)
                        if !project.hasReadyVenv {
                            Button("创建虚拟环境") { venv(project, "create") }
                                .disabled(working || !project.runtimeReady || project.running)
                        } else {
                            Button("安装 requirements.txt") { venv(project, "install_requirements") }
                                .disabled(working || project.running)
                        }
                        Spacer()
                    }
                }
            }
            if project.port > 0 {
                HStack {
                    InfoRow(label: "PORT 环境变量", value: String(project.port))
                    Button("复制代理地址") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("http://127.0.0.1:\(project.port)", forType: .string)
                        message = "已复制反向代理地址，可在网站管理中创建代理站点"
                        hasError = false
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(editing == nil ? "新建服务器项目" : "编辑服务器项目")
                .font(.title3.weight(.semibold))
            Form {
                TextField("项目标识（小写字母、数字、连字符）", text: $idInput)
                    .disabled(editing != nil)
                    .textFieldStyle(.roundedBorder)
                TextField("名称", text: $nameInput)
                    .textFieldStyle(.roundedBorder)
                Picker("运行环境", selection: $runtimeInput) {
                    ForEach(listing.runtimes) { runtime in
                        Text(runtime.installed ? runtime.name : "\(runtime.name)（未安装）").tag(runtime.id)
                    }
                }
                .onChange(of: runtimeInput) { newValue in
                    if editing == nil { entryInput = defaultEntry(for: newValue) }
                    useVenvInput = newValue == "python"
                    let runtime = listing.runtimes.first(where: { $0.id == newValue })
                    runtimeVersionInput = runtime?.legacyInstalled == true ? "" : (runtime?.versions?.first ?? "")
                }
                Picker("环境版本", selection: $runtimeVersionInput) {
                    if let runtime = listing.runtimes.first(where: { $0.id == runtimeInput }) {
                        if runtime.legacyInstalled == true { Text("原有版本").tag("") }
                        if runtime.legacyInstalled != true &&
                            (runtime.versions?.isEmpty != false || runtimeVersionInput.isEmpty) {
                            Text(runtime.versions?.isEmpty == false ? "未选择版本（无法启动）" : "尚未安装（稍后选择）")
                                .tag("")
                        }
                        ForEach(runtime.versions ?? [], id: \.self) { version in
                            Text(verbatim: version).tag(version)
                        }
                    }
                }
                if runtimeInput == "python" {
                    Toggle("使用项目虚拟环境", isOn: $useVenvInput)
                }
                HStack {
                    TextField("工程目录（留空使用默认目录）", text: $directoryInput)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") { pathSelection = .directory }
                        .disabled(working)
                }
                HStack {
                    TextField("入口（相对于项目目录）", text: $entryInput)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") { pathSelection = .entry }
                        .disabled(working)
                }
                TextField("PORT 环境变量（可选）", text: $portInput)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)
            Text(verbatim: directoryInput.isEmpty
                 ? "/www/seraphim/projects/\(idInput.isEmpty ? "项目标识" : idInput)"
                 : directoryInput)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("自定义工程目录须已存在。保存后上传入口文件；启用 Python 虚拟环境时先创建它，再从工程目录的 requirements.txt 安装依赖。未安装环境的项目可先保存，安装后再选择版本。Go 入口可填 . 或 main.go。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if hasError && !message.isEmpty {
                Text(verbatim: message).foregroundStyle(.orange).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("取消") { showingEditor = false }.disabled(working)
                Button("保存项目") { save() }.disabled(working)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 650, height: 540)
        .sheet(item: $pathSelection) { selection in
            ServerProjectPathPicker(connection: connection, token: token,
                                    selection: selection, runtime: runtimeInput,
                                    startPath: selection == .directory
                                        ? (directoryInput.isEmpty ? "/www/seraphim/projects" : directoryInput)
                                        : projectDirectoryForSelection) { path, useGoDirectory in
                if selection == .directory {
                    directoryInput = path
                } else if useGoDirectory {
                    directoryInput = path
                    entryInput = "."
                } else {
                    let base = projectDirectoryForSelection
                    let hasProjectDirectory = !directoryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !idInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if hasProjectDirectory && path.hasPrefix(base + "/") {
                        entryInput = String(path.dropFirst(base.count + 1))
                    } else {
                        directoryInput = (path as NSString).deletingLastPathComponent
                        entryInput = (path as NSString).lastPathComponent
                    }
                }
                pathSelection = nil
            }
        }
    }

    private var projectDirectoryForSelection: String {
        let directory = directoryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directory.isEmpty { return (directory as NSString).standardizingPath }
        let id = idInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? "/www/seraphim/projects" : "/www/seraphim/projects/\(id)"
    }

    private func defaultEntry(for runtime: String) -> String {
        switch runtime {
        case "python": return "main.py"
        case "node": return "index.js"
        case "go": return "."
        case "openjdk": return "app.jar"
        case "dotnet": return "app.dll"
        case "ruby": return "app.rb"
        case "bun": return "index.ts"
        case "deno": return "main.ts"
        default: return ""
        }
    }

    private func beginCreate() {
        editing = nil
        idInput = ""
        nameInput = ""
        runtimeInput = installedRuntimes.first?.id ?? "python"
        runtimeVersionInput = installedRuntimes.first?.legacyInstalled == true ? "" : (installedRuntimes.first?.versions?.first ?? "")
        useVenvInput = runtimeInput == "python"
        entryInput = defaultEntry(for: runtimeInput)
        portInput = "3000"
        directoryInput = ""
        message = ""
        hasError = false
        showingEditor = true
    }

    private func beginEdit(_ project: RemoteProject) {
        editing = project
        idInput = project.id
        nameInput = project.name
        runtimeInput = project.runtime
        runtimeVersionInput = project.runtimeVersion ?? ""
        useVenvInput = project.usesVenv
        entryInput = project.entry
        portInput = project.port == 0 ? "" : String(project.port)
        directoryInput = project.directory
        message = ""
        hasError = false
        showingEditor = true
    }

    @MainActor private func refresh(silent: Bool = false) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            listing = try await ServerProjectAPI.list(connection: connection, token: token)
            if !silent { message = ""; hasError = false }
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }

    private func save() {
        let port = portInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = port.isEmpty ? 0 : Int(port), (0...65535).contains(number) else {
            message = "端口须在 0 至 65535 之间"
            hasError = true
            return
        }
        let payload = RemoteProjectPayload(id: idInput.trimmingCharacters(in: .whitespacesAndNewlines),
                                           name: nameInput.trimmingCharacters(in: .whitespacesAndNewlines),
                                           runtime: runtimeInput,
                                           runtimeVersion: runtimeVersionInput,
                                           useVenv: runtimeInput == "python" && useVenvInput,
                                           entry: entryInput.trimmingCharacters(in: .whitespacesAndNewlines),
                                           port: number,
                                           directory: directoryInput.trimmingCharacters(in: .whitespacesAndNewlines))
        let wasEditing = editing != nil
        working = true
        Task { @MainActor in
            do {
                if wasEditing {
                    try await ServerProjectAPI.update(connection: connection, token: token, payload: payload)
                } else {
                    _ = try await ServerProjectAPI.create(connection: connection, token: token, payload: payload)
                }
                working = false
                showingEditor = false
                await refresh()
                message = wasEditing ? "项目配置已保存" : "项目已创建；请打开文件管理上传入口和依赖后启动"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func action(_ project: RemoteProject, _ command: String) {
        working = true
        Task { @MainActor in
            do {
                try await ServerProjectAPI.action(connection: connection, token: token, id: project.id, action: command)
                working = false
                await refresh()
                message = "项目操作已完成"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func venv(_ project: RemoteProject, _ command: String) {
        guard !working else { return }
        working = true
        Task { @MainActor in
            do {
                try await ServerProjectAPI.venv(connection: connection, token: token, id: project.id, action: command)
                working = false
                await refresh()
                message = command == "create" ? "虚拟环境已创建" : "requirements.txt 依赖已安装"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func remove(_ project: RemoteProject) {
        working = true
        Task { @MainActor in
            do {
                try await ServerProjectAPI.delete(connection: connection, token: token, id: project.id)
                working = false
                await refresh()
                message = "项目服务已删除；文件和日志已保留"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    @MainActor private func readLog(_ project: RemoteProject) async {
        do {
            logText = try await ServerProjectAPI.log(connection: connection, token: token, id: project.id)
        } catch {
            logText = error.localizedDescription
        }
    }
}

private struct ServerProjectPathPicker: View {
    let connection: ServerConnection
    let token: String
    let selection: ProjectPathSelection
    let runtime: String
    let startPath: String
    let onChoose: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = ""
    @State private var pathInput = ""
    @State private var listing: RemoteFileListing?
    @State private var loading = false
    @State private var errorMessage = ""

    private var visibleEntries: [RemoteFile] {
        (listing?.entries ?? []).filter { $0.isDirectory || (selection == .entry && $0.isRegularFile) }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private var allowedExtensions: Set<String> {
        switch runtime {
        case "python": return ["py"]
        case "node": return ["js", "mjs", "cjs"]
        case "go": return ["go"]
        case "openjdk": return ["jar"]
        case "dotnet": return ["dll"]
        case "ruby": return ["rb"]
        case "bun", "deno": return ["js", "mjs", "ts", "tsx"]
        default: return []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selection == .directory ? "选择服务器工程目录" : "选择服务器入口文件")
                .font(.headline)
            HStack {
                Button("上一级") { Task { await load(listing?.parent ?? "/") } }
                    .disabled(loading || currentPath == "/")
                TextField("服务器目录", text: $pathInput)
                    .font(.system(.callout, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await load(pathInput) } }
                Button("前往") { Task { await load(pathInput) } }
                    .disabled(loading)
            }
            if !errorMessage.isEmpty {
                Text(verbatim: errorMessage).font(.caption).foregroundStyle(.orange)
            }
            if loading { ProgressView().controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleEntries) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                                .frame(width: 20)
                            Text(verbatim: item.name)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if item.isDirectory {
                                Button("进入") { Task { await load(item.path) } }
                                    .disabled(loading)
                                if selection == .directory {
                                    Button("选择") { choose(item.path) }
                                }
                            } else {
                                Button("选择") { choose(item.path) }
                                    .disabled(!allowedExtensions.contains((item.name as NSString).pathExtension.lowercased()))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        Divider()
                    }
                    if visibleEntries.isEmpty && !loading {
                        Text(selection == .directory ? "此目录没有子文件夹" : "此目录没有可选文件")
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18)))
            HStack {
                Text(verbatim: currentPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("取消") { dismiss() }
                if selection == .directory {
                    Button("选择此目录") { choose(currentPath) }
                        .disabled(listing == nil || currentPath == "/" || loading)
                } else if runtime == "go" {
                    Button("使用此目录作为 Go 入口") {
                        onChoose(currentPath, true)
                        dismiss()
                    }
                    .disabled(listing == nil || currentPath == "/" || loading)
                }
            }
        }
        .padding(20)
        .frame(width: 700, height: 490)
        .task {
            await load(startPath)
            if listing == nil && startPath != "/www/seraphim/projects" {
                await load("/www/seraphim/projects")
            }
        }
    }

    private func choose(_ path: String) {
        onChoose(path, false)
        dismiss()
    }

    @MainActor private func load(_ path: String) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await ServerFileAPI.list(connection: connection, token: token, path: path)
            listing = result
            currentPath = result.path
            pathInput = result.path
            errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
