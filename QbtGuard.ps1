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
function Write-GuardLog([string]$Message) {
 $clean = $Message -replace '[\r\n\x00-\x1f]', ' '
 Add-Content -LiteralPath $log -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $clean)
 # Logging must not contaminate boolean function return values.
 Write-Host $clean
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
  if (-not $settled) { throw 'PIA did not finish disconnecting; region and connect requests withheld.' }
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
 throw 'VPN recovery timed out after bounded polling; no verified tunnel and forwarded port. Manual reconnect may be required.'
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
 foreach ($name in @('EnablePia','EnableVpnRecovery','EnablePortSync','EnableQbtRestart','DeleteProhibitedTorrents','DeleteInvalidMkvTorrents','BlockNoExtension','VerifyMkvSignatures','RemoteEndpoint')) {
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
 if ($piaEnabled) {
  $stage = 'VPN'
  if (-not (Test-LocalEndpoint $uri)) { throw 'PIA endpoint must resolve exclusively to this computer.' }
  Invoke-VpnRecovery
  if (-not (Test-VpnReady)) { throw 'VPN and configured interface not ready; cycle blocked.' }
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
 Write-GuardLog "$mode completed: files=$checked findings=$findings mkvChecked=$mkvChecked mkvSkipped=$mkvSkipped mkvUnreadable=$mkvUnreadable torrentsRemoved=$deleted"
} catch {
 Write-GuardLog ('ERROR: cycle failed at ' + $stage + ' (' + $_.Exception.GetType().Name + '). No successful completion recorded.')
 exit 1
} finally {
 if ($loggedIn) {
  try { Invoke-WebRequest -Uri ($baseUrl + '/api/v2/auth/logout') -Method Post -WebSession $session -Headers $headers -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null } catch {}
 }
 if ($null -ne $lock) { $lock.Dispose() }
}
