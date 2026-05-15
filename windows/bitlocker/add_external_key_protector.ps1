# Add external key protectors for all encrypted volumes, storing the keys
# in the "KeyFolderPath" directory. Specify "OSVolumeOnly" to ignore other
# volumes.
#
# This script is meant to be used before initiating a Coriolis migration,
# storing the Bitlocker keys on an unencrypted (potentially temporary) drive.
#
# Coriolis will migrate this drive along with the other encrypted disks.
# Windows automatically loads keys stored on USB drives but not disk drives.
# Consider using os-morphing scripts to unlock the disks using these keys.
#
# Note that the TPM data is not moved as part of the VM migration. Once the
# migration finishes and a replica is deployed, use the other scripts to
# re-add the TPM keys and cleanup the external keys.
param (
    [Parameter(Mandatory=$true)]
    [string]$KeyFolderPath,
    [Parameter(Mandatory=$false)]
    [string]$FriendlyNamePrefix="temporary-key-",
    # Add an external key only for the OS volume.
    [switch]$OSVolumeOnly
)

$ErrorActionPreference = "Stop"
# Disable progress updates. These often cause problems when invoked remotely.
$ProgressPreference = "SilentlyContinue"

$cryptoNamespace = "Root\CIMV2\Security\MicrosoftVolumeEncryption"

$wmiFilter = "EncryptionMethod != 0"
if ($OSVolumeOnly) {
    Write-Host "OSVolumeOnly specified, ignoring other volumes."
    $wmiFilter += "AND VolumeType = 0"
}
[array]$encryptedVolumes = Get-WmiObject `
    -Namespace $cryptoNamespace `
    -Class "Win32_EncryptableVolume" `
    -Filter $wmiFilter

foreach ($encryptedVolume in $encryptedVolumes) {
    $friendlyName = $FriendlyNamePrefix + (New-Guid).Guid
    $result = $encryptedVolume.ProtectKeyWithExternalKey(
        $friendlyName, $null)

    if ($result.ReturnValue) {
        throw ("Unable to add external key protector, "+
               "WMI error: $($result.ReturnValue), "+
               "volume: $encryptedVolume, "+
               "drive letter: $($encryptedVolume.DriveLetter)")
    }

    $volumeKeyProtectorID = $result.VolumeKeyProtectorID
    $encryptedVolume.SaveExternalKeyToFile($volumeKeyProtectorID, $KeyFolderPath)
    if ($result.ReturnValue) {
        throw ("Unable to save external key "+
               "$volumeKeyProtectorID to $KeyFolderPath, "+
               "WMI error: $($result.ReturnValue), "+
               "volume: $encryptedVolume, "+
               "drive letter: $($encryptedVolume.DriveLetter)")
    }

    $result = $encryptedVolume.GetExternalKeyFileName($volumeKeyProtectorID)
    if ($result.ReturnValue) {
        throw ("Unable to retrieve external key path, "+
               "protector ID: $volumeKeyProtectorID, "+
               "WMI error: $($result.ReturnValue), "+
               "volume: $encryptedVolume, "+
               "drive letter: $($encryptedVolume.DriveLetter)")
    }
    $keyFileName = $result.FileName
    $fullKeyPath = Join-Path $KeyFolderPath $keyFileName

    # Enforce stricter ACLs, disabling inheritance and explicitly removing
    # the "Users" account.
    $acl = Get-Acl $fullKeyPath
    # Disable inheritance, preserving current rules.
    $acl.SetAccessRuleProtection($true, $true)
    Set-Acl $fullKeyPath $acl

    $acl = Get-Acl $fullKeyPath
    # Remove the 'Users' group specifically.
    $users = New-Object System.Security.Principal.NTAccount("Builtin", "Users")
    $acl.PurgeAccessRules($users)
    Set-Acl $fullKeyPath $acl

    Write-Host ("Added external key. "+
                "Volume: $encryptedVolume, "+
                "drive letter: $($encryptedVolume.DriveLetter), "+
                "key id: $volumeKeyProtectorID, "+
                "key directory: $KeyFolderPath")
}
