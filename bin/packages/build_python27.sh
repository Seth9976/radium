#!/bin/bash

set -eEu

if ! declare -F untar_allow_symlink_fail >/dev/null 2>&1 ; then
    untar_allow_symlink_fail() {
        local flag="$1"
        local tarball="$2"
        shift 2
        tar "$flag" "$tarball" "$@" || true
        return 0
    }
fi

if ! declare -F assert_file_exists >/dev/null 2>&1 ; then
    assert_file_exists() {
        if [ ! -f "$1" ] ; then
            echo "error: expected file '$1' to exist" >&2
            exit 1
        fi
    }
fi

if ! declare -F assert_dir >/dev/null 2>&1 ; then
    assert_dir() {
        if [ ! -d "$1" ] ; then
            echo "error: expected directory '$1' to exist" >&2
            exit 1
        fi
    }
fi

is_defined() {
    [ -v "$1" ]
}

if ! is_defined MY_CC ; then
    MY_CC=gcc
fi

if ! is_defined MY_CPP ; then
    MY_CPP=g++
fi

echo "CC: $MY_CC"
echo "CPP: $MY_CPP"

build_python27() {
    local macos_patchfiles=$(cat <<-END
    patch-Makefile.pre.in.diff
    patch-setup.py.diff
    patch-Lib-cgi.py.diff
    patch-Lib-ctypes-macholib-dyld.py.diff
    patch-configure.diff
    patch-libedit.diff
    enable-loadable-sqlite-extensions.patch
    patch-_osx_support.py.diff
    darwin20.diff
    arm.patch
    implicit.patch
    openssl_ver.patch
    libedit-types.patch
    patch-getpath.diff
END
    )

    rm -rf python27_install
    mkdir -p python27_install

    local version=2.7.18

    rm -rf Python-$version
    untar_allow_symlink_fail xvzf Python-$version.tgz
    assert_file_exists Python-$version/configure
    cd Python-$version

    if uname | grep Darwin >/dev/null ; then
        for file in $macos_patchfiles ; do
            echo "FILE: $file"
            if [ ! -f "../python27_macport_patches/$file" ] ; then
                echo "File not found: ../python27_macport_patches/$file"
                exit -1
            fi
            patch -p0 < "../python27_macport_patches/$file"
        done
        patch -p1 < ../python27_disable_macos.patch
    else
        patch -p0 < ../python27_disable_linux.patch
    fi

    local ARCH_FLAGS=""
    if uname | grep Darwin >/dev/null ; then
        ARCH_FLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-14.0}"
    fi

    local PY_COMPAT_FLAGS="-Wno-error -Wno-implicit-function-declaration -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-return-mismatch"
    local PY_CFLAGS="-Wno-implicit-function-declaration $PY_COMPAT_FLAGS $ARCH_FLAGS"

    ./configure CC=$MY_CC CXX=$MY_CPP CFLAGS="$PY_CFLAGS" CPPCFLAGS="$PY_CFLAGS" LDFLAGS="$ARCH_FLAGS" --prefix=$(realpath $(pwd)/../python27_install) --without-gcc --without-threads --disable-ipv6 --without-system-ffi --disable-toolbox-glue --disable-framework --enable-shared

    CC=$MY_CC CXX=$MY_CPP CFLAGS="$PY_CFLAGS" CPPCFLAGS="$PY_CFLAGS" LDFLAGS="$ARCH_FLAGS" make -j$(nproc)

    make install
    export LD_LIBRARY_PATH="$(realpath $(pwd)/../python27_install/lib)"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    cd ..

    if [ -f python27_install/bin/python.exe ] && [ ! -f python27_install/bin/python ]; then
        cp -f python27_install/bin/python.exe python27_install/bin/python
    fi

    if [ -f python27_install/bin/python ] || [ -f python27_install/bin/python.exe ] ; then
        :
    else
        echo "error: python27_install/bin/python 未生成" >&2
        exit 1
    fi
}
