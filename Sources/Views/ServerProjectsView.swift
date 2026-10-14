import SwiftUI
import AppKit

private enum ProjectPathSelection: String, Identifiable {
    case directory, entry
    var id: String { rawValue }
}

/// 同一个视图上挂多个 sheet 会互相顶掉，全部收敛到一个枚举驱动的 sheet。
private enum ProjectSheet: Identifiable {
    case editor
    case detail(RemoteProject)
    case log(RemoteProject)

    var id: String {
        switch self {
        case .editor: return "editor"
        case .detail(let project): return "detail/\(project.id)"
        case .log(let project): return "log/\(project.id)"
        }
    }
}

/// 环境变量编辑用的键值对。
private struct EnvPair: Identifiable, Hashable {
    let id = UUID()
    var key = ""
    var value = ""
}

struct ServerProjectsView: View {
    let connection: ServerConnection
    let token: String
    let openFiles: (String) -> Void
    let openEnvironments: () -> Void
    /// 「环境变量管理」是独立模块，这里只负责把用户带过去。
    let openVariables: () -> Void

    @State private var listing = RemoteProjectListing(items: [], runtimes: [])
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false
    @State private var editing: RemoteProject?
    @State private var sheet: ProjectSheet?
    @State private var pendingDelete: RemoteProject?
    @State private var logText = ""
    @State private var idInput = ""
    @State private var nameInput = ""
    @State private var runtimeInput = "python"
    @State private var runtimeVersionInput = ""
    @State private var useVenvInput = true
    @State private var pythonServerInput = "gunicorn"
    @State private var pythonWorkerInput = "sync"
    @State private var pythonCallableInput = "app"
    @State private var pythonWorkersInput = "2"
    @State private var pythonThreadsInput = "1"
    @State private var entryInput = "main.py"
    @State private var portInput = "3000"
    @State private var directoryInput = ""
    @State private var envPairs: [EnvPair] = []
    @State private var envFileInput = false
    @State private var useGlobalEnvInput = false
    /// 「环境变量管理」里现有的变量，只在打开编辑器时取一次：勾上加载时要告诉
    /// 用户这个项目会读到哪些值。
    @State private var globalVariables: [RemoteGlobalVariable] = []
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
            Text("使用服务器上已安装的 Python、Node.js、Go、Java、.NET、Ruby、Bun 或 Deno 运行项目。工程目录可指定服务器路径；默认在 /www/seraphim/projects。服务日志放在 /www/seraphim/logs/projects。项目想用面板里那份公用变量，就在编辑里勾上「加载面板环境变量」；不勾就完全不碰这个项目。")
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
            if !working && sheet == nil { Task { await refresh(silent: true) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .serverManagementRefresh)) { _ in
            Task { await refresh() }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .editor:
                editor
            case .detail(let project):
                ProjectDetailSheet(connection: connection, token: token, project: project,
                                   onPageAction: handlePageAction,
                                   onChanged: { Task { await refresh(silent: true) } })
            case .log(let project):
                logSheet(project)
            }
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

    private func logSheet(_ project: RemoteProject) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(project.name) · 运行日志").font(.headline)
                Spacer()
                Button("刷新") { Task { await readLog(project) } }
                Button("关闭") { sheet = nil }
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


    // MARK: - 项目卡片

    private func projectCard(_ project: RemoteProject) -> some View {
        Card(title: project.name) {
            HStack(spacing: 12) {
                Text(project.stateText)
                    .foregroundStyle(project.needsAttention ? Color.orange
                                     : project.running ? Color.green : Color.secondary)
                if project.enabled {
                    Text("开机启动").foregroundStyle(.secondary)
                }
                Text((listing.runtimes.first(where: { $0.id == project.runtime })?.name ?? project.runtime)
                     + (project.runtimeVersion?.isEmpty == false ? " \(project.runtimeVersion!)" : ""))
                    .foregroundStyle(.secondary)
                if !project.runtimeReady { Text("运行环境缺失").foregroundStyle(.orange) }
                if project.usesVenv && !project.hasReadyVenv { Text("虚拟环境未就绪").foregroundStyle(.orange) }
                if !project.hasReadyServer { Text("启动器未安装").foregroundStyle(.orange) }
                if project.portBusy == true { Text("端口被占用").foregroundStyle(.orange) }
                Spacer()
                if project.running {
                    Button("重启") { action(project, "restart") }
                        .disabled(working || !project.runtimeReady || (project.usesVenv && !project.hasReadyVenv) || !project.hasReadyServer)
                    Button("停止") { action(project, "stop") }.disabled(working)
                } else {
                    Button("启动") { action(project, "start") }
                        .disabled(working || !project.runtimeReady || (project.usesVenv && !project.hasReadyVenv) || !project.hasReadyServer)
                }
                Button("详情") { sheet = .detail(project) }
                Button("文件") { openFiles(project.directory) }
                Button("编辑") { beginEdit(project) }.disabled(working)
                Menu("更多") {
                    Button("查看日志") {
                        logText = ""
                        sheet = .log(project)
                        Task { await readLog(project) }
                    }
                    Button("安装依赖") { installDependencies(project) }
                        .disabled(working || project.running)
                    if project.runtime == "python" {
                        if !project.hasReadyVenv {
                            Button("创建虚拟环境") { venv(project, "create") }
                                .disabled(working || !project.runtimeReady || project.running)
                        } else if project.pythonServer != nil && project.pythonServer != "direct" && !project.hasReadyServer {
                            Button("安装 \(project.serverLabel ?? "启动器")") { venv(project, "install_server") }
                                .disabled(working || project.running)
                        }
                    }
                    Button(project.enabled ? "取消开机自启" : "设置为开机自启") {
                        action(project, project.enabled ? "disable" : "enable")
                    }
                    .disabled(working || ((!project.runtimeReady || (project.usesVenv && !project.hasReadyVenv) || !project.hasReadyServer) && !project.enabled))
                    if project.port > 0 {
                        Button("复制反向代理地址") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("http://127.0.0.1:\(project.port)", forType: .string)
                            message = "已复制反向代理地址，可在网站管理中创建代理站点"
                            hasError = false
                        }
                    }
                    Divider()
                    Button("删除项目…", role: .destructive) { pendingDelete = project }.disabled(working)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(working)
            }
            InfoRow(label: "目录", value: project.directory)
            InfoRow(label: "入口", value: project.entry)
            if let dependency = project.dependency, let summary = dependency.cardSummary {
                HStack(alignment: .top, spacing: 8) {
                    Text("依赖清单")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Text(verbatim: summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if dependency.action == "deps" {
                        Button("安装依赖") { installDependencies(project) }
                            .buttonStyle(.link)
                            .disabled(working || project.running)
                    }
                }
            }
            if let failure = project.failureSummary {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(verbatim: failure).foregroundStyle(.orange).lineLimit(2)
                    Button("查看详情") { sheet = .detail(project) }
                        .buttonStyle(.link)
                }
            }
            if project.running || project.mainPid != nil {
                HStack(spacing: 16) {
                    if let pid = project.mainPid, pid > 0 {
                        Text("PID \(pid)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let memory = project.memoryText {
                        Text("内存 \(memory)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let uptime = project.uptimeText {
                        Text("已运行 \(uptime)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let restarts = project.restarts, restarts > 0 {
                        Text("已重启 \(restarts) 次").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if project.runtime == "python" {
                InfoRow(label: "启动方式", value: pythonDescription(project))
            }
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
                            if project.pythonServer != "direct" && !project.hasReadyServer {
                                Button("安装 \(project.serverLabel ?? "启动器")") { venv(project, "install_server") }
                                    .disabled(working || project.running)
                            }
                        }
                        Spacer()
                    }
                }
            }
            if let pairs = project.env, !pairs.isEmpty || project.envFile == true {
                HStack(alignment: .top, spacing: 8) {
                    Text("环境变量")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(project.envEntries) { entry in
                            Text(verbatim: "\(entry.name)=\(entry.value)")
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if project.envFile == true {
                            Text("另有 .env 文件由项目加载").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            if project.inheritsGlobalEnv {
                HStack(alignment: .top, spacing: 8) {
                    Text("面板环境变量")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Text(verbatim: "已加载「环境变量管理」里的值（同名以项目自己的为准）")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("打开环境变量管理", action: openVariables)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if project.port > 0 {
                HStack {
                    InfoRow(label: "PORT 环境变量", value: String(project.port))
                    if project.portBusy == true {
                        Text("该端口已被其他进程占用，启动会失败")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
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

    private func pythonDescription(_ project: RemoteProject) -> String {
        let server = project.serverLabel ?? "直接运行"
        guard server != "直接运行" else { return "直接运行 \(project.entry)" }
        var parts = [server, "\(project.pythonCallable ?? "app")", "\(project.pythonWorkers ?? 2) 进程"]
        if project.pythonServer == "gunicorn" {
            let worker = project.pythonWorker ?? ((project.pythonThreads ?? 1) > 1 ? "gthread" : "sync")
            parts.append(worker == "uvicorn" ? "uvicorn worker（ASGI）" : "\(worker) worker")
        }
        return parts.joined(separator: " · ")
    }

    private func handlePageAction(_ action: String) {
        guard case .detail(let project) = sheet else { return }
        switch action {
        case "edit": beginEdit(project)
        case "files": openFiles(project.directory)
        case "runtime": openEnvironments()
        case "variables": openVariables()
        default: break
        }
    }

    // MARK: - 编辑器

    private var editor: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(editing == nil ? "新建服务器项目" : "编辑服务器项目")
                .font(.title3.weight(.semibold))
            ScrollView {
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
                        Picker("启动方式", selection: $pythonServerInput) {
                            Text("Gunicorn（WSGI）").tag("gunicorn")
                            Text("Uvicorn（ASGI）").tag("uvicorn")
                            Text("uWSGI（WSGI）").tag("uwsgi")
                            Text("直接运行脚本").tag("direct")
                        }
                        .onChange(of: pythonServerInput) { newValue in
                            if newValue != "direct" { useVenvInput = true }
                        }
                        if pythonServerInput != "direct" {
                            if pythonServerInput == "gunicorn" {
                                Picker("Worker class", selection: $pythonWorkerInput) {
                                    Text("sync（WSGI）").tag("sync")
                                    Text("gthread（WSGI）").tag("gthread")
                                    Text("uvicorn_worker.UvicornWorker（ASGI）").tag("uvicorn")
                                }
                            }
                            TextField("应用对象（例如 app 或 application）", text: $pythonCallableInput)
                            HStack {
                                TextField("进程数", text: $pythonWorkersInput)
                                if pythonServerInput == "uwsgi" || (pythonServerInput == "gunicorn" && pythonWorkerInput == "gthread") {
                                    TextField("每进程线程数", text: $pythonThreadsInput)
                                }
                            }
                            Text("入口填写定义应用对象的 .py 文件；服务仅监听 127.0.0.1。FastAPI、Starlette 等 ASGI 应用请选 Uvicorn，或 Gunicorn + uvicorn worker；Flask、Django 等 WSGI 应用用 sync 或 gthread。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
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
                    HStack {
                        TextField("PORT 环境变量（可选）", text: $portInput)
                            .textFieldStyle(.roundedBorder)
                        Button("选择空闲端口") { chooseFreePort() }
                            .disabled(working)
                    }
                    Section("环境变量") {
                        Toggle("加载面板的公用环境变量", isOn: $useGlobalEnvInput)
                        if useGlobalEnvInput {
                            if globalVariables.isEmpty {
                                Text("「环境变量管理」里还没有定义变量。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                let overridden = Set(envPairs.map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines) })
                                Text(verbatim: "将加载 \(globalVariables.count) 项：" + globalVariables.map { variable in
                                    overridden.contains(variable.name) ? "\(variable.name)（被下面的项目变量覆盖）" : variable.name
                                }.joined(separator: "、"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text("这个项目只用下面自己填的变量。代码也可以直接读服务器的共用文件，不必改项目配置。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle("同时加载工程目录下的 .env 文件", isOn: $envFileInput)
                        ForEach($envPairs) { $pair in
                            HStack {
                                TextField("名称", text: $pair.key)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                Text("=").foregroundStyle(.secondary)
                                TextField("值", text: $pair.value)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    envPairs.removeAll { $0.id == pair.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("添加环境变量") { envPairs.append(EnvPair()) }
                            .disabled(envPairs.count >= 64)
                        Text("PORT、PATH、HOME、VIRTUAL_ENV 等由面板管理，不能在这里覆盖；端口请填上面的端口字段。同名变量会盖住面板那份公用变量里的值。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
            Text(verbatim: directoryInput.isEmpty
                 ? "/www/seraphim/projects/\(idInput.isEmpty ? "项目标识" : idInput)"
                 : directoryInput)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("自定义工程目录须已存在。保存后上传入口文件；依赖可点「安装依赖」一键装好（Python 需先建虚拟环境）。未安装环境的项目可先保存。Go 入口可填 . 或 main.go。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if hasError && !message.isEmpty {
                Text(verbatim: message).foregroundStyle(.orange).lineLimit(3)
            }
            HStack {
                Spacer()
                Button("取消") { sheet = nil }.disabled(working)
                Button("保存项目") { save() }.disabled(working)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700, height: 720)
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

    private func chooseFreePort() {
        let base = Int(portInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 3000
        working = true
        Task { @MainActor in
            do {
                let ports = try await ServerProjectAPI.freePorts(connection: connection, token: token, after: base)
                working = false
                guard let port = ports.first else {
                    message = "没有找到空闲端口，请手工填写"
                    hasError = true
                    return
                }
                portInput = String(port)
                message = "已选择空闲端口 \(port)"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func beginCreate() {
        editing = nil
        idInput = ""
        nameInput = ""
        runtimeInput = installedRuntimes.first?.id ?? "python"
        runtimeVersionInput = installedRuntimes.first?.legacyInstalled == true ? "" : (installedRuntimes.first?.versions?.first ?? "")
        useVenvInput = runtimeInput == "python"
        pythonServerInput = "gunicorn"
        pythonWorkerInput = "sync"
        pythonCallableInput = "app"
        pythonWorkersInput = "2"
        pythonThreadsInput = "1"
        entryInput = defaultEntry(for: runtimeInput)
        portInput = "3000"
        directoryInput = ""
        envPairs = []
        envFileInput = false
        useGlobalEnvInput = false
        message = ""
        hasError = false
        sheet = .editor
        Task { await loadGlobalVariables() }
    }

    private func beginEdit(_ project: RemoteProject) {
        editing = project
        idInput = project.id
        nameInput = project.name
        runtimeInput = project.runtime
        runtimeVersionInput = project.runtimeVersion ?? ""
        useVenvInput = project.usesVenv
        pythonServerInput = project.pythonServer ?? "direct"
        pythonWorkerInput = project.pythonWorker ?? ((project.pythonThreads ?? 1) > 1 ? "gthread" : "sync")
        pythonCallableInput = project.pythonCallable ?? "app"
        pythonWorkersInput = String(project.pythonWorkers ?? 2)
        pythonThreadsInput = String(project.pythonThreads ?? 1)
        entryInput = project.entry
        portInput = project.port == 0 ? "" : String(project.port)
        directoryInput = project.directory
        envPairs = project.envEntries.map { EnvPair(key: $0.name, value: $0.value) }
        envFileInput = project.envFile == true
        useGlobalEnvInput = project.inheritsGlobalEnv
        message = ""
        hasError = false
        sheet = .editor
        Task { await loadGlobalVariables() }
    }

    /// 「环境变量管理」里的变量只在打开编辑器时取一次：列表页不需要它，定时刷新
    /// 也就不会每 10 秒多打一次接口。取不到不影响编辑，只是勾选处少一行提示。
    @MainActor private func loadGlobalVariables() async {
        if let listing = try? await ServerProjectAPI.variables(connection: connection, token: token) {
            globalVariables = listing.items
        }
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
        let hasServer = runtimeInput == "python" && pythonServerInput != "direct"
        guard !hasServer || (number > 0 && useVenvInput) else {
            message = "Python 启动器需要虚拟环境和监听端口"
            hasError = true
            return
        }
        let workers = Int(pythonWorkersInput) ?? 0
        let threads = Int(pythonThreadsInput) ?? 0
        guard !hasServer || ((1...32).contains(workers) && (1...64).contains(threads)) else {
            message = "进程数须为 1–32，线程数须为 1–64"
            hasError = true
            return
        }
        var environment: [String: String] = [:]
        for pair in envPairs {
            let name = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard environment[name] == nil, !name.contains("=") else {
                message = "环境变量名 \(name) 重复或包含等号"
                hasError = true
                return
            }
            environment[name] = pair.value
        }
        let payload = RemoteProjectPayload(id: idInput.trimmingCharacters(in: .whitespacesAndNewlines),
                                           name: nameInput.trimmingCharacters(in: .whitespacesAndNewlines),
                                           runtime: runtimeInput,
                                           runtimeVersion: runtimeVersionInput,
                                           useVenv: runtimeInput == "python" && useVenvInput,
                                           pythonServer: runtimeInput == "python" ? pythonServerInput : "",
                                           pythonWorker: runtimeInput == "python" && pythonServerInput == "gunicorn" ? pythonWorkerInput : "",
                                           pythonCallable: hasServer ? pythonCallableInput.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                                           pythonWorkers: hasServer ? workers : 0,
                                           pythonThreads: hasServer ? threads : 0,
                                           entry: entryInput.trimmingCharacters(in: .whitespacesAndNewlines),
                                           port: number,
                                           directory: directoryInput.trimmingCharacters(in: .whitespacesAndNewlines),
                                           env: environment,
                                           envFile: envFileInput,
                                           useGlobalEnv: useGlobalEnvInput)
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
                sheet = nil
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
                message = command == "enable" ? "已设置为开机自启"
                    : command == "disable" ? "已取消开机自启"
                    : command == "stop" ? "项目已停止"
                    : command == "restart" ? "项目已重启" : "项目已启动"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
                await refresh(silent: true)
            }
        }
    }

    private func installDependencies(_ project: RemoteProject) {
        guard !working else { return }
        working = true
        Task { @MainActor in
            do {
                try await ServerProjectAPI.installDependencies(connection: connection, token: token, id: project.id)
                working = false
                await refresh()
                message = "依赖已安装"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
                await refresh(silent: true)
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
                message = command == "create" ? "虚拟环境已创建" : "Python 启动器已安装"
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
