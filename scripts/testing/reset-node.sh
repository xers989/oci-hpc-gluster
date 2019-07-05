#!/bin/bash

# Reset Gluster Specific Settings
umount /glusterpermset
gluster volume stop glustervol force --mode=script
service smb stop
service ctdb stop
gluster volume stop ctdb force --mode=script
gluster volume delete glustervol --mode=script
gluster volume delete ctdb --mode=script
service glusterfsd stop
service glusterfs stop
# Remove LVM setup
rm -rf /bricks/brick1/*
umount /bricks/brick1
lvremove vg_gluster
vgremove vg_gluster

if [ `lsblk -d --noheadings | awk '{print $1}' | grep nvme0n1` = "nvme0n1" ]; then NVME=true; else NVME=false; fi

for i in `lsblk -d --noheadings | awk '{print $1}'`
do
  if [ $i = "sda" ]; then next
  else
    pvremove /dev/$i
  fi
done

sed -i '/\/dev\/vg_gluster/d' /etc/fstab
rmdir /glusterpermset
