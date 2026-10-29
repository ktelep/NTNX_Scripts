param(
    [Parameter(Mandatory = $true)][string]$CategoryName,
    [Parameter(Mandatory = $true)][string]$CategoryKey,
    [Parameter(Mandatory = $true)][string]$PrismCentralUrl,
    [Parameter(Mandatory = $true)][PSCredential]$Credential
)

. (Join-Path $PSScriptRoot 'CategoryCommon.ps1')

$headers = New-PCHeaders -Credential $Credential
$pcUrl = $PrismCentralUrl.TrimEnd('/')
$category = Get-PCV4Category -PCUrl $pcUrl -Headers $headers -Key $CategoryName -Value $CategoryKey

if (-not $category) {
    throw "Category '$CategoryName`:$CategoryKey' was not found."
}

$vmsUrl = "$pcUrl/api/vmm/v4.3/ahv/config/vms"
$vms = Get-PCV4Collection -Uri $vmsUrl -Headers $headers
$matchedVms = @($vms | Where-Object {
    @($_.categories | Where-Object { $_.extId -eq $category.extId }).Count -gt 0
})

if ($matchedVms.Count -eq 0) {
    Write-Host "No VMs are assigned category '$CategoryName`:$CategoryKey'."
    return
}

$matchedVms | ForEach-Object { Write-Output $_.name }
