import SwiftUI
import AppKit

/// 剪贴板历史页：点任意一条就复制回系统剪贴板。
///
/// 拆成两层是有意的：`ClipboardService` 是独立的 `ObservableObject`，
/// 只有把它当 `@ObservedObject` 持有，它的 `@Published`（条目、Redis 状态）变化才会让界面刷新。
struct ClipboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ClipboardContent(clipboard: model.clipboard)
    }
}

private struct ClipboardContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var clipboard: ClipboardService
    /// 刚复制过的那条（按钮上短暂显示「已复制」）。
    @State private var copiedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .navigationTitle("剪贴板")
        .onAppear {
            // 进页面时跟 Redis 对一次：别的程序/另一台机器往同一个 Redis 里写过也能看到。
            clipboard.syncFromRedis()
        }
    }

    // MARK: 顶部状态

    private var header: some View {
        Card(title: "剪贴板历史") {
            HStack(spacing: 12) {
                StatusDot(running: clipboard.recording)
                Text(verbatim: clipboard.recording ? "正在记录" : "已暂停记录")
                    .font(.title3.weight(.semibold))
                Text(verbatim: "\(clipboard.entries.count)/\(ClipboardService.maxEntries) 条")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(verbatim: "固化文件 \(FileTools.humanBytes(Int64(clipboard.fileBytes))) / 上限 \(FileTools.humanBytes(Int64(ClipboardService.maxFileBytes)))")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("记录剪贴板", isOn: Binding(
                    get: { model.settings.clipboard.enabled },
                    set: { model.setClipboardRecording($0) }))
                .toggleStyle(.checkbox)
                Button("重新读 Redis") { clipboard.syncFromRedis() }
                Button("清空") { clipboard.clear() }
                    .disabled(clipboard.entries.isEmpty)
            }
            Text(verbatim: "存储：Redis（\(ClipboardHistory.redisKey)，读得快）+ 本地文件 \(clipboard.filePath)（关机重开还在）。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "只记文本：图片、文件等非文本内容不会进历史，也不会写进本地文件。点击任意一条即可复制回剪贴板。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "Redis：\(clipboard.redisNote)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 列表

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "最新在前；单条超过 \(FileTools.humanBytes(Int64(ClipboardHistory.maxTextBytes))) 会被截断")
                .font(.caption)
                .foregroundStyle(.secondary)
            if clipboard.entries.isEmpty {
                EmptyHint(text: "还没有记录。复制一段文字试试 —— 本页面没打开时也会记。")
            } else {
                FlexibleScroll {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(clipboard.entries.enumerated()), id: \.element.id) { index, entry in
                            ClipboardRow(index: index + 1,
                                         entry: entry,
                                         copied: copiedID == entry.id,
                                         onCopy: { copy(entry) },
                                         onDelete: { clipboard.remove(entry) })
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func copy(_ entry: ClipboardEntry) {
        clipboard.copy(entry)
        copiedID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedID == entry.id { copiedID = nil }
        }
    }
}

// MARK: - 单条历史

private struct ClipboardRow: View {
    var index: Int
    var entry: ClipboardEntry
    var copied: Bool
    var onCopy: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "#\(index)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: timeText(entry.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: FileTools.humanBytes(Int64(entry.bytes)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if entry.truncated {
                        Text(verbatim: "已截断")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(verbatim: entry.text)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(copied ? "已复制" : "复制") { onCopy() }
                .buttonStyle(.borderless)
                .font(.caption)
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("从历史里删掉这一条")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.18)))
        // 整行可点：点哪儿都是「复制回剪贴板」
        .contentShape(Rectangle())
        .onTapGesture { onCopy() }
    }
}
