# qBtGuard 0.1.0-preview - read-only audit engine
[CmdletBinding()]
param([string]$InstallPath)
if ([string]::IsNullOrWhiteSpace($InstallPath)) { $InstallPath = Split-Path -Parent $PSCommandPath }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$configFile = Join-Path $InstallPath 'config.json'
if (-not (Test-Path -LiteralPath $configFile)) { throw 'Missing config.json. Run Install-QbtGuard.ps1.' }
$c = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
$log = Join-Path $InstallPath 'qbtguard.log'
function Write-GuardLog([string]$Message) {
 $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
 Add-Content -LiteralPath $log -Value $line
 Write-Output $line
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
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$headers = $null
$uri = $null
try {
 $uri = [uri]([string]$c.QbtUrl)
 if ($uri.Scheme -notin @('http','https')) { throw 'Web UI URL must use http or https.' }
 $secure = (Get-Content -LiteralPath (Join-Path $InstallPath 'credential.dpapi') -Raw).Trim() | ConvertTo-SecureString
 $credential = New-Object System.Management.Automation.PSCredential([string]$c.QbtUser, $secure)
 $headers = @{ Referer = ($uri.AbsoluteUri.TrimEnd('/') + '/'); Origin = $uri.GetLeftPart([UriPartial]::Authority) }
 $login = Invoke-WebRequest -Uri ($uri.AbsoluteUri.TrimEnd('/') + '/api/v2/auth/login') -Method Post -WebSession $session -Headers $headers -Body @{ username = [string]$c.QbtUser; password = $credential.GetNetworkCredential().Password } -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
 if ($login.Content.Trim() -ne 'Ok.') { throw 'qBittorrent authentication failed.' }
 $torrents = @(Invoke-RestMethod -Uri ($uri.AbsoluteUri.TrimEnd('/') + '/api/v2/torrents/info') -WebSession $session -Headers $headers -TimeoutSec 30 -ErrorAction Stop | ForEach-Object { $_ })
 $blocked = @($c.BlockedExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
 $checked = 0; $findings = 0
 foreach ($torrent in $torrents) {
  if ($null -eq $torrent -or -not $torrent.hash) { continue }
  $files = @(Invoke-RestMethod -Uri ($uri.AbsoluteUri.TrimEnd('/') + '/api/v2/torrents/files?hash=' + [uri]::EscapeDataString([string]$torrent.hash)) -WebSession $session -Headers $headers -TimeoutSec 30 -ErrorAction Stop | ForEach-Object { $_ })
  foreach ($file in $files) {
   if ($null -eq $file) { continue }
   $checked++
   $name = [string]$file.name
   $ext = [IO.Path]::GetExtension($name).ToLowerInvariant()
   if (($c.BlockNoExtension -and [string]::IsNullOrWhiteSpace($ext)) -or ($blocked -contains $ext)) {
    $findings++
    Write-GuardLog ('ALERT prohibited file: torrent="{0}" file="{1}" extension="{2}"' -f $torrent.name, $name, $ext)
   }
   if ($c.VerifyMkvSignatures -and $ext -eq '.mkv' -and [double]$torrent.progress -ge 1 -and [double]$file.progress -ge 1) {
    $path = Resolve-TorrentFile $torrent $name
    if (-not $path) { Write-GuardLog ('NOTICE MKV unavailable: torrent="{0}" file="{1}"' -f $torrent.name, $name); continue }
    $issue = Get-MkvIssue $path
    if ($issue) { $findings++; Write-GuardLog ('ALERT MKV signature: torrent="{0}" file="{1}" issue="{2}"' -f $torrent.name, $name, $issue) }
   }
  }
 }
 Write-GuardLog ("AUDIT completed: files=$checked findings=$findings. No changes made.")
} catch { Write-GuardLog ('ERROR: audit failed (' + $_.Exception.GetType().Name + '). Check Web UI connectivity, credentials, and configuration.'); exit 1 }
finally {
 if ($null -ne $session -and $null -ne $headers -and $null -ne $uri) {
  try { Invoke-WebRequest -Uri ($uri.AbsoluteUri.TrimEnd('/') + '/api/v2/auth/logout') -Method Post -WebSession $session -Headers $headers -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null } catch {}
 }
}
