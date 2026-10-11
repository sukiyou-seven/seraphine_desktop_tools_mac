import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 两态的底部圆角；展开面板留出屏幕边距时，顶部也使用圆角。
private let dockletCollapsedRadius: CGFloat = 14
private let dockletExpandedRadius: CGFloat = 26

// MARK: - 形状

/// 「刘海」形状：贴着屏幕上沿时顶部直角；留出间隙时顶部也可圆润。
/// 折叠时是一个小胶囊，展开时同一形状拉成一块大板子，视觉上像是从刘海下拉出来的。
struct NotchShape: Shape {
    var bottomRadius: CGFloat = 12
    var topRadius: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bottom = min(bottomRadius, rect.width / 2, rect.height / 2)
        let top = min(topRadius, rect.width / 2, rect.height / 2)

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + top))
        if top > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.minX + top, y: rect.minY),
                        radius: top)
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        if top > 0 {
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.maxX, y: rect.minY + top),
                        radius: top)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
                    radius: bottom)
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottom),
                    radius: bottom)
        path.closeSubpath()
        return path
    }
}

// MARK: - 图标缓存

/// 应用图标取一次就缓存住 —— `NSWorkspace.icon(forFile:)` 每次都要碰磁盘，网格滚动时会很明显。
@MainActor
enum DockletIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }

    static func forget(_ path: String) {
        cache[path] = nil
    }
}

// MARK: - 主视图

/// 顶部小组件的内容：平时是一个刘海胶囊，悬停后展开成「左图标 + 右快捷功能」的大盒子。
struct DockletView: View {
    @ObservedObject var docklet: DockletController
    @EnvironmentObject private var model: AppModel

    private var appPaths: [String] { model.settings.docklet.appPaths }
    private var collapsedOpacity: Double { model.settings.docklet.collapsedOpacity }
    private var expandedOpacity: Double { model.settings.docklet.expandedOpacity }
    private var expandedShape: NotchShape {
        let settings = model.settings.docklet
        let screenWidth = Double(NSScreen.screens.first?.frame.width ?? 1440)
        let hasGap = settings.expandedTopGap > 0 || settings.expandedSideGap(for: screenWidth) > 0
        return NotchShape(bottomRadius: dockletExpandedRadius,
                          topRadius: hasGap ? dockletExpandedRadius : 0)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { docklet.hover($0) }
            // 尺寸调整即时更新窗口；内容由新的实际尺寸自动重排。
            .onChange(of: model.settings.docklet.expandedWidthRatio) { _ in docklet.relayout() }
            .onChange(of: model.settings.docklet.expandedHeight) { _ in docklet.relayout() }
            .onChange(of: model.settings.docklet.collapsedWidth) { _ in docklet.relayout() }
            .onChange(of: model.settings.docklet.collapsedHeight) { _ in docklet.relayout() }
            .onChange(of: model.settings.docklet.expandedTopGap) { _ in docklet.relayout() }
    }

    @ViewBuilder
    private var content: some View {
        if docklet.expanded {
            expandedCard
        } else {
            collapsedNotch
        }
    }

    // MARK: 折叠态

    /// 平时露出来的那一小块：底部两角圆润，像屏幕自带的刘海。
    /// 整块（含描边）跟着设置里的不透明度走 —— 这一条本来就是色块，没有内容要保住。
    private var collapsedNotch: some View {
        ZStack {
            collapsedBackdrop
            NotchShape(bottomRadius: dockletCollapsedRadius)
                .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
        }
        .contentShape(NotchShape(bottomRadius: dockletCollapsedRadius))
        .onTapGesture { docklet.expandNow() }
        .opacity(collapsedOpacity)
    }

    // MARK: 展开态

    private var expandedCard: some View {
        GeometryReader { geo in
            ZStack {
                expandedBackdrop
                HStack(spacing: 0) {
                    // 两栏宽度使用设置页同一套约束，避免窄面板把右栏挤没。
                    appColumn
                        .frame(width: model.settings.docklet.columnWidths(totalWidth: geo.size.width).left)
                    Divider().overlay(Color.white.opacity(0.10))
                    shortcutColumn
                        .frame(width: model.settings.docklet.columnWidths(totalWidth: geo.size.width).right)
                }
                // 内容单独裁一刀，免得滚动区的内容顶出圆角；底板自己带形状。
                .clipShape(expandedShape)
            }
            .overlay(expandedShape
                .stroke(Color.white.opacity(0.09), lineWidth: 1))
        }
    }

    // MARK: 底板（液态玻璃）

    /// 折叠态底板：macOS 26 起用系统的「液态玻璃」（Liquid Glass），更早的系统上还是原来的纯黑。
    /// 形状两态都是 `NotchShape`，所以玻璃也照着这个轮廓裁。
    @ViewBuilder
    private var collapsedBackdrop: some View {
        if #available(macOS 26.0, *), model.settings.docklet.collapsedLiquidGlassEnabled {
            Color.clear
                .glassEffect(.regular.tint(Color.black.opacity(0.72)),
                             in: NotchShape(bottomRadius: dockletCollapsedRadius))
        } else {
            NotchShape(bottomRadius: dockletCollapsedRadius)
                .fill(Color.black)
        }
    }

    /// 展开态底板：同样优先液态玻璃，玻璃上压一层很淡的深色渐变保证白字读得清；
    /// macOS 26 以下退回原来的深色渐变。
    /// 只有底板跟着「展开态不透明度」走，图标和文字始终清晰。
    @ViewBuilder
    private var expandedBackdrop: some View {
        let shape = expandedShape
        ZStack {
            if #available(macOS 26.0, *), model.settings.docklet.expandedLiquidGlassEnabled {
                Color.clear.glassEffect(.regular.tint(Color(white: 0.05).opacity(0.62)), in: shape)
            } else {
                LinearGradient(colors: [Color(white: 0.10), Color(white: 0.035)],
                               startPoint: .top, endPoint: .bottom)
                    .clipShape(shape)
            }
            // 玻璃在浅色桌面上偏亮，垫一层薄渐变，白字才稳。
            LinearGradient(colors: [Color.black.opacity(0.18), Color.black.opacity(0.34)],
                           startPoint: .top, endPoint: .bottom)
                .clipShape(shape)
        }
        .opacity(expandedOpacity)
    }

    // MARK: 左：用户添加的应用图标

    private var appColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("应用")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                if !appPaths.isEmpty {
                    Text("\(appPaths.count) 个")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 2)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 78, maximum: 112), spacing: 8)],
                          alignment: .leading, spacing: 12) {
                    ForEach(appPaths, id: \.self) { path in
                        appTile(path)
                    }
                    addTile
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func appTile(_ path: String) -> some View {
        DockletAppTile(
            path: path,
            onOpen: { open(path) },
            onRemove: {
                model.removeDockletApp(path)
                DockletIconCache.forget(path)
            }
        )
    }

    /// 网格末尾的「＋」：挑选 .app 加进来。
    private var addTile: some View {
        Button(action: pickApps) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.white.opacity(0.28),
                                          style: StrokeStyle(lineWidth: 1.3, dash: [4, 3]))
                    )
                Text("添加应用")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("从「应用程序」里选一个 .app 放到这里")
    }

    // MARK: 右：快捷功能

    private var shortcutColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷功能")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 4)

            DockletShortcutTile(title: "截图", systemImage: "camera.viewfinder") {
                docklet.captureScreenshot()
            }

            Spacer(minLength: 0)

            if let notice = docklet.notice {
                Text(verbatim: notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .onTapGesture { docklet.clearNotice() }
            }

            Text("移开鼠标即可收起")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.25))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 动作

    private func open(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            docklet.showNotice("应用已不在原位：\(path)")
            return
        }
        // 点完就收起，把桌面让出来。
        docklet.collapseNow()
        if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
            docklet.showNotice("打不开 \(URL(fileURLWithPath: path).lastPathComponent)")
        }
    }

    private func pickApps() {
        let panel = NSOpenPanel()
        panel.message = "选择要放进顶部小组件的应用"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let selected = docklet.withPanelHiddenDuringModal {
            NSApp.activate(ignoringOtherApps: true)
            return panel.runModal() == .OK ? panel.urls : []
        }
        model.addDockletApps(selected.map(\.path))
    }
}

// MARK: - 单个应用图标

private struct DockletAppTile: View {
    let path: String
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    private var url: URL { URL(fileURLWithPath: path) }
    private var name: String { url.deletingPathExtension().lastPathComponent }
    private var missing: Bool { !FileManager.default.fileExists(atPath: path) }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 6) {
                Image(nsImage: DockletIconCache.icon(for: path))
                    .resizable()
                    .frame(width: 48, height: 48)
                    .opacity(missing ? 0.35 : 1)
                Text(verbatim: name)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(missing ? 0.45 : 0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(hovering ? 0.12 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("从小组件里移除（不会卸载应用）")
                .offset(x: 3, y: -3)
            }
        }
        .contextMenu {
            Button("打开") { onOpen() }
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button("在小组件中移除", role: .destructive) { onRemove() }
        }
        .help(missing ? "应用已移走：\(path)" : path)
    }
}

// MARK: - 右侧快捷功能按钮

private struct DockletShortcutTile: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(hovering ? 0.14 : 0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("用系统截图工具框选区域")
    }
}
