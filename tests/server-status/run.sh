#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$ROOT/build"
swiftc "$ROOT/Sources/ServerManagement/ServerStatusAPI.swift" \
  "$ROOT/Sources/ServerManagement/ServerFileAPI.swift" \
  "$ROOT/Sources/ServerManagement/ServerServiceAPI.swift" \
  "$ROOT/Sources/ServerManagement/ServerSoftwareAPI.swift" "$ROOT/tests/server-status/main.swift" \
  -o "$ROOT/build/test-server-status-api"
"$ROOT/build/test-server-status-api"
