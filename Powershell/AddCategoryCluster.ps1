param(
    [string]$ClusterName,
    [string]$CategoryName,
    [string]$CategoryKey
)

# Set Prism Central credentials
# --------------------------------------------------
$PrismCentralURL = "https://10.38.4.74:9440"
$UserName = "admin"
$Password = "ahv4EVA!!"


#[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
#[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Ssl3, [Net.SecurityProtocolType]::Tls, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls12


# Check if ClusterName and CategoryName are provided
# --------------------------------------------------
if (-not $ClusterName -or -not $CategoryName) {
    Write-Host "Please provide the name of the cluster and the category as arguments."
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
$CatResponse = try { Invoke-WebRequest -SkipCertificateCheck -Uri $CatURL -Headers $headers -method Get
} catch [System.Net.WebException] {
    Write-Host "Category Name and Key not found, check spelling and capitalization"
    Write-Host $CategoryName
    Write-Host $CategoryKey
    exit
}

# Get our Virtual machine info and VMUUID
# --------------------------------------------------
$CLURL = "$PrismCentralURL/api/nutanix/v3/clusters/list"
$CLBody = @"
{ "kind": "cluster" }
"@

$CLResponse = Invoke-RestMethod -SkipCertificateCheck -Uri $CLURL -Headers $headers -Method Post -Body $CLBody
$CL = $CLResponse.entities | Where-Object { $_.spec.name -eq $ClusterName }
if (-not $CL) {
    Write-Host "Cluster '$ClusterName' not found."
    exit
}
$CLUUID = $CL.metadata.uuid

# Update the Cluster Definition with our changes
# This looks really complex, but it's really so we don't
# wipe out any existing categories that are already set
# --------------------------------------------------
$CL.PSObject.Properties.Remove('status')   # Drop the status field

$NewCLCategories = [PSCustomObject]@{}     # Object for our new categories

# Get our Category Objects, loop through each one
$CatFound = $false 

$CL.metadata.categories_mapping | get-member -type NoteProperty | foreach-object { 
    if ($_.Name -eq $CategoryName) {   # Handle if the Category already exists
       $CatFound = $true
       if ($CL.metadata.categories_mapping.$CategoryName -is [System.String]) {  # If it's a single element, we need to convert to array
                $CatValue = $CL.metadata.categories_mapping.$CategoryName
                if ($CatValue -eq $CategoryKey) {  # If we've already got this category assigned, we're done here
                    Write-Host "Category already assigned to CL"
                    exit
                }
                # Create a new array with the new Key and the existing Key
                $CatArr = @($CatValue, $CategoryKey)
                $NewCLCategories | Add-Member -MemberType NoteProperty -Name $CategoryName -Value $CatArr
       } 
       else  # Handle adding our item to the array if necessary
       {
                if ($CL.metadata.categories_mapping.$CategoryName.contains($CategoryKey)){  # Check if already assigned
                    Write-Host "Category already assigned to CL"
                    exit
                }
                $CatArr = @($CategoryKey) + $CL.metadata.categories_mapping.$CategoryName
                $NewCLCategories | Add-Member -MemberType NoteProperty -Name $CategoryName -Value $CatArr
       }
    } 
    else # Copy over the values
    {
        if ($CL.metadata.categories_mapping."$($_.Name)" -is [System.String]) {  
            $CatValue = $CL.metadata.categories_mapping."$($_.Name)"
            $NewCLCategories | Add-Member -MemberType NoteProperty -Name $_.Name -Value $CatValue
        } 
        else
        {
            $CatArr = @() + $CL.metadata.categories_mapping."$($_.Name)"
            $NewCLCategories | Add-Member -MemberType NoteProperty -Name $_.Name -Value $CatArr
        }
    }
    
}

if ($CatFound -eq $false) {
   $CatArr = @($CategoryKey)
   $NewCLCategories | Add-Member -MemberType NoteProperty -Name $CategoryName -Value $CatArr
}

# Actually assign our new mappings
# Note we have to make sure use_category_mapping is set 
# to true here, so it will actually honor the new map
# --------------------------------------------------
$CL.metadata.categories_mapping = $NewCLCategories
$CL.metadata | Add-Member -MemberType NoteProperty -Name "use_categories_mapping" -Value $true
# Send the request to update the mappings
# --------------------------------------------------
$CategoryURL = "$PrismCentralURL/api/nutanix/v3/clusters/$CLUUID"
$CLCategoryResponse = Invoke-WebRequest -SkipCertificateCheck -Uri $CategoryURL -Headers $headers -Method Put -Body (ConvertTo-Json -InputObject $CL -Depth 10)
Write-Host $CLCategoryResponse.StatusCode

if ($CLCategoryResponse.StatusCode -eq 202) {
    Write-Host "Category '$CategoryName' accepted successfully for CL '$ClusterName'."
} else {
    Write-Host "Failed to send request assigning '$CategoryName : $CategoryKey' for CL '$ClusterName'."
}