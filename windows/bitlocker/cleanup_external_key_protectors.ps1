# The script iterates over external key protectors and deletes those found
# at a given location.
#
# If "DeleteFile" is set, the key file is deleted as well.
param (
    [Parameter(Mandatory=$true)]
    [string]$KeyFolderPath,
    [switch]$DeleteFile
)

$ErrorActionPreference = "Stop"
# Disable progress updates. These often cause problems when invoked remotely.
$ProgressPreference = "SilentlyContinue"

$cryptoNamespace = "Root\CIMV2\Security\MicrosoftVolumeEncryption"

[array]$encryptedVolumes = Get-WmiObject `
    -Namespace $cryptoNamespace `
    -Class "Win32_EncryptableVolume" `
    -Filter "EncryptionMethod != 0"

foreach ($encryptedVolume in $encryptedVolumes) {
    Write-Host (
        "Looking for external key protectors, volume: $encryptedVolume, "+
        "drive letter: $($encryptedVolume.DriveLetter)"
    )

    $externalKeyType = 2
    $result = $encryptedVolume.GetKeyProtectors($externalKeyType)
    if ($result.ReturnValue) {
        throw ("Unable to retrieve external key protectors, "+
               "WMI error: $($result.ReturnValue), "+
               "volume: $encryptedVolume, "+
               "drive letter: $($encryptedVolume.DriveLetter)")
    }

    $volumeKeyProtectorIDs = $result.VolumeKeyProtectorID

    foreach($volumeKeyProtectorID in $volumeKeyProtectorIDs) {
        Write-Host "Checking external key, protector ID: $volumeKeyProtectorID"
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
        if (Test-Path $fullKeyPath) {
            Write-Host (
                "Removing external key, protector ID: $volumeKeyProtectorID, "+
                "path: $fullKeyPath, "+
                "volume: $encryptedVolume, "+
                "drive letter: $($encryptedVolume.DriveLetter)"
            )
            $result = $encryptedVolume.DeleteKeyProtector($volumeKeyProtectorID)
            if ($result.ReturnValue) {
                throw (
                    "Unable to delete external key protector, "+
                    "protector ID: $volumeKeyProtectorID, "+
                    "path: $fullKeyPath, "+
                    "volume: $encryptedVolume, "+
                    "drive letter: $($encryptedVolume.DriveLetter)"
                )
            }
            if ($DeleteFile) {
                Write-Host "Deleting key file: $fullKeyPath"
                rm -force $fullKeyPath
            }
        } else {
            Write-Host (
                "Ignoring external key that doesn't reside at the specified location. "+
                "Key file name: $keyFileName, "+
                "protector ID: $volumeKeyProtectorID, "+
                "volume: $encryptedVolume, "+
                "drive letter: $($encryptedVolume.DriveLetter)")
        }
    }
}
