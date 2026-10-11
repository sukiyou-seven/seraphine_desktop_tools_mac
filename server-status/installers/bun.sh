version=${SERA_SELECTED_VERSION:-1.4.2}
case "$version" in
    1.4.2|1.3.13) ;;
    *) echo '不支持的 Bun 版本' >&2; exit 1 ;;
esac
sera_begin bun "$version"
sera_packages unzip
case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo 'Bun 不支持当前架构' >&2; exit 1 ;;
esac
case "$version/$arch" in
    1.4.2/x64) sha=36368faef7527875d5ffa52e53cd48021741f2a83eb6208a8dd64068d422a913 ;;
    1.4.2/aarch64) sha=54328bbc2d9c8e0c9f892c544d66c57a83b84139e34909e5ee81758f1ac8fda7 ;;
    1.3.13/x64) sha=79c0771fa8b92c33aae41e15a0e0d307ea99d0e2f00317c71c6c53237a78e25a ;;
    1.3.13/aarch64) sha=70bae41b3908b0a120e1e58c5c8af30e74afae3b8d11b0d3fdd8e787ddfb4b22 ;;
esac
file=bun-linux-${arch}.zip
sera_stage '下载 Bun 官方发布包'
sera_download "bun-$version-$file" "https://github.com/oven-sh/bun/releases/download/bun-v$version/$file" "$sha"
sera_mkwork
unzip -q "$sera_archive" -d "$sera_work"
sera_create_prefix
install -d -m 0755 "$sera_prefix/bin"
install -m 0755 "$sera_work/bun-linux-$arch/bun" "$sera_prefix/bin/bun"
"$sera_prefix/bin/bun" --version
sera_commit
