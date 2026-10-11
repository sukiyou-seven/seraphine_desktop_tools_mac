import Foundation

struct HomeLogCandidate: Identifiable {
    let url: URL
    let size: Int
    let modified: Date
    let source: String

    var id: String { url.path }
}

enum HomeLogCleanup {
    /// 只检查家目录顶层、至少一天未修改的普通 .log 文件。内容必须能识别为开发临时输出。
    static func scan(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                     now: Date = Date()) -> [HomeLogCandidate] {
        let files = (try? FileManager.default.contentsOfDirectory(at: home,
                       includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                     .fileSizeKey, .contentModificationDateKey],
                       options: [])) ?? []
        return files.compactMap { inspect($0, home: home, now: now) }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    static func inspect(_ url: URL, home: URL, now: Date = Date()) -> HomeLogCandidate? {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent == home.standardizedFileURL, url.pathExtension.lowercased() == "log" else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                             .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, let modified = values.contentModificationDate,
              now.timeIntervalSince(modified) >= 24 * 3600 else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let prefix = String(decoding: handle.readData(ofLength: 8192), as: UTF8.self)
        try? handle.close()
        guard let source = classify(name: url.lastPathComponent, prefix: prefix) else { return nil }
        return HomeLogCandidate(url: url, size: size, modified: modified, source: source)
    }

    private static func classify(name: String, prefix: String) -> String? {
        if prefix.hasPrefix("Command line invocation:\n"),
           prefix.contains("/xcodebuild "), prefix.contains(".xcodeproj"),
           prefix.contains(" -scheme ") {
            return "Xcode 构建输出"
        }
        if name.hasPrefix("_"), name.hasSuffix("_install.log"),
           prefix.contains("CoreDeviceError") || prefix.contains("App installed:") {
            return "Xcode 设备安装输出"
        }
        if name.hasPrefix("_"), name.hasSuffix("_launch.log"),
           prefix.contains("CoreDeviceError") || prefix.contains("Launched application with") {
            return "Xcode 设备启动输出"
        }
        if name == "_dd_clean.log", prefix.hasPrefix("start\n"),
           prefix.contains("DerivedData") {
            return "Xcode DerivedData 检查输出"
        }
        return nil
    }

    /// 点击清理时重新识别并核对大小、修改时间；有变化就跳过，避免收走正在写的日志。
    static func moveToTrash(_ candidates: [HomeLogCandidate],
                            home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> (moved: Int, skipped: Int) {
        var moved = 0
        var skipped = 0
        for candidate in candidates {
            guard let current = inspect(candidate.url, home: home),
                  current.size == candidate.size, current.modified == candidate.modified,
                  current.source == candidate.source else {
                skipped += 1
                continue
            }
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: candidate.url, resultingItemURL: &trashed)
                moved += 1
            } catch {
                skipped += 1
            }
        }
        return (moved, skipped)
    }
}
