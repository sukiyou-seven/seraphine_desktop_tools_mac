sera_begin opensearch 3.9.0 /etc/systemd/system/sera-opensearch.service
test "$(uname -m)" = x86_64 || { echo '此 OpenSearch 官方包仅支持 x86_64' >&2; exit 1; }
file=opensearch-3.9.0-linux-x64.tar.gz
sera_stage '下载 OpenSearch 官方发布包'
sera_download512 "$file" "https://artifacts.opensearch.org/releases/bundle/opensearch/3.9.0/$file" a70e52a93ad66d9497dd734f5cc48eb4a8a8c4a92c47491a7ad0f1a898383d11c2948d4ba4159b2361d961bf221efa0fd02084e6389532df960b1ebe0c0a2099
sera_create_user seraphim-opensearch
sera_create_prefix
tar -xzf "$sera_archive" -C "$sera_prefix" --strip-components=1
chown -R seraphim-opensearch:seraphim-opensearch "$sera_prefix/config"
install -d -m 0750 -o seraphim-opensearch -g seraphim-opensearch "$sera_prefix/data" "$sera_root/logs/opensearch"
sed -i "s#logs/#$sera_root/logs/opensearch/#g" "$sera_prefix/config/jvm.options"
cat >> "$sera_prefix/config/opensearch.yml" <<'EOF'
cluster.name: seraphim
node.name: seraphim-single
discovery.type: single-node
network.host: 127.0.0.1
http.port: 9201
path.data: /www/seraphim/server/opensearch/data
path.logs: /www/seraphim/logs/opensearch
plugins.security.disabled: true
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim OpenSearch
After=network-online.target
[Service]
User=seraphim-opensearch
Group=seraphim-opensearch
Environment="OPENSEARCH_JAVA_OPTS=-Xms512m -Xmx512m"
ExecStart=/www/seraphim/server/opensearch/bin/opensearch
Restart=on-failure
SuccessExitStatus=143
NoNewPrivileges=true
LimitNOFILE=65535
ProtectSystem=strict
PrivateTmp=true
ReadWritePaths=/www/seraphim/server/opensearch/config /www/seraphim/server/opensearch/data /www/seraphim/logs/opensearch
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/bin/opensearch" --version
sera_commit
