version=${SERA_SELECTED_VERSION:-10.0.401}
case "$version" in
    10.0.401|9.0.306) ;;
    *) echo '不支持的 .NET 版本' >&2; exit 1 ;;
esac
sera_begin dotnet "$version"
case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo '.NET 不支持当前架构' >&2; exit 1 ;;
esac
case "$version/$arch" in
    10.0.401/x64) sha=51c8b999af9e8dd9998c9edc5944e19a90788862068acd38694e098889054ce8c23d4f0c5cccfa16bf187d044562359e5ee69a9f8ad0bbe913ba90311fbce25b ;;
    10.0.401/arm64) sha=58ace73ced6b4360754689a686bdfb8a317f4da6cb8bb416dbc7d0ba9f47e43e3c09f5eb1f1a1cfaacbd10df9558da4882bf2a5e195d6ab56a02c1f9f76102ed ;;
    9.0.306/x64) sha=bbb6bdc3c8048e7cc189759b406257839e7d4bd6b8b1ba4bcdaeea8f92340e6855231043dd73f902130ca5357af72b810bb51a4da4d1315a2927ff85f831f1d5 ;;
    9.0.306/arm64) sha=72667eb4167308fec780a9fbb59a16087d1015afa09ce771a04e21663782cabbd59c395587af6835dcc1f34e2e677c765e44dcc68a446d2caa4ed4a4a0e329ee ;;
esac
sera_packages libicu
file=dotnet-sdk-$version-linux-$arch.tar.gz
sera_stage '下载 Microsoft .NET 官方 SDK'
sera_download512 "$file" "https://builds.dotnet.microsoft.com/dotnet/Sdk/$version/$file" "$sha"
sera_create_prefix
tar -xzf "$sera_archive" -C "$sera_prefix"
DOTNET_CLI_HOME="$sera_prefix" DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 "$sera_prefix/dotnet" --version
sera_commit
