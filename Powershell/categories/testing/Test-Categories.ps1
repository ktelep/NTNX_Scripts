param(
    [Parameter(Mandatory = $true)][PSCredential]$Credential,
    [string]$PrismCentralUrl = 'https://192.168.2.210:9440',
    [string]$ClusterName = 'NTNXP1',
    [string]$ImageName = 'Rocky-10-GenericCloud-Base.latest.x86_64.qcow2',
    [string]$SubnetName = 'VLAN3',
    [string]$InputFile = (Join-Path $PSScriptRoot 'TestCategoryPairs.txt')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CategoryCommon.ps1')

$pcUrl = $PrismCentralUrl.TrimEnd('/')
$headers = New-PCHeaders -Credential $Credential
$categoryScript = Join-Path $PSScriptRoot 'CreateCategories.ps1'
$assignScript = Join-Path $PSScriptRoot 'AddCategory.ps1'
$listScript = Join-Path $PSScriptRoot 'ListCategoryVMs.ps1'
$vmNames = [System.Collections.Generic.List[string]]::new()
$vmExtIds = @{}
$pairs = [System.Collections.Generic.List[object]]::new()
$expectedAssignments = @{}
$cleanupErrors = [System.Collections.Generic.List[string]]::new()
$testInputFile = $null
$mayCleanupCategories = $false
$runId = [guid]::NewGuid().ToString('N').Substring(0, 10)

function Get-TestPairs {
    param([string]$Path)

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $entry = $line.Trim()
        if (-not $entry -or $entry.StartsWith('#')) { continue }

        $separator = $entry.IndexOf(':')
        if ($separator -lt 1 -or $separator -eq ($entry.Length - 1)) {
            throw "Invalid test input row '$entry'; expected key:value."
        }

        $result.Add(@{
            Key   = $entry.Substring(0, $separator).Trim()
            Value = $entry.Substring($separator + 1).Trim()
        })
    }
    return $result.ToArray()
}

function Get-UniqueNamedResource {
    param(
        [object[]]$Resources,
        [string]$Name,
        [string]$ResourceType
    )

    $matches = @($Resources | Where-Object { $_.name -eq $Name })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one $ResourceType named '$Name'; found $($matches.Count)."
    }
    return $matches[0]
}

$vmCreateUrl = "$pcUrl/api/vmm/v4.3/ahv/config/vms"
$vmDeleteUrl = "$pcUrl/api/vmm/v4.3/ahv/config/vms"
$categoryCollectionUrl = "$pcUrl/api/prism/v4.4/config/categories"

try {
    if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
        throw "Test input file '$InputFile' does not exist."
    }

    $testPairs = @(Get-TestPairs -Path $InputFile)
    $uniqueOriginalKeys = @($testPairs.Key | Sort-Object -Unique)
    if ($testPairs.Count -lt 50 -or $uniqueOriginalKeys.Count -lt 10) {
        throw "Test input must have at least 50 pairs and 10 unique category keys. Found $($testPairs.Count) pairs and $($uniqueOriginalKeys.Count) keys."
    }
    foreach ($key in $uniqueOriginalKeys) {
        $valuesForKey = @($testPairs | Where-Object { $_.Key -eq $key })
        if ($valuesForKey.Count -lt 5) {
            throw "Test input key '$key' must have at least five values so every test VM receives a distinct value."
        }
    }
    foreach ($pair in $testPairs) {
        $pairs.Add(@{
            Key   = "CategoryScriptTest_${runId}_$($pair.Key)"
            Value = $pair.Value
        })
    }
    $uniqueKeys = @($pairs.Key | Sort-Object -Unique)

    $testInputFile = [System.IO.Path]::GetTempFileName()
    $testInputLines = @($pairs | ForEach-Object { "$($_.Key):$($_.Value)" })
    [System.IO.File]::WriteAllLines($testInputFile, $testInputLines)

    # Refuse to run against existing test categories; cleanup must never remove pre-existing data.
    foreach ($pair in $pairs) {
        $category = Get-PCV4Category -PCUrl $pcUrl -Headers $headers -Key $pair.Key -Value $pair.Value
        if ($category) {
            throw "Test category '$($pair.Key):$($pair.Value)' already exists. Remove or rename the test data before retrying."
        }
    }
    $clusters = Get-PCV4Collection -Uri "$pcUrl/api/clustermgmt/v4.3/config/clusters" -Headers $headers
    $cluster = Get-UniqueNamedResource -Resources $clusters -Name $ClusterName -ResourceType 'cluster'

    $images = Get-PCV4Collection -Uri "$pcUrl/api/vmm/v4.3/content/images" -Headers $headers
    $image = Get-UniqueNamedResource -Resources $images -Name $ImageName -ResourceType 'image'
    if (-not $image.sizeBytes -or [long]$image.sizeBytes -le 0) {
        throw "Image '$ImageName' did not report a usable disk size."
    }
    if ($image.type -match 'ISO') {
        throw "Image '$ImageName' is an ISO image; the VM test requires a bootable disk image."
    }

    $subnets = Get-PCV4Collection -Uri "$pcUrl/api/networking/v4.4/config/subnets" -Headers $headers
    $subnet = Get-UniqueNamedResource -Resources $subnets -Name $SubnetName -ResourceType 'subnet'

    $storageContainers = Get-PCV4Collection -Uri "$pcUrl/api/clustermgmt/v4.3/config/storage-containers" -Headers $headers
    $clusterContainers = @($storageContainers | Where-Object {
        $_.clusterExtId -eq $cluster.extId -and -not $_.isInternal
    })
    if ($clusterContainers.Count -eq 0) {
        throw "No usable storage container was found on cluster '$ClusterName'."
    }
    $storageContainer = $clusterContainers[0]
    if (-not $storageContainer.containerExtId) {
        throw "Storage container '$($storageContainer.name)' did not provide a container external ID."
    }

    $mayCleanupCategories = $true
    Write-Host "Creating categories from '$InputFile'..."
    & $categoryScript -InputFile $testInputFile -PrismCentralUrl $pcUrl -Credential $Credential

    # Run it a second time to exercise existing-key and existing-pair handling.
    & $categoryScript -InputFile $testInputFile -PrismCentralUrl $pcUrl -Credential $Credential

    $categories = [System.Collections.Generic.List[object]]::new()
    foreach ($pair in $pairs) {
        $category = Get-PCV4Category -PCUrl $pcUrl -Headers $headers -Key $pair.Key -Value $pair.Value
        if (-not $category) {
            throw "Category '$($pair.Key):$($pair.Value)' was not created."
        }
        $categories.Add($category)
    }

    for ($vmIndex = 1; $vmIndex -le 5; $vmIndex++) {
        $vmName = "CategoryScriptTest-$runId-$vmIndex"
        $vmNames.Add($vmName)

        $vmBody = @{
            name              = $vmName
            description       = 'Temporary VM created by the category scripts integration test.'
            numSockets        = 1
            numCoresPerSocket = 1
            numThreadsPerCore = 1
            memorySizeBytes   = 1073741824
            bootConfig        = @{
                '$objectType' = 'vmm.v4.ahv.config.LegacyBoot'
                bootOrder     = @('DISK')
                bootDevice    = @{
                    '$objectType' = 'vmm.v4.ahv.config.BootDeviceDisk'
                    diskAddress   = @{
                        busType     = 'SCSI'
                        index       = 0
                        '$objectType' = 'vmm.v4.ahv.config.DiskAddress'
                    }
                }
            }
            cluster           = @{
                extId        = $cluster.extId
                '$objectType' = 'vmm.v4.ahv.config.ClusterReference'
            }
            disks             = @(
                @{
                    diskAddress = @{
                        busType     = 'SCSI'
                        index       = 0
                        '$objectType' = 'vmm.v4.ahv.config.DiskAddress'
                    }
                    backingInfo = @{
                        '$objectType'    = 'vmm.v4.ahv.config.VmDisk'
                        diskSizeBytes    = [long]$image.sizeBytes
                        storageContainer = @{
                            extId        = $storageContainer.containerExtId
                            '$objectType' = 'vmm.v4.ahv.config.VmDiskContainerReference'
                        }
                        dataSource       = @{
                            '$objectType' = 'vmm.v4.ahv.config.DataSource'
                            reference = @{
                                '$objectType'  = 'vmm.v4.ahv.config.ImageReference'
                                imageExtId     = $image.extId
                                storageCluster = @{
                                    extId        = $cluster.extId
                                    '$objectType' = 'vmm.v4.ahv.config.ClusterReference'
                                }
                            }
                        }
                    }
                }
            )
            nics              = @(
                @{
                    nicBackingInfo = @{
                        '$objectType' = 'vmm.v4.ahv.config.VirtualEthernetNic'
                        model         = 'VIRTIO'
                        isConnected   = $true
                    }
                    nicNetworkInfo = @{
                        '$objectType' = 'vmm.v4.ahv.config.VirtualEthernetNicNetworkInfo'
                        nicType       = 'NORMAL_NIC'
                        subnet        = @{
                            extId        = $subnet.extId
                            '$objectType' = 'vmm.v4.ahv.config.SubnetReference'
                        }
                        ipv4Config    = @{ shouldAssignIp = $true }
                    }
                }
            )
        }

        Write-Host "Creating test VM '$vmName'..."
        $createResponse = Invoke-PCV4Request -Uri $vmCreateUrl -Headers $headers -Method Post -Body $vmBody
        $vmExtIds[$vmName] = $createResponse.data.extId
        $createdVm = $null
        for ($attempt = 0; $attempt -lt 36 -and -not $createdVm; $attempt++) {
            $createdVm = Get-PCV4VmByName -PCUrl $pcUrl -Headers $headers -Name $vmName
            if (-not $createdVm) { Start-Sleep -Seconds 5 }
        }
        if (-not $createdVm) {
            throw "VM '$vmName' was submitted but did not appear in Prism Central before timeout."
        }
        $vmExtIds[$vmName] = $createdVm.extId

        # Assign one value per key to each VM, covering all 50 category pairs.
        foreach ($key in $uniqueKeys) {
            $keyPairs = @($pairs | Where-Object { $_.Key -eq $key })
            $pairForVm = $keyPairs[$vmIndex - 1]
            & $assignScript -VMName $vmName -CategoryName $pairForVm.Key -CategoryKey $pairForVm.Value -PrismCentralUrl $pcUrl -Credential $Credential
            $expectedAssignments["$($pairForVm.Key):$($pairForVm.Value)"] = $vmName
        }
    }

    # Verify the listing script returns the VM assigned to every tested category pair.
    foreach ($pair in $pairs) {
        $expectedVm = $expectedAssignments["$($pair.Key):$($pair.Value)"]
        $listedVms = @(& $listScript -CategoryName $pair.Key -CategoryKey $pair.Value -PrismCentralUrl $pcUrl -Credential $Credential)
        if ($expectedVm -notin $listedVms) {
            throw "ListCategoryVMs.ps1 did not return expected VM '$expectedVm' for '$($pair.Key):$($pair.Value)'."
        }
    }

    Write-Host 'Category and VM integration checks passed.' -ForegroundColor Green
}
finally {
    Write-Host 'Cleaning up test VMs and categories...'

    foreach ($vmName in $vmNames) {
        try {
            $vm = Get-PCV4VmByName -PCUrl $pcUrl -Headers $headers -Name $vmName
            for ($attempt = 0; $attempt -lt 6 -and -not $vm; $attempt++) {
                Start-Sleep -Seconds 5
                $vm = Get-PCV4VmByName -PCUrl $pcUrl -Headers $headers -Name $vmName
            }
            $vmExtId = $null
            if ($vm) { $vmExtId = $vm.extId }
            elseif ($vmExtIds.ContainsKey($vmName)) { $vmExtId = $vmExtIds[$vmName] }

            if ($vmExtId) {
                $null = Invoke-PCV4Request -Uri "$vmDeleteUrl/$vmExtId" -Headers $headers -Method Delete
                $isDeleted = $false
                for ($attempt = 0; $attempt -lt 24 -and -not $isDeleted; $attempt++) {
                    Start-Sleep -Seconds 5
                    $remainingVm = Get-PCV4VmByName -PCUrl $pcUrl -Headers $headers -Name $vmName
                    $isDeleted = -not $remainingVm
                }
                if (-not $isDeleted) {
                    throw "VM deletion was accepted, but '$vmName' remains visible in Prism Central."
                }
                Write-Host "Deleted test VM '$vmName'."
            }
        } catch {
            $cleanupErrors.Add("VM '$vmName': $($_.Exception.Message)")
            Write-Warning "Could not delete test VM '$vmName': $($_.Exception.Message)"
        }
    }

    if ($mayCleanupCategories) {
        foreach ($pair in $pairs) {
            try {
                $category = Get-PCV4Category -PCUrl $pcUrl -Headers $headers -Key $pair.Key -Value $pair.Value
                if ($category) {
                    $null = Invoke-PCV4Request -Uri "$categoryCollectionUrl/$($category.extId)" -Headers $headers -Method Delete
                    $isDeleted = $false
                    for ($attempt = 0; $attempt -lt 12 -and -not $isDeleted; $attempt++) {
                        Start-Sleep -Seconds 5
                        $remainingCategory = Get-PCV4Category -PCUrl $pcUrl -Headers $headers -Key $pair.Key -Value $pair.Value
                        $isDeleted = -not $remainingCategory
                    }
                    if (-not $isDeleted) {
                        throw "Category deletion was accepted, but '$($pair.Key):$($pair.Value)' remains visible in Prism Central."
                    }
                    Write-Host "Deleted test category '$($pair.Key):$($pair.Value)'."
                }
            } catch {
                $cleanupErrors.Add("Category '$($pair.Key):$($pair.Value)': $($_.Exception.Message)")
                Write-Warning "Could not delete test category '$($pair.Key):$($pair.Value)': $($_.Exception.Message)"
            }
        }
    }

    if ($testInputFile -and (Test-Path -LiteralPath $testInputFile)) {
        Remove-Item -LiteralPath $testInputFile -Force
    }

    if ($cleanupErrors.Count -gt 0) {
        Write-Warning "Cleanup completed with $($cleanupErrors.Count) error(s). Review the warnings above."
    }
}
