import SwiftUI
import AppKit

/// 「API 设置」：给用户看接口列表，再给一把能直接复制走的 key。
///
/// 这把 key 是服务端单独生成、单独存的一把，和面板客户端连服务器用的凭据
/// 不是同一个——所以这里可以「换一把」：脚本或 AI 客户端那边泄露了就重置，
/// 已经连上的面板不受影响。
///
/// 唯一能做的动作是重置：key 只由服务端生成，页面上没有填写框，也没有接口
/// 接受用户指定的值。
struct ServerAPIAccessView: View {
    let connection: ServerConnection
    let token: String

    @State private var document: RemoteAPIDocument?
    @State private var loading = false
    @State private var message = ""
    @State private var hasError = false
    @State private var bridgePath = ServerAPIAccessAPI.bridgeScriptDestination
    @State private var savingBridge = false
    @State private var confirmingReset = false
    @State private var resetting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text("面板的全部能力都走同一套 HTTPS 接口。用下面这把 key 就能调用：上传项目、启动停止、改配置、装依赖，脚本和 AI 客户端都一样。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !message.isEmpty {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(hasError ? Color.orange : Color.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlexibleScroll {
                VStack(alignment: .leading, spacing: 10) {
                    accessCard
                    quickStartCard
                    endpointCard
                    mcpCard
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            refreshBridgePath()
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .serverManagementRefresh)) { _ in
            Task { await reload() }
        }
        .alert("重置 API key？", isPresented: $confirmingReset) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) { Task { await resetKey() } }
        } message: {
            Text("服务端会生成新的一把，旧的立刻失效：正在用它的脚本和 AI 客户端都要换成新的。面板连服务器用的是另一份凭据，不会掉线。")
        }
    }

    private var header: some View {
        HStack {
            Text("API 设置").font(.title3.weight(.semibold))
            Spacer()
            if loading || resetting { ProgressView().controlSize(.small) }
            Button("刷新") { Task { await reload() } }.disabled(loading || resetting)
        }
    }

    // MARK: - 连接信息

    private var accessCard: some View {
        Card(title: "连接信息") {
            VStack(alignment: .leading, spacing: 8) {
                if let document {
                    HStack(alignment: .top, spacing: 8) {
                        label("服务地址")
                        CopyableText(text: document.endpoint)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        label("API key")
                        SecretCell(secret: document.key)
                        Spacer(minLength: 8)
                        Button("重置") { confirmingReset = true }
                            .disabled(resetting)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        label("请求头")
                        CopyableText(text: document.header)
                    }
                    Text("这把 key 由服务端生成，和面板客户端连服务器用的凭据是两把，所以在脚本泄露时可以直接换掉它。页面上只能重置，不能自己填。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(loading ? "正在读取…" : "还没取到接入信息。点右上角「刷新」重试。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: 78, alignment: .leading)
    }

    // MARK: - 快速开始

    private var quickStartCard: some View {
        Card(title: "快速开始") {
            VStack(alignment: .leading, spacing: 8) {
                if let document {
                    Text("把下面三行贴进终端，第一行设置地址与 key，第三行就能列出服务器上的项目。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CodeBlock(code: document.curlExample)
                    Text("常见的自动化：打包上传项目（POST /v1/projects/import）、启动（POST /v1/projects/{id}/action）、改公用环境变量（PUT /v1/variables）。每一行的完整示例见下面的接口列表。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("重置 key 之后，脚本里这几行里的 key 也要一起换新的。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("正在读取…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 接口列表

    private var endpointCard: some View {
        Card(title: "接口列表") {
            VStack(alignment: .leading, spacing: 12) {
                if let document {
                    Text("共 \(document.endpointCount) 个接口。带 {id} 的参数按实际项目标识替换。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(document.sections) { section in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(section.name)
                                .font(.callout.weight(.semibold))
                            ForEach(section.endpoints) { endpoint in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(endpoint.method)
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(methodColor(endpoint.method))
                                            .frame(width: 46, alignment: .leading)
                                        Text(verbatim: endpoint.path)
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .textSelection(.enabled)
                                        Text(verbatim: endpoint.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                    if let example = endpoint.example, !example.isEmpty {
                                        CodeBlock(code: example, compact: true)
                                            .padding(.leading, 54)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text("正在读取…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": return .accentColor
        case "POST": return .green
        case "PUT": return .orange
        case "DELETE": return .red
        default: return .secondary
        }
    }

    // MARK: - MCP

    private var mcpCard: some View {
        Card(title: "MCP（让 AI 直接管理）") {
            VStack(alignment: .leading, spacing: 8) {
                if let document {
                    Text("面板自带 MCP 端点，AI 客户端接上之后就能直接看项目、上传代码、启动服务、读自检。支持 HTTP 传输的客户端用第一段配置；只支持 stdio 的（多数桌面客户端）先把桥脚本存到本机，再用第二段。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("HTTP 传输")
                        .font(.callout.weight(.semibold))
                        .padding(.top, 2)
                    CodeBlock(code: document.mcpHTTPConfiguration)
                    HStack(spacing: 8) {
                        Text("stdio 传输")
                            .font(.callout.weight(.semibold))
                        Button(savingBridge ? "正在保存…" : "把桥脚本存到本机") { saveBridge() }
                            .disabled(savingBridge)
                        if bridgeExists {
                            Text(verbatim: bridgePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.top, 2)
                    CodeBlock(code: document.mcpStdioConfiguration(scriptPath: bridgePath))
                    DisclosureGroup("AI 能用的 \(document.mcp.tools.count) 个工具") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(document.mcp.tools) { tool in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(verbatim: tool.name)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .frame(width: 210, alignment: .leading)
                                    Text(verbatim: tool.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.callout)
                } else {
                    Text("正在读取…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var bridgeExists: Bool {
        FileManager.default.fileExists(atPath: bridgePath)
    }

    private func refreshBridgePath() {
        bridgePath = ServerAPIAccessAPI.bridgeScriptDestination
    }

    // MARK: - 数据

    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true
        do {
            document = try await ServerAPIAccessAPI.document(connection: connection, token: token)
            message = ""
            hasError = false
        } catch {
            message = error.localizedDescription
            hasError = true
        }
        loading = false
    }

    /// 重置：服务端生成新的一把并把整份接入信息发回来，所以这里不用再读一次。
    /// 新 key 立刻显示出来，页面上的示例与 MCP 配置跟着一起换。
    @MainActor private func resetKey() async {
        guard !resetting else { return }
        resetting = true
        hasError = false
        do {
            let updated = try await ServerAPIAccessAPI.resetKey(connection: connection, token: token)
            document = updated
            message = "已重置：旧 key 立刻失效，脚本和 AI 客户端里的都要换成新的。"
        } catch {
            message = error.localizedDescription
            hasError = true
        }
        resetting = false
    }

    private func saveBridge() {
        guard let document else { return }
        savingBridge = true
        hasError = false
        Task { @MainActor in
            do {
                let data = try await ServerAPIAccessAPI.bridgeScript(connection: connection, token: token)
                let url = URL(fileURLWithPath: ServerAPIAccessAPI.bridgeScriptDestination)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                bridgePath = url.path
                message = "桥脚本已保存到 \(url.path)；上面那段 stdio 配置可以直接用了。"
                hasError = false
                _ = document
            } catch {
                message = error.localizedDescription
                hasError = true
            }
            savingBridge = false
        }
    }
}

/// 多行代码块：等宽字体、可选横向滚动，右上角一个复制按钮。
private struct CodeBlock: View {
    var code: String
    var compact = false

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(.system(size: compact ? 10.5 : 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                Spacer()
                Button(copied ? "已复制" : "复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
    }
}
