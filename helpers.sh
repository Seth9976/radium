source $(dirname "${0}")/bash_setup.sh

assert_exe_exists() {
    if ! command -v "${1}" >/dev/null 2>&1 ; then
        handle_failure "\"${1}\" doesn't seem to exist."
    fi
}

assert_file_exists() {
    if [ ! -f "$1" ] ; then
        handle_failure "\"${1}\" doesn't seem to exist."
    fi
}

assert_dir() {
    if [ ! -d "$1" ] ; then
        handle_failure "\"${1}\" doesn't seem to be a directory."
    fi
}

untar_allow_symlink_fail() {
    local flag="$1"
    local tarball="$2"
    shift 2
    tar "$flag" "$tarball" "$@" || true
    return 0
}

is_empty() {
    [ -z "$1" ]
}

is_defined() {
    [ -v "$1" ]
}

is_set() {
    is_defined "$1" && ! is_empty "$1"
}

is_set_and_equals() {
    is_defined "$1" && [[ "${!1}" == "$2" ]]
}

is_0() {
    [ "${1}" == "0" ]
}

assert_var_value() {
    if [ "${!1}" != "$2" ] ; then
        handle_failure "\"${1}\" should have the value \"$2\". Instead it has the value \"${!1}\""
    fi
}

set_var() {
    if [ "$#" -ne 2 ]; then
        handle_failure "${FUNCNAME}: Illegal number of arguments: \"set_var $@\""
    fi

    if ! is_defined "$1" ; then
        export "$1"="$2"
    fi
}

set_radium_build_dirs() {
    local branch
    branch=$(git branch | sed -n -e 's/^\* \(.*\)/\1/p')

    if [ -z "$branch" ] ; then
        branch=unknown
    fi

    branch=${branch//[^A-Za-z0-9_.-]/_}

    set_var RADIUM_TMP_BIN_DIR "/tmp/radium_bin_$branch"
    set_var RADIUM_TMP_OBJ_DIR "/tmp/radium_objects_$branch"
    set_var T "$RADIUM_TMP_OBJ_DIR/"
}
