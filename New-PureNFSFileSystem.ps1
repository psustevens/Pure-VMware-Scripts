<#
.SYNOPSIS
    Creates a new NFS file system on an Everpure FlashArray with associated policy objects.

.DESCRIPTION
    This script creates a new NFS file system on an Everpure FlashArray with associated
    NFS export, quota, snapshot, and autodir policies. It does NOT mount the filesystem
    to vCenter - use New-PureNFSDatastore.ps1 for that.

    The credentials for logging into the FlashArray are stored in an XML file.
    You will need to create the XML file outside of this PowerShell script.

    Here is a quick way to create the credentials XML file:
    $FlashArrayCreds = Get-Credential
    $FlashArrayCreds | Export-CliXml -Path "$HOME/Documents/creds/FA-creds.xml"

.PARAMETER FileSystemName
    (Required, String) Name of the NFS file system to create on the FlashArray.
    This will also be used as the prefix for all associated policy names.

    Examples: "NFS-DS-01", "VMware-Prod-NFS", "Test-FS-100GB"

.PARAMETER FileSystemSize
    (Required, String) Size of the file system using format: <number><unit>
    where unit is KB, MB, GB, TB, or PB.
    This size is used to set the quota limit if quota is enabled.

    Valid formats: 100GB, 16TB, 5000GB, 2PB
    Examples: "10TB", "500GB", "2TB"

.PARAMETER FlashArrayEndpoint
    (Required, String) FQDN or IP address of the Everpure FlashArray management interface.
    This is the management endpoint, not the data VIF.

    Examples: "array.domain.com", "sn1-x90r2-f07-27.fsa.lab", "10.1.1.100"

.PARAMETER NFSVersion
    (Optional, String) NFS protocol version to use for the export.

    Valid values:
      - 'nfsv3' = NFS version 3 (default, most compatible)
      - 'nfsv4' = NFS version 4.1 (newer, supports multipathing with nconnect)

    Default: nfsv3

.PARAMETER QuotaEnabled
    (Optional, Boolean) Enable or disable quota policy enforcement on the file system.
    When enabled, the file system will be limited to the size specified in FileSystemSize.

    Valid values: $true or $false
    Default: $true

.PARAMETER SnapshotEnabled
    (Optional, Boolean) Enable or disable automatic snapshot policy.
    When enabled, snapshots will be taken at the interval specified by SnapshotRulesEvery
    and retained for the duration specified by SnapshotRulesKeepFor.

    Valid values: $true or $false
    Default: $true

.PARAMETER SnapshotRulesEvery
    (Optional, Int64) Snapshot interval in milliseconds.
    Controls how frequently snapshots are automatically taken.

    Type: Int64 (64-bit integer)
    Range: 300000 to 31536000000 (5 minutes to 1 year)
    Default: 86400000 (1 day = 24 hours)

    Common values:
      - 5 minutes  = 300000
      - 1 hour     = 3600000
      - 6 hours    = 21600000
      - 1 day      = 86400000 (default)
      - 7 days     = 604800000
      - 30 days    = 2592000000

.PARAMETER SnapshotRulesKeepFor
    (Optional, Int64) Snapshot retention duration in milliseconds.
    Controls how long snapshots are kept before being automatically deleted.

    Type: Int64 (64-bit integer)
    Range: 300000 to 157680000000 (5 minutes to 5 years)
    Default: 604800000 (7 days = 168 hours)

    Common values:
      - 1 day      = 86400000
      - 7 days     = 604800000 (default)
      - 30 days    = 2592000000
      - 90 days    = 7776000000
      - 1 year     = 31536000000

.PARAMETER SnapshotName
    (Optional, String) Client name used in snapshot naming convention.
    This name is used as a prefix or identifier for snapshots created by this policy.
    Should describe the snapshot frequency or purpose.

    Type: String
    Default: 'daily'
    Examples: "hourly", "daily", "weekly", "monthly", "production"

.PARAMETER FlashArrayCredsPath
    (Optional, String) Full path to the FlashArray credentials XML file.
    This file should contain a PSCredential object exported using Export-CliXml.
    The file is encrypted and can only be read by the same user on the same computer.

    Type: String (file path)
    Default: "$HOME/Documents/creds/FA-creds.xml"

    To create credentials file, run: .\Setup-Credentials.ps1
    Or manually: Get-Credential | Export-CliXml -Path "<path>"

.EXAMPLE
    .\New-PureNFSFileSystem.ps1 -FileSystemName "NFS-FS-01" -FileSystemSize 10TB -NFSVersion nfsv3 -FlashArrayEndpoint "sn1-x90r2-f07-27.fsa.lab"

.EXAMPLE
    .\New-PureNFSFileSystem.ps1 -FileSystemName "NFS-FS-02" -FileSystemSize 100GB -NFSVersion nfsv4 -FlashArrayEndpoint "sn1-x90r2-f07-27.fsa.lab"

.EXAMPLE
    .\New-PureNFSFileSystem.ps1 -FileSystemName "NFS-FS-03" -FileSystemSize 2TB -NFSVersion nfsv3 -FlashArrayEndpoint "sn1-x90r2-f07-27.fsa.lab" -SnapshotRulesEvery 3600000 -SnapshotRulesKeepFor 86400000 -SnapshotName "hourly"

.NOTES

    Common Snapshot Time Values (in milliseconds):
    - 5 minutes   = 300000
    - 15 minutes  = 900000
    - 30 minutes  = 1800000
    - 1 hour      = 3600000
    - 6 hours     = 21600000
    - 12 hours    = 43200000
    - 1 day       = 86400000
    - 7 days      = 604800000
    - 30 days     = 2592000000
    - 1 year      = 31536000000

    Author: David Stevens - Everpure
    Requires: PureStoragePowerShellSDK2
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$FileSystemName,
    
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^\d+[KMGTP]B$')]
    [string]$FileSystemSize,

    [Parameter(Mandatory=$true)]
    [string]$FlashArrayEndpoint,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('nfsv3','nfsv4')]
    [string]$NFSVersion = 'nfsv3',
    
    [Parameter(Mandatory=$false)]
    [bool]$QuotaEnabled = $true,

    [Parameter(Mandatory=$false)]
    [bool]$SnapshotEnabled = $true,

    [Parameter(Mandatory=$false)]
    [ValidateRange(300000, 31536000000)]
    [int64]$SnapshotRulesEvery = 86400000,

    [Parameter(Mandatory=$false)]
    [ValidateRange(300000, 157680000000)]
    [int64]$SnapshotRulesKeepFor = 604800000,

    [Parameter(Mandatory=$false)]
    [string]$SnapshotName = 'daily',

    [Parameter(Mandatory=$false)]
    [string]$FlashArrayCredsPath = "$HOME/Documents/creds/FA-creds.xml"
)

# ==============================================================================
# 1. LOAD MODULES AND VALIDATE
# ==============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Everpure NFS File System Creation Script" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Import required module
try {
    Import-Module PureStoragePowerShellSDK2 -ErrorAction Stop
    Write-Host "[OK] Module loaded successfully" -ForegroundColor Green
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[ERROR] Failed to load required module: $ErrorMsg" -ForegroundColor Red
    exit 1
}

# Convert size to bytes for quota
$SizeInBytes = switch -Regex ($FileSystemSize) {
    '(\d+)KB$' { [int64]$matches[1] * 1KB }
    '(\d+)MB$' { [int64]$matches[1] * 1MB }
    '(\d+)GB$' { [int64]$matches[1] * 1GB }
    '(\d+)TB$' { [int64]$matches[1] * 1TB }
    '(\d+)PB$' { [int64]$matches[1] * 1PB }
}

Write-Host "[INFO] File System Name: $FileSystemName" -ForegroundColor Yellow
Write-Host "[INFO] File System Size: $FileSystemSize ($SizeInBytes bytes)" -ForegroundColor Yellow
Write-Host "[INFO] NFS Version: $NFSVersion" -ForegroundColor Yellow

# ==============================================================================
# 2. CONNECT TO FLASHARRAY
# ==============================================================================

Write-Host "`n[STEP 1] Connecting to FlashArray..." -ForegroundColor Cyan

try {
    $FlashArrayCreds = Import-CliXml -Path $FlashArrayCredsPath -ErrorAction Stop
    $FlashArray = Connect-Pfa2Array -EndPoint $FlashArrayEndpoint `
        -Credential $FlashArrayCreds `
        -IgnoreCertificateError `
        -ErrorAction Stop
    Write-Host "[OK] Connected to FlashArray: $FlashArrayEndpoint" -ForegroundColor Green
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[ERROR] Failed to connect to FlashArray: $ErrorMsg" -ForegroundColor Red
    exit 1
}

# ==============================================================================
# 3. CREATE FILE SYSTEM ON FLASHARRAY
# ==============================================================================

Write-Host "`n[STEP 2] Creating NFS file system on FlashArray..." -ForegroundColor Cyan

try {
    # Create the file system
    $FileSystem = New-Pfa2FileSystem -Array $FlashArray -Name $FileSystemName -ErrorAction Stop
    Write-Host "[OK] File system created: $($FileSystem.Name)" -ForegroundColor Green

    # Get the root managed directory
    $RootManagedDirectory = Get-Pfa2Directory -Array $FlashArray -FileSystemName $FileSystem.Name -ErrorAction Stop
    Write-Host "[OK] Managed directory: $($RootManagedDirectory.Name)" -ForegroundColor Green
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[ERROR] Failed to create file system: $ErrorMsg" -ForegroundColor Red
    Disconnect-Pfa2Array -Array $FlashArray
    exit 1
}

# ==============================================================================
# 4. CREATE AND ASSIGN NFS EXPORT POLICY
# ==============================================================================

Write-Host "`n[STEP 3] Creating NFS export policy..." -ForegroundColor Cyan

try {
    # Create NFS export policy
    New-Pfa2PolicyNfs -Array $FlashArray `
        -Name "$($FileSystemName)-export-policy" `
        -UserMappingEnabled $false `
        -Enabled $true `
        -ErrorAction Stop | Out-Null

    # Add client rule with no-root-squash for all clients
    New-Pfa2PolicyNfsClientRule -Array $FlashArray `
        -PolicyName "$($FileSystemName)-export-policy" `
        -RulesClient '*' `
        -RulesAccess 'no-root-squash' `
        -RulesPermission 'rw' `
        -RulesNfsVersion $NFSVersion `
        -ErrorAction Stop | Out-Null

    # Assign NFS export policy to the file system
    New-Pfa2DirectoryPolicyNfs -Array $FlashArray `
        -MemberName $RootManagedDirectory.Name `
        -PolicyName "$($FileSystemName)-export-policy" `
        -PoliciesExportName "$($FileSystemName)" `
        -ErrorAction Stop | Out-Null

    Write-Host "[OK] NFS export policy created and assigned" -ForegroundColor Green
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[ERROR] Failed to create NFS export policy: $ErrorMsg" -ForegroundColor Red
    Disconnect-Pfa2Array -Array $FlashArray
    exit 1
}

# ==============================================================================
# 5. CREATE AND ASSIGN QUOTA POLICY (OPTIONAL)
# ==============================================================================

if ($QuotaEnabled) {
    Write-Host "`n[STEP 4] Creating quota policy..." -ForegroundColor Cyan

    try {
        # Create quota policy
        New-Pfa2PolicyQuota -Array $FlashArray `
            -Name "$($FileSystemName)-quota-policy" `
            -Enabled $true `
            -ErrorAction Stop | Out-Null

        # Add quota rule
        New-Pfa2PolicyQuotaRule -Array $FlashArray `
            -PolicyName "$($FileSystemName)-quota-policy" `
            -RulesQuotaLimit $SizeInBytes `
            -RulesEnforced $true `
            -ErrorAction Stop | Out-Null

        # Assign quota policy to the file system
        New-Pfa2DirectoryPolicyQuota -Array $FlashArray `
            -MemberName $RootManagedDirectory.Name `
            -PolicyName "$($FileSystemName)-quota-policy" `
            -ErrorAction Stop | Out-Null

        Write-Host "[OK] Quota policy created and assigned ($FileSystemSize)" -ForegroundColor Green
    } catch {
        $ErrorMsg = $_.Exception.Message
        Write-Host "[WARNING] Failed to create quota policy: $ErrorMsg" -ForegroundColor Yellow
    }
}

# ==============================================================================
# 6. CREATE AND ASSIGN SNAPSHOT POLICY (OPTIONAL)
# ==============================================================================

if ($SnapshotEnabled) {
    Write-Host "`n[STEP 5] Creating snapshot policy..." -ForegroundColor Cyan

    # Calculate human-readable time values
    $EveryHours = [math]::Round($SnapshotRulesEvery / 3600000, 2)
    $EveryDays = [math]::Round($SnapshotRulesEvery / 86400000, 2)
    $KeepForHours = [math]::Round($SnapshotRulesKeepFor / 3600000, 2)
    $KeepForDays = [math]::Round($SnapshotRulesKeepFor / 86400000, 2)

    try {
        # Create snapshot policy
        New-Pfa2PolicySnapshot -Array $FlashArray `
            -Name "$($FileSystemName)-snapshot-policy" `
            -Enabled $true `
            -ErrorAction Stop | Out-Null

        # Add snapshot rule with user-specified parameters
        New-Pfa2PolicySnapshotRule -Array $FlashArray `
            -PolicyName "$($FileSystemName)-snapshot-policy" `
            -RulesClientName $SnapshotName `
            -RulesEvery $SnapshotRulesEvery `
            -RulesKeepFor $SnapshotRulesKeepFor `
            -ErrorAction Stop | Out-Null

        # Assign snapshot policy to the file system
        New-Pfa2DirectoryPolicySnapshot -Array $FlashArray `
            -MemberName $RootManagedDirectory.Name `
            -PolicyName "$($FileSystemName)-snapshot-policy" `
            -ErrorAction Stop | Out-Null

        # Display human-readable snapshot schedule
        if ($EveryDays -ge 1) {
            $EveryText = "$EveryDays days"
        } else {
            $EveryText = "$EveryHours hours"
        }

        if ($KeepForDays -ge 1) {
            $KeepForText = "$KeepForDays days"
        } else {
            $KeepForText = "$KeepForHours hours"
        }

        Write-Host "[OK] Snapshot policy created and assigned" -ForegroundColor Green
        Write-Host "    Snapshot Name: $SnapshotName" -ForegroundColor Gray
        Write-Host "       Interval: Every $EveryText" -ForegroundColor Gray
        Write-Host "      Retention: $KeepForText" -ForegroundColor Gray
    } catch {
        $ErrorMsg = $_.Exception.Message
        Write-Host "[WARNING] Failed to create snapshot policy: $ErrorMsg" -ForegroundColor Yellow
    }
}

# ==============================================================================
# 7. CREATE AND ASSIGN AUTODIR POLICY
# ==============================================================================

Write-Host "`n[STEP 6] Creating autodir policy..." -ForegroundColor Cyan

try {
    # Create autodir policy
    New-Pfa2PolicyAutodir -Array $FlashArray `
        -Name "$($FileSystemName)-autodir-policy" `
        -Enabled $true `
        -ErrorAction Stop | Out-Null

    # Assign autodir policy to the file system
    New-Pfa2DirectoryPolicyAutodir -Array $FlashArray `
        -MemberName $RootManagedDirectory.Name `
        -PolicyName "$($FileSystemName)-autodir-policy" `
        -ErrorAction Stop | Out-Null

    Write-Host "[OK] Autodir policy created and assigned" -ForegroundColor Green
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[WARNING] Failed to create autodir policy: $ErrorMsg" -ForegroundColor Yellow
}

# ==============================================================================
# 8. GET NFS EXPORT PATH
# ==============================================================================

Write-Host "`n[STEP 7] Retrieving NFS export path..." -ForegroundColor Cyan

try {
    $NFSExport = Get-Pfa2DirectoryExport -Array $FlashArray `
        -DirectoryName $RootManagedDirectory.Name `
        -ErrorAction Stop

    # Get the actual export path from the FlashArray
    # For NFS 3, use the export name; for NFS 4.1, use the full path
    if ($NFSVersion -eq 'nfsv4') {
        # NFS 4.1 requires the full path from the FlashArray
        $NFSExportPath = $NFSExport.Path
        if (-not $NFSExportPath) {
            # Fallback to constructed path
            $NFSExportPath = "/$($FileSystemName)"
        }
    } else {
        # NFS 3 uses the export name
        $NFSExportPath = "/$($FileSystemName)"
    }

    Write-Host "[OK] NFS export path: $NFSExportPath" -ForegroundColor Green
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[ERROR] Failed to retrieve NFS export path: $ErrorMsg" -ForegroundColor Red
    Disconnect-Pfa2Array -Array $FlashArray
    exit 1
}

# ==============================================================================
# 9. CLEANUP AND SUMMARY
# ==============================================================================

Write-Host "`n[STEP 8] Disconnecting from FlashArray..." -ForegroundColor Cyan
Disconnect-Pfa2Array -Array $FlashArray
Write-Host "[OK] Disconnected from FlashArray" -ForegroundColor Green

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "FILE SYSTEM CREATION COMPLETE" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "[SUMMARY]" -ForegroundColor Green
Write-Host "  File System Name: $FileSystemName" -ForegroundColor Gray
Write-Host "  File System Size: $FileSystemSize" -ForegroundColor Gray
Write-Host "  NFS Version: $NFSVersion" -ForegroundColor Gray
Write-Host "  NFS Export Path: $NFSExportPath" -ForegroundColor Gray
Write-Host "  FlashArray: $FlashArrayEndpoint" -ForegroundColor Gray
Write-Host "`n[NEXT STEPS]" -ForegroundColor Yellow
Write-Host "  To mount this filesystem to vCenter, use:" -ForegroundColor Gray
Write-Host "    .\\New-PureNFSDatastore.ps1 -DatastoreName '$FileSystemName' -NFSExportPath '$NFSExportPath' -NFSHost '<NFS_VIF_IP>' -vCenterCluster '<cluster>' -vCenterServer '<vcenter>'" -ForegroundColor Gray
Write-Host ""

