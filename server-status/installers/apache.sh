sera_begin apache 2.4.69 /etc/systemd/system/sera-apache.service
sera_packages gcc make apr-devel apr-util-devel pcre2-devel openssl-devel expat-devel
sera_stage '下载 Apache HTTP Server 官方源码'
sera_download httpd-2.4.69.tar.gz https://downloads.apache.org/httpd/httpd-2.4.69.tar.gz c551b9861e26f146f57e1b1765e69c89a60b3db0ec252ccab0d36283487016bb
sera_extract_tar
cd "$sera_work"
sera_stage '编译 Apache HTTP Server'
./configure --prefix="$sera_prefix" --enable-so --enable-ssl --enable-rewrite \
    --enable-proxy=shared --enable-proxy-http=shared --enable-proxy-fcgi=shared \
    --with-mpm=event --with-ssl
make -j1
sera_create_user sera
sera_create_prefix
make install
# worker 以 sera 运行（面板唯一的业务账户），才读得到归 sera 所有的站点目录。
sed -i 's/^Listen 80$/Listen 8082/; s/^User daemon$/User sera/; s/^Group daemon$/Group sera/' "$sera_prefix/conf/httpd.conf"
cat >> "$sera_prefix/conf/httpd.conf" <<'EOF'
ServerName localhost
DocumentRoot "/www/seraphim/web"
<Directory "/www/seraphim/web">
    Require all granted
</Directory>
EOF
cat >> "$sera_prefix/conf/httpd.conf" <<'EOF'
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_http_module modules/mod_proxy_http.so
IncludeOptional /www/seraphim/sites/apache/*.conf
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim Apache HTTP Server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/www/seraphim/server/apache/bin/httpd -DFOREGROUND -f /www/seraphim/server/apache/conf/httpd.conf
ExecReload=/www/seraphim/server/apache/bin/httpd -k graceful -f /www/seraphim/server/apache/conf/httpd.conf
Restart=on-failure
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
"$sera_prefix/bin/httpd" -t -f "$sera_prefix/conf/httpd.conf"
sera_commit
