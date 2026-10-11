sera_begin pureftpd 1.0.54 /etc/systemd/system/sera-pureftpd.service
sera_packages gcc make openssl-devel
sera_stage '下载 Pure-FTPd 官方源码'
sera_download pure-ftpd-1.0.54.tar.gz https://download.pureftpd.org/pub/pure-ftpd/releases/pure-ftpd-1.0.54.tar.gz dc9140420ec44f7829579591ff378aa6396b4604b9c6aeae847368e0f35bd7b2
sera_extract_tar
cd "$sera_work"
sera_stage '编译 Pure-FTPd'
./configure --prefix="$sera_prefix" --with-tls --with-puredb --with-altlog
make -j1
sera_create_prefix
make install
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim Pure-FTPd
After=network-online.target
[Service]
Type=simple
ExecStart=/www/seraphim/server/pureftpd/sbin/pure-ftpd -l unix -E -A -S 127.0.0.1,2121 -O clf:/www/seraphim/logs/pureftpd.log
Restart=on-failure
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/sbin/pure-ftpd" --help >/dev/null 2>&1 || true
sera_commit
