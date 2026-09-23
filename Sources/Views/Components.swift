import SwiftUI
import AppKit

// MARK: - 状态点

struct StatusDot: View {
    var running: Bool
    var body: some View {
        Circle()
            .fill(running ? Color.green : Color.secondary.opacity(0.45))
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
    }
}

// MARK: - 卡片

struct Card<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.18)))
    }
}

// MARK: - 信息行

struct InfoRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(verbatim: value.isEmpty ? "—" : value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 只读文本块

struct ReadonlyText: View {
    var text: String
    var minHeight: CGFloat = 120

    var body: some View {
        ScrollView {
            Text(verbatim: text.isEmpty ? "（空）" : text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minHeight: minHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2)))
    }
}

// MARK: - 配置项编辑

struct ParamEditor: View {
    var row: ParamRow
    var onSave: (String) -> Void

    @State private var value: String

    init(row: ParamRow, onSave: @escaping (String) -> Void) {
        self.row = row
        self.onSave = onSave
        _value = State(initialValue: row.value)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(row.label)
                .font(.callout)
                .frame(width: 200, alignment: .leading)

            if row.options.isEmpty {
                TextField(row.placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                Button("保存") { onSave(value) }
                    .disabled(value == row.value)
            } else {
                // 布尔 / 枚举型：直接下拉选择，选完立即写回配置
                Picker("", selection: Binding(
                    get: { value },
                    set: { newValue in
                        value = newValue
                        onSave(newValue)
                    })) {
                        ForEach(row.options, id: \.value) { option in
                            Text(verbatim: option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                Text(verbatim: "选择后立即保存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: row.value) { newValue in
            value = newValue
        }
    }
}

// MARK: - 密码输入（可显示 / 生成 / 复制）

struct PasswordField: View {
    var label: String
    var placeholder = "密码"
    var labelWidth: CGFloat = 200
    @Binding var text: String

    @State private var revealed = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .frame(width: labelWidth, alignment: .leading)
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.callout, design: .monospaced))
            Button("生成") { text = PasswordGenerator.make() }
                .help("生成 20 位强密码：已排除难辨认（l/I/0/O）和会破坏连接串的字符")
            Button(revealed ? "隐藏" : "显示") { revealed.toggle() }
                .disabled(text.isEmpty)
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .disabled(text.isEmpty)
        }
    }
}

// MARK: - 顶部提示条

struct ToastBanner: View {
    var toast: Toast
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(toast.ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: toast.text)
                    .font(.callout)
                    .lineLimit(6)          // 长错误不撑爆界面（之前整页被盖住就是它惹的）
                    .fixedSize(horizontal: false, vertical: true)
                if !toast.detail.isEmpty {
                    // 限高 + 内部滚动：否则长内容会把整个界面盖住。
                    ScrollView {
                        Text(verbatim: toast.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(toast.ok ? Color.green.opacity(0.5) : Color.orange.opacity(0.6)))
        .frame(maxWidth: 680)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(14)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { onDismiss() }
        }
    }
}

// MARK: - 重置密码弹窗

/// 重置某个用户密码的弹窗：输入新密码，输入框后面的图标一键生成
struct PasswordResetSheet: View {
    @EnvironmentObject var model: AppModel
    var target: PasswordResetTarget

    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "重置密码")
                .font(.headline)
            Text(verbatim: "库：\(target.database)　用户：\(target.user)")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("输入新密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                Button {
                    password = PasswordGenerator.make()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("随机生成一个新密码")
            }

            Text(verbatim: "重置会用「设置」里的管理员凭据连接数据库；成功后新密码会记进工具，列表里可以直接复制。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消") { model.passwordResetTarget = nil }
                Button("重置密码") {
                    model.resetUserPassword(target: target, newPassword: password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - 可复制文本 / 密文单元格

/// 一行文本 + 复制按钮（用户名、连接串这类需要拿走的东西）
struct CopyableText: View {
    var text: String
    var monospaced = true

    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            if monospaced {
                Text(verbatim: text).font(.system(size: 12, design: .monospaced))
            } else {
                Text(verbatim: text).font(.caption)
            }
            Button(copied ? "已复制" : "复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .disabled(text.isEmpty)
        }
    }
}

/// 密码单元格：默认打码，可显示明文、可复制
struct SecretCell: View {
    var secret: String

    @State private var revealed = false
    @State private var copied = false

    private var masked: String {
        String(repeating: "•", count: min(12, max(6, secret.count)))
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: revealed ? secret : masked)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Button(revealed ? "隐藏" : "显示") { revealed.toggle() }
                .buttonStyle(.borderless)
                .font(.caption2)
                .disabled(secret.isEmpty)
            Button(copied ? "已复制" : "复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(secret, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .disabled(secret.isEmpty)
        }
    }
}

// MARK: - 占用条

/// 一条横向占用条，用于磁盘 / CPU / 内存（占用越高颜色越警示：绿 → 橙 → 红）
struct UsageBar: View {
    var label: String
    var detail: String
    var fraction: Double

    private var barColor: Color {
        if fraction >= 0.9 { return .red }
        if fraction >= 0.7 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: label)
                .font(.caption)
                .frame(width: 62, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(barColor)
                        .frame(width: max(geo.size.width * min(max(fraction, 0), 1),
                                          fraction > 0 ? 4 : 0))
                }
            }
            .frame(height: 13)
            Text(verbatim: String(format: "%.1f%%", fraction * 100))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(barColor)
                .frame(width: 54, alignment: .trailing)
            Text(verbatim: detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
        }
    }
}

// MARK: - 空状态

struct EmptyHint: View {
    var text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
