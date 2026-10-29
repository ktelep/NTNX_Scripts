param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [Parameter(Mandatory = $true)][string]$PrismCentralUrl,
    [Parameter(Mandatory = $true)][PSCredential]$Credential
)

. (Join-Path $PSScriptRoot 'CategoryCommon.ps1')

if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
    throw "Input file '$InputFile' does not exist."
}

$headers = New-PCHeaders -Credential $Credential
$pcUrl = $PrismCentralUrl.TrimEnd('/')
$categoriesUrl = "$pcUrl/api/prism/v4.4/config/categories"
$lineNumber = 0

foreach ($line in Get-Content -LiteralPath $InputFile) {
    $lineNumber++
    $entry = $line.Trim()

    if (-not $entry -or $entry.StartsWith('#')) {
        continue
    }

    $separator = $entry.IndexOf(':')
    if ($separator -lt 1 -or $separator -eq ($entry.Length - 1)) {
        throw "Invalid input at line $lineNumber. Expected key:value."
    }

    $key = $entry.Substring(0, $separator).Trim()
    $value = $entry.Substring($separator + 1).Trim()
    if (-not $key -or -not $value) {
        throw "Invalid input at line $lineNumber. Both key and value are required."
    }

    $matchingKey = "key eq '$($key.Replace("'", "''"))'"
    $encodedKeyFilter = [uri]::EscapeDataString($matchingKey)
    $keyUrl = "$($categoriesUrl)?`$filter=$encodedKeyFilter&`$limit=1"
    $keyResponse = Invoke-PCV4Request -Uri $keyUrl -Headers $headers -Method Get
    $keyExists = $keyResponse.data -and @($keyResponse.data).Count -gt 0

    $matchingPair = "key eq '$($key.Replace("'", "''"))' and value eq '$($value.Replace("'", "''"))'"
    $encodedPairFilter = [uri]::EscapeDataString($matchingPair)
    $pairUrl = "$($categoriesUrl)?`$filter=$encodedPairFilter&`$limit=1"
    $pairResponse = Invoke-PCV4Request -Uri $pairUrl -Headers $headers -Method Get
    $category = $null
    if ($pairResponse.data -and @($pairResponse.data).Count -gt 0) {
        $category = @($pairResponse.data)[0]
    }

    if ($keyExists) {
        Write-Host "Key '$key' already exists."
    } else {
        Write-Host "Key '$key' does not exist; creating its first value."
    }

    if ($category) {
        Write-Host "Category '$key`:$value' already exists."
        continue
    }

    $body = @{ key = $key; value = $value }
    $null = Invoke-PCV4Request -Uri $categoriesUrl -Headers $headers -Method Post -Body $body
    Write-Host "Created category '$key`:$value'."
}
