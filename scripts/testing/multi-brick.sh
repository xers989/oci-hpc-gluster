#!/bin/bash

config_node()
{
    systemctl stop firewalld
    systemctl disable firewalld
    setenforce 0
    yum-config-manager --add-repo http://yum.oracle.com/repo/OracleLinux/OL7/gluster312/x86_64
    yum install -y glusterfs-server samba git
    cd ~
    git clone https://github.com/oci-hpc/oci-hpc-ref-arch

    touch /var/log/CONFIG_COMPLETE
}

create_pvolume()
{
    if [ `lsblk -d --noheadings | awk '{print $1}' | grep nvme0n1` = "nvme0n1" ]; then NVME=true; else NVME=false; fi
    for i in `lsblk -d --noheadings | awk '{print $1}'`
    do
        if [ $i = "sda" ]; then  next
        else
            pvcreate --dataalignment 256K /dev/$i
            vgcreate vg_gluster${i} /dev/$i
        fi
    done

    vgdisplay
}

config_gluster()
{
    echo CONFIG GLUSTER
    vg_list=$(vgdisplay | grep "VG Name" | awk '{ print $3 }')
    for vg in $vg_list
    do
      lvcreate -l 100%VG -n "lv_${vg}" $vg
      lvdisplay
      mkfs.xfs -f -i size=512 /dev/$vg/lv_${vg}
      mkdir -p /bricks/$vg
      mount /dev/$vg/lv_${vg} /bricks/$vg
      echo "/dev/$vg/lv_${vg}  /bricks/$vg    xfs     defaults,_netdev  0 0" >> /etc/fstab
    done

    ls -d /bricks/* | while read x
    do
      mkdir -p ${x}/multibrick
    done

    sed -i '/search/d' /etc/resolv.conf 
    echo "search baremetal.oraclevcn.com gluster_subnet-d6700.baremetal.oraclevcn.com publicsubnetad1.baremetal.oraclevcn.com publicsubnetad3.baremetal.oraclevcn.com localdomain" >> /etc/resolv.conf
    chattr -R +i /etc/resolv.conf

    systemctl enable glusterd
    systemctl start glusterd

}

config_node
create_pvolume
config_gluster
