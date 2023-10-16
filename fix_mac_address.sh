#!/bin/bash

# fix_mac_address.sh - Sets MAC address for VM to new custom prefix
# fix_mac_address.sh <VM ID> <PREFIX>
#
# example:   fix_mac_address.sh fc770413-975e-4d24-b480-539776101147 02:01:20
#
# Collect info on VM
acli vm.get $1 > /tmp/vm_info
NETWORK=`cat /tmp/vm_info | grep -i network_name | awk -F: '{print $NF}'`
OLDMAC=`cat /tmp/vm_info | grep -i mac_add | cut -d'"' -f2`
NEWMAC=`echo $OLDMAC | sed "s/^......../$2/g"`
NAME=`cat /tmp/vm_info | grep -m 1 name | cut -d '"' -f2`

echo $NAME,$NETWORK,$OLDMAC,$NEWMAC >> /tmp/mac_change_log
echo
echo "====================="
echo "$NAME"
echo "====================="
echo
echo "Deleting old NIC"
echo "---------------------"
acli vm.nic_delete $1 $OLDMAC

echo
echo "Creating new NIC"
echo "---------------------"
acli vm.nic_create $1 network=$NETWORK mac=$NEWMAC

echo
echo "Updating Boot Order"
echo "---------------------"
acli vm.update_boot_device $1 boot_device_order=kNetwork,kCdrom,kDisk
acli vm.update_boot_device $1 mac_addr=$NEWMAC
echo
echo "Done"
echo

