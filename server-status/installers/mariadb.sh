sera_begin mariadb 11.8.9 /etc/systemd/system/sera-mariadb.service
test "$(uname -m)" = x86_64 || { echo '此 MariaDB 官方二进制包仅支持 x86_64' >&2; exit 1; }
sera_packages libaio libstdc++ ncurses
file=mariadb-11.8.9-linux-systemd-x86_64.tar.gz
sera_stage '下载 MariaDB 官方二进制包'
sera_download "$file" "https://archive.mariadb.org/mariadb-11.8.9/bintar-linux-systemd-x86_64/$file" 32f8871a2aa38b36aa418b7f4abc6fc0c6ef1ba5a45798cacb2afa52c8a6113b
sera_create_user seraphim-mariadb
sera_create_prefix
tar -xzf "$sera_archive" -C "$sera_prefix" --strip-components=1
sera_libaio_compat "$sera_prefix"
LD_LIBRARY_PATH="$sera_prefix/compat-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
install -d -m 0700 -o seraphim-mariadb -g seraphim-mariadb "$sera_prefix/data" "$sera_prefix/run"
cat > "$sera_prefix/my.cnf" <<'EOF'
[mysqld]
basedir=/www/seraphim/server/mariadb
datadir=/www/seraphim/server/mariadb/data
socket=/www/seraphim/server/mariadb/run/mariadb.sock
pid-file=/www/seraphim/server/mariadb/run/mariadb.pid
port=3307
bind-address=127.0.0.1
performance_schema=OFF
innodb_buffer_pool_size=128M
[client]
socket=/www/seraphim/server/mariadb/run/mariadb.sock
EOF
sera_stage '初始化 MariaDB 数据目录'
"$sera_prefix/scripts/mariadb-install-db" --no-defaults --user=seraphim-mariadb --basedir="$sera_prefix" --datadir="$sera_prefix/data" --auth-root-authentication-method=socket
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim MariaDB
After=network-online.target
[Service]
User=seraphim-mariadb
Group=seraphim-mariadb
Environment=LD_LIBRARY_PATH=/www/seraphim/server/mariadb/compat-lib
ExecStart=/www/seraphim/server/mariadb/bin/mariadbd --defaults-file=/www/seraphim/server/mariadb/my.cnf
Restart=on-failure
UMask=0077
LimitNOFILE=65535
StandardOutput=append:/www/seraphim/logs/mariadb.log
StandardError=append:/www/seraphim/logs/mariadb.log
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/bin/mariadbd" --version
sera_commit
