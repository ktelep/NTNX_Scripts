[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$PC_IP,

    [Parameter(Mandatory=$true)]
    [string]$CLUSTER_NAME,

    [Parameter(Mandatory=$true)]
    [string]$Username,

    [Parameter(Mandatory=$true)]
    [string]$Password,

    [Parameter(Mandatory=$true)]
    [string]$TEMPLATE_NAME,

    [Parameter(Mandatory=$true)]
    [string]$PROFILE_NAME
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

# Nutanix V4 API Base URLs 
$BaseUrl = "https://${PC_IP}:9440"
$VmmApi = "$BaseUrl/api/vmm/v4.2/ahv/config"
$TemplateApi = "$BaseUrl/api/vmm/v4.2/content/templates"
$ClusterApi = "$BaseURL/api/clustermgmt/v4.2/config"

# Helper function to invoke API
function Invoke-NtxRest {
    param(
        $Uri, 
        $Method = "GET", 
        $Body = $null,
        $ETag = $null 
    )

    Write-Host $Uri
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
    
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 20) }
   
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

Write-Host "Connecting to Prism Central ($PC_IP) to gather Template info..." -ForegroundColor Cyan
$TemplateSearch = Invoke-NtxRest -Uri "$TemplateApi/?`$filter=templateName eq '$TEMPLATE_NAME'"
if ($TemplateSearch.data.Count -eq 0) {
    Write-Error "ERROR: Template '$TEMPLATE_NAME' not found."
    exit
}
$TemplateExtId = $TemplateSearch.data[0].extId
Write-Host "Template ID: $TemplateExtID"

Write-Host "Gathering Guest Customization Profile ID"
$gcpSearch = Invoke-NtxRest -Uri "$VmmApi/vm-guest-customization-profiles?`$filter=name eq '$PROFILE_NAME'"
if ($gcpSearch.data.Count -eq 0) {
    Write-Error "ERROR: Profile '$PROFILE_NAME' not found."
    exit
}
$gcpExtId = $gcpSearch.data[0].extId
Write-Host "gcp ID: $gcpExtID"

Write-Host "Gathering our Cluster Information"
$ClusterSearch = Invoke-NtxRest -Uri "$ClusterApi/clusters?`$filter=name eq '$CLUSTER_NAME'"
if ($ClusterSearch.data.Count -eq 0) {
    Write-Error "ERROR: Cluster '$CLUSTER_NAME' not found."
    exit
}
$ClusterExtId = $ClusterSearch.data[0].extId
Write-Host "Cluster ID: $ClusterExtID"

Write-Host "Deploying VM with Customization Profile No Overrides"

#Construct our VM Build Payload
$PayloadInfo = @{
    clusterReference = $ClusterExtId
    numberOfVms = 2
    overrideVmConfigMap = @{
        "0" = @{
            name = "MyNewServer"
            guestCustomizationProfileConfig = @{
                profile = @{
                    extId = $gcpExtId
                }
                configOverrideSpec = @{
                    customization = @{
                        generalSettings = @{
                            computerName = @{
                                value = "MyNewServer"
                                '$objectType' = "vmm.v4.ahv.config.VmGcProfileComputerName"
                            }
                        }
                        networkSettings = @{
                            nicConfigList = @(
                                @{
                                    dnsConfig = @{
                                        preferredDnsServerAddress = "192.168.2.5"
                                        alternateDnsServerAddresses = @("192.168.2.7")
                                    }
                                    ipv4Config = @{
                                        ipAddress = @{
                                            value = "192.168.2.190"
                                            prefixLength = 24
                                        }
                                        defaultGateways = @("192.168.2.1")
                                        '$objectType' = "vmm.v4.ahv.config.VmGcProfileNicIpv4ConfigOverrideSpec" 
                                    }
                                }
                            )
                        }
                        '$objectType' = "vmm.v4.ahv.config.VmGcProfileSysprepParamsOverrideSpec"
                    }   
                    '$objectType' = "vmm.v4.ahv.config.VmGcProfileSysprepConfigOverrideSpec"
                }
            }
        }
        "1" = @{
            name = "MyNewServerAD"
            guestCustomizationProfileConfig = @{
                profile = @{
                    extId = $gcpExtId
                }
                configOverrideSpec = @{
                    customization = @{
                        generalSettings = @{
                            computerName = @{
                                value = "MyNewServerAD"
                                '$objectType' = "vmm.v4.ahv.config.VmGcProfileComputerName"
                            }
                        }
                        workgroupOrDomainInfo = @{
                            credentials = @{
                                domainName = "ADS.lab.ktelep.net"
                                username = "administrator"
                                password = "nutanix/4u"
                            }
                            '$objectType' = "vmm.v4.ahv.config.VmGcProfileDomainSettingsOverrideSpec"
                        }
                        networkSettings = @{
                            nicConfigList = @(
                                @{
                                    dnsConfig = @{
                                        preferredDnsServerAddress = "192.168.2.5"
                                        alternateDnsServerAddresses = @("192.168.2.7")
                                    }
                                    ipv4Config = @{
                                        ipAddress = @{
                                            value = "192.168.2.189"
                                            prefixLength = 24
                                        }
                                        defaultGateways = @("192.168.2.1")
                                        '$objectType' = "vmm.v4.ahv.config.VmGcProfileNicIpv4ConfigOverrideSpec" 
                                    }
                                }
                            )
                        }
                        '$objectType' = "vmm.v4.ahv.config.VmGcProfileSysprepParamsOverrideSpec"
                    }   
                    '$objectType' = "vmm.v4.ahv.config.VmGcProfileSysprepConfigOverrideSpec"
                }
            }
        }
    }
}

$JsonPayload = $PayloadInfo | ConvertTo-Json -Depth 20

Write-Host $JsonPayload
$VmCreate = Invoke-NtxRest -Uri "$TemplateApi/$TemplateExtId/`$actions/deploy" -Method "POST" -Body $PayloadInfo