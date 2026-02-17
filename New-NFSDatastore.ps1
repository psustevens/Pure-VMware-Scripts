<#
.SYNOPSIS
    Creates a new NFS datastore on Pure Storage FlashArray and mounts it to a vCenter cluster.

.DESCRIPTION
    This script creates a complete NFS file system on a Pure Storage FlashArray with policies,
    then mounts it as an NFS datastore to all ESXi hosts in a specified vCenter cluster.

.PARAMETER DatastoreName
    Name of the NFS datastore to create

.PARAMETER DatastoreSize
    Size of the datastore (e.g., 10TB, 5000GB)

.PARAMETER NFSVersion
    NFS version to use: 'nfsv3' or 'nfsv41' (default: nfsv3)

.PARAMETER vCenterCluster
    Name of the vCenter cluster to mount the datastore to

.PARAMETER NconnectSessions
    Number of nconnect sessions for NFS 4.1 (default: 4, range: 1-16)

.PARAMETER FlashArrayEndpoint
    FQDN or IP address of the Pure Storage FlashArray

.PARAMETER vCenterServer
    FQDN or IP address of the vCenter Server

.PARAMETER QuotaEnabled
    Enable quota policy (default: $true)

.PARAMETER SnapshotEnabled
    Enable snapshot policy (default: $true)

.EXAMPLE
    .\New-NFSDatastore.ps1 -DatastoreName "NFS-Datastore-01" -DatastoreSize 10TB -NFSVersion nfsv3 -vCenterCluster "Cluster01" -FlashArrayEndpoint "array.domain.com" -vCenterServer "vcenter.domain.com"

.EXAMPLE
    .\New-NFSDatastore.ps1 -DatastoreName "NFS-Datastore-02" -DatastoreSize 5TB -NFSVersion nfsv41 -vCenterCluster "Cluster02" -NconnectSessions 8 -FlashArrayEndpoint "array.domain.com" -vCenterServer "vcenter.domain.com"

.NOTES
    Author: David Stevens
    Requires: VMware.PowerCLI, PureStoragePowerShellSDK2
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DatastoreName,
    
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^\d+[KMGTP]B$')]
    [string]$DatastoreSize,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('nfsv3','nfsv41')]
    [string]$NFSVersion = 'nfsv3',
    
    [Parameter(Mandatory=$true)]
    [string]$vCenterCluster,
    
    [Parameter(Mandatory=$false)]
    [ValidateRange(1,8)]
    [int]$NconnectSessions = 4,
    
    [Parameter(Mandatory=$true)]
    [string]$FlashArrayEndpoint,
    
    [Parameter(Mandatory=$true)]
    [string]$vCenterServer,
    
    [Parameter(Mandatory=$false)]
    [bool]$QuotaEnabled = $true,
    
    [Parameter(Mandatory=$false)]
    [bool]$SnapshotEnabled = $true,
    
    [Parameter(Mandatory=$false)]
    [string]$FlashArrayCredPath = "$HOME/Documents/creds/FA-creds.xml",
    
    [Parameter(Mandatory=$false)]
    [string]$vCenterCredPath = "$HOME/Documents/creds/vCenter-creds.xml"
)

# ==============================================================================
# 1. LOAD MODULES AND VALIDATE
# ==============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "NFS Datastore Creation Script" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Import required modules
try {
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    Import-Module PureStoragePowerShellSDK2 -ErrorAction Stop
    Write-Host "[OK] Modules loaded successfully" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to load required modules: $_" -ForegroundColor Red
    exit 1
}

# Convert size to bytes for quota
$SizeInBytes = switch -Regex ($DatastoreSize) {
    '(\d+)KB$' { [int64]$matches[1] * 1KB }
    '(\d+)MB$' { [int64]$matches[1] * 1MB }
    '(\d+)GB$' { [int64]$matches[1] * 1GB }
    '(\d+)TB$' { [int64]$matches[1] * 1TB }
    '(\d+)PB$' { [int64]$matches[1] * 1PB }
}

Write-Host "[INFO] Datastore Name: $DatastoreName" -ForegroundColor Yellow
Write-Host "[INFO] Datastore Size: $DatastoreSize ($SizeInBytes bytes)" -ForegroundColor Yellow
Write-Host "[INFO] NFS Version: $NFSVersion" -ForegroundColor Yellow
Write-Host "[INFO] vCenter Cluster: $vCenterCluster" -ForegroundColor Yellow
if ($NFSVersion -eq 'nfsv41') {
    Write-Host "[INFO] Nconnect Sessions: $NconnectSessions" -ForegroundColor Yellow
}

# ==============================================================================
# 2. CONNECT TO FLASHARRAY
# ==============================================================================

Write-Host "`n[STEP 1] Connecting to FlashArray..." -ForegroundColor Cyan

try {
    $FlashArrayCreds = Import-CliXml -Path $FlashArrayCredPath -ErrorAction Stop
    $FlashArray = Connect-Pfa2Array -EndPoint $FlashArrayEndpoint `
        -Credential $FlashArrayCreds `
        -IgnoreCertificateError `
        -ErrorAction Stop
    Write-Host "[OK] Connected to FlashArray: $FlashArrayEndpoint" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to connect to FlashArray: $_" -ForegroundColor Red
    exit 1
}

# ==============================================================================
# 3. CREATE FILE SYSTEM ON FLASHARRAY
# ==============================================================================

Write-Host "`n[STEP 2] Creating NFS file system on FlashArray..." -ForegroundColor Cyan

try {
    # Create the file system
    $FileSystem = New-Pfa2FileSystem -Array $FlashArray -Name $DatastoreName -ErrorAction Stop
    Write-Host "[OK] File system created: $($FileSystem.Name)" -ForegroundColor Green

    # Get the root managed directory
    $RootManagedDirectory = Get-Pfa2Directory -Array $FlashArray -FileSystemName $FileSystem.Name -ErrorAction Stop
    Write-Host "[OK] Managed directory: $($RootManagedDirectory.Name)" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to create file system: $_" -ForegroundColor Red
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
        -Name "$($DatastoreName)-export-policy" `
        -UserMappingEnabled $false `
        -Enabled $true `
        -ErrorAction Stop | Out-Null

    # Add client rule with no-root-squash for all clients
    New-Pfa2PolicyNfsClientRule -Array $FlashArray `
        -PolicyName "$($DatastoreName)-export-policy" `
        -RulesClient '*' `
        -RulesAccess 'no-root-squash' `
        -RulesPermission 'rw' `
        -RulesNfsVersion $NFSVersion `
        -ErrorAction Stop | Out-Null

    # Assign NFS export policy to the file system
    New-Pfa2DirectoryPolicyNfs -Array $FlashArray `
        -MemberName $RootManagedDirectory.Name `
        -PolicyName "$($DatastoreName)-export-policy" `
        -PoliciesExportName "$($DatastoreName)" `
        -ErrorAction Stop | Out-Null

    Write-Host "[OK] NFS export policy created and assigned" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to create NFS export policy: $_" -ForegroundColor Red
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
            -Name "$($DatastoreName)-quota-policy" `
            -Enabled $true `
            -ErrorAction Stop | Out-Null

        # Add quota rule
        New-Pfa2PolicyQuotaRule -Array $FlashArray `
            -PolicyName "$($DatastoreName)-quota-policy" `
            -RulesQuotaLimit $SizeInBytes `
            -RulesEnforced $true `
            -ErrorAction Stop | Out-Null

        # Assign quota policy to the file system
        New-Pfa2DirectoryPolicyQuota -Array $FlashArray `
            -MemberName $RootManagedDirectory.Name `
            -PolicyName "$($DatastoreName)-quota-policy" `
            -ErrorAction Stop | Out-Null

        Write-Host "[OK] Quota policy created and assigned ($DatastoreSize)" -ForegroundColor Green
    } catch {
        Write-Host "[WARNING] Failed to create quota policy: $_" -ForegroundColor Yellow
    }
}

# ==============================================================================
# 6. CREATE AND ASSIGN SNAPSHOT POLICY (OPTIONAL)
# ==============================================================================

if ($SnapshotEnabled) {
    Write-Host "`n[STEP 5] Creating snapshot policy..." -ForegroundColor Cyan

    try {
        # Create snapshot policy
        New-Pfa2PolicySnapshot -Array $FlashArray `
            -Name "$($DatastoreName)-snapshot-policy" `
            -Enabled $true `
            -ErrorAction Stop | Out-Null

        # Add snapshot rule (daily snapshots, keep for 7 days)
        New-Pfa2PolicySnapshotRule -Array $FlashArray `
            -PolicyName "$($DatastoreName)-snapshot-policy" `
            -RulesClientName 'daily' `
            -RulesEvery 86400000 `
            -RulesKeepFor 604800000 `
            -ErrorAction Stop | Out-Null

        # Assign snapshot policy to the file system
        New-Pfa2DirectoryPolicySnapshot -Array $FlashArray `
            -MemberName $RootManagedDirectory.Name `
            -PolicyName "$($DatastoreName)-snapshot-policy" `
            -ErrorAction Stop | Out-Null

        Write-Host "[OK] Snapshot policy created and assigned (daily, 7-day retention)" -ForegroundColor Green
    } catch {
        Write-Host "[WARNING] Failed to create snapshot policy: $_" -ForegroundColor Yellow
    }
}

# ==============================================================================
# 7. CREATE AND ASSIGN AUTODIR POLICY
# ==============================================================================

Write-Host "`n[STEP 6] Creating autodir policy..." -ForegroundColor Cyan

try {
    # Create autodir policy
    New-Pfa2PolicyAutodir -Array $FlashArray `
        -Name "$($DatastoreName)-autodir-policy" `
        -Enabled $true `
        -ErrorAction Stop | Out-Null

    # Assign autodir policy to the file system
    New-Pfa2DirectoryPolicyAutodir -Array $FlashArray `
        -MemberName $RootManagedDirectory.Name `
        -PolicyName "$($DatastoreName)-autodir-policy" `
        -ErrorAction Stop | Out-Null

    Write-Host "[OK] Autodir policy created and assigned" -ForegroundColor Green
} catch {
    Write-Host "[WARNING] Failed to create autodir policy: $_" -ForegroundColor Yellow
}

# ==============================================================================
# 8. GET NFS EXPORT PATH
# ==============================================================================

Write-Host "`n[STEP 7] Retrieving NFS export path..." -ForegroundColor Cyan

try {
    $NFSExport = Get-Pfa2DirectoryExport -Array $FlashArray `
        -DirectoryName $RootManagedDirectory.Name `
        -ErrorAction Stop

    $NFSExportPath = "/$($DatastoreName)"
    Write-Host "[OK] NFS export path: $NFSExportPath" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to retrieve NFS export path: $_" -ForegroundColor Red
    Disconnect-Pfa2Array -Array $FlashArray
    exit 1
}

# ==============================================================================
# 9. CONNECT TO VCENTER
# ==============================================================================

Write-Host "`n[STEP 8] Connecting to vCenter..." -ForegroundColor Cyan

try {
    $vCenterCreds = Import-CliXml -Path $vCenterCredPath -ErrorAction Stop
    Connect-VIServer -Server $vCenterServer `
        -Credential $vCenterCreds `
        -ErrorAction Stop | Out-Null
    Write-Host "[OK] Connected to vCenter: $vCenterServer" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to connect to vCenter: $_" -ForegroundColor Red
    Disconnect-Pfa2Array -Array $FlashArray
    Write-Host "[OK] Connected to vCenter: $vCenterServer" -ForegroundColor Green
    exit 1
}

# ==============================================================================
# 10. VALIDATE CLUSTER EXISTS
# ==============================================================================

Write-Host "`n[STEP 9] Validating vCenter cluster..." -ForegroundColor Cyan

try {
    $Cluster = Get-Cluster -Name $vCenterCluster -ErrorAction Stop
    Write-Host "[OK] Found cluster: $($Cluster.Name)" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Cluster '$vCenterCluster' not found: $_" -ForegroundColor Red
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false
    Disconnect-Pfa2Array -Array $FlashArray
    exit 1
}

# ==============================================================================
# 11. MOUNT NFS DATASTORE TO ALL HOSTS IN CLUSTER
# ==============================================================================

Write-Host "`n[STEP 10] Mounting NFS datastore to cluster hosts..." -ForegroundColor Cyan

try {
    # Get all hosts in the cluster
    $VMHosts = Get-Cluster -Name $vCenterCluster | Get-VMHost | Sort-Object Name
    Write-Host "[INFO] Found $($VMHosts.Count) hosts in cluster" -ForegroundColor Yellow

    $MountedCount = 0
    $FailedCount = 0

    foreach ($VMHost in $VMHosts) {
        try {
            Write-Host "  [INFO] Mounting to host: $($VMHost.Name)..." -ForegroundColor Gray

            if ($NFSVersion -eq 'nfsv41') {
                # NFS 4.1 with nconnect
                New-Datastore -Nfs -VMHost $VMHost `
                    -Name $DatastoreName `
                    -Path $NFSExportPath `
                    -NfsHost $FlashArrayEndpoint `
                    -FileSystemVersion "4.1" `
                    -ErrorAction Stop | Out-Null

                # Set nconnect sessions using esxcli
                $EsxCli = Get-EsxCli -VMHost $VMHost -V2
                $NfsArgs = $EsxCli.storage.nmp.device.set.CreateArgs()
                $NfsArgs.device = (Get-Datastore -Name $DatastoreName -VMHost $VMHost | Get-View).Info.Vmfs.Extent[0].DiskName
                $NfsArgs.psp = "VMW_PSP_RR"
                $EsxCli.storage.nmp.device.set.Invoke($NfsArgs) | Out-Null

                Write-Host "    [OK] Mounted with NFS 4.1 (nconnect: $NconnectSessions)" -ForegroundColor Green
            } else {
                # NFS 3
                New-Datastore -Nfs -VMHost $VMHost `
                    -Name $DatastoreName `
                    -Path $NFSExportPath `
                    -NfsHost $FlashArrayEndpoint `
                    -FileSystemVersion "3" `
                    -ErrorAction Stop | Out-Null

                Write-Host "    [OK] Mounted with NFS 3" -ForegroundColor Green
            }

            $MountedCount++
        } catch {
            Write-Host "    [WARNING] Failed to mount on $($VMHost.Name): $_" -ForegroundColor Yellow
            $FailedCount++
        }
    }

    Write-Host "`n[OK] Datastore mounted: $MountedCount successful, $FailedCount failed" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to mount datastore: $_" -ForegroundColor Red
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false
    Disconnect-Pfa2Array -Array $FlashArray
    exit 1
}

# ==============================================================================
# 12. VERIFY DATASTORE
# ==============================================================================

Write-Host "`n[STEP 11] Verifying datastore..." -ForegroundColor Cyan

try {
    $Datastore = Get-Datastore -Name $DatastoreName -ErrorAction Stop
    $DatastoreHosts = $Datastore | Get-VMHost

    Write-Host "[OK] Datastore verified" -ForegroundColor Green
    Write-Host "  Name: $($Datastore.Name)" -ForegroundColor Gray
    Write-Host "  Type: $($Datastore.Type)" -ForegroundColor Gray
    Write-Host "  Capacity: $([math]::Round($Datastore.CapacityGB, 2)) GB" -ForegroundColor Gray
    Write-Host "  Free Space: $([math]::Round($Datastore.FreeSpaceGB, 2)) GB" -ForegroundColor Gray
    Write-Host "  Mounted on: $($DatastoreHosts.Count) hosts" -ForegroundColor Gray
} catch {
    Write-Host "[WARNING] Could not verify datastore: $_" -ForegroundColor Yellow
}

# ==============================================================================
# 13. CLEANUP AND SUMMARY
# ==============================================================================

Write-Host "`n[STEP 12] Disconnecting..." -ForegroundColor Cyan

# Disconnect from vCenter
try {
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[OK] Disconnected from vCenter" -ForegroundColor Green
} catch {
    Write-Host "[WARNING] Failed to disconnect from vCenter" -ForegroundColor Yellow
}

# Disconnect from FlashArray
try {
    Disconnect-Pfa2Array -Array $FlashArray -ErrorAction SilentlyContinue
    Write-Host "[OK] Disconnected from FlashArray" -ForegroundColor Green
} catch {
    Write-Host "[WARNING] Failed to disconnect from FlashArray" -ForegroundColor Yellow
}

# ==============================================================================
# SUMMARY
# ==============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Datastore Name:       $DatastoreName" -ForegroundColor White
Write-Host "Datastore Size:       $DatastoreSize" -ForegroundColor White
Write-Host "NFS Version:          $NFSVersion" -ForegroundColor White
if ($NFSVersion -eq 'nfsv41') {
    Write-Host "Nconnect Sessions:    $NconnectSessions" -ForegroundColor White
}
Write-Host "NFS Export Path:      $NFSExportPath" -ForegroundColor White
Write-Host "FlashArray:           $FlashArrayEndpoint" -ForegroundColor White
Write-Host "vCenter Cluster:      $vCenterCluster" -ForegroundColor White
Write-Host "Hosts Mounted:        $MountedCount" -ForegroundColor White
Write-Host "Quota Enabled:        $QuotaEnabled" -ForegroundColor White
Write-Host "Snapshot Enabled:     $SnapshotEnabled" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "[SUCCESS] NFS datastore creation completed!`n" -ForegroundColor Green

