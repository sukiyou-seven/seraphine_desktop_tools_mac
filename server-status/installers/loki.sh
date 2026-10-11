sera_begin loki 3.7.8 /etc/systemd/system/sera-loki.service
sera_packages unzip
case "$(uname -m)" in
    x86_64) arch=amd64; sha=62aea42c9cba52cd1642b3666ab37019a0ce4c24ab50b07e85dccc8d812f7d61 ;;
    aarch64|arm64) arch=arm64; sha=a874c10ffefe4d66c914b8aac8897159451d3026469598341aa03c76084697de ;;
    *) echo 'Loki 不支持当前架构' >&2; exit 1 ;;
esac
file=loki-linux-$arch.zip
sera_stage '下载 Loki 官方发布包'
sera_download "loki-3.7.8-$file" "https://github.com/grafana/loki/releases/download/v3.7.8/$file" "$sha"
sera_mkwork
unzip -q "$sera_archive" -d "$sera_work"
sera_create_user seraphim-loki
sera_create_prefix
install -m 0755 "$sera_work/loki-linux-$arch" "$sera_prefix/loki"
install -d -m 0750 -o seraphim-loki -g seraphim-loki "$sera_prefix/data"
cat > "$sera_prefix/loki.yml" <<'EOF'
auth_enabled: false
server:
  http_listen_address: 127.0.0.1
  http_listen_port: 3100
common:
  path_prefix: /www/seraphim/server/loki/data
  storage:
    filesystem:
      chunks_directory: /www/seraphim/server/loki/data/chunks
      rules_directory: /www/seraphim/server/loki/data/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2024-04-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
limits_config:
  allow_structured_metadata: true
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim Loki
After=network-online.target
Wants=network-online.target
[Service]
User=seraphim-loki
Group=seraphim-loki
ExecStart=/www/seraphim/server/loki/loki -config.file=/www/seraphim/server/loki/loki.yml
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/www/seraphim/server/loki/data
StandardOutput=append:/www/seraphim/logs/loki.log
StandardError=append:/www/seraphim/logs/loki.log
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/loki" -version
sera_commit
