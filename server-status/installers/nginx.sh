#!/bin/sh
set -eu

version=1.30.5
sera_id=nginx
root=/www/seraphim
prefix=$root/server/nginx
archive=$root/download/nginx-$version.tar.gz
work=
committed=0
created=0
cleanup() {
    if [ -n "$work" ]; then rm -rf "$work"; fi
    if [ "$committed" -eq 0 ] && [ "$created" -eq 1 ]; then
        rm -rf "$prefix" /etc/systemd/system/sera-nginx.service
        systemctl daemon-reload || true
    fi
}
trap cleanup EXIT

if [ -e "$prefix" ] || [ -e /etc/systemd/system/sera-nginx.service ]; then
    echo 'Nginx 安装目录或服务单元已存在，已停止以保护现有配置。' >&2
    exit 1
fi
install -d -m 0755 "$root/server" "$root/download" "$root/web"
install -d -m 0700 "$root/tmp"
install -d -m 0750 "$root/logs"

echo 'SERA_STAGE:安装 Nginx 编译依赖'
sera_packages gcc make pcre2-devel zlib-devel openssl-devel

echo 'SERA_STAGE:下载 Nginx 官方源码'
if [ ! -f "$archive" ]; then
    if ! command -v curl >/dev/null 2>&1; then sera_packages curl; fi
    curl --fail --location --show-error --silent --retry 3 --connect-timeout 15 --max-time 1200 \
        -o "$archive.part" "https://nginx.org/download/nginx-$version.tar.gz"
    mv "$archive.part" "$archive"
fi
echo '6c20565aa2325cb82216ae804f4a4ff1875179014759a381c42ddc8e11c4906d  '"$archive" | sha256sum -c -

work=$(mktemp -d "$root/tmp/nginx-install.XXXXXX")
tar -xzf "$archive" -C "$work" --strip-components=1
echo 'SERA_STAGE:编译 Nginx（单线程）'
cd "$work"
./configure --prefix="$prefix" --sbin-path="$prefix/sbin/nginx" \
    --conf-path="$prefix/conf/nginx.conf" --pid-path="$prefix/run/nginx.pid" \
    --error-log-path="$root/logs/nginx-error.log" --http-log-path="$root/logs/nginx-access.log" \
    --with-http_ssl_module --with-http_v2_module --with-stream
make -j1
echo 'SERA_STAGE:安装 Nginx 到 /www/seraphim/server/nginx'
# 面板只有两种身份：root 做需要特权的事，sera 跑一切业务进程（Web worker、PHP、项目）。
# worker 以 sera 运行，因此读得到归 sera 所有的站点目录。
sera_create_user sera
created=1
make install
install -d -m 0755 "$prefix/run" "$root/web"
cat > "$prefix/conf/nginx.conf" <<'CONFIG'
user sera;
worker_processes  1;
pid /www/seraphim/server/nginx/run/nginx.pid;
error_log /www/seraphim/logs/nginx-error.log warn;
events { worker_connections 512; }
http {
    include /www/seraphim/server/nginx/conf/mime.types;
    default_type application/octet-stream;
    access_log /www/seraphim/logs/nginx-access.log;
    sendfile on;
    keepalive_timeout 65;
    include /www/seraphim/sites/nginx/*.conf;
    server {
        listen 80;
        server_name _;
        root /www/seraphim/web;
        index index.html;
        location / { try_files $uri $uri/ =404; }
    }
}
CONFIG
"$prefix/sbin/nginx" -t -c "$prefix/conf/nginx.conf"
cat > /etc/systemd/system/sera-nginx.service <<'UNIT'
[Unit]
Description=Seraphim Nginx web server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/www/seraphim/server/nginx/sbin/nginx -c /www/seraphim/server/nginx/conf/nginx.conf -g "daemon off;"
ExecReload=/www/seraphim/server/nginx/sbin/nginx -c /www/seraphim/server/nginx/conf/nginx.conf -s reload
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
printf '%s\n' "$version" > "$prefix/.sera-installed"
committed=1
echo 'SERA_STAGE:Nginx 安装完成，可在软件商店中启动'
