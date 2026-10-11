sera_begin rabbitmq 4.3.6 /etc/systemd/system/sera-rabbitmq.service
sera_packages gcc gcc-c++ make ncurses-devel openssl-devel autoconf
sera_stage '下载 Erlang/OTP 官方源码'
sera_download otp-28.5.tar.gz https://codeload.github.com/erlang/otp/tar.gz/refs/tags/OTP-28.5 7d0a43be4ee5c3965509c0c20cf0b28afa0ab9573f0cc49631f2858165335a5a
sera_extract_tar
sera_create_user seraphim-rabbitmq
sera_create_prefix
cd "$sera_work"
sera_stage '编译 RabbitMQ 所需 Erlang/OTP'
./configure --prefix="$sera_prefix/erlang" --without-javac --without-wx --without-debugger --without-observer --without-et
make -j1
make install
file=rabbitmq-server-generic-unix-4.3.6.tar.xz
sera_stage '下载 RabbitMQ 官方发布包'
sera_download "$file" "https://github.com/rabbitmq/rabbitmq-server/releases/download/v4.3.6/$file" aa0ff5de9ff0136dc42eba21dc3a973cc3b286437cdba0f45556e890509c1614
install -d -m 0755 "$sera_prefix/rabbitmq"
tar -xJf "$sera_archive" -C "$sera_prefix/rabbitmq" --strip-components=1
install -d -m 0700 -o seraphim-rabbitmq -g seraphim-rabbitmq "$sera_prefix/data"
install -d -m 0700 -o seraphim-rabbitmq -g seraphim-rabbitmq "$sera_prefix/data/mnesia"
install -d -m 0700 -o seraphim-rabbitmq -g seraphim-rabbitmq "$sera_root/logs/rabbitmq"
umask 077
openssl rand -hex 32 > "$sera_prefix/data/.erlang.cookie"
chown seraphim-rabbitmq:seraphim-rabbitmq "$sera_prefix/data/.erlang.cookie"
chmod 0400 "$sera_prefix/data/.erlang.cookie"
umask 022
cat > "$sera_prefix/rabbitmq.conf" <<'EOF'
listeners.tcp.1 = 127.0.0.1:5672
loopback_users.guest = true
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim RabbitMQ
After=network-online.target
[Service]
User=seraphim-rabbitmq
Group=seraphim-rabbitmq
WorkingDirectory=/www/seraphim/server/rabbitmq/data
Environment=HOME=/www/seraphim/server/rabbitmq/data
Environment=PATH=/www/seraphim/server/rabbitmq/erlang/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
Environment=RABBITMQ_BASE=/www/seraphim/server/rabbitmq/data
Environment=RABBITMQ_MNESIA_BASE=/www/seraphim/server/rabbitmq/data/mnesia
Environment=RABBITMQ_CONFIG_FILE=/www/seraphim/server/rabbitmq/rabbitmq.conf
Environment=RABBITMQ_LOG_BASE=/www/seraphim/logs/rabbitmq
ExecStart=/www/seraphim/server/rabbitmq/rabbitmq/sbin/rabbitmq-server
Restart=on-failure
NoNewPrivileges=true
LimitNOFILE=65535
ProtectSystem=strict
ReadWritePaths=/www/seraphim/server/rabbitmq/data /www/seraphim/logs/rabbitmq
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/erlang/bin/erl" -noshell -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().'
sera_commit
