import SwiftUI
import AppKit

struct HomeCleanupView: View {
    @State private var candidates: [HomeLogCandidate] = []
    @State private var selected: Set<String> = []
    @State private var confirming = false
    @State private var result = ""

    private var chosen: [HomeLogCandidate] { candidates.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("家目录日志清理").font(.title2.weight(.semibold))
                Spacer()
                Button("重新扫描") { refresh() }
                Button("全选") { selected = Set(candidates.map(\.id)) }
                    .disabled(candidates.isEmpty)
                Button("移到废纸篓", role: .destructive) { confirming = true }
                    .disabled(chosen.isEmpty)
            }
            Text("只扫描 \(NSHomeDirectory()) 顶层的 .log。仅列出超过 24 小时、内容可确认为 Xcode 构建或设备操作输出的文件；其他日志不会列出。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("找到 \(candidates.count) 个，已选 \(chosen.count) 个")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(chosen.reduce(0) { $0 + $1.size }),
                                               countStyle: .file))
            }
            .font(.callout)
            if !result.isEmpty {
                Text(verbatim: result).font(.callout).foregroundStyle(.secondary)
            }
            List {
                ForEach(candidates) { candidate in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { selected.contains(candidate.id) },
                            set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) } }
                        )) { EmptyView() }
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: candidate.url.lastPathComponent).font(.body.monospaced())
                            Text(verbatim: candidate.source + " · "
                                 + ByteCountFormatter.string(fromByteCount: Int64(candidate.size), countStyle: .file)
                                 + " · " + candidate.modified.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: candidate.url.path)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("查看") { NSWorkspace.shared.open(candidate.url) }
                    }
                    .padding(.vertical, 3)
                }
            }
            if candidates.isEmpty {
                Text("没有符合规则的旧日志。")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .navigationTitle("清理")
        .onAppear { refresh() }
        .alert("把选中的 \(chosen.count) 个日志移到废纸篓？", isPresented: $confirming) {
            Button("移到废纸篓", role: .destructive) {
                let outcome = HomeLogCleanup.moveToTrash(chosen)
                refresh()
                result = "已移到废纸篓 \(outcome.moved) 个；跳过 \(outcome.skipped) 个（可能已变动或无权限）。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("可在废纸篓中恢复。移动前会再次检查文件，正在写入或已改变的文件会跳过。")
        }
    }

    private func refresh() {
        candidates = HomeLogCleanup.scan()
        selected = Set(candidates.map(\.id))
    }
}
