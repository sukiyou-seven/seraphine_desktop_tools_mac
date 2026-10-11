#!/bin/bash
# 编译 Seraphim.app —— 双击 build/Seraphim.app 即可运行
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Seraphim.app"

export TMPDIR="$BUILD/tmp"
mkdir -p "$TMPDIR" "$BUILD/mc"

ARCH="$(uname -m)"
SOURCES=$(find "$ROOT/Sources" -name '*.swift' | sort)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift 源码（$(echo "$SOURCES" | wc -l | tr -d ' ') 个文件，目标 $ARCH-apple-macos13.0）"
# -disable-sandbox：@State 等 SwiftUI 宏需要运行 swift-plugin-server，
# 受限环境里嵌套 sandbox-exec 会失败，这里关掉插件沙箱（只编译本地源码）。
# shellcheck disable=SC2086
swiftc -O \
  -target "$ARCH-apple-macos13.0" \
  -module-name Seraphim \
  -Xfrontend -disable-sandbox \
  -module-cache-path "$BUILD/mc" \
  -o "$APP/Contents/MacOS/sera" \
  $SOURCES

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  echo "    已内置图标 AppIcon.icns"
fi

echo "==> 编译内置 Linux 服务端安装文件（amd64 / arm64）"
if ! command -v go >/dev/null 2>&1; then
  echo "错误：需要 Go 1.25 或更高版本来编译服务端安装文件" >&2
  exit 1
fi
for SERVER_ARCH in amd64 arm64; do
  (cd "$ROOT/server-status" && CGO_ENABLED=0 GOOS=linux GOARCH="$SERVER_ARCH" \
    go build -trimpath -ldflags='-s -w' -o "$APP/Contents/Resources/sera-linux-$SERVER_ARCH" .)
done

echo "==> ad-hoc 签名"
if codesign --force --sign - "$APP" 2>/dev/null; then
  echo "    已签名"
else
  echo "    跳过签名（不影响运行）"
fi

echo "==> 完成：$APP"
echo "    运行： open \"$APP\""
