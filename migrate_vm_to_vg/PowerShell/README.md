# Description

These PowerShell scripts use the v4 APIs to migrate disks from an existing VM to a Volume Group attached to that VM. If the VG already exists, then the script will add the disks to the Volume Group and then attach the guest to that VG.  If the VG does not exist, the script will create it and set VGLB enabled or disabled.

Two versions are provided:

| Script | Description |
|--------|-------------|
|Migrate-VmDisksToVg.ps1 | Migrates all disks except SCSI.0 to the new Volume Group|
|Migrate-VmDisksToVg-Picklist.ps1 | Provides a picklist that lets you select which devices to migrate.   This is useful if you want to migrate to multiple VGs to separate Logs/TempDB/Data/etc.  Just run the script multiple times with different VG names. |

## Usage

1. Power off the VM you wish to migrate into a Volume Group
2. Execute the script of your choice from above.
3. Provide the Prism Central IP, VM, and VG names (case sensitive) you can also provide the user credentials on the command line, or allow the script to prompt you.
4. Once the Script is completed, Power the VM back on

## What does it do?

1. Validates the VM exists and confirms it is powered off
2. Confirms if the Volume Group already exists
3. Collects all the SCSI attached disks to the VM and confirms that you want to proceed. 
4. If creating a new VG, it creates the VG and sets whether or not VGLB should be configured
5. Takes a Recovery Point of the VM in case you need to revert
6. Clones the disks into the Volume Group
7. Removes the vdisks from the VM
8. Attaches the Volume Group to the VM

## Reverting (if something doesn't work after the fact)

1. Detach the Volume Group from the VM from within Prism Central or Prism Element
2. From Prism Central, Restore the VM from the RecoveryPoint created by the script, it will be labeled "Pre-VG Migration Snapshot (datestamp)"

## Post Script Cleanup

After you have completed your migration, you can manually delete the pre-migration Recovery Point, or allow it to expire (it is set to expire in 24 hours)

