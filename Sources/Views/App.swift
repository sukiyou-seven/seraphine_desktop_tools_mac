import SwiftUI

@main
struct DBManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DBManager — MongoDB / Redis 本地管理") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 680)
        }
        // 固定初始尺寸，并且只按「内容最小尺寸」约束窗口；
        // 否则内容一长（比如设置页那种长表单），macOS 会把窗口撑到屏幕外，连侧边栏都被顶出去。
        .defaultSize(width: 1360, height: 1120)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("刷新状态") {
                    model.refreshAll()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Diag.install()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 记录窗口是否真的显示出来，方便诊断“双击后什么都没有”这类问题。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let windows = NSApp.windows
            let visible = windows.filter { $0.isVisible }.count
            Diag.log("窗口自检：共 \(windows.count) 个，可见 \(visible) 个，激活策略 \(NSApp.activationPolicy().rawValue)")
            if visible == 0, let window = windows.first {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                Diag.log("没有可见窗口，已主动前置")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Diag.noteExit("applicationWillTerminate")
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.tab) {
                Section("数据库") {
                    Label("MongoDB", systemImage: "leaf.fill")
                        .tag("mongo")
                    Label("MySQL", systemImage: "cylinder.split.1x2.fill")
                        .tag("mysql")
                    Label("Redis", systemImage: "bolt.fill")
                        .tag("redis")
                }
                Section("工具") {
                    Label("证书", systemImage: "lock.shield.fill")
                        .tag("certificate")
                    Label("宝塔面板", systemImage: "server.rack")
                        .tag("btpanel")
                    Label("网络代理", systemImage: "globe")
                        .tag("vpn")
                }
                Section {
                    Label("设置", systemImage: "gearshape.fill")
                        .tag("settings")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            ZStack(alignment: .top) {
                Group {
                    switch model.tab {
                    case "certificate":
                        CertificateView()
                    case "btpanel":
                        BTPanelView()
                    case "vpn":
                        VPNView()
                    case "mysql":
                        MySQLView()
                    case "redis":
                        RedisView()
                    case "settings":
                        SettingsView()
                    default:
                        MongoView()
                    }
                }
                if let toast = model.toast {
                    ToastBanner(toast: toast) {
                        model.toast = nil
                    }
                }
            }
            // detail 区域始终占满可用空间，不让页面内容左右窗口尺寸
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .status) {
                    if let busy = model.busy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(verbatim: busy).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.refreshAll()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }
}
