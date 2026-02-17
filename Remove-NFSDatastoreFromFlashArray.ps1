<#
.SYNOPSIS
    Cleans up FlashArray resources created by New-NFSDatastore.ps1 after a failed run.

.DESCRIPTION
    This script removes the NFS file system and all associated policies from the Pure Storage FlashArray.
    It does NOT unmount the datastore from vCenter/ESXi hosts - only removes FlashArray resources.
    
    Resources removed:
    - Policy assignments (NFS export, quota, snapshot, autodir)
    - NFS export policy and rules
    - Quota policy and rules
    - Snapshot policy and rules
    - Autodir policy
    - File system (and managed directory)

.PARAMETER DatastoreName
    Name of the datastore/file system to remove (must match the name used in New-NFSDatastore.ps1)

.PARAMETER FlashArrayEndpoint
    FQDN or IP address of the Pure Storage FlashArray

.PARAMETER FlashArrayCredPath
    Path to the FlashArray credentials XML file

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\Remove-NFSDatastoreFromFlashArray.ps1 -DatastoreName "Test-NFS-DS" -FlashArrayEndpoint "sn1-x90r2-f07-27.fsa.lab"

.EXAMPLE
    .\Remove-NFSDatastoreFromFlashArray.ps1 -DatastoreName "Test-NFS-DS" -FlashArrayEndpoint "sn1-x90r2-f07-27.fsa.lab" -Force

.NOTES
    Author: David Stevens
    Requires: PureStoragePowerShellSDK2
    WARNING: This will permanently ERADICATE the file system and all data!
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true)]
    [string]$DatastoreName,
    
    [Parameter(Mandatory=$true)]
    [string]$FlashArrayEndpoint,
    
    [Parameter(Mandatory=$false)]
    [string]$FlashArrayCredPath = "$HOME/Documents/creds/FA-creds.xml",
    
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

# ==============================================================================
# 1. LOAD MODULES AND CONNECT
# ==============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "FlashArray NFS Cleanup Script" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Import required module
try {
    Import-Module PureStoragePowerShellSDK2 -ErrorAction Stop
    Write-Host "[OK] Module loaded successfully" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to load PureStoragePowerShellSDK2 module: $_" -ForegroundColor Red
    exit 1
}

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
# 2a. VERIFY FILE SYSTEM EXISTS
# ==============================================================================

Write-Host "`n[STEP 2] Verifying file system exists..." -ForegroundColor Cyan

try {
    $FileSystem = Get-Pfa2FileSystem -Array $FlashArray -Name $DatastoreName -ErrorAction Stop
    Write-Host "[OK] Found file system: $($FileSystem.Name)" -ForegroundColor Green
    
    # Get the root managed directory
    $RootManagedDirectory = Get-Pfa2Directory -Array $FlashArray -FileSystemName $FileSystem.Name -ErrorAction Stop
    Write-Host "[OK] Found managed directory: $($RootManagedDirectory.Name)" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] File system '$DatastoreName' not found: $_" -ForegroundColor Red
    Disconnect-Pfa2Array -Array $FlashArray
    exit 1
}

# ==============================================================================
# 2b. CONFIRMATION
# ==============================================================================

if (-not $Force) {
    Write-Host "`n[WARNING] This will permanently ERADICATE the following resources:" -ForegroundColor Yellow
    Write-Host "  - File System: $DatastoreName" -ForegroundColor Yellow
    Write-Host "  - All policies associated with this file system" -ForegroundColor Yellow
    Write-Host "  - ALL DATA in the file system will be lost!" -ForegroundColor Red
    Write-Host ""
    $Confirmation = Read-Host "Type 'DELETEALLALLMYDATA' to confirm"
    
    if ($Confirmation -ne 'DELETEALLALLMYDATA') {
        Write-Host "`n[CANCELLED] Cleanup aborted by user" -ForegroundColor Yellow
        Disconnect-Pfa2Array -Array $FlashArray
        exit 0
    }
}

Write-Host "`n[STEP 3] Starting cleanup process..." -ForegroundColor Cyan

# ==============================================================================
# 3. REMOVE MANAGED DIRECTORY EXPORT
# ==============================================================================

Write-Host "`n[STEP 3] Removing Managed Directory Export..." -ForegroundColor Cyan

# Remove NFS export
try {
    $NfsAssignment = Get-Pfa2DirectoryPolicyNfs -Array $FlashArray -MemberName $RootManagedDirectory.Name -ErrorAction SilentlyContinue
    if ($RootManagedDirectory.Name) {
        Remove-Pfa2DirectoryExport -Array $FlashArray -ExportName $DatastoreName -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Removed NFS export" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] No NFS export found" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [WARNING] Failed to remove NFS export $_" -ForegroundColor Yellow
}

# ==============================================================================
# 4. REMOVE FILE SYSTEM
# ==============================================================================

Write-Host "`n[STEP 4] Removing file system..." -ForegroundColor Cyan

try {
    Remove-Pfa2FileSystem -Array $FlashArray -Name $DatastoreName -ErrorAction Stop | Out-Null
    Remove-Pfa2FileSystem -Array $FlashArray -Name $DatastoreName -Eradicate -Confirm:$false -ErrorAction Stop 
    Write-Host "  [OK] File system eradicated: $DatastoreName" -ForegroundColor Green
} catch {
    Write-Host "  [ERROR] Failed to remove file system: $_" -ForegroundColor Red
    Write-Host "  [INFO] You may need to manually remove the file system from the FlashArray GUI" -ForegroundColor Yellow
}

<#
# ==============================================================================
# 5. REMOVE POLICY ASSIGNMENTS
# ==============================================================================

Write-Host "`n[STEP 5] Removing policy assignments..." -ForegroundColor Cyan

# Remove NFS export policy assignment
try {
    $NfsAssignment = Get-Pfa2DirectoryPolicyNfs -Array $FlashArray -MemberName $RootManagedDirectory.Name -ErrorAction SilentlyContinue
    if ($RootManagedDirectory.Name) {
        Remove-Pfa2DirectoryPolicyNfs -Array $FlashArray -MemberName $RootManagedDirectory.Name -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Removed NFS export policy assignment" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] No NFS export policy assignment found" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [WARNING] Failed to remove NFS export policy assignment: $_" -ForegroundColor Yellow
}

# Remove quota policy assignment
try {
    $QuotaAssignment = Get-Pfa2DirectoryPolicyQuota -Array $FlashArray -MemberName $RootManagedDirectory.Name -ErrorAction SilentlyContinue
    if ($QuotaAssignment) {
        Remove-Pfa2DirectoryPolicyQuota -Array $FlashArray -MemberName $RootManagedDirectory.Name -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Removed quota policy assignment" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] No quota policy assignment found" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [WARNING] Failed to remove quota policy assignment: $_" -ForegroundColor Yellow
}

# Remove snapshot policy assignment
try {
    $SnapshotAssignment = Get-Pfa2DirectoryPolicySnapshot -Array $FlashArray -MemberName $RootManagedDirectory.Name -ErrorAction SilentlyContinue
    if ($SnapshotAssignment) {
        Remove-Pfa2DirectoryPolicySnapshot -Array $FlashArray -MemberName $RootManagedDirectory.Name -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Removed snapshot policy assignment" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] No snapshot policy assignment found" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [WARNING] Failed to remove snapshot policy assignment: $_" -ForegroundColor Yellow
}

# Remove autodir policy assignment
try {
    $AutodirAssignment = Get-Pfa2DirectoryPolicyAutodir -Array $FlashArray -MemberName $RootManagedDirectory.Name -ErrorAction SilentlyContinue
    if ($AutodirAssignment) {
        Remove-Pfa2DirectoryPolicyAutodir -Array $FlashArray -MemberName $RootManagedDirectory.Name -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Removed autodir policy assignment" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] No autodir policy assignment found" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [WARNING] Failed to remove autodir policy assignment: $_" -ForegroundColor Yellow
}
#>

# ==============================================================================
# 5. REMOVE POLICIES
# ==============================================================================

Write-Host "`n[STEP 5] Removing policies..." -ForegroundColor Cyan

# Remove NFS export policy
try {
    $NfsPolicy = Get-Pfa2PolicyNfs -Array $FlashArray -Name "$($DatastoreName)-export-policy" -ErrorAction SilentlyContinue
    if ($NfsPolicy) {
        Remove-Pfa2PolicyNfs -Array $FlashArray -Name "$($DatastoreName)-export-policy" -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Removed NFS export policy" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] No NFS export policy found" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [WARNING] Failed to remove NFS export policy: $_" -ForegroundColor Yellow
}

# Remove quota policy
try {
    $QuotaPolicy = Get-Pfa2PolicyQuota -Array $FlashArray -Name "$($DatastoreName)-quota-policy" -ErrorAction SilentlyContinue
    if ($QuotaPolicy) {
        Remove-Pfa2PolicyQuota -Array $FlashArray -Name "$($DatastoreName)-quota-policy" -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Removed quota policy" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] No quota policy found" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [WARNING] Failed to remove quota policy: $_" -ForegroundColor Yellow
}

# Remove snapshot policy
try {
    $SnapshotPolicy = Get-Pfa2PolicySnapshot -Array $FlashArray -Name "$($DatastoreName)-snapshot-policy" -ErrorAction SilentlyContinue
    if ($SnapshotPolicy) {
        Remove-Pfa2PolicySnapshot -Array $FlashArray -Name "$($DatastoreName)-snapshot-policy" -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Removed snapshot policy" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] No snapshot policy found" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [WARNING] Failed to remove snapshot policy: $_" -ForegroundColor Yellow
}

# Remove autodir policy
try {
    $AutodirPolicy = Get-Pfa2PolicyAutodir -Array $FlashArray -Name "$($DatastoreName)-autodir-policy" -ErrorAction SilentlyContinue
    if ($AutodirPolicy) {
        Remove-Pfa2PolicyAutodir -Array $FlashArray -Name "$($DatastoreName)-autodir-policy" -ErrorAction Stop | Out-Null
        Write-Host "  [OK] Removed autodir policy" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] No autodir policy found" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [WARNING] Failed to remove autodir policy: $_" -ForegroundColor Yellow
}

# ==============================================================================
# 6. DISCONNECT AND SUMMARY
# ==============================================================================

Write-Host "`n[STEP 6] Disconnecting..." -ForegroundColor Cyan

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
Write-Host "CLEANUP SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "File System:          $DatastoreName" -ForegroundColor White
Write-Host "FlashArray:           $FlashArrayEndpoint" -ForegroundColor White
Write-Host "Status:               Cleanup completed" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "[SUCCESS] FlashArray resources have been removed!`n" -ForegroundColor Green
#Write-Host "[NOTE] If the datastore was mounted to vCenter/ESXi hosts," -ForegroundColor Yellow
#Write-Host "       you will need to manually unmount it from each host.`n" -ForegroundColor Yellow

