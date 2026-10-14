#!/bin/sh
# Inputs are selected and validated against publisher metadata by the Go API.
set -eu
id=$SERA_RUNTIME_ID
version=$SERA_SELECTED_VERSION
asset_url=$SERA_ASSET_URL
asset_file=$SERA_ASSET_FILE
asset_sha256=${SERA_ASSET_SHA256:-}
asset_sha512=${SERA_ASSET_SHA512:-}
unit=
if [ "$id" = php ]; then unit=/etc/systemd/system/sera-php-$version.service; fi
sera_begin "$id" "$version" "$unit"
case "$asset_file" in *[!A-Za-z0-9._-]*|'') echo '无效安装包名' >&2; exit 1;; esac
sera_prefix=$SERA_INSTALL_PREFIX
case "$id" in
 python) sera_packages gcc make zlib-devel openssl-devel bzip2-devel libffi-devel xz-devel sqlite-devel readline-devel ;;
 php) sera_packages gcc make pkgconf-pkg-config libxml2-devel sqlite-devel oniguruma-devel openssl-devel libcurl-devel zlib-devel ;;
 ruby) sera_packages gcc make openssl-devel readline-devel zlib-devel libyaml-devel gdbm-devel ;;
 dotnet) sera_packages libicu ;;
 bun|deno) sera_packages unzip ;;
esac
sera_stage "下载 $id $version 发布包"
if [ -n "$asset_sha512" ]; then
    sera_download512 "$id-$version-$asset_file" "$asset_url" "$asset_sha512"
else
    sera_download "$id-$version-$asset_file" "$asset_url" "$asset_sha256"
fi
case "$id" in
 python|php|ruby)
    sera_extract_tar
    cd "$sera_work"
    sera_stage "编译 $id $version"
    case "$id" in
      python) ./configure --prefix="$sera_prefix" --with-ensurepip=install ;;
      ruby) ./configure --prefix="$sera_prefix" --disable-install-doc ;;
      php) ./configure --prefix="$sera_prefix" --with-config-file-path="$sera_prefix/etc" --with-config-file-scan-dir="$sera_prefix/etc/conf.d" --enable-fpm --enable-opcache --enable-mbstring --enable-exif --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --with-curl --with-openssl --with-zlib --disable-phpdbg --disable-cgi --without-pear ;;
    esac
    make -j1
    sera_create_prefix
    make install
    if [ "$id" = python ]; then "$sera_prefix/bin/python3" --version; fi
    if [ "$id" = ruby ]; then "$sera_prefix/bin/ruby" --version; fi
    if [ "$id" = php ]; then
        install -d -m 0755 "$sera_prefix/etc" "$sera_prefix/etc/conf.d"
        install -d -m 0750 "$sera_prefix/run"
        cp php.ini-production "$sera_prefix/etc/php.ini"
        # PHP 以 sera 运行（面板唯一的业务账户），它才是站点目录的属主。
        sera_create_user sera
        install -d -m 0750 -o sera -g sera "$sera_root/logs/php-$version"
        cat > "$sera_prefix/etc/php-fpm.conf" <<EOF
[global]
pid = $sera_prefix/run/php-fpm.pid
error_log = $sera_root/logs/php-$version/php-fpm.log
daemonize = no
[www]
user = sera
group = sera
listen = $sera_prefix/run/php-fpm.sock
listen.owner = sera
listen.group = sera
listen.mode = 0660
pm = ondemand
pm.max_children = 3
pm.process_idle_timeout = 10s
EOF
        chown -R sera:sera "$sera_prefix/run"
        "$sera_prefix/sbin/php-fpm" -t -y "$sera_prefix/etc/php-fpm.conf" -c "$sera_prefix/etc/php.ini"
        if [ -f "$sera_root/logs/php-$version/php-fpm.log" ]; then
            chown sera:sera "$sera_root/logs/php-$version/php-fpm.log"
            chmod 0600 "$sera_root/logs/php-$version/php-fpm.log"
        fi
        "$sera_prefix/bin/php" --version
        cat > "$unit" <<EOF
[Unit]
Description=Seraphim PHP-FPM $version
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=sera
Group=sera
ExecStart=$sera_prefix/sbin/php-fpm --nodaemonize --fpm-config $sera_prefix/etc/php-fpm.conf --php-ini $sera_prefix/etc/php.ini
Restart=on-failure
RestartSec=3
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
    fi
    ;;
 go|node|openjdk|dotnet)
    sera_create_prefix
    case "$asset_file" in
      *.tar.gz) tar -xzf "$sera_archive" -C "$sera_prefix" $( [ "$id" = dotnet ] || printf '%s' '--strip-components=1' ) ;;
      *.tar.xz) tar -xJf "$sera_archive" -C "$sera_prefix" --strip-components=1 ;;
      *) echo '未知安装包格式' >&2; exit 1 ;;
    esac
    case "$id" in go) "$sera_prefix/bin/go" version ;; node) "$sera_prefix/bin/node" --version ;; openjdk) "$sera_prefix/bin/java" --version ;; dotnet) DOTNET_CLI_HOME="$sera_prefix" "$sera_prefix/dotnet" --version ;; esac
    ;;
 bun|deno)
    sera_mkwork
    unzip -q "$sera_archive" -d "$sera_work"
    sera_create_prefix
    install -d -m 0755 "$sera_prefix/bin"
    if [ "$id" = bun ]; then
        bun_binary=$(find "$sera_work" -type f -name bun -print -quit)
        test -n "$bun_binary"
        install -m 0755 "$bun_binary" "$sera_prefix/bin/bun"
        "$sera_prefix/bin/bun" --version
    else
        install -m 0755 "$sera_work/deno" "$sera_prefix/bin/deno"
        "$sera_prefix/bin/deno" --version
    fi
    ;;
 *) echo '未知运行环境' >&2; exit 1 ;;
esac
sera_commit
