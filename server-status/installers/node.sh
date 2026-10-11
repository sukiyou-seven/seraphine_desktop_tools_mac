#!/bin/sh
set -eu

version=${SERA_SELECTED_VERSION:-24.21.0}
root=/www/seraphim
prefix=$root/server/node
case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo '当前架构暂不支持 Node.js 官方二进制包。' >&2; exit 1 ;;
esac
case "$version/$arch" in
    24.21.0/x64) expected=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6 ;;
    24.21.0/arm64) expected=6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2 ;;
    22.23.3/x64) expected=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de ;;
    22.23.3/arm64) expected=a44aeb94849a299b22df10b9e622ec2f605c2183501bc40590705131de7c740f ;;
    *) echo '不支持的 Node.js 版本' >&2; exit 1 ;;
esac
filename=node-v$version-linux-$arch.tar.xz
archive=$root/download/$filename
created=0
committed=0
cleanup() {
    if [ "$committed" -eq 0 ] && [ "$created" -eq 1 ]; then rm -rf "$prefix"; fi
}
trap cleanup EXIT

if [ -e "$prefix" ]; then
    echo 'Node.js 安装目录已存在，已停止以保护现有文件。' >&2
    exit 1
fi
install -d -m 0755 "$root/server" "$root/download"
echo 'SERA_STAGE:下载 Node.js 官方二进制包'
if [ ! -f "$archive" ]; then
    if ! command -v curl >/dev/null 2>&1; then sera_packages curl; fi
    curl --fail --location --show-error --silent --retry 3 --connect-timeout 15 --max-time 1800 \
        -o "$archive.part" "https://nodejs.org/dist/v$version/$filename"
    mv "$archive.part" "$archive"
fi
echo "$expected  $archive" | sha256sum -c -
echo 'SERA_STAGE:安装 Node.js 到 /www/seraphim/server/node'
created=1
install -d -m 0755 "$prefix"
tar -xJf "$archive" -C "$prefix" --strip-components=1
"$prefix/bin/node" --version
"$prefix/bin/node" "$prefix/lib/node_modules/npm/bin/npm-cli.js" --version
printf '%s\n' "$version" > "$prefix/.sera-installed"
committed=1
echo 'SERA_STAGE:Node.js 安装完成；使用 /www/seraphim/server/node/bin/node 和 npm'
