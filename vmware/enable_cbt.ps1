Param(
  [string]$Server,
  [string]$VMName,
  [PSCredential]$Credential,
  [switch]$Enabled = $true
)

$ErrorActionPreference = "Stop"

Import-Module VMware.VimAutomation.Core

Connect-VIServer -Server $server -Credential $Credential | Out-Null

$vm = Get-vm $VMName
$vmView = $vm | Get-View

if ($vmView.Config.changeTrackingEnabled -eq $Enabled)
{
    Write-Verbose "CBT is already set to $Enabled for this VM" -Verbose
}
else
{
    if ($vm | Get-Snapshot)
    {
        throw "Remove all VM snapshots before changing the CBT setting"
    }

    $vmConfigSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $vmConfigSpec.changeTrackingEnabled = $Enabled
    $vmView.reconfigVM($vmConfigSpec)
}