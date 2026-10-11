version=${SERA_SELECTED_VERSION:-2.9.7}
case "$version" in
    2.9.7|2.8.0) ;;
    *) echo '不支持的 Deno 版本' >&2; exit 1 ;;
esac
sera_begin deno "$version"
sera_packages unzip
case "$(uname -m)" in
    x86_64) target=x86_64-unknown-linux-gnu ;;
    aarch64|arm64) target=aarch64-unknown-linux-gnu ;;
    *) echo 'Deno 不支持当前架构' >&2; exit 1 ;;
esac
case "$version/$target" in
    2.9.7/x86_64-unknown-linux-gnu) sha=c6527f24f4b16031d3ae4fa9f658d5f11534c8d84ce7dc8502420280919c3490 ;;
    2.9.7/aarch64-unknown-linux-gnu) sha=c832298b1ad4422481334855f6003e0f54145762c5a134f20a489511d2f65bbf ;;
    2.8.0/x86_64-unknown-linux-gnu) sha=be2c8b53c8ca1d66be76feb9b1a524419da708b00d4ca074cf5c633c81c1627b ;;
    2.8.0/aarch64-unknown-linux-gnu) sha=933a6a7d2985957271cd2085a5a5a1832398aa221a354daab5635196cf2cbbae ;;
esac
file=deno-$target.zip
sera_stage '下载 Deno 官方发布包'
sera_download "deno-$version-$file" "https://github.com/denoland/deno/releases/download/v$version/$file" "$sha"
sera_mkwork
unzip -q "$sera_archive" -d "$sera_work"
sera_create_prefix
install -d -m 0755 "$sera_prefix/bin"
install -m 0755 "$sera_work/deno" "$sera_prefix/bin/deno"
"$sera_prefix/bin/deno" --version
sera_commit
