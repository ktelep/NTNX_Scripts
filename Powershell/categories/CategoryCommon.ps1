function New-PCHeaders {
    param(
        [Parameter(Mandatory = $true)][PSCredential]$Credential
    )

    $password = $Credential.GetNetworkCredential().Password
    $authBytes = [System.Text.Encoding]::UTF8.GetBytes("$($Credential.UserName):$password")
    $authInfo = [Convert]::ToBase64String($authBytes)

    return @{
        Authorization = "Basic $authInfo"
        Accept        = "application/json"
        'Content-Type' = "application/json"
    }
}

function Invoke-PCV4Request {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][ValidateSet('Get', 'Post', 'Delete')][string]$Method,
        [object]$Body
    )

    $request = @{
        Uri                  = $Uri
        Headers              = @{
            Authorization     = $Headers.Authorization
            Accept            = $Headers.Accept
            'Content-Type'    = $Headers['Content-Type']
            'NTNX-Request-Id' = [guid]::NewGuid().ToString()
        }
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
        $pageUri = "$($Uri)?`$page=$page&`$limit=$limit"
        $response = Invoke-PCV4Request -Uri $pageUri -Headers $Headers -Method Get
        if ($null -ne $response.data) {
            foreach ($item in @($response.data)) {
                $items.Add($item)
            }
        }
        $page++
    } while (@($response.data).Count -eq $limit)

    return $items.ToArray()
}

function Get-PCV4Category {
    param(
        [Parameter(Mandatory = $true)][string]$PCUrl,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $filter = "key eq '$($Key.Replace("'", "''"))' and value eq '$($Value.Replace("'", "''"))'"
    $encodedFilter = [uri]::EscapeDataString($filter)
    $uri = "$($PCUrl.TrimEnd('/'))/api/prism/v4.4/config/categories?`$filter=$encodedFilter&`$limit=100"
    $response = Invoke-PCV4Request -Uri $uri -Headers $Headers -Method Get

    if ($response.data -and @($response.data).Count -gt 0) {
        return @($response.data)[0]
    }

    return $null
}

function Get-PCV4VmByName {
    param(
        [Parameter(Mandatory = $true)][string]$PCUrl,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $uri = "$($PCUrl.TrimEnd('/'))/api/vmm/v4.3/ahv/config/vms"
    $vms = Get-PCV4Collection -Uri $uri -Headers $Headers
    $matches = @($vms | Where-Object { $_.name -eq $Name })

    if ($matches.Count -gt 1) {
        throw "More than one VM named '$Name' was returned by Prism Central."
    }

    if ($matches.Count -eq 1) {
        return $matches[0]
    }

    return $null
}
