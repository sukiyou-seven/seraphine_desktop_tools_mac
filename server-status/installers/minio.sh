sera_begin minio RELEASE.2025-10-15T17-29-55Z /etc/systemd/system/sera-minio.service
sera_stage '下载 MinIO 官方源码'
sera_download minio-RELEASE.2025-10-15T17-29-55Z.tar.gz https://codeload.github.com/minio/minio/tar.gz/refs/tags/RELEASE.2025-10-15T17-29-55Z be6d0bd3696c3a13a35f02d3a0280b64319c67918b4501c5c3d87f96d000085c
sera_extract_tar
sera_create_user seraphim-minio
sera_create_prefix
sera_ensure_go
install -d -m 0755 "$sera_prefix/bin"
install -d -m 0750 -o seraphim-minio -g seraphim-minio "$sera_prefix/data"
sera_stage '编译 MinIO'
cd "$sera_work"
PATH="$sera_prefix/go/bin:$PATH" GOCACHE="$sera_work/go-cache" GOPATH="$sera_work/go-path" GOPROXY="$(sera_go_proxy)" GOMAXPROCS=2 CGO_ENABLED=0 \
    "$sera_prefix/go/bin/go" build -p 1 -trimpath -o "$sera_prefix/bin/minio" .
root_password=$(openssl rand -hex 24)
umask 077
printf 'MINIO_ROOT_USER=seraphim\nMINIO_ROOT_PASSWORD=%s\n' "$root_password" > "$sera_prefix/minio.env"
printf '%s\n' "$root_password" > "$sera_prefix/initial-root-password"
chmod 0600 "$sera_prefix/minio.env" "$sera_prefix/initial-root-password"
umask 022
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim MinIO
After=network-online.target
[Service]
User=seraphim-minio
Group=seraphim-minio
Environment=HOME=/www/seraphim/server/minio/data
EnvironmentFile=/www/seraphim/server/minio/minio.env
ExecStart=/www/seraphim/server/minio/bin/minio server /www/seraphim/server/minio/data --address 127.0.0.1:9000 --console-address 127.0.0.1:9001
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/www/seraphim/server/minio/data
StandardOutput=append:/www/seraphim/logs/minio.log
StandardError=append:/www/seraphim/logs/minio.log
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/bin/minio" --version
sera_commit
