# qBtGuard 0.1.0-preview uninstaller. Retains installed files and logs.
[CmdletBinding()]
param([string]$Destination = (Join-Path $env:LOCALAPPDATA 'qBtGuard'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'qBtGuard Audit'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    $expectedLauncher = Join-Path ([IO.Path]::GetFullPath($Destination)) 'Run-QbtGuard.vbs'
    $actions = @($task.Actions)
    if ($actions.Count -ne 1 -or [IO.Path]::GetFileName([string]$actions[0].Execute) -ine 'wscript.exe' -or
        [string]$actions[0].Arguments -ne ('//B //Nologo ' + [char]34 + $expectedLauncher + [char]34)) {
        throw "Task '$taskName' does not match the expected qBtGuard launcher for '$Destination'. No task removed."
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed scheduled task: $taskName"
} else {
    Write-Host "Scheduled task not found: $taskName"
}
if (Test-Path -LiteralPath $Destination) { Write-Host "Installation directory retained at $Destination for manual inspection/removal." }
Write-Host 'Torrents and downloads untouched.'
