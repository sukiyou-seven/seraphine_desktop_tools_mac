#!/bin/bash
# 核心逻辑自测：不需要本机安装 MongoDB / Redis（Redis 用进程内的假服务器）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
WORK="$BUILD/selftest-work"

export TMPDIR="$BUILD/tmp"
mkdir -p "$TMPDIR" "$BUILD/mc"
rm -rf "$WORK"
mkdir -p "$WORK"

ARCH="$(uname -m)"
CORE=(
  "$ROOT/Sources/Support.swift"
  "$ROOT/Sources/Diagnostics.swift"
  "$ROOT/Sources/ConfStore.swift"
  "$ROOT/Sources/RedisClient.swift"
  "$ROOT/Sources/Settings.swift"
  "$ROOT/Sources/MongoService.swift"
  "$ROOT/Sources/RedisService.swift"
  "$ROOT/Sources/MySQLService.swift"
  "$ROOT/Sources/ACMEService.swift"
  "$ROOT/Sources/ProjectService.swift"
  "$ROOT/Sources/PythonEnvironmentService.swift"
  "$ROOT/Sources/HomeLogCleanup.swift"
  "$ROOT/Sources/DNSService.swift"
  "$ROOT/Sources/ClipboardHistory.swift"
  "$ROOT/Sources/SystemNotice.swift"
  "$ROOT/Sources/AIDevService.swift"
  "$ROOT/Sources/AIReviewService.swift"
  "$ROOT/Sources/AICloudService.swift"
  "$ROOT/tests/FakeRedis.swift"
  "$ROOT/tests/main.swift"
)

echo "==> 编译自测程序"
swiftc -target "$ARCH-apple-macos13.0" \
  -Xfrontend -disable-sandbox \
  -module-cache-path "$BUILD/mc" \
  -o "$BUILD/selftest" \
  "${CORE[@]}"

echo "==> 运行自测"
"$BUILD/selftest" "$WORK"
