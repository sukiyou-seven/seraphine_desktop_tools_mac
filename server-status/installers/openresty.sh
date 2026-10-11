sera_begin openresty 1.31.1.1 /etc/systemd/system/sera-openresty.service
sera_packages gcc make pcre2-devel zlib-devel openssl-devel perl
sera_stage '下载 OpenResty 官方源码'
sera_download openresty-1.31.1.1.tar.gz https://openresty.org/download/openresty-1.31.1.1.tar.gz 65b78baadd3f0984055de89bf13f4a1932e5bfe9c31932037a134ea2b1a0ce42
sera_extract_tar
cd "$sera_work"
sera_stage '编译 OpenResty'
./configure --prefix="$sera_prefix" --with-http_ssl_module --with-http_v2_module --with-pcre-jit
make -j1
sera_create_prefix
make install
cat > "$sera_prefix/nginx/conf/nginx.conf" <<'EOF'
worker_processes 1;
pid /www/seraphim/server/openresty/nginx/logs/nginx.pid;
events { worker_connections 512; }
http {
    include mime.types;
    default_type application/octet-stream;
    access_log /www/seraphim/logs/openresty-access.log;
    error_log /www/seraphim/logs/openresty-error.log warn;
    include /www/seraphim/sites/openresty/*.conf;
    server {
        listen 8083;
        server_name _;
        root /www/seraphim/web;
        location / { try_files $uri $uri/ =404; }
    }
}
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim OpenResty
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/www/seraphim/server/openresty/nginx/sbin/nginx -c /www/seraphim/server/openresty/nginx/conf/nginx.conf -g 'daemon off;'
ExecReload=/www/seraphim/server/openresty/nginx/sbin/nginx -s reload
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/nginx/sbin/nginx" -t -c "$sera_prefix/nginx/conf/nginx.conf"
sera_commit
