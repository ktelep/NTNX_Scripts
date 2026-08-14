param(
    [string]$CategoryName,
    [string]$CategoryKey
)

# Set Prism Central credentials
# --------------------------------------------------
$PrismCentralURL = "https://192.168.1.205:9440"
$UserName = "admin"
$Password = "password"


[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Ssl3, [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12


# Check if VMName and CategoryName are provided
# --------------------------------------------------
if (-not $CategoryKey -or -not $CategoryName) {
    Write-Host "Please provide the Category Name and Category Key"
    exit
}

# Authenticate with Prism Central
# --------------------------------------------------
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $UserName,$Password)))
$headers = @{
    
    Authorization=("Basic {0}" -f $base64AuthInfo);
    "Content-Type"="application/json";
    "Accept"="application/json"
}

# Check that our Category actually exists
# --------------------------------------------------
$CatURL = "$PrismCentralURL/api/nutanix/v3/categories/$CategoryName/$CategoryKey"
$CatResponse = try { Invoke-WebRequest -Uri $CatURL -Headers $headers -method Get
} catch [System.Net.WebException] {
    Write-Host "Category Name and Key not found, check spelling and capitalization"
    exit
}

$CategoryRequest = @"
{
    "usage_type":"APPLIED_TO",
    "group_member_count":1000,
    "category_filter": {
        "kind_list": [ "vm" ],
        "params": {
            "$CategoryName" : ["$CategoryKey"]
        }
    }
}
"@


$QURL = "$PrismCentralURL/api/nutanix/v3/category/query"

$VMResponse = Invoke-RestMethod -Uri $QURL -Headers $headers -Method Post -Body $CategoryRequest
$VMResponse.results[0].kind_reference_list | Write-Output | foreach-object {
    Write-Host $_.name
}
