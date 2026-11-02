#!/bin/bash

set -eEu

# build.sh 里已经定义过这三个 helper；若单独运行本文件则兜底一份。
if ! declare -F untar_allow_symlink_fail >/dev/null 2>&1; then
    untar_allow_symlink_fail() {
        local flag="$1" tarball="$2"; shift 2
        local rc=0
        tar "$flag" "$tarball" "$@" || rc=$?
        [ "$rc" -ne 0 ] && echo "warn: tar '$tarball' exited with $rc (symlink permission?)" >&2
        return 0
    }
fi
if ! declare -F assert_file >/dev/null 2>&1; then
    assert_file() { [ -e "$1" ] || { echo "error: missing '$1'" >&2; exit 1; }; }
fi

is_defined()
{
    [ -v $1 ]
}

if ! is_defined MY_CC ; then
	MY_CC=clang
fi

if ! is_defined MY_CPP ; then
	MY_CPP=clang++
fi

echo "CC: $MY_CC"
echo "CPP: $MY_CPP"

build_python27 () {
    local macos_patchfiles=$(cat <<-END
    patch-Makefile.pre.in.diff \
                    patch-setup.py.diff \
                    patch-Lib-cgi.py.diff \
                    patch-Lib-ctypes-macholib-dyld.py.diff \
                    patch-configure.diff \
                    patch-libedit.diff \
                    enable-loadable-sqlite-extensions.patch \
                    patch-_osx_support.py.diff \
                    darwin20.diff \
                    arm.patch \
                    implicit.patch \
                    openssl_ver.patch \
                    libedit-types.patch \
		    patch-getpath.diff
END
	  )

    rm -fr python27_install
    mkdir python27_install

    local version=2.7.18

    rm -fr Python-$version
    # Python 2.7 tarball 里 Tools/、Modules/_ctypes/libffi_osx/ 等有 symlink，
    # Windows 上可能因权限失败，但 configure 已解出，不影响构建。
    untar_allow_symlink_fail xvzf Python-$version.tgz
    assert_file Python-$version/configure
    cd Python-$version

    if uname |grep Darwin > /dev/null ; then
		for file in $macos_patchfiles ; do
			echo "FILE: $file"
			if [ ! -f ../python27_macport_patches/$file ] ; then
				echo "File not found: -" ../python27_macport_patches/$file + "-"
				exit -1
			fi
			patch -p0 < ../python27_macport_patches/$file
		done
 		patch -p1 <../python27_disable_macos.patch
    else
		patch -p0 <../python27_disable_linux.patch
    fi

    CC=$MY_CC
    CXX=$MY_CPP
    CFLAGS=-Wno-implicit-function-declaration
    CPPCFLAGS=-Wno-implicit-function-declaration

    ARCH_FLAGS=""
    if uname |grep Darwin > /dev/null ; then
        ARCH_FLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-14.0}"
    fi

    ./configure CC=$MY_CC CXX=$MY_CPP \
        CFLAGS="-Wno-implicit-function-declaration $ARCH_FLAGS" \
        CPPCFLAGS="-Wno-implicit-function-declaration $ARCH_FLAGS" \
        LDFLAGS="$ARCH_FLAGS" \
        --prefix=$(realpath `pwd`/../python27_install) \
        --without-gcc --without-threads --disable-ipv6 --without-system-ffi \
        --disable-toolbox-glue --disable-framework --enable-shared

    CC=$MY_CC CXX=$MY_CPP \
        CFLAGS="-Wno-implicit-function-declaration $ARCH_FLAGS" \
        CPPCFLAGS="-Wno-implicit-function-declaration $ARCH_FLAGS" \
        LDFLAGS="$ARCH_FLAGS" \
        make -j`nproc`

    make install
    export LD_LIBRARY_PATH="$(realpath `pwd`/../python27_install/lib)"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    cd ..

    # Windows 上 install 出来是 python.exe；Unix 是 python
    if [ -f python27_install/bin/python ]; then
        :
    elif [ -f python27_install/bin/python.exe ]; then
        :
    else
        echo "error: python27_install/bin/python 未生成" >&2
        exit 1
    fi
}
