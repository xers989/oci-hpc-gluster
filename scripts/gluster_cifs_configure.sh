#!/bin/bash
# Name: gluster_cifs_configure.sh
# Author: Chuck Gilbert <chuck.gilbert@oracle.com>
# Description: This script takes an existing GlusterFS Volume,
#   and enables CIFS export of the volume for access of windows clients.
#

# Exit on any errors
set -e

# Source Functions
. ./functions

# print_usage(): Function to print script usage
function print_usage() {
  echo "$0 -v volume -m \"masternode ip address\" -n \"list of workernode addresses\" -b \"brick path\" -u \"SMB Username\" -p \"SMB Password\" -s \"Secondary VNIC yes|no\" "
  echo "Example: $0 -v examplevolume -m 1.1.1.1 -n \"1.1.1.2 1.1.1.3 1.1.1.4\" -b \"/brick/mybrick\" -u \"opc\" -p \"password123\" -s \"yes\""
  exit 1
}

# Check Arg Length
if [ "$#" = 0 ]
then
  print_usage
fi

# Get Commandline Options
while getopts ":v:m:n:b:u:p:s:" opt; do
  case $opt in
  v)
    VOLNAME=$OPTARG
    ;;
  m)
    MASTER_NODE=$OPTARG
    ;;
  n)
    NODE_LIST=$OPTARG
    ;;
  b)
    BRICK=$OPTARG
    ;;
  u)
    SMBUSERNAME=$OPTARG
    ;;
  p)
    SMBPASSWORD=$OPTARG
    ;;
  s)
    SECONDARY_VNIC=$OPTARG
    ;;
  \?)
    echo "Invalid option: -$OPTARG" >&2
    print_usage
    ;;
  esac
done

# Install CTDB and SMB Prereqs
install_gluster_smb_reqs

# Tuned Setup
tuned_config

# Update the SMB Auto Start(Only) Scripts
# and enable SMB for clustering
update_smb_auto_start
enable_smb_clustering

# Update the CTDB Auto Start/Stop Scripts
update_ctdb_auto_scripts

# Create the volume needed for CTDB if on the master
# glusterfs server only.
ret=$(check_master_node $MASTER_NODE)

if [ "$ret" = "0" ]
then
  create_ctdb_volume "$BRICK/ctdb" "$MASTER_NODE $NODE_LIST"
fi

# Create the list of nodes in the CTDB cluster
create_ctdb_cluster_list "$MASTER_NODE $NODE_LIST"

# Start CTDB Volume
start_ctdb

# Tune desired volume for Samba Metadata Performance
tune_gluster_for_smb $VOLNAME

# Restart GlusterFS Daemon
restart_glusterd

# Enable and Start Samba
enable_smb
start_smb

# Set Username/Password for accessing share
set_smbpasswd $SMBUSERNAME $SMBPASSWORD

# Restart Gluster Volume
restart_volume $VOLNAME

# Setup ACL perms
ret=$(check_master_node $MASTER_NODE)

if [ "$ret" = "0" ]
then
  set_perms $VOLNAME $SMBUSERNAME
fi

if [ "$SECONDARY_VNIC" = "yes" ]
then
  secondary_vnic_config
fi

# end of script