#!/bin/bash
# 用项目根目录的 title_icon.png 重新生成 Resources/AppIcon.icns
# 换了图标之后跑一次这个，再 ./build.sh 即可。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
SRC="${1:-$ROOT/title_icon.png}"
OUT="$ROOT/Resources/AppIcon.icns"

export TMPDIR="$BUILD/tmp"
mkdir -p "$TMPDIR" "$BUILD/mc" "$ROOT/Resources"

if [ ! -f "$SRC" ]; then
  echo "找不到源图：$SRC"
  echo "用法：$0 [源图.png]（默认用项目根目录的 title_icon.png）"
  exit 1
fi

ARCH="$(uname -m)"
echo "==> 编译图标工具"
swiftc -target "$ARCH-apple-macos13.0" \
  -Xfrontend -disable-sandbox \
  -module-cache-path "$BUILD/mc" \
  -o "$BUILD/make-icon" \
  "$ROOT/tools/make-icon.swift"

echo "==> 生成 icns（源图：${SRC}）"
"$BUILD/make-icon" "$SRC" "$OUT"

echo "==> 完成。重新构建 app 即可：./build.sh"
