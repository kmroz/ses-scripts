#!/bin/bash
# ==============================================================================
# deploy-ses.sh
# -------------
#
# Simple script to deploy a SES2 or SES3 installation.  Attempts to automate as much as
# possible using ceph-deploy.
# Assumes that correct repos are added to the entire cluster.
# ==============================================================================

# Error codes
success=0
yes=0
failure=1
no=1
assert_err=255

# globals
scriptname=$(basename "$0")
nodes=() # List of nodes we will operate on.
ses_ver=""
cephadm_user=""

txtbold=$(tput bold)
txtnorm=$(tput sgr0)
txtred=$(tput setaf 1)
txtgreen=$(tput setaf 2)

usage_msg="\nusage: $scriptname <ses2 | ses3> <admin_node> [node list]\n"

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

out_fail_exit () {
    local msg=$1
    out_bold_red "$msg"
    exit "$failure"
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

running_as_user_ceph () {
    [[ `whoami` = "$cephadm_user" ]]
}

# Get our admin node (which will also run Ceph) ready.
prepare_admin_node () {
    # Generate keys
    out_bold "\tGenerating SSH keys... "
    [[ -d ~/.ssh ]] || mkdir ~/.ssh
    [[ -e ~/.ssh/id_rsa ]] || ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa &> /dev/null
    out_bold_green "done\n"

    # Distribute keys to all nodes
    out_bold "\tDistributing SSH key to all nodes (including this node)...\n"
    for n in "${nodes[@]}"
    do
        out_bold "${cephadm_user}@$n\n"
        ssh-copy-id "${cephadm_user}"@"$n"
    done
    out_bold_green "\tdone\n"
}

set_passwordless_sudo () {
    for n in "${nodes[@]}"
    do
        out_bold "root@$n\n"
        ssh root@"$n" << EOF
echo "${cephadm_user} ALL = (root) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/${cephadm_user} &> /dev/null
sudo chmod 0440 /etc/sudoers.d/${cephadm_user}
EOF
    done

    out_bold "done\n"
}

install_ceph () {
    # First install ceph/ceph-deploy on admin node (here)
    out_bold "\tInstalling Ceph on admin (${nodes[0]}) node...\n"
    sudo zypper --non-interactive install ceph || return "$failure"
    sudo zypper --non-interactive install ceph-deploy || return "$failure"
    out_bold_green "\tdone\n"
    # Install ceph on all nodes (repeats attempt to install locally as well)
    out_bold "\tInstalling Ceph on remainder of nodes...\n"
    ceph-deploy install "${nodes[@]}" || return "$failure"
    out_bold_green "\tdone\n"
    out_bold "\tDeploying new Ceph cluster...\n"
    ceph-deploy new "${nodes[@]}" || return "$failure"
    out_bold_green "\tdone\n"
    out_bold "\tCreating MONs...\n"
    ceph-deploy mon create-initial || return "$failure"
    out_bold_green "\tdone\n"
    out_bold "\tPreparing OSDs...\n"
    for n in "${nodes[@]}"
    do
        # Prepare osds. Assumes we have /dev/vdb devoted to OSD.
        ceph-deploy osd prepare $n:vdb || return "$failure"
    done
    out_bold_green "\tdone\n"
    # Install rgw on admin (this) node.
    out_bold "\tInstalling RGW on admin (${nodes[0]}) node...\n"
    ceph-deploy --overwrite-conf rgw create "${nodes[0]}"
    out_bold_greep "\tdone\n"
    out_bold "\tGathering keys on admin (${nodes[0]}) node...\n"
    ceph-deploy gatherkeys "${nodes[0]}"
}

# ==============================================================================
# main()

[[ "$#" < "2" ]] && usage_exit "$failure"

ses_ver="$1"
[[ "$ses_ver" = "ses2" || "$ses_ver" = "ses3" ]] || usage_exit "$failure"
[[ "$ses_ver" = "ses2" ]] && cephadm_user="ceph" || cephadm_user="cephadm"
shift
nodes=( "$@" )

out_bold_green "==========================\n"
out_bold_green "Admin Node: Deploying ${ses_ver}\n"
out_bold_green "==========================\n"

out_bold "\nChecking if running as user '${cephadm_user}'... "
running_as_user_ceph && out_bold "yes\n" || out_fail_exit "no\n"

out_bold "\nPreparing admin (${nodes[0]}) node...\n"
prepare_admin_node && out_bold_green "done\n" || out_fail_exit "failed\n"

out_bold "\nSetting passwordless sudo on all nodes (root password needed)...\n"
set_passwordless_sudo && out_bold_green "done\n" || out_fail_exit "failed\n"

out_bold "\nInstalling Ceph on all nodes...\n"
install_ceph && out_bold "done\n" || out_fail_exit "failed\n"

out_bold_green "\nFinished\n"
