param(
    [string]$VMName,
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
if (-not $VMName -or -not $CategoryName) {
    Write-Host "Please provide the name of the virtual machine and the category as arguments."
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

# Get our Virtual machine info and VMUUID
# --------------------------------------------------
$VMURL = "$PrismCentralURL/api/nutanix/v3/vms/list"

$VMBody = @"
{ "kind": "vm" }
"@

$VMResponse = Invoke-RestMethod -Uri $VMURL -Headers $headers -Method Post -Body $VMBody
$VM = $VMResponse.entities | Where-Object { $_.spec.name -eq $VMName }
if (-not $VM) {
    Write-Host "Virtual machine '$VMName' not found."
    exit
}
$VMUUID = $VM.metadata.uuid

# Update the VM Definition with our changes
# This looks really complex, but it's really so we don't
# wipe out any existing categories that are already set
# --------------------------------------------------
$VM.PSObject.Properties.Remove('status')   # Drop the status field

$NewVMCategories = [PSCustomObject]@{}     # Object for our new categories

# Get our Category Objects, loop through each one
$CatFound = $false 

$VM.metadata.categories_mapping | get-member -type NoteProperty | foreach-object { 
    if ($_.Name -eq $CategoryName) {   # Handle if the Category already exists
       $CatFound = $true
       if ($VM.metadata.categories_mapping.$CategoryName -is [System.String]) {  # If it's a single element, we need to convert to array
                $CatValue = $VM.metadata.categories_mapping.$CategoryName
                if ($CatValue -eq $CategoryKey) {  # If we've already got this category assigned, we're done here
                    Write-Host "Category already assigned to VM"
                    exit
                }
                # Create a new array with the new Key and the existing Key
                $CatArr = @($CatValue, $CategoryKey)
                $NewVMCategories | Add-Member -MemberType NoteProperty -Name $CategoryName -Value $CatArr
       } 
       else  # Handle adding our item to the array if necessary
       {
                if ($VM.metadata.categories_mapping.$CategoryName.contains($CategoryKey)){  # Check if already assigned
                    Write-Host "Category already assigned to VM"
                    exit
                }
                $CatArr = @($CategoryKey) + $VM.metadata.categories_mapping.$CategoryName
                $NewVMCategories | Add-Member -MemberType NoteProperty -Name $CategoryName -Value $CatArr
       }
   } 
    else # Copy over the values
    {
        if ($VM.metadata.categories_mapping."$($_.Name)" -is [System.String]) {  
            $CatValue = $VM.metadata.categories_mapping."$($_.Name)"
            $NewVMCategories | Add-Member -MemberType NoteProperty -Name $_.Name -Value $CatValue
        } 
        else
        {
            $CatArr = @() + $VM.metadata.categories_mapping."$($_.Name)"
            $NewVMCategories | Add-Member -MemberType NoteProperty -Name $_.Name -Value $CatArr
        }
    }
    
}

if ($CatFound -eq $false) {
   $NewVMCategories | Add-Member -MemberType NoteProperty -Name $CategoryName -Value $CategoryKey
}

# Actually assign our new mappings
# Note we have to make sure use_category_mapping is set 
# to true here, so it will actually honor the new map
# --------------------------------------------------
$VM.metadata.categories_mapping = $NewVMCategories
$VM.metadata | Add-Member -MemberType NoteProperty -Name "use_categories_mapping" -Value $true

# Send the request to update the mappings
# --------------------------------------------------
$CategoryURL = "$PrismCentralURL/api/nutanix/v3/vms/$VMUUID"
$VMCategoryResponse = Invoke-WebRequest -Uri $CategoryURL -Headers $headers -Method Put -Body (ConvertTo-Json -InputObject $VM -Depth 10)
Write-Host $VMCategoryResponse.StatusCode

if ($VMCategoryResponse.StatusCode -eq 202) {
    Write-Host "Category '$CategoryName' accepted successfully for VM '$VMName'."
} else {
    Write-Host "Failed to send request assigning '$CategoryName : $CategoryKey' for VM '$VMName'."
}