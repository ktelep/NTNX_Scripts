param(
    [Parameter(Mandatory = $true)][string]$ClusterName,
    [Parameter(Mandatory = $true)][string]$CategoryName,
    [Parameter(Mandatory = $true)][string]$CategoryKey,
    [Parameter(Mandatory = $true)][string]$PrismCentralUrl,
    [Parameter(Mandatory = $true)][PSCredential]$Credential
)

. (Join-Path $PSScriptRoot 'CategoryCommon.ps1')

$headers = New-PCHeaders -Credential $Credential
$pcUrl = $PrismCentralUrl.TrimEnd('/')
$clustersUrl = "$pcUrl/api/clustermgmt/v4.3/config/clusters"
$clusters = Get-PCV4Collection -Uri $clustersUrl -Headers $headers
$matches = @($clusters | Where-Object { $_.name -eq $ClusterName })

if ($matches.Count -eq 0) {
    throw "Cluster '$ClusterName' not found."
}
if ($matches.Count -gt 1) {
    throw "More than one cluster named '$ClusterName' was returned by Prism Central."
}

$category = Get-PCV4Category -PCUrl $pcUrl -Headers $headers -Key $CategoryName -Value $CategoryKey
if (-not $category) {
    throw "Category '$CategoryName`:$CategoryKey' does not exist. Create it before assigning it to a cluster."
}

$uri = "$pcUrl/api/clustermgmt/v4.3/config/clusters/$($matches[0].extId)/`$actions/associate-categories"
$body = @{ categories = @($category.extId) }
$null = Invoke-PCV4Request -Uri $uri -Headers $headers -Method Post -Body $body
Write-Host "Category '$CategoryName`:$CategoryKey' assigned to cluster '$ClusterName'."
