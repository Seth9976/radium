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

PY27_VER=2.7.18
PY27_DIR="Python-$PY27_VER"
PY27_PATCH="python27_mingw.patch"

# ================= 补丁生成器 =================
# 原则: 内容锚定 + awk 状态机逐行校验 + diff 计算行号 + patch 应用。
# 不使用行号 sed 插入 #if/#endif(会把 #endif 放到 } 之前,结构断裂)。

python27_guard_random_c() {
    awk '
    BEGIN { st = 0; failed = 0 }
    st == 0 && /^[ \t]*attr = fcntl$$fd, F_GETFD$$;[ \t]*$/ {
        print "#if defined(F_GETFD) && defined(F_SETFD) && defined(FD_CLOEXEC)"
        print
        st = 1
        next
    }
    st == 1 {
        if ($0 !~ /^[ \t]*if[ \t]*$$[ \t]*attr >= 0[ \t]*$$[ \t]*\{[ \t]*$/) { print "gen-err random.c line " NR ": " $0 > "/dev/stderr"; failed = 1; exit 1 }
        print; st = 2; next
    }
    st == 2 {
        if ($0 !~ /attr[ \t]*\|=[ \t]*FD_CLOEXEC;/) { print "gen-err random.c line " NR ": " $0 > "/dev/stderr"; failed = 1; exit 1 }
        print; st = 3; next
    }
    st == 3 {
        if ($0 !~ /fcntl$$fd,[ \t]*F_SETFD,[ \t]*attr$$/) { print "gen-err random.c line " NR ": " $0 > "/dev/stderr"; failed = 1; exit 1 }
        print; st = 4; next
    }
    st == 4 {
        if ($0 !~ /^[ \t]*\}[ \t]*$/) { print "gen-err random.c line " NR ": " $0 > "/dev/stderr"; failed = 1; exit 1 }
        print
        print "#endif"
        st = 5
        next
    }
    { print }
    END { if (!failed && st != 5) { print "gen-err random.c: fcntl 块未找到或未闭合" > "/dev/stderr"; exit 1 } }
    ' "$1"
}

python27_guard_posixmodule_c() {
    awk '
    function is_target(line) {
        return (line ~ /^[ \t]*[^#]*fcntl[ \t]*\(/ && line ~ /(F_GETFD|F_SETFD|FD_CLOEXEC|F_GETFL|F_SETFL)/ && line ~ /;[ \t]*$/ && line !~ /\\[ \t]*$/)
    }
    BEGIN { inrun = 0 }
    is_target($0) {
        if (!inrun) { print "#if defined(F_GETFD) && defined(F_SETFD) && defined(FD_CLOEXEC)"; inrun = 1 }
        print
        next
    }
    {
        if (inrun) { print "#else"; print "    (void)0;"; print "#endif"; inrun = 0 }
        print
    }
    END { if (inrun) { print "#else"; print "    (void)0;"; print "#endif" } }
    ' "$1"
}

python27_already_patched() {
    grep -q "F_GETFD) && defined(F_SETFD) && defined(FD_CLOEXEC)" "$1/Python/random.c"
}

# 生成 ../python27_mingw.patch: 临时修改 -> diff(自动算行号) -> 还原原始文件
python27_make_mingw_patches() {
    local src="$1"
    local out="$2"
    local tmp
    tmp="$(mktemp -d)"
    cp "$src/Python/random.c" "$tmp/random.c.orig"
    cp "$src/Modules/posixmodule.c" "$tmp/posixmodule.c.orig"
    python27_guard_random_c "$tmp/random.c.orig" > "$src/Python/random.c"
    python27_guard_posixmodule_c "$tmp/posixmodule.c.orig" > "$src/Modules/posixmodule.c"
    : > "$out"
    diff -u --label Python/random.c --label Python/random.c "$tmp/random.c.orig" "$src/Python/random.c" >> "$out" || true
    diff -u --label Modules/posixmodule.c --label Modules/posixmodule.c "$tmp/posixmodule.c.orig" "$src/Modules/posixmodule.c" >> "$out" || true
    cp "$tmp/random.c.orig" "$src/Python/random.c"
    cp "$tmp/posixmodule.c.orig" "$src/Modules/posixmodule.c"
    rm -rf "$tmp"
    if [ ! -s "$out" ] ; then
        echo "gen-err: 生成的补丁为空: $out" >&2
        exit 1
    fi
    echo "==== 生成补丁: $out ===="
    cat "$out"
}

python27_apply_mingw_patches() {
    local src="$1"
    if python27_already_patched "$src" ; then
        echo "== mingw 补丁此前已应用,跳过 =="
        return 0
    fi
    if [ -f "$src/../$PY27_PATCH" ] ; then
        echo "== 尝试已提交补丁: ../$PY27_PATCH =="
        if ( cd "$src" && patch -p0 --dry-run -N -l < "../$PY27_PATCH" ) ; then
            ( cd "$src" && patch -p0 -N -l < "../$PY27_PATCH" )
        else
            echo "::warning::已提交补丁不适用,现场重新生成"
            python27_make_mingw_patches "$src" "$src/../$PY27_PATCH"
            ( cd "$src" && patch -p0 --dry-run -N -l < "../$PY27_PATCH" )
            ( cd "$src" && patch -p0 -N -l < "../$PY27_PATCH" )
        fi
    else
        python27_make_mingw_patches "$src" "$src/../$PY27_PATCH"
        ( cd "$src" && patch -p0 --dry-run -N -l < "../$PY27_PATCH" )
        ( cd "$src" && patch -p0 -N -l < "../$PY27_PATCH" )
    fi
    if ! python27_already_patched "$src" ; then
        echo "error: mingw 补丁应用后校验失败" >&2
        exit 1
    fi
    echo "== 补丁应用后关键区域 =="
    grep -n -B2 -A6 "F_GETFD) && defined(F_SETFD) && defined(FD_CLOEXEC)" "$src/Python/random.c" "$src/Modules/posixmodule.c" || true
}

# 同类 POSIX 风险扫描: 位点 + 外层 #if 栈(确认是否参与编译)
python27_mingw_risk_report() {
    local src="$1"
    echo "==== 同类 POSIX 位点扫描(仅报告) ===="
    for sym in F_GETFD F_SETFD FD_CLOEXEC F_GETFL F_SETFL O_CLOEXEC "fork(" "waitpid(" "sigaction(" "symlink(" "readlink(" "chown(" "getuid(" "mkfifo(" "openpty(" "forkpty(" "getloadavg(" "lockf(" "sendfile(" "utimes(" "fchmod(" "chroot(" "initgroups(" "ttyname(" "getpgid(" "setitimer(" "alarm(" "dlopen(" ; do
        echo "--- $sym ---"
        grep -rnF -- "$sym" "$src/Python" "$src/Modules" "$src/Objects" "$src/Parser" "$src/Include" 2>/dev/null | head -n 8 || true
    done
    echo "==== fcntl 位点的预处理器外层栈 ===="
    awk '
        /^[ \t]*#[ \t]*if/ { depth++; stack[depth] = $0 }
        /^[ \t]*#[ \t]*endif/ { if (depth > 0) depth-- }
        /F_GETFD|F_SETFD|FD_CLOEXEC|fcntl[ \t]*\(/ {
            printf "%s:%d:", FILENAME, NR
            for (i = 1; i <= depth; i++) printf " [%s]", stack[i]
            printf "  %s\n", $0
        }
    ' "$src/Python/random.c" "$src/Modules/posixmodule.c" "$src/Modules/fcntlmodule.c" 2>/dev/null || true
}

# ================= 构建 =================

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

    rm -rf "$PY27_DIR"
    untar_allow_symlink_fail xvzf "Python-$PY27_VER.tgz"
    assert_file_exists "$PY27_DIR/configure"
    cd "$PY27_DIR"

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

    # ---- LLP64 护栏一: pyport.h 的 sizeof(pid_t) > sizeof(long)(保留你已验证的 sed,加幂等守卫) ----
    if ! grep -q "__MINGW32__" Include/pyport.h ; then
        sed -i 's/#   error "Python doesn'\''t support sizeof(pid_t) > sizeof(long)"/#   if !defined(__MINGW32__) \&\& !defined(_WIN32)\n#       error "Python doesn'\''t support sizeof(pid_t) > sizeof(long)"\n#   endif/' Include/pyport.h
        echo "== pyport.h LLP64 护栏已注入 =="
    else
        echo "== pyport.h 护栏已存在,跳过 =="
    fi
    grep -n "sizeof(pid_t)" Include/pyport.h || true

    # ---- LLP64/POSIX 护栏二: F_GETFD/F_SETFD/FD_CLOEXEC 守护补丁 ----
    python27_apply_mingw_patches "$(pwd)"

    local ARCH_FLAGS=""
    if uname | grep Darwin >/dev/null ; then
        ARCH_FLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-14.0}"
    fi

    local PY_COMPAT_FLAGS="-std=gnu17 -Wno-error -Wno-implicit-function-declaration -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-return-mismatch -Wno-format -Wno-format-extra-args"
    local PY_CFLAGS="-fPIC -fno-strict-aliasing -O2 $PY_COMPAT_FLAGS $ARCH_FLAGS"
    local PY_LIBS="-lversion -lshlwapi -lws2_32 -lshell32"

    ac_cv_sizeof_pid_t=4 ./configure CC=$MY_CC CXX=$MY_CPP CFLAGS="$PY_CFLAGS" CPPCFLAGS="$PY_CFLAGS" LDFLAGS="$ARCH_FLAGS" LIBS="$PY_LIBS" --prefix=$(realpath $(pwd)/../python27_install) --without-gcc --without-threads --disable-ipv6 --without-system-ffi --disable-toolbox-glue --disable-framework --enable-shared

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
            echo "-- DLL 导入表: $so"
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

# 作为顶层程序运行(绝不 source,否则 ${0} 指向 runner 临时脚本):
#   bash bin/packages/build_python27.sh                  -> 完整构建
#   bash bin/packages/build_python27.sh gen-patches-only -> 只生成/验证/打印补丁 + 风险扫描
if [[ "${BASH_SOURCE[0]}" == "$0" ]] ; then
    THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
    cd "$THIS_DIR"
    case "${1:-build}" in
        gen-patches-only)
            rm -rf "$PY27_DIR"
            untar_allow_symlink_fail xvzf "Python-$PY27_VER.tgz"
            assert_file_exists "$PY27_DIR/configure"
            python27_make_mingw_patches "$PY27_DIR" "$PY27_PATCH"
            echo "== dry-run 校验 =="
            ( cd "$PY27_DIR" && patch -p0 --dry-run -N -l < "../$PY27_PATCH" )
            python27_mingw_risk_report "$PY27_DIR"
            echo "== 完成: $THIS_DIR/$PY27_PATCH =="
            ;;
        *)
            build_python27
            ;;
    esac
fi
