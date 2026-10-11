version=${SERA_SELECTED_VERSION:-4.0.7}
case "$version" in
    4.0.7) sha=911ace20f90d068ca0e4dda6d0e4f0f81e52e52f2dd4f4004c721e253412e82d ;;
    3.4.11) sha=5c22be44524312b3d433d68739bcc530633b1da5ef8ba0afa0a37680da17d3de ;;
    *) echo '不支持的 Ruby 版本' >&2; exit 1 ;;
esac
sera_begin ruby "$version"
sera_packages gcc make openssl-devel readline-devel zlib-devel libyaml-devel gdbm-devel
sera_stage '下载 Ruby 官方源码'
sera_download "ruby-$version.tar.gz" "https://cache.ruby-lang.org/pub/ruby/${version%.*}/ruby-$version.tar.gz" "$sha"
sera_extract_tar
cd "$sera_work"
sera_stage '编译 Ruby'
./configure --prefix="$sera_prefix" --disable-install-doc
make -j1
sera_create_prefix
make install
"$sera_prefix/bin/ruby" --version
sera_commit
