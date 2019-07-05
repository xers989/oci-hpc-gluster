#!/bin/bash

#######################################################################################################################################################
### This bootstrap script runs on glusterFS server and configures the following
### 1- install gluster packages
### 2- formats the disks (NVME), creates a LVM (striped) LV called "brick" (XFS)
### 3- fixes the resolve.conf file. GlusterFS needs DNS to work properly so make sure you update the below domains to match your environment
### 4- disable local firewall. Feel free to update this script to open only the required ports.
### 5- install and configure a gluster volume called glustervol using server1-mybrick, server2-mybrick (distributed)
###
######################################################################################################################################################

exec 2>/dev/null

lvm_stripe_size="64k"
gluster_yum_release="http://yum.oracle.com/repo/OracleLinux/OL7/gluster312/x86_64"
oci_hpc_git="https://github.com/oci-hpc/oci-hpc-ref-arch"


config_node()
{
    # Disable firewalld TODO: Add firewall settings to node in future rev.
    systemctl stop firewalld
    systemctl disable firewalld

    # Disable Selinux TODO: Enable Selinux
    setenforce 0

    # Enable latest Oracle Linux Gluster release
    yum-config-manager --add-repo $gluster_yum_release
    yum install -y glusterfs-server samba git nvme-cli

    # Clone OCI-HPC Reference Architecture
    cd ~
    git clone $oci_hpc_git

    touch /var/log/CONFIG_COMPLETE
}

create_pvolume()
{
    # Check if NVME
    if [ `lsblk -d --noheadings | awk '{print $1}' | grep nvme0n1` = "nvme0n1" ]; then NVME=true; else NVME=false; fi
    
    # Gather list of block devices for brick config
    blk_lst=$(lsblk -d --noheadings | grep -v sda | awk '{ print $1 }')
    blk_cnt=$(lsblk -d --noheadings | grep -v sda | wc -l)

    # Configure physical volumes and volume group
    for pvol in $blk_lst
    do 
            pvcreate /dev/$pvol
            vgcreate vg_gluster /dev/$pvol
            vgextend vg_gluster /dev/$pvol
    done

    vgdisplay
    config_gluster
}

config_gluster()
{
    echo CONFIG GLUSTER
    # Create Logical Volume for Gluster Brick
    lvcreate -y -l 100%VG --stripes $blk_cnt --stripesize $lvm_stripe_size -n brick1 vg_gluster
    lvdisplay
    
    # Create XFS filesystem with Inodes set at 512 and Directory block size at 8192
    # and set the su and sw for optimal stripe performance
    mkfs.xfs -f -i size=512 -n size=8192 -d su=${lvm_stripe_size},sw=${blk_cnt} /dev/vg_gluster/brick1
    mkdir -p /bricks/brick1
    mount -o noatime,inode64,nobarrier /dev/vg_gluster/brick1 /bricks/brick1
    echo "/dev/vg_gluster/brick1  /bricks/brick1    xfs     noatime,inode64,nobarrier  1 2" >> /etc/fstab
    df -h
    
    # Setup DNS search path
    sed -i '/search/d' /etc/resolv.conf 
    echo "search baremetal.oraclevcn.com gluster_subnet-d6700.baremetal.oraclevcn.com publicsubnetad1.baremetal.oraclevcn.com publicsubnetad3.baremetal.oraclevcn.com localdomain" >> /etc/resolv.conf
    chattr -R +i /etc/resolv.conf
    
    # Start gluster services
    systemctl enable glusterd.service
    systemctl start glusterd.service
    
    # Create gluster brick
    mkdir /bricks/brick1/brick

}

config_node
create_pvolume
config_gluster