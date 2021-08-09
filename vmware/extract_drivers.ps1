# create zip dirs
$WORKDIR = "$env:TEMP\vmware_export_data"
$ZIP_DRIVERS_DIR = "$WORKDIR\drivers"
mkdir $WORKDIR
mkdir $ZIP_DRIVERS_DIR

# Copy installed VMWare drivers
$DRIVER_FOLDER_PREFIXES = @(
    'pvscsi',     # Paravirtual SCSI
    'vmci',       # Virtual Machine Communication Interface (KVP equivalent)
    'vmmouse',    # Mouse integration
    'vmusbmouse', # USB-based mouse
    'vm3d',       # Accelerated graphics
    'vmxnet3',    # VMXNET3 networking
    'efifw',      # EFI Firmware Tools
    # dependencies:
    'pnpxinternetgatewaydevices'
)
$DriverPattern = $DRIVER_FOLDER_PREFIXES -join '|'
$DriversDir = "$env:SystemRoot\System32\DriverStore\FileRepository"
$FoundDrivers = dir $DriversDir | Select-String -Pattern $DriverPattern

foreach ($d in $FoundDrivers) {
    $driverDir = Join-Path -Path $DriversDir -ChildPath $d
    Copy-Item $driverDir -Destination $ZIP_DRIVERS_DIR -Recurse
}

# Create the ZIP with all the copied data
Compress-Archive -Path "$WORKDIR\*" -DestinationPath "$WORKDIR.zip"
Write-Output "Drivers ZIP created at $WORKDIR.zip"
