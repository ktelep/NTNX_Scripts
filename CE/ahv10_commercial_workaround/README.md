# Workaround for commercial CPU issue when booting VMs in AHV10+

Scripted or Unscripted version must be performed on ALL hosts in the AHV cluster

## Scripted Version ##
1. scp the script in this repo (fix_ahv10_comm.sh) to each AHV host into the /tmp directory

2. Log into AHV as root.   

3. Execute the script

```bash
   bash /tmp/fix_ahv10_comm.sh
```

## Manual Version ##

1. Log into AHV as root.   

2. Make a backup of the /usr/libexec/qemu-kvm-frodo file

```bash
    cp /usr/libexec/qemu-kvm-frodo /usr/libexec/qemu-kvm-frodo.bak
```

3. Edit the file /usr/libexec/qemu-kvm-frodo 

First, locate the following line (should be line 635)

```python
    if arg not in ("-device", "-blockdev", "-cpu", "-uuid", "-boot"):
```

And add the '-m' parameter to the end so it looks like this:

```python
    if arg not in ("-device", "-blockdev", "-cpu", "-uuid", "-boot", "-m"):
```

Next, find the line that reads the following (it will be around line 662):

```python
  elif arg == "-blockdev":
    _, opts = parse_json_opt(argval)
```

Just above it place the following:  (whitespace matters! there are only *two* spaces before the elif and 4 spaces before the new_argval)

```python
  elif arg == "-m":
    new_argval = argval.replace("maxmem=4831838208k","maxmem=128G")
    qemu_argv.append(arg)
    qemu_argv.append(new_argval)
```

The script should look something like this (see how the elifs line up?):

```python
    658
    659     qemu_argv.append(arg)
    660     qemu_argv.append(argval)
    661
    662   elif arg == "-m":
    663     new_argval = argval.replace("maxmem=4831838208k","maxmem=128G")
    664     qemu_argv.append(arg)
    665     qemu_argv.append(new_argval)
    666
    667   elif arg == "-blockdev":
    668     _, opts = parse_json_opt(argval)
    669
```

4.  Copy this version of /usr/libexec/qemu-kvm-frodo to all of the AHV nodes in your CE cluster and place it in /usr/libexec replacing the existing one.

5.  On each AHV node run this as root to fix any SELinux contexts that may have gotten changed

```bash
   restorecon /usr/libexec/qemu-kvm-frodo
```

You should now be able to start VMs.   This limits the maximum memory available for each VM to 128GB

Many thanks to SteveCooperArch in the .Next forums for identifying using this script as a quick and dirty workaround.   Note this IS resolved in an upcoming release of AHV.   We have no plans to stop supporting Commercial CPUs!
