[CmdletBinding()]
param([string]$Destination = (Join-Path $env:LOCALAPPDATA 'qBtGuard'))
$ErrorActionPreference = 'Stop'
$task = Get-ScheduledTask -TaskName 'qBtGuard Audit' -ErrorAction SilentlyContinue
if ($task) { Unregister-ScheduledTask -TaskName 'qBtGuard Audit' -Confirm:$false }
if (Test-Path -LiteralPath $Destination) { Write-Host "Installation directory retained at $Destination for manual inspection/removal." }
Write-Host 'qBtGuard task removed. Torrents and downloads untouched.'
