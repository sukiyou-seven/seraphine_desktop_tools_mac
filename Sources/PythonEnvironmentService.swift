import Foundation
import Darwin

struct PythonEnvironment: Identifiable, Equatable {
    let pythonPath: String
    let source: String
    let virtualDirectory: String?
    var id: String { pythonPath }
    var name: String {
        if let virtualDirectory { return URL(fileURLWithPath: virtualDirectory).lastPathComponent }
        return URL(fileURLWithPath: pythonPath).lastPathComponent
    }
    var isVirtual: Bool { virtualDirectory != nil }
}

struct PythonPackage: Decodable, Identifiable {
    let name: String
    let version: String
    var id: String { name.lowercased() }
}

enum PythonEnvironmentDiscovery {
    private static let ignored: Set<String> = [".git", "node_modules", "dist", "build", "coverage",
                                                "__pycache__", ".next", ".nuxt", ".tox", ".mypy_cache"]

    static func pythonPath(at path: String) -> String? {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            for name in ["bin/python", "bin/python3"] {
                let candidate = url.appendingPathComponent(name).path
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
            return nil
        }
        return fm.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    static func virtualDirectory(for pythonPath: String) -> String? {
        let python = URL(fileURLWithPath: pythonPath).standardizedFileURL
        let bin = python.deletingLastPathComponent()
        guard bin.lastPathComponent == "bin" else { return nil }
        let directory = bin.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("pyvenv.cfg").path) else { return nil }
        return directory.path
    }

    static func deletableDirectory(for pythonPath: String) -> String? {
        guard let directory = virtualDirectory(for: pythonPath),
              (try? URL(fileURLWithPath: directory).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: directory),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              FileManager.default.isExecutableFile(atPath: pythonPath) else { return nil }
        return directory
    }

    static func discover(projectRoots: [String], addedPaths: [String], createdPaths: [String],
                         hiddenPaths: Set<String> = []) -> [PythonEnvironment] {
        let fm = FileManager.default
        var candidates: [(String, String)] = []
        for path in addedPaths { candidates.append((path, createdPaths.contains(path) ? "本工具创建" : "手动添加")) }

        func addEnvironments(in parent: String, source: String) {
            for child in (try? fm.contentsOfDirectory(atPath: parent)) ?? [] {
                let path = parent + "/" + child
                if virtualDirectory(for: path + "/bin/python") != nil { candidates.append((path, source)) }
                else if fm.isExecutableFile(atPath: path + "/bin/python") { candidates.append((path, source)) }
            }
        }

        for root in projectRoots {
            func walk(_ directory: String, depth: Int) {
                guard depth <= 5 else { return }
                if fm.fileExists(atPath: directory + "/pyvenv.cfg") {
                    candidates.append((directory, "工程目录"))
                    return
                }
                guard depth < 5 else { return }
                for child in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] {
                    if ignored.contains(child) || child.hasPrefix(".") && child != ".venv" { continue }
                    let path = directory + "/" + child
                    let url = URL(fileURLWithPath: path)
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values?.isDirectory == true && values?.isSymbolicLink != true { walk(path, depth: depth + 1) }
                }
            }
            walk(root, depth: 0)
        }

        let user = NSHomeDirectory()
        for parent in [user + "/.virtualenvs", user + "/Envs", user + "/miniconda3/envs",
                       user + "/anaconda3/envs", user + "/.local/share/virtualenvs"] {
            addEnvironments(in: parent, source: "常用位置")
        }
        for child in (try? fm.contentsOfDirectory(atPath: user + "/.pyenv/versions")) ?? [] {
            candidates.append((user + "/.pyenv/versions/" + child + "/bin/python", "pyenv"))
        }
        for bin in Set(Paths.searchPaths + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)) {
            for name in (try? fm.contentsOfDirectory(atPath: bin)) ?? [] {
                if name == "python" || name == "python3"
                    || name.range(of: #"^python3\.\d+t?$"#, options: .regularExpression) != nil {
                    candidates.append((bin + "/" + name, "本机 Python"))
                }
            }
        }

        var seen = Set<String>()
        return candidates.compactMap { path, source in
            guard let python = pythonPath(at: path), !hiddenPaths.contains(python),
                  seen.insert(python).inserted else { return nil }
            return PythonEnvironment(pythonPath: python, source: source,
                                     virtualDirectory: virtualDirectory(for: python))
        }.sorted { a, b in
            if a.isVirtual != b.isVirtual { return a.isVirtual }
            return a.pythonPath.localizedStandardCompare(b.pythonPath) == .orderedAscending
        }
    }
}

private struct PythonEnvironmentCatalog: Codable {
    var addedPaths: [String] = []
    var createdPaths: [String] = []
    var hiddenPaths: Set<String> = []
    var indexURL = ""
    var selectedPath = ""

    init() {}
    private enum CodingKeys: String, CodingKey { case addedPaths, createdPaths, hiddenPaths, indexURL, selectedPath }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        addedPaths = try values.decodeIfPresent([String].self, forKey: .addedPaths) ?? []
        createdPaths = try values.decodeIfPresent([String].self, forKey: .createdPaths) ?? []
        hiddenPaths = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenPaths) ?? []
        indexURL = try values.decodeIfPresent(String.self, forKey: .indexURL) ?? ""
        selectedPath = try values.decodeIfPresent(String.self, forKey: .selectedPath) ?? ""
    }
}

@MainActor
final class PythonEnvironmentManager: ObservableObject {
    @Published private(set) var environments: [PythonEnvironment] = []
    @Published var selectedPath = ""
    @Published var packageInput = ""
    @Published var upgradePackages = false
    @Published private(set) var indexURL = ""
    @Published private(set) var packages: [PythonPackage] = []
    @Published var packageSearch = ""
    @Published private(set) var busy: String?
    @Published private(set) var scanning = false
    @Published private(set) var output = ""
    @Published var message = ""

    private var catalog = PythonEnvironmentCatalog()
    private let catalogURL: URL
    private var scanGeneration = 0
    private var process: Process?
    private var pipe: Pipe?
    private var processGroup = false
    private var onSuccess: (() -> Void)?

    init(catalogURL: URL? = nil) {
        self.catalogURL = catalogURL ?? Paths.appSupport.appendingPathComponent("python-environments.json")
        if let data = try? Data(contentsOf: self.catalogURL),
           let saved = try? JSONDecoder().decode(PythonEnvironmentCatalog.self, from: data) {
            catalog = saved
            selectedPath = saved.selectedPath
            indexURL = saved.indexURL
        }
    }

    private func save() {
        catalog.selectedPath = selectedPath
        catalog.indexURL = indexURL
        if let data = try? JSONEncoder().encode(catalog) { try? data.write(to: catalogURL, options: .atomic) }
    }

    func refresh(projectRoots: [String]) {
        scanGeneration += 1
        let generation = scanGeneration
        let added = catalog.addedPaths
        let created = catalog.createdPaths
        let hidden = catalog.hiddenPaths
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = PythonEnvironmentDiscovery.discover(projectRoots: projectRoots,
                                                            addedPaths: added, createdPaths: created,
                                                            hiddenPaths: hidden)
            DispatchQueue.main.async {
                guard self.scanGeneration == generation else { return }
                self.environments = found
                self.scanning = false
                if !found.contains(where: { $0.pythonPath == self.selectedPath }) {
                    self.selectedPath = found.first?.pythonPath ?? ""
                    self.save()
                }
            }
        }
    }

    func select(_ path: String) {
        selectedPath = path
        packages = []
        save()
    }

    func add(_ path: String, projectRoots: [String]) {
        guard let python = PythonEnvironmentDiscovery.pythonPath(at: path) else {
            message = "找不到可执行的 Python：\(path)"
            return
        }
        if !catalog.addedPaths.contains(python) { catalog.addedPaths.append(python) }
        catalog.hiddenPaths.remove(python)
        selectedPath = python
        message = "已添加 Python 环境"
        save()
        refresh(projectRoots: projectRoots)
    }

    func removeFromList(_ environment: PythonEnvironment, projectRoots: [String]) {
        catalog.addedPaths.removeAll { $0 == environment.pythonPath }
        catalog.createdPaths.removeAll { $0 == environment.pythonPath }
        catalog.hiddenPaths.insert(environment.pythonPath)
        if selectedPath == environment.pythonPath { selectedPath = ""; packages = [] }
        save()
        refresh(projectRoots: projectRoots)
    }

    func isAdded(_ environment: PythonEnvironment) -> Bool {
        catalog.addedPaths.contains(environment.pythonPath)
    }

    func setIndexURL(_ value: String) {
        indexURL = value
        save()
    }

    nonisolated static func validIndexURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let url = URLComponents(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return false }
        return true
    }

    func create(parent: String, name: String, basePython: String, projectRoots: [String]) {
        let folder = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty, folder != ".", folder != "..", !folder.contains("/"), !folder.contains("\\") else {
            message = "环境名称只能是单个文件夹名称"
            return
        }
        guard FileTools.isDirectory(parent) else { message = "请选择现有的父目录"; return }
        guard FileManager.default.isExecutableFile(atPath: basePython) else { message = "请选择可用的基础 Python"; return }
        let target = URL(fileURLWithPath: parent).appendingPathComponent(folder).standardizedFileURL.path
        guard !FileManager.default.fileExists(atPath: target) else { message = "目标目录已存在：\(target)"; return }
        launch(executable: basePython, arguments: ["-m", "venv", target], cwd: parent,
               label: "正在创建环境…") {
            guard let python = PythonEnvironmentDiscovery.pythonPath(at: target) else {
                self.message = "命令已结束，但没有找到新环境的 Python"
                return
            }
            if !self.catalog.addedPaths.contains(python) { self.catalog.addedPaths.append(python) }
            if !self.catalog.createdPaths.contains(python) { self.catalog.createdPaths.append(python) }
            self.catalog.hiddenPaths.remove(python)
            self.selectedPath = python
            self.save()
            self.refresh(projectRoots: projectRoots)
        }
    }

    func delete(_ environment: PythonEnvironment, projectRoots: [String]) {
        guard busy == nil else { message = "请等待当前操作结束"; return }
        guard let directory = PythonEnvironmentDiscovery.deletableDirectory(for: environment.pythonPath) else {
            message = "只能删除带 pyvenv.cfg 的虚拟环境；系统 Python 不会被删除"
            return
        }
        busy = "正在删除环境…"
        output = "删除 \(directory)\n"
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do { try FileManager.default.removeItem(atPath: directory) }
            catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                self.busy = nil
                if let failure {
                    self.message = "删除失败：\(failure)"
                } else {
                    self.message = "已删除虚拟环境：\(directory)"
                    self.catalog.addedPaths.removeAll { $0 == environment.pythonPath }
                    self.catalog.createdPaths.removeAll { $0 == environment.pythonPath }
                    self.catalog.hiddenPaths.remove(environment.pythonPath)
                    if self.selectedPath == environment.pythonPath { self.selectedPath = ""; self.packages = [] }
                    self.save()
                    self.refresh(projectRoots: projectRoots)
                }
            }
        }
    }

    func installPackages() {
        guard let environment = environments.first(where: { $0.pythonPath == selectedPath }) else {
            message = "请先选择 Python 环境"
            return
        }
        guard let specs = ProjectRunner.parseArguments(packageInput), !specs.isEmpty else {
            message = "请输入包名；参数中的引号需成对"
            return
        }
        let source = indexURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validIndexURL(source) else { message = "pip 源需为完整的 http:// 或 https:// 地址"; return }
        var arguments = ["-m", "pip", "install"]
        if upgradePackages { arguments.append("--upgrade") }
        if !source.isEmpty { arguments += ["--index-url", source] }
        arguments += specs
        let cwd = environment.virtualDirectory.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        } ?? NSHomeDirectory()
        launch(executable: environment.pythonPath, arguments: arguments, cwd: cwd,
               label: "正在安装包…") {
            self.message = "安装完成"
            self.loadPackages()
        }
    }

    func loadPackages() {
        guard let environment = environments.first(where: { $0.pythonPath == selectedPath }) else { packages = []; return }
        let path = environment.pythonPath
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Shell.run([path, "-m", "pip", "list", "--format=json"], timeout: 45)
            let parsed = try? JSONDecoder().decode([PythonPackage].self, from: Data(result.stdout.utf8))
            DispatchQueue.main.async {
                guard self.selectedPath == path else { return }
                if let parsed, result.ok {
                    self.packages = parsed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                } else {
                    self.packages = []
                    self.message = "读取包列表失败：\(result.message)"
                }
            }
        }
    }

    private func launch(executable: String, arguments: [String], cwd: String, label: String,
                        onSuccess: @escaping () -> Void) {
        guard busy == nil else { message = "请等待当前操作结束"; return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ([URL(fileURLWithPath: executable).deletingLastPathComponent().path]
                               + Paths.searchPaths + (environment["PATH"] ?? "").split(separator: ":").map(String.init))
            .joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        task.environment = environment
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.output += chunk
                if self.output.count > 100_000 { self.output = String(self.output.suffix(100_000)) }
            }
        }
        task.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.finish(status: ended.terminationStatus) }
        }
        do {
            try task.run()
            processGroup = setpgid(task.processIdentifier, task.processIdentifier) == 0
            process = task
            self.pipe = pipe
            self.onSuccess = onSuccess
            busy = label
            output = "$ \(executable) \(arguments.joined(separator: " "))\n"
            message = ""
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            message = "启动失败：\(error.localizedDescription)"
        }
    }

    private func finish(status: Int32) {
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        process = nil
        processGroup = false
        busy = nil
        if status == 0 {
            let completion = onSuccess
            onSuccess = nil
            completion?()
            if message.isEmpty { message = "操作完成" }
        } else {
            onSuccess = nil
            message = "命令退出，代码 \(status)。请查看下方输出。"
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        if processGroup { _ = kill(-process.processIdentifier, SIGTERM) }
        else {
            for child in Self.descendants(of: process.processIdentifier).reversed() {
                _ = kill(child, SIGTERM)
            }
            process.terminate()
        }
    }

    private static func descendants(of pid: Int32) -> [Int32] {
        let result = Shell.run(["/usr/bin/pgrep", "-P", String(pid)], timeout: 3)
        let children = result.stdout.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        return children + children.flatMap { descendants(of: $0) }
    }
}
