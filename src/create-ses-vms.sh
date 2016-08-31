#!/bin/bash
#
# ==============================================================================
# create-ses-vms.sh
# ------------------
#
# A simple scripts that creates a few VM's...
# ==============================================================================

# Error codes
success=0
failure=1
assert_err=255

# Some globals
scriptname=$(basename "$0")
www_srv=oak  # TODO: make this configurable

# Required params
num_vms=3                     # number of vms to create
vm_base_name=""               # name for vms: foo-1, foo-2, foo-n
vm_names=()                   # array that will hold vm names
iso_path=""                   # path to SLE/openSUSE iso to use
img_path="~/libvirt/images"   # destion of created image

# Optional
autoyast=""                   # autoyast file

txtbold=$(tput bold)
txtnorm=$(tput sgr0)
txtred=$(tput setaf 1)
txtgreen=$(tput setaf 2)

usage_msg="usage: $scriptname <required-params> [options]
required-params:
\t-b, --base-name
\t\tBase name for vms. Default: ?

\t-n, --num-vms
\t\tNumber of vms to create. Default: 3

\t-i, --iso
\t\tPath to iso. Default: ?

\t-d, --img-destination
\t\tDestination path for created img. Default: ${img_path}

options:
\t-a, --autoyast
\t\tAutoyast file to use.

\t-h, --help
\t\tPrint this usage message.
"

out_bold () {
    local msg=$1
    printf "${txtnorm}${txtbold}${msg}${txtnorm}"
}

out_norm () {
    local msg=$1
    printf "${txtnorm}${msg}"
}

out_red () {
    local msg=$1
    printf "${txtnorm}${txtred}${msg}${txtnorm}"
}

out_bold_red () {
    local msg=$1
    printf "${txtnorm}${txtbold}${txtred}${msg}${txtnorm}"
}

out_bold_green () {
    local msg=$1
    printf "${txtnorm}${txtbold}${txtgreen}${msg}${txtnorm}"
}

out_err () {
    local msg=$1
    out_bold_red "ERROR: $msg"
}

out_err_exit () {
    local msg="$1"
    out_bold_red "ERROR: $msg"
    usage_exit "$failure"
}

out_info () {
    local msg="$1"
    out_bold "INFO: $msg"
}

assert () {
    local msg="$1"
    out_bold_red "FATAL: $msg"
    exit "$assert_err"
}

usage_exit () {
    ret_code="$1"
    out_norm "$usage_msg"
    [[ -z "$ret_code" ]] && exit "$success" || exit "$ret_code"
}

running_as_root () {
    [[ "$EUID" = 0 ]] || out_err_exit "Run $scriptname as root\n"
}

print_vm_names () {
    for n in "${vm_names[@]}"
    do
        out_norm "$n\n"
    done
}
set_vm_names () {
    for n in `seq ${num_vms}`
    do
        vm_names+=("${vm_base_name}-${n}")
    done
}

# Print details of what the script will do.
print_procedure_details () {
    out_bold "Creating the following VMs:\n"
    print_vm_names
    out_bold "VMs will run:\n"
    out_norm "$iso_path\n"
    if [ ! -z "$autoyast" ]
    then
        out_bold "Autoyast file:\n"
        out_norm "$autoyast\n"
    fi
    out_bold "And will reside in:\n"
    out_norm "$img_path\n"
}

# Creates the blank images.
# Assumptions:
#  - qcow2
#  - 1 osd hd per vm
#  - 32 gb base image, 20 gb osd image
create_blank_images () {
    local img_type="qcow2"
    local base_img_size="32G"
    local osd_img_size="20G"

    for n in "${vm_names[@]}"
    do
        echo sudo qemu-img create -f "$img_type" "${img_path}/${n}.${img_type}" "$base_img_size"
        echo sudo qemu-img create -f "$img_type" "${img_path}/${n}-osd-hd.${img_type}" "$osd_img_size"
    done
}

# Install the OS onto the base images
install_os () {
    local vcpus=1
    local ram=1024
    local img_type="qcow2"

    for n in "${vm_names[@]}"
    do
        if [ ! -z "$autoyast" ]
        then
            echo sudo virt-install --vcpus "$vcpus" -r "$ram" --accelerate -n "$n" \
                -f "${img_path}/${n}.${img_type}" \
                --location http://"${www_srv}/${iso_path}" \
                --extra-args "console=tty0 console=ttyS0,115200n8 serial autoyast=http://${www_srv}/${autoyast}"
        else
            echo sudo virt-install --vcpus "$vcpus" -r "$ram" --accelerate -n "$n" \
                -f "${img_path}/${n}.${img_type}" \
                --location http://"${www_srv}/${iso_path}" \
                --extra-args "console=tty0 console=ttyS0,115200n8 serial"
        fi
    done
}

# Parse our command line options
while [ "$#" -ge 1 ]
do
    case $1 in
	-n | --num-vms)
            num_vms="$2"
            shift
	    ;;
        -b | --base-name)
            vm_base_name="$2"
            shift
            ;;
        -i | --iso)
            iso_path="$2"
            shift
            ;;
        -d | --img-destination)
            img_path="$2"
            shift
            ;;
        -a | --autoyast)
            autoyast="$2"
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

# Check for null vars. $autoyast can be null
[[ ! -z "$num_vms" && ! -z "$vm_base_name" && ! -z "$iso_path" && ! -z "$img_path" ]] ||
    out_err_exit "Missing needed parameters.\n"

# Make sure we're running as root
running_as_root

set_vm_names
print_procedure_details

create_blank_images
install_os
