import Foundation
import UserNotifications

/// 系统级通知（右上角横幅）。
///
/// 只做「锦上添花」：没授权、系统不支持、或者当前根本不在 App bundle 里跑
/// （比如无 GUI 的自测程序），都静默跳过 —— 界面里的 toast 照常显示。
enum SystemNotice {
    private static var didRequestAuthorization = false

    /// 首次用到时请求一次通知权限（用户拒绝也不影响其它功能）。
    static func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization, isAvailable else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 发一条通知。`identifier` 用随机值，不做合并。
    static func post(title: String, body: String) {
        guard isAvailable, !body.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 只有在真正的 App bundle 里才可用 —— 命令行自测程序没有 bundle，调了会崩。
    private static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }
}
