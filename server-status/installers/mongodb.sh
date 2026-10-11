sera_begin mongodb 8.2.12 /etc/systemd/system/sera-mongodb.service
test "$(uname -m)" = x86_64 || { echo '此 MongoDB 官方二进制包仅支持 x86_64' >&2; exit 1; }
sera_packages openssl libcurl cyrus-sasl-lib libatomic
file=mongodb-linux-x86_64-amazon2023-8.2.12.tgz
sera_stage '下载 MongoDB 官方二进制包'
sera_download "$file" "https://fastdl.mongodb.org/linux/$file" f4168d9d2058e4eb01b4e792bf3b305a06396dcb3c82cdf581333a2fc5e43df6
sera_create_user seraphim-mongodb
sera_create_prefix
tar -xzf "$sera_archive" -C "$sera_prefix" --strip-components=1
install -d -m 0700 -o seraphim-mongodb -g seraphim-mongodb "$sera_prefix/data"
install -d -m 0700 -o seraphim-mongodb -g seraphim-mongodb "$sera_prefix/run"
install -d -m 0700 -o seraphim-mongodb -g seraphim-mongodb "$sera_root/logs/mongodb"
cat > "$sera_prefix/mongod.conf" <<'EOF'
storage:
  dbPath: /www/seraphim/server/mongodb/data
systemLog:
  destination: file
  path: /www/seraphim/logs/mongodb/mongod.log
  logAppend: true
net:
  bindIp: 127.0.0.1
  port: 27018
  unixDomainSocket:
    pathPrefix: /www/seraphim/server/mongodb/run
processManagement:
  fork: false
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim MongoDB
After=network-online.target
[Service]
User=seraphim-mongodb
Group=seraphim-mongodb
ExecStart=/www/seraphim/server/mongodb/bin/mongod --config /www/seraphim/server/mongodb/mongod.conf
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/www/seraphim/server/mongodb/data /www/seraphim/server/mongodb/run /www/seraphim/logs/mongodb
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/bin/mongod" --version | head -n 1
sera_commit
