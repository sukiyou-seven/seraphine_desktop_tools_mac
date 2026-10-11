import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DockletSettingsView: View {
    @EnvironmentObject private var model: AppModel

    private var screenWidth: Double { Double(NSScreen.screens.first?.frame.width ?? 1440) }
    private var screenHeight: Double { Double(NSScreen.screens.first?.frame.height ?? 900) }
    private var menuBarHeight: Double {
        guard let screen = NSScreen.screens.first else { return Double(NSStatusBar.system.thickness) }
        let measured = Double(screen.frame.maxY - screen.visibleFrame.maxY)
        return measured > 0 && measured < 80 ? measured : Double(NSStatusBar.system.thickness)
    }
    private var expandedWidth: Double {
        model.settings.docklet.expandedWidth(for: screenWidth)
    }
    private var expandedWidthRange: ClosedRange<Double> {
        min(screenWidth, max(320, screenWidth * DockletSettings.widthRatioRange.lowerBound))...screenWidth
    }
    private var expandedHeightRange: ClosedRange<Double> {
        let upper = min(DockletSettings.expandedHeightRange.upperBound,
                        (screenHeight * 0.85).rounded(), screenHeight - model.settings.docklet.expandedTopGap)
        return min(DockletSettings.expandedHeightRange.lowerBound, upper)...upper
    }
    private var expandedTopGapRange: ClosedRange<Double> {
        0...min(DockletSettings.expandedTopGapRange.upperBound, max(0, screenHeight - 240))
    }
    private var expandedSideGapRange: ClosedRange<Double> {
        0...max(0, (screenWidth - expandedWidthRange.lowerBound) / 2)
    }
    private var leftWidthRange: ClosedRange<Double> {
        DockletSettings.columnWidthRange(totalWidth: expandedWidth)
    }
    private var rightWidthRange: ClosedRange<Double> {
        let available = max(2, expandedWidth - 1)
        return (available - leftWidthRange.upperBound)...(available - leftWidthRange.lowerBound)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("顶部小组件").font(.title2.weight(.semibold))

                Card(title: "显示") {
                    Toggle("在屏幕顶部显示小组件", isOn: Binding(
                        get: { model.settings.docklet.enabled },
                        set: { value in
                            model.settings.docklet.enabled = value
                            save()
                        }
                    ))
                    .toggleStyle(.checkbox)
                    Text("鼠标移到刘海条上展开；菜单栏图标也可以控制显示并打开本页。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Card(title: "尺寸") {
                    DockletPointSlider(label: "刘海状态宽度",
                                       value: dockletValue(\.collapsedWidth,
                                                           range: DockletSettings.collapsedWidthRange),
                                       range: DockletSettings.collapsedWidthRange,
                                       onCommit: save)
                    DockletPointSlider(label: "刘海状态高度",
                                       value: Binding(
                                        get: { model.settings.docklet.collapsedHeight == 0
                                            ? menuBarHeight : model.settings.docklet.collapsedHeight },
                                        set: { model.settings.docklet.collapsedHeight =
                                            DockletSettings.clamp($0, to: DockletSettings.collapsedHeightRange) }),
                                       range: DockletSettings.collapsedHeightRange,
                                       onCommit: save)
                    if model.settings.docklet.collapsedHeight != 0 {
                        Button("恢复为系统菜单栏高度") {
                            model.settings.docklet.collapsedHeight = 0
                            save()
                        }
                    }
                    DockletPointSlider(label: "展开状态宽度",
                                       value: Binding(
                                        get: { expandedWidth },
                                        set: { model.settings.docklet.expandedWidthRatio =
                                            DockletSettings.clamp($0 / screenWidth,
                                                                 to: DockletSettings.widthRatioRange) }),
                                       range: expandedWidthRange,
                                       onCommit: save)
                    DockletPointSlider(label: "展开状态高度",
                                       value: dockletValue(\.expandedHeight, range: expandedHeightRange),
                                       range: expandedHeightRange,
                                       onCommit: save)
                    DockletPointSlider(label: "距屏幕顶边",
                                       value: dockletValue(\.expandedTopGap, range: expandedTopGapRange),
                                       range: expandedTopGapRange,
                                       onCommit: save)
                    DockletPointSlider(label: "距左右边缘（各）",
                                       value: Binding(
                                        get: { model.settings.docklet.expandedSideGap(for: screenWidth) },
                                        set: { gap in
                                            model.settings.docklet.expandedWidthRatio = DockletSettings.clamp(
                                                (screenWidth - 2 * gap) / screenWidth,
                                                to: DockletSettings.widthRatioRange)
                                        }),
                                       range: expandedSideGapRange,
                                       onCommit: save)
                    Text("左右间隙与展开宽度联动。展开面板留有顶边或左右间隙时，顶部也会显示圆角。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Card(title: "左右分栏") {
                    DockletPointSlider(label: "左栏 · 应用图标",
                                       value: Binding(
                                        get: { model.settings.docklet.columnWidths(totalWidth: expandedWidth).left },
                                        set: { setLeftWidth($0) }),
                                       range: leftWidthRange,
                                       onCommit: save)
                    DockletPointSlider(label: "右栏 · 快捷功能",
                                       value: Binding(
                                        get: { model.settings.docklet.columnWidths(totalWidth: expandedWidth).right },
                                        set: { setRightWidth($0) }),
                                       range: rightWidthRange,
                                       onCommit: save)
                    Text("两栏加起来等于展开宽度。调整任一栏时，另一栏会相应变化。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Card(title: "外观") {
                    Toggle("胶囊状态液态玻璃", isOn: Binding(
                        get: { model.settings.docklet.collapsedLiquidGlassEnabled },
                        set: { value in
                            model.settings.docklet.collapsedLiquidGlassEnabled = value
                            save()
                        }
                    ))
                    .toggleStyle(.checkbox)
                    Toggle("展开状态液态玻璃", isOn: Binding(
                        get: { model.settings.docklet.expandedLiquidGlassEnabled },
                        set: { value in
                            model.settings.docklet.expandedLiquidGlassEnabled = value
                            save()
                        }
                    ))
                    .toggleStyle(.checkbox)
                    if #unavailable(macOS 26.0) {
                        Text("液态玻璃需要 macOS 26 或更新版本；当前使用深色底板。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    SettingSlider(label: "刘海状态不透明度",
                                  value: dockletValue(\.collapsedOpacity,
                                                      range: DockletSettings.opacityRange),
                                  range: DockletSettings.opacityRange,
                                  onCommit: save)
                    SettingSlider(label: "展开状态不透明度",
                                  value: dockletValue(\.expandedOpacity,
                                                      range: DockletSettings.opacityRange),
                                  range: DockletSettings.opacityRange,
                                  onCommit: save)
                    Text("展开状态只调整底板透明度，应用图标和文字保持清晰。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Card(title: "应用图标") {
                    HStack {
                        Text("已添加 \(model.settings.docklet.appPaths.count) 个应用")
                            .font(.callout)
                        Spacer()
                        Button("添加应用") { pickApps() }
                        Button("清空图标") {
                            model.settings.docklet.appPaths.removeAll()
                            save()
                        }
                        .disabled(model.settings.docklet.appPaths.isEmpty)
                    }
                    ForEach(model.settings.docklet.appPaths, id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(nsImage: DockletIconCache.icon(for: path))
                                .resizable().frame(width: 28, height: 28)
                            Text(verbatim: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                            Text(verbatim: path)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("移除") {
                                model.removeDockletApp(path)
                                DockletIconCache.forget(path)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("顶部小组件")
    }

    /// 拖动时更新模型与顶部面板，松开滑块才写入设置文件。
    private func dockletValue(_ keyPath: WritableKeyPath<DockletSettings, Double>,
                              range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { DockletSettings.clamp(model.settings.docklet[keyPath: keyPath], to: range) },
            set: { model.settings.docklet[keyPath: keyPath] = DockletSettings.clamp($0, to: range) }
        )
    }

    private func setLeftWidth(_ width: Double) {
        let available = max(2, expandedWidth - 1)
        model.settings.docklet.appColumnRatio = DockletSettings.clamp(width / available,
                                                                      to: DockletSettings.appColumnRatioRange)
    }

    private func setRightWidth(_ width: Double) {
        let available = max(2, expandedWidth - 1)
        setLeftWidth(available - width)
    }

    private func save() {
        SettingsStore.save(model.settings)
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
        guard panel.runModal() == .OK else { return }
        model.addDockletApps(panel.urls.map(\.path))
    }
}

private struct DockletPointSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onCommit: () -> Void
    @FocusState private var editingNumber: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).frame(width: 200, alignment: .leading)
            Slider(value: $value, in: range, step: 1) { editing in
                if !editing { onCommit() }
            }
            TextField("", value: $value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 66)
                .focused($editingNumber)
                .onSubmit(onCommit)
                .onChange(of: editingNumber) { focused in
                    if !focused { onCommit() }
                }
            Text("pt").font(.callout).foregroundStyle(.secondary)
        }
    }
}
