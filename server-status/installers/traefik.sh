sera_begin traefik 3.7.14 /etc/systemd/system/sera-traefik.service
case "$(uname -m)" in
    x86_64) arch=amd64; sha=d08641f5de2dd3788097bddab1ce4b29c10a0b788566970db707fa5c94c71f15 ;;
    aarch64|arm64) arch=arm64; sha=e5a2d0620cecc01dbc3d8da739db0671fdc030ef1c3b2d90d54f3baaa25d85d3 ;;
    *) echo 'Traefik 不支持当前架构' >&2; exit 1 ;;
esac
file=traefik_v3.7.14_linux_${arch}.tar.gz
sera_stage '下载 Traefik 官方发布包'
sera_download "$file" "https://github.com/traefik/traefik/releases/download/v3.7.14/$file" "$sha"
sera_mkwork
tar -xzf "$sera_archive" -C "$sera_work" traefik
sera_create_user seraphim-traefik
sera_create_prefix
install -m 0755 "$sera_work/traefik" "$sera_prefix/traefik"
cat > "$sera_prefix/traefik.yml" <<'EOF'
entryPoints:
  web:
    address: ":8081"
providers:
  file:
    filename: /www/seraphim/server/traefik/dynamic.yml
api:
  dashboard: false
EOF
cat > "$sera_prefix/dynamic.yml" <<'EOF'
http:
  routers: {}
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim Traefik
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=seraphim-traefik
Group=seraphim-traefik
ExecStart=/www/seraphim/server/traefik/traefik --configFile=/www/seraphim/server/traefik/traefik.yml
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/traefik" version
sera_commit
