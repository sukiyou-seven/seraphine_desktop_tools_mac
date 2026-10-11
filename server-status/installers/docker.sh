sera_begin docker 29.8.2 /etc/systemd/system/sera-docker.service
test "$(uname -m)" = x86_64 || { echo '此 Docker 官方静态包仅支持 x86_64' >&2; exit 1; }
sera_packages iptables
file=docker-29.8.2.tgz
sera_stage '下载 Docker 官方静态发布包'
sera_download "$file" "https://download.docker.com/linux/static/stable/x86_64/$file" 995d1ef289677f74fd58d8d2c35727b6a4ee389c69db8638a3e42d0487aa5b0f
sera_create_prefix
install -d -m 0755 "$sera_prefix/bin"
install -d -m 0700 "$sera_prefix/data" "$sera_prefix/run"
tar -xzf "$sera_archive" -C "$sera_prefix/bin" --strip-components=1
cat > "$sera_prefix/daemon.json" <<'EOF'
{
  "data-root": "/www/seraphim/server/docker/data",
  "exec-root": "/www/seraphim/server/docker/run",
  "hosts": ["unix:///www/seraphim/server/docker/run/docker.sock"]
}
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim Docker Engine
After=network-online.target
Wants=network-online.target
[Service]
Type=notify
Environment=PATH=/www/seraphim/server/docker/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStart=/www/seraphim/server/docker/bin/dockerd --config-file=/www/seraphim/server/docker/daemon.json
Restart=on-failure
Delegate=yes
KillMode=process
LimitNOFILE=infinity
TasksMax=infinity
[Install]
WantedBy=multi-user.target
EOF
sera_commit
