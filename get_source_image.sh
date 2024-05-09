#!/bin/bash

# ./get_source_image.sh <VM Name>
# ---------------------------------------------
# Grabs the image that a VM was built off of
# Assumes boot disk is at scsi.0 (99% of cases this is true)

VM_BOOT_SOURCE_UUID=`acli vm.disk_get $1 disk_addr=scsi.0 | grep source_vmdisk_uuid | awk '{print $NF}'`

if [ -z "${VM_BOOT_SOURCE_UUID}" ]; then
    echo "VM does not appear to be based on a disk image"
    exit 1
fi
    
for i in $(acli image.list | awk '{print $NF}' | tail -n +2)
do
  if [ "$(acli image.get ${i} | grep -c $VM_BOOT_SOURCE_UUID)" -ge 1 ]; then
      IMAGE_NAME=`acli image.get ${i} | grep name | awk -F: '{print $2}' | xargs`
      echo "VM is image of: $IMAGE_NAME"
      exit 0
  fi
done

SOURCE_VM=`acli vm.get $1 | grep source_vm_uuid | awk '{print $2}' | xargs`

if [ -z "${SOURCE_VM}" ]; then
    echo "VM does not appear to be a clone or based off of an available image"
    exit 1
fi

SOURCE_VM_NAME=`acli vm.get ${SOURCE_VM} | grep " name:"| awk -F: '{print $2}' | xargs`
echo "VM is clone of: $SOURCE_VM_NAME"
