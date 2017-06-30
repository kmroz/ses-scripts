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

usage_msg="\nusage: $scriptname <ses_ver> <admin_node> [node list]\n"

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

running_as_root () {
    [[ `whoami` = "root" ]]
}

cephadm_user_exists () {
    cephadm_user="$1"

    id -u "$cephadm_user" &> /dev/null

    if [ $? = 1 ]
    then
        out_bold_red "no\n"
        out_bold "\tCreating $cephadm_user\n"
        useradd --create-home "$cephadm_user"
        out_bold "\tSetting password\n"
        passwd "$cephadm_user"
    else
        out_bold "yes\n"
    fi
}

# Get our admin node (which will also run Ceph) ready.
prepare_admin_node () {
    # Generate keys
    out_bold "\tGenerating SSH keys... "
    sudo -u "$cephadm_user" -H bash -c "[[ -d ~/.ssh ]] || mkdir ~/.ssh"
    sudo -u "$cephadm_user" -H bash -c "[[ -e ~/.ssh/id_rsa ]] || ssh-keygen -t rsa -N \"\" -f ~/.ssh/id_rsa &> /dev/null"
    out_bold_green "done\n"

    # Distribute keys to all nodes
    out_bold "\tDistributing SSH key to all nodes (including this node)...\n"
    for n in "${nodes[@]}"
    do
        out_bold "${cephadm_user}@$n\n"
        # StrictHostKeyChecking=no prevents fingerprint checking and the need for manual input of 'yes'.
        sudo -u "$cephadm_user" -H bash -c "ssh-copy-id -o StrictHostKeyChecking=no \"${cephadm_user}\"@\"$n\" &> /dev/null"
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

add_salt_master_to_hosts () {
    # Do our best to get the admin IP address.  Assuming first one wins.
    # Matches "src" in something like:
    #   10.0.0.0/24 dev eth0  proto kernel  scope link  src 10.0.0.234 
    # and stores the next column after (ie. the address).
    ipaddrs=( `ip r | awk '{for(i=1;i<=NF;i++)if($i~/src/)print $(i+1)}'` )
    ip=${ipaddrs[0]}

    # As of SES5, the salt master needs to have it's hostname entry prior to
    # the salt entry to prevent socket.getfqdn() from thinking the hostname
    # is salt :/
    hostname=`hostname --fqdn`
    echo "$ip" "$hostname" >> /etc/hosts

    for n in "${nodes[@]}"
    do
        out_bold "Adding $ip to ${n}:/etc/hosts\n"
        ssh root@"$n" "echo $ip salt >> /etc/hosts"
    done
}

_install_ceph_via_ceph_deploy () {
    # First install ceph/ceph-deploy on admin node (here)
    out_bold "\tInstalling Ceph on admin (${nodes[0]}) node...\n"
    out_bold "\tChanging to /home/$cephadm_user...\n"
    cd "/home/$cephadm_user"
    zypper --non-interactive install ceph || return "$failure"
    zypper --non-interactive install ceph-deploy || return "$failure"
    out_bold_green "\tdone\n"
    # Install ceph on all nodes (repeats attempt to install locally as well)
    out_bold "\tInstalling Ceph on remainder of nodes...\n"
    sudo -u "$cephadm_user" -H bash -c "ceph-deploy install ${nodes[*]} || return \"$failure\""
    out_bold_green "\tdone\n"
    out_bold "\tDeploying new Ceph cluster...\n"
    sudo -u "$cephadm_user" -H bash -c "ceph-deploy new ${nodes[*]} || return \"$failure\""
    out_bold_green "\tdone\n"
    out_bold "\tCreating MONs...\n"
    sudo -u "$cephadm_user" -H bash -c "ceph-deploy mon create-initial || return \"$failure\""
    out_bold_green "\tdone\n"
    out_bold "\tPreparing OSDs...\n"
    for n in "${nodes[@]}"
    do
        # Prepare osds. Assumes we have /dev/vdb devoted to OSD.
        sudo -u "$cephadm_user" -H bash -c "ceph-deploy osd prepare \"$n\":vdb || return \"$failure\""
    done
    out_bold_green "\tdone\n"
    # Install rgw on admin (this) node.
    out_bold "\tInstalling RGW on admin (${nodes[0]}) node...\n"
    sudo -u "$cephadm_user" -H bash -c "ceph-deploy --overwrite-conf rgw create ${nodes[0]}"
    out_bold_green "\tdone\n"
    out_bold "\tGathering keys on admin (${nodes[0]}) node...\n"
    sudo -u "$cephadm_user" -H bash -c "ceph-deploy gatherkeys ${nodes[0]}"
    out_bold "\tCopying client admin keyring to /etc/ceph/\n"
    cp /home/$cephadm_user/ceph.client.admin.keyring /etc/ceph/
}

_install_ceph_via_deepsea () {
    # Make sure minions can reach salt master
    add_salt_master_to_hosts

    # TODO Currently this only installs salt/deepsea and does not generate
    # any configs/run any stages.
    zypper --non-interactive in salt-master
    systemctl start salt-master
    systemctl enable salt-master
    for n in "${nodes[@]}"
    do
        ssh root@$n 'zypper --non-interactive in salt-minion'
        ssh root@$n 'systemctl start salt-minion'
        ssh root@$n 'systemctl enable salt-minion'
    done

    salt-key -L
    salt-key -A -y

    zypper --non-interactive in deepsea

    out_bold_green "Now proceed with DeepSea\n"
}

install_ceph () {
    [[ "$ses_ver" = "ses2" || "$ses_ver" = "ses3" ]] && _install_ceph_via_ceph_deploy || _install_ceph_via_deepsea
}

# ==============================================================================
# main()

[[ "$#" < "2" ]] && usage_exit "$failure"

ses_ver="$1"
ses_ver_found=false
for ver in "ses"{2..5} # Dictates supported versions of SES.
do
    [[ "$ses_ver" = "$ver" ]] && ses_ver_found=true
done
[[ $ses_ver_found = true ]] || usage_exit "$failure"

if [ "$ses_ver" = "ses2" ]
then
    cephadm_user="ceph"
elif [ "$ses_ver" = "ses3" ]
then
    cephadm_user="cephadm"
else
    cephadm_user="root"
fi
shift
nodes=( "$@" )

out_bold_green "==========================\n"
out_bold_green "Admin Node: Deploying ${ses_ver}\n"
out_bold_green "==========================\n"

out_bold "\nChecking if running as root... "
running_as_root && out_bold "yes\n" || out_fail_exit "no\n"

out_bold "\nChecking if user $cephadm_user exists... "
cephadm_user_exists "$cephadm_user"

out_bold "\nSetting passwordless sudo on all nodes (root password needed)...\n\n"
set_passwordless_sudo || out_fail_exit "failed\n"

out_bold "\nPreparing admin (${nodes[0]}) node...\n\n"
prepare_admin_node || out_fail_exit "failed\n"

out_bold "\nInstalling SES\n\n"
install_ceph || out_fail_exit "failed\n"

out_bold_green "\nFinished\n"
