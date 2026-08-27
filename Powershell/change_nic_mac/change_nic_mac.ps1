param (
    [Parameter(Mandatory=$true)][string]$PrismCentralIp,
    [Parameter(Mandatory=$true)][string]$Username,
    [Parameter(Mandatory=$true)][string]$Password,
    [Parameter(Mandatory=$true)][string]$VMName,
    [Parameter(Mandatory=$true)][string]$OriginalMac,
    [Parameter(Mandatory=$true)][string]$NewMac
)

# Cross-platform SSL handling
$commonParams = @{}
if ($PSVersionTable.PSVersion.Major -ge 6) {
    # PowerShell Core (Linux/Mac/Modern Windows)
    $commonParams.Add("SkipCertificateCheck", $true)
    $commonParams.Add("SkipHeaderValidation", $true)
} else {
    # Windows PowerShell 5.1
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

$baseUrl = "https://${PrismCentralIp}:9440/api/vmm/v4.0/ahv/config/vms"
$authBytes = [System.Text.Encoding]::UTF8.GetBytes("${Username}:${Password}")
$authBase64 = [System.Convert]::ToBase64String($authBytes)

$headers = @{
    "Authorization" = "Basic $authBase64"
    "Accept"        = "application/json"
    "Content-Type"  = "application/json"
}

# Locate our VM that we're updating
Write-Host "Searching for VM with name: $VMName..."
$listVmUrl = "$baseUrl`?`$filter=name eq '$VMName'"
$listResponse = Invoke-RestMethod -Uri $listVmUrl -Method GET -Headers $headers @commonParams

if ($listResponse.data.Count -eq 0) {
    Write-Error "No VM found with name $VMName."
    exit
} elseif ($listResponse.data.Count -gt 1) {
    Write-Error "Multiple VMs found with name $VMName. Please ensure the VM name is unique."
    exit
}

$vm = $listResponse.data[0]
$VmExtId = $vm.extId
Write-Host "Found VM $VMName with ExtId: $VmExtId"

# Find the NIC with the Original Mac Address
$targetNic = $null
foreach ($nic in $vm.nics) {
    if ($nic.nicBackingInfo.macAddress -eq $OriginalMac) {
        $targetNic = $nic
        break
    }
}

if (-not $targetNic) {
    Write-Error "Could not find a NIC with MAC address $OriginalMac on VM $VMName."
    exit
}

$NicExtId = $targetNic.extId
$SubnetExtId = $targetNic.nicNetworkInfo.subnet.extId
Write-Host "Found target NIC to replace:`n  NIC ExtId: $NicExtId`n  Subnet ExtId: $SubnetExtId"

# Lets play fun games with eTags so we can make updates
$getVmUrl = "$baseUrl/$VmExtId"
Write-Host "Fetching latest VM ETag..."
$getVmResponse = Invoke-WebRequest -Uri $getVmUrl -Method GET -Headers $headers @commonParams

# Fix for PowerShell on Mac returning an array instead of string
$etag = $getVmResponse.Headers["ETag"]
if (-not $etag) { $etag = $getVmResponse.Headers["etag"] }
if ($etag -is [array]) { $etag = $etag[0] }

if (-not $etag) {
    Write-Error "Failed to retrieve ETag from VM."
    exit
}

# Delete the existing NIC, but we know everything about it already
$deleteNicUrl = "$baseUrl/$VmExtId/nics/$NicExtId"
$headers.Add("If-Match", $etag)
$headers.Add("NTNX-Request-Id", [guid]::NewGuid().ToString()) # Required for mutations


Write-Host "Deleting NIC with MAC $OriginalMac..."
$deleteResponse = Invoke-RestMethod -Uri $deleteNicUrl -Method DELETE -Headers $headers @commonParams
Write-Host "Delete task initiated. Task ExtId: $($deleteResponse.data.extId)"

# Give Prism Central a few seconds to process the deletion task before requesting a new ETag
# Probably could wait for the task to complete here, but I'm a little lazy and it runs fast
Start-Sleep -Seconds 5

# Get the updated VM ETag (ETag changes after NIC deletion)
$headers.Remove("If-Match")
$headers.Remove("NTNX-Request-Id")
Write-Host "Fetching updated VM ETag..."
$getVmResponse = Invoke-WebRequest -Uri $getVmUrl -Method GET -Headers $headers @commonParams

$etag = $getVmResponse.Headers["ETag"]
if (-not $etag) { $etag = $getVmResponse.Headers["etag"] }
if ($etag -is [array]) { $etag = $etag[0] }
$headers.Add("If-Match", $etag)
$headers.Add("NTNX-Request-Id", [guid]::NewGuid().ToString()) # New unique ID for the POST

# Create the new NIC using the saved SubnetExtId using our new MAC
$createNicUrl = "$baseUrl/$VmExtId/nics"
$newNicBody = @{
    "`$objectType" = "vmm.v4.ahv.config.Nic"
    "nicBackingInfo" = @{
        "`$objectType" = "vmm.v4.ahv.config.VirtualEthernetNic"
        "isConnected" = $true
        "macAddress" = $NewMac
    }
    "nicNetworkInfo" = @{
        "`$objectType" = "vmm.v4.ahv.config.VirtualEthernetNicNetworkInfo"
        "subnet" = @{
            "extId" = $SubnetExtId
        }
    }
} | ConvertTo-Json -Depth 5

Write-Host "Creating new NIC with MAC $NewMac on Subnet $SubnetExtId..."
$createResponse = Invoke-RestMethod -Uri $createNicUrl -Method POST -Headers $headers -Body $newNicBody @commonParams

Write-Host "NIC creation task initiated successfully. Task ExtId: $($createResponse.data.extId)"
