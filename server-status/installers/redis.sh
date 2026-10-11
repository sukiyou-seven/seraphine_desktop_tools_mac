#!/bin/sh
set -eu

version=8.4.7
sera_id=redis
root=/www/seraphim
prefix=$root/server/redis
archive=$root/download/redis-$version.tar.gz
unit=/etc/systemd/system/sera-redis.service
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
    echo 'Redis 安装目录或服务单元已存在，已停止以保护现有数据。' >&2
    exit 1
fi
install -d -m 0755 "$root/server" "$root/download"
install -d -m 0700 "$root/tmp"
install -d -m 0711 "$root/logs"

echo 'SERA_STAGE:安装 Redis 编译依赖'
sera_packages gcc gcc-c++ make
if ! getent group seraphim-redis >/dev/null 2>&1; then
    groupadd --system seraphim-redis
fi
if ! id -u seraphim-redis >/dev/null 2>&1; then
    useradd --system --no-create-home --gid seraphim-redis --shell /sbin/nologin seraphim-redis
fi

echo 'SERA_STAGE:下载 Redis 官方源码'
if [ ! -f "$archive" ]; then
    curl --fail --location --show-error --silent --retry 3 --connect-timeout 15 --max-time 1200 \
        -o "$archive.part" "https://download.redis.io/releases/redis-$version.tar.gz"
    mv "$archive.part" "$archive"
fi
echo 'ed83df9fcb724176fc901147aaa63830166e35c1cff39835c4fc9a5860ed1310  '"$archive" | sha256sum -c -

work=$(mktemp -d "$root/tmp/redis-install.XXXXXX")
tar -xzf "$archive" -C "$work" --strip-components=1
echo 'SERA_STAGE:编译 Redis（单线程）'
cd "$work"
make -j1 MALLOC=libc BUILD_TLS=no
echo 'SERA_STAGE:安装 Redis 到 /www/seraphim/server/redis'
created=1
make PREFIX="$prefix" install
install -d -m 0755 "$prefix" "$prefix/bin" "$prefix/etc"
install -d -m 0700 -o seraphim-redis -g seraphim-redis "$prefix/data" "$root/logs/redis"
install -m 0600 -o seraphim-redis -g seraphim-redis /dev/null "$prefix/data/users.acl"
printf '%s\n' 'user default on nopass ~* &* +@all' > "$prefix/data/users.acl"
cat > "$prefix/etc/redis.conf" <<'CONFIG'
bind 127.0.0.1
protected-mode yes
port 6379
daemonize no
supervised no
dir /www/seraphim/server/redis/data
logfile /www/seraphim/logs/redis/redis.log
maxmemory 128mb
maxmemory-policy noeviction
appendonly yes
appendfsync everysec
aclfile /www/seraphim/server/redis/data/users.acl
CONFIG
chmod 0644 "$prefix/etc/redis.conf"
cat > "$unit" <<'UNIT'
[Unit]
Description=Seraphim Redis key-value database
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=seraphim-redis
Group=seraphim-redis
ExecStart=/www/seraphim/server/redis/bin/redis-server /www/seraphim/server/redis/etc/redis.conf
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
printf '%s\n' "$version" > "$prefix/.sera-installed"
committed=1
echo 'SERA_STAGE:Redis 安装完成，可在软件商店中启动'
