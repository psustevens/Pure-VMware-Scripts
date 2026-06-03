<#
.SYNOPSIS
    Sets up credentials for Everpure FlashArray and vCenter Server.

.DESCRIPTION
    This script prompts for FlashArray and vCenter credentials and exports them
    to encrypted XML files for use by other scripts in this repository.
    
    The credentials are encrypted using Windows Data Protection API (DPAPI) and can
    only be decrypted by the same user on the same computer where they were created.

.PARAMETER CredsPath
    Directory path where credential files will be saved (default: $HOME/Documents/creds)

.PARAMETER FlashArrayOnly
    Only set up FlashArray credentials

.PARAMETER vCenterOnly
    Only set up vCenter credentials

.EXAMPLE
    .\Setup-Credentials.ps1
    Prompts for both FlashArray and vCenter credentials

.EXAMPLE
    .\Setup-Credentials.ps1 -CredsPath "C:\SecureCreds"
    Saves credentials to a custom directory

.EXAMPLE
    .\Setup-Credentials.ps1 -FlashArrayOnly
    Only prompts for and saves FlashArray credentials

.NOTES
    Author: David Stevens - Everpure
    
    Security Notes:
    - Credential files are encrypted using Windows DPAPI
    - Files can only be decrypted by the same user on the same computer
    - Store credential files in a secure location with appropriate permissions
    - Do not commit credential files to version control
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$CredsPath = "$HOME/Documents/creds",

    [Parameter(Mandatory=$false)]
    [switch]$FlashArrayOnly,

    [Parameter(Mandatory=$false)]
    [switch]$vCenterOnly
)

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "CREDENTIAL SETUP SCRIPT" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Create credentials directory if it doesn't exist
Write-Host "[INFO] Credentials directory: $CredsPath" -ForegroundColor Yellow

if (-not (Test-Path $CredsPath)) {
    try {
        New-Item -ItemType Directory -Path $CredsPath -Force | Out-Null
        Write-Host "[OK] Created credentials directory" -ForegroundColor Green
    } catch {
        $ErrorMsg = $_.Exception.Message
        Write-Host "[ERROR] Failed to create directory: $ErrorMsg" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[OK] Credentials directory exists" -ForegroundColor Green
}

# Setup FlashArray credentials
if (-not $vCenterOnly) {
    Write-Host "`n[STEP 1] FlashArray Credentials" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    $FACredPath = Join-Path $CredsPath "FA-creds.xml"
    
    # Check if credentials already exist
    if (Test-Path $FACredPath) {
        Write-Host "[WARNING] FlashArray credentials already exist at:" -ForegroundColor Yellow
        Write-Host "          $FACredPath" -ForegroundColor Yellow
        
        $Overwrite = Read-Host "Do you want to overwrite them? (y/n)"
        if ($Overwrite -ne 'y') {
            Write-Host "[INFO] Skipping FlashArray credentials" -ForegroundColor Gray
        } else {
            Write-Host "`nEnter FlashArray credentials:" -ForegroundColor Cyan
            $FACreds = Get-Credential -Message "FlashArray Login (e.g., pureuser)"
            
            try {
                $FACreds | Export-CliXml -Path $FACredPath -Force
                Write-Host "[OK] FlashArray credentials saved" -ForegroundColor Green
                Write-Host "    Location: $FACredPath" -ForegroundColor Gray
                Write-Host "    Username: $($FACreds.UserName)" -ForegroundColor Gray
            } catch {
                $ErrorMsg = $_.Exception.Message
                Write-Host "[ERROR] Failed to save credentials: $ErrorMsg" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "`nEnter FlashArray credentials:" -ForegroundColor Cyan
        $FACreds = Get-Credential -Message "FlashArray Login (e.g., pureuser)"
        
        try {
            $FACreds | Export-CliXml -Path $FACredPath
            Write-Host "[OK] FlashArray credentials saved" -ForegroundColor Green
            Write-Host "    Location: $FACredPath" -ForegroundColor Gray
            Write-Host "    Username: $($FACreds.UserName)" -ForegroundColor Gray
        } catch {
            $ErrorMsg = $_.Exception.Message
            Write-Host "[ERROR] Failed to save credentials: $ErrorMsg" -ForegroundColor Red
        }
    }
}

# Setup vCenter credentials
if (-not $FlashArrayOnly) {
    Write-Host "`n[STEP 2] vCenter Credentials" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    $vCenterCredPath = Join-Path $CredsPath "vCenter-creds.xml"
    
    # Check if credentials already exist
    if (Test-Path $vCenterCredPath) {
        Write-Host "[WARNING] vCenter credentials already exist at:" -ForegroundColor Yellow
        Write-Host "          $vCenterCredPath" -ForegroundColor Yellow
        
        $Overwrite = Read-Host "Do you want to overwrite them? (y/n)"
        if ($Overwrite -ne 'y') {
            Write-Host "[INFO] Skipping vCenter credentials" -ForegroundColor Gray
        } else {
            Write-Host "`nEnter vCenter credentials:" -ForegroundColor Cyan
            $vCenterCreds = Get-Credential -Message "vCenter Login (e.g., administrator@vsphere.local)"
            
            try {
                $vCenterCreds | Export-CliXml -Path $vCenterCredPath -Force
                Write-Host "[OK] vCenter credentials saved" -ForegroundColor Green
                Write-Host "    Location: $vCenterCredPath" -ForegroundColor Gray
                Write-Host "    Username: $($vCenterCreds.UserName)" -ForegroundColor Gray
            } catch {
                $ErrorMsg = $_.Exception.Message
                Write-Host "[ERROR] Failed to save credentials: $ErrorMsg" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "`nEnter vCenter credentials:" -ForegroundColor Cyan
        $vCenterCreds = Get-Credential -Message "vCenter Login (e.g., administrator@vsphere.local)"
        
        try {
            $vCenterCreds | Export-CliXml -Path $vCenterCredPath
            Write-Host "[OK] vCenter credentials saved" -ForegroundColor Green
            Write-Host "    Location: $vCenterCredPath" -ForegroundColor Gray
            Write-Host "    Username: $($vCenterCreds.UserName)" -ForegroundColor Gray
        } catch {
            $ErrorMsg = $_.Exception.Message
            Write-Host "[ERROR] Failed to save credentials: $ErrorMsg" -ForegroundColor Red
        }
    }
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "SETUP COMPLETE" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "[SUMMARY]" -ForegroundColor Green
Write-Host "  Credentials stored in: $CredsPath" -ForegroundColor Gray

if (-not $vCenterOnly -and (Test-Path (Join-Path $CredsPath "FA-creds.xml"))) {
    Write-Host "  ✓ FlashArray credentials ready" -ForegroundColor Gray
}

if (-not $FlashArrayOnly -and (Test-Path (Join-Path $CredsPath "vCenter-creds.xml"))) {
    Write-Host "  ✓ vCenter credentials ready" -ForegroundColor Gray
}

Write-Host "`n[SECURITY NOTES]" -ForegroundColor Yellow
Write-Host "  • Credentials are encrypted using Windows DPAPI" -ForegroundColor Gray
Write-Host "  • Only you can decrypt them on this computer" -ForegroundColor Gray
Write-Host "  • Do not share or commit these files to version control" -ForegroundColor Gray

Write-Host "`n[NEXT STEPS]" -ForegroundColor Cyan
Write-Host "  You can now run scripts that require credentials:" -ForegroundColor Gray
Write-Host "    • New-PureNFSFileSystem.ps1" -ForegroundColor Gray
Write-Host "    • New-PureNFSDatastore.ps1" -ForegroundColor Gray
Write-Host "    • New-NFSv3Datastore.ps1" -ForegroundColor Gray
Write-Host "    • Remove-NFSDatastoreFromFlashArray.ps1" -ForegroundColor Gray
Write-Host ""
