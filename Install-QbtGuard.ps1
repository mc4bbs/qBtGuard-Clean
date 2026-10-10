# qBtGuard 0.1.1-preview installer. Run as the intended scheduled-task Windows user.
[CmdletBinding()]
param(
 [string]$Destination = (Join-Path $env:LOCALAPPDATA 'qBtGuard'),
 [switch]$NoTask
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'qBtGuard Audit'
$staging = $null
$installed = $false
$taskCreated = $false
$session = $null
$headers = $null
$uri = $null
try {
 if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion -lt [version]'5.1') { throw 'Windows PowerShell 5.1 is required.' }
 if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable. Sign in with a normal Windows user profile.' }
 if (-not $NoTask) {
  Import-Module ScheduledTasks -ErrorAction Stop
  if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw "Task '$taskName' already exists. No changes made." }
 }
 $source = Join-Path $PSScriptRoot 'QbtGuard.ps1'
 if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'QbtGuard.ps1 missing from installer directory.' }
 $destinationFull = [IO.Path]::GetFullPath($Destination)
 if (Test-Path -LiteralPath $destinationFull) { throw "Destination already exists: $destinationFull. No changes made." }
 $parent = Split-Path -Parent $destinationFull
 if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Destination parent does not exist: $parent" }
 Write-Host 'qBtGuard preview: READ-ONLY. No torrent deletion or PIA changes.'
 $url = Read-Host 'qBittorrent Web UI URL [http://127.0.0.1:8080]'
 if ([string]::IsNullOrWhiteSpace($url)) { $url = 'http://127.0.0.1:8080' }
 $uri = [uri]$url
 if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'Invalid Web UI URL. Use http(s)://host:port without credentials, query or fragment.' }
 $user = Read-Host 'qBittorrent Web UI username'
 if ([string]::IsNullOrWhiteSpace($user)) { throw 'Username required.' }
 $pw = Read-Host 'qBittorrent Web UI password' -AsSecureString
 if ($pw.Length -eq 0) { throw 'Password required.' }
 $credential = New-Object System.Management.Automation.PSCredential($user, $pw)
 $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
 $baseUrl = $uri.AbsoluteUri.TrimEnd('/')
 $headers = @{ Referer = ($baseUrl + '/'); Origin = $uri.GetLeftPart([UriPartial]::Authority) }
 Write-Host 'Checking qBittorrent Web UI authentication...'
 $login = Invoke-WebRequest -Uri ($baseUrl + '/api/v2/auth/login') -Method Post -WebSession $session -Headers $headers -Body @{ username=$user; password=$credential.GetNetworkCredential().Password } -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
 if ($login.Content.Trim() -ne 'Ok.') { throw 'qBittorrent login rejected the credentials.' }
 $null = Invoke-RestMethod -Uri ($baseUrl + '/api/v2/app/version') -WebSession $session -Headers $headers -TimeoutSec 15 -ErrorAction Stop
 $null = Invoke-RestMethod -Uri ($baseUrl + '/api/v2/torrents/info') -WebSession $session -Headers $headers -TimeoutSec 30 -ErrorAction Stop
 Write-Host 'Authentication and read-only API access verified.'
 $config = [ordered]@{
  QbtUrl=$baseUrl; QbtUser=$user; BlockNoExtension=$true; VerifyMkvSignatures=$true
  BlockedExtensions=@('.exe','.scr','.com','.bat','.cmd','.msi','.msp','.ps1','.psm1','.vbs','.vbe','.js','.jse','.wsf','.wsh','.hta','.cpl','.pif','.lnk','.jar','.zipx')
  AuditOnly=$true; IntervalMinutes=10
 }
 $staging = Join-Path $parent ('.qBtGuard-staging-' + [guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $staging -ErrorAction Stop | Out-Null
 Copy-Item -LiteralPath $source -Destination (Join-Path $staging 'QbtGuard.ps1') -ErrorAction Stop
 $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $staging 'config.json') -Encoding UTF8 -ErrorAction Stop
 $pw | ConvertFrom-SecureString | Set-Content -LiteralPath (Join-Path $staging 'credential.dpapi') -Encoding ASCII -ErrorAction Stop
 Move-Item -LiteralPath $staging -Destination $destinationFull -ErrorAction Stop
 $staging = $null
 $installed = $true
 if (-not $NoTask) {
  $scriptPath = Join-Path $destinationFull 'QbtGuard.ps1'
  $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
  # Daily trigger with one-day repetition avoids the 3650-day repetition-duration issue.
  $trigger = New-ScheduledTaskTrigger -Daily -At (Get-Date).AddMinutes(2)
  $trigger.Repetition.Interval = 'PT10M'
  $trigger.Repetition.Duration = 'P1D'
  $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'qBtGuard read-only audit; runs while user is logged on' -ErrorAction Stop | Out-Null
  $taskCreated = $true
 }
 Write-Host "SUCCESS: Installed to $destinationFull"
 if ($NoTask) { Write-Host 'No scheduled task created (-NoTask).' }
 else { Write-Host "Scheduled task: $taskName (requires this Windows user to be logged on)." }
 Write-Host 'Run QbtGuard.ps1 manually and review qbtguard.log before relying on the audit.'
} catch {
 Write-Host ("INSTALL FAILED: " + $_.Exception.Message) -ForegroundColor Red
 if ($taskCreated) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
 if ($installed -and (Test-Path -LiteralPath $destinationFull)) { Remove-Item -LiteralPath $destinationFull -Recurse -Force -ErrorAction SilentlyContinue }
 if ($staging -and (Test-Path -LiteralPath $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
 throw
} finally {
 if ($session -and $headers -and $uri) {
  try { Invoke-WebRequest -Uri ($uri.AbsoluteUri.TrimEnd('/') + '/api/v2/auth/logout') -Method Post -WebSession $session -Headers $headers -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null } catch {}
 }
}
