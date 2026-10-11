import Foundation

for address in ["https://192.168.0.103:27520", "https://10.0.0.1:27520",
                "https://172.16.0.1:27520", "https://[fd12::1]:27520"] {
    guard ServerStatusAPI.sessionConfiguration(endpoint: address).connectionProxyDictionary?.isEmpty == true else {
        fatalError("local server traffic must bypass the system proxy: \(address)")
    }
}
guard ServerStatusAPI.sessionConfiguration(endpoint: "https://47.109.68.130:27520").connectionProxyDictionary == nil else {
    fatalError("public server proxy settings should follow the system")
}
print("局域网 HTTPS 直连配置测试通过")

let json = #"""
{
  "schema_version": 1,
  "timestamp": "2026-10-08T08:00:00Z",
  "host": {"hostname":"server","os":"Linux","kernel":"6.0","architecture":"amd64","uptime_seconds":3600},
  "cpu": {"usage_percent":12.5,"logical_cores":2,"load_1m":0.3,"load_5m":0.2,"load_15m":0.1},
  "memory": {"total_bytes":1073741824,"available_bytes":536870912,"used_bytes":536870912,"usage_percent":50},
  "swap": {"total_bytes":0,"used_bytes":0,"usage_percent":0},
  "disks": [{"device":"/dev/vda1","mountpoint":"/","filesystem":"ext4","total_bytes":1000,"available_bytes":200,"used_bytes":700,"usage_percent":70}],
  "network": [{"name":"eth0","rx_bytes":1000,"tx_bytes":2000,"rx_bytes_per_second":100,"tx_bytes_per_second":200}]
}
"""#

let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase
let status = try decoder.decode(ServerSnapshot.self, from: Data(json.utf8))
guard status.schemaVersion == 1,
      status.cpu.load1M == 0.3,
      status.memory.availableBytes == 536870912,
      status.disks.first?.mountpoint == "/",
      status.network.first?.rxBytesPerSecond == 100 else {
    fatalError("server status JSON decoding mismatch")
}
guard (try? ServerStatusAPI.statusURL("https://example.com:27520"))?.absoluteString == "https://example.com:27520/v1/status",
      (try? ServerStatusAPI.statusURL("http://example.com")) == nil,
      (try? ServerStatusAPI.normalizedFingerprint(String(repeating: "AB:", count: 32).dropLast().description)) == String(repeating: "ab", count: 32) else {
    fatalError("server status configuration validation mismatch")
}
print("服务器状态协议测试通过")

let connections = [
    ServerConnection(name: "测试", endpoint: "https://example.com:27520", fingerprint: "abc"),
    ServerConnection(name: "生产", endpoint: "https://example.net:27520", fingerprint: "def"),
]
let restoredConnections = try JSONDecoder().decode([ServerConnection].self,
                                                    from: JSONEncoder().encode(connections))
guard restoredConnections == connections,
      restoredConnections.map(\.label) == ["测试", "生产"],
      restoredConnections[0].id != restoredConnections[1].id else {
    fatalError("multiple server connection configuration mismatch")
}
print("多服务器连接配置测试通过")

let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("sera-connection-test-\(UUID().uuidString)")
ServerConnectionStore.storageDirectoryOverride = testDirectory
defer {
    ServerConnectionStore.storageDirectoryOverride = nil
    try? FileManager.default.removeItem(at: testDirectory)
}
let initialConnections = ServerConnectionStore.load()
guard initialConnections.contains(where: { $0.id == ServerConnectionStore.selectedID }) else {
    fatalError("initial connection selection is unstable")
}
try ServerConnectionStore.save(connections, selectedID: connections[0].id, token: "first-token")
try ServerConnectionStore.save(connections, selectedID: connections[1].id, token: "second-token")
guard ServerConnectionStore.load() == connections,
      ServerConnectionStore.selectedID == connections[1].id,
      ServerConnectionStore.token(for: connections[0].id) == "first-token",
      ServerConnectionStore.token(for: connections[1].id) == "second-token" else {
    fatalError("file-based connection storage mismatch")
}
try ServerConnectionStore.save([connections[0]], selectedID: connections[0].id)
guard ServerConnectionStore.token(for: connections[1].id).isEmpty,
      ServerConnectionStore.token(for: connections[0].id) == "first-token" else {
    fatalError("deleting a connection did not remove only its token")
}
let folderMode = (try FileManager.default.attributesOfItem(atPath: testDirectory.path)[.posixPermissions] as? NSNumber)?.intValue
let fileMode = (try FileManager.default.attributesOfItem(atPath: ServerConnectionStore.storageFile.path)[.posixPermissions] as? NSNumber)?.intValue
guard folderMode == 0o700, fileMode == 0o600 else {
    fatalError("connection file permissions are too open: \(String(describing: folderMode)), \(String(describing: fileMode))")
}
print("本地连接文件与权限测试通过")

let listingJSON = #"{"path":"/www/seraphim","parent":"/www","entries":[{"name":"web","path":"/www/seraphim/web","kind":"directory","permissions":"0755","size_bytes":0,"modified_at":"2026-10-08T00:00:00Z"}]}"#
let fileDecoder = JSONDecoder()
fileDecoder.keyDecodingStrategy = .convertFromSnakeCase
let listing = try fileDecoder.decode(RemoteFileListing.self, from: Data(listingJSON.utf8))
let fileURL = try ServerFileAPI.url(endpoint: "https://example.com:27520", path: "/v1/files",
                                    remotePath: "/www/seraphim/web/中文.txt")
guard listing.entries.first?.isDirectory == true,
      listing.entries.first?.permissions == "0755",
      listing.entries.first?.isProtectedPath == true,
      listing.parent == "/www",
      URLComponents(url: fileURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "/www/seraphim/web/中文.txt" else {
    fatalError("file API protocol mismatch")
}
print("文件接口协议测试通过")

let serviceJSON = #"{"services":[{"name":"firewalld.service","description":"firewalld","active_state":"inactive","sub_state":"dead","unit_state":"disabled"}]}"#
let serviceDecoder = JSONDecoder()
serviceDecoder.keyDecodingStrategy = .convertFromSnakeCase
let serviceListing = try serviceDecoder.decode(RemoteServiceListing.self, from: Data(serviceJSON.utf8))
guard serviceListing.services.first?.runningText == "已停止",
      serviceListing.services.first?.startupText == "未启用",
      serviceListing.services.first?.isActive == false,
      serviceListing.services.first?.isEnabled == false,
      (try? ServerServiceAPI.url(endpoint: "https://example.com:27520"))?.absoluteString == "https://example.com:27520/v1/services" else {
    fatalError("service API protocol mismatch")
}
print("服务接口协议测试通过")

let softwareJSON = #"{"items":[{"id":"mysql","name":"MySQL","version":"8.4.11","description":"数据库服务","install_path":"/www/seraphim/server/mysql","log_path":"/www/seraphim/logs/software-mysql.log","credential_path":"/www/seraphim/server/mysql/initial-root-password","state":"not_installed","message":"","service_state":"inactive","enabled":false,"supported":true}]}"#
let softwareDecoder = JSONDecoder()
softwareDecoder.keyDecodingStrategy = .convertFromSnakeCase
let catalog = try softwareDecoder.decode(RemoteSoftwareListing.self, from: Data(softwareJSON.utf8))
guard catalog.items.first?.stateText == "未安装",
      catalog.items.first?.runningText == "已停止",
      (try? ServerSoftwareAPI.url(endpoint: "https://example.com:27520"))?.absoluteString == "https://example.com:27520/v1/software" else {
    fatalError("software API protocol mismatch")
}
print("软件商店协议测试通过")
