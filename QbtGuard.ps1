# qBtGuard 0.2.0 candidate: unified audit and opt-in enforcement.
[CmdletBinding()]
param(
 [string]$InstallPath,
 [ValidatePattern('^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$')]
 [string]$OnlyTorrentHash
)
if ([string]::IsNullOrWhiteSpace($InstallPath)) { $InstallPath = Split-Path -Parent $PSCommandPath }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$log = Join-Path $InstallPath 'qbtguard.log'
$script:cycleLogged = $false
function Write-GuardLog([string]$Message) {
 $clean = $Message -replace '[\r\n\x00-\x1f]', ' '
 Add-Content -LiteralPath $log -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $clean)
 # Logging must not contaminate boolean function return values.
 $script:cycleLogged = $true
 Write-Host $clean
}
function Write-GuardCompletion([string]$Message, [bool]$Quiet = $false, [datetime]$Now = (Get-Date)) {
 if (-not $Quiet) { Write-GuardLog $Message; return }
 # Match the original local-calendar cutoff, not a rolling 24-hour timer.
 $cutoff = $Now.Date.AddDays(-1).AddMinutes(1)
 if (-not (Test-Path -LiteralPath $log) -or (Get-Item -LiteralPath $log).LastWriteTime -lt $cutoff) {
  Write-GuardLog ("HEARTBEAT: " + $Message)
 } else {
  # Manual callers still see the successful summary; the disk log stays quiet.
  Write-Host $Message
 }
}
function Get-Setting([string]$Name, $Default) {
 $property = $c.PSObject.Properties[$Name]
 if ($null -eq $property) { return $Default }
 return $property.Value
}
function Invoke-GuardAction([string]$Name, [scriptblock]$Action) {
 if ($auditOnly) { Write-GuardLog "WOULD $Name"; return $false }
 & $Action | Out-Null
 Write-GuardLog "ACTION $Name"
 return $true
}
function Invoke-Pia([string[]]$Arguments) {
 # Use ProcessStartInfo for bounded execution and explicit exit status.
 # All arguments come from fixed verbs or validated region IDs.
 $si = New-Object Diagnostics.ProcessStartInfo
 $si.FileName = [string](Get-Setting 'PiaCtl' '')
 $si.Arguments = $Arguments -join ' '
 $si.UseShellExecute = $false; $si.CreateNoWindow = $true
 $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true
 $process = New-Object Diagnostics.Process
 $process.StartInfo = $si
 try {
  if (-not $process.Start()) { throw 'PIA command did not start.' }
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'PIA command timed out.' }
  if ($process.ExitCode -ne 0) { throw 'PIA command failed.' }
  return $stdout.Result.Trim()
 } finally { $process.Dispose() }
}
function Test-LocalEndpoint([uri]$Address) {
 $local = @('127.0.0.1','::1') + @(Get-NetIPAddress | Select-Object -ExpandProperty IPAddress)
 $resolved = @([Net.Dns]::GetHostAddresses($Address.DnsSafeHost) | ForEach-Object { $_.ToString() })
 return ($resolved.Count -gt 0 -and @($resolved | Where-Object { $_ -notin $local }).Count -eq 0)
}
function Test-VpnReady {
 $state = Invoke-Pia -Arguments @('get','connectionstate')
 if ($state -ne 'Connected') { Write-GuardLog "VPN BLOCKED: PIA connection state is $state"; return $false }
 # Public exit-IP discovery is telemetry, not the local tunnel readiness gate.
 # PIA can return Unknown for vpnip while Connected with a usable tunnel.
 $expected = [string](Get-Setting 'VpnInterface' '')
 if ([string]::IsNullOrWhiteSpace($expected)) { Write-GuardLog 'VPN BLOCKED: VpnInterface is not configured'; return $false }
 $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Name -eq $expected })
 if ($adapters.Count -ne 1) { Write-GuardLog 'VPN BLOCKED: configured tunnel adapter was not uniquely found'; return $false }
 if ($adapters[0].Status -ne 'Up') { Write-GuardLog 'VPN BLOCKED: configured tunnel adapter is not Up'; return $false }
 $addresses = @(Get-NetIPAddress -InterfaceIndex $adapters[0].InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
  Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -notlike '127.*' -and $_.IPAddress -ne '0.0.0.0' })
 if ($addresses.Count -eq 0) { Write-GuardLog 'VPN BLOCKED: no usable Preferred IPv4 address on the configured tunnel'; return $false }
 return $true
}
function Get-SavedBinding {
 $path = [string](Get-Setting 'QbtSettingsPath' '')
 $expected = [string](Get-Setting 'VpnInterface' '')
 if ([string]::IsNullOrWhiteSpace($expected) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
 $ini = Get-Content -LiteralPath $path
 $ids = @($ini | Where-Object { $_ -match '^Connection\\Interface=' })
 $names = @($ini | Where-Object { $_ -match '^Connection\\InterfaceName=' })
 if ($ids.Count -ne 1 -or $names.Count -gt 1) { return $null }
 $id = ($ids[0] -split '=',2)[1].Trim()
 if ([string]::IsNullOrWhiteSpace($id)) { return $null }
 # Windows qBittorrent saves a display name separately from its internal ID.
 $name = $id
 if ($names.Count -eq 1) { $name = ($names[0] -split '=',2)[1].Trim() }
 if ($name -ne $expected) { return $null }
 return [pscustomobject]@{ Name=$name; Id=$id }
}
function Test-StartupBinding {
 return ($null -ne (Get-SavedBinding))
}
function Test-LiveBinding($Preferences) {
 $saved = Get-SavedBinding
 if ($null -eq $saved) { return $false }
 return ([string]$Preferences.current_network_interface -eq $saved.Id)
}
function Invoke-QbtApi([string]$Endpoint, [string]$Method = 'Get', $Body = $null) {
 $requestArgs = @{ Uri=($baseUrl + '/api/v2/' + $Endpoint); Method=$Method; WebSession=$session; Headers=$headers; TimeoutSec=30; ErrorAction='Stop' }
 if ($null -ne $Body) { $requestArgs.Body = $Body }
 Invoke-RestMethod @requestArgs
}
function Get-ForwardedPort {
 $output = Invoke-Pia -Arguments @('get','portforward')
 if ($output -match '^\d{1,5}$' -and [int]$output -ge 1 -and [int]$output -le 65535) { return [int]$output }
 return $null
}
function Invoke-VpnRecovery {
 $state = Invoke-Pia -Arguments @('get','connectionstate')
 $portState = Invoke-Pia -Arguments @('get','portforward')
 if ($state -eq 'Connected' -and $portState -ne 'Failed') { return }
 if (-not (Get-Setting 'EnableVpnRecovery' $false)) { Write-GuardLog "NOTICE VPN recovery disabled; state=$state port=$portState"; return }
 $statePath = Join-Path $InstallPath 'region-state.json'
 if (Test-Path -LiteralPath $statePath) {
  # A corrupt cooldown record blocks recovery rather than causing rapid rotation.
  $last = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  $elapsed = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($last.LastAttemptUtc)).TotalMinutes
  if ($elapsed -lt [int](Get-Setting 'RegionCooldownMinutes' 10)) { Write-GuardLog 'NOTICE VPN recovery cooldown active'; return }
 }
 $regions = @(Get-Setting 'PiaRegions' @())
 if ($regions.Count -lt 2) { throw 'Configure at least two PIA region IDs.' }
 foreach ($region in $regions) { if ([string]$region -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'Invalid PIA region ID.' } }
 $current = Invoke-Pia -Arguments @('get','region')
 $index = [Array]::IndexOf($regions, $current)
 $next = [string]$regions[(($index + 1) % $regions.Count)]
 $changed = Invoke-GuardAction "prepare PIA region recovery to $next" {
  $script:vpnRecoveryAttempted = $true
  @{LastAttemptUtc=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
  # A successful CLI exit acknowledges a request, not a completed state change.
  $before = Invoke-Pia -Arguments @('get','connectionstate')
  if ($before -notin @('Disconnected','Disconnecting')) {
   Invoke-Pia -Arguments @('disconnect') | Out-Null
  }
  $settled = $false
  for ($poll = 0; $poll -lt 15; $poll++) {
   if ((Invoke-Pia -Arguments @('get','connectionstate')) -eq 'Disconnected') { $settled = $true; break }
   Start-Sleep -Seconds 2
  }
  if (-not $settled) { Write-GuardLog 'VPN recovery failed: disconnect did not settle within 30 seconds'; throw 'PIA did not finish disconnecting; region and connect requests withheld.' }
  Invoke-Pia -Arguments @('set','region',$next) | Out-Null
 }
 if (-not $changed) { return }
 # Retry acknowledged connect requests only while fully Disconnected.
 # Never issue connect during Disconnecting or interrupt Connecting.
 $connectAttempts = 0; $nextConnectPoll = 0
 for ($poll = 0; $poll -lt 24; $poll++) {
  $state = Invoke-Pia -Arguments @('get','connectionstate')
  if ($state -eq 'Disconnected' -and $connectAttempts -lt 4 -and $poll -ge $nextConnectPoll) {
   $requested = Invoke-GuardAction 'request PIA connect' {
    Invoke-Pia -Arguments @('connect') | Out-Null
   }
   if (-not $requested) { return }
   $connectAttempts++
   $nextConnectPoll = $poll + 3
   Write-GuardLog "PIA connect request $connectAttempts issued; awaiting Connected state"
  }
  if ($state -eq 'Connected' -and (Invoke-Pia -Arguments @('get','region')) -eq $next -and (Test-VpnReady) -and $null -ne (Get-ForwardedPort)) {
   Write-GuardLog 'VPN recovery verified'
   return
  }
  Start-Sleep -Seconds 5
 }
 Write-GuardLog ("VPN recovery failed: target=$next lastState=$state connectRequests=$connectAttempts; bounded polling exhausted")
 throw 'VPN recovery timed out after bounded polling; no verified tunnel and forwarded port. Manual reconnect may be required.'
}


function Get-RebootPolicy {
 $values = @{}
 foreach ($spec in @(
  @('VpnRebootAfterMinutes',30,10,1440),
  @('VpnRebootAfterFailedRecoveries',3,2,100),
  @('VpnRebootStartupGraceMinutes',15,5,120),
  @('VpnRebootMinimumIntervalMinutes',1440,60,10080)
 )) {
  $v = Get-Setting $spec[0] $spec[1]
  if (($v -isnot [int] -and $v -isnot [long]) -or $v -lt $spec[2] -or $v -gt $spec[3]) { throw ('Invalid reboot policy: ' + $spec[0]) }
  $values[$spec[0]] = [int]$v
 }
 return $values
}
function Get-GuardBootUtc {
 $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
 return ([DateTimeOffset]$os.LastBootUpTime).ToUniversalTime()
}
function Save-VpnWatchdogState($State) {
 $path = Join-Path $InstallPath 'vpn-watchdog-state.json'
 $temp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
 try {
  [IO.File]::WriteAllText($temp, ($State | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
  if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp,$path,($path + '.previous')) }
  else { [IO.File]::Move($temp,$path) }
 } finally {
  if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
 }
}
function Invoke-SystemReboot {
 # A positive shutdown timeout implies /f on Windows. Use zero, without /f:
 # applications may block the restart instead of being forcibly terminated.
 $si = New-Object Diagnostics.ProcessStartInfo
 $si.FileName = Join-Path $env:WINDIR 'System32\shutdown.exe'
 $si.Arguments = '/r /t 0 /d p:0:0 /c "qBtGuard: sustained VPN recovery failure"'
 $si.UseShellExecute = $false; $si.CreateNoWindow = $true
 $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true
 $process = New-Object Diagnostics.Process
 $process.StartInfo = $si
 try {
  if (-not $process.Start()) { throw 'Restart command did not start.' }
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Restart command timed out.' }
  if ($process.ExitCode -ne 0) { throw 'Restart command was rejected.' }
 } finally { $process.Dispose() }
}
function Update-VpnWatchdog([bool]$Healthy, [bool]$RecoveryFailed = $false, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow) {
 if (-not (Get-Setting 'EnableVpnReboot' $false) -or -not (Get-Setting 'EnablePia' $false) -or
     -not (Get-Setting 'EnableVpnRecovery' $false) -or (Get-Setting 'RemoteEndpoint' $false) -or $OnlyTorrentHash) { return $false }
 $policy = Get-RebootPolicy
 $boot = Get-GuardBootUtc
 if ($boot -gt $Now) { throw 'Boot time is in the future; reboot blocked.' }
 $bootId = $boot.ToString('o')
 $path = Join-Path $InstallPath 'vpn-watchdog-state.json'
 $state = [pscustomobject]@{Version=1;FirstFailureUtc=$null;LastFailureUtc=$null;FailedRecoveries=0;FailureBootUtc=$bootId;LastRebootAttemptUtc=$null;LastRebootBootUtc=$null}
 if (Test-Path -LiteralPath $path) {
  $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
  foreach ($key in @('Version','FirstFailureUtc','LastFailureUtc','FailedRecoveries','FailureBootUtc','LastRebootAttemptUtc','LastRebootBootUtc')) {
   if ($null -eq $state.PSObject.Properties[$key]) { throw 'Incomplete VPN watchdog state; reboot blocked.' }
  }
  if ($state.Version -isnot [int] -or $state.Version -ne 1 -or
      ($state.FailedRecoveries -isnot [int] -and $state.FailedRecoveries -isnot [long]) -or
      $state.FailedRecoveries -lt 0 -or $state.FailedRecoveries -gt 1000000) { throw 'Invalid VPN watchdog state; reboot blocked.' }
  foreach ($key in @('FirstFailureUtc','LastFailureUtc','FailureBootUtc','LastRebootAttemptUtc','LastRebootBootUtc')) {
   if ($null -ne $state.$key) {
    $parsed = [DateTimeOffset]::Parse([string]$state.$key)
    if ($parsed -gt $Now) { throw 'Future VPN watchdog timestamp; reboot blocked.' }
   }
  }
  if (($null -eq $state.FirstFailureUtc) -ne ($null -eq $state.LastFailureUtc) -or
      ($state.FirstFailureUtc -and [DateTimeOffset]::Parse($state.FirstFailureUtc) -gt [DateTimeOffset]::Parse($state.LastFailureUtc)) -or
      (($null -eq $state.LastRebootAttemptUtc) -ne ($null -eq $state.LastRebootBootUtc))) { throw 'Inconsistent VPN watchdog state; reboot blocked.' }
 }
 if ($Healthy) {
  if ($state.FirstFailureUtc -or $state.FailedRecoveries -gt 0) {
   $state.FirstFailureUtc=$null; $state.LastFailureUtc=$null; $state.FailedRecoveries=0; $state.FailureBootUtc=$bootId
   if (-not $auditOnly) { Save-VpnWatchdogState $state }
   Write-GuardLog 'NOTICE VPN watchdog outage cleared; reboot history retained'
  }
  return $false
 }
 # Missing observations or a new boot start a fresh outage window.
 $maxGap = [Math]::Max(30, 3 * [int](Get-Setting 'RegionCooldownMinutes' 10))
 if ((-not $state.FailureBootUtc -or [DateTimeOffset]::Parse([string]$state.FailureBootUtc) -ne $boot) -or ($state.LastFailureUtc -and ($Now - [DateTimeOffset]::Parse($state.LastFailureUtc)).TotalMinutes -gt $maxGap)) {
  $state.FirstFailureUtc=$null; $state.LastFailureUtc=$null; $state.FailedRecoveries=0; $state.FailureBootUtc=$bootId
 }
 if (-not $state.FirstFailureUtc) { $state.FirstFailureUtc=$Now.ToString('o') }
 $state.LastFailureUtc=$Now.ToString('o')
 if ($RecoveryFailed) { $state.FailedRecoveries++ }
 if (-not $auditOnly) { Save-VpnWatchdogState $state }
 $minutes = ($Now - [DateTimeOffset]::Parse($state.FirstFailureUtc)).TotalMinutes
 Write-GuardLog ('NOTICE VPN watchdog: outageMinutes={0} failedRecoveries={1}' -f [int][Math]::Floor($minutes),$state.FailedRecoveries)
 if (($Now - $boot).TotalMinutes -lt $policy.VpnRebootStartupGraceMinutes) { Write-GuardLog 'NOTICE VPN reboot startup grace active'; return $false }
 if ($minutes -lt $policy.VpnRebootAfterMinutes -or $state.FailedRecoveries -lt $policy.VpnRebootAfterFailedRecoveries) { return $false }
 if ($state.LastRebootBootUtc -and [DateTimeOffset]::Parse($state.LastRebootBootUtc) -eq $boot) {
  Write-GuardLog 'NOTICE VPN reboot already attempted this boot; manual intervention required'; return $false
 }
 if ($state.LastRebootAttemptUtc -and ($Now - [DateTimeOffset]::Parse($state.LastRebootAttemptUtc)).TotalMinutes -lt $policy.VpnRebootMinimumIntervalMinutes) {
  Write-GuardLog 'NOTICE VPN reboot minimum interval active; manual intervention may be required'; return $false
 }
 return (Invoke-GuardAction 'request computer restart after sustained VPN recovery failure' {
  # Recheck PIA immediately before committing the reboot attempt.
  $fresh = Invoke-Pia -Arguments @('get','connectionstate')
  if ($fresh -notin @('Disconnected','Connecting','Disconnecting','Reconnecting')) { throw 'PIA state changed or is unknown; reboot withheld.' }
  $state.LastRebootAttemptUtc=$Now.ToString('o'); $state.LastRebootBootUtc=$bootId
  # Persist before requesting reboot; rejected/blocked requests remain rate limited.
  Save-VpnWatchdogState $state
  Write-GuardLog 'NOTICE requesting Windows restart for VPN recovery; attempt persisted; applications may block restart'
  Invoke-SystemReboot
 })
}
function Invoke-GuardVpnCycle {
 $script:vpnRecoveryAttempted = $false
 try {
  Invoke-VpnRecovery
  if (-not (Test-VpnReady)) { throw 'VPN and configured interface not ready; cycle blocked.' }
  try { Update-VpnWatchdog -Healthy $true -Now ([DateTimeOffset]::UtcNow) | Out-Null }
  catch { Write-GuardLog ('NOTICE VPN reboot withheld: watchdog check failed (' + $_.Exception.GetType().Name + ')') }
 } catch {
  $failure = $_
  # Only an explicitly disconnected/transitional PIA state can advance reboot
  # escalation. API/file/configuration failures and unknown CLI state cannot.
  if (Get-Setting 'EnableVpnReboot' $false) {
   try {
    $observed = Invoke-Pia -Arguments @('get','connectionstate')
    if ($observed -eq 'Connected') { Update-VpnWatchdog -Healthy $true -Now ([DateTimeOffset]::UtcNow) | Out-Null }
    elseif ($observed -in @('Disconnected','Connecting','Disconnecting','Reconnecting')) {
     Update-VpnWatchdog -Healthy $false -RecoveryFailed $script:vpnRecoveryAttempted -Now ([DateTimeOffset]::UtcNow) | Out-Null
    } else { Write-GuardLog 'NOTICE VPN reboot withheld: connection state unknown' }
   } catch {
    Write-GuardLog ('NOTICE VPN reboot withheld: watchdog check failed (' + $_.Exception.GetType().Name + ')')
   }
  }
  throw $failure
 }
}

function Ensure-QbtRunning {
 $processName = [string](Get-Setting 'QbtProcessName' 'qbittorrent')
 if (Get-Process -Name $processName -ErrorAction SilentlyContinue) { return $true }
 if (-not (Get-Setting 'EnableQbtRestart' $false)) { Write-GuardLog 'NOTICE qBittorrent absent; restart disabled'; return $false }
 if (-not (Test-VpnReady) -or -not (Test-StartupBinding)) { throw 'Restart blocked: VPN readiness or saved interface binding not verified.' }
 $exe = [string](Get-Setting 'QbtExe' '')
 if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'qBittorrent executable missing.' }
 $started = Invoke-GuardAction 'restart qBittorrent' {
  if (-not (Test-VpnReady)) { throw 'VPN changed before restart.' }
  Start-Process -FilePath $exe -WindowStyle Minimized | Out-Null
 }
 if (-not $started) { return $false }
 $deadline = [DateTime]::UtcNow.AddSeconds(60)
 do {
  if (Get-Process -Name $processName -ErrorAction SilentlyContinue) { return $true }
  Start-Sleep -Seconds 2
 } while ([DateTime]::UtcNow -lt $deadline)
 throw 'qBittorrent process restart timed out.'
}
function Get-MkvIssue([string]$Path) {
 $stream = $null
 try {
  $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  $bytes = New-Object byte[] 12
  $count = $stream.Read($bytes, 0, 12)
  if ($count -lt 4) { return 'Too short for EBML signature' }
  if ($bytes[0] -eq 0x1a -and $bytes[1] -eq 0x45 -and $bytes[2] -eq 0xdf -and $bytes[3] -eq 0xa3) { return $null }
  if ($bytes[0] -eq 0x4d -and $bytes[1] -eq 0x5a) { return 'Windows MZ executable header' }
  return ('Not an EBML header: ' + [BitConverter]::ToString($bytes, 0, [Math]::Min($count, 12)))
 } catch { return 'UNREADABLE: file could not be opened or read' }
 finally { if ($null -ne $stream) { $stream.Dispose() } }
}
function Test-NoReparsePoint([string]$Root, [string]$Candidate) {
 # Reject links/junctions at any component, including the save directory itself.
 # Fail closed if a path component cannot be inspected.
 try {
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char]92, [char]47)
  $candidateFull = [IO.Path]::GetFullPath($Candidate)
  $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
  if (-not $candidateFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
  $walk = $candidateFull
  while ($walk) {
   $item = Get-Item -LiteralPath $walk -Force -ErrorAction Stop
   if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
   if ($walk.TrimEnd([char]92, [char]47) -ieq $rootFull) { return $true }
   $parent = [IO.Path]::GetDirectoryName($walk.TrimEnd([char]92, [char]47))
   if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $walk) { return $false }
   $walk = $parent
  }
 } catch { return $false }
 return $false
}
function Resolve-TorrentFile($Torrent, [string]$Name) {
 if ([IO.Path]::IsPathRooted($Name) -or $Name -match '(^|[\\/])\.\.([\\/]|$)' -or $Name -match '^[a-zA-Z]:') { return $null }
 $root = [string]$Torrent.save_path
 if ([string]::IsNullOrWhiteSpace($root)) { return $null }
 $rootFull = [IO.Path]::GetFullPath($root).TrimEnd([char]92) + [char]92
 $candidate = [IO.Path]::GetFullPath((Join-Path $root ($Name -replace '/', '\')))
 if (-not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $null }
 if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-NoReparsePoint $root $candidate)) { return $candidate }
 $content = [string]$Torrent.content_path
 if (-not [string]::IsNullOrWhiteSpace($content) -and [IO.Path]::GetFileName($content) -ieq [IO.Path]::GetFileName($Name) -and (Test-Path -LiteralPath $content -PathType Leaf)) {
  $full = [IO.Path]::GetFullPath($content)
  if ($full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase) -and (Test-NoReparsePoint $root $full)) { return $full }
 }
 return $null
}

$session = $null; $headers = $null; $uri = $null; $lock = $null
$loggedIn = $false
$stage = 'configuration'
try {
 # Exclusive lock covers manual and scheduled runs from this installation.
 try { $lock = [IO.File]::Open((Join-Path $InstallPath 'run.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
 catch [IO.IOException] { Write-Output 'qBtGuard already running or lock unavailable; cycle skipped.'; return }
 $c = Get-Content -LiteralPath (Join-Path $InstallPath 'config.json') -Raw | ConvertFrom-Json
 $auditOnly = Get-Setting 'AuditOnly' $true
 if ($auditOnly -isnot [bool]) { throw 'AuditOnly must be a JSON boolean.' }
 foreach ($name in @('EnablePia','EnableVpnRecovery','EnablePortSync','EnableQbtRestart','DeleteProhibitedTorrents','DeleteInvalidMkvTorrents','BlockNoExtension','VerifyMkvSignatures','RemoteEndpoint','QuietLogging','EnableVpnReboot')) {
  if ((Get-Setting $name $false) -isnot [bool]) { throw "Invalid boolean setting: $name" }
 }
 $uri = [uri]([string]$c.QbtUrl)
 if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'Invalid Web UI URL.' }
 $baseUrl = $uri.AbsoluteUri.TrimEnd('/')
 $piaEnabled = Get-Setting 'EnablePia' $false
 $remote = Get-Setting 'RemoteEndpoint' $false
 if ($remote -and ($piaEnabled -or (Get-Setting 'EnableQbtRestart' $false))) { throw 'Remote endpoint cannot use local PIA or watchdog controls.' }
 if ((Get-Setting 'EnableQbtRestart' $false) -and -not $piaEnabled) { throw 'Restart requires PIA integration.' }
 if (-not $piaEnabled -and ((Get-Setting 'EnableVpnRecovery' $false) -or (Get-Setting 'EnablePortSync' $false))) { throw 'VPN recovery and port sync require PIA integration.' }
 if (Get-Setting 'EnableVpnReboot' $false) {
  if (-not $piaEnabled -or -not (Get-Setting 'EnableVpnRecovery' $false) -or $remote) { throw 'VPN reboot requires local PIA integration and VPN recovery.' }
  $null = Get-RebootPolicy
 }
 if ($piaEnabled) {
  $stage = 'VPN'
  if (-not (Test-LocalEndpoint $uri)) { throw 'PIA endpoint must resolve exclusively to this computer.' }
  Invoke-GuardVpnCycle
  if (-not (Ensure-QbtRunning)) { return }
 }
 $stage = 'authentication'
 $secure = (Get-Content -LiteralPath (Join-Path $InstallPath 'credential.dpapi') -Raw).Trim() | ConvertTo-SecureString
 $credential = New-Object System.Management.Automation.PSCredential([string]$c.QbtUser, $secure)
 $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
 $headers = @{ Referer=($baseUrl + '/'); Origin=$uri.GetLeftPart([UriPartial]::Authority) }
 $deadline = [DateTime]::UtcNow.AddSeconds(60)
 do {
  try {
   $login = Invoke-WebRequest -Uri ($baseUrl + '/api/v2/auth/login') -Method Post -WebSession $session -Headers $headers -Body @{username=[string]$c.QbtUser; password=$credential.GetNetworkCredential().Password} -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
   if ($login.Content.Trim() -ne 'Ok.') { throw 'Authentication rejected.' }
   $loggedIn = $true
  } catch {
   if (-not $piaEnabled -or [DateTime]::UtcNow -ge $deadline) { throw }
   Start-Sleep -Seconds 2
  }
 } until ($loggedIn)
 $stage = 'preferences'
 if ($piaEnabled) {
  $prefs = Invoke-QbtApi 'app/preferences'
  if (-not (Test-LiveBinding $prefs)) { throw 'Live qBittorrent VPN interface binding mismatch.' }
  if (Get-Setting 'EnablePortSync' $false) {
   $port = Get-ForwardedPort
   if ($null -ne $port -and [int]$prefs.listen_port -ne $port) {
    $changed = Invoke-GuardAction "set qBittorrent listening port to $port" {
     if (-not (Test-VpnReady) -or (Get-ForwardedPort) -ne $port) { throw 'VPN or port changed before synchronization.' }
     Invoke-QbtApi 'app/setPreferences' 'Post' @{json=(@{listen_port=$port} | ConvertTo-Json -Compress)} | Out-Null
    }
    if ($changed -and [int](Invoke-QbtApi 'app/preferences').listen_port -ne $port) { throw 'Port change verification failed.' }
   } elseif ($null -eq $port) { Write-GuardLog 'NOTICE no valid PIA forwarded port available' }
  }
 }
 $stage = 'file scan'
 $infoEndpoint = 'torrents/info'
 if ($OnlyTorrentHash) { $infoEndpoint += '?hashes=' + $OnlyTorrentHash }
 $torrents = @(Invoke-QbtApi $infoEndpoint | ForEach-Object { $_ })
 if ($OnlyTorrentHash) {
  # Enforce scope locally even if a server ignores its hashes query filter.
  $torrents = @($torrents | Where-Object { $null -ne $_ -and $_.PSObject.Properties['hash'] -and [string]$_.hash -eq $OnlyTorrentHash })
  Write-GuardLog ("SCOPE requested hash=$OnlyTorrentHash matched=" + $torrents.Count)
 }
 $blocked = @($c.BlockedExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
 $checked = 0; $findings = 0; $mkvChecked = 0; $mkvSkipped = 0; $mkvUnreadable = 0; $deleted = 0
 foreach ($torrent in $torrents) {
  if ($null -eq $torrent -or [string]$torrent.hash -notmatch '^[a-fA-F0-9]{40,64}$') { throw 'Invalid torrent identity returned by API.' }
  $hash = [string]$torrent.hash
  $files = @(Invoke-QbtApi ('torrents/files?hash=' + $hash) | ForEach-Object { $_ })
  $prohibited = $false; $invalidMkv = $false
  foreach ($file in $files) {
   if ($null -eq $file) { continue }
   $checked++
   $name = [string]$file.name
   $ext = [IO.Path]::GetExtension($name).ToLowerInvariant()
   if (((Get-Setting 'BlockNoExtension' $true) -and [string]::IsNullOrWhiteSpace($ext)) -or $ext -in $blocked) {
    $prohibited = $true; $findings++
    Write-GuardLog ('ALERT prohibited file: torrent="{0}" file="{1}"' -f $torrent.name, $name)
   }
   if ((Get-Setting 'VerifyMkvSignatures' $true) -and $ext -eq '.mkv') {
    if ([double]$torrent.progress -lt 1 -or [double]$file.progress -lt 1 -or $remote) { $mkvSkipped++; continue }
    $path = Resolve-TorrentFile $torrent $name
    if (-not $path) { $mkvSkipped++; Write-GuardLog ('NOTICE MKV unavailable: file="{0}"' -f $name); continue }
    $mkvChecked++
    $issue = Get-MkvIssue $path
    if ($issue) {
     $findings++
     if ($issue -like 'UNREADABLE:*') { $mkvUnreadable++ } else { $invalidMkv = $true }
     Write-GuardLog ('ALERT MKV signature: file="{0}" issue="{1}"' -f $name, $issue)
    }
   }
  }
  if (($prohibited -and (Get-Setting 'DeleteProhibitedTorrents' $false)) -or ($invalidMkv -and (Get-Setting 'DeleteInvalidMkvTorrents' $false))) {
   $didDelete = Invoke-GuardAction "delete torrent $hash AND downloaded data" {
    # Recheck existence before deletion; never call direct filesystem deletion.
    $present = @(Invoke-QbtApi ('torrents/info?hashes=' + $hash) | ForEach-Object { $_ })
    if ($present.Count -ne 1 -or [string]$present[0].hash -ne $hash) { throw 'Torrent changed or disappeared before deletion.' }
    Invoke-QbtApi 'torrents/delete' 'Post' @{hashes=$hash; deleteFiles='true'} | Out-Null
    if (@(Invoke-QbtApi ('torrents/info?hashes=' + $hash) | ForEach-Object { $_ }).Count -ne 0) { throw 'Torrent removal not verified.' }
   }
   if ($didDelete) { $deleted++ }
  }
 }
 $mode = 'ENFORCE'; if ($auditOnly) { $mode = 'AUDIT' }
 $quietCompletion = (Get-Setting 'QuietLogging' $false) -and -not $auditOnly -and -not $OnlyTorrentHash -and $findings -eq 0 -and -not $script:cycleLogged
 Write-GuardCompletion "$mode completed: files=$checked findings=$findings mkvChecked=$mkvChecked mkvSkipped=$mkvSkipped mkvUnreadable=$mkvUnreadable torrentsRemoved=$deleted" $quietCompletion
} catch {
 Write-GuardLog ('ERROR: cycle failed at ' + $stage + ' (' + $_.Exception.GetType().Name + '). No successful completion recorded.')
 exit 1
} finally {
 if ($loggedIn) {
  try { Invoke-WebRequest -Uri ($baseUrl + '/api/v2/auth/logout') -Method Post -WebSession $session -Headers $headers -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null } catch {}
 }
 if ($null -ne $lock) { $lock.Dispose() }
}
