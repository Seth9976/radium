



source $(dirname "${0}")/bash_setup.sh


assert_exe_exists()
{
	if ! command -v "${1}" >/dev/null 2>&1 ; then
		handle_failure "\"${1}\" doesn't seem to exist."
    fi
}

assert_file_exists()
{
    if [ ! -f "$1" ] ; then
		handle_failure "\"${1}\" doesn't seem to exist."
    fi
}

is_empty()
{
    [ -z $1 ]
}

# same as "has_value", except that it also returns true for empty variables.
# Note: call like this: is_defined VAR_NAME
# Not like this: is_defined $VAR_NAME
is_defined()
{
    [ -v $1 ]
}

# returns true if defined and not empty
is_set()
{
    is_defined $1 && ! is_empty $1
}

# E.g "is_set_and_equals GAKK 5"
is_set_and_equals()
{
    is_defined $1 && [[ "${!1}" == "$2" ]]
}

is_0()
{
    [ "${1}" == "0" ]
}

#trap 'handle_failure' ERR

assert_var_value()
{
    if [ "${!1}" != "$2" ] ; then
		handle_failure "\"${1}\" should have the value \"$2\". Instead it has the value \"${!1}\""
    fi	
}





# Sets a variable unless already set.
#
set_var()
{
    if [ "$#" -ne 2 ]; then
	handle_failure "${FUNCNAME}: Illegal number of arguments: \"set_var $@\""
    fi

    if ! is_defined $1 ; then
	export $1="$2"
    fi
}

# Sets the per-branch temporary build directories.
set_radium_build_dirs()
{
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

assert_dir()
{
    if [ ! -d "$1" ] ; then
        handle_failure "\"${1}\" doesn't seem to be a directory."
    fi
}

# 解压 tarball，容忍 Windows 上创建符号链接失败导致的非零退出码。
# 调用方必须紧跟 assert_file_exists / assert_dir 验证真正需要的文件存在，
# 不能把它当成“解压一定成功”的保证。
untar_allow_symlink_fail()
{
    local flag="$1"
    local tarball="$2"
    shift 2
    tar "$flag" "$tarball" "$@" || true
    return 0
}
#export GAKK
#set_var GAKK 4
#echo "GAKK: -${GAKK}-"
#exit

