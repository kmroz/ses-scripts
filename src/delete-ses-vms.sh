#!/bin/bash
#
# ==============================================================================
# delete-ses-vms.sh
# ------------------
#
# A simple scripts that deletes a few VM's...
# ==============================================================================

# Fail fast
#set -e

# Error codes
success=0
yes=0
failure=1
no=1
assert_err=255

# Some globals
scriptname=$(basename "$0")
img_type="qcow2"

# Required params
vm_base_name=""               # name for vms: foo-1, foo-2, foo-n
img_path=""                   # destination of created image

vms_to_destroy=()
base_imgs_to_destroy=()
hd_imgs_to_destroy=()


txtbold=$(tput bold)
txtnorm=$(tput sgr0)
txtred=$(tput setaf 1)
txtgreen=$(tput setaf 2)

usage_msg="usage: $scriptname <required-params> [options]
required-params:
\t-b, --base-name
\t\tBase name for VMs to delete. A VM will be named as <base-name>-<instance num>.

\t-d, --img-destination
\t\tPath where images reside. Default: ${img_path}

options:
\t-h, --help
\t\tPrint this usage message.
"

out_norm () {
    local msg=$1
    printf "${txtnorm}${msg}"
}

out_bold () {
    local msg=$1
    printf "${txtnorm}${txtbold}${msg}${txtnorm}"
}

out_bold_red () {
    local msg=$1
    printf "${txtnorm}${txtbold}${txtred}${msg}${txtnorm}"
}

out_err () {
    local msg=$1
    out_bold_red "ERROR: $msg"
}

out_err_exit () {
    local msg=$1
    out_bold_red "ERROR: $msg"
    exit "$failure"
}

out_err_usage_exit () {
    local msg="$1"
    out_bold_red "ERROR: $msg"
    usage_exit "$failure"
}

usage_exit () {
    ret_code="$1"
    out_norm "$usage_msg"
    [[ -z "$ret_code" ]] && exit "$success" || exit "$ret_code"
}

running_as_root () {
    [[ "$EUID" = 0 ]] || out_err_usage_exit "Run $scriptname as root\n"
}

# Based on VM name, get the full base image path.
get_base_img_path () {
    local vm_name="$1"

    [[ -z "$vm_name" ]] && assert_err "Empty image name\n"
    echo "${img_path}/${vm_name}.${img_type}"
}

get_hd_img_path () {
    local vm_name="$1"

    [[ -z "$vm_name" ]] && assert_err "Empty image name\n"
    echo "${img_path}/${vm_name}-osd-hd.${img_type}"
}

# Get list of VMs on the system matching the form: $vm_base_name-*
get_vms_to_destroy () {
    vms_to_destroy=($(sudo virsh list --all | grep "$vm_base_name" | awk '{print $2}'))
}

# Look in $img_path for images matching the form: v in $vms_to_destroy -> $v.$img_type
get_base_images_to_destroy () {
    for v in "${vms_to_destroy[@]}"
    do
        img=`get_base_img_path $v`
        [[ -e "$img" ]] && base_imgs_to_destroy+=("$img")
    done
}

# Look in $img_path for images matching the form: v in $vms_to_destroy -> $v-osd-hd.$img_type
get_hd_images_to_destroy () {
    for v in "${vms_to_destroy[@]}"
    do
        img=`get_hd_img_path $v`
        [[ -e "$img" ]] && hd_imgs_to_destroy+=("$img")
    done
}

# Output what we'll do and get permission.
get_user_consent () {
    local msg="Are you sure you want to proceed?"
    local answers="Y[es]/N[o] (N)"
    local prompt="[$msg - $answers]> "
    local choice=""

    out_bold "About to destroy the following VMs:\n"
    for v in "${vms_to_destroy[@]}"
    do
        out_norm "$v\n"
    done

    out_bold "About to destroy the following base images:\n"
    for i in "${base_imgs_to_destroy[@]}"
    do
        out_norm "$i\n"
    done

    out_bold "About to destroy the following hd images:\n"
    for i in "${hd_imgs_to_destroy[@]}"
    do
        out_norm "$i\n"
    done

    while true
    do
	out_bold_red "$prompt"
        read choice
        case $choice in
            [Yy] | [Yy][Ee][Ss])
		return "$yes"
                ;;
            [Nn] | [Nn][Oo] | "")
		return "$no"
                ;;
            *)
                out_err "Invalid input.\n"
                ;;
        esac
    done
}

# Search for VMs starting with vm_base_name.
destroy_vms () {
    if [ -z "${vms_to_destroy[@]}" ]
    then
        out_err "No VMs found starting with a base name of: $vm_base_name\n"
        return "$success"
    fi

    for v in "${vms_to_destroy[@]}"
    do
        out_bold "Destroying $v\n"
        # If a VM is not running, this will output an error message. We don't really care.
        sudo virsh destroy "$v"
    done
}

remove_base_imgs () {
    for i in "${base_imgs_to_destroy[@]}"
    do
        out_bold "Deleting $i\n"
        sudo virsh vol-delete "$i"
    done
}

remove_hd_imgs () {
    for i in "${hd_imgs_to_destroy[@]}"
    do
        out_bold "Deleting $i\n"
        sudo virsh vol-delete "$i"
    done
}

undefine_vms () {
    for v in "${vms_to_destroy[@]}"
    do
        out_bold "Undefining $v\n"
        sudo virsh undefine "$v"
    done
}

# Parse our command line options
while [ "$#" -ge 1 ]
do
    case $1 in
        -b | --base-name)
            vm_base_name="$2"
            shift
            ;;
        -d | --img-destination)
            img_path="$2"
            shift
            ;;
        -h | --help)
            usage_exit
            ;;
	*)  # unrecognized option
	    usage_exit
	    ;;
    esac
    shift
done

running_as_root

# Check for null vars. $autoyast can be null
[[ ! -z "$vm_base_name" && ! -z "$img_path" ]] ||
    out_err_usage_exit "Missing needed parameters.\n"

get_vms_to_destroy
get_base_images_to_destroy
get_hd_images_to_destroy

get_user_consent || exit "$success"

destroy_vms
remove_base_imgs
remove_hd_imgs
undefine_vms
