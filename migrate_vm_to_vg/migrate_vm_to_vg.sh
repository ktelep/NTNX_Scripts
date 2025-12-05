#!/bin/bash

# Move all VM disks except scsi.0 to a Nutanix Volume Group

LOAD_BALANCE_VG="true"

# Ask user for input
read -p "Enter VM name: " VM_NAME
read -p "Enter Volume Group name: " VG_NAME

if [[ -z "$VM_NAME" || -z "$VG_NAME" ]]; then
    echo "VM name and Volume Group name are required."
    exit 1
fi

# Check VM exists
if ! acli vm.get "$VM_NAME" &>/dev/null; then
    echo "ERROR: VM '$VM_NAME' not found."
    exit 1
fi

echo ""
echo "Confirming VM is powered off"
VM_STATE=$(acli vm.get "$VM_NAME" | grep "\sstate" | awk '{print $2}' | sed 's/\"//g')
if [[ "$VM_STATE" != "kOff" ]]; then
    echo "ERROR: VM '$VM_NAME' is not powered off. Please power off the VM and try again."
    exit 1
fi

echo ""
echo "Collecting disks for VM: $VM_NAME"
echo ""

# Get all disks except scsi.0
DISKS=$(acli vm.disk_list "$VM_NAME" | grep -i "scsi" | awk '{print $1"."$2}' | grep -v "scsi.0")

if [[ -z "$DISKS" ]]; then
    echo "No disks found other than scsi.0. Nothing to move."
    exit 0
fi

if acli vg.list | grep -qw "$VG_NAME"; then
    echo "WARNING: Volume Group '$VG_NAME' already exists."
    echo "Disks will be added to the existing Volume Group."
    echo ""
fi

echo "The following disks will be moved to Volume Group: $VG_NAME"
echo "-----------------------------------------------------------"
for DISK in $DISKS; do
    SIZE=$(acli vm.disk_get "$VM_NAME" disk_addr="$DISK" | grep "size:" | awk '{print $2/1024/1024/1024 " GB"}')
    echo "- $DISK (Size: $SIZE)"
done
echo ""

echo "The following disks will NOT be moved"
echo "-----------------------------------------------------------"
SIZE=$(acli vm.disk_get "$VM_NAME" disk_addr="scsi.0" | grep "size:" | awk '{print $2/1024/1024/1024 " GB"}')
echo "- scsi.0 (Size: $SIZE)"

echo ""
read -p "Are you sure you want to proceed? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    echo "Operation cancelled."
    exit 0
fi

# Check if Volume Group exists
if ! acli vg.list | grep -qw "$VG_NAME"; then
    echo ""
    echo "Creating new Volume Group: $VG_NAME"
    acli vg.create "$VG_NAME"
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to create volume group."
        exit 1
    fi
    echo ""
    echo "Setting load balancing option to $LOAD_BALANCE_VG"
    acli vg.update "$VG_NAME" load_balance_vm_attachments="$LOAD_BALANCE_VG"
else
    echo ""
    echo "Using existing Volume Group: $VG_NAME"
fi

sleep 5

echo "Taking PE level snapshot of VM"
acli vm.snapshot_create "$VM_NAME" snapshot_name_list="Pre-VG Migration Snapshot $(date +%Y%m%d%H%M%S)" 
if [[ $? -ne 0 ]]; then
    echo "ERROR: Unable to take a snapshot of the VM. Aborting."
    exit 1
fi

echo ""
echo "Cloning disks to Volume Group"
for DISK in $DISKS; do
    echo "Adding $DISK to Volume Group"
    acli vg.disk_create $VG_NAME clone_from_vmdisk=vm:$VM_NAME:$DISK
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Error cloning disk $DISK to Volume Group. Aborting."
        echo "Remove any disks already added to the Volume Group before retrying."
        exit 1
    fi
done


echo ""
echo "Detaching disks from VM"
echo ""
echo "** Respond 'yes' to any prompts, or you will have a duplicate disk attached to the VM."
echo "** If we have made it to this point, we've successfully cloned the disks into the new VG"
echo "** and have a snapshot to revert to if needed."

for DISK in $DISKS; do
    echo ""
    echo "Removing $DISK from VM"
    acli vm.disk_delete "$VM_NAME" disk_addr="$DISK"
done

echo ""
echo "Attaching Volume Group to VM"
acli vg.attach_to_vm "$VG_NAME" "$VM_NAME"
echo "Volume Group '$VG_NAME' has been successfully attached to VM '$VM_NAME'."

echo ""
echo "Migration to VG Completed successfully."
echo "You may now power on the VM."

