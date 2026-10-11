#!/bin/sh
set -eu

version=8.4.11
sera_id=mysql
root=/www/seraphim
prefix=$root/server/mysql
filename=mysql-$version-linux-glibc2.28-x86_64-minimal.tar.xz
archive=$root/download/$filename
work=
committed=0
created=0
cleanup() {
    if [ -n "$work" ]; then rm -rf "$work"; fi
    if [ "$committed" -eq 0 ] && [ "$created" -eq 1 ]; then
        rm -rf "$prefix" /etc/systemd/system/sera-mysql.service
        systemctl daemon-reload || true
    fi
}
trap cleanup EXIT

if [ "$(uname -m)" != x86_64 ]; then
    echo '当前 MySQL 精简安装包仅支持 x86_64。' >&2
    exit 1
fi
if [ -e "$prefix" ] || [ -e /etc/systemd/system/sera-mysql.service ]; then
    echo 'MySQL 安装目录或服务单元已存在，已停止以保护现有数据。' >&2
    exit 1
fi
install -d -m 0755 "$root/server" "$root/download"
install -d -m 0700 "$root/tmp"
install -d -m 0711 "$root/logs"

echo 'SERA_STAGE:检查 MySQL 系统依赖'
sera_packages libaio numactl-libs
if ! getent group seraphim-mysql >/dev/null 2>&1; then
    groupadd --system seraphim-mysql
fi
if ! id -u seraphim-mysql >/dev/null 2>&1; then
    useradd --system --no-create-home --gid seraphim-mysql --shell /sbin/nologin seraphim-mysql
fi
install -d -m 0700 -o seraphim-mysql -g seraphim-mysql "$root/logs/mysql"

echo 'SERA_STAGE:下载 MySQL 官方精简安装包'
if [ ! -f "$archive" ]; then
    curl --fail --location --show-error --silent --retry 3 --connect-timeout 15 --max-time 3600 \
        -o "$archive.part" "https://cdn.mysql.com/Downloads/MySQL-8.4/$filename"
    mv "$archive.part" "$archive"
fi
echo '3358302178e35d893f14fc49be542847  '"$archive" | md5sum -c -

work=$(mktemp -d "$root/tmp/mysql-install.XXXXXX")
install -d -m 0700 "$work/gnupg" "$work/unpack"
echo 'SERA_STAGE:验证 MySQL 官方签名'
curl --fail --location --show-error --silent --connect-timeout 15 --max-time 60 \
    -o "$work/archive.asc" "https://cdn.mysql.com/Downloads/MySQL-8.4/$filename.asc"
curl --fail --location --show-error --silent --connect-timeout 15 --max-time 60 \
    -o "$work/mysql-key.asc" https://repo.mysql.com/RPM-GPG-KEY-mysql-2025
gpg --homedir "$work/gnupg" --batch --show-keys --with-colons "$work/mysql-key.asc" \
    | grep -Fq 'BCA43417C3B485DD128EC6D4B7B3B788A8D3785C'
gpg --homedir "$work/gnupg" --batch --import "$work/mysql-key.asc"
gpg --homedir "$work/gnupg" --batch --verify "$work/archive.asc" "$archive"

echo 'SERA_STAGE:解压并初始化 MySQL'
tar -xJf "$archive" -C "$work/unpack" --strip-components=1
test -x "$work/unpack/bin/mysqld"
created=1
mv "$work/unpack" "$prefix"
chmod 0755 "$prefix"
sera_libaio_compat "$prefix"
LD_LIBRARY_PATH="$prefix/compat-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
install -d -m 0700 -o seraphim-mysql -g seraphim-mysql "$prefix/data" "$prefix/run"
cat > "$prefix/my.cnf" <<'CONFIG'
[mysqld]
basedir=/www/seraphim/server/mysql
datadir=/www/seraphim/server/mysql/data
socket=/www/seraphim/server/mysql/run/mysql.sock
pid-file=/www/seraphim/server/mysql/run/mysqld.pid
log-error=/www/seraphim/logs/mysql/error.log
port=3306
bind-address=127.0.0.1
mysqlx=OFF
performance_schema=OFF
innodb_buffer_pool_size=128M
innodb_log_buffer_size=8M
max_connections=30
table_open_cache=200
CONFIG
chown seraphim-mysql:seraphim-mysql "$prefix/my.cnf"
chmod 0600 "$prefix/my.cnf"
"$prefix/bin/mysqld" --no-defaults --initialize --user=seraphim-mysql \
    --basedir="$prefix" --datadir="$prefix/data" \
    --innodb-buffer-pool-size=64M --performance-schema=OFF \
    --log-error="$root/logs/mysql/initialize.log"
awk '/temporary password is generated for root@localhost:/ { print $NF }' \
    "$root/logs/mysql/initialize.log" > "$prefix/initial-root-password"
test -s "$prefix/initial-root-password"
chmod 0600 "$prefix/initial-root-password"

cat > /etc/systemd/system/sera-mysql.service <<'UNIT'
[Unit]
Description=Seraphim MySQL database server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=seraphim-mysql
Group=seraphim-mysql
Environment=LD_LIBRARY_PATH=/www/seraphim/server/mysql/compat-lib
ExecStart=/www/seraphim/server/mysql/bin/mysqld --defaults-file=/www/seraphim/server/mysql/my.cnf
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
printf '%s\n' "$version" > "$prefix/.sera-installed"
committed=1
echo 'SERA_STAGE:MySQL 安装完成，可在软件商店中启动；初始 root 密码保存在 /www/seraphim/server/mysql/initial-root-password'
