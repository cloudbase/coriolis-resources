# Recreate TPM-only key protector. 
#
# Meant to be used after a Coriolis migration. The TPM data doesn't get
# transferred as part of the migration, so the initial key protector is no
# longer valid and needs to be recreated.
#
# The script will refuse to remove protectors that use a TPM *and* additional
# authentication mechanisms (external drive, pin, etc), unless the "-Force"
# flag is set.
param (
    # Use TPM-only even if currently there are additional authorization
    # mechanisms.
    [switch]$Force,
    # Ignore the current TPM validation profile and use the default one.
    [switch]$UseDefaultProfile,
    [string]$FriendlyName="os-tpm-key"
)

$ErrorActionPreference = "Stop"
# Disable progress updates. These often cause problems when invoked remotely.
$ProgressPreference = "SilentlyContinue"

$cryptoNamespace = "Root\CIMV2\Security\MicrosoftVolumeEncryption"

[array]$osVolumes = Get-WmiObject `
    -Namespace $cryptoNamespace `
    -Class "Win32_EncryptableVolume" `
    -Filter "VolumeType = 0"

if ($osVolumes.Length -eq 0) {
    throw "Couldn't retrieve OS encryptable volume."
}
if ($osVolumes.Length -gt 1) {
    # Shouldn't happen, sanity check.
    throw "Multiple OS volumes retrieved: $osVolumes"
}
$osVolume = $osVolumes[0]
$driveLetter = $osVolume.DriveLetter

Write-Host (
    "Looking for TPM key protectors, "+
    "OS volume: $osVolume, "+
    "drive letter: $driveLetter"
)

$externalKeyType = 2
$result = $osVolume.GetKeyProtectors(0)
if ($result.ReturnValue) {
    throw ("Unable to retrieve external key protectors, "+
           "WMI error: $($result.ReturnValue), "+
           "volume: $osVolume, "+
           "drive letter: $driveLetter")
}

$volumeKeyProtectorIDs = $result.VolumeKeyProtectorID
$tpmValidationProfile = $null

foreach($volumeKeyProtectorID in $volumeKeyProtectorIDs) {
    Write-Host "Checking protector ID: $volumeKeyProtectorID"
    $result = $osVolume.GetKeyProtectorType($volumeKeyProtectorID)
    if ($result.ReturnValue) {
        throw ("Unable to retrieve protector type, "+
               "protector ID: $volumeKeyProtectorID, "+
               "WMI error: $($result.ReturnValue), "+
               "volume: $osVolume, "+
               "drive letter: $driveLetter")
    }
    $protectorType = $result.KeyProtectorType


    if (1,4,5,6 -contains $protectorType) {
        if (-not $UseDefaultProfile) {
            $result = $osVolume.GetKeyProtectorPlatformValidationProfile(
                $volumeKeyProtectorID)
            if ($result.ReturnValue) {
                throw ("Unable to retrieve TPM protector profile, "+
                       "protector ID: $volumeKeyProtectorID, "+
                       "WMI error: $($result.ReturnValue), "+
                       "volume: $osVolume, "+
                       "drive letter: $driveLetter")
            }
            $tpmValidationProfile = $result.PlatformValidationProfile
            Write-Host "Existing TPM validation profile: $tpmValidationProfile"
        } else {
            Write-Host "Using default TPM validation profile, ignoring current profile."
        }
    }

    switch ($protectorType) {
        # 0 All types. All key protectors are returned.
        # 1 Trusted Platform Module (TPM).
        # 2 External key.
        # 3 Numeric password.
        # 4 TPM And PIN.
        # 5 TPM And Startup Key.
        # 6 TPM And PIN And Startup Key.
        # 7 Public Key.
        # 8 Passphrase.
        # 9 TPM Certificate
        # 10 Security Identifier (SID)
        1 {
            Write-Host ("Removing TPM-only protector.")
            $result = $encryptedVolume.DeleteKeyProtector($volumeKeyProtectorID)
            if ($result.ReturnValue) {
                throw (
                    "Unable to delete TPM protector, "+
                    "protector ID: $volumeKeyProtectorID, "+
                    "WMI error: $($result.ReturnValue), "+
                    "volume: $osVolume, "+
                    "drive letter: $driveLetter"
                )
            }
        }
        {4,5,6,9 -contains $_} {
            if (!Force) {
                throw (
                    "Refusing to remove TPM protector that requires "+
                    "an additional mechanism. Protector type: $protectorType. "+
                    "Use -Force to override."
                )
            }
            Write-Host (
                "Force flag specified. Removing TPM protector with additional "+
                "authentication mechanism. The new protector will be TPM-only. "+
                "Protector type: $protectorType."
            )
            $result = $encryptedVolume.DeleteKeyProtector($volumeKeyProtectorID)
            if ($result.ReturnValue) {
                throw (
                    "Unable to delete TPM protector, "+
                    "protector ID: $volumeKeyProtectorID, "+
                    "WMI error: $($result.ReturnValue), "+
                    "volume: $osVolume, "+
                    "drive letter: $driveLetter"
                )
            }
        }
        default {
            Write-Host(
                "Ignoring non-TPM protector, type: $protectorType, "+
                "id: $volumeKeyProtectorID"
            )
        }
    }
}

$result = $osVolume.ProtectKeyWithTPM($FriendlyName, $tpmValidationProfile)
if ($result.ReturnValue) {
    throw ("Unable to add TPM key protector, "+
           "WMI error: $($result.ReturnValue), "+
           "volume: $osVolume, "+
           "drive letter: $driveLetter")
}
$volumeKeyProtectorID = $result.VolumeKeyProtectorID

Write-Host (
    "Added TPM protector. "+
    "Volume: $osVolume, "+
    "drive letter: $driveLetter, "+
    "key id: $volumeKeyProtectorID, "+
    "preserved TPM validation profile: $tpmValidationProfile"
)