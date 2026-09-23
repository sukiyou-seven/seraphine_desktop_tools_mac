import Foundation

/// 工具为某个数据库创建的账号凭据。
/// 只记录**本工具自己创建**的库用户；外部手工建的账号无从得知密码，列表里会显示「—」。
struct DatabaseCredential: Codable, Identifiable {
    var database: String
    var user: String
    var password: String
    /// ISO8601 字符串，避免 Date 编解码策略不一致
    var createdAt: String

    var id: String { database }
}

enum CredentialStore {
    /// 与设置分开放：这是按库的凭据清单，权限同样收紧到 600。
    static var fileURL: URL { Paths.appSupport.appendingPathComponent("credentials.json") }

    static func load() -> [DatabaseCredential] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([DatabaseCredential].self, from: data) else {
            return []
        }
        return list.sorted { $0.database < $1.database }
    }

    private static func save(_ list: [DatabaseCredential]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(list) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            try? data.write(to: fileURL)          // 受限环境下退回非原子写
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// 新增或覆盖某个库的凭据，返回更新后的清单。
    @discardableResult
    static func upsert(database: String, user: String, password: String) -> [DatabaseCredential] {
        var list = load()
        list.removeAll { $0.database == database }
        list.append(DatabaseCredential(database: database, user: user, password: password,
                                       createdAt: ISO8601DateFormatter().string(from: Date())))
        save(list)
        return list.sorted { $0.database < $1.database }
    }

    @discardableResult
    static func remove(database: String) -> [DatabaseCredential] {
        var list = load()
        list.removeAll { $0.database == database }
        save(list)
        return list
    }
}
