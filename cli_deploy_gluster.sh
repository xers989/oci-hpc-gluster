#!/bin/bash
#set -x
source variables

create_key()
{
  #CREATE KEY
  echo -e "${GREEN}CREATING key${NC}"
  ssh-keygen -f $PRE.key -t rsa -N '' > /dev/null
}

create_network()
{
  #CREATE NETWORK
  echo -e "${GREEN}CREATING glusterfs-network ${NC}"
  if [ -z "$vcn_id" ]
  then
    echo Create Network
    V=`oci network vcn create --profile $profile --region $region --cidr-block $subnet.0/24 --compartment-id $compartment_id --display-name "gluster_vcn-$PRE" --wait-for-state AVAILABLE | jq -r '.data.id'`
    NG=`oci network internet-gateway create --profile $profile --region $region -c $compartment_id --vcn-id $V --is-enabled TRUE --display-name "gluster_ng-$PRE" --wait-for-state AVAILABLE | jq -r '.data.id'`
    RT=`oci network route-table create --profile $profile --region $region -c $compartment_id --vcn-id $V --display-name "gluster_rt-$PRE" --wait-for-state AVAILABLE --route-rules '[{"cidrBlock":"0.0.0.0/0","networkEntityId":"'$NG'"}]' | jq -r '.data.id'`
    SL=`oci network security-list create --profile $profile --region $region -c $compartment_id --vcn-id $V --display-name "gluster_sl-$PRE" --wait-for-state AVAILABLE --egress-security-rules '[{"destination":  "0.0.0.0/0",  "protocol": "all", "isStateless":  null}]' --ingress-security-rules '[{"source":  "0.0.0.0/0",  "protocol": "all", "isStateless":  null}]' | jq -r '.data.id'`
    S=`oci network subnet create -c $compartment_id --vcn-id $V --profile $profile --region $region --availability-domain "$AD" --display-name "gluster_subnet-$PRE" --cidr-block "$subnet.0/26" --route-table-id $RT --security-list-ids '["'$SL'"]' --wait-for-state AVAILABLE | jq -r '.data.id'`
  else
    echo Existing Network Present
    V=$vcn_id
    S=$subnet_id
    NG=`oci network internet-gateway list --compartment-id $compartment_id --vcn-id $vcn_id | jq -r .data[].id`
    SL=`oci network security-list create --profile $profile --region $region -c $compartment_id --vcn-id $V --display-name "gluster_sl-$PRE" --wait-for-state AVAILABLE --egress-security-rules '[{"destination":  "0.0.0.0/0",  "protocol": "all", "isStateless":  null}]' --ingress-security-rules '[{"source":  "0.0.0.0/0",  "protocol": "all", "isStateless":  null}]' | jq -r '.data.id'`
    subnet=`oci network subnet list -c $compartment_id --vcn-id $V | jq -r '.data[]."virtual-router-ip"' | awk -F. '{print $1"."$2"."$3}'`
  fi
}

create_headnode()
{
  #CREATE BLOCK AND HEADNODE
  priv_ip_list=''
  BLKSIZE_GB=`expr $blksize_tb \* 1024`
  for i in `seq $server_nodes -1 1`; do
    echo -e "${GREEN}CREATING glusterfs-server$i ${NC}"
    priv_ip_list=$priv_ip_list' '$subnet.1$i
    masterID=`oci compute instance launch $INFO --shape "$gluster_server_shape" -c $compartment_id --display-name "gluster-server-$PRE-$i" --image-id $OS --subnet-id $S --private-ip $subnet.1$i --wait-for-state RUNNING --user-data-file scripts/gluster_configure.sh --ssh-authorized-keys-file $PRE.key.pub | jq -r '.data.id'`
    if [ "$cifs_multi_channel" = "yes" ]
    then
      echo -e "${GREEN}Creating secondary vnic for CIFS multi-channel support"
      svnic=`oci compute instance attach-vnic --instance-id $masterID --subnet-id $S --nic-index 1 --assign-public-ip false --vnic-display-name "gluster-server-$PRE-$i-svnic" --wait`
    fi
    for k in `seq 1 $blk_num`; do
      echo -e "${GREEN}CREATING glusterfs-block-$PRE-$i-$k ${NC}"
      BV=`oci bv volume create $INFO --display-name "gluster-block-$PRE-$i-$k" --size-in-gbs $BLKSIZE_GB --wait-for-state AVAILABLE | jq -r '.data.id'`;
    done
  done
}

configure_storage()
{
  IID=`oci compute instance list --compartment-id $compartment_id --profile $profile --region $region | jq -r '.data[] | select(."display-name" | contains ("'$PRE-$i'")) | .id'`
  IP=`oci compute instance list-vnics --profile $profile --region $region --instance-id $IID | jq -r '.data[]."public-ip"'`
  echo -e "${GREEN}ADDING key to head node${NC}"

  for i in `seq $server_nodes -1 1`; do
    n=0
    until [ $n -ge 5 ]; do scp -o StrictHostKeyChecking=no -i $PRE.key $PRE.key $USER@$IP:/home/$USER/.ssh/id_rsa && break; n=$[$n+1]; sleep 30; done
    ssh -i $PRE.key $USER@$IP 'while [ ! -f /var/log/CONFIG_COMPLETE ]; do sleep 30; echo "WAITING for node to complete configuration: `date +%T`"; done'
    IID=`oci compute instance list --compartment-id $compartment_id --profile $profile --region $region | jq -r '.data[] | select(."display-name" | contains ("'$PRE-$i'")) | .id'`
    IP=`oci compute instance list-vnics --profile $profile --region $region --instance-id $IID | jq -r '.data[]."public-ip"'`

    for k in `seq 1 $blk_num`; do
      echo -e "${GREEN}ATTACHING glusterfs-block-$PRE-$i-$k ${NC}"
      BVID=`oci bv volume list --compartment-id $compartment_id --profile $profile --region $region | jq -r '.data[] | select(."display-name" | contains ("'gluster-block-$PRE-$i-$k'")) | .id'`
      attachID=`oci compute volume-attachment attach --profile $profile --region $region --instance-id $IID --type iscsi --volume-id $BVID --wait-for-state ATTACHED | jq -r '.data.id'`
      attachIQN=`oci compute volume-attachment get --volume-attachment-id $attachID --profile $profile --region $region | jq -r .data.iqn`
      attachIPV4=`oci compute volume-attachment get --volume-attachment-id $attachID --profile $profile --region $region | jq -r .data.ipv4`
      ssh -o StrictHostKeyChecking=no -i $PRE.key $USER@$IP sudo sh /root/oci-hpc-ref-arch/scripts/mount_block.sh attach $attachIQN $attachIPV4
    done
    echo -e "${GREEN}CONFIGURING gluster-server-$PRE-$i ${NC}"
    ssh -o StrictHostKeyChecking=no -i $PRE.key $USER@$IP sudo sh /var/lib/cloud/instance/user-data.txt config_node $server_nodes $subnet
  done
  scp -i $PRE.key -r scripts/ $USER@$IP:/home/$USER/
  ip_list=$(echo $priv_ip_list | cut -d ' ' -f-`expr $server_nodes - 1`)
  sleep 30
  echo $ip_list
  ssh -i $PRE.key $USER@$IP "chmod +x scripts/*.sh; cd /home/$USER/scripts/; pwd; sudo -E bash -c '/home/$USER/scripts/gluster_cifs_configure.sh -v glustervol -m $subnet.11 -n "$ip_list" -b "/bricks/brick1" -u opc -p "password123"-s "$cifs_multi_channel"'"
}


create_remove()
{
cat << EOF >> removeCluster-$PRE.sh
#!/bin/bash
export masterIP=$masterIP
export masterPRVIP=$masterPRVIP
export USER=$USER
export compartment_id=$compartment_id
export PRE=$PRE
export region=$region
export AD=$AD
export V=$V
export NG=$NG
export RT=$RT
export SL=$SL
export S=$S
export BV=$BV
export masterID=$masterID
export profile=$profile
EOF

cat << "EOF" >> removeCluster-$PRE.sh
echo -e "Removing: Gluster Nodes"
for instanceid in $(oci compute instance list --profile $profile --region $region --compartment-id $compartment_id | jq -r '.data[] | select(."display-name" | contains ("'$PRE'")) | .id'); do oci compute instance terminate --profile $profile --region $region --instance-id $instanceid --force; done
sleep 60
echo -e "Removing: Blocks"
for id in `oci bv volume list --compartment-id $compartment_id --profile $profile --region $region | jq -r '.data[] | select(."display-name" | contains ("'$PRE'")) | .id'`; do oci bv volume delete --profile $profile --region $region --volume-id $id --force; done
sleep 60
echo -e "Removing: Subnet, Route Table, Security List, Gateway, and VCN"
oci network subnet delete --profile $profile --region $region --subnet-id $S --force
sleep 10
oci network route-table delete --profile $profile --region $region --rt-id $RT --force
sleep 10
oci network security-list delete --profile $profile --region $region --security-list-id $SL --force
sleep 10
oci network internet-gateway delete --profile $profile --region $region --ig-id $NG --force
sleep 10
oci network vcn delete --profile $profile --region $region --vcn-id $V --force

mv removeCluster-$PRE.sh .removeCluster-$PRE.sh
mv $PRE.key .$PRE.key
mv $PRE.key.pub .$PRE.key.pub
echo -e "Complete"
EOF
  chmod +x removeCluster-$PRE*.sh

}
echo Creating GlusterFS $PRE
STARTTIME=`date +%T' '%D`

create_key
create_network
create_headnode
configure_storage
create_remove

echo Started: $STARTTIME
echo Finished: `date +%T' '%D`
echo GlusterFS $PRE IP is: $IP
