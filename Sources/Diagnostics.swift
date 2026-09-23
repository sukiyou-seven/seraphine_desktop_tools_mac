import Foundation
import Darwin

// 崩溃处理必须用「不捕获上下文」的顶层函数，才能作为 C 函数指针传给 signal / atexit。

private var dbmCrashFD: Int32 = -1

private func dbmWriteCrash(_ text: String) {
    guard dbmCrashFD >= 0 else { return }
    _ = text.withCString { pointer in
        write(dbmCrashFD, pointer, strlen(pointer))
    }
}

private func dbmExceptionHandler(_ exception: NSException) {
    let text = "未捕获异常 \(exception.name.rawValue): \(exception.reason ?? "无原因")\n"
        + exception.callStackSymbols.joined(separator: "\n") + "\n"
    dbmWriteCrash(text)
}

private func dbmSignalHandler(_ number: Int32) {
    dbmWriteCrash("\n!!! 崩溃：收到信号 \(number)（异常退出）\n")
    // 恢复默认处理并重新抛出，让系统照常生成崩溃报告
    signal(number, SIG_DFL)
    raise(number)
}

private func dbmAtExit() {
    dbmWriteCrash("--- 进程正常退出 ---\n")
}

/// 轻量诊断：运行日志 + 崩溃记录。
/// 出问题时看 `~/Library/Application Support/DBManager/log/run.log` 与 `crash.log`。
enum Diag {
    private static let queue = DispatchQueue(label: "dbmanager.diag")

    static var logURL: URL { Paths.logDir.appendingPathComponent("run.log") }
    static var crashURL: URL { Paths.logDir.appendingPathComponent("crash.log") }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    // MARK: 普通运行日志

    static func log(_ message: String) {
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        queue.async { append(logURL, line) }
    }

    /// 同步落盘，用于崩溃/退出前。
    static func logNow(_ message: String) {
        append(logURL, "[\(stamp.string(from: Date()))] \(message)\n")
    }

    private static func append(_ url: URL, _ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: 崩溃捕获

    static func install() {
        dbmCrashFD = open(crashURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        NSSetUncaughtExceptionHandler(dbmExceptionHandler)
        for number in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(number, dbmSignalHandler)
        }
        atexit(dbmAtExit)

        log("=== 启动 === macOS \(ProcessInfo.processInfo.operatingSystemVersionString)，"
            + "pid \(ProcessInfo.processInfo.processIdentifier)")
        log("数据目录：\(Paths.appSupport.path)")
    }

    static func noteExit(_ reason: String) {
        logNow("--- 退出请求：\(reason) ---")
    }
}
