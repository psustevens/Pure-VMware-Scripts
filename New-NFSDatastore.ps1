<#
.SYNOPSIS
    Mounts an existing NFS export from Pure Storage FlashArray to a vCenter cluster.

.DESCRIPTION
    This script connects to vCenter and mounts an existing NFS export (from FlashArray or any NFS server)
    to all ESXi hosts in a specified vCenter cluster. It assumes the NFS export already exists.

.PARAMETER DatastoreName
    Name of the NFS datastore to create in vCenter

.PARAMETER NFSExportPath
    NFS export path (e.g., /datastore-name)

.PARAMETER NFSHost
    FQDN or IP address of the NFS server (FlashArray VIF)

.PARAMETER vCenterCluster
    Name of the vCenter cluster to mount the datastore to

.PARAMETER vCenterServer
    FQDN or IP address of the vCenter Server

.PARAMETER NFSVersion
    NFS version to use: 'nfsv3' or 'nfsv4' (default: nfsv3)

.PARAMETER NconnectSessions
    Number of nconnect sessions for NFS 4.1 (default: 4, range: 1-8)

.PARAMETER vCenterCredPath
    Path to vCenter credentials XML file

.EXAMPLE
    .\New-NFSv3Datastore.ps1 -DatastoreName "NFS-DS-01" -NFSExportPath "/NFS-DS-01" -NFSHost "array.domain.com" -vCenterCluster "Cluster01" -vCenterServer "vcenter.domain.com"

.EXAMPLE
    .\New-NFSv3Datastore.ps1 -DatastoreName "NFS-DS-02" -NFSExportPath "/NFS-DS-02" -NFSHost "10.0.0.100" -vCenterCluster "Cluster01" -vCenterServer "vcenter.domain.com" -NFSVersion nfsv4 -NconnectSessions 8

.NOTES
    Author: David Stevens
    Requires: VMware.PowerCLI, specifically VMware.VimAutomation.Core
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DatastoreName,
    
    [Parameter(Mandatory=$true)]
    [string]$NFSExportPath,
    
    [Parameter(Mandatory=$true)]
    [string]$NFSHost,
    
    [Parameter(Mandatory=$true)]
    [string]$vCenterCluster,
    
    [Parameter(Mandatory=$true)]
    [string]$vCenterServer,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('nfsv3','nfsv4')]
    [string]$NFSVersion = 'nfsv3',
    
    [Parameter(Mandatory=$false)]
    [ValidateRange(1,8)]
    [int]$NconnectSessions = 4,

    [Parameter(Mandatory=$false)]
    [string]$vCenterCredPath = "$HOME/Documents/creds/vCenter-creds.xml"
)

# ==============================================================================
# SCRIPT INITIALIZATION
# ==============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "NFS DATASTORE MOUNT SCRIPT" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Import required module
try {
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    Write-Host "[OK] Module loaded successfully" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to load required module: $_" -ForegroundColor Red
    exit 1
}

# ==============================================================================
# 1. CONNECT TO VCENTER
# ==============================================================================

Write-Host "[STEP 1] Connecting to vCenter..." -ForegroundColor Cyan

try {
    $vCenterCreds = Import-CliXml -Path $vCenterCredPath -ErrorAction Stop
    Connect-VIServer -Server $vCenterServer `
        -Credential $vCenterCreds `
        -ErrorAction Stop | Out-Null
    Write-Host "[OK] Connected to vCenter: $vCenterServer" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to connect to vCenter: $_" -ForegroundColor Red
    exit 1
}

# ==============================================================================
# 2. VALIDATE CLUSTER EXISTS
# ==============================================================================

Write-Host "`n[STEP 2] Validating vCenter cluster..." -ForegroundColor Cyan

try {
    $Cluster = Get-Cluster -Name $vCenterCluster -ErrorAction Stop
    Write-Host "[OK] Found cluster: $($Cluster.Name)" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Cluster '$vCenterCluster' not found: $_" -ForegroundColor Red
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false
    exit 1
}

# ==============================================================================
# 3. PRE-MOUNT DIAGNOSTICS (NFS 4.1)
# ==============================================================================

if ($NFSVersion -eq 'nfsv4') {
    Write-Host "`n[DIAGNOSTICS] Running NFS 4.1 pre-mount checks..." -ForegroundColor Cyan
    
    # Get first host for diagnostics
    $DiagHost = Get-Cluster -Name $vCenterCluster | Get-VMHost | Select-Object -First 1
    
    # Check ESXi version
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

    # Check NFS firewall rules
    Write-Host "  [CHECK] NFS Firewall Rules:" -ForegroundColor Gray
    $FirewallRules = Get-VMHostFirewallException -VMHost $DiagHost | Where-Object {$_.Name -like "*NFS*"}
    foreach ($Rule in $FirewallRules) {
        $Status = if ($Rule.Enabled) { "Enabled" } else { "DISABLED" }
        $Color = if ($Rule.Enabled) { "Gray" } else { "Yellow" }
        Write-Host "    $($Rule.Name): $Status" -ForegroundColor $Color
    }

    # Check network connectivity
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
        Write-Host "    Ping test failed: $_" -ForegroundColor Yellow
    }

    # Check VMkernel adapters
    Write-Host "  [CHECK] VMkernel Adapters:" -ForegroundColor Gray
    $VMKAdapters = Get-VMHostNetworkAdapter -VMHost $DiagHost -VMKernel
    foreach ($Adapter in $VMKAdapters) {
        Write-Host "    $($Adapter.Name): $($Adapter.IP) (MTU: $($Adapter.Mtu))" -ForegroundColor Gray
    }

    # Check existing NFS 4.1 mounts
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
# 4. MOUNT NFS DATASTORE TO CLUSTER HOSTS
# ==============================================================================

Write-Host "`n[STEP 3] Mounting datastore to cluster hosts..." -ForegroundColor Cyan

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
            # NFS 4.1 with nconnect
            try {
                Write-Host "    [DEBUG] Using esxcli method for NFS 4.1" -ForegroundColor DarkGray

                # Mount NFS 4.1 datastore using esxcli for better control
                $EsxCli = Get-EsxCli -VMHost $VMHost -V2

                # Create arguments for NFS 4.1 mount
                $MountArgs = $EsxCli.storage.nfs41.add.CreateArgs()
                $MountArgs.host = $NFSHost
                $MountArgs.share = $NFSExportPath
                $MountArgs.volumename = $DatastoreName

                Write-Host "    [DEBUG] Mount parameters:" -ForegroundColor DarkGray
                Write-Host "      NFS Host:  $($MountArgs.host)" -ForegroundColor DarkGray
                Write-Host "      Share:     $($MountArgs.share)" -ForegroundColor DarkGray
                Write-Host "      Volume:    $($MountArgs.volumename)" -ForegroundColor DarkGray

                # Add nconnect parameter if supported (vSphere 7.0 U1+)
                if ($NconnectSessions -gt 1) {
                    try {
                        # Try to set nconnect - may not be supported on all versions
                        $MountArgs.nconnect = $NconnectSessions
                        Write-Host "      Nconnect: $($MountArgs.nconnect)" -ForegroundColor DarkGray
                    } catch {
                        Write-Host "    [WARNING] Nconnect not supported on this ESXi version" -ForegroundColor Yellow
                    }
                }

                # Mount the datastore
                Write-Host "    [DEBUG] Executing mount command..." -ForegroundColor DarkGray
                $MountResult = $EsxCli.storage.nfs41.add.Invoke($MountArgs)

                # Verify mount succeeded
                Start-Sleep -Seconds 5
                $VerifyDS = Get-Datastore -Name $DatastoreName -VMHost $VMHost -ErrorAction SilentlyContinue

                if ($VerifyDS) {
                    Write-Host "    [OK] Mounted with NFS 4.1 (nconnect: $NconnectSessions)" -ForegroundColor Green
                    Write-Host "    [DEBUG] Datastore capacity: $([math]::Round($VerifyDS.CapacityGB, 2)) GB" -ForegroundColor DarkGray
                } else {
                    throw "Mount command succeeded but datastore not visible"
                }
            } catch {
                # Fallback to PowerCLI cmdlet if esxcli fails
                Write-Host "    [WARNING] esxcli mount failed: $_" -ForegroundColor Yellow
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
                    Write-Host "    [ERROR] PowerCLI mount also failed: $_" -ForegroundColor Red
                    Write-Host "    [TROUBLESHOOTING] Check:" -ForegroundColor Yellow
                    Write-Host "      1. ESXi version supports NFS 4.1 (6.0+)" -ForegroundColor Yellow
                    Write-Host "      2. NFS 4.1 firewall rule is enabled" -ForegroundColor Yellow
                    Write-Host "      3. Network connectivity to $NFSHost" -ForegroundColor Yellow
                    Write-Host "      4. Export path is correct: $NFSExportPath" -ForegroundColor Yellow
                    throw
                }
            }
        } else {
            # NFS 3
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
        Write-Host "    [ERROR] Failed to mount on $($VMHost.Name)" -ForegroundColor Red
        Write-Host "    [ERROR] Error details: $_" -ForegroundColor Red
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
# 6. CLEANUP AND SUMMARY
# ==============================================================================

Write-Host "`n[STEP 5] Disconnecting..." -ForegroundColor Cyan

# Disconnect from vCenter
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
    Write-Host "[FAILED] No hosts were successfully mounted!`n" -ForegroundColor Red
    exit 1
}

