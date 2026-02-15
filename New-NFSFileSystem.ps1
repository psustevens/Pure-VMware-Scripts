
# Install PowerShell modules
Import-Module VMware.VimAutomation.Core
Import-Module PureStoragePowerShellSDK2

# FlashArray variables
$ArrayName        = 'sn1-x90r2-f07-27.fsa.lab'    # FlashArray FQDN

#region Create NFS FileSystem

# Connect to our FlashArray
$FlashArrayCreds = Import-CliXml -Path "$HOME/Documents/creds/FA-creds.xml"

# Connect to the FlashArray, negotiate highest supported API version on the arrray.
$FlashArray = Connect-Pfa2Array -EndPoint $ArrayName `
    -Credential $FlashArrayCreds -IgnoreCertificateError # -Verbose # -ApiVersion 2.27

# Create a new file system (10TB) and capture the result
$FileSystem = New-Pfa2FileSystem -Array $FlashArray -Name 'New-FS' # -Verbose

# Get the name of the root managed directory
$RootManagedDirectory = Get-Pfa2Directory -Array $FlashArray -FileSystemName $FileSystem.Name
Write-Host "Created managed directory: $($RootManagedDirectory.Name)" -ForegroundColor Green
Write-Host "Path: $($RootManagedDirectory.Path)" -ForegroundColor Green

# Create a new NFS export policy
New-Pfa2PolicyNfs -Array $FlashArray -Name 'New-FS-export-policy' `
    -UserMappingEnabled $false `
    -Enabled $true `
    # -Verbose

# Add client rule with no-root-squash for all clients using NFSv3
New-Pfa2PolicyNfsClientRule -Array $FlashArray `
    -PolicyName 'New-FS-export-policy' `
    -RulesClient '*' `
    -RulesAccess 'no-root-squash' `
    -RulesPermission 'rw' `
    -RulesNfsVersion 'nfsv3' `
    # -Verbose

# Create a new quota policy
New-Pfa2PolicyQuota -Array $FlashArray -Name 'New-FS-quota-policy' -Enabled $true -Verbose

# Add quota rule with 10TB limit (10995116277760 bytes = 10TB)
New-Pfa2PolicyQuotaRule -Array $FlashArray `
    -PolicyName 'New-FS-quota-policy' `
    -RulesQuotaLimit 10TB `
    -RulesEnforced $true `
    # -Verbose

# Create a new autodir policy
New-Pfa2PolicyAutodir -Array $FlashArray -Name 'New-FS-autodir-policy' -Enabled $true -Verbose

# Assign the NFS export policy to the file system
New-Pfa2DirectoryPolicyNfs -Array $FlashArray `
    -MemberName $RootManagedDirectory.Name `
    -PolicyName 'New-FS-export-policy' `
    -PoliciesExportName 'New-FS' `
    # -Verbose

# After creating the export, retrieve it to display details
$NFSExport = Get-Pfa2DirectoryExport -Array $FlashArray `
    -DirectoryName $RootManagedDirectory.Name 

# Assign the quota policy to the file system
New-Pfa2DirectoryPolicyQuota -Array $FlashArray `
    -MemberName $RootManagedDirectory.Name `
    -PolicyName 'New-FS-quota-policy' `
    # -Verbose

# Assign the autodir policy to the file system
New-Pfa2DirectoryPolicyAutodir -Array $FlashArray `
    -MemberName $RootManagedDirectory.Name `
    -PolicyName 'New-FS-autodir-policy' `
    # -Verbose

Write-Host "Created File System: $($FileSystem.Name)" -ForegroundColor Green
Write-Host "Created NFS export:  $($NFSExport.Path)$($FileSystem.Name)" -ForegroundColor Green
Write-Host "A (10TB) quota was applied." -ForegroundColor Green
#endregion
