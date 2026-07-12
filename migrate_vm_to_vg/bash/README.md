This bash script will take an existing VM and migrate all disks except scsi.0 to a Volume Group.  If the VG already exists, then the script will add the disks to the Volume Group and then attach the guest to that VG.  If the VG does not exist, the script will create it and set VGLB enabled or disabled.

Usage
--------
1. Power off the VM you wish to migrate into a Volume Group
2. Execute the script from the CVM:  bash migrate_vm_to_vg.sh
3. Provide the name of the VM and the VG name when prompted (case sensitive)
4. Once the Script is completed, Power the VM back on

What does it do?
------------------
1. Validates the VM exists and confirms it is powered off
2. Confirms if the Volume Group already exists
3. Collects all the SCSI attached disks to the VM and confirms that you want to proceed.  *This is important*, as this assumes that SCSI.0 is NOT to be moved.
4. If creating a new VG, it creates the VG and sets whether or not VGLB should be configured
5. Takes a Prism Element level snapshot of the VM in case you need to revert
6. Clones the disks into the Volume Group
7. Removes the vdisks from the VM (with user prompts)
8. Attaches the Volume Group to the VM

Sample run
------------------

```
nutanix@NTNX-44bcd2f8-A-CVM:192.168.2.202:~$ bash migrate_vm_to_vg.sh 
Enter VM name: SQL_User05
Enter Volume Group name: SQLVGTest

Confirming VM is powered off...

Collecting disks for VM: SQL_User05...

The following disks will be moved to Volume Group: SQLVGTest
-----------------------------------------------------------
- scsi.1 (Size: 100 GB)
- scsi.2 (Size: 100 GB)
- scsi.3 (Size: 100 GB)

The following disks will NOT be moved
-----------------------------------------------------------
- scsi.0 (Size: 100 GB)

Are you sure you want to proceed? (yes/no): yes

Creating new Volume Group: SQLVGTest
SQLVGTest: pending
SQLVGTest: complete

Setting load balancing option to true
SQLVGTest: pending
SQLVGTest: complete
Taking PE level snapshot of VM...
SnapshotCreate: pending
SnapshotCreate: complete

Cloning disks to Volume Group...
Adding scsi.1 to Volume Group...
DiskCreate: pending
DiskCreate: complete
Adding scsi.2 to Volume Group...
DiskCreate: pending
DiskCreate: complete
Adding scsi.3 to Volume Group...
DiskCreate: pending
DiskCreate: complete

Detaching disks from VM...

** Respond 'yes' to any prompts, or you will have a duplicate disk attached to the VM.
** If we have made it to this point, we've successfully cloned the disks into the new VG
** and have a snapshot to revert to if needed.

Removing scsi.1 from VM...
Delete existing disk? (yes/no) yes
DiskDelete: pending
DiskDelete: complete

Removing scsi.2 from VM...
Delete existing disk? (yes/no) yes
DiskDelete: pending
DiskDelete: complete

Removing scsi.3 from VM...
Delete existing disk? (yes/no) yes
DiskDelete: pending
DiskDelete: complete

Attaching Volume Group to VM...
AttachToVm: pending
AttachToVm: complete
Volume Group 'SQLVGTest' has been successfully attached to VM 'SQL_User05'.

Migration to VG Completed successfully.
You may now power on the VM.
nutanix@NTNX-44bcd2f8-A-CVM:192.168.2.202:~$ 
```

Reverting (if something doesn't work after the fact)
-----------------------
1.  Detach the Volume Group from the VM from within Prism Central or Prism Element
2.  From Prism Element, Restore the VM from the snapshot created by the script, it will be labeled "Pre-VG Migration Snapshot <datestamp>"

Post Script Cleanup
---------------------
After you have completed your migration, do NOT forget to remove the snapshot that was taken in Prism Element of the VM.  This will not appear in Prism Central and you will find it only in PE by clicking on the VM name and then selecting the "VM Snapshots" tab.


