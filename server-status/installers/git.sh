sera_begin git 2.52.0
sera_packages gcc make curl-devel expat-devel gettext-devel openssl-devel zlib-devel perl-ExtUtils-MakeMaker
sera_stage '下载 Git 官方源码'
sera_download git-2.52.0.tar.xz https://www.kernel.org/pub/software/scm/git/git-2.52.0.tar.xz 3cd8fee86f69a949cb610fee8cd9264e6873d07fa58411f6060b3d62729ed7c5
sera_extract_tar
cd "$sera_work"
sera_stage '编译 Git'
make -j1 prefix="$sera_prefix" all
sera_create_prefix
make prefix="$sera_prefix" install
"$sera_prefix/bin/git" --version
sera_commit
