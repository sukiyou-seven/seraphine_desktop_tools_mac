sera_begin caddy 2.11.7 /etc/systemd/system/sera-caddy.service
case "$(uname -m)" in
    x86_64) arch=amd64; sha=727b91701a392de6ebc5027509f548bf39979e5216340d0faed8fa5e69c84f8b ;;
    aarch64|arm64) arch=arm64; sha=d8fc6d179a5d283028a472a5618564f6ad8a86fed513e64f032b3b0b7cc45e42 ;;
    *) echo 'Caddy 不支持当前架构' >&2; exit 1 ;;
esac
file=caddy_2.11.7_linux_${arch}.tar.gz
sera_stage '下载 Caddy 官方发布包'
sera_download "$file" "https://github.com/caddyserver/caddy/releases/download/v2.11.7/$file" "$sha"
sera_mkwork
tar -xzf "$sera_archive" -C "$sera_work" caddy
sera_create_user seraphim-caddy
sera_create_prefix
install -d -m 0750 -o seraphim-caddy -g seraphim-caddy "$sera_prefix/data"
install -m 0755 "$sera_work/caddy" "$sera_prefix/caddy"
cat > "$sera_prefix/Caddyfile" <<'EOF'
:8080 {
    root * /www/seraphim/web
    file_server
}
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim Caddy
After=network-online.target
Wants=network-online.target
[Service]
Type=notify
User=seraphim-caddy
Group=seraphim-caddy
Environment=XDG_DATA_HOME=/www/seraphim/server/caddy/data
Environment=XDG_CONFIG_HOME=/www/seraphim/server/caddy/data
ExecStart=/www/seraphim/server/caddy/caddy run --environ --config /www/seraphim/server/caddy/Caddyfile
ExecReload=/www/seraphim/server/caddy/caddy reload --config /www/seraphim/server/caddy/Caddyfile --force
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/www/seraphim/server/caddy/data
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/caddy" version
sera_commit
