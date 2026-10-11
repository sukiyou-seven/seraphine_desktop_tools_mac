import AppKit
import SwiftUI
import QuartzCore

/// 顶部小组件的窗口：无边框、不抢焦点、浮在菜单栏之上。
final class DockletPanel: NSPanel {
    /// 需要成为 key 才能让 SwiftUI 的按钮正常拿到点击；
    /// `.nonactivatingPanel` 保证这不会顺带把整个 app 激活、抢走别的窗口焦点。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 请求把主窗口找回来（面板在、主窗口被关掉时用）。
extension Notification.Name {
    static let dockletOpenMainWindow = Notification.Name("DBManager.openMainWindow")
}

/// 屏幕顶部那块「刘海」小组件的窗口管理：显隐、折叠 / 展开、鼠标悬停、菜单栏开关。
///
/// 只负责窗口本身和展开状态；界面在 `DockletView` 里，配置在 `DockletSettings`。
/// 所有入口都假定在主线程调用（AppKit / SwiftUI 的常规约定）。
@MainActor
final class DockletController: NSObject, ObservableObject {

    /// 面板是否已展开成「大盒子」。
    @Published private(set) var expanded = false
    /// 底部提示（截图失败之类），nil 表示不显示。
    @Published private(set) var notice: String?

    // MARK: 尺寸与时长

    private let expandDuration: TimeInterval = 0.26
    private let collapseDuration: TimeInterval = 0.20
    /// 鼠标移出后等这么久再收，避免只是贴着边划过就炸开。
    private let collapseDelay: TimeInterval = 0.30

    // MARK: 内部状态

    private weak var model: AppModel?
    private var panel: DockletPanel?
    private var statusItem: NSStatusItem?
    private var collapseWork: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    /// 截图等外部动作进行中：此时不响应悬停，免得面板冒出来挡住操作。
    private var suppressHover = false
    /// 收起时鼠标若还在胶囊上，等它实际离开后再接受下一次进入。
    private var needsPointerExitToReopen = false

    // MARK: 生命周期

    /// 显式声明，让它跟着类一起是 `@MainActor`；单纯继承 NSObject 的 init 会漏掉隔离标注。
    override init() {
        super.init()
    }

    /// 按设置里的开关显示或隐藏小组件。顺带把主模型记下来（这里只弱引用，强引用在 SwiftUI 那边）。
    func syncEnabled(model: AppModel) {
        self.model = model
        if model.settings.docklet.enabled {
            show()
        } else {
            hide()
        }
    }

    /// 小组件此刻是否真的挂在屏幕上。
    var isShowing: Bool { panel?.isVisible == true }

    private func show() {
        guard let model else { return }
        if panel == nil { buildPanel(model: model) }
        guard let panel else { return }
        cancelPendingCollapse()
        expanded = false
        needsPointerExitToReopen = false
        notice = nil
        panel.setFrame(targetFrame(expanded: false) ?? panel.frame, display: true)
        panel.orderFrontRegardless()
        installStatusItem()
        Diag.log("顶部小组件：已显示，屏幕 \(dockletScreen?.frame.debugDescription ?? "未知")")
    }

    private func hide() {
        cancelPendingCollapse()
        expanded = false
        needsPointerExitToReopen = false
        panel?.orderOut(nil)
        removeStatusItem()
        notice = nil
        Diag.log("顶部小组件：已隐藏")
    }

    private func buildPanel(model: AppModel) {
        guard let frame = targetFrame(expanded: false) else {
            Diag.log("顶部小组件：拿不到屏幕信息，放弃创建面板")
            return
        }
        let panel = DockletPanel(contentRect: frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 阴影交给 SwiftUI 画：无边框窗口自带的阴影是方的，跟圆角对不上。
        panel.hasShadow = false
        // 压住菜单栏（状态栏那层是 25），同时跟着切 space、盖在全屏应用上。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: DockletView(docklet: self).environmentObject(model))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.relayout() }
            }
    }

    // MARK: 位置

    /// 有菜单栏的那块屏（系统设置里的主显示器）。多屏时行为可预测，不会随焦点乱跳。
    private var dockletScreen: NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    /// 菜单栏高度。刘海屏上这个值会把刘海高度一起算进去。
    private func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let measured = screen.frame.maxY - screen.visibleFrame.maxY
        if measured > 0, measured < 80 { return measured }
        return NSStatusBar.system.thickness
    }

    /// 面板目标矩形：水平居中；展开时可以留出屏幕顶边间隙。
    private func targetFrame(expanded: Bool) -> NSRect? {
        guard let screen = dockletScreen else { return nil }
        let bounds = screen.frame
        let settings = model?.settings.docklet ?? DockletSettings()
        if expanded {
            let width = CGFloat(settings.expandedWidth(for: Double(bounds.width)))
            let topGap = min(CGFloat(settings.expandedTopGap), max(0, bounds.height - 240))
            let height = min(CGFloat(settings.expandedHeight),
                             (bounds.height * 0.85).rounded(), bounds.height - topGap)
            return NSRect(x: (bounds.midX - width / 2).rounded(),
                          y: bounds.maxY - topGap - height,
                          width: width,
                          height: height)
        }
        let height = min(bounds.height, settings.collapsedHeight == 0
                         ? menuBarHeight(of: screen) : CGFloat(settings.collapsedHeight))
        let collapsedWidth = min(bounds.width, CGFloat(settings.collapsedWidth)).rounded()
        return NSRect(x: (bounds.midX - collapsedWidth / 2).rounded(),
                      y: bounds.maxY - height,
                      width: collapsedWidth,
                      height: height)
    }

    /// 换屏或设置里改了展开尺寸后，按当前状态把窗口重新摆一次。
    /// 面板没显示时什么都不用做 —— 下次展开会用新值重新算。
    func relayout() {
        guard let panel, panel.isVisible else { return }
        cancelPendingCollapse()
        panel.setFrame(targetFrame(expanded: expanded) ?? panel.frame, display: true)
    }

    // MARK: 折叠 / 展开

    /// 鼠标进出面板。展开要立刻响应；收起要等一等再看看鼠标还在不在。
    func hover(_ inside: Bool) {
        guard model?.settings.docklet.enabled == true, !suppressHover else { return }
        if inside {
            cancelPendingCollapse()
            guard !expanded, !needsPointerExitToReopen else { return }
            guard targetFrame(expanded: false)?.contains(NSEvent.mouseLocation) == true else { return }
            setExpanded(true)
        } else {
            if targetFrame(expanded: false)?.contains(NSEvent.mouseLocation) != true {
                needsPointerExitToReopen = false
            }
            if expanded { scheduleCollapse() }
        }
    }

    /// 胶囊上的主动点击可以立即展开，即使鼠标尚未离开过胶囊。
    func expandNow() {
        guard model?.settings.docklet.enabled == true, !suppressHover else { return }
        needsPointerExitToReopen = false
        cancelPendingCollapse()
        setExpanded(true)
    }

    private func cancelPendingCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    private func scheduleCollapse() {
        cancelPendingCollapse()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            // onHover(false) 在窗口尺寸变化时也会冒出来，所以以鼠标真实位置为准。
            if panel.frame.contains(NSEvent.mouseLocation) {
                self.scheduleCollapse()
            } else {
                self.setExpanded(false)
            }
        }
        collapseWork = work
        let topGap = model?.settings.docklet.expandedTopGap ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + max(collapseDelay, topGap / 160), execute: work)
    }

    private func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        // 内容和窗口同步做动画，两边曲线一致，看起来才是「一个盒子在长大」。
        withAnimation(.easeOut(duration: value ? expandDuration : collapseDuration)) {
            expanded = value
        }
        if !value {
            needsPointerExitToReopen = targetFrame(expanded: false)?.contains(NSEvent.mouseLocation) == true
        }
        guard let panel, let target = targetFrame(expanded: value) else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = value ? expandDuration : collapseDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// 立刻收起（执行外部动作之前用，别让面板留在画面里）。
    func collapseNow() {
        cancelPendingCollapse()
        setExpanded(false)
    }

    /// 系统文件选择器的窗口层级低于顶部面板。选择期间隐藏面板，结束后恢复胶囊态。
    func withPanelHiddenDuringModal<T>(_ operation: () -> T) -> T {
        let wasVisible = panel?.isVisible == true
        suppressHover = true
        cancelPendingCollapse()
        if wasVisible { panel?.orderOut(nil) }
        defer {
            expanded = false
            needsPointerExitToReopen = targetFrame(expanded: false)?.contains(NSEvent.mouseLocation) == true
            if wasVisible, model?.settings.docklet.enabled == true, let panel {
                panel.setFrame(targetFrame(expanded: false) ?? panel.frame, display: true)
                panel.orderFrontRegardless()
            }
            suppressHover = false
        }
        return operation()
    }

    // MARK: 快捷功能

    /// 交互式选区截图。先把面板收起来，等动画走完再交给系统，免得把自己也截进去。
    func captureScreenshot() {
        suppressHover = true
        collapseNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDuration + 0.12) { [weak self] in
            guard let self else { return }
            let tool = "/usr/sbin/screencapture"
            guard FileManager.default.isExecutableFile(atPath: tool) else {
                self.suppressHover = false
                self.notice = "找不到系统截图工具 \(tool)"
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["-i"]
            process.terminationHandler = { [weak self] finished in
                let status = finished.terminationStatus
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.suppressHover = false
                        // rc 0 = 存了一张；非 0 基本都是按 Esc 取消，不算错误。
                        self.notice = status == 0 ? nil : "截图已取消"
                        Diag.log("顶部小组件：截图结束 rc=\(status)")
                    }
                }
            }
            do {
                try process.run()
                Diag.log("顶部小组件：已唤起 screencapture -i")
            } catch {
                self.suppressHover = false
                self.notice = "截图启动失败：\(error.localizedDescription)"
            }
        }
    }

    func clearNotice() {
        notice = nil
    }

    /// 显示一条底部提示（截图失败、应用被移走之类）。
    func showNotice(_ text: String) {
        notice = text
    }

    // MARK: 菜单栏图标

    /// 面板常驻在屏幕上，总得留个地方把它关掉 —— 用菜单栏图标兜底。
    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "顶部小组件")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "顶部小组件"
        }
        let menu = NSMenu()
        addItem(to: menu, title: "显示顶部小组件", action: #selector(toggleDocklet))
        addItem(to: menu, title: "小组件设置…", action: #selector(openDockletSettings))
        menu.addItem(.separator())
        addItem(to: menu, title: "打开 Seraphim 窗口", action: #selector(openMainWindow))
        addItem(to: menu, title: "退出 Seraphim", action: #selector(quitApp))
        item.menu = menu
        refreshStatusMenu()
        statusItem = item
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
    }

    private func refreshStatusMenu() {
        guard let menu = statusItem?.menu, let item = menu.item(at: 0) else { return }
        item.state = (model?.settings.docklet.enabled ?? false) ? .on : .off
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc private func toggleDocklet() {
        guard let model else { return }
        model.settings.docklet.enabled.toggle()
        SettingsStore.save(model.settings)
        syncEnabled(model: model)
        refreshStatusMenu()
    }

    @objc private func openDockletSettings() {
        model?.tab = "docklet-settings"
        openMainWindow()
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is DockletPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // 主窗口已经被关掉了，让 SwiftUI 重新开一个（见 App.swift 里的 openWindow）。
            NotificationCenter.default.post(name: .dockletOpenMainWindow, object: nil)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
