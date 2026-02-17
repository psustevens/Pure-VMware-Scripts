
# Install PowerShell modules
Import-Module PureStoragePowerShellSDK2

# FlashArray variables
$ArrayName        = 'sn1-x90r2-f07-27.fsa.lab'  # FlashArray FQDN
$FileSystemName   = 'NFSv3-Test'                    # File System Name
$SnapshotEvery    = 1800000                     # Snapshot every 30 minutes (in ms)
$SnapshotKeepFor  = 86400000                    # Keep snapshots for 1 day (in ms)
$NFSversion       = 'nfsv3'                     # Use nfsv41 for NFS version
$QuotaLimit       = 10TB                        # Quota limit for the file system

#region Create NFS FileSystem

# Connect to our FlashArray
$FlashArrayCreds = Import-CliXml -Path "$HOME/Documents/creds/FA-creds.xml"

# Connect to the FlashArray, negotiate highest supported API version on the arrray.
$FlashArray = Connect-Pfa2Array -EndPoint $ArrayName `
    -Credential $FlashArrayCreds `
    -IgnoreCertificateError
    # -Verbose `
    # -ApiVersion 2.27

# Create a new file system and capture the result
$FileSystem = New-Pfa2FileSystem -Array $FlashArray `
    -Name $FileSystemName
    # -Verbose

# Get the name of the root managed directory
$RootManagedDirectory = Get-Pfa2Directory -Array $FlashArray -FileSystemName $FileSystem.Name
Write-Host "Created managed directory: $($RootManagedDirectory.Name)" -ForegroundColor Green
#Write-Host "Path: $($RootManagedDirectory.Path)" -ForegroundColor Green

# Create a new NFS export policy
New-Pfa2PolicyNfs -Array $FlashArray -Name "$($FileSystemName)-export-policy" `
    -UserMappingEnabled $false `
    -Enabled $true | Out-Null
    # -Verbose

# Add client rule with no-root-squash for all clients using NFSv3
New-Pfa2PolicyNfsClientRule -Array $FlashArray `
    -PolicyName "$($FileSystemName)-export-policy" `
    -RulesClient '*' `
    -RulesAccess 'no-root-squash' `
    -RulesPermission 'rw' `
    -RulesNfsVersion $NFSversion | Out-Null
    # -Verbose

# Create a new quota policy
New-Pfa2PolicyQuota -Array $FlashArray -Name "$($FileSystemName)-quota-policy" -Enabled $true | Out-Null # -Verbose

# Add quota rule with $QuotaLimit limit (10995116277760 bytes = 10TB)
New-Pfa2PolicyQuotaRule -Array $FlashArray `
    -PolicyName "$($FileSystemName)-quota-policy" `
    -RulesQuotaLimit $QuotaLimit `
    -RulesEnforced $true | Out-Null
    # -Verbose

# Create a new autodir policy
New-Pfa2PolicyAutodir -Array $FlashArray -Name "$($FileSystemName)-autodir-policy" -Enabled $true | Out-Null # -Verbose

# Create a new snapshot policy
New-Pfa2PolicySnapshot -Array $FlashArray -Name "$($FileSystemName)-snapshot-policy" -Enabled $true | Out-Null #-Verbose

# Add snapshot rule with $SnapshotEvery snapshots, retained for $SnapshotKeepFor ms (43200000 ms = 12 hours)
$SnapshotRule = New-Pfa2PolicySnapshotRule -Array $FlashArray `
    -PolicyName "$($FileSystemName)-snapshot-policy" `
    -RulesClientName '30-minute-snapshots' `
    -RulesEvery $SnapshotEvery `
    -RulesKeepFor $SnapshotKeepFor `
    # -Verbose

# Assign the NFS export policy to the file system
New-Pfa2DirectoryPolicyNfs -Array $FlashArray `
    -MemberName $RootManagedDirectory.Name `
    -PolicyName "$($FileSystemName)-export-policy" `
    -PoliciesExportName "$($FileSystemName)" | Out-Null 
    # -Verbose

# After assigning the export, retrieve it to display details
$NFSExport = Get-Pfa2DirectoryExport -Array $FlashArray `
    -DirectoryName $RootManagedDirectory.Name 

# Assign the quota policy to the file system
New-Pfa2DirectoryPolicyQuota -Array $FlashArray `
    -MemberName $RootManagedDirectory.Name `
    -PolicyName "$($FileSystemName)-quota-policy" | Out-Null
    # -Verbose

# Assign the autodir policy to the file system
New-Pfa2DirectoryPolicyAutodir -Array $FlashArray `
    -MemberName $RootManagedDirectory.Name `
    -PolicyName "$($FileSystemName)-autodir-policy" | Out-Null
    # -Verbose

# Assign the snapshot policy to the file system
New-Pfa2DirectoryPolicySnapshot -Array $FlashArray `
    -MemberName $RootManagedDirectory.Name `
    -PolicyName "$($FileSystemName)-snapshot-policy" | Out-Null
    # -Verbose

Write-Host "Created File System: $($FileSystem.Name)" -ForegroundColor Green
Write-Host "Created NFS export:  $($NFSExport.Path)$($FileSystem.Name)" -ForegroundColor Green
#Write-Host "A $($QuotaLimit) quota limit was applied." -ForegroundColor Green
#Write-host "Snapshot policy was applied with $($SnapshotEvery) ms snapshots, retained for $($SnapshotKeepFor) ms days." -ForegroundColor Green
#endregion
