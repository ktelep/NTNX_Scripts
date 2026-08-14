[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$PrismCentralIP,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [Parameter(Mandatory = $true)]
    [string]$TargetVmName,

    [Parameter(Mandatory = $true)]
    [string[]]$SourceVgNames,

    [Parameter(Mandatory = $true)]
    [string[]]$TargetVgNames
)

# Pre-Flight Validation
if ($SourceVgNames.Count -ne $TargetVgNames.Count) {
    throw "The number of Source VGs ($($SourceVgNames.Count)) must match the number of Target VGs ($($TargetVgNames.Count))."
}

# Initialize Session / SSL Bypass
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
$ErrorActionPreference = "Stop"

# Setup Base Headers
$authBytes  = [System.Text.Encoding]::UTF8.GetBytes("${Username}:${Password}")
$base64Auth = [System.Convert]::ToBase64String($authBytes)

$globalHeaders = @{
    "Authorization" = "Basic $base64Auth"
    "Accept"        = "application/json"
    "Content-Type"  = "application/json"
}

$baseUrl = "https://${PrismCentralIP}:9440/api"

# Helper Function: API Invocation wrapper
function Invoke-NutanixV4Api {
    param (
        [string]$Method,
        [string]$Uri,
        [object]$Body = $null
    )
    
    $headers = $globalHeaders.Clone()
    $headers["NTNX-Request-Id"] = [guid]::NewGuid().ToString()

    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $headers
        ErrorAction = 'Stop'
	SkipCertificateCheck = $true 
    }

    if ($Body) {
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10)
    }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        Write-Error "API Call Failed [$Method $Uri]: $_"
        throw $_
    }
}

# Helper Function: Poll Nutanix Task until completion
function Wait-NutanixTask {
    param (
        [string]$TaskId,
        [int]$TimeoutSeconds = 600,
        [int]$PollIntervalSeconds = 5
    )

    Write-Host "Monitoring Task [$TaskId]..." -ForegroundColor Cyan
    $taskUri = "$baseUrl/prism/v4.0/config/tasks/$TaskId"
    $elapsed = 0

    while ($elapsed -lt $TimeoutSeconds) {
        $taskResponse = Invoke-NutanixV4Api -Method 'GET' -Uri $taskUri
        $taskState = $taskResponse.data.status

        Write-Host "Task Status: $taskState ($elapsed seconds elapsed)" -ForegroundColor Gray

        if ($taskState -eq 'SUCCEEDED') {
            Write-Host "Task completed successfully." -ForegroundColor Green
            return $taskResponse.data
        }
        elseif ($taskState -in @('FAILED', 'CANCELED', 'ABORTED')) {
            $errorMsg = $taskResponse.data.errorDetail
            throw "Task [$TaskId] failed with status '$taskState'. Details: $errorMsg"
        }

        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
    }

    throw "Timed out waiting for Task [$TaskId] after $TimeoutSeconds seconds."
}

# Step 0: Validate and Fetch Entities
Write-Host "--- Starting Entity Validation ---" -ForegroundColor Cyan

# 0a. Fetch Target VM
Write-Host "Fetching Target VM '$TargetVmName'..."
$vmListUrl = "$baseUrl/vmm/v4.0/ahv/config/vms?`$filter=name eq '$TargetVmName'"
$vmResponse = Invoke-NutanixV4Api -Method 'GET' -Uri $vmListUrl

if (-not $vmResponse.data -or $vmResponse.data.Count -eq 0) {
    throw "Target VM '$TargetVmName' not found on Prism Central."
}
$targetVmExtId = $vmResponse.data[0].extId
Write-Host "Found Target VM ID: $targetVmExtId" -ForegroundColor Green

# 0b. Fetch Source VGs and map them
$vgMappings = @()
for ($i = 0; $i -lt $SourceVgNames.Count; $i++) {
    $srcName = $SourceVgNames[$i]
    $tgtName = $TargetVgNames[$i]
    
    Write-Host "Fetching Source VG '$srcName'..."
    $sourceVgUrl = "$baseUrl/volumes/v4.0/config/volume-groups?`$filter=name eq '$srcName'"
    $sourceVgResponse = Invoke-NutanixV4Api -Method 'GET' -Uri $sourceVgUrl

    if (-not $sourceVgResponse.data -or $sourceVgResponse.data.Count -eq 0) {
        throw "Source Volume Group '$srcName' not found."
    }
    
    $vgMappings += [PSCustomObject]@{
        SourceName = $srcName
        TargetName = $tgtName
        SourceExtId = $sourceVgResponse.data[0].extId
    }
    Write-Host "Found Source VG ID: $($sourceVgResponse.data[0].extId) (Maps to Target: $tgtName)" -ForegroundColor Green
}

# --- Step 1: Handle Existing Target VG Detach & Delete ---
Write-Host "`n--- Step 1: Checking Existing Target VGs ---" -ForegroundColor Cyan

foreach ($mapping in $vgMappings) {
    $tgtName = $mapping.TargetName
    Write-Host "Checking if Target VG '$tgtName' exists..."
    $targetVgUrl = "$baseUrl/volumes/v4.0/config/volume-groups?`$filter=name eq '$tgtName'"
    $targetVgResponse = Invoke-NutanixV4Api -Method 'GET' -Uri $targetVgUrl

    if ($targetVgResponse.data -and $targetVgResponse.data.Count -gt 0) {
        $targetVgExtId = $targetVgResponse.data[0].extId
        Write-Host "Existing Target VG '$tgtName' found. ID: $targetVgExtId" -ForegroundColor Yellow
        
        $attachmentsUrl = "$baseUrl/volumes/v4.0/config/volume-groups/$targetVgExtId/vm-attachments"
        $attachmentsResponse = Invoke-NutanixV4Api -Method 'GET' -Uri $attachmentsUrl

        $isAttachedToTargetVm = $false
        if ($attachmentsResponse.data) {
            $isAttachedToTargetVm = $attachmentsResponse.data | Where-Object { $_.extId -eq $targetVmExtId }
        }

        if ($isAttachedToTargetVm) {
            Write-Host "Target VG '$tgtName' is attached to Target VM. Detaching..." -ForegroundColor Yellow
            $detachUrl = "$baseUrl/volumes/v4.0/config/volume-groups/$targetVgExtId/`$actions/detach-vm"
            $detachBody = @{
                "extId"       = $targetVmExtId
                "$objectType" = "volumes.v4.config.VmAttachment"
            }
            $detachTask = Invoke-NutanixV4Api -Method 'POST' -Uri $detachUrl -Body $detachBody
            Wait-NutanixTask -TaskId $detachTask.data.extId
        }

        Write-Host "Deleting existing Target VG '$tgtName'..." -ForegroundColor Yellow
        $deleteVgUrl = "$baseUrl/volumes/v4.0/config/volume-groups/$targetVgExtId"
        $deleteTask = Invoke-NutanixV4Api -Method 'DELETE' -Uri $deleteVgUrl
        Wait-NutanixTask -TaskId $deleteTask.data.extId
    }
}

# --- Step 2: Create a Single Recovery Point Containing All Source VGs ---
Write-Host "`n--- Step 2: Creating Consolidated Recovery Point (with 2 hour expiry) ---" -ForegroundColor Cyan

$rpName = "RP_MultiVG_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

# Calculate Expiration Time in ISO-8601 Format (2 hours from now in UTC)
$expirationTime = (Get-Date).ToUniversalTime().AddHours(2).ToString("yyyy-MM-ddTHH:mm:ssZ")

$vgRecoveryPointsConfig = @()

foreach ($mapping in $vgMappings) {
    $vgRecoveryPointsConfig += @{
        "volumeGroupExtId" = $mapping.SourceExtId
        "$objectType"      = "dataprotection.v4.config.VolumeGroupRecoveryPoint"
    }
}

$createRpBody = @{
    "name"                      = $rpName
    "expirationTime"            = $expirationTime
    "volumeGroupRecoveryPoints" = $vgRecoveryPointsConfig
    "$objectType"               = "dataprotection.v4.config.RecoveryPoint"
}

Write-Host "Triggering Recovery Point creation for $($vgRecoveryPointsConfig.Count) VGs (Expires at $expirationTime)..."
$createRpUrl = "$baseUrl/dataprotection/v4.0/config/recovery-points"
$createRpTask = Invoke-NutanixV4Api -Method 'POST' -Uri $createRpUrl -Body $createRpBody
$completedRpTask = Wait-NutanixTask -TaskId $createRpTask.data.extId

# Extract Recovery Point ExtId
$rpExtId = ($completedRpTask.completionDetails | Where-Object { $_.name -eq 'recoveryPointExtId' }).value
if (-not $rpExtId) {
    # Fallback lookup
    $rpListUrl = "$baseUrl/dataprotection/v4.0/config/recovery-points?`$filter=name eq '$rpName'"
    $rpListResp = Invoke-NutanixV4Api -Method 'GET' -Uri $rpListUrl
    $rpExtId = $rpListResp.data[0].extId
}

Write-Host "Created Recovery Point ID: $rpExtId" -ForegroundColor Green

# Fetch specific Volume Group Recovery Point IDs inside the new top-level RP
$rpDetailUrl = "$baseUrl/dataprotection/v4.0/config/recovery-points/$rpExtId"
$rpDetail = Invoke-NutanixV4Api -Method 'GET' -Uri $rpDetailUrl

# --- Step 3: Restore Recovery Point as Target VGs ---
Write-Host "`n--- Step 3: Restoring VG Recovery Points ---" -ForegroundColor Cyan

$restoreOverrides = @()
foreach ($vgRp in $rpDetail.data.volumeGroupRecoveryPoints) {
    # Match the inner VG Recovery Point to our original source mapping to grab the intended Target Name
    $matchingMapping = $vgMappings | Where-Object { $_.SourceExtId -eq $vgRp.volumeGroupExtId }
    
    if ($matchingMapping) {
        $restoreOverrides += @{
            "volumeGroupRecoveryPointExtId" = $vgRp.extId
            "volumeGroupOverrideSpec"       = @{
                "name"        = $matchingMapping.TargetName
                "$objectType" = "dataprotection.v4.config.VolumeGroupOverrideSpec"
            }
            "$objectType"                  = "dataprotection.v4.config.VolumeGroupRecoveryPointRestoreOverride"
        }
    }
}

$restoreUrl = "$baseUrl/dataprotection/v4.0/config/recovery-points/$rpExtId/`$actions/restore"
$restoreBody = @{
    "volumeGroupRecoveryPointRestoreOverrides" = $restoreOverrides
    "$objectType"                              = "dataprotection.v4.config.RecoveryPointRestorationSpec"
}

Write-Host "Triggering restore task for all Volume Groups..."
$restoreTask = Invoke-NutanixV4Api -Method 'POST' -Uri $restoreUrl -Body $restoreBody
Wait-NutanixTask -TaskId $restoreTask.data.extId

# --- Step 4: Attach Target VGs to Target VM ---
Write-Host "`n--- Step 4: Attaching Restored VGs to Target VM ---" -ForegroundColor Cyan

Start-Sleep -Seconds 5 # Brief pause for entity propagation on Prism Central

foreach ($mapping in $vgMappings) {
    $tgtName = $mapping.TargetName
    Write-Host "Locating newly restored Target VG '$tgtName'..."
    $targetVgUrl = "$baseUrl/volumes/v4.0/config/volume-groups?`$filter=name eq '$tgtName'"
    $newTargetVgResponse = Invoke-NutanixV4Api -Method 'GET' -Uri $targetVgUrl

    if (-not $newTargetVgResponse.data -or $newTargetVgResponse.data.Count -eq 0) {
        throw "Unable to find restored Volume Group '$tgtName'."
    }
    
    $newTargetVgExtId = $newTargetVgResponse.data[0].extId
    Write-Host "Found New Target VG ID: $newTargetVgExtId. Attaching..." -ForegroundColor Green

    $attachUrl = "$baseUrl/volumes/v4.0/config/volume-groups/$newTargetVgExtId/`$actions/attach-vm"
    $attachBody = @{
        "extId"       = $targetVmExtId
        "$objectType" = "volumes.v4.config.VmAttachment"
    }

    $attachTask = Invoke-NutanixV4Api -Method 'POST' -Uri $attachUrl -Body $attachBody
    Wait-NutanixTask -TaskId $attachTask.data.extId
}

Write-Host "`n--- Multi-VG Clone and Attach Workflow Completed Successfully! ---" -ForegroundColor Green
