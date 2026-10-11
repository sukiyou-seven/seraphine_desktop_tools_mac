sera_begin prometheus 3.15.0 /etc/systemd/system/sera-prometheus.service
case "$(uname -m)" in
    x86_64) arch=amd64; sha=2a542df32eac02ee17b9d844fb2aa1de00dafa5476579ba8a3ba862e9d572ea0 ;;
    aarch64|arm64) arch=arm64; sha=f1f90ec08e849d494ca66c611470afc50192f0355f1a61c33f2cbde02d067823 ;;
    *) echo 'Prometheus 不支持当前架构' >&2; exit 1 ;;
esac
file=prometheus-3.15.0.linux-$arch.tar.gz
sera_stage '下载 Prometheus 官方发布包'
sera_download "$file" "https://github.com/prometheus/prometheus/releases/download/v3.15.0/$file" "$sha"
sera_mkwork
tar -xzf "$sera_archive" -C "$sera_work"
sera_create_user seraphim-prometheus
sera_create_prefix
install -m 0755 "$sera_work/prometheus-3.15.0.linux-$arch/prometheus" "$sera_prefix/prometheus"
install -m 0644 "$sera_work/prometheus-3.15.0.linux-$arch/promtool" "$sera_prefix/promtool"
chmod 0755 "$sera_prefix/promtool"
install -d -m 0750 -o seraphim-prometheus -g seraphim-prometheus "$sera_prefix/data"
cat > "$sera_prefix/prometheus.yml" <<'EOF'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['127.0.0.1:9090']
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim Prometheus
After=network-online.target
Wants=network-online.target
[Service]
User=seraphim-prometheus
Group=seraphim-prometheus
ExecStart=/www/seraphim/server/prometheus/prometheus --config.file=/www/seraphim/server/prometheus/prometheus.yml --storage.tsdb.path=/www/seraphim/server/prometheus/data --web.listen-address=127.0.0.1:9090
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/www/seraphim/server/prometheus/data
StandardOutput=append:/www/seraphim/logs/prometheus.log
StandardError=append:/www/seraphim/logs/prometheus.log
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/promtool" check config "$sera_prefix/prometheus.yml"
sera_commit
