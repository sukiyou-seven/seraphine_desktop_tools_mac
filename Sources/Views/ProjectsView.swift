import SwiftUI
import AppKit

private struct ProjectSelection: Hashable {
    let root: String
    let directory: String
}

struct ProjectsView: View {
    @ObservedObject var runner: ProjectRunner
    @ObservedObject var environments: PythonEnvironmentManager
    @State private var selection: ProjectSelection?
    @State private var selectedLogID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已添加 \(runner.roots.count) 个工程").font(.headline)
                Spacer()
                Button("添加工程") { chooseDirectory() }
                Button("全部刷新") { runner.refreshAll() }.disabled(runner.roots.isEmpty)
            }
            if !runner.error.isEmpty {
                Text(verbatim: runner.error).font(.callout).foregroundStyle(.orange)
                    .lineLimit(2).textSelection(.enabled)
            } else if !runner.notice.isEmpty {
                Text(verbatim: runner.notice).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 0) {
                projectList
                    .frame(width: 310)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    selectedDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    logPanel.frame(height: 220)
                }
                .padding(.leading, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .navigationTitle("项目管理")
        .onAppear { ensureSelection() }
        .onChange(of: runner.roots) { _ in
            ensureSelection()
            environments.refresh(projectRoots: runner.roots)
        }
        .onChange(of: runner.scans) { _ in ensureSelection() }
    }

    private var projectList: some View {
        List(selection: $selection) {
            ForEach(runner.roots, id: \.self) { root in
                Section {
                    if !runner.collapsedRoots.contains(root) {
                        HStack {
                            Text("工程目录").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(verbatim: "\(runner.scans[root]?.components.count ?? 0) 个子工程")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(ProjectSelection(root: root, directory: ""))
                        ForEach(runner.scans[root]?.components ?? []) { component in
                            HStack(spacing: 6) {
                                componentIcon(component)
                                Text(verbatim: component.relativePath == "." ? "根目录" : component.relativePath)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                if runner.hasRunning(in: component.directory) { StatusDot(running: true) }
                            }
                            .tag(ProjectSelection(root: root, directory: component.directory))
                        }
                    }
                } header: {
                    HStack(spacing: 4) {
                        Button { runner.toggleCollapsed(root) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: runner.collapsedRoots.contains(root) ? "chevron.right" : "chevron.down")
                                    .font(.caption2)
                                Text(verbatim: URL(fileURLWithPath: root).lastPathComponent)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                        if runner.hasRunning(in: root) { StatusDot(running: true) }
                        if runner.scanningRoots.contains(root) { ProgressView().controlSize(.mini) }
                        Button { runner.refresh(root) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("刷新这个工程")
                        Button {
                            runner.remove(root)
                        } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).help("移除这个工程")
                            .disabled(runner.hasRunning(in: root))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func componentIcon(_ component: ProjectComponent) -> some View {
        if component.hasPython && component.scripts.isEmpty {
            Text("🐍").font(.system(size: 14)).frame(width: 17)
        } else if component.hasWeChat && component.scripts.isEmpty {
            Image(systemName: "square.grid.2x2").frame(width: 17)
        } else {
            Image(systemName: "terminal").frame(width: 17)
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        if let selected = selectedComponent {
            componentDetail(selected.component, root: selected.root)
        } else if let selection {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: URL(fileURLWithPath: selection.root).lastPathComponent)
                    .font(.title2.weight(.semibold))
                Text(verbatim: selection.root).font(.callout.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let error = runner.scanErrors[selection.root] {
                    Text(verbatim: error).foregroundStyle(.orange)
                } else if runner.scanningRoots.contains(selection.root) {
                    ProgressView("正在扫描子工程…")
                } else if runner.scans[selection.root]?.components.isEmpty == true {
                    Text("未找到 package.json 脚本、Python 工程或微信小程序配置。")
                        .foregroundStyle(.secondary)
                } else {
                    Text("从左侧选择一个子工程，查看和运行命令。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("先添加工程目录").font(.title2.weight(.semibold))
                Text("添加后，左侧列出所有工程及其 Node、Python 和微信小程序子工程。")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var selectedComponent: (root: String, component: ProjectComponent)? {
        guard let selection, !selection.directory.isEmpty,
              let component = runner.scans[selection.root]?.components.first(where: { $0.directory == selection.directory })
        else { return nil }
        return (selection.root, component)
    }

    private func componentDetail(_ component: ProjectComponent, root: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: component.relativePath == "." ? URL(fileURLWithPath: root).lastPathComponent : component.relativePath)
                .font(.title2.weight(.semibold))
            Text(verbatim: component.directory).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)

            if !component.scripts.isEmpty {
                HStack(spacing: 8) {
                    Text("网页地址").font(.callout)
                    TextField("运行后自动识别，或填 http://localhost:3000", text: Binding(
                        get: { runner.webURLs[component.directory] ?? "" },
                        set: { runner.setWebURL($0, for: component.directory) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 410)
                    Button("打开网页") { runner.openWebsite(component) }
                        .disabled(runner.websiteURL(for: component) == nil)
                }
                if runner.webURLs[component.directory, default: ""].isEmpty,
                   let detected = runner.websiteURL(for: component) {
                    Text(verbatim: "已从运行输出识别：\(detected.absoluteString)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if component.hasWeChat {
                Button("微信开发者工具打开") { runner.openWeChat(component) }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !component.scripts.isEmpty {
                        Text("npm 脚本").font(.callout.weight(.semibold))
                        ForEach(component.scripts, id: \.self) { script in
                            let id = runner.npmID(component, script)
                            commandRow(id: id, title: "npm run \(script)") {
                                runner.startNPM(component, script: script)
                            }
                        }
                    }
                    if component.hasPython {
                        Divider()
                        Text("Python").font(.callout.weight(.semibold))
                        pythonControls(component, root: root)
                        commandRow(id: runner.pythonID(component),
                                   title: "python " + (runner.pythonScripts[component.directory] ?? "main.py")) {
                            runner.startPython(component, in: root)
                        }
                    }
                    Divider()
                    Text("自定义入口（不限类型）").font(.callout.weight(.semibold))
                    customControls(component)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func pythonControls(_ component: ProjectComponent, root: String) -> some View {
        let suggested = ProjectDiscovery.preferredPython(for: component.directory, root: root,
                                                         interpreters: runner.scans[root]?.interpreters ?? [])
        let chosen = runner.pythonOverrides[component.directory]
        let options = Array(Set((runner.scans[root]?.interpreters ?? [])
                                + environments.environments.map(\.pythonPath)
                                + (chosen.map { [$0] } ?? []))).sorted()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("入口文件", text: Binding(
                    get: { runner.pythonScripts[component.directory] ?? "main.py" },
                    set: { runner.pythonScripts[component.directory] = $0 }))
                    .frame(maxWidth: 230)
                TextField("参数（可选）", text: Binding(
                    get: { runner.pythonArguments[component.directory] ?? "" },
                    set: { runner.pythonArguments[component.directory] = $0 }))
                    .frame(maxWidth: 300)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Text("解释器").font(.caption)
                Picker("", selection: Binding(
                    get: { runner.pythonOverrides[component.directory] ?? "" },
                    set: { runner.setPythonOverride($0.isEmpty ? nil : $0, for: component.directory) })) {
                    Text("自动：" + (suggested ?? ProjectDiscovery.executable("python3") ?? "未找到"))
                        .tag("")
                    ForEach(options, id: \.self) { path in
                        Text(verbatim: path).tag(path)
                    }
                }
                .labelsHidden().frame(maxWidth: 360)
                Button("添加…") { choosePythonInterpreter(for: component) }
            }
        }
    }

    /// 自定义入口：可执行文件 / .dll / 脚本都行，**不限制类型**。
    /// C# 编译出来的 `Ylp.Api`（或 Go 的二进制、任意带 shebang 的脚本）都能在这里选。
    private func customControls(_ component: ProjectComponent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("入口文件（.exe / .dll / 可执行脚本，不限类型）", text: Binding(
                    get: { runner.customExecutables[component.directory] ?? "" },
                    set: { runner.customExecutables[component.directory] = $0 }))
                    .frame(maxWidth: 360)
                Button("选择…") { chooseCustomExecutable(for: component) }
                TextField("参数（可选）", text: Binding(
                    get: { runner.customArguments[component.directory] ?? "" },
                    set: { runner.customArguments[component.directory] = $0 }))
                    .frame(maxWidth: 220)
            }
            .textFieldStyle(.roundedBorder)
            commandRow(id: runner.customID(component),
                       title: customEntryTitle(component)) {
                runner.startCustom(component)
            }
        }
    }

    private func customEntryTitle(_ component: ProjectComponent) -> String {
        let path = (runner.customExecutables[component.directory] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "（还没选入口）" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func chooseCustomExecutable(for component: ProjectComponent) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "选择要运行的入口（可执行文件、.dll、脚本都行，不限类型）"
        panel.prompt = "选为入口"
        panel.directoryURL = URL(fileURLWithPath: component.directory)
        if panel.runModal() == .OK, let url = panel.url {
            runner.customExecutables[component.directory] = url.path
        }
    }

    private func choosePythonInterpreter(for component: ProjectComponent) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "选择这个子工程使用的 python 或 python3 可执行文件"
        panel.prompt = "添加解释器"
        let current = runner.pythonOverrides[component.directory]
        panel.directoryURL = URL(fileURLWithPath: current.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
                                         ?? component.directory)
        if panel.runModal() == .OK, let url = panel.url {
            runner.setPythonOverride(url.path, for: component.directory)
        }
    }

    private func commandRow(id: String, title: String, start: @escaping () -> Void) -> some View {
        let state = runner.runs[id]
        return HStack(spacing: 8) {
            StatusDot(running: state?.running == true)
            Text(verbatim: title).font(.system(.callout, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let message = state?.message {
                Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).frame(maxWidth: 200, alignment: .trailing)
            }
            if state != nil {
                Button("输出") { selectedLogID = id }
            }
            if state?.running == true {
                Button("停止") { runner.stop(id) }
            } else {
                Button("运行") { start(); selectedLogID = id }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("命令输出").font(.callout.weight(.semibold))
                if let id = selectedLogID, let state = runner.runs[id] {
                    Text(verbatim: id.replacingOccurrences(of: "|", with: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(verbatim: state.running ? "运行中" : state.message)
                        .font(.caption).foregroundStyle(.secondary)
                    Button("复制全部") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.output, forType: .string)
                    }
                    .disabled(state.output.isEmpty)
                } else {
                    Spacer()
                }
            }
            if let id = selectedLogID, let state = runner.runs[id] {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(verbatim: String(state.output.suffix(20_000)))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .onChange(of: state.output.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
            } else {
                Text("运行命令后，这里显示输出；点击任意命令的「输出」可切换。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
    }

    private func ensureSelection() {
        if let selection, runner.roots.contains(selection.root),
           (selection.directory.isEmpty || runner.scans[selection.root]?.components.contains(where: { $0.directory == selection.directory }) == true) {
            return
        }
        guard let root = runner.roots.first else { selection = nil; return }
        selection = ProjectSelection(root: root, directory: runner.scans[root]?.components.first?.directory ?? "")
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "选择一个或多个工程目录"
        panel.prompt = "添加"
        panel.directoryURL = URL(fileURLWithPath: runner.roots.last ?? NSHomeDirectory())
        if panel.runModal() == .OK {
            for url in panel.urls { runner.add(url.path) }
            if let first = panel.urls.first {
                selection = ProjectSelection(root: first.standardizedFileURL.path, directory: "")
            }
        }
    }
}
