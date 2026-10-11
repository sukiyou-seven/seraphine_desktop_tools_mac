sera_begin elasticsearch 9.5.5 /etc/systemd/system/sera-elasticsearch.service
test "$(uname -m)" = x86_64 || { echo '此 Elasticsearch 官方包仅支持 x86_64' >&2; exit 1; }
file=elasticsearch-9.5.5-linux-x86_64.tar.gz
sera_stage '下载 Elasticsearch 官方发布包'
sera_download512 "$file" "https://artifacts.elastic.co/downloads/elasticsearch/$file" 36bf5d6897faeda3743841dfaece365330bb41880f907e4c45958964dd2803617d503cba66e99686124899cff944c983b01a2e08eaebd8f54c26db02bf709ced
sera_create_user seraphim-elastic
sera_create_prefix
tar -xzf "$sera_archive" -C "$sera_prefix" --strip-components=1
chown -R seraphim-elastic:seraphim-elastic "$sera_prefix/config"
install -d -m 0750 -o seraphim-elastic -g seraphim-elastic "$sera_prefix/data" "$sera_root/logs/elasticsearch"
cat >> "$sera_prefix/config/elasticsearch.yml" <<'EOF'
cluster.name: seraphim
node.name: seraphim-single
discovery.type: single-node
network.host: 127.0.0.1
http.port: 9200
path.data: /www/seraphim/server/elasticsearch/data
path.logs: /www/seraphim/logs/elasticsearch
xpack.security.enabled: false
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim Elasticsearch
After=network-online.target
[Service]
User=seraphim-elastic
Group=seraphim-elastic
Environment="ES_JAVA_OPTS=-Xms512m -Xmx512m"
ExecStart=/www/seraphim/server/elasticsearch/bin/elasticsearch
Restart=on-failure
SuccessExitStatus=143
NoNewPrivileges=true
LimitNOFILE=65535
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=/www/seraphim/server/elasticsearch/config /www/seraphim/server/elasticsearch/data /www/seraphim/logs/elasticsearch
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/bin/elasticsearch" --version
sera_commit
