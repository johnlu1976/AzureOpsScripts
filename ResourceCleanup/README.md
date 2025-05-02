# Azure Resource Cleanup

A comprehensive PowerShell script for identifying and cleaning up unused Azure resources to optimize cloud spending.

**Author:** [johnlu1976](https://github.com/johnlu1976)  
**Website:** [SysOSX.com](https://www.sysosx.com)

## Overview

The Azure Resource Cleanup tool helps cloud administrators identify and remove orphaned resources that are no longer in use but still incurring costs. This script is designed to be safe, thorough, and flexible, operating first in a non-destructive reporting mode by default.

## Features

This script identifies and can clean up:

- 🖧 **Orphaned NICs** not attached to any VM or endpoint
- 📸 **Old Azure disk snapshots** beyond your retention period
- 📸 **Storage account blob snapshots** beyond your retention period
- 📁 **File share snapshots** beyond your retention period 
- 💽 **Orphaned managed disks** not attached to any VM
- 🌐 **Orphaned public IPs** not associated with any resource
- 🔒 **Orphaned Network Security Groups**
- ⚡ **Unused Availability Sets**
- 📦 **Empty Resource Groups**
- 🔄 **Potentially unused Virtual Networks**
- 🔢 **Reserved but unused IP addresses**

## Requirements

- PowerShell 5.1 or higher
- Az PowerShell module (`Install-Module -Name Az`)
- Azure account with appropriate permissions to view and delete resources

## Usage

### Basic Usage (Report Only)

```powershell
.\Azure-Resource-Cleanup.ps1
```

This will scan your subscription and generate detailed reports of orphaned resources without deleting anything.

### Cleanup Mode

```powershell
.\Azure-Resource-Cleanup.ps1 -DeleteResources
```

This will identify orphaned resources and delete them.

### Customizing Snapshot Retention

```powershell
.\Azure-Resource-Cleanup.ps1 -SnapshotRetentionDays 7 -DeleteResources
```

This will identify and delete snapshots older than 7 days.

### Excluding Storage Account Checks

```powershell
.\Azure-Resource-Cleanup.ps1 -IncludeStorageSnapshots:$false
```

This will skip checking storage account blob and file share snapshots (useful for large environments where this check could be time-consuming).

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `SnapshotRetentionDays` | Integer | `3` | Number of days to keep snapshots. Snapshots older than this will be identified for cleanup. |
| `DeleteResources` | Switch | `$false` | When set to `$true`, the script will delete identified resources. Otherwise, it just reports them. |
| `IncludeStorageSnapshots` | Switch | `$true` | When set to `$true`, the script checks storage account blob and file share snapshots. |

## Report Output

The script creates a timestamped report folder with detailed CSV files for each resource type:

- `orphaned_nics.csv`
- `old_managed_snapshots.csv`
- `old_blob_snapshots.csv`
- `old_fileshare_snapshots.csv`
- `orphaned_disks.csv`
- `orphaned_public_ips.csv`
- `orphaned_nsgs.csv`
- `unused_availability_sets.csv`
- `empty_resource_groups.csv`
- `unused_vnets.csv`
- `subnet_ip_usage.csv`
- `cleanup_log.txt` (full log of the script's actions)

## Best Practices

1. **Always run in report-only mode first** (without `-DeleteResources`) to review what would be deleted
2. **Review the CSV reports** carefully before using deletion mode
3. **Adjust the snapshot retention period** based on your organization's needs
4. **Consider running the script as a scheduled task** to regularly clean up orphaned resources

## Example Workflow

1. Run the script in report mode:
   ```powershell
   .\Azure-Resource-Cleanup.ps1
   ```

2. Review the generated CSV files in the report folder

3. When confident, run in deletion mode:
   ```powershell
   .\Azure-Resource-Cleanup.ps1 -DeleteResources
   ```

## License

MIT License - Feel free to use and modify this script as needed.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Disclaimer

This script deletes Azure resources. Always verify the resources being deleted before using the `-DeleteResources` parameter. The author is not responsible for any data loss or unexpected deletions.