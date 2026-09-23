import SwiftUI

struct RedisView: View {
    @EnvironmentObject var model: AppModel
    @State private var section = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RedisHeader()
            Picker("", selection: $section) {
                Text("数据浏览").tag(0)
                Text("概览").tag(1)
                Text("配置").tag(2)
                Text("控制台").tag(3)
                Text("日志").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch section {
            case 1: RedisOverviewSection()
            case 2: RedisConfigSection()
            case 3: RedisConsoleSection()
            case 4: RedisLogSection()
            default: RedisDataSection()
            }
        }
        // 占满整屏并从顶部开始排；各标签页自己负责内部滚动
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .navigationTitle("Redis")
        .onAppear {
            model.refreshRedisStatus()
            model.scanRedis(reset: true)
        }
    }
}

// MARK: - 顶部状态

private struct RedisHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "Redis") {
            HStack(spacing: 10) {
                StatusDot(running: model.redisStatus.running)
                Text(verbatim: model.redisStatus.running ? "运行中" : "已停止")
                    .font(.title3.weight(.semibold))
                Text(verbatim: model.redisTarget)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("启动") { model.startRedis() }.disabled(model.redisStatus.running)
                Button("停止") { model.stopRedis() }.disabled(!model.redisStatus.running)
                Button("重启") { model.restartRedis() }.disabled(!model.redisStatus.running)
                Button("刷新") { model.refreshRedisStatus() }
            }

            if !model.redisStatus.installed {
                Text(verbatim: "未检测到 redis-server。安装方式：brew install redis；装完后点「刷新」，或在设置里手动指定路径。")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - 数据浏览

private struct RedisDataSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("库", selection: $model.redisDatabase) {
                    ForEach(0..<16, id: \.self) { index in
                        Text("db\(index)").tag(index)
                    }
                }
                .frame(width: 130)
                .onChange(of: model.redisDatabase) { _ in
                    model.scanRedis(reset: true)
                }

                TextField("匹配模式，如 user:*", text: $model.redisPattern)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { model.scanRedis(reset: true) }

                Button("扫描") { model.scanRedis(reset: true) }
                    .disabled(!model.redisStatus.running)
                Button("下一页") { model.scanRedis(reset: false) }
                    .disabled(!model.redisStatus.running || model.redisScannedAll)

                Spacer()
                Text(verbatim: "共 \(model.redisTotalKeys) 个 key · 第 \(model.redisPage) 批\(model.redisScannedAll ? "（已扫完）" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.redisStatus.running {
                EmptyHint(text: "Redis 未运行：先在上面启动服务")
            } else {
                HStack(alignment: .top, spacing: 12) {
                    keyList
                        .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
                    Divider()
                    RedisValuePane()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)   // 撑满剩余高度，左右两边各自滚动
            }
        }
    }

    private var keyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("key").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                Text("类型").font(.caption).frame(width: 70, alignment: .leading)
                Text("TTL").font(.caption).frame(width: 60, alignment: .leading)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.redisRows) { row in
                        HStack(spacing: 6) {
                            Text(verbatim: row.key)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: row.typeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Text(verbatim: row.ttlLabel)
                                .font(.caption)
                                .foregroundStyle(row.ttl >= 0 ? Color.orange : Color.secondary)
                                .frame(width: 60, alignment: .leading)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 4)
                        .background(model.redisSelectedKey == row.key
                                    ? Color.accentColor.opacity(0.18) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { model.loadRedisKey(row.key) }
                        Divider()
                    }
                }
            }
            // 撑满剩余高度：key 多的时候在列表里滚，别把整页顶出窗口
            .frame(minHeight: 200, maxHeight: .infinity)
            if model.redisRows.isEmpty {
                EmptyHint(text: "没有匹配的 key")
            }
        }
    }
}

private struct RedisValuePane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let error = model.redisDetailError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: error).foregroundStyle(.orange).font(.callout)
                    Text(verbatim: "选一个 key 看内容").font(.caption).foregroundStyle(.secondary)
                }
            } else if let detail = model.redisDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: detail.key)
                            .font(.system(.title3, design: .monospaced))
                            .textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 5) {
                            InfoRow(label: "类型", value: detail.typeLabel)
                            InfoRow(label: "TTL", value: detail.ttlLabel)
                            InfoRow(label: "底层编码", value: detail.encoding)
                            if let count = detail.count {
                                InfoRow(label: "元素数量", value: String(count))
                            }
                        }
                        if !detail.note.isEmpty {
                            Text(verbatim: detail.note).font(.caption).foregroundStyle(.secondary)
                        }
                        if detail.truncated {
                            Text(verbatim: "内容较多，仅显示前 200 项 / 8000 字符。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let text = detail.text {
                            Card(title: "值") {
                                ReadonlyText(text: text, minHeight: 220)
                            }
                        }
                        if !detail.rows.isEmpty {
                            Card(title: "内容") {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(detail.rows) { row in
                                        HStack(alignment: .top, spacing: 10) {
                                            Text(verbatim: row.label)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 150, alignment: .leading)
                                                .lineLimit(1)
                                            Text(verbatim: row.value)
                                                .font(.system(size: 12, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(.vertical, 3)
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)   // 右侧详情也撑满剩余高度、内部滚动
            } else {
                EmptyHint(text: "从左侧选一个 key 查看内容")
            }
        }
    }
}

// MARK: - 概览

private struct RedisOverviewSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "连接信息") {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "监听地址", value: model.redisTarget)
                    InfoRow(label: "版本", value: model.redisStatus.version)
                    InfoRow(label: "可执行文件", value: model.redisStatus.binary)
                    InfoRow(label: "进程 PID", value: model.redisStatus.pid > 0 ? String(model.redisStatus.pid) : "")
                    InfoRow(label: "配置文件", value: model.redisStatus.confPath)
                    InfoRow(label: "工作目录", value: model.redisStatus.dirPath)
                    InfoRow(label: "连通性", value: model.redisStatus.ping)
                }
            }

            Card(title: "运行概览") {
                HStack {
                    Button("刷新概览") { model.loadRedisOverview() }
                        .disabled(!model.redisStatus.running)
                    Text(verbatim: "统计 db\(model.redisDatabase) 与整个实例")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.redisOverviewError {
                    Text(verbatim: error).font(.callout).foregroundStyle(.orange)
                }
                if let overview = model.redisOverview {
                    VStack(alignment: .leading, spacing: 6) {
                        InfoRow(label: "版本", value: overview.version)
                        InfoRow(label: "运行模式", value: overview.mode)
                        InfoRow(label: "角色", value: overview.role)
                        InfoRow(label: "当前库 key 数", value: String(overview.keys))
                        InfoRow(label: "客户端连接", value: overview.clients)
                        InfoRow(label: "已用内存", value: overview.memory)
                        InfoRow(label: "内存峰值", value: overview.memoryPeak)
                        InfoRow(label: "AOF", value: overview.aof == "1" ? "已开启" : "未开启")
                        InfoRow(label: "命中率", value: overview.hitRate)
                        InfoRow(label: "运行时长", value: overview.uptime.isEmpty ? "" : overview.uptime + " 秒")
                    }
                    if !overview.keyspace.isEmpty {
                        Divider()
                        Text("各库键数量").font(.callout)
                        ForEach(overview.keyspace, id: \.0) { pair in
                            InfoRow(label: pair.0, value: pair.1)
                        }
                    }
                }
            }
        }
        .onAppear { model.loadRedisOverview() }
    }
}

// MARK: - 配置

private struct RedisConfigSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // 配置项多、还有配置全文编辑器，必须能滚
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card(title: "配置文件") {
                    InfoRow(label: "文件路径", value: model.redisConfigFile)
                    Text(verbatim: "保存时先备份成 .bak。改完端口 / 密码 / 持久化等要重启 Redis 才生效。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .onAppear {
                    if model.redisParamRows.isEmpty { model.loadRedisConfig() }
                }

                Card(title: "常用配置项") {
                    if model.redisParamRows.isEmpty {
                        EmptyHint(text: "点下面的按钮加载配置项")
                    } else {
                        ForEach(model.redisParamRows) { row in
                            ParamEditor(row: row) { newValue in
                                model.saveRedisParam(row, value: newValue)
                            }
                        }
                    }
                    Button("加载 / 重新读取") { model.loadRedisConfig() }
                }

                Card(title: "配置文件全文") {
                    TextEditor(text: $model.redisConfigText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 240)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25)))
                    HStack {
                        Button("读取当前文件") { model.loadRedisConfig() }
                        Button("保存") { model.saveRedisConfigText() }
                    }
                }
            }
        }
    }
}

// MARK: - 控制台

private struct RedisConsoleSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "直接执行 Redis 命令（作用于 db\(model.redisDatabase)，写操作会真的生效）。例：GET user:1、HGETALL cart、INFO memory、DEL tmp。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.consoleEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: "> " + entry.command)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            Text(verbatim: entry.output)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(entry.ok ? Color.primary : Color.orange)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    }
                    if model.consoleEntries.isEmpty {
                        EmptyHint(text: "还没有执行过命令")
                    }
                }
            }
            // 输出区撑满剩余高度，输入框始终留在底部
            .frame(minHeight: 220, maxHeight: .infinity)

            HStack {
                TextField("输入命令后回车", text: $model.consoleInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit { model.runRedisCommand() }
                Button("执行") { model.runRedisCommand() }
                    .disabled(!model.redisStatus.running)
            }
        }
    }
}

// MARK: - 日志

private struct RedisLogSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "日志尾部") {
            HStack {
                Button("刷新日志") { model.loadRedisLog() }
                InfoRow(label: "日志文件", value: model.redisStatus.logFile)
            }
            ReadonlyText(text: model.redisLog, minHeight: 320)
        }
        .onAppear { model.loadRedisLog() }
    }
}
