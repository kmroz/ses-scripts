#!/bin/bash
#
# ==============================================================================
# create-ses-vms.sh
# ------------------
#
# A simple scripts that creates a few VM's...
# ==============================================================================

# Fail fast
set -e

# Error codes
success=0
yes=0
failure=1
no=1
assert_err=255

# Some globals
scriptname=$(basename "$0")
www_srv="oak"                 # TODO: make this configurable
img_type="qcow2"              # TODO: make this configurable

# Required params
num_vms=3                     # number of vms to create
vm_base_name=""               # name for vms: foo-1, foo-2, foo-n
vm_names=()                   # array that will hold vm names
iso_path=""                   # path to SLE/openSUSE iso to use
img_path="~/libvirt/images"   # destination of created image

# Optional
autoyast=""                   # autoyast file

txtbold=$(tput bold)
txtnorm=$(tput sgr0)
txtred=$(tput setaf 1)
txtgreen=$(tput setaf 2)

usage_msg="usage: $scriptname <required-params> [options]
required-params:
\t-b, --base-name
\t\tBase name for VMs. A VM will be named as <base-name>-<instance num>.

\t-n, --num-vms
\t\tNumber of vms to create.

\t-i, --iso
\t\tPath to iso as a path off of http://$www_srv/

\t-d, --img-destination
\t\tDestination path for created img. Default: ${img_path}

options:
\t-a, --autoyast
\t\tPath to autyast file as a path off of http://$www_srv/

\t-h, --help
\t\tPrint this usage message.

example:
\t sudo ./create-ses-vms.sh -b firsttest -n 1 -i SLES12-SP2/ -d /home/kmroz/libvirt/images
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
    local msg=$1
    out_bold_red "ERROR: $msg"
    exit "$failure"
}

out_err_usage_exit () {
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
    [[ "$EUID" = 0 ]] || out_err_usage_exit "Run $scriptname as root\n"
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
get_user_consent () {
    local msg="Are you sure you want to proceed?"
    local answers="Y[es]/N[o] (N)"
    local prompt="[$msg - $answers]> "
    local choice=""

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

    while true
    do
	out_bold_green "\n$prompt"
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

# Based on VM name, get the full base image path.
get_base_img_path () {
    local vm_name="$1"

    [[ -z "$vm_name" ]] && assert "Empty image name\n"
    echo "${img_path}/${vm_name}.${img_type}"
}

get_hd_img_path () {
    local vm_name="$1"

    [[ -z "$vm_name" ]] && assert "Empty image name\n"
    echo "${img_path}/${vm_name}-osd-hd.${img_type}"
}

# Creates the blank images.
# Assumptions:
#  - qcow2
#  - 1 osd hd per vm
#  - 32 gb base image, 20 gb osd image
create_blank_images () {
    local base_img_size="32G"
    local osd_img_size="20G"
    local base_img_path=""
    local hd_img_path=""

    for n in "${vm_names[@]}"
    do
	base_img_path=`get_base_img_path $n`
	hd_img_path=`get_hd_img_path $n`
	sudo qemu-img create -f "$img_type" "$base_img_path" "$base_img_size" || out_err_exit "Failed to create: $base_img_path\n"
	sudo qemu-img create -f "$img_type" "$hd_img_path" "$osd_img_size" || out_err_exit "Failed to create: $hd_img_path\n"
    done
}

# Install the OS onto the base images
install_os () {
    local vcpus=1
    local ram=1024
    local base_img_path=""

    for n in "${vm_names[@]}"
    do
        out_bold "About to install $n: "
        out_norm "Connect to console via: "
        out_bold_green "sudo virsh console $n\n"
	base_img_path=`get_base_img_path $n`
        if [ ! -z "$autoyast" ]
        then
            sudo virt-install --vcpus "$vcpus" -r "$ram" --accelerate -n "$n" \
		-f "$base_img_path" \
                --location http://"${www_srv}/${iso_path}" \
		--extra-args "console=tty0 console=ttyS0,115200n8 serial autoyast=http://${www_srv}/${autoyast}" ||
		out_err_exit "Failed to create $n\n"
        else
            sudo virt-install --vcpus "$vcpus" -r "$ram" --accelerate -n "$n" \
		-f "$base_img_path" \
                --location http://"${www_srv}/${iso_path}" \
		--extra-args "console=tty0 console=ttyS0,115200n8 serial" ||
		out_err_exit "Failed to create $n\n"
        fi
    done
}

# Attach disks to VMs and destroy/restart.
attach_disks () {
    local hd_img_path=""

    for n in "${vm_names[@]}"
    do
	hd_img_path=`get_hd_img_path $n`
	out_bold "Attaching disk $hd_img_path to $n\n"
	# Generate xml
	cat << EOT > /tmp/add-disk.xml
<disk type='file' device='disk'>
   <driver name='qemu' type='qcow2' cache='none'/>
   <source file='$hd_img_path'/>
   <target dev='vdb'/>
</disk>
EOT
	# Attach the disk.
	sudo virsh attach-device --config "$n" /tmp/add-disk.xml || out_err_exit "Failed to attach $hd_img_path to $n\n"
	# Destroy and re-start VM for disk to appear.
	sudo virsh destroy "$n" || out_err_exit "Failed to destroy $n\n"
	sudo virsh start "$n" || out_err_exit "Failed to start $n\n"
    done
    rm /tmp/add-disk.xml
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

# Make sure we're running as root
running_as_root

# Check for null vars. $autoyast can be null
[[ ! -z "$num_vms" && ! -z "$vm_base_name" && ! -z "$iso_path" && ! -z "$img_path" ]] ||
    out_err_usage_exit "Missing needed parameters.\n"

set_vm_names
get_user_consent || exit "$success"

create_blank_images
install_os
attach_disks
