param(
    [Parameter(Mandatory = $true)][string]$ClusterName,
    [Parameter(Mandatory = $true)][string]$InputFile,
    [Parameter(Mandatory = $true)][string]$PrismCentralUrl,
    [Parameter(Mandatory = $true)][PSCredential]$Credential,
    [ValidateSet('Advanced', 'Basic')][string]$NetworkMode = 'Advanced'
)

$ErrorActionPreference = 'Stop'

function New-PCHeaders {
    param([Parameter(Mandatory = $true)][PSCredential]$Credential)

    $password = $Credential.GetNetworkCredential().Password
    $authBytes = [System.Text.Encoding]::UTF8.GetBytes("$($Credential.UserName):$password")
    $authInfo = [Convert]::ToBase64String($authBytes)

    return @{
        Authorization  = "Basic $authInfo"
        Accept         = 'application/json'
        'Content-Type' = 'application/json'
    }
}

function Invoke-PCV4Request {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][ValidateSet('Get', 'Post')][string]$Method,
        [object]$Body
    )

    $requestHeaders = @{}
    foreach ($key in $Headers.Keys) {
        $requestHeaders[$key] = $Headers[$key]
    }
    $requestHeaders['NTNX-Request-Id'] = [guid]::NewGuid().ToString()

    $request = @{
        Uri                  = $Uri
        Headers              = $requestHeaders
        Method               = $Method
        ErrorAction          = 'Stop'
        SkipCertificateCheck = $true
    }
    if ($null -ne $Body) {
        $request.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }

    try {
        return Invoke-RestMethod @request
    } catch {
        $errorDetails = $_.ErrorDetails.Message
        if (-not $errorDetails) {
            $errorDetails = $_.Exception.Message
        }
        throw "Prism Central $Method request to '$Uri' failed: $errorDetails"
    }
}

function Get-PCV4Collection {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $page = 0
    $limit = 100

    do {
        $separator = if ($Uri.Contains('?')) { '&' } else { '?' }
        $pageUri = "$Uri$separator`$page=$page&`$limit=$limit"
        $response = Invoke-PCV4Request -Uri $pageUri -Headers $Headers -Method Get
        foreach ($item in @($response.data)) {
            if ($null -ne $item) {
                $items.Add($item)
            }
        }
        $page++
    } while (@($response.data).Count -eq $limit)

    return $items.ToArray()
}

function Get-UniqueNamedResource {
    param(
        [Parameter(Mandatory = $true)][object[]]$Resources,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ResourceType
    )

    $matches = @($Resources | Where-Object { $_.name -eq $Name })
    if ($matches.Count -eq 0) {
        throw "$ResourceType '$Name' was not found."
    }
    if ($matches.Count -gt 1) {
        throw "More than one $ResourceType named '$Name' was returned."
    }
    return $matches[0]
}

function Wait-PCV4Task {
    param(
        [Parameter(Mandatory = $true)][string]$PCUrl,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$TaskExtId
    )

    $taskUrl = "$PCUrl/api/prism/v4.4/config/tasks/$TaskExtId"
    for ($attempt = 0; $attempt -lt 36; $attempt++) {
        $response = Invoke-PCV4Request -Uri $taskUrl -Headers $Headers -Method Get
        $task = $response.data
        if ($task.status -in @('SUCCEEDED', 'FAILED', 'CANCELLED')) {
            return $task
        }
        Start-Sleep -Seconds 5
    }

    throw "Task '$TaskExtId' did not complete within 3 minutes."
}

if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
    throw "Input file '$InputFile' does not exist."
}

$networks = [System.Collections.Generic.List[object]]::new()
$networkNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$lineNumber = 0
foreach ($line in Get-Content -LiteralPath $InputFile) {
    $lineNumber++
    $entry = $line.Trim()
    if (-not $entry -or $entry.StartsWith('#')) {
        continue
    }

    $fields = $entry.Split(':')
    if ($fields.Count -ne 3) {
        throw "Invalid input at line $lineNumber. Expected network_name:VLANID:vswitch_name."
    }

    $networkName = $fields[0].Trim()
    $vlanText = $fields[1].Trim()
    $virtualSwitchName = $fields[2].Trim()
    if (-not $networkName -or -not $vlanText -or -not $virtualSwitchName) {
        throw "Invalid input at line $lineNumber. Network name, VLAN ID, and vSwitch name are all required."
    }
    if (-not $networkNames.Add($networkName)) {
        throw "Duplicate network name '$networkName' at line $lineNumber. Each network name may appear only once in the input file."
    }

    $vlanId = 0
    if (-not [int]::TryParse($vlanText, [ref]$vlanId) -or $vlanId -lt 1 -or $vlanId -gt 4094) {
        throw "Invalid VLAN ID '$vlanText' at line $lineNumber. VLAN IDs must be integers from 1 through 4094."
    }

    $networks.Add(@{
        Name             = $networkName
        VlanId           = $vlanId
        VirtualSwitchName = $virtualSwitchName
    })
}

if ($networks.Count -eq 0) {
    throw "Input file '$InputFile' contains no network entries."
}

$headers = New-PCHeaders -Credential $Credential
$pcUrl = $PrismCentralUrl.TrimEnd('/')
$clustersUrl = "$pcUrl/api/clustermgmt/v4.3/config/clusters"
$clusters = Get-PCV4Collection -Uri $clustersUrl -Headers $headers
$cluster = Get-UniqueNamedResource -Resources $clusters -Name $ClusterName -ResourceType 'Cluster'
if (-not $cluster.extId) {
    throw "Cluster '$ClusterName' did not provide an external ID."
}

$virtualSwitchHeaders = @{}
foreach ($key in $headers.Keys) {
    $virtualSwitchHeaders[$key] = $headers[$key]
}
$virtualSwitchHeaders['X-Cluster-Id'] = $cluster.extId
$virtualSwitchesUrl = "$pcUrl/api/networking/v4.4/config/virtual-switches"
$virtualSwitches = Get-PCV4Collection -Uri $virtualSwitchesUrl -Headers $virtualSwitchHeaders

$subnetsUrl = "$pcUrl/api/networking/v4.4/config/subnets"
$existingSubnets = Get-PCV4Collection -Uri $subnetsUrl -Headers $headers
$creationErrors = [System.Collections.Generic.List[string]]::new()

foreach ($network in $networks) {
    $virtualSwitch = Get-UniqueNamedResource -Resources $virtualSwitches -Name $network.VirtualSwitchName -ResourceType 'Virtual switch'
    if (-not $virtualSwitch.extId) {
        throw "Virtual switch '$($network.VirtualSwitchName)' did not provide an external ID."
    }

    $existing = @($existingSubnets | Where-Object {
        $_.name -eq $network.Name -and $_.clusterReference -eq $cluster.extId
    })
    if ($existing.Count -gt 0) {
        Write-Host "Subnet '$($network.Name)' already exists on cluster '$ClusterName'; skipping."
        continue
    }

    $body = @{
        name                   = $network.Name
        subnetType             = 'VLAN'
        networkId              = $network.VlanId
        clusterReference       = $cluster.extId
        virtualSwitchReference = $virtualSwitch.extId
        isAdvancedNetworking   = ($NetworkMode -eq 'Advanced')
    }

    try {
        $createResponse = Invoke-PCV4Request -Uri $subnetsUrl -Headers $headers -Method Post -Body $body
        if (-not $createResponse.data.extId) {
            throw 'The create request did not return a task ID.'
        }

        $task = Wait-PCV4Task -PCUrl $pcUrl -Headers $headers -TaskExtId $createResponse.data.extId
        if ($task.status -ne 'SUCCEEDED') {
            $taskErrors = @($task.errorMessages | ForEach-Object { $_.message }) -join '; '
            if (-not $taskErrors) {
                $taskErrors = "Task finished with status '$($task.status)'."
            }
            throw $taskErrors
        }

        Write-Host "Created $($NetworkMode.ToLowerInvariant()) VLAN network '$($network.Name)' (VLAN $($network.VlanId)) on cluster '$ClusterName' using vSwitch '$($network.VirtualSwitchName)'."
    } catch {
        $message = "Network '$($network.Name)' (VLAN $($network.VlanId)): $($_.Exception.Message)"
        $creationErrors.Add($message)
        Write-Warning $message
    }
}

if ($creationErrors.Count -gt 0) {
    throw "Failed to create $($creationErrors.Count) network(s): $($creationErrors -join ' | ')"
}
