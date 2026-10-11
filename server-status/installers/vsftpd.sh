sera_begin vsftpd 3.0.5 /etc/systemd/system/sera-vsftpd.service
sera_packages gcc make openssl-devel libcap-devel pam-devel
sera_stage '下载 vsftpd 源码镜像（固定校验值）'
sera_download vsftpd-3.0.5.tar.gz https://mirrors.kernel.org/slackware/slackware64-current/source/n/vsftpd/vsftpd-3.0.5.tar.gz 26b602ae454b0ba6d99ef44a09b6b9e0dfa7f67228106736df1f278c70bc91d3
sera_extract_tar
cd "$sera_work"
sera_stage '编译 vsftpd'
make -j1 'LIBS=`./vsf_findlibs.sh` -lcap'
sera_create_prefix
install -d -m 0755 "$sera_prefix/sbin"
install -d -m 0555 "$sera_prefix/empty"
install -m 0755 vsftpd "$sera_prefix/sbin/vsftpd"
cat > "$sera_prefix/vsftpd.conf" <<'EOF'
listen=YES
listen_ipv6=NO
listen_address=127.0.0.1
listen_port=2122
anonymous_enable=NO
local_enable=YES
write_enable=NO
chroot_local_user=YES
allow_writeable_chroot=NO
seccomp_sandbox=NO
secure_chroot_dir=/www/seraphim/server/vsftpd/empty
pam_service_name=login
xferlog_enable=YES
xferlog_file=/www/seraphim/logs/vsftpd.log
EOF
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim vsftpd
After=network-online.target
[Service]
Type=simple
ExecStart=/www/seraphim/server/vsftpd/sbin/vsftpd /www/seraphim/server/vsftpd/vsftpd.conf
Restart=on-failure
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
sera_commit
