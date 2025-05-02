# Azure Resource Cleanup Script
# Author: johnlu1976
# Website: https://www.sysosx.com
# Description: This script identifies and optionally removes orphaned resources to save costs.
# Usage: Set $DeleteResources to $true to actually delete resources, otherwise it will just report them.

param(
    [int]$SnapshotRetentionDays = 3,
    [switch]$DeleteResources = $false,
    [switch]$IncludeStorageSnapshots = $true
)

# Connect to Azure if not already connected
$context = Get-AzContext
if (!$context) {
    Connect-AzAccount
}

# Important warning before proceeding
Write-Host "===================================================================================" -ForegroundColor Yellow
Write-Host "IMPORTANT: This script will identify orphaned resources across your Azure subscription." -ForegroundColor Yellow
if ($DeleteResources) {
    Write-Host "WARNING: DeleteResources is set to TRUE - identified resources WILL BE DELETED!" -ForegroundColor Red
} else {
    Write-Host "DeleteResources is set to FALSE - resources will be identified but NOT deleted." -ForegroundColor Green
    Write-Host "This is a safe preview mode. Review results before running with -DeleteResources switch." -ForegroundColor Green
}

if ($IncludeStorageSnapshots) {
    Write-Host "Storage account snapshots (blobs AND file shares) will be checked." -ForegroundColor Cyan
    Write-Host "This may take time for large storage accounts with many snapshots." -ForegroundColor Cyan
} else {
    Write-Host "Storage account snapshots will NOT be checked (use -IncludeStorageSnapshots to check them)." -ForegroundColor Cyan
}
Write-Host "===================================================================================" -ForegroundColor Yellow
Write-Host ""

# Get current date for age calculations
$currentDate = Get-Date

# Create a report folder with timestamp
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportFolder = "AzureCleanupReport-$timestamp"
New-Item -ItemType Directory -Path $reportFolder -Force | Out-Null
$logFile = Join-Path $reportFolder "cleanup_log.txt"

function Write-Log {
    param([string]$message)
    
    Write-Host $message
    Add-Content -Path $logFile -Value $message
}

Write-Log "Azure Resource Cleanup Report - Generated on $(Get-Date)"
Write-Log "==================================================================================="

# 1. Find orphaned NICs (not attached to any VM or other resource)
Write-Log "`n=== Finding orphaned NICs ==="
$orphanedNics = Get-AzNetworkInterface | Where-Object { $null -eq $_.VirtualMachine -and $null -eq $_.PrivateEndpoint }

if ($orphanedNics.Count -eq 0) {
    Write-Log "No orphaned NICs found."
} else {
    Write-Log "Found $($orphanedNics.Count) orphaned NICs:"
    $orphanedNics | ForEach-Object {
        $nicDetails = "- NIC: $($_.Name) | Resource Group: $($_.ResourceGroupName) | Location: $($_.Location)"
        Write-Log $nicDetails
        
        if ($DeleteResources) {
            try {
                $_ | Remove-AzNetworkInterface -Force
                Write-Log "  DELETED: $($_.Name)"
            } catch {
                Write-Log "  ERROR deleting NIC $($_.Name): $_"
            }
        }
    }
    $orphanedNics | Export-Csv -Path (Join-Path $reportFolder "orphaned_nics.csv") -NoTypeInformation
}

# 2. Find old managed disk snapshots
Write-Log "`n=== Finding managed disk snapshots older than $SnapshotRetentionDays days ==="
$oldManagedSnapshots = Get-AzSnapshot | Where-Object { $_.TimeCreated -lt $currentDate.AddDays(-$SnapshotRetentionDays) }

if ($oldManagedSnapshots.Count -eq 0) {
    Write-Log "No managed disk snapshots older than $SnapshotRetentionDays days found."
} else {
    Write-Log "Found $($oldManagedSnapshots.Count) managed disk snapshots older than $SnapshotRetentionDays days:"
    $oldManagedSnapshots | ForEach-Object {
        $age = [math]::Round(($currentDate - $_.TimeCreated).TotalDays, 1)
        $snapshotDetails = "- Managed Snapshot: $($_.Name) | Resource Group: $($_.ResourceGroupName) | Age: $age days | Created: $($_.TimeCreated)"
        Write-Log $snapshotDetails
        
        if ($DeleteResources) {
            try {
                $_ | Remove-AzSnapshot -Force
                Write-Log "  DELETED: $($_.Name)"
            } catch {
                Write-Log "  ERROR deleting managed snapshot $($_.Name): $_"
            }
        }
    }
    $oldManagedSnapshots | Select-Object Name, ResourceGroupName, Location, TimeCreated, DiskSizeGB | 
        Export-Csv -Path (Join-Path $reportFolder "old_managed_snapshots.csv") -NoTypeInformation
}

# 2b. Find old storage account blob and file share snapshots
if ($IncludeStorageSnapshots) {
    Write-Log "`n=== Finding storage account snapshots older than $SnapshotRetentionDays days ==="
    
    # Get all storage accounts
    $storageAccounts = Get-AzStorageAccount
    $oldBlobSnapshots = @()
    $oldFileShareSnapshots = @()
    $blobSnapshotCount = 0
    $fileShareSnapshotCount = 0
    $deletedBlobSnapshotCount = 0
    $deletedFileShareSnapshotCount = 0
    
    foreach ($storageAccount in $storageAccounts) {
        Write-Host "Checking storage account: $($storageAccount.StorageAccountName)..." -ForegroundColor Cyan
        $storageKey = (Get-AzStorageAccountKey -ResourceGroupName $storageAccount.ResourceGroupName -Name $storageAccount.StorageAccountName)[0].Value
        $context = New-AzStorageContext -StorageAccountName $storageAccount.StorageAccountName -StorageAccountKey $storageKey
        
        # 1. Check blob containers
        Write-Host "  Checking blob containers..." -ForegroundColor Gray
        $containers = Get-AzStorageContainer -Context $context -ErrorAction SilentlyContinue
        
        if ($containers) {
            foreach ($container in $containers) {
                # Get all blobs including snapshots
                $blobs = Get-AzStorageBlob -Container $container.Name -Context $context -IncludeSnapshot
                
                # Filter to get only snapshots older than specified days
                $oldSnapshots = $blobs | Where-Object { 
                    $_.IsSnapshot -eq $true -and $_.SnapshotTime -lt $currentDate.AddDays(-$SnapshotRetentionDays) 
                }
                
                foreach ($snapshot in $oldSnapshots) {
                    $age = [math]::Round(($currentDate - $snapshot.SnapshotTime).TotalDays, 1)
                    $snapshotObj = [PSCustomObject]@{
                        StorageAccount = $storageAccount.StorageAccountName
                        ResourceGroup = $storageAccount.ResourceGroupName
                        Container = $container.Name
                        BlobName = $snapshot.Name
                        SnapshotTime = $snapshot.SnapshotTime
                        Age = $age
                    }
                    $oldBlobSnapshots += $snapshotObj
                    $blobSnapshotCount++
                    
                    $snapshotDetails = "- Blob Snapshot: $($snapshot.Name) | Container: $($container.Name) | Storage Account: $($storageAccount.StorageAccountName) | Age: $age days"
                    Write-Log $snapshotDetails
                    
                    if ($DeleteResources) {
                        try {
                            # Use specific snapshot removal
                            Remove-AzStorageBlob -Blob $snapshot.Name -Container $container.Name -Context $context -SnapshotTime $snapshot.SnapshotTime -Force
                            Write-Log "  DELETED: Blob snapshot $($snapshot.Name) from $($snapshot.SnapshotTime)"
                            $deletedBlobSnapshotCount++
                        } catch {
                            Write-Log "  ERROR deleting blob snapshot $($snapshot.Name): $_"
                        }
                    }
                }
            }
        }
        
        # 2. Check file shares
        Write-Host "  Checking file shares..." -ForegroundColor Gray
        try {
            $fileShares = Get-AzStorageShare -Context $context -IncludeSnapshot -ErrorAction SilentlyContinue
            
            if ($fileShares) {
                # Filter to get only snapshots older than specified days
                $oldShareSnapshots = $fileShares | Where-Object { 
                    $_.IsSnapshot -eq $true -and $_.SnapshotTime -lt $currentDate.AddDays(-$SnapshotRetentionDays) 
                }
                
                foreach ($shareSnapshot in $oldShareSnapshots) {
                    $age = [math]::Round(($currentDate - $shareSnapshot.SnapshotTime).TotalDays, 1)
                    $shareSnapshotObj = [PSCustomObject]@{
                        StorageAccount = $storageAccount.StorageAccountName
                        ResourceGroup = $storageAccount.ResourceGroupName
                        ShareName = $shareSnapshot.Name
                        SnapshotTime = $shareSnapshot.SnapshotTime
                        Age = $age
                    }
                    $oldFileShareSnapshots += $shareSnapshotObj
                    $fileShareSnapshotCount++
                    
                    $shareSnapshotDetails = "- File Share Snapshot: $($shareSnapshot.Name) | Storage Account: $($storageAccount.StorageAccountName) | Age: $age days"
                    Write-Log $shareSnapshotDetails
                    
                    if ($DeleteResources) {
                        try {
                            # Remove file share snapshot
                            Remove-AzStorageShare -Share $shareSnapshot.Name -Context $context -SnapshotTime $shareSnapshot.SnapshotTime -Force
                            Write-Log "  DELETED: File share snapshot $($shareSnapshot.Name) from $($shareSnapshot.SnapshotTime)"
                            $deletedFileShareSnapshotCount++
                        } catch {
                            Write-Log "  ERROR deleting file share snapshot $($shareSnapshot.Name): $_"
                        }
                    }
                }
            }
        } catch {
            Write-Log "  ERROR accessing file shares in storage account $($storageAccount.StorageAccountName): $_"
        }
    }
    
    # Report summary for blob snapshots
    if ($blobSnapshotCount -eq 0) {
        Write-Log "No storage account blob snapshots older than $SnapshotRetentionDays days found."
    } else {
        Write-Log "Found $blobSnapshotCount storage account blob snapshots older than $SnapshotRetentionDays days."
        if ($DeleteResources) {
            Write-Log "Deleted $deletedBlobSnapshotCount storage account blob snapshots."
        }
        $oldBlobSnapshots | Export-Csv -Path (Join-Path $reportFolder "old_blob_snapshots.csv") -NoTypeInformation
    }
    
    # Report summary for file share snapshots
    if ($fileShareSnapshotCount -eq 0) {
        Write-Log "No file share snapshots older than $SnapshotRetentionDays days found."
    } else {
        Write-Log "Found $fileShareSnapshotCount file share snapshots older than $SnapshotRetentionDays days."
        if ($DeleteResources) {
            Write-Log "Deleted $deletedFileShareSnapshotCount file share snapshots."
        }
        $oldFileShareSnapshots | Export-Csv -Path (Join-Path $reportFolder "old_fileshare_snapshots.csv") -NoTypeInformation
    }
}

# 3. Find orphaned managed disks
Write-Log "`n=== Finding orphaned managed disks ==="
$orphanedDisks = Get-AzDisk | Where-Object { $_.ManagedBy -eq $null }

if ($orphanedDisks.Count -eq 0) {
    Write-Log "No orphaned managed disks found."
} else {
    Write-Log "Found $($orphanedDisks.Count) orphaned managed disks:"
    $orphanedDisks | ForEach-Object {
        $diskDetails = "- Disk: $($_.Name) | Resource Group: $($_.ResourceGroupName) | Size: $($_.DiskSizeGB) GB | Type: $($_.Sku.Name)"
        Write-Log $diskDetails
        
        if ($DeleteResources) {
            try {
                $_ | Remove-AzDisk -Force
                Write-Log "  DELETED: $($_.Name)"
            } catch {
                Write-Log "  ERROR deleting disk $($_.Name): $_"
            }
        }
    }
    $orphanedDisks | Select-Object Name, ResourceGroupName, Location, DiskSizeGB, Sku, TimeCreated | 
        Export-Csv -Path (Join-Path $reportFolder "orphaned_disks.csv") -NoTypeInformation
}

# 4. Find orphaned public IPs
Write-Log "`n=== Finding orphaned public IPs ==="
$orphanedPublicIPs = Get-AzPublicIpAddress | Where-Object { $_.IpConfiguration -eq $null -and $_.NatGateway -eq $null -and $_.LoadBalancerFrontendIpConfiguration -eq $null }

if ($orphanedPublicIPs.Count -eq 0) {
    Write-Log "No orphaned public IPs found."
} else {
    Write-Log "Found $($orphanedPublicIPs.Count) orphaned public IPs:"
    $orphanedPublicIPs | ForEach-Object {
        $ipDetails = "- Public IP: $($_.Name) | Resource Group: $($_.ResourceGroupName) | IP: $($_.IpAddress) | SKU: $($_.Sku.Name)"
        Write-Log $ipDetails
        
        if ($DeleteResources) {
            try {
                $_ | Remove-AzPublicIpAddress -Force
                Write-Log "  DELETED: $($_.Name)"
            } catch {
                Write-Log "  ERROR deleting Public IP $($_.Name): $_"
            }
        }
    }
    $orphanedPublicIPs | Select-Object Name, ResourceGroupName, Location, IpAddress, Sku | 
        Export-Csv -Path (Join-Path $reportFolder "orphaned_public_ips.csv") -NoTypeInformation
}

# 5. Find orphaned security groups
Write-Log "`n=== Finding orphaned Network Security Groups ==="
$allNSGs = Get-AzNetworkSecurityGroup
$orphanedNSGs = @()

foreach ($nsg in $allNSGs) {
    # Check if NSG is associated with a subnet or NIC
    if (($nsg.NetworkInterfaces.Count -eq 0) -and ($nsg.Subnets.Count -eq 0)) {
        $orphanedNSGs += $nsg
    }
}

if ($orphanedNSGs.Count -eq 0) {
    Write-Log "No orphaned Network Security Groups found."
} else {
    Write-Log "Found $($orphanedNSGs.Count) orphaned Network Security Groups:"
    $orphanedNSGs | ForEach-Object {
        $nsgDetails = "- NSG: $($_.Name) | Resource Group: $($_.ResourceGroupName)"
        Write-Log $nsgDetails
        
        if ($DeleteResources) {
            try {
                $_ | Remove-AzNetworkSecurityGroup -Force
                Write-Log "  DELETED: $($_.Name)"
            } catch {
                Write-Log "  ERROR deleting NSG $($_.Name): $_"
            }
        }
    }
    $orphanedNSGs | Select-Object Name, ResourceGroupName, Location | 
        Export-Csv -Path (Join-Path $reportFolder "orphaned_nsgs.csv") -NoTypeInformation
}

# 6. Find unused availability sets
Write-Log "`n=== Finding unused Availability Sets ==="
$unusedAvSets = Get-AzAvailabilitySet | Where-Object { $_.VirtualMachinesReferences.Count -eq 0 }

if ($unusedAvSets.Count -eq 0) {
    Write-Log "No unused Availability Sets found."
} else {
    Write-Log "Found $($unusedAvSets.Count) unused Availability Sets:"
    $unusedAvSets | ForEach-Object {
        $avSetDetails = "- Availability Set: $($_.Name) | Resource Group: $($_.ResourceGroupName)"
        Write-Log $avSetDetails
        
        if ($DeleteResources) {
            try {
                $_ | Remove-AzAvailabilitySet -Force
                Write-Log "  DELETED: $($_.Name)"
            } catch {
                Write-Log "  ERROR deleting Availability Set $($_.Name): $_"
            }
        }
    }
    $unusedAvSets | Select-Object Name, ResourceGroupName, Location | 
        Export-Csv -Path (Join-Path $reportFolder "unused_availability_sets.csv") -NoTypeInformation
}

# 7. Find empty resource groups
Write-Log "`n=== Finding empty Resource Groups ==="
$allResourceGroups = Get-AzResourceGroup
$emptyResourceGroups = @()

foreach ($rg in $allResourceGroups) {
    $resources = Get-AzResource -ResourceGroupName $rg.ResourceGroupName
    if ($resources.Count -eq 0) {
        $emptyResourceGroups += $rg
    }
}

if ($emptyResourceGroups.Count -eq 0) {
    Write-Log "No empty Resource Groups found."
} else {
    Write-Log "Found $($emptyResourceGroups.Count) empty Resource Groups:"
    $emptyResourceGroups | ForEach-Object {
        $rgDetails = "- Resource Group: $($_.ResourceGroupName) | Location: $($_.Location)"
        Write-Log $rgDetails
        
        if ($DeleteResources) {
            try {
                $_ | Remove-AzResourceGroup -Force
                Write-Log "  DELETED: $($_.ResourceGroupName)"
            } catch {
                Write-Log "  ERROR deleting Resource Group $($_.ResourceGroupName): $_"
            }
        }
    }
    $emptyResourceGroups | Select-Object ResourceGroupName, Location | 
        Export-Csv -Path (Join-Path $reportFolder "empty_resource_groups.csv") -NoTypeInformation
}

# 8. Find unused Azure Virtual Networks
Write-Log "`n=== Finding potentially unused Virtual Networks ==="
$allVNets = Get-AzVirtualNetwork
$unusedVNets = @()

foreach ($vnet in $allVNets) {
    $hasSubnets = $false
    foreach ($subnet in $vnet.Subnets) {
        if ($subnet.IpConfigurations.Count -gt 0) {
            $hasSubnets = $true
            break
        }
    }
    
    if (!$hasSubnets) {
        $unusedVNets += $vnet
    }
}

if ($unusedVNets.Count -eq 0) {
    Write-Log "No potentially unused Virtual Networks found."
} else {
    Write-Log "Found $($unusedVNets.Count) potentially unused Virtual Networks:"
    $unusedVNets | ForEach-Object {
        $vnetDetails = "- VNet: $($_.Name) | Resource Group: $($_.ResourceGroupName) | Address Space: $($_.AddressSpace.AddressPrefixes -join ', ')"
        Write-Log $vnetDetails
        
        # NOTE: Only reporting these, not deleting automatically as they could be planned for future use
        if ($DeleteResources) {
            Write-Log "  WARNING: Virtual Networks might be planned for future use. Review before manual deletion."
        }
    }
    $unusedVNets | Select-Object Name, ResourceGroupName, Location | 
        Export-Csv -Path (Join-Path $reportFolder "unused_vnets.csv") -NoTypeInformation
}

# 9. Find reserved but unused IP addresses
Write-Log "`n=== Finding reserved but unused private IPs ==="
$allVNets = Get-AzVirtualNetwork

$unusedPrivateIPs = @()
foreach ($vnet in $allVNets) {
    foreach ($subnet in $vnet.Subnets) {
        # Check if there are any IP configurations (used addresses)
        if ($subnet.IpConfigurations.Count -gt 0) {
            $subnetDetails = @{
                VNetName = $vnet.Name
                SubnetName = $subnet.Name
                AddressPrefix = $subnet.AddressPrefix
                UsedIPCount = $subnet.IpConfigurations.Count
            }
            $unusedPrivateIPs += New-Object PSObject -Property $subnetDetails
        }
    }
}

if ($unusedPrivateIPs.Count -eq 0) {
    Write-Log "No subnets with reserved IP addresses found."
} else {
    Write-Log "Found $($unusedPrivateIPs.Count) subnets with reserved IP addresses:"
    $unusedPrivateIPs | ForEach-Object {
        Write-Log "- VNet: $($_.VNetName) | Subnet: $($_.SubnetName) | Address Space: $($_.AddressPrefix) | Used IPs: $($_.UsedIPCount)"
    }
    $unusedPrivateIPs | Select-Object VNetName, SubnetName, AddressPrefix, UsedIPCount | 
        Export-Csv -Path (Join-Path $reportFolder "subnet_ip_usage.csv") -NoTypeInformation
}

# Summarize findings
Write-Log "`n==================================================================================="
Write-Log "SUMMARY OF FINDINGS:"
Write-Log "- Orphaned NICs: $($orphanedNics.Count)"
Write-Log "- Old Managed Disk Snapshots (>$SnapshotRetentionDays days): $($oldManagedSnapshots.Count)"
if ($IncludeStorageSnapshots) {
    Write-Log "- Old Blob Snapshots (>$SnapshotRetentionDays days): $blobSnapshotCount"
    Write-Log "- Old File Share Snapshots (>$SnapshotRetentionDays days): $fileShareSnapshotCount"
}
Write-Log "- Orphaned Managed Disks: $($orphanedDisks.Count)"
Write-Log "- Orphaned Public IPs: $($orphanedPublicIPs.Count)"
Write-Log "- Orphaned Network Security Groups: $($orphanedNSGs.Count)"
Write-Log "- Unused Availability Sets: $($unusedAvSets.Count)"
Write-Log "- Empty Resource Groups: $($emptyResourceGroups.Count)"
Write-Log "- Potentially Unused Virtual Networks: $($unusedVNets.Count)"
Write-Log "==================================================================================="

if ($DeleteResources) {
    Write-Log "`nDELETE MODE was enabled. Resources have been deleted as indicated above."
} else {
    Write-Log "`nThis was a REPORT ONLY run. No resources were deleted."
    Write-Log "To delete the identified resources, run the script with the -DeleteResources switch."
}

Write-Log "`nDetailed reports saved to: $((Get-Item $reportFolder).FullName)"
