MINIMUM_CORES=4
MINIMUM_MEM_IN_GB=30
MINIMUM_NICS=1
MINIMUM_DISKS=3

errors=0
warnings=0

check_min_cores() {
  cores=`lscpu | grep 'Core(s) per socket:' | awk '{print $NF}'`
  sockets=`lscpu | grep 'Socket(s):' | awk '{print $NF}'`

  echo "  Installed Sockets: $sockets"
  echo "  Installed Cores per socket: $cores"

  total_cores=$(($sockets * cores))
 
  if [[ $total_cores -lt $MINIMUM_CORES ]]; then
    return 1
  fi
 
  return 0
}

check_min_mem() {
  total_mem=`lsmem | awk -F: '/Total online memory:/ {gsub(/[[:space:]]+/, "", $2); print $2}'` 
  echo "  Total Memory: $total_mem"
  
  total_memory_in_bytes=`echo $total_mem | numfmt --from=iec`
  min_mem_in_bytes=$(($MINIMUM_MEM_IN_GB-1 *1024 *1024 *1024))

  if [[ $total_memory_in_bytes -lt $min_mem_in_bytes ]]; then
    return 1
  fi

  return 0
    
}

check_min_nics() {
  nic_count=`lspci -mm | grep Ether | wc -l`
  echo "  NICs found: $nic_count"
  if [[ $nic_count -lt MINIMUM_NICS ]]; then
    return 1
  fi

  return 0    
}

check_min_disks() {
  disk_count=`lsblk -nd | grep -v sr | wc -l`
  real_count=$((disk_count-1))   # Account for the installer disk

  echo "  Disks found: $real_count"

  if [[ real_count < MINIMUM_DISKS ]]; then
    return 1
  fi

  return 0
}

check_nvme_conflicts() {

echo "  NVMe Devices Found" 

for group in /sys/kernel/iommu_groups/*; do
  group_num=$(basename "$group")
  
  nvme_devices=()
  non_nvme_devices=()
 
  for device in "$group"/devices/*; do
    pci_addr=$(basename "$device")
    device_desc=$(lspci -s "$pci_addr")
    
    if echo "$device_desc" | grep -qi "Non-Volatile memory controller"; then
      nvme_devices+=("$device_desc")
      echo "    - $device_desc"
    elif echo "$device_desc" | grep -qi "Root Port"; then   # Ignore Root Ports
      continue 
    else
      non_nvme_devices+=("$device_desc")
    fi
  done
  
  # Check for NVMe devices sharing with non-NVMe devices
  if [[ ${#nvme_devices[@]} -gt 0 && ${#non_nvme_devices[@]} -gt 0 ]]; then
    ((warnings++)) 
    echo ""
    echo "  IOMMU Group $group_num: NVMe device(s) share group with non-NVMe device(s)"
    echo "    NVMe devices:"
    for nvme in "${nvme_devices[@]}"; do
      echo "    - $nvme"
      pci_id=`echo $nvme | awk '{print $1}'`
      for dev in /sys/block/nvme*; do
        dev_pci=$(cat $dev/device/address | awk -F: '{print $2":"$3}')
        if [[ "$dev_pci" == "$pci_id" ]]; then
            echo "        - /dev/$(basename $dev) maps to PCI ID $pci_id"
        fi
      done
    done
    echo "    Non-NVMe devices:"
    for other in "${non_nvme_devices[@]}"; do
      echo "    - $other"
    done
  fi
  
  # Check for multiple NVMe devices in the same group
  if [[ ${#nvme_devices[@]} -gt 1 ]]; then
    ((warnings++))
    echo ""
    echo "  IOMMU Group $group_num: Multiple NVMe devices detected in the same group"
    echo "    NVMe devices:"
    for nvme in "${nvme_devices[@]}"; do
      echo "    - $nvme"
      pci_id=`echo $nvme | awk '{print $1}'`
      for dev in /sys/block/nvme*; do
        dev_pci=$(cat $dev/device/address | awk -F: '{print $2":"$3}')
        if [[ "$dev_pci" == "$pci_id" ]]; then
            echo "        - /dev/$(basename $dev) maps to PCI ID $pci_id"
        fi
      done
    done
  fi
done

return $warnings

}
echo "Checking that there are the minimum of $MINIMUM_CORES cores..."
if check_min_cores; then
   echo "--- OK ---"
else
   echo "!!! Minimum cores not met !!!"
   ((errors++))
fi

echo ""
echo "Checking that there is at least $MINIMUM_MEM_IN_GB GB of memory..."
if check_min_mem; then
   echo "--- OK ---"
else
   echo "!!! Minimum memory not met !!!"
   ((errors++))
fi

echo ""
echo "Checking that there are at least $MINIMUM_NICS NICs..."
if check_min_nics; then
   echo "--- OK ---"
else
   echo "!!! Minimum NICs not detected !!!"
   ((errors++))
fi

echo ""
echo "Checking that there are at least $MINIMUM_DISKS Disks..."
if check_min_disks; then
   echo "--- OK ---"
else
   echo "!!! Minimum number of disks not detected !!!"
   ((errors++))
fi

echo ""
echo "Checking IOMMU Groups for NVMe isolation issues..."
if check_nvme_conflicts; then
   echo "--- OK ---"
else
   echo "!!! Warning, there may be NVMe IOMMU conflicts !!!"
fi

echo ""
echo "Total errors found: $errors"
echo "Total warnings found: $warnings"
echo ""
exit $errors
