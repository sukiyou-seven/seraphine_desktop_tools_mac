sera_begin grafana 13.2.3 /etc/systemd/system/sera-grafana.service
test "$(uname -m)" = x86_64 || { echo '此 Grafana 官方独立安装包仅支持 x86_64' >&2; exit 1; }
file=grafana-13.2.3.linux-amd64.tar.gz
sera_stage '下载 Grafana 官方独立安装包'
sera_download "$file" "https://dl.grafana.com/oss/release/$file" 6107ad27016296aac38e0d7ffa8753ab540b5541ad27e94790f771289d733235
sera_create_user seraphim-grafana
sera_create_prefix
tar -xzf "$sera_archive" -C "$sera_prefix" --strip-components=1
install -d -m 0750 -o seraphim-grafana -g seraphim-grafana "$sera_prefix/data" "$sera_prefix/plugins"
install -d -m 0750 -o seraphim-grafana -g seraphim-grafana "$sera_root/logs/grafana"
admin_password=$(openssl rand -hex 24)
umask 077
printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$admin_password" > "$sera_prefix/grafana.env"
printf '%s\n' "$admin_password" > "$sera_prefix/initial-admin-password"
chmod 0600 "$sera_prefix/grafana.env" "$sera_prefix/initial-admin-password"
umask 022
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim Grafana
After=network-online.target
[Service]
User=seraphim-grafana
Group=seraphim-grafana
WorkingDirectory=/www/seraphim/server/grafana
EnvironmentFile=/www/seraphim/server/grafana/grafana.env
Environment=GF_SERVER_HTTP_ADDR=127.0.0.1
Environment=GF_SERVER_HTTP_PORT=3000
Environment=GF_PATHS_DATA=/www/seraphim/server/grafana/data
Environment=GF_PATHS_LOGS=/www/seraphim/logs/grafana
Environment=GF_PATHS_PLUGINS=/www/seraphim/server/grafana/plugins
ExecStart=/www/seraphim/server/grafana/bin/grafana server --homepath=/www/seraphim/server/grafana
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/www/seraphim/server/grafana/data /www/seraphim/server/grafana/plugins /www/seraphim/logs/grafana
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/bin/grafana" --version
sera_commit
