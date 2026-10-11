import SwiftUI
import AppKit

private struct LaunchableApp: Identifiable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// 只列出 Applications 目录中的应用包，不进入 .app 内部。
private enum ApplicationsCatalog {
    static func scan() -> [LaunchableApp] {
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     URL(fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true)]
        let files = FileManager.default
        var found: [LaunchableApp] = []
        var seen = Set<String>()

        func visit(_ directory: URL, depth: Int) {
            guard depth <= 4,
                  let children = try? files.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles]) else { return }
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if child.pathExtension.lowercased() == "app" {
                    if seen.insert(child.path).inserted { found.append(LaunchableApp(url: child)) }
                } else {
                    visit(child, depth: depth + 1)
                }
            }
        }

        for root in roots { visit(root, depth: 0) }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct QuickLaunchView: View {
    @EnvironmentObject private var model: AppModel
    @State private var apps: [LaunchableApp] = []
    @State private var search = ""
    @State private var showingPicker = false
    @State private var showingNameEditor = false
    @State private var editingWorkspaceID: String?
    @State private var draftName = ""
    @State private var confirmingDelete = false
    @State private var launching = false
    @State private var pendingLaunches = 0
    @State private var failedLaunches: [String] = []
    @State private var message = ""

    private var currentWorkspace: QuickLaunchWorkspace? {
        model.settings.quickLaunchWorkspaces.first {
            $0.id == model.settings.selectedQuickLaunchWorkspaceID
        }
    }

    private var currentIndex: Int? {
        model.settings.quickLaunchWorkspaces.firstIndex {
            $0.id == model.settings.selectedQuickLaunchWorkspaceID
        }
    }

    private var appByPath: [String: LaunchableApp] {
        Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
    }

    private var filteredApps: [LaunchableApp] {
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var nameIsValid: Bool {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !model.settings.quickLaunchWorkspaces.contains {
            $0.id != editingWorkspaceID && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("快捷启动").font(.title2.weight(.semibold))
                Spacer()
                Button("新建方案") { beginCreate() }
            }
            Text("每个方案保存自己的 App 组合。选择方案后，可一次打开其中的所有应用。")
                .font(.callout).foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(failedLaunches.isEmpty ? Color.secondary : Color.orange)
            }
            HStack(spacing: 0) {
                workspaceList.frame(width: 250)
                Divider()
                workspaceDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 14)
            }
        }
        .padding(16)
        .navigationTitle("快捷启动")
        .onAppear { apps = ApplicationsCatalog.scan() }
        .sheet(isPresented: $showingNameEditor) { nameEditor }
        .sheet(isPresented: $showingPicker) { appPicker }
        .alert("删除方案？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { deleteCurrentWorkspace() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除“\(currentWorkspace?.name ?? "")”及它保存的应用列表。不会卸载任何 App。")
        }
    }

    private var workspaceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("方案").font(.headline)
            List {
                ForEach(model.settings.quickLaunchWorkspaces) { workspace in
                    Button {
                        model.settings.selectedQuickLaunchWorkspaceID = workspace.id
                        SettingsStore.save(model.settings)
                        message = ""
                        failedLaunches = []
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.stack.3d.up")
                                .foregroundStyle(workspace.id == currentWorkspace?.id ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: workspace.name).lineLimit(1)
                                Text("\(workspace.appPaths.count) 个应用")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(workspace.id == currentWorkspace?.id
                                       ? Color.accentColor.opacity(0.15) : Color.clear)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var workspaceDetail: some View {
        if let workspace = currentWorkspace {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(verbatim: workspace.name).font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Button("重命名") { beginRename(workspace) }
                    Button("删除方案") { confirmingDelete = true }
                        .disabled(model.settings.quickLaunchWorkspaces.count <= 1 || launching)
                    Button("选择应用") {
                        apps = ApplicationsCatalog.scan()
                        search = ""
                        showingPicker = true
                    }
                    Button("启动此方案") { launch(workspace) }
                        .disabled(workspace.appPaths.isEmpty || launching)
                }
                if workspace.appPaths.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("这个方案还没有应用").font(.headline)
                        Text("点击「选择应用」添加要一起打开的 App。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(workspace.appPaths, id: \.self) { path in
                            HStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                    .resizable().frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: appByPath[path]?.name
                                         ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                                    Text(verbatim: appByPath[path] == nil ? "应用已不在 Applications 中" : path)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Button("移除") { setSelected(path, selected: false) }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingWorkspaceID == nil ? "新建方案" : "重命名方案").font(.headline)
            TextField("方案名称", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if nameIsValid { saveWorkspaceName() } }
            if !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !nameIsValid {
                Text("方案名称已存在。").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { showingNameEditor = false }
                Button("保存") { saveWorkspaceName() }
                    .disabled(!nameIsValid)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private var appPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("为“\(currentWorkspace?.name ?? "")”选择应用").font(.headline)
                Spacer()
                Button("完成") { showingPicker = false }
            }
            TextField("搜索应用", text: $search)
                .textFieldStyle(.roundedBorder)
            Text("已选择 \(currentWorkspace?.appPaths.count ?? 0) 个应用")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(filteredApps) { app in
                    Toggle(isOn: Binding(
                        get: { currentWorkspace?.appPaths.contains(app.id) ?? false },
                        set: { selected in setSelected(app.id, selected: selected) }
                    )) {
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.id))
                                .resizable().frame(width: 28, height: 28)
                            Text(verbatim: app.name)
                            Spacer()
                            Text(verbatim: app.url.deletingLastPathComponent().path)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 500)
    }

    private func beginCreate() {
        editingWorkspaceID = nil
        draftName = "新方案 \(model.settings.quickLaunchWorkspaces.count + 1)"
        showingNameEditor = true
    }

    private func beginRename(_ workspace: QuickLaunchWorkspace) {
        editingWorkspaceID = workspace.id
        draftName = workspace.name
        showingNameEditor = true
    }

    private func saveWorkspaceName() {
        guard nameIsValid else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editingWorkspaceID,
           let index = model.settings.quickLaunchWorkspaces.firstIndex(where: { $0.id == id }) {
            model.settings.quickLaunchWorkspaces[index].name = name
        } else {
            let workspace = QuickLaunchWorkspace(name: name)
            model.settings.quickLaunchWorkspaces.append(workspace)
            model.settings.selectedQuickLaunchWorkspaceID = workspace.id
            message = ""
        }
        SettingsStore.save(model.settings)
        showingNameEditor = false
    }

    private func deleteCurrentWorkspace() {
        guard model.settings.quickLaunchWorkspaces.count > 1,
              let index = currentIndex else { return }
        model.settings.quickLaunchWorkspaces.remove(at: index)
        model.settings.selectedQuickLaunchWorkspaceID = model.settings.quickLaunchWorkspaces[0].id
        SettingsStore.save(model.settings)
        message = ""
    }

    private func setSelected(_ path: String, selected: Bool) {
        guard let index = currentIndex else { return }
        if selected {
            if !model.settings.quickLaunchWorkspaces[index].appPaths.contains(path) {
                model.settings.quickLaunchWorkspaces[index].appPaths.append(path)
            }
        } else {
            model.settings.quickLaunchWorkspaces[index].appPaths.removeAll { $0 == path }
        }
        SettingsStore.save(model.settings)
    }

    private func launch(_ workspace: QuickLaunchWorkspace) {
        // 重新扫描，避免向已移走或已替换的应用发出启动请求。
        apps = ApplicationsCatalog.scan()
        let catalog = appByPath
        let targets = workspace.appPaths.compactMap { catalog[$0] }
        failedLaunches = workspace.appPaths.filter { catalog[$0] == nil }
            .map { URL(fileURLWithPath: $0).lastPathComponent + "：应用已不在 Applications 中" }
        guard !targets.isEmpty else {
            message = failedLaunches.isEmpty ? "请先选择应用。" : failedLaunches.joined(separator: "；")
            return
        }

        launching = true
        pendingLaunches = targets.count
        message = "正在打开“\(workspace.name)”中的 \(targets.count) 个应用…"
        for app in targets {
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                DispatchQueue.main.async {
                    if let error { failedLaunches.append(app.name + "：" + error.localizedDescription) }
                    pendingLaunches -= 1
                    if pendingLaunches == 0 {
                        launching = false
                        message = failedLaunches.isEmpty
                            ? "已打开“\(workspace.name)”中的 \(targets.count) 个应用。"
                            : "“\(workspace.name)”启动完成；\(failedLaunches.joined(separator: "；"))"
                    }
                }
            }
        }
    }
}
