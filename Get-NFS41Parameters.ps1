<#
.SYNOPSIS
    Displays available parameters for esxcli storage nfs41 add command

.DESCRIPTION
    This diagnostic script connects to vCenter and displays all available
    parameters for the NFS 4.1 mount command, including which are required.

.PARAMETER vCenterServer
    vCenter Server FQDN or IP

.PARAMETER vCenterCredPath
    Path to vCenter credentials XML file

.EXAMPLE
    .\Get-NFS41Parameters.ps1 -vCenterServer "vc02.fsa.lab"

.NOTES
    Author: David Stevens
    Requires: VMware.PowerCLI
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$vCenterServer,
    
    [Parameter(Mandatory=$false)]
    [string]$vCenterCredPath = "$HOME/Documents/creds/vCenter-creds.xml"
)

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "NFS 4.1 PARAMETER INSPECTOR" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Connect to vCenter
Write-Host "[STEP 1] Connecting to vCenter..." -ForegroundColor Cyan
try {
    $vCenterCreds = Import-CliXml -Path $vCenterCredPath -ErrorAction Stop
    Connect-VIServer -Server $vCenterServer `
        -Credential $vCenterCreds `
        -ErrorAction Stop | Out-Null
    Write-Host "[OK] Connected to vCenter: $vCenterServer" -ForegroundColor Green
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[ERROR] Failed to connect to vCenter: $ErrorMsg" -ForegroundColor Red
    exit 1
}

# Get first host
Write-Host "`n[STEP 2] Getting ESXi host..." -ForegroundColor Cyan
try {
    $VMHost = Get-VMHost | Select-Object -First 1
    Write-Host "[OK] Using host: $($VMHost.Name)" -ForegroundColor Green
    Write-Host "     Version: $($VMHost.Version)" -ForegroundColor Gray
    Write-Host "     Build: $($VMHost.Build)" -ForegroundColor Gray
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[ERROR] Failed to get host: $ErrorMsg" -ForegroundColor Red
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false
    exit 1
}

# Get esxcli interface
Write-Host "`n[STEP 3] Getting esxcli interface..." -ForegroundColor Cyan
try {
    $EsxCli = Get-EsxCli -VMHost $VMHost -V2
    Write-Host "[OK] esxcli interface obtained" -ForegroundColor Green
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[ERROR] Failed to get esxcli: $ErrorMsg" -ForegroundColor Red
    Disconnect-VIServer -Server $vCenterServer -Confirm:$false
    exit 1
}

# Display help for nfs41.add
Write-Host "`n[STEP 4] Getting help for storage.nfs41.add..." -ForegroundColor Cyan
try {
    $HelpText = $EsxCli.storage.nfs41.add.Help()
    Write-Host "`n$HelpText" -ForegroundColor White
} catch {
    Write-Host "[WARNING] Could not retrieve help text" -ForegroundColor Yellow
}

# Create args and inspect
Write-Host "`n[STEP 5] Inspecting available parameters..." -ForegroundColor Cyan
try {
    $Args = $EsxCli.storage.nfs41.add.CreateArgs()
    
    Write-Host "`nAvailable Parameters:" -ForegroundColor White
    Write-Host "=====================" -ForegroundColor White
    
    $Args | Get-Member -MemberType Property | ForEach-Object {
        $PropName = $_.Name
        $PropValue = $Args.$PropName
        $PropType = $_.Definition -replace '^(\S+)\s.*','$1'
        
        Write-Host "  Parameter: $PropName" -ForegroundColor Cyan
        Write-Host "    Type: $PropType" -ForegroundColor Gray
        Write-Host "    Default: $PropValue" -ForegroundColor Gray
        Write-Host ""
    }
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[ERROR] Failed to inspect parameters: $ErrorMsg" -ForegroundColor Red
}

# List existing NFS 4.1 mounts
Write-Host "`n[STEP 6] Listing existing NFS 4.1 mounts..." -ForegroundColor Cyan
try {
    $ExistingMounts = $EsxCli.storage.nfs41.list.Invoke()
    
    if ($ExistingMounts.Count -gt 0) {
        Write-Host "[OK] Found $($ExistingMounts.Count) existing NFS 4.1 mount(s):" -ForegroundColor Green
        $ExistingMounts | Format-Table -AutoSize
    } else {
        Write-Host "[INFO] No existing NFS 4.1 mounts found" -ForegroundColor Gray
    }
} catch {
    $ErrorMsg = $_.Exception.Message
    Write-Host "[WARNING] Could not list NFS 4.1 mounts: $ErrorMsg" -ForegroundColor Yellow
}

# Disconnect
Write-Host "`n[STEP 7] Disconnecting..." -ForegroundColor Cyan
Disconnect-VIServer -Server $vCenterServer -Confirm:$false
Write-Host "[OK] Disconnected from vCenter" -ForegroundColor Green

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "INSPECTION COMPLETE" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

