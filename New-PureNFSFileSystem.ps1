<#
.SYNOPSIS
    Creates a new NFS file system on an Everpure FlashArray with associated policy objects.

.DESCRIPTION
    This script creates a new NFS file system on an Everpure FlashArray with associated
    NFS export, quota, snapshot, and autodir policies. It does NOT mount the filesystem
    to vCenter - use New-NFSDatastore.ps1 for that.

    If you don't care to run two separate scripts, you can create the file system and
    mount it to vCenter in one step by running New-PureNFSFileSystem.ps1.  See the help 
    for New-PureNFSFileSystem.ps1 for details.

    The credentials for logging into the FlashArray are stored in an XML file.
    You will need to create the XML file outside of this PowerShell script.

    Here is a quick way to create the credentials XML file:
    $FlashArrayCreds = Get-Credential
    $FlashArrayCreds | Export-CliXml -Path "$HOME/Documents/creds/FA-creds.xml"

.PARAMETER FileSystemName
    (Required) Name of the NFS file system to create on the FlashArray

.PARAMETER FileSystemSize
    (Required) Size of the file system (e.g., 16TB, 5000GB)

.PARAMETER FlashArrayEndpoint
    (Required) FQDN or IP address of the Everpure FlashArray management interface

.PARAMETER NFSVersion
    (Optional) NFS version to use: 'nfsv3' or 'nfsv4' (default: nfsv3)

.PARAMETER QuotaEnabled
    (Optional) Enable quota policy (default: $true)

.PARAMETER SnapshotEnabled
    (Optional)  Enable snapshot policy (default: $true)

.PARAMETER SnapshotRulesEvery
    (Optional) Snapshot interval in milliseconds (default: 86400000 = 1 day, range: 5 min to 1 year)

.PARAMETER SnapshotRulesKeepFor
    (Optional) Snapshot retention in milliseconds (default: 604800000 = 7 days, range: 5 min to 5 years)

.PARAMETER SnapshotName
    (Optional) Snapshot name for naming snapshots (default: 'daily')

.PARAMETER FlashArrayCredsPath
    (Optional) Path to FlashArray credentials XML file (default: $HOME/Documents/creds/FA-creds.xml)

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

# PureStoragePowerShellSDK2 provides all Pfa2* cmdlets used throughout this script
try {
    Import-Module PureStoragePowerShellSDK2 -ErrorAction Stop
    Write-Host "[OK] Module loaded successfully" -ForegroundColor Green
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[ERROR] Failed to load required module: $ErrorMsg" -ForegroundColor Red
    exit 1
}

# The FlashArray quota API requires size in raw bytes; convert the human-readable
# input (e.g., "10TB") by extracting the numeric part and multiplying by the
# appropriate PowerShell unit constant
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
    # Credentials are stored in an encrypted XML file rather than hardcoded to
    # avoid exposing passwords in source control or script history
    $FlashArrayCreds = Import-CliXml -Path $FlashArrayCredsPath -ErrorAction Stop

    # -IgnoreCertificateError allows connections to arrays using self-signed certs,
    # which is common in lab and non-production environments
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
    # Creates the FlashArray file system object — this is the storage container
    # that will be exported via NFS
    $FileSystem = New-Pfa2FileSystem -Array $FlashArray -Name $FileSystemName -ErrorAction Stop
    Write-Host "[OK] File system created: $($FileSystem.Name)" -ForegroundColor Green

    # A FlashArray file system exposes its contents through a "managed directory"
    # (the root directory of the file system). Policies such as NFS export, quota,
    # snapshot, and autodir are attached to this directory object, not the file
    # system directly
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
    # Creates an NFS export policy that defines how the file system is shared.
    # UserMappingEnabled $false means the array will not attempt to map UIDs/GIDs
    # from an identity source (LDAP/AD), which is appropriate for VMware datastores
    # where only the ESXi host (UID 0) accesses the share
    New-Pfa2PolicyNfs -Array $FlashArray `
        -Name "$($FileSystemName)-export-policy" `
        -UserMappingEnabled $false `
        -Enabled $true `
        -ErrorAction Stop | Out-Null

    # Adds a client rule allowing ALL hosts (*) to mount with read-write access.
    # 'no-root-squash' preserves root privileges — required for ESXi hosts that
    # mount NFS datastores as UID 0. Restrict RulesClient to specific IPs or
    # subnets in security-sensitive environments
    New-Pfa2PolicyNfsClientRule -Array $FlashArray `
        -PolicyName "$($FileSystemName)-export-policy" `
        -RulesClient '*' `
        -RulesAccess 'no-root-squash' `
        -RulesPermission 'rw' `
        -RulesNfsVersion $NFSVersion `
        -ErrorAction Stop | Out-Null

    # Binds the NFS export policy to the managed directory and sets the export
    # name, which becomes the last path component of the NFS mount path
    # (e.g., /FileSystemName on the NFS VIF)
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
        # Creates the quota policy container
        New-Pfa2PolicyQuota -Array $FlashArray `
            -Name "$($FileSystemName)-quota-policy" `
            -Enabled $true `
            -ErrorAction Stop | Out-Null

        # Sets a hard capacity limit equal to the requested file system size so
        # writes are rejected once the directory reaches $SizeInBytes.
        # RulesEnforced $true makes this a hard limit (writes fail at the cap)
        # vs. a soft advisory limit
        New-Pfa2PolicyQuotaRule -Array $FlashArray `
            -PolicyName "$($FileSystemName)-quota-policy" `
            -RulesQuotaLimit $SizeInBytes `
            -RulesEnforced $true `
            -ErrorAction Stop | Out-Null

        # Attaches the quota policy to the managed directory so the limit
        # applies to all data written under the NFS export
        New-Pfa2DirectoryPolicyQuota -Array $FlashArray `
            -MemberName $RootManagedDirectory.Name `
            -PolicyName "$($FileSystemName)-quota-policy" `
            -ErrorAction Stop | Out-Null

        Write-Host "[OK] Quota policy created and assigned ($FileSystemSize)" -ForegroundColor Green
    } catch {
        # Quota failure is non-fatal; the file system is still usable without it
        $ErrorMsg = $_.Exception.Message
        Write-Host "[WARNING] Failed to create quota policy: $ErrorMsg" -ForegroundColor Yellow
    }
}

# ==============================================================================
# 6. CREATE AND ASSIGN SNAPSHOT POLICY (OPTIONAL)
# ==============================================================================

if ($SnapshotEnabled) {
    Write-Host "`n[STEP 5] Creating snapshot policy..." -ForegroundColor Cyan

    # Convert millisecond values to hours and days for the human-readable summary
    # printed at the end — the API only accepts milliseconds
    $EveryHours = [math]::Round($SnapshotRulesEvery / 3600000, 2)
    $EveryDays = [math]::Round($SnapshotRulesEvery / 86400000, 2)
    $KeepForHours = [math]::Round($SnapshotRulesKeepFor / 3600000, 2)
    $KeepForDays = [math]::Round($SnapshotRulesKeepFor / 86400000, 2)

    try {
        # Creates the snapshot policy container
        New-Pfa2PolicySnapshot -Array $FlashArray `
            -Name "$($FileSystemName)-snapshot-policy" `
            -Enabled $true `
            -ErrorAction Stop | Out-Null

        # Adds a schedule rule to the policy:
        #   RulesClientName  — label embedded in the snapshot name (e.g., "daily")
        #   RulesEvery       — how often to take a snapshot (milliseconds)
        #   RulesKeepFor     — how long to retain each snapshot before auto-deletion (milliseconds)
        New-Pfa2PolicySnapshotRule -Array $FlashArray `
            -PolicyName "$($FileSystemName)-snapshot-policy" `
            -RulesClientName $SnapshotName `
            -RulesEvery $SnapshotRulesEvery `
            -RulesKeepFor $SnapshotRulesKeepFor `
            -ErrorAction Stop | Out-Null

        # Attaches the snapshot policy to the managed directory so automatic
        # snapshots are taken of the NFS export on the defined schedule
        New-Pfa2DirectoryPolicySnapshot -Array $FlashArray `
            -MemberName $RootManagedDirectory.Name `
            -PolicyName "$($FileSystemName)-snapshot-policy" `
            -ErrorAction Stop | Out-Null

        # Choose the most readable unit (days if >= 1 day, otherwise hours)
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
        # Snapshot failure is non-fatal; the file system is still usable without it
        $ErrorMsg = $_.Exception.Message
        Write-Host "[WARNING] Failed to create snapshot policy: $ErrorMsg" -ForegroundColor Yellow
    }
}

# ==============================================================================
# 7. CREATE AND ASSIGN AUTODIR POLICY
# ==============================================================================

Write-Host "`n[STEP 6] Creating autodir policy..." -ForegroundColor Cyan

try {
    # An autodir policy automatically creates subdirectories when an ESX host
    # accesses a path that does not yet exist, eliminating the need to pre-create
    # directories before mounting. For VMware this will create a managed directory
    # for each VM.
    New-Pfa2PolicyAutodir -Array $FlashArray `
        -Name "$($FileSystemName)-autodir-policy" `
        -Enabled $true `
        -ErrorAction Stop | Out-Null

    # Attaches the autodir policy to the managed directory so on-demand
    # subdirectory creation applies to the entire NFS export tree
    New-Pfa2DirectoryPolicyAutodir -Array $FlashArray `
        -MemberName $RootManagedDirectory.Name `
        -PolicyName "$($FileSystemName)-autodir-policy" `
        -ErrorAction Stop | Out-Null

    Write-Host "[OK] Autodir policy created and assigned" -ForegroundColor Green
} catch {
    # Autodir failure is non-fatal; the file system is still accessible without it
    $ErrorMsg = $_.Exception.Message
    Write-Host "[WARNING] Failed to create autodir policy: $ErrorMsg" -ForegroundColor Yellow
}

# ==============================================================================
# 8. GET NFS EXPORT PATH
# ==============================================================================

Write-Host "`n[STEP 7] Retrieving NFS export path..." -ForegroundColor Cyan

try {
    # Retrieves the export object created when the NFS policy was assigned, which
    # contains the resolved mount path reported by the FlashArray
    $NFSExport = Get-Pfa2DirectoryExport -Array $FlashArray `
        -DirectoryName $RootManagedDirectory.Name `
        -ErrorAction Stop

    # NFSv3 and NFSv4 use different path conventions on FlashArray:
    #   NFSv4: clients mount using the full pseudo-root path returned by the array
    #   NFSv3: clients mount using just the export name as a top-level path
    # The constructed fallback path is used if the array does not return a .Path
    if ($NFSVersion -eq 'nfsv4') {
        $NFSExportPath = $NFSExport.Path
        if (-not $NFSExportPath) {
            $NFSExportPath = "/$($FileSystemName)"
        }
    } else {
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
Write-Host "    .\\New-NFSDatastore.ps1 -DatastoreName '$FileSystemName' -NFSExportPath '$NFSExportPath' -NFSHost '<NFS_VIF_IP>' -vCenterCluster '<cluster>' -vCenterServer '<vcenter>'" -ForegroundColor Gray
Write-Host ""

