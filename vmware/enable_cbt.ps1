Param(
  [string]$Server,
  [string]$VMName,
  [PSCredential]$Credential
)

$ErrorActionPreference = "Stop"

Connect-VIServer -Server $server -Credential $Credential

$vm = Get-vm $VMName | Get-View
$vmConfigSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
$vmConfigSpec.changeTrackingEnabled = $true
$vm.reconfigVM($vmConfigSpec)
