$ErrorActionPreference = "Stop"

$coriolisConfPath = $null
$coriolisGit = $null
# NOTE: must be publicly available:
$coriolisZipURL = $null
# NOTE: if downloaded off of github, the branch name is used to form the "coriolis-<branch>"
# directory where the source root lies. Leave blank/null if installing off of bitbucket:
$coriolisBranch = "master"

$coriolisInstallPath = "C:\Program Files\Cloudbase Solutions\Coriolis"
$coriolisLogDir = Join-Path $coriolisInstallPath "Log"
$coriolisLogFile = Join-Path $coriolisLogDir "Coriolis-Worker.log"

$gitURL = "https://github.com/git-for-windows/git/releases/download/v2.9.0.windows.1/Git-2.9.0-32-bit.exe"

# Nova installation parameters; used for python3 and all the libraries:
$novaZipURL = "https://cloudbase.it/downloads/HyperVNovaCompute_Mitaka_13_0_0.zip"
$novaInstallPath = "C:\Program Files\Cloudbase Solutions\Nova"
$novaBinPath = Join-Path $novaInstallPath "Bin"

# Python variables:
$pythonPath = Join-Path $novaInstallPath "Python"
$pythonExePath = Join-Path $pythonPath "python.exe"
$pythonLibPath = Join-Path $pythonPath "Lib"
$pythonScriptsPath = Join-Path $pythonPath "Scripts"
$pipPath = Join-Path $pythonScriptsPath "pip.exe"

$pythonSitePackagesPath = Join-Path $pythonLibPath "site-packages"

$coriolisExePath = Join-Path $pythonScriptsPath "Coriolis-Worker.exe"


################################################################# helpers:
function Ensure-PathAvailable {
    Param ( [string]$path )
    if ( Test-Path $path ) {
        Write-Host "Cleaning up '$path' before reinstalling."
        Remove-Item -Recurse -Force $path
    }
}

function Download-File {
    Param ( [string]$URL, [string]$OutFile )

    (New-Object System.Net.WebClient).DownloadFile($URL, $OutFile)
    Write-Host "Downloaded '$URL' to '$OutFile'."
}

function Prepend-ToPATH {
    Param ( [string]$path )

    setx PATH "$path;$env:Path"
    $env:Path = "$path;" + $env:Path
    Write-Host "Prepended '$path' to PATH."
}

function Log-ProcessError {
    Param ( $proc )
    Write-Error "Error code: $($proc.ExitCode)."
    Write-Error "StdOut: $($proc.StandardOutput)"
    Write-Error "StdErr: $($proc.StandardError)"
}

function Run-ExeInstaller {
    Param ( [string]$path )
    Write-Host "Running .exe installer '$path'."
    $proc = Start-Process -FilePath $path -ArgumentList @('/SILENT') -PassThru -Wait
    if ($proc.ExitCode) {
        Log-ProcessError $proc
        Throw "Failed to install $path."
    }
}

function Run-MSIInstaller {
    Param ( [string]$path, [string]$extraArgs )
    Write-Host "Running MSI installer '$path'."
    $proc = Start-Process -Wait -PassThru -FilePath msiexec -ArgumentList "/i $path /qn $extraArgs"
    if ($proc.ExitCode) {
        Log-ProcessError $proc
        Throw "Failed to install $path."
    }
}


function Install-Git {
    Write-Host "Installing git."
    $gitPath = "$env:TEMP\git.exe"

    Download-File -URL $gitURL -OutFile $gitPath
    Run-ExeInstaller -path $gitPath
    Remove-Item $gitPath

    Prepend-ToPath "$($env:ProgramFiles)\Git\cmd"
}


################################################################# functions:
function Setup-CoriolisEnv {
    Write-Host "Setting up Python environment."

    # fetch Nova (for python3 & libs):
    $novaZipPath = "$env:TEMP\nova.zip"
    Download-File -URL $novaZipURL -OutFile $novaZipPath

    # NOTE: only works on PowerShell >= 5.0
    Ensure-PathAvailable $novaInstallPath
    Expand-Archive -Path $novaZipPath -DestinationPath $novaInstallPath

    # Setup python path:
    Prepend-ToPATH $pythonPath

    # Setup bins path for qemu-img:
    Prepend-ToPATH $novaBinPath
}

function Update-Pip {
    Write-Host "Updating pip."

    $proc = Start-Process -FilePath $pythonExePath -ArgumentList @("""$pipPath""", "install", """--upgrade""", "pip") -PassThru -Wait -NoNewWindow
    if ( $LASTEXITCODE -ne 0 ) {
        Log-ProcessError $proc
        Throw "Failed to update pip."
    }

    Write-Host "Updated pip."
}

function Install-CoriolisPip {
    Param ( [string]$coriolisPath )

    Write-Host "pip installing Coriolis"

    Update-Pip

    $requirementsPath = Join-Path $coriolisPath "requirements.txt"
    $proc = Start-Process -FilePath $pythonExePath -ArgumentList @("""$pipPath""", "install", "-r", """$requirementsPath""") -PassThru -Wait -NoNewWindow
    if ( $LASTEXITCODE -ne 0 ) {
        Log-ProcessError $proc
        Throw "Failed to install Coriolis requirements."
    }

    $coriolisModulePath = Join-Path $coriolisPath "coriolis"
    Copy-Item -Recurse -Force $coriolisModulePath $pythonSitePackagesPath

    $proc = Start-Process -FilePath $pythonExePath -ArgumentList @("-c", """import os; import sys; from pip._vendor.distlib import scripts; specs = 'coriolis-worker = coriolis.cmd.worker:main'; m = scripts.ScriptMaker(None, r'$pythonScriptsPath'); m.executable = sys.executable; m.make(specs)""") -PassThru -Wait -NoNewWindow
    if ( $LASTEXITCODE -ne 0 ) {
        Log-ProcessError $proc
        Throw "Failed to update Python exe wrappers."
    }

    Write-Host "Succesfully pip installed Coriolis."
}


function Install-CoriolisGit {
    Write-Host "Git cloning and installing Coriolis."

    Install-Git

    # create the path and clone Coriolis:
    Ensure-PathAvailable $coriolisInstallPath
    New-Item -Path $coriolisInstallPath -Type Directory
    $coriolisPath = Join-Path $coriolisInstallPath "coriolis"

    & git.exe clone $coriolisGit -b $coriolisBranch $coriolisPath
    if ( $LASTEXITCODE -ne 0 ) {
        Throw "Failed to clone Coriolis."
    }

    Install-CoriolisPip $coriolisPath

    Write-Host "Succesfully installed Coriolis."
}


function Install-CoriolisZip {
    Write-Host "Fetching and installing Coriolis."

    # Download and extract Coriolis ZIP:
    $coriolisZipPath = "$env:TEMP\coriolis.zip"
    Download-File -URL $coriolisZipURL -OutFile $coriolisZipPath

    Ensure-PathAvailable $coriolisInstallPath
    Expand-Archive -Path $coriolisZipPath -DestinationPath $coriolisInstallPath

    $coriolisPath = $coriolisInstallPath
    if ( $coriolisBranch ) { $coriolisPath = Join-Path $coriolisInstallPath "coriolis-$coriolisBranch" }

    Install-CoriolisPip $coriolisPath

    Write-Host "Succesfully installed Coriolis."
}

function Setup-CoriolisWorkerService {
    Write-Host "Registering Coriolis Worker Service."
    $servicewrap = Join-Path $novaBinPath "OpenStackService.exe"

    & sc.exe create "coriolis-worker" binPath= "\""${servicewrap} \"" coriolis-worker \""${coriolisExePath}\"" --config-file \""${coriolisConfPath}\"" --log-file \""${coriolisLogFile}\""" DisplayName= "Coriolis Migration Worker" start= auto
    if ( $LASTEXITCODE -ne 0 ) {
        Throw "Failed to register Coriolis worker service."
    }
    Write-Host "Succesfully registered Coriolis Worker Service."
}

function Start-CoriolisWorkerService {
    Write-Host "Starting Coriolis Worker Service."
    & $pythonExePath $coriolisExePath --config-file $coriolisConfPath --log-file $coriolisLogFile
    if ( $LASTEXITCODE -ne 0 ) {
        Throw "Failed to start Coriolis worker service."
    }
    Write-Host "Succesfully started Coriolis Worker Sevice."
}

function Install-CoriolisWorker {
    Param ([bool]$InstallFromZip)

    if (!$coriolisConfPath) {
        throw "coriolisConfPath not specified."
    }

    if (!$coriolisGit) {
        throw "coriolisGit not specified."
    }

    Setup-CoriolisEnv

    if( $InstallFromZip ) {
        Install-CoriolisZip
    } else {
        Install-CoriolisGit
    }

    New-Item -Path $coriolisLogDir -Type Directory
    Setup-CoriolisWorkerService
    Start-CoriolisWorkerService
}
