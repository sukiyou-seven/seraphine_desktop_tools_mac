#!/bin/sh
set -eu

version=${SERA_SELECTED_VERSION:-8.4.26}
case "$version" in
    8.4.26) expected=32a2de53862ad44ed4a5005244ce4f1b50c271e74dced215449a4443b40569f1 ;;
    8.3.32) expected=8698ec1f9402fa5e5e872ae3d0916b62f5f27503c1fbfc9cc3521e113355ea92 ;;
    *) echo '不支持的 PHP 版本' >&2; exit 1 ;;
esac
sera_id=php
root=/www/seraphim
prefix=$root/server/php
archive=$root/download/php-$version.tar.xz
unit=/etc/systemd/system/sera-php.service
work=
created=0
committed=0
cleanup() {
    if [ -n "$work" ]; then rm -rf "$work"; fi
    if [ "$committed" -eq 0 ] && [ "$created" -eq 1 ]; then
        rm -rf "$prefix" "$unit"
        systemctl daemon-reload || true
    fi
}
trap cleanup EXIT

if [ -e "$prefix" ] || [ -e "$unit" ]; then
    echo 'PHP 安装目录或服务单元已存在，已停止以保护现有配置。' >&2
    exit 1
fi
install -d -m 0755 "$root/server" "$root/download" "$root/web"
install -d -m 0700 "$root/tmp"
install -d -m 0711 "$root/logs"

echo 'SERA_STAGE:安装 PHP 编译依赖'
sera_packages \
    gcc make pkgconf-pkg-config libxml2-devel sqlite-devel oniguruma-devel \
    openssl-devel libcurl-devel zlib-devel
if ! getent group seraphim-web >/dev/null 2>&1; then
    groupadd --system seraphim-web
fi
if ! id -u seraphim-web >/dev/null 2>&1; then
    useradd --system --no-create-home --gid seraphim-web --shell /sbin/nologin seraphim-web
fi

echo 'SERA_STAGE:下载 PHP 官方源码'
if [ ! -f "$archive" ]; then
    curl --fail --location --show-error --silent --retry 3 --connect-timeout 15 --max-time 1800 \
        -o "$archive.part" "https://www.php.net/distributions/php-$version.tar.xz"
    mv "$archive.part" "$archive"
fi
echo "$expected  $archive" | sha256sum -c -

work=$(mktemp -d "$root/tmp/php-install.XXXXXX")
tar -xJf "$archive" -C "$work" --strip-components=1
echo 'SERA_STAGE:配置 PHP-FPM 与常用扩展'
cd "$work"
./configure --prefix="$prefix" \
    --with-config-file-path="$prefix/etc" \
    --with-config-file-scan-dir="$prefix/etc/conf.d" \
    --enable-fpm --enable-opcache --enable-mbstring --enable-exif \
    --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd \
    --with-curl --with-openssl --with-zlib \
    --disable-phpdbg --disable-cgi --without-pear
echo 'SERA_STAGE:编译 PHP（单线程）'
make -j1
echo 'SERA_STAGE:安装 PHP 到 /www/seraphim/server/php'
created=1
make install
find "$prefix" -type d -exec chmod 0755 {} +
chmod 0755 "$prefix/bin/php" "$prefix/sbin/php-fpm"
install -d -m 0755 "$prefix/etc" "$prefix/etc/conf.d"
install -d -m 0700 -o seraphim-web -g seraphim-web "$prefix/run" "$root/logs/php"
cp php.ini-production "$prefix/etc/php.ini"
cat >> "$prefix/etc/php.ini" <<'CONFIG'

memory_limit = 128M
date.timezone = UTC
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 64
zend_extension = opcache
CONFIG
cat > "$prefix/etc/php-fpm.conf" <<'CONFIG'
[global]
pid = /www/seraphim/server/php/run/php-fpm.pid
error_log = /www/seraphim/logs/php/php-fpm.log
daemonize = no

[www]
user = seraphim-web
group = seraphim-web
listen = 127.0.0.1:9000
pm = ondemand
pm.max_children = 3
pm.process_idle_timeout = 10s
pm.max_requests = 300
catch_workers_output = yes
php_admin_value[error_log] = /www/seraphim/logs/php/worker.log
php_admin_flag[log_errors] = on
CONFIG
"$prefix/sbin/php-fpm" -t -y "$prefix/etc/php-fpm.conf" -c "$prefix/etc/php.ini"
if [ -f "$root/logs/php/php-fpm.log" ]; then
    chown seraphim-web:seraphim-web "$root/logs/php/php-fpm.log"
    chmod 0600 "$root/logs/php/php-fpm.log"
fi
cat > "$unit" <<'UNIT'
[Unit]
Description=Seraphim PHP-FPM application runtime
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=seraphim-web
Group=seraphim-web
ExecStart=/www/seraphim/server/php/sbin/php-fpm --nodaemonize --fpm-config /www/seraphim/server/php/etc/php-fpm.conf --php-ini /www/seraphim/server/php/etc/php.ini
Restart=on-failure
RestartSec=3
UMask=0027

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
printf '%s\n' "$version" > "$prefix/.sera-installed"
committed=1
echo 'SERA_STAGE:PHP-FPM 安装完成，可在软件商店中启动；网站需配置 Nginx FastCGI 转发'
