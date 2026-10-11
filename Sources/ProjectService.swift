import Foundation
import Darwin
import AppKit

struct ProjectComponent: Identifiable, Equatable {
    let directory: String
    let relativePath: String
    let scripts: [String]
    let hasPython: Bool
    let hasWeChat: Bool
    var id: String { directory }
}

struct ProjectScan: Equatable {
    let components: [ProjectComponent]
    let interpreters: [String]
}

enum ProjectDiscovery {
    private static let ignored: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".next", ".nuxt", ".output",
        "dist", "build", "coverage", "vendor", "__pycache__", ".pytest_cache",
        ".mypy_cache", ".tox", ".idea", ".vscode", "venv", ".venv", "env", ".env"
    ]

    static func weChatProjectDirectory(in directory: String) -> String? {
        let paths = [directory, directory + "/dist/dev/mp-weixin", directory + "/dist/build/mp-weixin",
                     directory + "/unpackage/dist/dev/mp-weixin", directory + "/unpackage/dist/build/mp-weixin",
                     directory + "/dist", directory + "/build"]
        return paths.first {
            FileManager.default.fileExists(atPath: $0 + "/project.config.json")
        }
    }

    static func scan(root: String, maxDepth: Int = 5) -> ProjectScan {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: root).standardizedFileURL
        var components: [ProjectComponent] = []
        var interpreters: [String] = []

        func walk(_ url: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            let path = url.path
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }

            for name in [".venv", "venv", "env"] {
                let python = url.appendingPathComponent(name).appendingPathComponent("bin/python").path
                if fm.isExecutableFile(atPath: python) { interpreters.append(python) }
            }

            var scripts: [String] = []
            let packageURL = url.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: packageURL),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let entries = object["scripts"] as? [String: Any] {
                scripts = entries.compactMap { key, value in value is String ? key : nil }.sorted()
            }
            let hasPython = ["main.py", "pyproject.toml", "requirements.txt"].contains {
                fm.fileExists(atPath: url.appendingPathComponent($0).path)
            }
            let hasWeChat = weChatProjectDirectory(in: path) != nil
                || scripts.contains { $0.localizedCaseInsensitiveContains("mp-weixin")
                    || $0.localizedCaseInsensitiveContains("weapp") }
            if !scripts.isEmpty || hasPython || hasWeChat {
                let relative = path == base.path ? "." : String(path.dropFirst(base.path.count + 1))
                components.append(ProjectComponent(directory: path, relativePath: relative,
                                                   scripts: scripts, hasPython: hasPython,
                                                   hasWeChat: hasWeChat))
            }

            guard depth < maxDepth else { return }
            let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                        options: [.skipsHiddenFiles])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if ignored.contains(child.lastPathComponent) { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true && values?.isSymbolicLink != true { walk(child, depth: depth + 1) }
            }
        }
        walk(base, depth: 0)
        return ProjectScan(components: components.sorted { $0.relativePath < $1.relativePath },
                           interpreters: interpreters.sorted())
    }

    static func preferredPython(for directory: String, root: String, interpreters: [String]) -> String? {
        let path = URL(fileURLWithPath: directory).standardizedFileURL.path
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        let ancestors = interpreters.filter { interpreter in
            let venvParent = URL(fileURLWithPath: interpreter).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().path
            return path == venvParent || path.hasPrefix(venvParent + "/")
        }
        if let nearest = ancestors.max(by: { $0.count < $1.count }) { return nearest }
        if interpreters.count == 1 { return interpreters[0] }
        // A root-level virtual environment is usable for every child project.
        return interpreters.first { $0.hasPrefix(rootPath + "/.venv/") || $0.hasPrefix(rootPath + "/venv/") }
    }

    static func executable(_ name: String) -> String? {
        let fm = FileManager.default
        let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let user = NSHomeDirectory()
        let candidates = Paths.searchPaths + environmentPaths + [
            user + "/.volta/bin", user + "/.local/share/mise/shims", user + "/.asdf/shims",
            user + "/.local/bin"
        ]
        for dir in candidates {
            let path = dir + "/" + name
            if fm.isExecutableFile(atPath: path) { return path }
        }
        if name == "npm" {
            let versions = user + "/.nvm/versions/node"
            let entries = (try? fm.contentsOfDirectory(atPath: versions)) ?? []
            for entry in entries.sorted().reversed() {
                let path = versions + "/" + entry + "/bin/npm"
                if fm.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }
}

struct ProjectRunState {
    var running = false
    var output = ""
    var exitCode: Int32?
    var message = ""
}

private struct ProjectCatalog: Codable {
    var roots: [String]
    var webURLs: [String: String]
    var pythonOverrides: [String: String]
    var collapsedRoots: Set<String>

    init(roots: [String], webURLs: [String: String], pythonOverrides: [String: String],
         collapsedRoots: Set<String>) {
        self.roots = roots
        self.webURLs = webURLs
        self.pythonOverrides = pythonOverrides
        self.collapsedRoots = collapsedRoots
    }

    private enum CodingKeys: String, CodingKey { case roots, webURLs, pythonOverrides, collapsedRoots }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        roots = try values.decodeIfPresent([String].self, forKey: .roots) ?? []
        webURLs = try values.decodeIfPresent([String: String].self, forKey: .webURLs) ?? [:]
        pythonOverrides = try values.decodeIfPresent([String: String].self, forKey: .pythonOverrides) ?? [:]
        collapsedRoots = try values.decodeIfPresent(Set<String>.self, forKey: .collapsedRoots) ?? []
    }
}

@MainActor
final class ProjectRunner: ObservableObject {
    @Published private(set) var roots: [String] = []
    @Published private(set) var scans: [String: ProjectScan] = [:]
    @Published private(set) var scanningRoots: Set<String> = []
    @Published private(set) var scanErrors: [String: String] = [:]
    @Published private(set) var runs: [String: ProjectRunState] = [:]
    @Published var pythonScripts: [String: String] = [:]
    @Published var pythonArguments: [String: String] = [:]
    @Published private(set) var pythonOverrides: [String: String] = [:]
    @Published private(set) var collapsedRoots: Set<String> = []
    @Published private(set) var webURLs: [String: String] = [:]
    @Published var error = ""
    @Published var notice = ""

    private var processes: [String: Process] = [:]
    private var pipes: [String: Pipe] = [:]
    private var processGroups: Set<String> = []
    private var runDirectories: [String: String] = [:]
    private var runExecutables: [String: String] = [:]
    private var scanGenerations: [String: Int] = [:]
    private let catalogURL: URL

    init(catalogURL: URL? = nil) {
        self.catalogURL = catalogURL ?? Paths.appSupport.appendingPathComponent("projects.json")
        if let data = try? Data(contentsOf: self.catalogURL) {
            if let catalog = try? JSONDecoder().decode(ProjectCatalog.self, from: data) {
                roots = catalog.roots
                webURLs = catalog.webURLs
                pythonOverrides = catalog.pythonOverrides
                collapsedRoots = catalog.collapsedRoots
            } else if let paths = try? JSONDecoder().decode([String].self, from: data) {
                roots = paths
            }
        }
        refreshAll()
    }

    func add(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard FileTools.isDirectory(normalized) else { error = "目录不存在：\(normalized)"; return }
        if !roots.contains(normalized) { roots.append(normalized) }
        collapsedRoots.remove(normalized)
        save()
        refresh(normalized)
    }

    func remove(_ root: String) {
        guard roots.contains(root) else { return }
        guard !hasRunning(in: root) else { error = "请先停止这个工程正在运行的命令"; return }
        roots.removeAll { $0 == root }
        collapsedRoots.remove(root)
        scans[root] = nil
        scanErrors[root] = nil
        scanningRoots.remove(root)
        scanGenerations[root] = (scanGenerations[root] ?? 0) + 1
        save()
    }

    private func save() {
        let catalog = ProjectCatalog(roots: roots, webURLs: webURLs,
                                     pythonOverrides: pythonOverrides, collapsedRoots: collapsedRoots)
        if let data = try? JSONEncoder().encode(catalog) { try? data.write(to: catalogURL, options: .atomic) }
    }

    func refreshAll() {
        for root in roots { refresh(root) }
    }

    func refresh(_ root: String) {
        guard roots.contains(root) else { return }
        let generation = (scanGenerations[root] ?? 0) + 1
        scanGenerations[root] = generation
        scanErrors[root] = nil
        guard FileTools.isDirectory(root) else {
            scanErrors[root] = "目录不存在：\(root)"
            scanningRoots.remove(root)
            scans[root] = nil
            return
        }
        scanningRoots.insert(root)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ProjectDiscovery.scan(root: root)
            DispatchQueue.main.async {
                guard self.roots.contains(root), self.scanGenerations[root] == generation else { return }
                self.scans[root] = result
                self.scanningRoots.remove(root)
            }
        }
    }

    func hasRunning(in root: String) -> Bool {
        runDirectories.values.contains { $0 == root || $0.hasPrefix(root + "/") }
    }

    func isUsingInterpreter(_ path: String) -> Bool {
        runExecutables.values.contains(path)
    }

    func npmID(_ component: ProjectComponent, _ script: String) -> String { "npm|\(component.directory)|\(script)" }
    func pythonID(_ component: ProjectComponent) -> String { "python|\(component.directory)" }

    func setWebURL(_ value: String, for directory: String) {
        webURLs[directory] = value
        save()
    }

    func setPythonOverride(_ path: String?, for directory: String) {
        if let path, !path.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: path) else {
                error = "不是可执行的 Python 解释器：\(path)"
                return
            }
            pythonOverrides[directory] = path
        } else {
            pythonOverrides[directory] = nil
        }
        error = ""
        save()
    }

    func toggleCollapsed(_ root: String) {
        guard roots.contains(root) else { return }
        if collapsedRoots.contains(root) { collapsedRoots.remove(root) }
        else { collapsedRoots.insert(root) }
        save()
    }

    func websiteURL(for component: ProjectComponent) -> URL? {
        if let manual = webURLs[component.directory], !manual.trimmingCharacters(in: .whitespaces).isEmpty {
            return Self.validWebsiteURL(manual)
        }
        for script in component.scripts {
            let id = npmID(component, script)
            guard let run = runs[id], run.running else { continue }
            let output = run.output
            if let url = Self.localURL(in: output) { return url }
        }
        return nil
    }

    nonisolated static func validWebsiteURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    nonisolated static func localURL(in output: String) -> URL? {
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?(?:/[^\s"'<>]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
        return matches.reversed().compactMap { validWebsiteURL(ns.substring(with: $0.range)) }.first
    }

    func openWebsite(_ component: ProjectComponent) {
        guard let url = websiteURL(for: component) else {
            error = "先运行开发服务器，或填写完整的网址（如 http://localhost:3000）"
            return
        }
        if !NSWorkspace.shared.open(url) { error = "无法打开网页：\(url.absoluteString)" }
    }

    static func weChatCLI() -> String? {
        let fm = FileManager.default
        let apps = ["/Applications/wechatwebdevtools.app", "/Applications/微信开发者工具.app",
                    NSHomeDirectory() + "/Applications/wechatwebdevtools.app"]
        for app in apps {
            let cli = app + "/Contents/MacOS/cli"
            if fm.isExecutableFile(atPath: cli) { return cli }
        }
        return nil
    }

    func openWeChat(_ component: ProjectComponent) {
        guard component.hasWeChat else { error = "这个目录没有 project.config.json"; return }
        guard let projectDirectory = ProjectDiscovery.weChatProjectDirectory(in: component.directory) else {
            error = "还没有生成小程序目录，请先运行 dev:mp-weixin 或 build:mp-weixin"
            return
        }
        guard let cli = Self.weChatCLI() else { error = "找不到微信开发者工具，请先安装"; return }
        notice = "正在打开微信开发者工具…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Shell.run([cli, "open", "--project", projectDirectory], timeout: 45)
            DispatchQueue.main.async {
                if result.ok {
                    self.notice = "已在微信开发者工具中打开 \(component.relativePath)"
                    self.error = ""
                } else {
                    self.notice = ""
                    self.error = "微信开发者工具打开失败：\(result.message)"
                }
            }
        }
    }

    func startNPM(_ component: ProjectComponent, script: String) {
        guard component.scripts.contains(script) else { error = "脚本已不存在，请重新扫描"; return }
        guard let npm = ProjectDiscovery.executable("npm") else { error = "找不到 npm，请先安装 Node.js，或将 npm 加入 PATH"; return }
        launch(id: npmID(component, script), executable: npm, arguments: ["run", script], cwd: component.directory)
    }

    func startPython(_ component: ProjectComponent, in root: String) {
        let script = (pythonScripts[component.directory] ?? "main.py").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { error = "请填写 Python 入口文件"; return }
        let scriptURL = URL(fileURLWithPath: script, relativeTo: URL(fileURLWithPath: component.directory + "/"))
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { error = "找不到入口文件：\(script)"; return }
        let preferred = ProjectDiscovery.preferredPython(for: component.directory, root: root,
                                                          interpreters: scans[root]?.interpreters ?? [])
        let python = pythonOverrides[component.directory] ?? preferred ?? ProjectDiscovery.executable("python3")
        guard let python, FileManager.default.isExecutableFile(atPath: python) else {
            error = "找不到可用的 Python，请为这个子工程选择虚拟环境"; return
        }
        let rawArguments = pythonArguments[component.directory] ?? ""
        guard let args = Self.parseArguments(rawArguments) else { error = "Python 参数的引号没有闭合"; return }
        launch(id: pythonID(component), executable: python,
               arguments: [scriptURL.path] + args, cwd: component.directory)
    }

    private func launch(id: String, executable: String, arguments: [String], cwd: String) {
        guard processes[id] == nil else { error = "这条命令已在运行"; return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        let binDir = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        environment["PATH"] = ([binDir] + Paths.searchPaths + (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let text = String(decoding: chunk, as: UTF8.self)
            DispatchQueue.main.async { self?.append(text, to: id) }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.finished(id: id, code: ended.terminationStatus) }
        }
        do {
            try process.run()
            // A separate process group lets Stop terminate npm and the server it spawned.
            if setpgid(process.processIdentifier, process.processIdentifier) == 0 { processGroups.insert(id) }
            processes[id] = process
            pipes[id] = pipe
            runDirectories[id] = cwd
            runExecutables[id] = executable
            runs[id] = ProjectRunState(running: true, output: "", exitCode: nil,
                                       message: "PID \(process.processIdentifier) · \(executable) \(arguments.joined(separator: " "))")
            error = ""
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            self.error = "启动失败：\(error.localizedDescription)"
        }
    }

    private func append(_ text: String, to id: String) {
        guard var state = runs[id] else { return }
        state.output += text
        if state.output.count > 100_000 { state.output = String(state.output.suffix(100_000)) }
        runs[id] = state
    }

    private func finished(id: String, code: Int32) {
        pipes[id]?.fileHandleForReading.readabilityHandler = nil
        pipes[id] = nil
        processes[id] = nil
        runDirectories[id] = nil
        runExecutables[id] = nil
        processGroups.remove(id)
        guard var state = runs[id] else { return }
        state.running = false
        state.exitCode = code
        state.message = code == 0 ? "已结束" : "已退出（代码 \(code)）"
        runs[id] = state
    }

    func stop(_ id: String) {
        guard let process = processes[id], process.isRunning else { return }
        if processGroups.contains(id) {
            _ = kill(-process.processIdentifier, SIGTERM)
        } else {
            // setpgid can race with exec. Stop children first when a group was not created.
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

    func stopAll() {
        for id in Array(processes.keys) { stop(id) }
    }

    static func parseArguments(_ input: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var started = false
        for ch in input {
            if escaped { current.append(ch); escaped = false; started = true; continue }
            if ch == "\\" && quote != "'" { escaped = true; started = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch; started = true
            } else if ch.isWhitespace {
                if started { words.append(current); current = ""; started = false }
            } else { current.append(ch); started = true }
        }
        guard quote == nil && !escaped else { return nil }
        if started { words.append(current) }
        return words
    }
}
