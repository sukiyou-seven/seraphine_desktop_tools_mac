sera_begin memcached 1.6.45 /etc/systemd/system/sera-memcached.service
sera_packages gcc make libevent-devel
sera_stage '下载 Memcached 官方源码'
sera_download memcached-1.6.45.tar.gz https://memcached.org/files/memcached-1.6.45.tar.gz d362c64e6d8d5287153501eabf7c85b4a761432fbf53f5d7b085d0bb1653c1dd
sera_extract_tar
cd "$sera_work"
sera_stage '编译 Memcached'
./configure --prefix="$sera_prefix"
make -j1
sera_create_user seraphim-memcached
sera_create_prefix
make install
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim Memcached
After=network-online.target
[Service]
User=seraphim-memcached
Group=seraphim-memcached
ExecStart=/www/seraphim/server/memcached/bin/memcached -m 64 -l 127.0.0.1 -p 11211 -U 0 -vv
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
StandardOutput=append:/www/seraphim/logs/memcached.log
StandardError=append:/www/seraphim/logs/memcached.log
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/bin/memcached" -h | head -n 1
sera_commit
