# qBtGuard 0.1.0-preview installer. Run as the intended Windows task user.
[CmdletBinding()]
param([string]$Destination = (Join-Path $env:LOCALAPPDATA 'qBtGuard'), [switch]$NoTask)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows only.' }
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Windows PowerShell 5.1 or later required.' }
$source = Join-Path $PSScriptRoot 'QbtGuard.ps1'
if (-not (Test-Path -LiteralPath $source)) { throw 'QbtGuard.ps1 missing from installer folder.' }
if (Test-Path -LiteralPath (Join-Path $Destination 'config.json')) { throw 'Existing installation found. No files were overwritten.' }
if (-not $NoTask -and (Get-ScheduledTask -TaskName 'qBtGuard Audit' -ErrorAction SilentlyContinue)) { throw 'Task qBtGuard Audit already exists; no changes made.' }
Write-Host 'qBtGuard 0.1 preview: REPORT-ONLY. Never deletes torrents or changes PIA.'
$url = Read-Host 'qBittorrent Web UI URL [http://127.0.0.1:8080]'
if ([string]::IsNullOrWhiteSpace($url)) { $url = 'http://127.0.0.1:8080' }
$parsed = [uri]$url
if ($parsed.Scheme -notin @('http','https')) { throw 'URL must be HTTP or HTTPS.' }
if ($parsed.Scheme -eq 'http' -and $parsed.Host -notin @('localhost','127.0.0.1','::1')) { throw 'Remote Web UI requires HTTPS.' }
$user = Read-Host 'qBittorrent Web UI username'
if ([string]::IsNullOrWhiteSpace($user)) { throw 'Username required.' }
$pw = Read-Host 'qBittorrent Web UI password' -AsSecureString
if ($pw.Length -eq 0) { throw 'Password required.' }
$config = [ordered]@{
 QbtUrl=$url.TrimEnd('/'); QbtUser=$user; BlockNoExtension=$true; VerifyMkvSignatures=$true
 BlockedExtensions=@('.exe','.scr','.com','.bat','.cmd','.msi','.msp','.ps1','.psm1','.vbs','.vbe','.js','.jse','.wsf','.wsh','.hta','.cpl','.pif','.lnk','.jar','.zipx')
 AuditOnly=$true; IntervalMinutes=10
}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
Copy-Item -LiteralPath $source -Destination (Join-Path $Destination 'QbtGuard.ps1')
$config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Destination 'config.json') -Encoding UTF8
$pw | ConvertFrom-SecureString | Set-Content -LiteralPath (Join-Path $Destination 'credential.dpapi') -Encoding ASCII
if (-not $NoTask) {
 $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $Destination 'QbtGuard.ps1'))
 $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
 $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel LeastPrivilege
 Register-ScheduledTask -TaskName 'qBtGuard Audit' -Action $action -Trigger $trigger -Principal $principal -Description 'Read-only torrent audit; requires user logged on' | Out-Null
}
Write-Host "Installed to $Destination. Run QbtGuard.ps1 manually to verify the connection."
