import SwiftUI
import AppKit

struct PythonEnvironmentView: View {
    @ObservedObject var manager: PythonEnvironmentManager
    @ObservedObject var projects: ProjectRunner
    @State private var showCreate = false
    @State private var createParent = ""
    @State private var createName = ".venv"
    @State private var basePython = ""
    @State private var pendingDelete: PythonEnvironment?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Python 环境").font(.headline)
                Text(verbatim: "\(manager.environments.count) 个")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if manager.scanning { ProgressView().controlSize(.small) }
                Button("扫描本机") { manager.refresh(projectRoots: projects.roots) }
                Button("添加已有环境") { chooseExisting() }
                Button(showCreate ? "收起新建" : "新建虚拟环境") { showCreate.toggle() }
            }
            if !manager.message.isEmpty {
                Text(verbatim: manager.message).font(.callout)
                    .foregroundStyle(manager.message.contains("失败") || manager.message.contains("找不到") ? .orange : .secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
            if showCreate { createCard }
            HStack(spacing: 0) {
                environmentList.frame(width: 310)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    environmentDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    outputPanel.frame(height: 195)
                }
                .padding(.leading, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .navigationTitle("Python 环境")
        .onAppear {
            manager.refresh(projectRoots: projects.roots)
            if createParent.isEmpty { createParent = projects.roots.first ?? NSHomeDirectory() }
            if basePython.isEmpty { basePython = defaultBasePython }
        }
        .onChange(of: manager.selectedPath) { _ in manager.loadPackages() }
        .onChange(of: manager.environments) { _ in manager.loadPackages() }
        .alert(item: $pendingDelete) { environment in
            Alert(title: Text("删除虚拟环境？"),
                  message: Text(verbatim: "将永久删除 \(environment.virtualDirectory ?? "") 及其中安装的包。"),
                  primaryButton: .destructive(Text("删除")) {
                      manager.delete(environment, projectRoots: projects.roots)
                  },
                  secondaryButton: .cancel(Text("取消")))
        }
    }

    private var environmentList: some View {
        List(selection: Binding(
            get: { manager.selectedPath },
            set: { manager.select($0) })) {
            ForEach(manager.environments) { environment in
                HStack(spacing: 8) {
                    Text(environment.isVirtual ? "🐍" : "Py")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: environment.name).lineLimit(1)
                        Text(verbatim: environment.source + " · " + environment.pythonPath)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .tag(environment.pythonPath)
            }
        }
        .listStyle(.sidebar)
    }

    private var selectedEnvironment: PythonEnvironment? {
        manager.environments.first { $0.pythonPath == manager.selectedPath }
    }

    @ViewBuilder
    private var environmentDetail: some View {
        if let environment = selectedEnvironment {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(verbatim: environment.name).font(.title2.weight(.semibold))
                    Text(verbatim: environment.isVirtual ? "虚拟环境" : "基础 Python")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if manager.isAdded(environment) {
                        Button("从列表移除") {
                            manager.removeFromList(environment, projectRoots: projects.roots)
                        }
                        .disabled(manager.busy != nil || projects.isUsingInterpreter(environment.pythonPath))
                    }
                    if PythonEnvironmentDiscovery.deletableDirectory(for: environment.pythonPath) != nil {
                        Button("删除环境", role: .destructive) { pendingDelete = environment }
                            .disabled(manager.busy != nil || projects.isUsingInterpreter(environment.pythonPath))
                    }
                }
                Text(verbatim: environment.pythonPath).font(.caption.monospaced())
                    .foregroundStyle(.secondary).textSelection(.enabled)
                if let directory = environment.virtualDirectory {
                    Text(verbatim: "环境目录：\(directory)").font(.caption)
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                Divider()
                Text("安装包").font(.callout.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("包名，如 requests==2.31.0；多个包用空格分隔", text: $manager.packageInput)
                        .textFieldStyle(.roundedBorder)
                    Toggle("升级", isOn: $manager.upgradePackages).fixedSize()
                    Button("pip 安装") { manager.installPackages() }
                        .disabled(manager.busy != nil || manager.packageInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: 8) {
                    Text("pip 源").font(.callout)
                    TextField("留空使用 pip 当前默认源；可填 https://…/simple", text: Binding(
                        get: { manager.indexURL },
                        set: { manager.setIndexURL($0) }))
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("已安装的包").font(.callout.weight(.semibold))
                    Text(verbatim: "\(manager.packages.count) 个")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    TextField("搜索包", text: $manager.packageSearch)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    Button("刷新列表") { manager.loadPackages() }.disabled(manager.busy != nil)
                }
                List(filteredPackages) { package in
                    HStack {
                        Text(verbatim: package.name)
                        Spacer()
                        Text(verbatim: package.version).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("选择 Python 环境").font(.title2.weight(.semibold))
                Text("可扫描本机、添加已有解释器，或在指定目录新建虚拟环境。")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var filteredPackages: [PythonPackage] {
        let query = manager.packageSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return manager.packages }
        return manager.packages.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var createCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("新建虚拟环境").font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                Text("父目录").frame(width: 55, alignment: .leading)
                TextField("选择工程或其它目录", text: $createParent)
                    .textFieldStyle(.roundedBorder)
                Button("选择…") { chooseParent() }
                Text("名称")
                TextField(".venv", text: $createName)
                    .textFieldStyle(.roundedBorder).frame(width: 110)
            }
            HStack(spacing: 8) {
                Text("基础 Python").frame(width: 85, alignment: .leading)
                Picker("", selection: $basePython) {
                    ForEach(basePythonOptions, id: \.self) { path in
                        Text(verbatim: path).tag(path)
                    }
                }
                .labelsHidden().frame(maxWidth: 460)
                Button("创建") {
                    manager.create(parent: createParent, name: createName,
                                   basePython: basePython, projectRoots: projects.roots)
                }
                .disabled(manager.busy != nil || basePython.isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var basePythonOptions: [String] {
        var choices = manager.environments.filter { !$0.isVirtual }.map(\.pythonPath)
        if let fallback = ProjectDiscovery.executable("python3") { choices.append(fallback) }
        if !basePython.isEmpty { choices.append(basePython) }
        return Array(Set(choices)).sorted()
    }

    private var defaultBasePython: String {
        manager.environments.first(where: { !$0.isVirtual })?.pythonPath
            ?? ProjectDiscovery.executable("python3") ?? ""
    }

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("命令输出").font(.callout.weight(.semibold))
                if let busy = manager.busy {
                    ProgressView().controlSize(.mini)
                    Text(verbatim: busy).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("停止") { manager.stop() }
                } else { Spacer() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(verbatim: String(manager.output.suffix(20_000)))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: manager.output.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
    }

    private func chooseExisting() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.message = "选择虚拟环境目录，或 python / python3 可执行文件"
        panel.prompt = "添加环境"
        panel.directoryURL = URL(fileURLWithPath: projects.roots.first ?? NSHomeDirectory())
        if panel.runModal() == .OK {
            for url in panel.urls { manager.add(url.path, projectRoots: projects.roots) }
        }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择新虚拟环境的父目录"
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: FileTools.isDirectory(createParent) ? createParent : NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url { createParent = url.path }
    }
}
