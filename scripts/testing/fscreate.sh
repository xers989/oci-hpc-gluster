#!/bin/bash
node1=$1
node2=$2


echo CONFIGURING GLUSTER SERVER

gluster volume create glustervol transport tcp ${node1}:/bricks/brick1/brick force
sleep 10

gluster volume add-brick glustervol ${node2}:/bricks/brick1/brick force

gluster volume start glustervol force
sleep 20
gluster volume start glustervol force
gluster volume status
gluster volume info

