# Shared helpers for catalog installers. The Go API embeds this file with each recipe.
set -eu
umask 022

sera_root=/www/seraphim
sera_id=
sera_version=
sera_prefix=
sera_unit=
sera_work=
sera_created=0
sera_committed=0

sera_stage() {
    printf 'SERA_STAGE:%s\n' "$*"
}

sera_cleanup() {
    if [ -n "$sera_work" ]; then rm -rf "$sera_work"; fi
    if [ "$sera_committed" -eq 0 ] && [ "$sera_created" -eq 1 ]; then
        rm -rf "$sera_prefix"
        if [ -n "$sera_unit" ]; then
            rm -f "$sera_unit"
            systemctl daemon-reload || true
        fi
    fi
}

sera_begin() {
    umask 022
    sera_id=$1
    sera_version=$2
    sera_prefix=${SERA_INSTALL_PREFIX:-$sera_root/server/$sera_id}
    sera_unit=${3:-}
    if [ -e "$sera_prefix" ] || { [ -n "$sera_unit" ] && [ -e "$sera_unit" ]; }; then
        echo "$sera_id 安装目录或服务单元已存在，已停止以保护现有文件。" >&2
        exit 1
    fi
    install -d -m 0755 "$sera_root/server" "$sera_root/download" "$sera_root/web"
    install -d -m 0700 "$sera_root/tmp"
    install -d -m 0711 "$sera_root/logs"
    trap sera_cleanup EXIT
}

sera_fetch() {
    sera_target=$1
    sera_source=$2
    if command -v aria2c >/dev/null 2>&1; then
        aria2c --quiet=true --max-tries=5 --connect-timeout=30 --timeout=60 \
            --max-connection-per-server=8 --split=8 --min-split-size=1M \
            --file-allocation=none --auto-file-renaming=false --allow-overwrite=true \
            --dir="$sera_root/download" --out="$(basename "$sera_target")" "$sera_source"
    else
        if ! command -v curl >/dev/null 2>&1; then sera_packages curl; fi
        curl --fail --location --show-error --silent --retry 5 --retry-delay 3 --connect-timeout 30 --speed-time 30 --speed-limit 1024 --max-time 3600 \
            -o "$sera_target" "$sera_source"
    fi
}

sera_download() {
    sera_archive=$sera_root/download/$1
    sera_url=$2
    sera_hash=$3
    printf '%s' "$sera_hash" | grep -Eq '^[a-f0-9]{64}$' || { echo '安装包 SHA-256 无效' >&2; exit 1; }
    if [ ! -f "$sera_archive" ]; then
        sera_fetch "$sera_archive.part" "$sera_url"
        mv "$sera_archive.part" "$sera_archive"
    fi
    echo "$sera_hash  $sera_archive" | sha256sum -c -
}

sera_download512() {
    sera_archive=$sera_root/download/$1
    sera_url=$2
    sera_hash=$3
    printf '%s' "$sera_hash" | grep -Eq '^[a-f0-9]{128}$' || { echo '安装包 SHA-512 无效' >&2; exit 1; }
    if [ ! -f "$sera_archive" ]; then
        sera_fetch "$sera_archive.part" "$sera_url"
        mv "$sera_archive.part" "$sera_archive"
    fi
    echo "$sera_hash  $sera_archive" | sha512sum -c -
}

sera_mkwork() {
    sera_work=$(mktemp -d "$sera_root/tmp/$sera_id-install.XXXXXX")
}

sera_packages() {
    sera_stage "安装 $sera_id 编译或运行依赖"
    if command -v dnf >/dev/null 2>&1; then
        dnf -y --setopt=install_weak_deps=False install "$@"
        case " $* " in
            *" gcc "*)
                if [ -f /etc/os-release ] && grep -q '^ID="alinux"' /etc/os-release &&
                    [ ! -e /usr/lib/rpm/anolis/anolis-hardened-ld ]; then
                    dnf -y --setopt=install_weak_deps=False install system-rpm-config
                fi
                ;;
        esac
    elif command -v apt-get >/dev/null 2>&1; then
        sera_apt_packages=
        for sera_pkg in "$@"; do
            case "$sera_pkg" in
                gcc-c++) sera_pkg=g++ ;;
                apr-devel) sera_pkg=libapr1-dev ;;
                apr-util-devel) sera_pkg=libaprutil1-dev ;;
                pcre2-devel) sera_pkg=libpcre2-dev ;;
                zlib-devel) sera_pkg=zlib1g-dev ;;
                openssl-devel) sera_pkg=libssl-dev ;;
                expat-devel) sera_pkg=libexpat1-dev ;;
                libaio) sera_pkg=libaio-dev ;;
                numactl-libs) sera_pkg=libnuma1 ;;
                libstdc++) sera_pkg=libstdc++6 ;;
                ncurses) sera_pkg=libncurses6 ;;
                libcurl) sera_pkg=curl ;;
                cyrus-sasl-lib) sera_pkg=libsasl2-2 ;;
                libatomic) sera_pkg=libatomic1 ;;
                readline-devel) sera_pkg=libreadline-dev ;;
                sqlite-devel) sera_pkg=libsqlite3-dev ;;
                libevent-devel) sera_pkg=libevent-dev ;;
                bzip2-devel) sera_pkg=libbz2-dev ;;
                xz-devel) sera_pkg=liblzma-dev ;;
                libffi-devel) sera_pkg=libffi-dev ;;
                libxml2-devel) sera_pkg=libxml2-dev ;;
                oniguruma-devel) sera_pkg=libonig-dev ;;
                pkgconf-pkg-config) sera_pkg=pkgconf ;;
                curl-devel|libcurl-devel) sera_pkg=libcurl4-openssl-dev ;;
                libyaml-devel) sera_pkg=libyaml-dev ;;
                gdbm-devel) sera_pkg=libgdbm-dev ;;
                libcap-devel) sera_pkg=libcap-dev ;;
                pam-devel) sera_pkg=libpam0g-dev ;;
                ncurses-devel) sera_pkg=libncurses-dev ;;
                glib2-devel) sera_pkg=libglib2.0-dev ;;
                libseccomp-devel) sera_pkg=libseccomp-dev ;;
                systemd-devel) sera_pkg=libsystemd-dev ;;
                perl-ExtUtils-MakeMaker) sera_pkg=perl ;;
                gettext-devel) sera_pkg=gettext ;;
                libicu) sera_pkg=libicu-dev ;;
                libicu-devel) sera_pkg=libicu-dev ;;
                containers-common) continue ;;
            esac
            sera_apt_packages="$sera_apt_packages $sera_pkg"
        done
        apt-get update -qq
        # Package names above are fixed in embedded installers, not client input.
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $sera_apt_packages
    else
        echo '需要 apt-get 或 dnf 包管理器' >&2
        exit 1
    fi
}

sera_extract_tar() {
    sera_mkwork
    case "$sera_archive" in
        *.tar.gz|*.tgz) tar -xzf "$sera_archive" -C "$sera_work" --strip-components=1 ;;
        *.tar.bz2) tar -xjf "$sera_archive" -C "$sera_work" --strip-components=1 ;;
        *.tar.xz) tar -xJf "$sera_archive" -C "$sera_work" --strip-components=1 ;;
        *) echo '未知安装包格式' >&2; exit 1 ;;
    esac
}

sera_create_prefix() {
    sera_created=1
    install -d -m 0755 "$sera_prefix"
}

sera_create_user() {
    if ! getent group "$1" >/dev/null 2>&1; then groupadd --system "$1"; fi
    if ! id -u "$1" >/dev/null 2>&1; then
        useradd --system --no-create-home --gid "$1" --shell /sbin/nologin "$1"
    fi
}

sera_go_proxy() {
    if ! command -v curl >/dev/null 2>&1; then sera_packages curl; fi
    if [ -n "${SERA_GOPROXY:-}" ]; then
        printf '%s\n' "$SERA_GOPROXY"
    elif curl -IL --connect-timeout 3 --max-time 5 --silent --fail \
        https://proxy.golang.org/ >/dev/null 2>&1; then
        printf '%s\n' 'https://proxy.golang.org'
    elif curl -IL --connect-timeout 3 --max-time 5 --silent --fail \
        https://goproxy.cn/ >/dev/null 2>&1; then
        printf '%s\n' 'https://goproxy.cn'
    else
        printf '%s\n' 'direct'
    fi
}

sera_libaio_compat() {
    # Ubuntu's time64 transition renamed this SONAME; on x86_64 its ABI is compatible.
    if ldconfig -p | grep -Eq '^[[:space:]]*libaio\.so\.1[[:space:]]'; then return; fi
    sera_libaio_t64=$(ldconfig -p | awk '$1 == "libaio.so.1t64" { print $NF; exit }')
    test -n "$sera_libaio_t64" && test -f "$sera_libaio_t64" || {
        echo '找不到 MySQL/MariaDB 所需的 libaio 运行库' >&2
        exit 1
    }
    install -d -m 0755 "$1/compat-lib"
    ln -s "$sera_libaio_t64" "$1/compat-lib/libaio.so.1"
}

sera_ensure_go() {
    if [ -f "$sera_root/server/go/.sera-installed" ]; then
        ln -s "$sera_root/server/go" "$sera_prefix/go"
        return
    fi
    case "$(uname -m)" in
        x86_64) arch=amd64; sha=63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445 ;;
        aarch64|arm64) arch=arm64; sha=3450b45a3f9ee8568792736a5c5e70a1f2e9b36c35a8f74958c03e51d7d92bec ;;
        *) echo '此软件编译所需 Go 不支持当前架构' >&2; exit 1 ;;
    esac
    file=go1.27.1.linux-$arch.tar.gz
    sera_stage '下载编译所需 Go 工具链'
    sera_download "$file" "https://dl.google.com/go/$file" "$sha"
    install -d -m 0755 "$sera_prefix/go"
    tar -xzf "$sera_archive" -C "$sera_prefix/go" --strip-components=1
}

sera_commit() {
    if [ -n "$sera_unit" ]; then systemctl daemon-reload; fi
    printf '%s\n' "$sera_version" > "$sera_prefix/.sera-installed"
    sera_committed=1
    sera_stage "$sera_id 安装完成"
}
