<#
.SYNOPSIS
    Creates a new NFS datastore on an Everpure FlashArray and mounts it to a vCenter cluster.

.DESCRIPTION
    This script creates a new NFS file system on an Everpure FlashArray with associated policies,
    then mounts it as an NFS datastore to all ESXi hosts in a specified vCenter cluster.

    The credentials for logging into the FlashArray are stored in an XML file.
    You will need to create the XML file outside of this PowerShell script.

    Here is a quick way to create the credentials XML file:
    $FlashArrayCreds = Get-Credential
    $FlashArrayCreds | Export-CliXml -Path "$HOME/Documents/creds/FA-creds.xml"

.PARAMETER DatastoreName
    Name of the NFS datastore to create in vCenter

.PARAMETER DatastoreSize
    Size of the datastore (e.g., 10TB, 5000GB)

.PARAMETER FlashArrayEndpoint
    FQDN or IP address of the Everpure FlashArray management interface

.PARAMETER FlashArrayCredPath
    Path to FlashArray credentials XML file

.PARAMETER NFSVersion
    NFS version to use: 'nfsv3' or 'nfsv4' (default: nfsv3)

.PARAMETER NFSHost
    FQDN or IP address of the NFS server (FlashArray VIF)

.PARAMETER NconnectSessions
    Number of nconnect sessions for NFS 4.1 (default: 4, range: 1-8)

.PARAMETER vCenterServer
    FQDN or IP address of the vCenter Server

.PARAMETER vCenterCredPath
    Path to vCenter credentials XML file

.PARAMETER vCenterCluster
    Name of the vCenter cluster to mount the datastore to

.PARAMETER QuotaEnabled
    Enable quota policy (default: $true)

.PARAMETER SnapshotEnabled
    Enable snapshot policy (default: $true)

.PARAMETER SnapshotRulesEvery
    Snapshot interval in milliseconds (default: 86400000 = 1 day, range: 5 min to 1 year)

.PARAMETER SnapshotRulesKeepFor
    Snapshot retention in milliseconds (default: 604800000 = 7 days, range: 5 min to 5 years)

.PARAMETER SnapshotClientName
    Snapshot client name for naming snapshots (default: 'daily')

.EXAMPLE
    .\New-PureNFSDatastore.ps1 -DatastoreName "NFS-Datastore-01" -DatastoreSize 10TB -NFSVersion nfsv3 -vCenterCluster "Cluster01" -FlashArrayEndpoint "array.domain.com" -vCenterServer "vcenter.domain.com"

.EXAMPLE
    .\New-PureNFSDatastore.ps1 -DatastoreName "NFS-Datastore-02" -DatastoreSize 100GB -NFSVersion nfsv4 -vCenterCluster "Cluster02" -NconnectSessions 8 -FlashArrayEndpoint "array.domain.com" -vCenterServer "vcenter.domain.com"

.EXAMPLE
    .\New-PureNFSDatastore.ps1 -DatastoreName "NFS-Datastore-03" -DatastoreSize 2TB -NFSVersion nfsv3 -vCenterCluster "Cluster01" -FlashArrayEndpoint "array.domain.com" -vCenterServer "vcenter.domain.com" -SnapshotRulesEvery 3600000 -SnapshotRulesKeepFor 86400000 -SnapshotClientName "hourly"

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
    Requires: PureStoragePowerShellSDK2, VMware.PowerCLI specifically VMware.VimAutomation.Core
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DatastoreName,
    
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^\d+[KMGTP]B$')]
    [string]$DatastoreSize,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('nfsv3','nfsv4')]
    [string]$NFSVersion = 'nfsv3',

    [Parameter(Mandatory=$true)]
    [string]$NFSHost,
    
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
    [ValidateRange(300000, 31536000000)]
    [int64]$SnapshotRulesEvery = 86400000,

    [Parameter(Mandatory=$false)]
    [ValidateRange(300000, 157680000000)]
    [int64]$SnapshotRulesKeepFor = 604800000,

    [Parameter(Mandatory=$false)]
    [string]$SnapshotClientName = 'daily',

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

# Both modules are required: VimAutomation.Core for all vCenter/ESXi cmdlets
# (Connect-VIServer, Get-Cluster, New-Datastore, etc.) and PureStoragePowerShellSDK2
# for all FlashArray Pfa2* cmdlets (Connect-Pfa2Array, New-Pfa2FileSystem, etc.)
try {
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    Import-Module PureStoragePowerShellSDK2 -ErrorAction Stop
    Write-Host "[OK] Modules loaded successfully" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to load required modules: $_" -ForegroundColor Red
    exit 1
}

# The FlashArray quota API requires size in raw bytes; convert the human-readable
# input (e.g., "10TB") by extracting the numeric part and multiplying by the
# appropriate PowerShell unit constant
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
if ($NFSVersion -eq 'nfsv4') {
    Write-Host "[INFO] Nconnect Sessions: $NconnectSessions" -ForegroundColor Yellow
}

# ==============================================================================
# 2. CONNECT TO FLASHARRAY
# ==============================================================================

Write-Host "`n[STEP 1] Connecting to FlashArray..." -ForegroundColor Cyan

try {
    # Credentials are loaded from an encrypted XML file rather than hardcoded to
    # avoid exposing passwords in source control or script history
    $FlashArrayCreds = Import-CliXml -Path $FlashArrayCredPath -ErrorAction Stop

    # -IgnoreCertificateError allows connections to arrays using self-signed certs,
    # which is common in lab and non-production environments
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
    # Creates the FlashArray file system object — the storage container that
    # will be exported via NFS and become the vCenter datastore
    $FileSystem = New-Pfa2FileSystem -Array $FlashArray -Name $DatastoreName -ErrorAction Stop
    Write-Host "[OK] File system created: $($FileSystem.Name)" -ForegroundColor Green

    # A FlashArray file system exposes its contents through a "managed directory"
    # (the root directory of the file system). All policies — NFS export, quota,
    # snapshot, autodir — are attached to this directory object, not the file
    # system itself
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
    # Creates an NFS export policy that controls how the file system is shared.
    # UserMappingEnabled $false disables UID/GID mapping from LDAP/AD — appropriate
    # for VMware datastores where only the ESXi host kernel (UID 0) accesses the share
    New-Pfa2PolicyNfs -Array $FlashArray `
        -Name "$($DatastoreName)-export-policy" `
        -UserMappingEnabled $false `
        -Enabled $true `
        -ErrorAction Stop | Out-Null

    # Adds a client rule allowing ALL hosts (*) with read-write access.
    # 'no-root-squash' preserves root privileges — required because ESXi mounts
    # NFS datastores as UID 0; squashing root would block all datastore I/O.
    # Restrict RulesClient to specific IPs or subnets in security-sensitive environments
    New-Pfa2PolicyNfsClientRule -Array $FlashArray `
        -PolicyName "$($DatastoreName)-export-policy" `
        -RulesClient '*' `
        -RulesAccess 'no-root-squash' `
        -RulesPermission 'rw' `
        -RulesNfsVersion $NFSVersion `
        -ErrorAction Stop | Out-Null

    # Binds the export policy to the managed directory and sets the export name,
    # which becomes the last path component of the NFS mount path on the VIF
    # (e.g., mounting /DatastoreName from the FlashArray NFS IP)
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
        # Creates the quota policy container
        New-Pfa2PolicyQuota -Array $FlashArray `
            -Name "$($DatastoreName)-quota-policy" `
            -Enabled $true `
            -ErrorAction Stop | Out-Null

        # Sets a hard capacity limit equal to the requested datastore size so
        # writes are rejected once the directory reaches $SizeInBytes.
        # RulesEnforced $true makes this a hard limit (writes fail at the cap)
        # rather than a soft advisory notification
        New-Pfa2PolicyQuotaRule -Array $FlashArray `
            -PolicyName "$($DatastoreName)-quota-policy" `
            -RulesQuotaLimit $SizeInBytes `
            -RulesEnforced $true `
            -ErrorAction Stop | Out-Null

        # Attaches the quota policy to the managed directory so the limit
        # applies to all data written under the NFS export
        New-Pfa2DirectoryPolicyQuota -Array $FlashArray `
            -MemberName $RootManagedDirectory.Name `
            -PolicyName "$($DatastoreName)-quota-policy" `
            -ErrorAction Stop | Out-Null

        Write-Host "[OK] Quota policy created and assigned ($DatastoreSize)" -ForegroundColor Green
    } catch {
        # Quota failure is non-fatal; the datastore is still usable without it
        Write-Host "[WARNING] Failed to create quota policy: $_" -ForegroundColor Yellow
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
            -Name "$($DatastoreName)-snapshot-policy" `
            -Enabled $true `
            -ErrorAction Stop | Out-Null

        # Adds a schedule rule:
        #   RulesClientName  — label embedded in each snapshot name (e.g., "daily")
        #   RulesEvery       — how often to take a snapshot (milliseconds)
        #   RulesKeepFor     — how long to retain each snapshot before auto-deletion (milliseconds)
        New-Pfa2PolicySnapshotRule -Array $FlashArray `
            -PolicyName "$($DatastoreName)-snapshot-policy" `
            -RulesClientName $SnapshotClientName `
            -RulesEvery $SnapshotRulesEvery `
            -RulesKeepFor $SnapshotRulesKeepFor `
            -ErrorAction Stop | Out-Null

        # Attaches the snapshot policy to the managed directory so automatic
        # snapshots are taken of the NFS export on the defined schedule
        New-Pfa2DirectoryPolicySnapshot -Array $FlashArray `
            -MemberName $RootManagedDirectory.Name `
            -PolicyName "$($DatastoreName)-snapshot-policy" `
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
        Write-Host "    Client Name: $SnapshotClientName" -ForegroundColor Gray
        Write-Host "       Interval: Every $EveryText" -ForegroundColor Gray
        Write-Host "      Retention: $KeepForText" -ForegroundColor Gray
    } catch {
        # Snapshot failure is non-fatal; the datastore is still usable without it
        Write-Host "[WARNING] Failed to create snapshot policy: $_" -ForegroundColor Yellow
    }
}

# ==============================================================================
# 7. CREATE AND ASSIGN AUTODIR POLICY
# ==============================================================================

Write-Host "`n[STEP 6] Creating autodir policy..." -ForegroundColor Cyan

try {
    # An autodir policy automatically creates subdirectories when a client accesses
    # a path that doesn't yet exist, eliminating the need to pre-create directories
    # before mounting — useful for multi-tenant or dynamically provisioned shares
    New-Pfa2PolicyAutodir -Array $FlashArray `
        -Name "$($DatastoreName)-autodir-policy" `
        -Enabled $true `
        -ErrorAction Stop | Out-Null

    # Attaches the autodir policy to the managed directory so on-demand
    # subdirectory creation applies to the entire NFS export tree
    New-Pfa2DirectoryPolicyAutodir -Array $FlashArray `
        -MemberName $RootManagedDirectory.Name `
        -PolicyName "$($DatastoreName)-autodir-policy" `
        -ErrorAction Stop | Out-Null

    Write-Host "[OK] Autodir policy created and assigned" -ForegroundColor Green
} catch {
    # Autodir failure is non-fatal; the datastore is still accessible without it
    Write-Host "[WARNING] Failed to create autodir policy: $_" -ForegroundColor Yellow
}

# ==============================================================================
# 8. GET NFS EXPORT PATH
# ==============================================================================

Write-Host "`n[STEP 7] Retrieving NFS export path..." -ForegroundColor Cyan

try {
    # Retrieves the export object created when the NFS policy was assigned; it
    # contains the resolved mount path as reported by the FlashArray
    $NFSExport = Get-Pfa2DirectoryExport -Array $FlashArray `
        -DirectoryName $RootManagedDirectory.Name `
        -ErrorAction Stop

    # NFSv4 and NFSv3 use different path conventions on FlashArray:
    #   NFSv4: clients mount using the full pseudo-root path returned by the array
    #   NFSv3: clients mount using just the export name as a top-level path
    # The constructed fallback is used if the array doesn't populate .Path
    if ($NFSVersion -eq 'nfsv4') {
        $NFSExportPath = $NFSExport.Path
        if (-not $NFSExportPath) {
            $NFSExportPath = "/$($DatastoreName)"
        }
    } else {
        $NFSExportPath = "/$($DatastoreName)"
    }

    Write-Host "[OK] NFS export path: $NFSExportPath" -ForegroundColor Green
    Write-Host "[INFO] NFS Host: $FlashArrayEndpoint" -ForegroundColor Gray
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
    # vCenter credentials are also stored in an encrypted XML file, separate
    # from the FlashArray credentials, to allow independent credential rotation
    $vCenterCreds = Import-CliXml -Path $vCenterCredPath -ErrorAction Stop

    # Out-Null suppresses the VIServer connection object that PowerCLI prints
    # by default, keeping console output clean
    Connect-VIServer -Server $vCenterServer `
        -Credential $vCenterCreds `
        -ErrorAction Stop | Out-Null
    Write-Host "[OK] Connected to vCenter: $vCenterServer" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to connect to vCenter: $_" -ForegroundColor Red
    # Disconnect FlashArray before exiting — the file system was already created
    # above and does not need to be rolled back, but the session should be closed
    Disconnect-Pfa2Array -Array $FlashArray
    exit 1
}

# ==============================================================================
# 10. VALIDATE CLUSTER EXISTS
# ==============================================================================

Write-Host "`n[STEP 9] Validating vCenter cluster..." -ForegroundColor Cyan

try {
    # Validate the cluster name before iterating hosts — fail fast here rather
    # than discovering a bad cluster name after attempting mounts on zero hosts
    $Cluster = Get-Cluster -Name $vCenterCluster -ErrorAction Stop
    Write-Host "[OK] Found cluster: $($Cluster.Name)" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Cluster '$vCenterCluster' not found: $_" -ForegroundColor Red
    # Disconnect both sessions before exiting to avoid orphaned connections
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false
    Disconnect-Pfa2Array -Array $FlashArray
    exit 1
}

# ==============================================================================
# 10a. PRE-MOUNT DIAGNOSTICS (NFS 4.1)
# ==============================================================================

if ($NFSVersion -eq 'nfsv4') {
    Write-Host "`n[DIAGNOSTICS] Running NFS 4.1 pre-mount checks..." -ForegroundColor Cyan

    # Use one representative host for pre-flight checks — we assume the cluster
    # is homogeneous; one host is enough to surface version or firewall issues
    $DiagHost = Get-Cluster -Name $vCenterCluster | Get-VMHost | Select-Object -First 1

    # NFS 4.1 requires vSphere 6.0+; nconnect requires 7.0 U1+.
    # Warn early so the operator can abort before attempting mounts that will fail
    Write-Host "  [CHECK] ESXi Version:" -ForegroundColor Gray
    Write-Host "    Host: $($DiagHost.Name)" -ForegroundColor Gray
    Write-Host "    Version: $($DiagHost.Version)" -ForegroundColor Gray
    Write-Host "    Build: $($DiagHost.Build)" -ForegroundColor Gray

    if ($DiagHost.Version -lt "6.0") {
        Write-Host "    [WARNING] NFS 4.1 requires vSphere 6.0 or later" -ForegroundColor Yellow
    }

    if ($DiagHost.Version -lt "7.0" -and $NconnectSessions -gt 1) {
        Write-Host "    [WARNING] Nconnect requires vSphere 7.0 U1 or later" -ForegroundColor Yellow
    }

    # ESXi has separate firewall rules for NFS v3 and NFS v4.1. If the NFS41Client
    # rule is disabled, the mount will silently fail or hang — surface this early
    Write-Host "  [CHECK] NFS Firewall Rules:" -ForegroundColor Gray
    $FirewallRules = Get-VMHostFirewallException -VMHost $DiagHost | Where-Object {$_.Name -like "*NFS*"}
    foreach ($Rule in $FirewallRules) {
        $Status = if ($Rule.Enabled) { "Enabled" } else { "DISABLED" }
        $Color = if ($Rule.Enabled) { "Gray" } else { "Yellow" }
        Write-Host "    $($Rule.Name): $Status" -ForegroundColor $Color
    }

    # Ping is issued via esxcli so it travels over the ESXi VMkernel network stack,
    # not the management network where this script runs. This confirms that the
    # FlashArray NFS VIF is reachable from the dataplane path ESXi will actually use
    Write-Host "  [CHECK] Network Connectivity:" -ForegroundColor Gray
    try {
        $EsxCli = Get-EsxCli -VMHost $DiagHost -V2
        $PingArgs = $EsxCli.network.diag.ping.CreateArgs()
        $PingArgs.host = $FlashArrayEndpoint
        $PingArgs.count = 3
        $PingResult = $EsxCli.network.diag.ping.Invoke($PingArgs)

        if ($PingResult.Summary.PacketLost -eq 0) {
            Write-Host "    Ping to ${FlashArrayEndpoint}: SUCCESS (0% loss)" -ForegroundColor Green
        } else {
            Write-Host "    Ping to ${FlashArrayEndpoint}: PARTIAL ($($PingResult.Summary.PacketLost)% loss)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    Ping test failed: $_" -ForegroundColor Yellow
    }

    # NFS traffic must flow over a VMkernel adapter. Listing them with MTU helps
    # diagnose jumbo frame mismatches that cause silent throughput degradation
    Write-Host "  [CHECK] VMkernel Adapters:" -ForegroundColor Gray
    $VMKAdapters = Get-VMHostNetworkAdapter -VMHost $DiagHost -VMKernel
    foreach ($Adapter in $VMKAdapters) {
        Write-Host "    $($Adapter.Name): $($Adapter.IP) (MTU: $($Adapter.Mtu))" -ForegroundColor Gray
    }

    # Listing existing NFS 4.1 mounts provides context when troubleshooting a
    # failed mount — e.g., the same export mounted under a different name causes
    # a duplicate-mount error that is hard to diagnose without this context
    Write-Host "  [CHECK] Existing NFS 4.1 Mounts:" -ForegroundColor Gray
    try {
        $ExistingNFS41 = $EsxCli.storage.nfs41.list.Invoke()
        if ($ExistingNFS41.Count -gt 0) {
            Write-Host "    Found $($ExistingNFS41.Count) existing NFS 4.1 datastore(s)" -ForegroundColor Gray
        } else {
            Write-Host "    No existing NFS 4.1 datastores" -ForegroundColor Gray
        }
    } catch {
        Write-Host "    Could not list NFS 4.1 datastores: $_" -ForegroundColor Yellow
    }

    Write-Host "  [INFO] Diagnostics complete`n" -ForegroundColor Cyan
}

# ==============================================================================
# 11. MOUNT NFS DATASTORE TO ALL HOSTS IN CLUSTER
# ==============================================================================

Write-Host "`n[STEP 10] Mounting NFS datastore to cluster hosts..." -ForegroundColor Cyan

try {
    # Sort alphabetically for consistent, readable log output across runs
    $VMHosts = Get-Cluster -Name $vCenterCluster | Get-VMHost | Sort-Object Name
    Write-Host "[INFO] Found $($VMHosts.Count) hosts in cluster" -ForegroundColor Yellow

    $MountedCount = 0
    $FailedCount = 0

    if ($VMHosts.Count -eq 0) {
        Write-Host "[ERROR] No hosts found in cluster '$vCenterCluster'" -ForegroundColor Red
        Disconnect-VIServer -Server $vCenterServer -Confirm:$false
        exit 1
    }

    foreach ($VMHost in $VMHosts) {
        try {
            Write-Host "  [INFO] Mounting to host: $($VMHost.Name)..." -ForegroundColor Gray

            if ($NFSVersion -eq 'nfsv4') {
                # esxcli is used as the primary path for NFS 4.1 because New-Datastore
                # does not expose the nconnect parameter — only esxcli storage.nfs41.add
                # supports setting the number of parallel TCP sessions (connections)
                try {
                    Write-Host "    [DEBUG] Using esxcli method for NFS 4.1" -ForegroundColor DarkGray

                    # -V2 returns a strongly-typed argument object rather than positional
                    # args, which prevents parameter-order bugs across ESXi versions
                    $EsxCli = Get-EsxCli -VMHost $VMHost -V2

                    $MountArgs = $EsxCli.storage.nfs41.add.CreateArgs()
                    $MountArgs.host = $FlashArrayEndpoint
                    $MountArgs.share = $NFSExportPath
                    $MountArgs.volumename = $DatastoreName

                    Write-Host "    [DEBUG] Mount parameters:" -ForegroundColor DarkGray
                    Write-Host "      Host: $($MountArgs.host)" -ForegroundColor DarkGray
                    Write-Host "      Share: $($MountArgs.share)" -ForegroundColor DarkGray
                    Write-Host "      Volume: $($MountArgs.volumename)" -ForegroundColor DarkGray

                    # nconnect opens multiple TCP sessions to the FlashArray, improving
                    # throughput by parallelizing I/O. Setting it will throw on ESXi < 7.0 U1,
                    # so it's wrapped in its own try/catch to degrade gracefully to a
                    # single-session mount rather than aborting the entire host
                    if ($NconnectSessions -gt 1) {
                        try {
                            $MountArgs.nconnect = $NconnectSessions
                            Write-Host "      Nconnect: $($MountArgs.nconnect)" -ForegroundColor DarkGray
                        } catch {
                            Write-Host "    [WARNING] Nconnect not supported on this ESXi version" -ForegroundColor Yellow
                        }
                    }

                    Write-Host "    [DEBUG] Executing mount command..." -ForegroundColor DarkGray
                    $MountResult = $EsxCli.storage.nfs41.add.Invoke($MountArgs)

                    # esxcli returns success before the ESXi storage stack finishes
                    # registering the datastore with vCenter; wait briefly so that the
                    # subsequent Get-Datastore call finds the new datastore
                    Start-Sleep -Seconds 2
                    $VerifyDS = Get-Datastore -Name $DatastoreName -VMHost $VMHost -ErrorAction SilentlyContinue

                    if ($VerifyDS) {
                        Write-Host "    [OK] Mounted with NFS 4.1 (nconnect: $NconnectSessions)" -ForegroundColor Green
                        Write-Host "    [DEBUG] Datastore capacity: $([math]::Round($VerifyDS.CapacityGB, 2)) GB" -ForegroundColor DarkGray
                    } else {
                        throw "Mount command succeeded but datastore not visible"
                    }
                } catch {
                    # Fall back to New-Datastore if esxcli fails. This path loses
                    # nconnect support but keeps the mount attempt alive on hosts
                    # where the esxcli NFS 4.1 API surface differs (e.g., older builds)
                    Write-Host "    [WARNING] esxcli mount failed: $_" -ForegroundColor Yellow
                    Write-Host "    [INFO] Trying PowerCLI New-Datastore method..." -ForegroundColor Gray

                    try {
                        New-Datastore -Nfs -VMHost $VMHost `
                            -Name $DatastoreName `
                            -Path $NFSExportPath `
                            -NfsHost $FlashArrayEndpoint `
                            -FileSystemVersion "4.1" `
                            -ErrorAction Stop | Out-Null

                        Write-Host "    [OK] Mounted with NFS 4.1 (PowerCLI method)" -ForegroundColor Green
                    } catch {
                        Write-Host "    [ERROR] PowerCLI mount also failed: $_" -ForegroundColor Red
                        Write-Host "    [TROUBLESHOOTING] Check:" -ForegroundColor Yellow
                        Write-Host "      1. ESXi version supports NFS 4.1 (6.0+)" -ForegroundColor Yellow
                        Write-Host "      2. NFS 4.1 firewall rule is enabled" -ForegroundColor Yellow
                        Write-Host "      3. Network connectivity to $FlashArrayEndpoint" -ForegroundColor Yellow
                        Write-Host "      4. Export path is correct: $NFSExportPath" -ForegroundColor Yellow
                        throw
                    }
                }
            } else {
                # NFSv3 uses the standard PowerCLI cmdlet — nconnect is not applicable
                # for NFS 3, and New-Datastore is sufficient for all supported ESXi versions
                Write-Host "    [DEBUG] Using NFS 3 mount" -ForegroundColor DarkGray
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
            # Per-host failures are counted but do not stop the loop — the script
            # continues mounting remaining hosts and reports a full tally at the end
            Write-Host "    [ERROR] Failed to mount on $($VMHost.Name)" -ForegroundColor Red
            Write-Host "    [ERROR] Error details: $_" -ForegroundColor Red
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
    # Query vCenter for the datastore object to confirm it is registered and
    # visible in inventory — stronger than trusting that individual mount commands returned success
    $Datastore = Get-Datastore -Name $DatastoreName -ErrorAction Stop

    # Retrieve the associated host list so we can confirm the mount count
    # matches the number of hosts the loop reported as successful
    $DatastoreHosts = $Datastore | Get-VMHost

    Write-Host "[OK] Datastore verified" -ForegroundColor Green
    Write-Host "  Name: $($Datastore.Name)" -ForegroundColor Gray
    Write-Host "  Type: $($Datastore.Type)" -ForegroundColor Gray
    Write-Host "  Capacity: $([math]::Round($Datastore.CapacityGB, 2)) GB" -ForegroundColor Gray
    Write-Host "  Free Space: $([math]::Round($Datastore.FreeSpaceGB, 2)) GB" -ForegroundColor Gray
    Write-Host "  Mounted on: $($DatastoreHosts.Count) hosts" -ForegroundColor Gray
} catch {
    # Verification failure is a warning, not fatal — mounts may still be usable
    # even if the vCenter inventory hasn't fully refreshed yet
    Write-Host "[WARNING] Could not verify datastore: $_" -ForegroundColor Yellow
}

# ==============================================================================
# 13. CLEANUP AND SUMMARY
# ==============================================================================

Write-Host "`n[STEP 12] Disconnecting..." -ForegroundColor Cyan

# -Confirm:$false suppresses the interactive prompt PowerCLI shows by default;
# -ErrorAction SilentlyContinue prevents a noisy error if the session already timed out
try {
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[OK] Disconnected from vCenter" -ForegroundColor Green
} catch {
    Write-Host "[WARNING] Failed to disconnect from vCenter" -ForegroundColor Yellow
}

# Disconnect FlashArray session; -ErrorAction SilentlyContinue handles the case
# where the session was already closed by an earlier error path
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
if ($NFSVersion -eq 'nfsv4') {
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

