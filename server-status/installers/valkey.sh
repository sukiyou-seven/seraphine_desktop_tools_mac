sera_begin valkey 9.1.2 /etc/systemd/system/sera-valkey.service
sera_packages gcc make openssl-devel
sera_stage '下载 Valkey 官方源码'
sera_download valkey-9.1.2.tar.gz https://codeload.github.com/valkey-io/valkey/tar.gz/refs/tags/9.1.2 19c23908e7d57e8d91ef85b41f5646307582f10f4f0fb999bbf89ed24ec9c983
sera_extract_tar
cd "$sera_work"
sera_stage '编译 Valkey'
make -j1 BUILD_TLS=yes
sera_create_user seraphim-valkey
sera_create_prefix
make PREFIX="$sera_prefix" install
install -d -m 0700 -o seraphim-valkey -g seraphim-valkey "$sera_prefix/data"
install -m 0600 -o seraphim-valkey -g seraphim-valkey /dev/null "$sera_prefix/data/users.acl"
printf '%s\n' 'user default on nopass ~* &* +@all' > "$sera_prefix/data/users.acl"
cat > "$sera_prefix/valkey.conf" <<'EOF'
bind 127.0.0.1
protected-mode yes
port 6380
daemonize no
dir /www/seraphim/server/valkey/data
appendonly yes
logfile ""
aclfile /www/seraphim/server/valkey/data/users.acl
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim Valkey
After=network-online.target
[Service]
User=seraphim-valkey
Group=seraphim-valkey
ExecStart=/www/seraphim/server/valkey/bin/valkey-server /www/seraphim/server/valkey/valkey.conf
Restart=on-failure
UMask=0077
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/www/seraphim/server/valkey/data
StandardOutput=append:/www/seraphim/logs/valkey.log
StandardError=append:/www/seraphim/logs/valkey.log
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/bin/valkey-server" --version
sera_commit
