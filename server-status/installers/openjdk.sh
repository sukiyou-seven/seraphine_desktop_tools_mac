version=${SERA_SELECTED_VERSION:-25.0.4.1}
case "$version" in
    25.0.4.1) major=25; release='25.0.4.1%2B1'; build=1 ;;
    21.0.12.1) major=21; release='21.0.12.1%2B1'; build=1 ;;
    *) echo '不支持的 OpenJDK 版本' >&2; exit 1 ;;
esac
sera_begin openjdk "$version"
case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo 'OpenJDK 不支持当前架构' >&2; exit 1 ;;
esac
case "$version/$arch" in
    25.0.4.1/x64) sha=dbb698396d478e7fa2b1e50f4103324b2a99b90569ee27c33f2261f9215cf41e ;;
    25.0.4.1/aarch64) sha=69df11a02cfa3ef7d7ca645e03edce6778ec090e100f6ae2b42097865730ac52 ;;
    21.0.12.1/x64) sha=ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94 ;;
    21.0.12.1/aarch64) sha=23e37e026f12f3e706f18938ff611db3032d075b09d0879a25d06718c773e223 ;;
esac
file=OpenJDK${major}U-jdk_${arch}_linux_hotspot_${version}_${build}.tar.gz
sera_stage '下载 Eclipse Temurin 官方 JDK'
sera_download "$file" "https://github.com/adoptium/temurin${major}-binaries/releases/download/jdk-$release/$file" "$sha"
sera_create_prefix
tar -xzf "$sera_archive" -C "$sera_prefix" --strip-components=1
"$sera_prefix/bin/java" --version
sera_commit
