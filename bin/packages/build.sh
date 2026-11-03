#!/usr/bin/env bash

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

setup_build_environment() {
    export PYTHONEXE_NOT_AVAILABLE_YET=1

    pushd ../../
    source configuration.sh
    popd

    unset CFLAGS
    unset CPPFLAGS
    unset LDFLAGS
    unset CXXFLAGS

    RELEASE_BUILD=true

    if $RELEASE_BUILD ; then
        export COMMON_CFLAGS="-mtune=generic -fPIC -fno-strict-aliasing -Wno-misleading-indentation "
    else
        export COMMON_CFLAGS="-ggdb3 -fno-omit-frame-pointer -fPIC -fno-strict-aliasing -Wno-misleading-indentation "
    fi

    if uname -s | grep Darwin >/dev/null ; then
        if [[ -z "${MACOSX_DEPLOYMENT_TARGET}" ]]; then
            echo "MACOSX_DEPLOYMENT_TARGET not set"
            exit -1
        fi
        export COMMON_CFLAGS="$COMMON_CFLAGS -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
        export DARWIN_ARCH_FLAGS="-arch arm64 -arch x86_64 "
        export DARWIN_MIN_FLAGS="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
        export DARWIN_CMAKEOPT="-DCMAKE_OSX_ARCHITECTURES=\"arm64;x86_64\" -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET}"
    else
        export DARWIN_ARCH_FLAGS=""
        export DARWIN_MIN_FLAGS=""
        export DARWIN_CMAKEOPT=""
    fi

    if ! arch | grep -E "arm|aarch64" >/dev/null ; then
        export COMMON_CFLAGS="$COMMON_CFLAGS -msse2 -mfpmath=sse "
    fi

    if [[ $RADIUM_USE_CLANG == 0 ]] ; then
        export COMMON_CFLAGS="$COMMON_CFLAGS -fmax-errors=5 "
    fi

    set_var QT_CPPFLAGS ""
    set_var QT_LDFLAGS ""

    export CFLAGS="$COMMON_CFLAGS "
    export CPPFLAGS="$QT_CPPFLAGS $COMMON_CFLAGS "
    export CXXFLAGS="$QT_CPPFLAGS $COMMON_CFLAGS "
    export LDFLAGS="$QT_LDFLAGS"

    DASCC=gcc
    DASCXX=g++

    if ! is_0 $RADIUM_USE_CLANG ; then
        DASCC=clang
        DASCXX=clang++
    fi

    PWD=$(pwd)
    PREFIX=$(dirname "$PWD/$0")
}

build_faust() {
    rm -rf faust
    untar_allow_symlink_fail xvzf faust-2.88.0.tar.gz
    assert_dir faust-2.88.0
    assert_file_exists faust-2.88.0/Makefile
    mv faust-2.88.0 faust
    cd faust

    patch -p0 < ../faust_soundfile_padding.patch
    patch -p0 < ../faust_fopenat_nochdir.patch
    patch -p0 < ../faust_fix_hang.patch
    patch -p0 < ../faust_fix_eval_recursion.patch
    patch -p0 < ../faust_fix_apply_memo.patch
    patch -p0 < ../faust_fix_svg_folding.patch
    patch -p0 < ../faust_fix_fft_route.patch

    cp ../faust_targets.cmake build/targets/most.cmake

    if is_0 $FAUST_USES_LLVM ; then
        cp ../faust_radium_nonllvm.cmake build/backends/most.cmake
    else
        cp ../faust_radium_llvm.cmake build/backends/most.cmake
        export ORGTEMPPATH=$PATH
        export PATH=$($LLVM_CONFIG_BIN --bindir):$PATH
    fi

    local JOBS=$(nproc)
    local CC_PATH=$(which $DASCC)
    local CXX_PATH=$(which $DASCXX)
    local CMAKEOPTS="-DCMAKE_BUILD_TYPE=Release -DSELF_CONTAINED_LIBRARY=on -DCMAKE_CXX_COMPILER=$CXX_PATH -DCMAKE_C_COMPILER=$CC_PATH $DARWIN_CMAKEOPT"

    BUILDOPT="--config Release -j${JOBS}" VERBOSE=1 CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" CMAKEOPT="$CMAKEOPTS" make most

    if ! is_0 $FAUST_USES_LLVM ; then
        export PATH=$ORGTEMPPATH
        unset ORGTEMPPATH
    fi

    cd ..
    assert_file_exists faust/build/bin/faust
}

build_libpds() {
    local NOWARNS="-Wno-return-mismatch -Wno-implicit-function-declaration -Wno-int-conversion -Wno-implicit-int -Wno-strict-prototypes -Wno-incompatible-pointer-types -std=gnu17"

    rm -rf libpd-master
    tar xvzf libpd-master.tar.gz
    cd libpd-master/
    sed -i.backup "/define CFLAGS/ s|\")| -I/usr/include/tirpc $NOWARNS\")|" make.scm
    sed -i.backup 's/k_cext$//' make.scm
    sed -i.backup 's/oscx //' make.scm
    sed -i.backup "s/gcc -O3/gcc -fcommon -O3 $NOWARNS/" make.scm

    local GLIBCVERSION=$(ldd --version 2>/dev/null | head -n 1 | awk '{print $NF}' || true)
    if [[ "$GLIBCVERSION" > "2.34" ]] ; then
        sed -i.backup 's/#define fsqrt sqrt/#include <math.h>\nstatic float fsqrt(float val){return sqrt(val);}/g' pure-data/extra/fiddle~/fiddle~.c
        sed -i.backup 's/fsqrt/myfsqrt/g' pure-data/extra/fiddle~/fiddle~.c
    fi

    make clean
    CPPFLAGS="$CFLAGS $NOWARNS" make -j$(nproc)
    cd ..
}

build_libpd() {
    rm -rf libpd
    untar_allow_symlink_fail xvzf libpd-0.16.1.tar.gz
    assert_dir libpd
    assert_file_exists libpd/Makefile
    assert_file_exists libpd/pure-data/src/m_pd.h
    cd libpd/

    for patch_file in ../libpd_patches/*.patch ; do
        patch -p1 --batch --forward < "$patch_file"
    done

    local LIBPD_DEBUG_FLAGS="-g -fno-omit-frame-pointer ${LIBPD_EXTRA_CFLAGS:-}"
    local LIBPD_LINK_FLAGS=""

    if uname -s | grep Darwin >/dev/null ; then
        LIBPD_DEBUG_FLAGS="$LIBPD_DEBUG_FLAGS $DARWIN_ARCH_FLAGS $DARWIN_MIN_FLAGS"
        LIBPD_LINK_FLAGS="$DARWIN_ARCH_FLAGS $DARWIN_MIN_FLAGS"
        LIBPD_LINK_FLAGS="$LIBPD_LINK_FLAGS -Wl,-install_name,@executable_path/packages/libpd/libs/libpd.dylib"
        for wish in /opt/local/libexec/tk-quartz/wish8.6 /opt/local/bin/wish8.6 /opt/homebrew/bin/wish8.6 ; do
            if [ -x "$wish" ] ; then
                LIBPD_DEBUG_FLAGS="$LIBPD_DEBUG_FLAGS -DWISH='\"$wish\"'"
                break
            fi
        done
    else
        local LIBPD_TARGET=$(${CC:-cc} -dumpmachine 2>/dev/null || true)
        case "$LIBPD_TARGET" in
            *mingw*|*cygwin*|*msys*) LIBPD_LINK_FLAGS="" ;;
            *) LIBPD_LINK_FLAGS="-Wl,-soname,libpd.so" ;;
        esac
    fi

    make clean
    make -j$(nproc) libpd STATIC=true MULTI=true UTIL=true EXTRA=true ADDITIONAL_CFLAGS="$LIBPD_DEBUG_FLAGS" ADDITIONAL_LDFLAGS="$LIBPD_LINK_FLAGS"

    cd ..
    assert_dir libpd/libpd_wrapper
    assert_file_exists libpd/pure-data/src/m_pd.h
}

build_tcltk_wish_darwin() {
    local TCLTK_VERSION=8.6.17
    local TCLTK_FRAMEWORK_VERSION=8.6
    local WISH_DIR="$(pwd)/tcltk-wish-embedded"
    local WISH_APP="$(pwd)/libpd/Wish.app"

    if [ ! -e libpd/pure-data/tcl/pd-gui.tcl ]; then
        echo "build_tcltk_wish: libpd has not been extracted yet. Run build_libpd first." >&2
        exit 1
    fi

    rm -rf tcl$TCLTK_VERSION tk$TCLTK_VERSION "$WISH_DIR" build
    tar xvzf tcl$TCLTK_VERSION-src.tar.gz
    tar xvzf tk$TCLTK_VERSION-src.tar.gz

    CFLAGS="$DARWIN_ARCH_FLAGS $DARWIN_MIN_FLAGS" make -C tcl$TCLTK_VERSION/macosx embedded
    CFLAGS="$DARWIN_ARCH_FLAGS $DARWIN_MIN_FLAGS" make -C tk$TCLTK_VERSION/macosx embedded
    CFLAGS="$DARWIN_ARCH_FLAGS $DARWIN_MIN_FLAGS" make -C tcl$TCLTK_VERSION/macosx install-embedded INSTALL_ROOT="$WISH_DIR"
    CFLAGS="$DARWIN_ARCH_FLAGS $DARWIN_MIN_FLAGS" make -C tk$TCLTK_VERSION/macosx install-embedded INSTALL_ROOT="$WISH_DIR"

    rm -rf "$WISH_APP"
    cp -a "$WISH_DIR/Applications/Utilities/Wish.app" "$WISH_APP"

    chmod -R u+w "$WISH_APP"
    local TCL_FRAMEWORK=/Library/Frameworks/Tcl.framework/Versions/$TCLTK_FRAMEWORK_VERSION/Tcl
    local TK_FRAMEWORK=/Library/Frameworks/Tk.framework/Versions/$TCLTK_FRAMEWORK_VERSION/Tk
    install_name_tool -change $TCL_FRAMEWORK @executable_path/../Frameworks/Tcl.framework/Versions/$TCLTK_FRAMEWORK_VERSION/Tcl "$WISH_APP/Contents/MacOS/Wish"
    install_name_tool -change $TK_FRAMEWORK @executable_path/../Frameworks/Tk.framework/Versions/$TCLTK_FRAMEWORK_VERSION/Tk "$WISH_APP/Contents/MacOS/Wish"
    install_name_tool -id @executable_path/../Frameworks/Tcl.framework/Versions/$TCLTK_FRAMEWORK_VERSION/Tcl "$WISH_APP/Contents/Frameworks/Tcl.framework/Versions/$TCLTK_FRAMEWORK_VERSION/Tcl"
    install_name_tool -id @executable_path/../Frameworks/Tk.framework/Versions/$TCLTK_FRAMEWORK_VERSION/Tk "$WISH_APP/Contents/Frameworks/Tk.framework/Versions/$TCLTK_FRAMEWORK_VERSION/Tk"

    rm -rf tcl$TCLTK_VERSION tk$TCLTK_VERSION "$WISH_DIR" build
}

build_tcltk_wish_linux() {
    local TCLTK_DEST="$(pwd)/libpd/pure-data"

    if [ ! -e "$TCLTK_DEST/tcl/pd-gui.tcl" ]; then
        echo "build_tcltk_wish_linux: libpd has not been extracted yet. Run build_libpd first." >&2
        exit 1
    fi

    if ! "$(pwd)/install_tcltk_aa_linux.sh" --dest "$TCLTK_DEST" ; then
        "$(pwd)/build_tcltk_wish_linux.sh" --dest "$TCLTK_DEST"
    fi
}

build_pd_externals() {
    local EXTERNALS_SRC="$(pwd)/pd_externals"
    local BUILD_EXTERNAL="$(pwd)/build_pd_external.sh"
    local EXTERNALS_DIR="${PD2_EXTERNALS_DIR:-$(pwd)/../pd/externals}"

    if [ ! -f "$BUILD_EXTERNAL" ]; then
        echo "Missing $BUILD_EXTERNAL" >&2
        exit 1
    fi
    if [ ! -f "$EXTERNALS_SRC/pd_externals.list" ]; then
        echo "Missing $EXTERNALS_SRC/pd_externals.list" >&2
        exit 1
    fi

    rm -rf "$EXTERNALS_DIR"
    mkdir -p "$EXTERNALS_DIR"

    local name="" tarball="" srcdir="" flags="" args=""
    local args_darwin="" args_linux="" args_windows="" patches="" exclude=""
    local install_dirs="" cppflags="" cflags="" author="" copyright="" license=""
    local submodule_path="" submodule_tarball="" pd_externals_credits=""

    build_one() {
        [ -n "$name" ] || return 0

        if [ -n "${PD2_EXTERNALS_ONLY:-}" ]; then
            case " $PD2_EXTERNALS_ONLY " in
                *" $name "*) ;;
                *) return 0 ;;
            esac
        fi

        if [ -n "${PD2_EXTERNALS_SKIP:-}" ]; then
            case " $PD2_EXTERNALS_SKIP " in
                *" $name "*) return 0 ;;
            esac
        fi

        case "${PD2_TARGET_OS:-$(uname -s)}" in
            Darwin)  args="$args $args_darwin" ;;
            Linux)   args="$args $args_linux" ;;
            Windows) args="$args $args_windows" ;;
        esac

        echo "==== Building Pd external '$name' ===="
        local tarball_path="$EXTERNALS_SRC/$tarball"
        if [ ! -f "$tarball_path" ]; then
            echo "Tarball not found: $tarball_path" >&2
            exit 1
        fi

        rm -rf "$(pwd)/$srcdir"
        untar_allow_symlink_fail xzf "$tarball_path"
        assert_dir "$(pwd)/$srcdir"

        if [ -n "$exclude" ]; then
            for exclude_path in $exclude ; do
                rm -rf "$(pwd)/$srcdir/$exclude_path"
            done
        fi

        if [ -n "$submodule_path" ]; then
            local sub_tarball_path="$EXTERNALS_SRC/$submodule_tarball"
            if [ ! -f "$sub_tarball_path" ]; then
                echo "Submodule tarball not found: $sub_tarball_path" >&2
                exit 1
            fi

            local sub_tmpdir="$(pwd)/.pd2-submodule-$$"
            rm -rf "$sub_tmpdir"
            mkdir -p "$sub_tmpdir"
            untar_allow_symlink_fail xzf "$sub_tarball_path" -C "$sub_tmpdir"
            local sub_source="$(find "$sub_tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
            if [ -z "$sub_source" ] ; then
                echo "Could not find the top-level directory in $submodule_tarball" >&2
                rm -rf "$sub_tmpdir"
                exit 1
            fi
            rm -rf "$(pwd)/$srcdir/$submodule_path"
            mkdir -p "$(pwd)/$srcdir/$submodule_path"
            cp -a "$sub_source"/. "$(pwd)/$srcdir/$submodule_path/"
            rm -rf "$sub_tmpdir"
        fi

        for patch_file in $patches ; do
            patch -p1 -d "$srcdir" --batch --forward < "$EXTERNALS_SRC/$patch_file"
        done

        local BUILD_ENV=()
        if [ -n "$cppflags" ]; then
            BUILD_ENV+=("PD2_CPPFLAGS=$cppflags")
        fi
        if [ -n "$cflags" ]; then
            BUILD_ENV+=("PD2_CFLAGS=$cflags")
        fi

        env ${BUILD_ENV[@]+"${BUILD_ENV[@]}"} "$BUILD_EXTERNAL" $flags --dest "$EXTERNALS_DIR" --lib-name "$name" "$(pwd)/$srcdir" $args

        if [ -n "$install_dirs" ]; then
            for extra_dir in $install_dirs ; do
                if [ -d "$(pwd)/$srcdir/$extra_dir" ]; then
                    cp -a "$(pwd)/$srcdir/$extra_dir" "$EXTERNALS_DIR/$name/"
                else
                    echo "install_dirs entry not found: $srcdir/$extra_dir" >&2
                    exit 1
                fi
            done
        fi

        pd_externals_credits+="$name|$author|$copyright|$license\n"
    }

    while IFS= read -r line || [ -n "$line" ] ; do
        line="${line%$'\r'}"
        case "$line" in
            ""|\#*) continue ;;
            \[*\])
                build_one
                name="${line#[}"
                name="${name%]}"
                tarball="" ; srcdir="" ; flags="" ; args=""
                args_darwin="" ; args_linux="" ; args_windows="" ; patches="" ; exclude=""
                install_dirs="" ; cppflags="" ; cflags="" ; author="" ; copyright="" ; license=""
                submodule_path="" ; submodule_tarball=""
                ;;
            *=*)
                local key=$(echo "${line%%=*}" | tr -d '[:space:]')
                local value=$(echo "${line#*=}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                case "$key" in
                    tarball)          tarball="$value" ;;
                    srcdir)           srcdir="$value" ;;
                    flags)            flags="$value" ;;
                    args)             args="$value" ;;
                    args_darwin)      args_darwin="$value" ;;
                    args_linux)       args_linux="$value" ;;
                    args_windows)     args_windows="$value" ;;
                    patches)          patches="$value" ;;
                    exclude)          exclude="$value" ;;
                    install_dirs)     install_dirs="$value" ;;
                    cppflags)         cppflags="$value" ;;
                    cflags)           cflags="$value" ;;
                    author)           author="$value" ;;
                    copyright)        copyright="$value" ;;
                    license)          license="$value" ;;
                    submodule_path)   submodule_path="$value" ;;
                    submodule_tarball) submodule_tarball="$value" ;;
                esac
                ;;
        esac
    done < "$EXTERNALS_SRC/pd_externals.list"
    build_one

    printf "%b" "$pd_externals_credits" > "$EXTERNALS_DIR/pd2-externals-credits.txt"

    if [ -z "${PD2_SKIP_SYMBOL_CLASH_CHECK:-}" ]; then
        "$EXTERNALS_SRC/check_symbol_clashes.sh" --externals "$EXTERNALS_DIR"
    fi
}

build_qhttpserver() {
    rm -rf qhttpserver-master
    untar_allow_symlink_fail xvzf qhttpserver-master.tar.gz
    assert_dir qhttpserver-master
    assert_file_exists qhttpserver-master/src/src.pro

    cd qhttpserver-master

    echo "CONFIG += staticlib" >> src/src.pro
    echo "CONFIG -= debug_and_release" >> src/src.pro
    echo "CONFIG -= debug" >> src/src.pro
    echo "CONFIG += release" >> src/src.pro

    patch -p1 < ../qhttpserver_qt6.patch

    cd src
    $QMAKE
    make -j$(nproc)
    cd ../..

    assert_file_exists qhttpserver-master/build/moc_qhttpconnection.cpp
    assert_file_exists qhttpserver-master/build/moc_qhttpserver.cpp
    assert_file_exists qhttpserver-master/lib/libqhttpserver.a
}

build_gc() {
    local GC_VERSION=8.2.8
    local LIBATOMIC_VERSION=7.8.0
    rm -rf gc-$GC_VERSION libatomic_ops-$LIBATOMIC_VERSION
    untar_allow_symlink_fail xvzf gc-$GC_VERSION.tar.gz
    untar_allow_symlink_fail xvzf libatomic_ops-$LIBATOMIC_VERSION.tar.gz
    assert_file_exists gc-$GC_VERSION/configure
    assert_dir libatomic_ops-$LIBATOMIC_VERSION/src
    cd gc-$GC_VERSION

    if ! ln -s ../libatomic_ops-$LIBATOMIC_VERSION libatomic_ops 2>/dev/null ; then
        echo "warn: ln -s failed, falling back to cp -r" >&2
        cp -r ../libatomic_ops-$LIBATOMIC_VERSION libatomic_ops
    fi
    assert_dir libatomic_ops/src

    echo 'void RADIUM_ensure_bin_packages_gc_is_used(void){}' >> malloc.c
    echo '#if defined(GC_ASSERTIONS) || !defined(NO_DEBUGGING)' >> malloc.c
    echo '#error "nope"' >> malloc.c
    echo '#endif' >> malloc.c

    CFLAGS="-mtune=generic -g -O2" ./configure --enable-static --disable-shared --disable-gc-debug --disable-gc-assertions
    CFLAGS="-mtune=generic -g -O2" make -j$(nproc)
    cd ..

    assert_file_exists gc-$GC_VERSION/.libs/libgc.a
    assert_dir gc-$GC_VERSION/include
}

build_fluidsynth() {
    rm -rf fluidsynth-1.1.6
    untar_allow_symlink_fail xvzf fluidsynth-1.1.6.tar.gz
    assert_file_exists fluidsynth-1.1.6/configure

    cd fluidsynth-1.1.6

    local FS_COMPAT_FLAGS="-std=gnu89 -Wno-error -Wno-incompatible-pointer-types -Wno-implicit-function-declaration -Wno-int-conversion -Wno-return-mismatch -Wno-deprecated-declarations"
    local FS_CFLAGS="-fPIC -fno-strict-aliasing -O3 -DDEFAULT_SOUNDFONT=\\\"\\\" $FS_COMPAT_FLAGS"
    local FS_CPPFLAGS="-fPIC -fno-strict-aliasing -O3"
    local FS_CXXFLAGS="-fPIC -fno-strict-aliasing -O3"
    local FS_LDFLAGS=""
    local FS_CONFIGURE_OPTS="--enable-static --disable-shared --disable-aufile-support --disable-pulse-support --disable-alsa-support --disable-libsndfile-support --disable-portaudio-support --disable-oss-support --disable-midishare --disable-jack-support --disable-coreaudio --disable-coremidi --disable-dart --disable-lash --disable-ladcca --disable-dbus-support --without-readline"

    CFLAGS="$FS_CFLAGS" CPPFLAGS="$FS_CPPFLAGS" CXXFLAGS="$FS_CXXFLAGS" LDFLAGS="$FS_LDFLAGS" CC=$DASCC CXX=$DASCXX ./configure $FS_CONFIGURE_OPTS

    local FS_M_CFLAGS="$FS_CFLAGS $DARWIN_MIN_FLAGS $DARWIN_ARCH_FLAGS"
    local FS_M_CPPFLAGS="$FS_CPPFLAGS $DARWIN_MIN_FLAGS $DARWIN_ARCH_FLAGS"
    local FS_M_CXXFLAGS="$FS_CXXFLAGS $DARWIN_MIN_FLAGS $DARWIN_ARCH_FLAGS"
    local FS_M_LDFLAGS="$DARWIN_MIN_FLAGS $DARWIN_ARCH_FLAGS"

    make -j$(nproc) -C src libfluidsynth.la CFLAGS="$FS_M_CFLAGS" CPPFLAGS="$FS_M_CPPFLAGS" CXXFLAGS="$FS_M_CXXFLAGS" LDFLAGS="$FS_M_LDFLAGS"

    if [ -f src/libfluidsynth.a ] && [ ! -f src/.libs/libfluidsynth.a ]; then
        mkdir -p src/.libs
        cp -f src/libfluidsynth.a src/.libs/libfluidsynth.a
    fi

    cd ..
    assert_file_exists fluidsynth-1.1.6/src/.libs/libfluidsynth.a
}

build_libgig() {
    exit -1
}

build_qscintilla() {
    rm -rf QScintilla_gpl-2.10.8 QScintilla_src-2.14.0
    untar_allow_symlink_fail xvzf QScintilla_src-2.14.0.tar.gz
    assert_file_exists QScintilla_src-2.14.0/src/qscintilla.pro

    cd QScintilla_src-2.14.0/src
    echo "CONFIG += staticlib" >> qscintilla.pro
    echo "CONFIG -= debug_and_release" >> qscintilla.pro
    echo "CONFIG -= debug" >> qscintilla.pro
    echo "CONFIG += release" >> qscintilla.pro

    if uname -s | grep Darwin >/dev/null ; then
        $QMAKE QMAKE_CFLAGS+="$DARWIN_ARCH_FLAGS" QMAKE_CXXFLAGS+="$DARWIN_ARCH_FLAGS" QMAKE_LFLAGS+="$DARWIN_ARCH_FLAGS"
        sed -i '' '/install_name_tool -id/d' Makefile
    else
        $QMAKE
    fi

    patch -p0 < ../../qscintilla.patch
    make -j$(nproc)

    if [ -f release/libqscintilla2_qt6.a ] && [ ! -f libqscintilla2_qt6.a ]; then
        cp -f release/libqscintilla2_qt6.a libqscintilla2_qt6.a
    fi

    cd ../..
    assert_file_exists QScintilla_src-2.14.0/src/libqscintilla2_qt6.a
}

build_xcb() {
    if ! is_0 ${RADIUM_BUILD_LIBXCB:-1} ; then
        rm -rf xcb-proto-1.13/
        tar xvjf xcb-proto-1.13.tar.bz2
        cd xcb-proto-1.13/
        mkdir install
        ./configure --prefix=$(pwd)/install PYTHON=$PYTHONEXE
        make -j$(nproc)
        make install
        cd ..

        rm -rf libxcb-1.13
        tar xvjf libxcb-1.13.tar.bz2
        cd libxcb-1.13
        export XCBPROTO_LIBS="$(pwd)/../xcb-proto-1.13/install/lib"
        export XCBPROTO_CFLAGS="$CFLAGS"
        CFLAGS="$CFLAGS" CPPFLAGS="$CPPFLAGS" CXXFLAGS="$CXXFLAGS" ./configure PYTHON=$PYTHONEXE
        CFLAGS="$CFLAGS" CPPFLAGS="$CPPFLAGS" CXXFLAGS="$CXXFLAGS" make -j$(nproc)
        cd ..
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]] ; then
    setup_build_environment

    source ./build_python27.sh

    build_faust
    build_qhttpserver
    build_gc
    build_fluidsynth
    build_python27
    build_qscintilla

    if uname -s | grep Linux >/dev/null ; then
        if ! arch | grep -E "arm|aarch64" >/dev/null ; then
            build_libpds
        fi
        build_xcb
        echo "Finished compiling libpds and xcb"
    fi

    build_libpd
    build_pd_externals
    echo "Finished building libpd and pd externals"

    if uname -s | grep Linux >/dev/null ; then
        if ! is_0 $INCLUDE_PD2DEV ; then
            build_tcltk_wish_linux
            echo "Finished installing the antialiased Tcl/Tk wish"
        fi
    elif uname -s | grep Darwin >/dev/null ; then
        if ! is_0 $INCLUDE_PD2DEV ; then
            build_tcltk_wish_darwin
            echo "Finished building the Tcl/Tk Wish.app"
        fi
    fi

    touch deletemetorebuild
fi

echo "Success"
