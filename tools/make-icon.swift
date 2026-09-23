import AppKit
import Foundation

// 把一张 PNG 转成 macOS 的 .icns（缩放 + 组装都在这里做，不依赖 sips / iconutil）。
// 用法：make-icon <源图.png> <输出.icns>

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("用法：make-icon <源图.png> <输出.icns>\n".utf8))
    exit(2)
}
let sourcePath = arguments[1]
let outputPath = arguments[2]

guard let source = NSImage(contentsOfFile: sourcePath) else {
    FileHandle.standardError.write(Data("无法读取源图：\(sourcePath)\n".utf8))
    exit(1)
}

/// icns 条目：4 字节类型 + 4 字节长度（含头部）+ 数据。
/// 现代 macOS 支持条目内直接放 PNG，所以这里只做缩放与拼接。
func entry(_ tag: String, _ png: Data) -> Data {
    var data = Data(tag.utf8)
    var length = UInt32(png.count + 8).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(png)
    return data
}

func pngData(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                from: NSRect(origin: .zero, size: source.size),
                operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// 条目类型 → 像素尺寸（覆盖 16pt ~ 512pt 的 1x/2x）
let layout: [(tag: String, size: Int)] = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64),
    ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
    ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512),
]

var body = Data()
for item in layout {
    guard let png = pngData(size: item.size) else {
        FileHandle.standardError.write(Data("缩放 \(item.size)px 失败\n".utf8))
        exit(1)
    }
    body.append(entry(item.tag, png))
}

var icns = Data("icns".utf8)
var total = UInt32(body.count + 8).bigEndian
withUnsafeBytes(of: &total) { icns.append(contentsOf: $0) }
icns.append(body)

do {
    try icns.write(to: URL(fileURLWithPath: outputPath))
    print("已生成 \(outputPath)（\(icns.count) 字节，\(layout.count) 个尺寸）")
} catch {
    FileHandle.standardError.write(Data("写入失败：\(error)\n".utf8))
    exit(1)
}
