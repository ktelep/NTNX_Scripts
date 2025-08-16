
# First we make a backup copy 
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

# Put everything back into place and reset our permissions
mv /tmp/qemu-kvm-frodo.tmp /usr/libexec/qemu-kvm-frodo
chmod 755 /usr/libexec/qemu-kvm-frodo

diff /usr/libexec/qemu-kvm-frodo /usr/libexec/qemu-kvm-frodo.bak
