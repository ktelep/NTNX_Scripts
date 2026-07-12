#requires -Modules Microsoft.PowerShell.ConsoleGuiTools
<#
.SYNOPSIS
    Migrates virtual machine disks from being directly presented to a host to being attached via 
    an AHV attached Volume Group

.DESCRIPTION
    This script automates the process of identifying disks attached to a specific AHV virtual machine, 
    cloning those disks into a target Volume Group, and safely removing the original disks from the VM. 
    This version has a nice pick-list so you can select the individual disks you would like to move 
    to a VG vs. assuming you want to move them all.

    If the Volume Group already exists, the disks are ADDED to the existing Volume Group.  If it does
    not already exist, then it is created for the disks.

.PARAMETER PC_IP
    The IP address or FQDN of the Prism Central instance.

.PARAMETER VmName
    The name of the source Virtual Machine.

.PARAMETER VgName
    The name of the destination Volume Group.

.PARAMETER Username
    Prism Central Username with access/credentials to create VGs, clone disks, and access VM info

.PARAMETER Password
    Password for Prism Central User

.EXAMPLE
    .\Migrate-VmDisksToVg-Picklist.ps1 -PC_IP 192.168.2.202 -VmName "SQL-Prod-01" -VgName "VG-SQL-Data" -Username admin -Password "AHV4eva!!"

.NOTES
    Author:      Kurt Telep - Cloud Transformation Architect (CTA)
    Company:     Nutanix
    Version:     1.0
    Date:        2026-07-11
    Prerequisites: Requires PowerShell 6+ (uses -SkipHeaderValidation for ETag handling).
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$PC_IP,

    [Parameter(Mandatory=$true)]
    [string]$Username,

    [Parameter(Mandatory=$true)]
    [string]$Password,

    [Parameter(Mandatory=$true)]
    [string]$VM_NAME,

    [Parameter(Mandatory=$true)]
    [string]$VG_NAME
)

# Bypass SSL Certificate Validation for older Windows PowerShell (v5.1)
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Construct Base64 Auth Header
$AuthString = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($Username):$($Password)"))
$Headers = @{
    "Authorization" = "Basic $AuthString"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
}

# Nutanix V4 API Base URLs (Notice the curly braces around PC_IP)
$BaseUrl = "https://${PC_IP}:9440"
$VmmApi = "$BaseUrl/api/vmm/v4.0/ahv/config"
$StorageApi = "$BaseUrl/api/volumes/v4.0/config"
$DpApi = "$BaseUrl/api/dataprotection/v4.0/config"
$v2Api = "$BaseUrl/PrismGateway/services/rest/v2.0"

# Helper function to invoke API
function Invoke-NtxRest {
    param(
        $Uri, 
        $Method = "GET", 
        $Body = $null,
        $ETag = $null 
    )
    
    # Clone the global headers
    $RequestHeaders = $Headers.Clone()
    $RequestHeaders['NTNX-Request-Id'] = [guid]::NewGuid().ToString()

    # <-- NEW: If an ETag is provided, inject it as the If-Match header
    if ($ETag) {
        $RequestHeaders['If-Match'] = $ETag
    }

    $params = @{
        Uri = $Uri
        Method = $Method
        Headers = $RequestHeaders
        ResponseHeadersVariable = 'ResHeaders' 
        SkipHeaderValidation = $true
    }
    
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10) }
   
    # Bypass SSL Certificate Validation
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $params.Add('SkipCertificateCheck', $true)
    }
    
    try {
        $Response = Invoke-RestMethod @params
        
        # Capture the ETag from headers and attach it to the response object
        if ($ResHeaders.ContainsKey('ETag')) {
            # Headers are returned as arrays, grab the first element
            $ReturnedETag = $ResHeaders['ETag'] | Select-Object -First 1
            
            # Silently append it to the response object as a custom property
            if ($null -ne $Response -and $Response -is [System.Management.Automation.PSCustomObject]) {
                $Response | Add-Member -MemberType NoteProperty -Name "NtnxETag" -Value $ReturnedETag -Force
            }
        }

        return $Response
    } catch {
        Write-Error "API Call Failed: $($_.Exception.Message)"
        if ($_.ErrorDetails) { Write-Error $_.ErrorDetails.Message }
        throw $_
    }
}

Write-Host "Connecting to Prism Central ($PC_IP) to gather VM info..." -ForegroundColor Cyan

# 1. Check VM exists and get details
$VmSearch = Invoke-NtxRest -Uri "$VmmApi/vms?`$filter=name eq '$VM_NAME'"
if ($VmSearch.data.Count -eq 0) {
    Write-Error "ERROR: VM '$VM_NAME' not found."
    exit
}
$VmExtId = $VmSearch.data[0].extId
$VmResponse = Invoke-NtxRest -Uri "$VmmApi/vms/$VmExtId"
$Vm = $VmResponse.data

# 2. Check VM Power State
Write-Host "Confirming VM is powered off..."
if ($Vm.powerState -ne "OFF") {
    Write-Error "ERROR: VM '$VM_NAME' is not powered off. Please power off the VM and try again."
    exit
}

# 3. Collect disks
Write-Host "Collecting disks for VM: $VM_NAME"

$AllDisks = $Vm.disks

$Options = foreach ($disk in $AllDisks) {
    $sizeGb = [math]::Round($disk.backingInfo.diskSizeBytes / 1GB, 2)
    [PSCustomObject]@{
        Bus = $disk.diskAddress.busType
        Address = $disk.diskAddress.index
        Size = $sizeGb
        extId = $disk.extId
    }
}

$DisksToMove = $Options | Out-ConsoleGridView -Title "Select disks to migrate" -OutputMode Multiple
$DisksNotToMove = $Options | Where-Object { $_.extId -notin $DisksToMove.extId}

if (-not $DisksToMove) {
    Write-Host "No disks selected. Nothing to move." -ForegroundColor Yellow
    exit
}

# 4. Check if Volume Group exists
$VgSearch = Invoke-NtxRest -Uri "$StorageApi/volume-groups?`$filter=name eq '$VG_NAME'"
$VgExists = $VgSearch.data.Count -gt 0

if ($VgExists) {
    Write-Host "WARNING: Volume Group '$VG_NAME' already exists." -ForegroundColor Yellow
    Write-Host "Disks will be added to the existing Volume Group." -ForegroundColor Yellow
}

# 5. Output Summary
Write-Host "`nThe following disks will be moved to Volume Group: $VG_NAME" -ForegroundColor Green
Write-Host "-----------------------------------------------------------"
foreach ($disk in $DisksToMove) {
    Write-Host "- $($disk.bus).$($disk.Address) (Size: $($disk.size) GB) [ExtId: $($disk.extId)]"
}

Write-Host "`nThe following disks will NOT be moved" -ForegroundColor Yellow
Write-Host "-----------------------------------------------------------"
foreach ($disk in $DisksNotToMove) {
    Write-Host "- $($disk.bus).$($disk.Address) (Size: $($disk.size) GB) [ExtId: $($disk.extId)]"
}

# 6. Confirm prompt
Write-Host ""
$Confirm = Read-Host "Are you sure you want to proceed? (yes/no)"
if ($Confirm -ne "yes") {
    Write-Host "Operation cancelled."
    exit
}

# 7. Create VG if needed
$VgExtId = $null
if (-not $VgExists) {
    Write-Host "`nCreating new Volume Group: $VG_NAME"
    $VgPayload = @{
        name = $VG_NAME
        clusterReference = $Vm.cluster.extId
    }
    
    $Task = Invoke-NtxRest -Uri "$StorageApi/volume-groups" -Method POST -Body $VgPayload
    Write-Host "Waiting for VG creation task to complete..."
    Start-Sleep -Seconds 5
    
    # Retrieve newly created VG
    $VgSearch = Invoke-NtxRest -Uri "$StorageApi/volume-groups?`$filter=name eq '$VG_NAME'"
    $VgExtId = $VgSearch.data[0].extId
} else {
    Write-Host "`nUsing existing Volume Group: $VG_NAME"
    $VgExtId = $VgSearch.data[0].extId
}

# 8. Snapshot the VM
Write-Host "Taking a snapshot of VM via Prism Central..."
$SnapName = "Pre-VG Migration Snapshot $(Get-Date -Format 'yyyyMMddHHmmss')"
$SnapPayload = @{
    name = $SnapName
    recoveryPointType = "CRASH_CONSISTENT"
    status = "COMPLETE"
    expirationTime = (Get-Date).AddHours(24).ToString("yyyy-MM-dd'T'HH:mm:sszzz")
    vmRecoveryPoints = @(
        @{ 
            name = $SnapName
            recoveryPointType = "CRASH_CONSISTENT"
            status = "COMPLETE"
            vmExtId = $VmExtId
            expirationTime = (Get-Date).AddHours(24).ToString("yyyy-MM-dd'T'HH:mm:sszzz")
        }
    )
}
$SnapTask = Invoke-NtxRest -Uri "$DpApi/recovery-points" -Method POST -Body $SnapPayload
Write-Host "Snapshot triggered. Waiting 10 seconds..."
Start-Sleep -Seconds 10


# We need to get the internal disk UUID, and this is broken in v4 API (ENG-697438)
# So we retrieve it with the v2 API, proxied through the v4 so we don't need to 
# connect directly to the underlying cluster, a nice little trick.   
# I'm just going to grab all the disks for the VM and build a hash table so we can
# look them up instead of individually running this query
Write-Host "`nCreating VM Disk Map"
$vm_v2data = Invoke-NtxRest -Uri "$v2Api/vms/$($VmExtId)?include_vm_disk_config=true&proxyClusterUuid=$($Vm.cluster.extId)"
$diskMap = @{}

foreach ($disk in $vm_v2data.vm_disk_info) {
    $deviceUuid = $disk.disk_address.device_uuid
    $vmDiskUuid = $disk.disk_address.vmdisk_uuid

    if ($deviceUuid -and $vmDiskUuid) {
        $diskMap[$deviceUuid] = $vmDiskUuid
    }
}

# 9. Clone disks to VG
Write-Host "`nCloning disks to Volume Group..."
foreach ($disk in $DisksToMove) {
    Write-Host "Adding $($disk.bus).$($disk.Address) to Volume Group..."

    $ClonePayload = @{ diskDataSourceReference = 
            @{
                extId = $diskMap[$disk.extId]  # Sweet disk map action
                entityType = "VM_DISK"
            }
        }
    # Update VG with the cloned disk
    $VgUpdate = Invoke-NtxRest -Uri "$StorageApi/volume-groups/$VgExtId/disks" -Method POST -Body $ClonePayload
    Start-Sleep -Seconds 5
}

# 10. Detach disks from VM
Write-Host "`nDetaching original Disks from VM..."
foreach ($disk in $DisksToMove) {
    Write-Host "Removing $($disk.bus).$($disk.Address) to Volume Group..."

    $DiskExtId = $disk.extId
    $toRemove = Invoke-NtxRest -Uri "$VmmApi/vms/$VmExtId/disks/$DiskExtId"

    $eTag = $toRemove.NtnxEtag
    $toRemove = Invoke-NtxRest -Uri "$VmmApi/vms/$VmExtId/disks/$DiskExtId" -Method "DELETE" -ETag $eTag
    Start-Sleep -Seconds 2
}    
Write-Host "Waiting for disk detachment to complete..."
Start-Sleep -Seconds 5

# 11. Attach VG to VM
Write-Host "`nAttaching Volume Group to VM..."
$AttachPayload = @{
    extId = $VmExtId
}

$AttachTask = Invoke-NtxRest -Uri "$StorageApi/volume-groups/$VgExtId/`$actions/attach-vm" -Method POST -Body $AttachPayload

Write-Host "`nMigration to VG Completed successfully." -ForegroundColor Green
Write-Host "You may now power on the VM." -ForegroundColor Green
