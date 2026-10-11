import SwiftUI

@main
struct SeraphimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    /// WindowGroup 的 id。顶部小组件里的「打开 Seraphim 窗口」靠它把主窗口叫回来。
    static let mainWindowID = "main"

    var body: some Scene {
        WindowGroup("Seraphim", id: SeraphimApp.mainWindowID) {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 680)
                .onAppear {
                    // 屏幕顶部那块「刘海」小组件：跟着主窗口一起露面。
                    delegate.model = model
                    model.docklet.syncEnabled(model: model)
                    // 「打开软件后自动启动」：按设置里的勾选把 MongoDB / Redis 拉起来（只跑一次）。
                    model.autoStartServicesIfNeeded()
                    // 首次用到时请求一次系统通知权限
                    SystemNotice.requestAuthorizationIfNeeded()
                }
                .onChange(of: model.settings.docklet.enabled) { _ in
                    // 小组件页的开关和菜单栏图标改的都是这个字段，这里统一收口。
                    model.docklet.syncEnabled(model: model)
                }
        }
        // 固定初始尺寸，并且只按「内容最小尺寸」约束窗口；
        // 否则内容一长（比如设置页那种长表单），macOS 会把窗口撑到屏幕外，连侧边栏都被顶出去。
        .defaultSize(width: 1360, height: 1120)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("刷新状态") {
                    if model.tab == "server-management" {
                        NotificationCenter.default.post(name: .serverManagementRefresh, object: nil)
                    } else {
                        model.refreshAll()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 由 ContentView 在出现时设进来。只用于「关掉主窗口到底要不要退出」这一个判断。
    weak var model: AppModel?

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
        // 顶部小组件还挂在屏幕上时，关掉主窗口不等于要退出 ——
        // 用户可以从菜单栏图标里把窗口叫回来，或者直接选「退出 Seraphim」。
        MainActor.assumeIsolated { model?.docklet.isShowing != true }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Diag.noteExit("applicationWillTerminate")
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    /// 顶部小组件里的「打开 Seraphim 窗口」会把主窗口叫回来（见 Docklet.swift）。
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(selection: $model.tab) {
                Section("本地环境管理") {
                    Label("MongoDB", systemImage: "leaf.fill")
                        .tag("mongo")
                    Label("MySQL", systemImage: "cylinder.split.1x2.fill")
                        .tag("mysql")
                    Label("Redis", systemImage: "bolt.fill")
                        .tag("redis")
                    Label("Python 环境", systemImage: "terminal.fill")
                        .tag("python-environments")
                }
                Section("项目管理") {
                    Label("项目管理", systemImage: "folder.fill")
                        .tag("projects")
                }
                Section("服务器管理") {
                    Label("服务器管理", systemImage: "server.rack")
                        .tag("server-management")
                }
                Section("AI") {
                    // 只留「云端任务」这一个入口。
                    // 「AI 开发」（本机看门狗 + 验收 + 审查 + 修复队列）是"在本机模拟云端"的复杂路子，
                    // 先收起来：源码都还在（AIDevView.swift / AIDevService.swift / AIReviewService.swift），
                    // 想恢复就把下面这行放开、并去掉上面那行的注释即可。
                    // Label("AI 开发", systemImage: "sparkles").tag("aidev")
                    Label("云端任务", systemImage: "cloud.fill")
                        .tag("aicloud")
                }
                Section("其他") {
                    Label("剪贴板", systemImage: "doc.on.clipboard")
                        .tag("clipboard")
                    Label("清理", systemImage: "trash")
                        .tag("cleanup")
                    Label("快捷启动", systemImage: "square.stack.3d.up.fill")
                        .tag("quick-launch")
                }
                Section {
                    Label("设置", systemImage: "gearshape.fill")
                        .tag("settings")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            ZStack(alignment: .topTrailing) {
                Group {
                    switch model.tab {
                    case "server-management":
                        ServerManagementView()
                    case "projects":
                        ProjectsView(runner: model.projectRunner, environments: model.pythonEnvironments)
                    case "python-environments":
                        PythonEnvironmentView(manager: model.pythonEnvironments, projects: model.projectRunner)
                    case "cleanup":
                        HomeCleanupView()
                    case "clipboard":
                        ClipboardView()
                    case "quick-launch":
                        QuickLaunchView()
                    case "docklet-settings":
                        DockletSettingsView()
                    case "aidev":
                        AIDevView()
                    case "aicloud":
                        AICloudView()
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
                    // 提示挪到**右上角**（原来在顶部中间）
                    .padding(.top, 6)
                    .padding(.trailing, 10)
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
                        if model.tab == "server-management" {
                            NotificationCenter.default.post(name: .serverManagementRefresh, object: nil)
                        } else {
                            model.refreshAll()
                        }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dockletOpenMainWindow)) { _ in
            openWindow(id: SeraphimApp.mainWindowID)
        }
    }
}
