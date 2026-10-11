version=${SERA_SELECTED_VERSION:-3.14.8}
case "$version" in
    3.14.8) sha=c2215904f02b175596dc49351585104f4bc20341e1c47378b26a2c274360ce73 ;;
    3.13.16) sha=f4b1bfb3c79b5bb11b8d228a12504163b4c0dab4d679828d8f5f26b6cb6ab35d ;;
    *) echo '不支持的 Python 版本' >&2; exit 1 ;;
esac
sera_begin python "$version"
sera_packages gcc make zlib-devel openssl-devel bzip2-devel libffi-devel xz-devel sqlite-devel readline-devel
sera_stage '下载 Python 官方源码'
sera_download "Python-$version.tar.xz" "https://www.python.org/ftp/python/$version/Python-$version.tar.xz" "$sha"
sera_extract_tar
cd "$sera_work"
sera_stage '编译 Python'
./configure --prefix="$sera_prefix" --with-ensurepip=install
make -j1
sera_create_prefix
make install
"$sera_prefix/bin/python3" --version
"$sera_prefix/bin/python3" -m pip --version
sera_commit
