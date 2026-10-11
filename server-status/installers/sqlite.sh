sera_begin sqlite 3.53.4
sera_packages gcc make readline-devel
sera_stage '下载 SQLite 官方源码'
sera_download sqlite-autoconf-3530400.tar.gz https://www.sqlite.org/2026/sqlite-autoconf-3530400.tar.gz 0e9483900e92cd5de8fd48d16bf9200145a61f7fd5be542a5ac81d8a9516eb9c
sera_extract_tar
cd "$sera_work"
sera_stage '编译 SQLite'
./configure --prefix="$sera_prefix"
make -j1
sera_create_prefix
make install
"$sera_prefix/bin/sqlite3" --version
sera_commit
