<#
.SYNOPSIS
    Mounts an existing NFS export, ideally from an Everpure FlashArray, to a vCenter cluster.

.DESCRIPTION
    This script connects to vCenter and mounts an existing NFS export (from FlashArray or any NFS server)
    to all ESXi hosts in a specified vCenter cluster. It assumes the NFS export already exists.

    The credentials for logging into vCenter are stored in an XML file.
    You will need to create the XML file outside of this PowerShell script.

    Here is a quick way to create the credentials XML file:
    $vCenterCreds = Get-Credential
    $vCenterCreds | Export-CliXml -Path "$HOME/Documents/creds/vCenter-creds.xml"

.PARAMETER DatastoreName
    (Required) Name of the NFS datastore to create in vCenter

.PARAMETER NFSHost
    (Required) FQDN or IP address of the NFS server (FlashArray VIF)

.PARAMETER NFSExportPath
    (Required) NFS export path (e.g., /datastore-name)

.PARAMETER NFSVersion
    (Optional) NFS version to use: 'nfsv3' or 'nfsv4' (default: nfsv3)

.PARAMETER NconnectSessions
    (Optional) Number of nconnect sessions for NFS 4.1 (default: 4, range: 1-8)

.PARAMETER vCenterCluster
    (Required) Name of the vCenter cluster to mount the datastore to

.PARAMETER vCenterServer
    (Required) FQDN or IP address of the vCenter Server

.PARAMETER vCenterCredsPath
    (Optional)Path to vCenter credentials XML file (default: $HOME/Documents/creds/vCenter-creds.xml)

.EXAMPLE
    .\New-NFSDatastore.ps1 -DatastoreName "NFS-DS-01" -NFSHost "array.domain.com" -NFSExportPath "/NFS-DS-01" -vCenterCluster "Cluster01" -vCenterServer "vcenter.domain.com"

.EXAMPLE
    .\New-NFSDatastore.ps1 -DatastoreName "NFS-DS-01" -NFSHost "10.0.0.100" -NFSExportPath "/NFS-DS-01" -vCenterCluster "Cluster01" -vCenterServer "vcenter.domain.com" -NFSVersion nfsv4 

.EXAMPLE
    .\New-NFSDatastore.ps1 -DatastoreName "NFS-DS-01" -NFSHost "array.domain.com" -NFSExportPath "/NFS-DS-01" -vCenterCluster "Cluster01" -vCenterServer "vcenter.domain.com" -NconnectSessions 8

.EXAMPLE
    .\New-NFSDatastore.ps1 -DatastoreName "NFS-DS-01" -NFSHost "10.0.0.100" -NFSExportPath "/NFS-DS-01" -vCenterCluster "Cluster01" -vCenterServer "vcenter.domain.com" -NFSVersion nfsv4 -NconnectSessions 8

.EXAMPLE 
    .\New-NFSDatastore.ps1 -DatastoreName "NFS-DS-01" -NFSHost "array.domain.com" -NFSExportPath "/NFS-DS-01" -vCenterCluster "Cluster01" -vCenterServer "vcenter.domain.com" -vCenterCredsPath "$HOME/Documents/creds/vCenter-creds.xml"

.NOTES
    Author: David Stevens - Everpure
    Requires: VMware.PowerCLI, specifically VMware.VimAutomation.Core
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DatastoreName,
    
    [Parameter(Mandatory=$true)]
    [string]$NFSHost,
    
    [Parameter(Mandatory=$true)]
    [string]$NFSExportPath,

    [Parameter(Mandatory=$false)]
    [ValidateSet('nfsv3','nfsv4')]
    [string]$NFSVersion = 'nfsv3',
    
    [Parameter(Mandatory=$false)]
    [ValidateRange(1,8)]
    [int]$NconnectSessions = 4,
    
    [Parameter(Mandatory=$true)]
    [string]$vCenterCluster,
    
    [Parameter(Mandatory=$true)]
    [string]$vCenterServer,

    [Parameter(Mandatory=$false)]
    [string]$vCenterCredsPath = "$HOME/Documents/creds/vCenter-creds.xml"
)

# ==============================================================================
# SCRIPT INITIALIZATION
# ==============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "NFS DATASTORE MOUNT SCRIPT" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# VMware.VimAutomation.Core provides Connect-VIServer, Get-Cluster, Get-VMHost,
# New-Datastore, Get-Datastore, and Get-EsxCli — all cmdlets used in this script
try {
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    Write-Host "[OK] Module loaded successfully" -ForegroundColor Green
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[ERROR] Failed to load required module: $ErrorMsg" -ForegroundColor Red
    exit 1
}

# ==============================================================================
# 1. CONNECT TO VCENTER
# ==============================================================================

Write-Host "[STEP 1] Connecting to vCenter..." -ForegroundColor Cyan

try {
    # Credentials are loaded from an encrypted XML file to avoid hardcoding
    # passwords in the script or exposing them in shell history
    $vCenterCreds = Import-CliXml -Path $vCenterCredsPath -ErrorAction Stop

    # Out-Null suppresses the VIServer connection object that PowerCLI prints
    # by default, keeping console output clean
    Connect-VIServer -Server $vCenterServer `
        -Credential $vCenterCreds `
        -ErrorAction Stop | Out-Null
    Write-Host "[OK] Connected to vCenter: $vCenterServer" -ForegroundColor Green
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[ERROR] Failed to connect to vCenter: $ErrorMsg" -ForegroundColor Red
    exit 1
}

# ==============================================================================
# 2. VALIDATE CLUSTER EXISTS
# ==============================================================================

Write-Host "`n[STEP 2] Validating vCenter cluster..." -ForegroundColor Cyan

try {
    # Validate the cluster name before iterating hosts — fail fast with a clear
    # error rather than silently mounting to zero hosts
    $Cluster = Get-Cluster -Name $vCenterCluster -ErrorAction Stop
    Write-Host "[OK] Found cluster: $($Cluster.Name)" -ForegroundColor Green
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[ERROR] Cluster '$vCenterCluster' not found: $ErrorMsg" -ForegroundColor Red
    # Disconnect before exiting to avoid leaving an orphaned vCenter session
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false
    exit 1
}

# ==============================================================================
# 3. PRE-MOUNT DIAGNOSTICS (NFS 4.1)
# ==============================================================================

if ($NFSVersion -eq 'nfsv4') {
    Write-Host "`n[DIAGNOSTICS] Running NFS 4.1 pre-mount checks..." -ForegroundColor Cyan

    # Use one representative host for pre-flight checks — we assume the cluster
    # is homogeneous; a single host is enough to surface version or firewall issues
    $DiagHost = Get-Cluster -Name $vCenterCluster | Get-VMHost | Select-Object -First 1

    # NFS 4.1 requires vSphere 6.0+; nconnect (multi-session) requires vSphere 7.0 U1+.
    # Warn early so the user can abort before attempting mounts that will fail
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
    # rule is disabled the mount will silently fail or hang — surface this early
    Write-Host "  [CHECK] NFS Firewall Rules:" -ForegroundColor Gray
    $FirewallRules = Get-VMHostFirewallException -VMHost $DiagHost | Where-Object {$_.Name -like "*NFS*"}
    foreach ($Rule in $FirewallRules) {
        $Status = if ($Rule.Enabled) { "Enabled" } else { "DISABLED" }
        $Color = if ($Rule.Enabled) { "Gray" } else { "Yellow" }
        Write-Host "    $($Rule.Name): $Status" -ForegroundColor $Color
    }

    # Ping is issued via esxcli so it travels over the ESXi VMkernel network stack,
    # not the management network where this script runs. This verifies that the
    # NFS VIF is reachable from the dataplane path that ESXi will actually use
    Write-Host "  [CHECK] Network Connectivity:" -ForegroundColor Gray
    try {
        $EsxCli = Get-EsxCli -VMHost $DiagHost -V2
        $PingArgs = $EsxCli.network.diag.ping.CreateArgs()
        $PingArgs.host = $NFSHost
        $PingArgs.count = 3
        $PingResult = $EsxCli.network.diag.ping.Invoke($PingArgs)

        if ($PingResult.Summary.PacketLost -eq 0) {
            Write-Host "    Ping to ${NFSHost}: SUCCESS (0% loss)" -ForegroundColor Green
        } else {
            Write-Host "    Ping to ${NFSHost}: PARTIAL ($($PingResult.Summary.PacketLost)% loss)" -ForegroundColor Yellow
        }
    } catch {
        $ErrorMsg = $_.Exception.Message
        Write-Host "    Ping test failed: $ErrorMsg" -ForegroundColor Yellow
    }

    # NFS traffic must flow over a VMkernel adapter. Listing them (with MTU) helps
    # diagnose jumbo frame mismatches that cause silent throughput degradation
    Write-Host "  [CHECK] VMkernel Adapters:" -ForegroundColor Gray
    $VMKAdapters = Get-VMHostNetworkAdapter -VMHost $DiagHost -VMKernel
    foreach ($Adapter in $VMKAdapters) {
        Write-Host "    $($Adapter.Name): $($Adapter.IP) (MTU: $($Adapter.Mtu))" -ForegroundColor Gray
    }

    # Listing existing NFS v4.1 mounts provides context when troubleshooting a
    # failed mount — e.g., the same export may already be mounted under a
    # different datastore name, which would cause a duplicate-mount error
    Write-Host "  [CHECK] Existing NFS 4.1 Mounts:" -ForegroundColor Gray
    try {
        $ExistingNFS41 = $EsxCli.storage.nfs41.list.Invoke()
        if ($ExistingNFS41.Count -gt 0) {
            Write-Host "    Found $($ExistingNFS41.Count) existing NFS 4.1 datastore(s)" -ForegroundColor Gray
        } else {
            Write-Host "    No existing NFS 4.1 datastores" -ForegroundColor Gray
        }
    } catch {
        $ErrorMsg = $_.Exception.Message
        Write-Host "    Could not list NFS 4.1 datastores: $ErrorMsg" -ForegroundColor Yellow
    }

    Write-Host "  [INFO] Diagnostics complete`n" -ForegroundColor Cyan
}

# ==============================================================================
# 4. MOUNT NFS DATASTORE TO CLUSTER HOSTS
# ==============================================================================

Write-Host "`n[STEP 3] Mounting datastore to cluster hosts..." -ForegroundColor Cyan

# Sort hosts alphabetically for consistent, readable log output
$VMHosts = Get-Cluster -Name $vCenterCluster | Get-VMHost | Sort-Object Name
$MountedCount = 0
$FailedCount = 0

if ($VMHosts.Count -eq 0) {
    Write-Host "[ERROR] No hosts found in cluster '$vCenterCluster'" -ForegroundColor Red
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false
    exit 1
}

Write-Host "[INFO] Found $($VMHosts.Count) hosts in cluster" -ForegroundColor Gray

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
                # args, which avoids parameter-order bugs across ESXi versions
                $EsxCli = Get-EsxCli -VMHost $VMHost -V2

                $MountArgs = $EsxCli.storage.nfs41.add.CreateArgs()
<#
                # Display available parameters
                Write-Host "    [DEBUG] Available parameters for nfs41.add:" -ForegroundColor DarkGray
                $MountArgs | Get-Member -MemberType Property | ForEach-Object {
                    Write-Host "      - $($_.Name)" -ForegroundColor DarkGray
                }
#>
                $MountArgs.hosts = $NFSHost
                $MountArgs.share = $NFSExportPath
                $MountArgs.volumename = $DatastoreName
<#
                Write-Host "    [DEBUG] Mount parameters being set:" -ForegroundColor DarkGray
                Write-Host "      NFS Host:  $($MountArgs.hosts)" -ForegroundColor DarkGray
                Write-Host "      Share:     $($MountArgs.share)" -ForegroundColor DarkGray
                Write-Host "      Volume:    $($MountArgs.volumename)" -ForegroundColor DarkGray
#>
                # nconnect opens multiple TCP sessions to the NFS server, improving
                # throughput by parallelizing I/O. Setting connections on ESXi < 7.0 U1 
                # will throw an error, so it's wrapped in its own try/catch to fail
                # gracefully to a single-session mount instead of aborting entirely
                if ($NconnectSessions -gt 1) {
                    try {
                        $MountArgs.connections = $NconnectSessions
                        Write-Host "      Nconnect: $($MountArgs.connections)" -ForegroundColor DarkGray
                    } catch {
                        Write-Host "    [WARNING] Nconnect not supported on this ESXi version" -ForegroundColor Yellow
                    }
                }
<#
                # Display all argument values before invoking
                Write-Host "    [DEBUG] All argument values before invoke:" -ForegroundColor DarkGray
                $MountArgs | Get-Member -MemberType Property | ForEach-Object {
                    $PropName = $_.Name
                    $PropValue = $MountArgs.$PropName
                    if ($null -ne $PropValue -and $PropValue -ne "") {
                        Write-Host "      $PropName = $PropValue" -ForegroundColor DarkGray
                    } else {
                        Write-Host "      $PropName = <null or empty>" -ForegroundColor DarkGray
                    }
                }
#>
                Write-Host "    [DEBUG] Executing mount command, please wait..." -ForegroundColor DarkGray
                $MountResult = $EsxCli.storage.nfs41.add.Invoke($MountArgs)

                # esxcli returns success even if the underlying mount is still
                # in progress; wait briefly so vCenter's inventory catches up
                # before checking for the datastore object
                Start-Sleep -Seconds 10
                $VerifyDS = Get-Datastore -Name $DatastoreName -VMHost $VMHost -ErrorAction SilentlyContinue

                if ($VerifyDS) {
                    Write-Host "    [OK] Mounted with NFS 4.1 (nconnect: $NconnectSessions)" -ForegroundColor Green
                    Write-Host "    [DEBUG] Datastore capacity: $([math]::Round($VerifyDS.CapacityGB, 2)) GB" -ForegroundColor DarkGray
                } else {
                    throw "Mount command succeeded but datastore not visible"
                }
            } catch {
                # Fall back to the PowerCLI New-Datastore cmdlet if esxcli fails.
                # This path loses nconnect support but keeps the mount attempt alive
                # on hosts where the esxcli API differs (e.g., older builds)
                $ErrorMsg = $_.Exception.Message
                Write-Host "    [WARNING] esxcli mount failed: $ErrorMsg" -ForegroundColor Yellow
                Write-Host "`n    [INFO] Trying PowerCLI New-Datastore method..." -ForegroundColor Gray

                try {
                    New-Datastore -Nfs -VMHost $VMHost `
                        -Name $DatastoreName `
                        -Path $NFSExportPath `
                        -NfsHost $NFSHost `
                        -FileSystemVersion "4.1" `
                        -ErrorAction Stop | Out-Null

                    Write-Host "    [OK] Mounted with NFS 4.1 (PowerCLI method)" -ForegroundColor Green
                } catch {
                    $ErrorMsg2 = $_.Exception.Message
                    Write-Host "    [ERROR] PowerCLI mount also failed: $ErrorMsg2" -ForegroundColor Red
                    Write-Host "    [TROUBLESHOOTING] Check:" -ForegroundColor Yellow
                    Write-Host "      1. ESXi version supports NFS 4.1 (6.0+)" -ForegroundColor Yellow
                    Write-Host "      2. NFS 4.1 firewall rule is enabled" -ForegroundColor Yellow
                    Write-Host "      3. Network connectivity to $NFSHost" -ForegroundColor Yellow
                    Write-Host "      4. Export path is correct: $NFSExportPath" -ForegroundColor Yellow
                    throw
                }
            }
        } else {
            # NFSv3 uses the standard PowerCLI cmdlet — nconnect is not applicable
            # for NFS 3, and New-Datastore is sufficient for all supported ESXi versions
            Write-Host "    [DEBUG] Using NFS 3.0 mount" -ForegroundColor DarkGray
            New-Datastore -Nfs -VMHost $VMHost `
                -Name $DatastoreName `
                -Path $NFSExportPath `
                -NfsHost $NFSHost `
                -FileSystemVersion "3.0" `
                -ErrorAction Stop | Out-Null

            Write-Host "    [OK] Mounted with NFS 3" -ForegroundColor Green
        }

        $MountedCount++
    } catch {
        # Per-host failures are counted but do not stop the loop — the script
        # continues mounting remaining hosts and reports a full tally at the end
        $ErrorMsg = $_.Exception.Message
        Write-Host "    [ERROR] Failed to mount on $($VMHost.Name)" -ForegroundColor Red
        Write-Host "    [ERROR] Error details: $ErrorMsg" -ForegroundColor Red
        $FailedCount++
    }
}

Write-Host "`n[INFO] Mount Summary:" -ForegroundColor Cyan
Write-Host "  Successfully mounted: $MountedCount hosts" -ForegroundColor Green
if ($FailedCount -gt 0) {
    Write-Host "  Failed to mount: $FailedCount hosts" -ForegroundColor Red
}

# ==============================================================================
# 5. VERIFY DATASTORE
# ==============================================================================

Write-Host "`n[STEP 4] Verifying datastore..." -ForegroundColor Cyan

try {
    # Query vCenter for the datastore object to confirm it is registered and
    # visible in the inventory — not just that the individual mount commands returned success
    $Datastore = Get-Datastore -Name $DatastoreName -ErrorAction Stop

    # Retrieve the host list associated with this datastore to confirm the mount
    # count matches expectations (should equal $MountedCount)
    $DatastoreHosts = $Datastore | Get-VMHost

    Write-Host "[OK] Datastore verified" -ForegroundColor Green
    Write-Host "  Name: $($Datastore.Name)" -ForegroundColor Gray
    Write-Host "  Type: $($Datastore.Type)" -ForegroundColor Gray
    Write-Host "  Capacity: $([math]::Round($Datastore.CapacityGB, 2)) GB" -ForegroundColor Gray
    Write-Host "  Free Space: $([math]::Round($Datastore.FreeSpaceGB, 2)) GB" -ForegroundColor Gray
    Write-Host "  Mounted on: $($DatastoreHosts.Count) hosts" -ForegroundColor Gray
} catch {
    # Verification failure is a warning rather than fatal — mounts may still be
    # usable even if vCenter inventory hasn't fully refreshed yet
    $ErrorMsg = $_.Exception.Message
    Write-Host "[WARNING] Could not verify datastore: $ErrorMsg" -ForegroundColor Yellow
}

# ==============================================================================
# 6. CLEANUP AND SUMMARY
# ==============================================================================

Write-Host "`n[STEP 5] Disconnecting..." -ForegroundColor Cyan

# -Confirm:$false suppresses the interactive "are you sure?" prompt that
# Disconnect-VIServer shows by default; -ErrorAction SilentlyContinue prevents
# a noisy error if the session already timed out
try {
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[OK] Disconnected from vCenter" -ForegroundColor Green
} catch {
    Write-Host "[WARNING] Failed to disconnect from vCenter" -ForegroundColor Yellow
}

# ==============================================================================
# SUMMARY
# ==============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Datastore Name:       $DatastoreName" -ForegroundColor White
Write-Host "NFS Export Path:      $NFSExportPath" -ForegroundColor White
Write-Host "NFS Host:             $NFSHost" -ForegroundColor White
Write-Host "NFS Version:          $NFSVersion" -ForegroundColor White
if ($NFSVersion -eq 'nfsv4') {
    Write-Host "Nconnect Sessions:    $NconnectSessions" -ForegroundColor White
}
Write-Host "vCenter Cluster:      $vCenterCluster" -ForegroundColor White
Write-Host "Hosts Mounted:        $MountedCount" -ForegroundColor White
if ($FailedCount -gt 0) {
    Write-Host "Hosts Failed:         $FailedCount" -ForegroundColor Red
}
Write-Host "========================================`n" -ForegroundColor Cyan

if ($MountedCount -gt 0) {
    Write-Host "[SUCCESS] NFS datastore mount completed!`n" -ForegroundColor Green
} else {
    # Exit with a non-zero code when zero hosts were mounted so that calling
    # scripts or CI pipelines can detect a total failure rather than treating
    # an empty mount as a success
    Write-Host "[FAILED] No hosts were successfully mounted!`n" -ForegroundColor Red
    exit 1
}

