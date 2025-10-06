#!/bin/bash

# This script fixes the AHV 10.0 and 10.1 issues with commercial processors
# by reducing the maxmem from 4TB to 128G during initial VM launch
# This is a workaround until Nutanix provides an official fix in a future release of AHV

# This script has been tested with AHV 10.0.3 and 10.1.1

# Store our context SELinux context for reference
SECON=`ls -lZ /usr/libexec/qemu-kvm-frodo`

# Some prechecks
if grep -Fq "maxmem=128G" /usr/libexec/qemu-kvm-frodo; then
    echo "It appears that this fix has already been applied to this system,"
    echo "Skipping to fixing permissions and restoring SELinux context"
else
    #First we make a backup copy 
    cp /usr/libexec/qemu-kvm-frodo /usr/libexec/qemu-kvm-frodo.bak

    # Next we need to update the line so we capture the -m for memory
    sed -i 's|\("-uuid", "-boot"\)|\1, "-m"|g' /usr/libexec/qemu-kvm-frodo

    # Add in our fix to reduce the maxmemory
    awk '
    NR == 661 {
        printf("\n  elif arg == \"-m\":\n")
        printf("    new_argval = argval.replace(\"maxmem=4831838208k\",\"maxmem=128G\")\n")
        printf("    qemu_argv.append(arg)\n")
        printf("    qemu_argv.append(new_argval)\n\n")
        modif=1
    }
    { print }
    ' /usr/libexec/qemu-kvm-frodo > /tmp/qemu-kvm-frodo.tmp

    # Put everything back in place
    mv /tmp/qemu-kvm-frodo.tmp /usr/libexec/qemu-kvm-frodo
fi

# Fix the permissions and SELinux context
chmod 755 /usr/libexec/qemu-kvm-frodo
restorecon /usr/libexec/qemu-kvm-frodo


# Show off our changes
echo ""
echo "Here is a diff of the changes between the original and modified file"
echo "----------------------------------------"
if [-e "/usr/libexec/qemu-kvm-frodo.bak" ]; then
    diff /usr/libexec/qemu-kvm-frodo /usr/libexec/qemu-kvm-frodo.bak
else
    echo " No backup file found, previous fix may have been manually applied"
    echo " in place."
fi

echo ""
echo "Here is the SE Linux perms before and after"
echo "----------------------------------------"
echo $SECON
ls -lZ /usr/libexec/qemu-kvm-frodo

echo "Done!"

