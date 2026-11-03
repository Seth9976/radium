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

    # ---- Windows/LLP64 适配一: pyport.h 的 sizeof(pid_t) > sizeof(long) 静态检查 ----
    if ! grep -q "__MINGW32__" Include/pyport.h ; then
        sed -i 's/#   error "Python doesn'\''t support sizeof(pid_t) > sizeof(long)"/#   if !defined(__MINGW32__) \&\& !defined(_WIN32)\n#       error "Python doesn'\''t support sizeof(pid_t) > sizeof(long)"\n#   endif/' Include/pyport.h
        echo "== pyport.h LLP64 护栏已注入 =="
    else
        echo "== pyport.h 护栏已存在,跳过 =="
    fi
    grep -n "sizeof(pid_t)" Include/pyport.h || true

    # ---- Windows/LLP64 适配二: random.c 的 POSIX fcntl 控制常量 ----
    # MinGW-w64 的 fcntl.h 有 O_* 但无 F_GETFD/F_SETFD/FD_CLOEXEC,且 fcntl() 无声明
    # (链接期会 undefined reference)。该块源码注释即 "ignore errors" 的尽力而为设置,直接编译隔离。
    local RANDOM_C=Python/random.c
    if ! grep -q "RAD_PATCH_MINGW_FCNTL" "$RANDOM_C" ; then
        sed -i 's|^        attr = fcntl(fd, F_GETFD);|        /* RAD_PATCH_MINGW_FCNTL */\n#if defined(F_GETFD) \&\& defined(F_SETFD) \&\& defined(FD_CLOEXEC)\n        attr = fcntl(fd, F_GETFD);|' "$RANDOM_C"
        sed -i 's|^            (void)fcntl(fd, F_SETFD, attr);|            (void)fcntl(fd, F_SETFD, attr);\n#endif /* RAD_PATCH_MINGW_FCNTL */|' "$RANDOM_C"
        echo "== random.c fcntl 护栏已注入 =="
    else
        echo "== random.c fcntl 护栏已存在,跳过 =="
    fi
    grep -n "RAD_PATCH_MINGW_FCNTL\|F_GETFD\|F_SETFD\|FD_CLOEXEC" "$RANDOM_C" || true

    # ---- 编译标志: 强制 gnu17(消除 C23 关键字冲突) + 静音 %zd 告警 ----
    local ARCH_FLAGS=""
    if uname | grep Darwin >/dev/null ; then
        ARCH_FLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-14.0}"
    fi

    local PY_STD_FLAGS="-std=gnu17"
    local PY_COMPAT_FLAGS="$PY_STD_FLAGS -Wno-error -Wno-implicit-function-declaration -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-return-mismatch -Wno-format -Wno-format-extra-args"
    local PY_CFLAGS="-fPIC -fno-strict-aliasing -O2 $PY_COMPAT_FLAGS $ARCH_FLAGS"
    local PY_LIBS="-lversion -lshlwapi -lws2_32 -lshell32"

    # 预防: 不设 PYTHONHASHSEED,避免 _PyRandom_Init 走 dev_urandom_noraise -> Py_FatalError("Failed to open /dev/urandom")
    unset PYTHONHASHSEED || true

    ac_cv_sizeof_pid_t=4 ./configure CC=$MY_CC CXX=$MY_CPP CFLAGS="$PY_CFLAGS" CPPCFLAGS="$PY_CFLAGS" LDFLAGS="$ARCH_FLAGS" LIBS="$PY_LIBS" --prefix=$(realpath $(pwd)/../python27_install) --without-gcc --without-threads --disable-ipv6 --without-system-ffi --disable-toolbox-glue --disable-framework --enable-shared

    echo "==== 嗅探 pyconfig.h 关键宏(CI 诊断用) ===="
    grep -nE "MS_WINDOWS|HAVE_FCNTL_H|HAVE_UNISTD_H|HAVE_FORK|HAVE_GETRANDOM|HAVE_GETENTROPY|HAVE_DEV_URANDOM|HAVE_FSTAT|SIZEOF_PID_T|SIZEOF_LONG|SIZEOF_VOID_P|SIZEOF_SIZE_T" pyconfig.h || true
    echo "==== 扫描其余 F_GETFD/F_SETFD/FD_CLOEXEC 潜在引用点 ===="
    grep -rn "F_GETFD\|F_SETFD\|FD_CLOEXEC" --include="*.c" --include="*.h" . | grep -v "RAD_PATCH_MINGW_FCNTL" || true

    make -j$(nproc)
    make install

    export LD_LIBRARY_PATH="$(realpath $(pwd)/../python27_install/lib)"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    cd ..

    echo "==== 嗅探 python27_install 目录结构 ===="
    find python27_install -maxdepth 3 -print || true
    ls -la python27_install/bin || true
    ls -la python27_install/lib || true

    if [ -f python27_install/bin/python.exe ] && [ ! -f python27_install/bin/python ] ; then
        cp -f python27_install/bin/python.exe python27_install/bin/python
    fi
    if [ ! -f python27_install/bin/python ] && [ -f python27_install/bin/python2.7.exe ] ; then
        cp -f python27_install/bin/python2.7.exe python27_install/bin/python
    fi

    local LIBDIR=python27_install/lib
    if [ -f "$LIBDIR/libpython2.7.so" ] && [ ! -f "$LIBDIR/libpython2.7.dll" ] ; then
        cp -f "$LIBDIR/libpython2.7.so" "$LIBDIR/libpython2.7.dll"
    fi
    if [ -f "$LIBDIR/libpython2.7.dll" ] && [ ! -f python27_install/bin/libpython2.7.dll ] ; then
        cp -f "$LIBDIR/libpython2.7.dll" python27_install/bin/libpython2.7.dll
    fi
    if [ ! -f "$LIBDIR/libpython2.7.dll.a" ] && [ -f "$LIBDIR/libpython2.7.dll" ] && command -v gendef >/dev/null 2>&1 ; then
        ( cd "$LIBDIR" && gendef libpython2.7.dll && dlltool -d libpython2.7.def -l libpython2.7.dll.a ) || true
    fi

    echo "==== 二进制信息嗅探 ===="
    if command -v file >/dev/null 2>&1 ; then
        file python27_install/bin/python.exe || true
        for so in "$LIBDIR"/libpython2.7* ; do file "$so" || true ; done
    fi
    for so in python27_install/bin/libpython2.7.dll "$LIBDIR"/libpython2.7.dll ; do
        if [ -f "$so" ] ; then
            echo "-- DLL 依赖: $so"
            objdump -p "$so" | grep "DLL Name" || true
        fi
    done

    if [ -f python27_install/bin/python ] || [ -f python27_install/bin/python.exe ] ; then
        echo "验证成功: Python 解释器二进制文件存在"
        ./python27_install/bin/python -V || ./python27_install/bin/python.exe -V || true
    else
        echo "error: python27_install/bin/python 未生成" >&2
        exit 1
    fi
}
