import Foundation

/// 「API 设置」要展示的东西：接口列表 + 一把给脚本和 AI 用的 key。
///
/// 这把 key 是服务端单独存的（`config/api-key`），不是面板客户端连服务器用的
/// 那个凭据——两者刻意分开，好让重置只作废脚本和 AI 客户端那一侧。
/// key 只由服务端生成：页面上没有填写框，这边也不会把任何值传上去。

struct RemoteAPIEndpoint: Decodable, Identifiable {
    let method: String
    let path: String
    let summary: String
    let example: String?

    var id: String { method + " " + path }
    /// 带路径参数的行在示例里没法直接粘贴，界面上给个提示。
    var needsParameters: Bool { path.contains("{") }
}

struct RemoteAPISection: Decodable, Identifiable {
    let name: String
    let endpoints: [RemoteAPIEndpoint]

    var id: String { name }
}

struct RemoteMCPTool: Decodable, Identifiable {
    let name: String
    let description: String

    var id: String { name }
}

struct RemoteMCPInfo: Decodable {
    let path: String
    let url: String
    let headers: [String: String]
    let script: String
    let tools: [RemoteMCPTool]
}

struct RemoteAPIDocument: Decodable {
    let version: String
    let endpoint: String
    let key: String
    let header: String
    let sections: [RemoteAPISection]
    let mcp: RemoteMCPInfo

    var endpointCount: Int { sections.reduce(0) { $0 + $1.endpoints.count } }

    /// 一段可以直接粘进终端跑的示例。`-k` 是为了自签证书，正式证书也能跑。
    var curlExample: String {
        """
        export SERAPHIM="\(endpoint)"
        export API_KEY="\(key)"
        curl -k -H "Authorization: Bearer $API_KEY" "$SERAPHIM/v1/projects"
        """
    }

    /// 支持 HTTP 传输的 AI 客户端用的配置片段。key 直接写进去，省一步。
    var mcpHTTPConfiguration: String {
        """
        {
          "mcpServers": {
            "seraphim": {
              "type": "http",
              "url": "\(mcp.url)",
              "headers": { "Authorization": "Bearer \(key)" }
            }
          }
        }
        """
    }

    /// 只支持 stdio 的客户端用的配置。桥脚本要在本机有份实体文件，
    /// 所以 scriptPath 由「保存到本机」那一步填进来。
    func mcpStdioConfiguration(scriptPath: String) -> String {
        """
        {
          "mcpServers": {
            "seraphim": {
              "command": "python3",
              "args": ["\(scriptPath)"],
              "env": {
                "SERAPHIM_ENDPOINT": "\(endpoint)",
                "SERAPHIM_TOKEN": "\(key)"
              }
            }
          }
        }
        """
    }
}

enum ServerAPIAccessAPI {
    /// 服务端这三条路径。集中放一处，改名时不会漏掉某一边。
    static let documentPath = "/v1/api"
    static let keyPath = "/v1/api/key"
    static let scriptPath = "/v1/mcp/script"

    /// 桥脚本在本机的落点。放在应用数据目录里：和连接配置同一处，卸载时一起清掉。
    static var bridgeScriptDestination: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Seraphim/seraphim-mcp.py").path
    }

    static func document(connection: ServerConnection, token: String) async throws -> RemoteAPIDocument {
        let data = try await ServerProjectAPI.call(connection: connection, token: token, path: documentPath,
                                                   method: "GET", expected: 200)
        return try ServerProjectAPI.decoder.decode(RemoteAPIDocument.self, from: data)
    }

    /// 重置 API key：服务端生成新的一把并返回整份接入信息，旧的那把立刻失效。
    /// 面板自己连服务器用的是另一份凭据，所以这一步不会把面板踢下线。
    static func resetKey(connection: ServerConnection, token: String) async throws -> RemoteAPIDocument {
        let data = try await ServerProjectAPI.call(connection: connection, token: token, path: keyPath,
                                                   method: "POST", expected: 200)
        return try ServerProjectAPI.decoder.decode(RemoteAPIDocument.self, from: data)
    }

    /// 取 stdio 桥脚本的原文，供「保存到本机」用。
    static func bridgeScript(connection: ServerConnection, token: String) async throws -> Data {
        try await ServerProjectAPI.call(connection: connection, token: token, path: scriptPath,
                                        method: "GET", expected: 200)
    }
}
