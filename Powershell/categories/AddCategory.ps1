param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][string]$CategoryName,
    [Parameter(Mandatory = $true)][string]$CategoryKey,
    [Parameter(Mandatory = $true)][string]$PrismCentralUrl,
    [Parameter(Mandatory = $true)][PSCredential]$Credential
)

. (Join-Path $PSScriptRoot 'CategoryCommon.ps1')

$headers = New-PCHeaders -Credential $Credential
$pcUrl = $PrismCentralUrl.TrimEnd('/')

# In the v4 API, the former category name is the key and the former category key is the value.
$category = Get-PCV4Category -PCUrl $pcUrl -Headers $headers -Key $CategoryName -Value $CategoryKey
if (-not $category) {
    throw "Category '$CategoryName`:$CategoryKey' does not exist. Create it before assigning it to a VM."
}

$vm = Get-PCV4VmByName -PCUrl $pcUrl -Headers $headers -Name $VMName
if (-not $vm) {
    throw "Virtual machine '$VMName' not found."
}

if (@($vm.categories | Where-Object { $_.extId -eq $category.extId }).Count -gt 0) {
    Write-Host "Category '$CategoryName`:$CategoryKey' is already assigned to VM '$VMName'."
    return
}

$uri = "$pcUrl/api/vmm/v4.3/ahv/config/vms/$($vm.extId)/`$actions/associate-categories"
$body = @{ categories = @(@{ extId = $category.extId }) }
$null = Invoke-PCV4Request -Uri $uri -Headers $headers -Method Post -Body $body
Write-Host "Category '$CategoryName`:$CategoryKey' assigned to VM '$VMName'."
