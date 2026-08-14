<#
.SYNOPSIS
Creates Nutanix Protection Policies for various RPOs using exclusively v4 APIs,
with automated UUID lookups for Clusters and Domain Managers (Prism Central) and dynamic Location Labels.
Automatically provisions mapped Categories using v4 APIs and assigns them to the protection policy.
#>

param (
    [Parameter(Mandatory=$true)][string]$SourcePCIP,
    [Parameter(Mandatory=$true)][string]$SourceUsername,
    [Parameter(Mandatory=$true)][string]$SourcePassword,

    [Parameter(Mandatory=$true)][string]$TargetPCIP,
    [Parameter(Mandatory=$true)][string]$TargetUsername,
    [Parameter(Mandatory=$true)][string]$TargetPassword,

    [Parameter(Mandatory=$true)][string]$SourceClusterName,
    [Parameter(Mandatory=$true)][string]$TargetClusterName,
    
    # Category key used to group the replication policies.
    # Nutanix restricts keys to alphanumeric characters, underscores, and hyphens.
    [Parameter(Mandatory=$false)][string]$CategoryKey = "Site_Replication"
)

# Bypass self-signed certificate errors
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

# Define the RPOs in a hash table (Name -> RecoveryPointObjectiveTimeSeconds)
$rpoSchedules = [ordered]@{
    "15 Minutes" = 900
    "1 Hour"     = 3600
    "6 Hours"    = 21600
    "1 Day"      = 86400
}

# --- Helper Function: Setup Auth Headers ---
function Get-AuthHeader {
    param ($Username, $Password)
    $authString = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${Username}:${Password}"))
    return @{
        "Authorization" = "Basic $authString"
        "Accept"        = "application/json"
        "Content-Type"  = "application/json"
    }
}

$SourceHeaders = Get-AuthHeader -Username $SourceUsername -Password $SourcePassword
$TargetHeaders = Get-AuthHeader -Username $TargetUsername -Password $TargetPassword

# --- Helper Function: Get Domain Manager (Prism Central) Info (v4 API) ---
function Get-DomainManagerInfo {
    param ($PCIP, $Headers)
    $url = "https://${PCIP}:9440/api/prism/v4.0/config/domain-managers"
    $response = Invoke-RestMethod -Uri $url -Method Get -Headers $Headers -SkipCertificateCheck

    if ($response.data -and $response.data.Count -gt 0) {
        return @{
            ExtId = $response.data[0].extId
            Name  = $response.data[0].name
        }
    }
    throw "Could not find Domain Manager (Prism Central) info for $PCIP"
}

# --- Helper Function: Get Cluster ExtId by Name (v4 API) ---
function Get-ClusterExtId {
    param ($PCIP, $Headers, $ClusterName)
    $url = "https://${PCIP}:9440/api/clustermgmt/v4.0/config/clusters?`$filter=name eq '$ClusterName'"
    $response = Invoke-RestMethod -Uri $url -Method Get -Headers $Headers -SkipCertificateCheck

    if ($response.data -and $response.data.Count -gt 0) { return $response.data[0].extId }
    throw "Could not find Cluster named '$ClusterName' on Prism Central $PCIP"
}

# --- Helper Function: Get or Create Category (v4 API) ---
function Get-OrCreateCategory {
    param ($PCIP, $Headers, $Key, $Value)

    # 1. Check if Category already exists via OData filter
    $filter = "key eq '$Key' and value eq '$Value'"
    $encodedFilter = [uri]::EscapeDataString($filter)
    $getUrl = "https://${PCIP}:9440/api/prism/v4.0/config/categories?`$filter=$encodedFilter"
    
    try {
        $getResp = Invoke-RestMethod -Uri $getUrl -Method Get -Headers $Headers -SkipCertificateCheck
        if ($getResp.data -and $getResp.data.Count -gt 0) {
            return $getResp.data[0].extId
        }
    } catch {
        Write-Warning "Failed to query category, attempting to create..."
    }

    # 2. Create the Category if it does not exist
    $postUrl = "https://${PCIP}:9440/api/prism/v4.0/config/categories"
    $body = @{
        key = $Key
        value = $Value
        description = "Automated Value mapped to Protection Policy"
    } | ConvertTo-Json
    
    try {
        $postResp = Invoke-RestMethod -Uri $postUrl -Method Post -Headers $Headers -Body $body -SkipCertificateCheck
        return $postResp.data.extId
    } catch {
        throw "Failed to create category $Key`:$Value. $_"
    }
}

Write-Host "Looking up External IDs and Prism Central Names..." -ForegroundColor Cyan

# Fetch Info for the Source Site (PC1)
$SourcePCInfo = Get-DomainManagerInfo -PCIP $SourcePCIP -Headers $SourceHeaders
$SourceDomainManagerExtId = $SourcePCInfo.ExtId
$SourceLocationLabel = "$($SourcePCInfo.Name)0"
$SourceClusterExtId = Get-ClusterExtId -PCIP $SourcePCIP -Headers $SourceHeaders -ClusterName $SourceClusterName

Write-Host "Source PC Name: $($SourcePCInfo.Name)"
Write-Host "Source PC ExtId: $SourceDomainManagerExtId"
Write-Host "Source Cluster ExtId ($SourceClusterName): $SourceClusterExtId`n"

# Fetch Info for the Target Site (PC2)
$TargetPCInfo = Get-DomainManagerInfo -PCIP $TargetPCIP -Headers $TargetHeaders
$TargetDomainManagerExtId = $TargetPCInfo.ExtId
$TargetLocationLabel = "$($TargetPCInfo.Name)1"
$TargetClusterExtId = Get-ClusterExtId -PCIP $TargetPCIP -Headers $TargetHeaders -ClusterName $TargetClusterName

Write-Host "Target PC Name: $($TargetPCInfo.Name)"
Write-Host "Target PC ExtId: $TargetDomainManagerExtId"
Write-Host "Target Cluster ExtId ($TargetClusterName): $TargetClusterExtId`n"


# --- Main Policy Creation Loop ---
$apiUrl = "https://${SourcePCIP}:9440/api/datapolicies/v4.2/config/protection-policies"

foreach ($rpo in $rpoSchedules.GetEnumerator()) {
    $rpoName = $rpo.Name
    $rpoSeconds = $rpo.Value

    $policyName = "$SourceClusterName to $TargetClusterName - $rpoName"
    
    Write-Host "Setting up Category mapping: $CategoryKey : $policyName..." -ForegroundColor Cyan
    $categoryExtId = Get-OrCreateCategory -PCIP $SourcePCIP -Headers $SourceHeaders -Key $CategoryKey -Value $policyName
    
    $SourceHeaders["NTNX-Request-Id"] = [guid]::NewGuid().ToString()

    if ($rpoSeconds -gt 3000) {
        $rollupSched = @{
                        "local" = 7
                        "remote" = 7
                        "`$objectType" = "datapolicies.v4.config.LinearRetention"
                        }
    } else {
        $rollupSched = @{
                        "local" = @{ "snapshotIntervalType" = "HOURLY"
                                     "frequency" = 7 }
                        "remote" = @{ "snapshotIntervalType" = "HOURLY"
                                     "frequency" = 7 }
                        "`$objectType" = "datapolicies.v4.config.AutoRollupRetention"
                        }
    }
    
    $payload = @{
        "name" = $policyName
        "description" = "Automated Protection Policy created via Script for $rpoName RPO"
        "categoryIds" = @($categoryExtId)
        "replicationLocations" = @(
            @{
                "label" = $SourceLocationLabel
                "domainManagerExtId" = $SourceDomainManagerExtId
                "replicationSubLocation" = @{
                    "clusterExtIds" = @($SourceClusterExtId)
                    "`$objectType" = "datapolicies.v4.config.NutanixCluster"
                }
                "isPrimary" = $true
                "`$objectType" = "datapolicies.v4.config.ReplicationLocation"
            },
            @{
                "label" = $TargetLocationLabel
                "domainManagerExtId" = $TargetDomainManagerExtId
                "replicationSubLocation" = @{
                    "clusterExtIds" = @($TargetClusterExtId)
                    "`$objectType" = "datapolicies.v4.config.NutanixCluster"
                }
                "isPrimary" = $false
                "`$objectType" = "datapolicies.v4.config.ReplicationLocation"
            }
        )
        "replicationConfigurations" = @(
            @{
                "sourceLocationLabel" = $SourceLocationLabel
                "remoteLocationLabel" = $TargetLocationLabel
                "schedule" = @{
                    "recoveryPointType" = "CRASH_CONSISTENT"
                    "recoveryPointObjectiveTimeSeconds" = $rpoSeconds
                    "retention" = $rollupSched
                    "`$objectType" = "datapolicies.v4.config.Schedule"
                }
                "`$objectType" = "datapolicies.v4.config.ReplicationConfiguration"
            }
            @{
                "sourceLocationLabel" = $TargetLocationLabel
                "remoteLocationLabel" = $SourceLocationLabel
                "schedule" = @{
                    "recoveryPointType" = "CRASH_CONSISTENT"
                    "recoveryPointObjectiveTimeSeconds" = $rpoSeconds
                    "retention" = $rollupSched
                    "`$objectType" = "datapolicies.v4.config.Schedule"
                }
                "`$objectType" = "datapolicies.v4.config.ReplicationConfiguration"
            }
        )
        "`$objectType" = "datapolicies.v4.config.ProtectionPolicy"
    }

    $jsonPayload = $payload | ConvertTo-Json -Depth 10

    Write-Host "Creating Protection Policy: $policyName (RPO: $rpoSeconds seconds)" -ForegroundColor Cyan

    # We bypass the standard Try/Catch block and capture the HTTP status code and response payload directly
    $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $SourceHeaders -Body $jsonPayload -SkipCertificateCheck -SkipHttpErrorCheck -StatusCodeVariable httpStatus

    if ($httpStatus -ge 200 -and $httpStatus -lt 300) {
        Write-Host "Success! Task ID: $($response.data.extId)`n" -ForegroundColor Green
    } else {
        Write-Host "Failed with HTTP Status: $httpStatus" -ForegroundColor Red
        Write-Host "Exact Error Payload from Nutanix:" -ForegroundColor Yellow
        $response | ConvertTo-Json -Depth 10 | Write-Host
        Write-Host "`n"
    }
}