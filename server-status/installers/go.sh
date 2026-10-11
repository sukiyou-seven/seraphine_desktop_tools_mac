#!/bin/sh
set -eu

version=${SERA_SELECTED_VERSION:-1.27.1}
root=/www/seraphim
prefix=$root/server/go
case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo '当前架构暂不支持 Go 官方二进制包。' >&2; exit 1 ;;
esac
case "$version/$arch" in
    1.27.1/amd64) expected=63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445 ;;
    1.27.1/arm64) expected=3450b45a3f9ee8568792736a5c5e70a1f2e9b36c35a8f74958c03e51d7d92bec ;;
    1.26.2/amd64) expected=990e6b4bbba816dc3ee129eaeaf4b42f17c2800b88a2166c265ac1a200262282 ;;
    1.26.2/arm64) expected=c958a1fe1b361391db163a485e21f5f228142d6f8b584f6bef89b26f66dc5b23 ;;
    *) echo '不支持的 Go 版本' >&2; exit 1 ;;
esac
filename=go$version.linux-$arch.tar.gz
archive=$root/download/$filename
created=0
committed=0
cleanup() {
    if [ "$committed" -eq 0 ] && [ "$created" -eq 1 ]; then rm -rf "$prefix"; fi
}
trap cleanup EXIT

if [ -e "$prefix" ]; then
    echo 'Go 安装目录已存在，已停止以保护现有文件。' >&2
    exit 1
fi
install -d -m 0755 "$root/server" "$root/download"
echo 'SERA_STAGE:下载 Go 官方二进制包'
if [ ! -f "$archive" ]; then
    if ! command -v curl >/dev/null 2>&1; then sera_packages curl; fi
    curl --fail --location --show-error --silent --retry 3 --connect-timeout 15 --max-time 1800 \
        -o "$archive.part" "https://dl.google.com/go/$filename"
    mv "$archive.part" "$archive"
fi
echo "$expected  $archive" | sha256sum -c -
echo 'SERA_STAGE:安装 Go 到 /www/seraphim/server/go'
created=1
install -d -m 0755 "$prefix"
tar -xzf "$archive" -C "$prefix" --strip-components=1
"$prefix/bin/go" version
printf '%s\n' "$version" > "$prefix/.sera-installed"
committed=1
echo 'SERA_STAGE:Go 安装完成；使用 /www/seraphim/server/go/bin/go'
