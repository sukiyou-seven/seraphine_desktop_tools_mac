import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ServerFilesView: View {
    let connection: ServerConnection
    let token: String

    init(connection: ServerConnection, token: String, startPath: String = "/www/seraphim") {
        self.connection = connection
        self.token = token
        _currentPath = State(initialValue: startPath)
        _pathInput = State(initialValue: startPath)
    }

    @State private var currentPath: String
    @State private var pathInput: String
    @State private var listing: RemoteFileListing?
    @State private var selectedPath: String?
    @State private var action: String?
    @State private var nameInput = ""
    @State private var permissionTarget: RemoteFile?
    @State private var permissionsInput = ""
    @State private var permissionsError = ""
    @State private var pendingUpload: [URL] = []
    @State private var dropTargeted = false
    @State private var pendingRename: (from: String, to: String)?
    @State private var confirmUploadOverwrite = false
    @State private var confirmRenameOverwrite = false
    @State private var confirmDelete = false
    @State private var pendingDelete: RemoteFile?
    @State private var working = false
    @State private var message = ""
    @State private var hasError = false

    private var selected: RemoteFile? {
        listing?.entries.first(where: { $0.path == selectedPath })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("上一级") { navigate(to: listing?.parent ?? "/") }
                    .disabled(working || currentPath == "/")
                TextField("服务器路径", text: $pathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit { navigate(to: pathInput) }
                Button("前往") { navigate(to: pathInput) }
                    .disabled(working)
                Button("刷新") { Task { await refresh() } }
                    .disabled(working)
            }

            HStack(spacing: 8) {
                Button("新建文件夹") { beginAction("folder") }.disabled(working)
                Button("新建文件") { beginAction("file") }.disabled(working)
                Button("上传") { chooseUpload() }.disabled(working)
                Divider().frame(height: 20)
                Button("下载") { chooseDownload() }
                    .disabled(working || selected?.isRegularFile != true)
                Button("重命名") { beginRename() }
                    .disabled(working || selected == nil)
                Button("修改权限") { if let selected { beginPermissions(for: selected) } }
                    .disabled(working || selected?.permissions == nil || selected?.isProtectedPath == true)
                Button("删除") { if let selected { askDelete(selected) } }
                    .disabled(working || selected == nil || selected?.isProtectedPath == true)
                Spacer(minLength: 0)
                if working { ProgressView().controlSize(.small) }
            }

            if let action {
                HStack(spacing: 8) {
                    Text(action == "folder" ? "文件夹名称" : action == "file" ? "文件名称" : "新名称")
                        .frame(width: 88, alignment: .leading)
                    TextField("名称", text: $nameInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 400)
                        .onSubmit { submitAction() }
                    Button("确定") { submitAction() }.disabled(nameInput.isEmpty || working)
                    Button("取消") { self.action = nil }
                }
            }

            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(hasError ? Color.orange : Color.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("权限").frame(width: 60, alignment: .trailing)
                Text("大小").frame(width: 110, alignment: .trailing)
                Text("修改时间").frame(width: 145, alignment: .trailing)
                Text("操作").frame(width: 76, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)

            Divider()
            FlexibleScroll {
                LazyVStack(spacing: 0) {
                    ForEach(listing?.entries ?? []) { item in
                        row(item)
                    }
                    if listing?.entries.isEmpty == true {
                        EmptyHint(text: "此目录为空")
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(dropTargeted ? Color.accentColor : .clear, lineWidth: 3))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: receiveDrop)

            Text("可选择多个文件或文件夹，也可拖拽到列表上传；保留目录结构和空目录。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("点击权限数字可修改权限；点击每行的删除按钮可删除文件或目录。新上传的普通文件默认 0644，新建目录默认 0755。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .serverManagementRefresh)) { _ in
            Task { await refresh() }
        }
        .confirmationDialog("服务器上已有同名文件或文件夹，覆盖文件并合并文件夹？", isPresented: $confirmUploadOverwrite) {
            Button("覆盖上传", role: .destructive) { upload(overwrite: true) }
            Button("取消", role: .cancel) { pendingUpload = [] }
        } message: {
            Text(pendingUpload.map(\.lastPathComponent).joined(separator: "、"))
        }
        .confirmationDialog("覆盖重命名目标文件？", isPresented: $confirmRenameOverwrite) {
            Button("覆盖并重命名", role: .destructive) { rename(overwrite: true) }
            Button("取消", role: .cancel) { pendingRename = nil }
        } message: {
            Text(pendingRename?.to ?? "")
        }
        .confirmationDialog("确定删除服务器上的文件？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { deletePending() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.isDirectory == true ? "将递归删除 \(pendingDelete?.path ?? "") 及其全部内容。" : (pendingDelete?.path ?? ""))
        }
        .sheet(item: $permissionTarget) { item in
            VStack(alignment: .leading, spacing: 12) {
                Text("修改权限").font(.headline)
                Text(verbatim: item.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                TextField("例如 0644 或 0755", text: $permissionsInput)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { submitPermissions() }
                if !permissionsError.isEmpty {
                    Text(verbatim: permissionsError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("普通文件通常用 0644，目录和可执行文件通常用 0755。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { permissionTarget = nil }
                    Button("保存") { submitPermissions() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }

    private func row(_ item: RemoteFile) -> some View {
        HStack(spacing: 8) {
            Button {
                selectedPath = item.path
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: item.isDirectory ? "folder.fill" : item.isRegularFile ? "doc" : "link")
                        .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                        .frame(width: 20)
                    Text(verbatim: item.name)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let permissions = item.permissions {
                Button(permissions) { beginPermissions(for: item) }
                    .buttonStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 60, alignment: .trailing)
                    .help("点击修改权限")
                    .disabled(working || item.isProtectedPath)
            } else {
                Text("—").frame(width: 60, alignment: .trailing)
            }
            Text(item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                .frame(width: 110, alignment: .trailing)
            Text(String(item.modifiedAt.prefix(16)).replacingOccurrences(of: "T", with: " "))
                .frame(width: 145, alignment: .trailing)
            HStack(spacing: 4) {
                if item.isDirectory {
                    Button("进入") { navigate(to: item.path) }
                        .buttonStyle(.borderless)
                        .frame(width: 44)
                } else {
                    Spacer().frame(width: 44)
                }
                if item.isProtectedPath {
                    Image(systemName: "lock")
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                        .help("固定目录不可删除")
                } else {
                    Button { askDelete(item) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28)
                    .help("删除 \(item.name)")
                    .disabled(working)
                }
            }
            .frame(width: 76)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(item.path == selectedPath ? Color.accentColor.opacity(0.13) : Color.clear)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if item.isDirectory && !working { navigate(to: item.path) }
        })
        .contextMenu {
            if item.permissions != nil && !item.isProtectedPath {
                Button("修改权限…") { beginPermissions(for: item) }
            }
            Button("删除", role: .destructive) { askDelete(item) }
                .disabled(item.isProtectedPath)
        }
    }

    private func navigate(to path: String) {
        currentPath = path
        pathInput = path
        selectedPath = nil
        Task { await refresh() }
    }

    @MainActor private func refresh() async {
        guard !working else { return }
        guard !token.isEmpty else {
            message = "请先在「服务器状态」保存连接令牌"
            hasError = true
            return
        }
        working = true
        defer { working = false }
        do {
            let result = try await ServerFileAPI.list(connection: connection, token: token, path: currentPath)
            listing = result
            currentPath = result.path
            pathInput = result.path
            if !result.entries.contains(where: { $0.path == selectedPath }) { selectedPath = nil }
            message = "\(result.entries.count) 项"
            hasError = false
        } catch {
            message = error.localizedDescription
            hasError = true
        }
    }

    private func execute(_ operation: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        Task {
            do {
                try await operation()
                working = false
                await refresh()
                message = "操作完成"
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func beginAction(_ kind: String) {
        nameInput = ""
        action = kind
    }

    private func beginRename() {
        guard let selected else { return }
        nameInput = selected.name
        action = "rename"
    }

    private func beginPermissions(for item: RemoteFile) {
        guard let permissions = item.permissions, !item.isProtectedPath, !working else { return }
        selectedPath = item.path
        action = nil
        permissionsInput = permissions
        permissionsError = ""
        permissionTarget = item
    }

    private func submitPermissions() {
        guard let item = permissionTarget, !working else { return }
        let value = permissionsInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...4).contains(value.count), value.allSatisfy({ "01234567".contains($0) }),
              let mode = Int(value, radix: 8), mode <= 0o777 else {
            permissionsError = "请输入 000 到 0777 的八进制权限，例如 0644 或 0755"
            return
        }
        permissionTarget = nil
        execute {
            try await ServerFileAPI.chmod(connection: connection, token: token,
                                          path: item.path, permissions: value)
        }
    }

    private func askDelete(_ item: RemoteFile) {
        guard !item.isProtectedPath, !working else { return }
        pendingDelete = item
        confirmDelete = true
    }

    private func path(for name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\0") else {
            message = "名称不能包含斜杠，也不能是 . 或 .."
            hasError = true
            return nil
        }
        let base = listing?.path ?? currentPath
        return (base == "/" ? "" : base) + "/" + value
    }

    private func submitAction() {
        guard let action, let target = path(for: nameInput) else { return }
        self.action = nil
        switch action {
        case "folder":
            execute { try await ServerFileAPI.mkdir(connection: connection, token: token, path: target) }
        case "file":
            execute { try await ServerFileAPI.createFile(connection: connection, token: token, path: target) }
        case "rename":
            guard let selected else { return }
            if selected.path == target { return }
            pendingRename = (selected.path, target)
            if listing?.entries.contains(where: { $0.path == target }) == true {
                confirmRenameOverwrite = true
            } else {
                rename(overwrite: false)
            }
        default: break
        }
    }

    private func rename(overwrite: Bool) {
        guard let item = pendingRename else { return }
        pendingRename = nil
        execute {
            try await ServerFileAPI.rename(connection: connection, token: token,
                                           from: item.from, to: item.to, overwrite: overwrite)
        }
    }

    private func deletePending() {
        guard let item = pendingDelete else { return }
        pendingDelete = nil
        execute {
            try await ServerFileAPI.delete(connection: connection, token: token,
                                           path: item.path, recursive: item.isDirectory)
        }
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        stageUpload(panel.urls)
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty, !working else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in matching {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let value = item as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                else { url = nil }
                if let url, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { stageUpload(urls) }
        return true
    }

    private func stageUpload(_ locals: [URL]) {
        guard !working, !locals.isEmpty else { return }
        let names = locals.map(\.lastPathComponent)
        guard Set(names).count == names.count else {
            message = "所选文件或文件夹的名称重复"
            hasError = true
            return
        }
        pendingUpload = locals
        if listing?.entries.contains(where: { names.contains($0.name) }) == true {
            confirmUploadOverwrite = true
        } else {
            upload(overwrite: false)
        }
    }

    private func upload(overwrite: Bool) {
        let locals = pendingUpload
        guard !locals.isEmpty, !working else { return }
        pendingUpload = []
        let directory = listing?.path ?? currentPath
        working = true
        message = "正在上传 \(locals.count) 项…"
        hasError = false
        Task {
            do {
                let result = try await ServerFileAPI.uploadSelection(connection: connection, token: token,
                    localURLs: locals, remoteDirectory: directory, overwrite: overwrite)
                working = false
                await refresh()
                message = "上传完成：\(result.files) 个文件、\(result.directories) 个文件夹" +
                    (result.skipped > 0 ? "；跳过 \(result.skipped) 个符号链接或特殊文件" : "")
                hasError = false
            } catch {
                working = false
                message = error.localizedDescription
                hasError = true
            }
        }
    }

    private func chooseDownload() {
        guard let item = selected, item.isRegularFile else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        execute {
            try await ServerFileAPI.download(connection: connection, token: token,
                                             remotePath: item.path, saveTo: destination)
        }
    }
}
