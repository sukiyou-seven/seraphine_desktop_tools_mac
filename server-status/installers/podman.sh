sera_begin podman 6.1.3
sera_packages gcc make git pkgconf-pkg-config glib2-devel libseccomp-devel systemd-devel \
    conmon crun netavark aardvark-dns iptables containers-common fuse-overlayfs
sera_stage '下载 Podman 官方源码'
sera_download podman-v6.1.3.tar.gz https://codeload.github.com/containers/podman/tar.gz/refs/tags/v6.1.3 6253aee14e573f747ca77e5a83a0df4ef9c2f609604f56715070ed06b6f9ddd8
sera_extract_tar
sera_create_prefix
sera_ensure_go
cd "$sera_work"
sera_stage '编译 Podman'
PATH="$sera_prefix/go/bin:$PATH" GOCACHE="$sera_work/go-cache" GOPATH="$sera_work/go-path" \
    make -j1 BUILDTAGS='seccomp systemd exclude_graphdriver_btrfs containers_image_openpgp' podman
install -d -m 0755 "$sera_prefix/bin"
install -d -m 0700 "$sera_prefix/data" "$sera_prefix/run"
install -m 0755 bin/podman "$sera_prefix/bin/podman.real"
for tool in conmon crun netavark aardvark-dns; do
    tool_path=$(command -v "$tool" || true)
    if [ -z "$tool_path" ]; then
        for candidate in "/usr/lib/podman/$tool" "/usr/libexec/podman/$tool"; do
            if [ -x "$candidate" ]; then tool_path=$candidate; break; fi
        done
    fi
    if [ -z "$tool_path" ] || [ ! -x "$tool_path" ]; then
        echo "找不到 Podman 所需工具 $tool" >&2
        exit 1
    fi
    install -m 0755 "$tool_path" "$sera_prefix/bin/$tool"
done
cat > "$sera_prefix/storage.conf" <<'EOF'
[storage]
driver = "overlay"
graphroot = "/www/seraphim/server/podman/data"
runroot = "/www/seraphim/server/podman/run"
EOF
cat > "$sera_prefix/containers.conf" <<'EOF'
[engine]
conmon_path = ["/www/seraphim/server/podman/bin/conmon"]
helper_binaries_dir = ["/www/seraphim/server/podman/bin"]
runtime = "crun"
[engine.runtimes]
crun = ["/www/seraphim/server/podman/bin/crun"]
EOF
cat > "$sera_prefix/bin/podman" <<'EOF'
#!/bin/sh
CONTAINERS_STORAGE_CONF=/www/seraphim/server/podman/storage.conf
CONTAINERS_CONF=/www/seraphim/server/podman/containers.conf
PATH=/www/seraphim/server/podman/bin:$PATH
export CONTAINERS_STORAGE_CONF CONTAINERS_CONF PATH
exec /www/seraphim/server/podman/bin/podman.real "$@"
EOF
chmod 0755 "$sera_prefix/bin/podman"
"$sera_prefix/bin/podman" --version
sera_commit
