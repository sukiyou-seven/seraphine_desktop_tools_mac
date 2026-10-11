sera_begin postgresql 18.6 /etc/systemd/system/sera-postgresql.service
sera_packages gcc make bison flex readline-devel zlib-devel openssl-devel libicu-devel bzip2
sera_stage '下载 PostgreSQL 官方源码'
sera_download postgresql-18.6.tar.bz2 https://ftp.postgresql.org/pub/source/v18.6/postgresql-18.6.tar.bz2 555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f
sera_extract_tar
cd "$sera_work"
sera_stage '编译 PostgreSQL'
./configure --prefix="$sera_prefix" --with-openssl
make -j1
sera_create_user seraphim-postgres
sera_create_prefix
make install
install -d -m 0700 -o seraphim-postgres -g seraphim-postgres "$sera_prefix/data"
install -d -m 0775 -o seraphim-postgres -g seraphim-postgres "$sera_prefix/run"
runuser -u seraphim-postgres -- "$sera_prefix/bin/initdb" -D "$sera_prefix/data" --auth-local=peer --auth-host=reject --no-instructions
cat > "$sera_prefix/data/pg_hba.conf" <<'EOF'
# Seraphim local password access
local all seraphim-postgres peer
local all all scram-sha-256
host all all 127.0.0.1/32 scram-sha-256
host all all ::1/128 scram-sha-256
EOF
chown seraphim-postgres:seraphim-postgres "$sera_prefix/data/pg_hba.conf"
chmod 0600 "$sera_prefix/data/pg_hba.conf"
cat >> "$sera_prefix/data/postgresql.conf" <<'EOF'
listen_addresses = '127.0.0.1'
unix_socket_directories = '/www/seraphim/server/postgresql/run'
password_encryption = 'scram-sha-256'
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim PostgreSQL
After=network-online.target
[Service]
Type=simple
User=seraphim-postgres
Group=seraphim-postgres
ExecStart=/www/seraphim/server/postgresql/bin/postgres -D /www/seraphim/server/postgresql/data
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/www/seraphim/server/postgresql/data /www/seraphim/server/postgresql/run
StandardOutput=append:/www/seraphim/logs/postgresql.log
StandardError=append:/www/seraphim/logs/postgresql.log
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/bin/postgres" --version
sera_commit
