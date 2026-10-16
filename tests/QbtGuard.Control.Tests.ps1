# Mocked controls: no VPN, process, or torrent changes are performed.
$engine = Join-Path (Split-Path -Parent $PSScriptRoot) 'QbtGuard.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($engine,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Get-Setting','Invoke-GuardAction','Test-LocalEndpoint','Test-VpnReady','Get-SavedBinding','Test-StartupBinding','Test-LiveBinding','Get-ForwardedPort','Invoke-VpnRecovery','Ensure-QbtRunning')) {
 $definition=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true) | Select-Object -First 1
 . ([scriptblock]::Create($definition.Extent.Text))
}
# Stubs exist only so Pester can mock engine-owned functions without running the engine.
function Write-GuardLog { param($Message) }
function Invoke-Pia { param($Arguments) }
Describe 'Global action gate' {
 It 'suppresses every action in audit mode' {
  $auditOnly=$true; $script:executed=$false
  Invoke-GuardAction 'test action' { $script:executed=$true } | Should Be $false
  $script:executed | Should Be $false
 }
 It 'executes an action in enforcement mode' {
  $auditOnly=$false; $script:executed=$false
  Invoke-GuardAction 'test action' { $script:executed=$true } | Should Be $true
  $script:executed | Should Be $true
 }
 It 'does not report success when an action fails' {
  $auditOnly=$false
  { Invoke-GuardAction 'test action' { throw 'failed' } } | Should Throw
 }
}
Describe 'Forwarded port validation' {
 It 'accepts a valid port' { Mock Invoke-Pia { '12345' }; Get-ForwardedPort | Should Be 12345 }
 It 'rejects Failed' { Mock Invoke-Pia { 'Failed' }; Get-ForwardedPort | Should BeNullOrEmpty }
 It 'rejects zero' { Mock Invoke-Pia { '0' }; Get-ForwardedPort | Should BeNullOrEmpty }
 It 'rejects an out of range port' { Mock Invoke-Pia { '65536' }; Get-ForwardedPort | Should BeNullOrEmpty }
}
Describe 'qBittorrent restart safeguards' {
 BeforeEach {
  $c=[pscustomobject]@{EnableQbtRestart=$true;QbtProcessName='qbittorrent';QbtExe='test.exe'}
  $auditOnly=$false
  Mock Get-Process { $null }
  Mock Start-Process { }
  Mock Test-VpnReady { $true }
  Mock Test-StartupBinding { $true }
  Mock Test-Path { $true }
 }
 It 'does not restart when the VPN is unhealthy' {
  Mock Test-VpnReady { $false }
  { Ensure-QbtRunning } | Should Throw
  Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
 }
 It 'does not restart when saved binding cannot be verified' {
  Mock Test-StartupBinding { $false }
  { Ensure-QbtRunning } | Should Throw
  Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
 }
 It 'does not restart in audit mode' {
  $auditOnly=$true
  Ensure-QbtRunning | Should Be $false
  Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
 }
 It 'respects disabled restart' {
  $c.EnableQbtRestart=$false
  Ensure-QbtRunning | Should Be $false
  Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
 }
 It 'leaves an existing process running' {
  Mock Get-Process { [pscustomobject]@{Id=123} }
  Ensure-QbtRunning | Should Be $true
  Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
 }
}
Describe 'VPN recovery audit and cooldown' {
 BeforeEach {
  $InstallPath=Join-Path $TestDrive ([guid]::NewGuid().ToString())
  New-Item -ItemType Directory $InstallPath | Out-Null
  $c=[pscustomobject]@{EnableVpnRecovery=$true;PiaRegions=@('region-a','region-b');RegionCooldownMinutes=10}
  $auditOnly=$true
  Mock Invoke-Pia { if ($Arguments[1] -eq 'connectionstate') { 'Reconnecting' } elseif ($Arguments[1] -eq 'portforward') { 'Failed' } elseif ($Arguments[1] -eq 'region') { 'region-a' } }
 }
 It 'plans recovery without changing PIA or cooldown state' {
  Invoke-VpnRecovery
  Test-Path (Join-Path $InstallPath 'region-state.json') | Should Be $false
  Assert-MockCalled Invoke-Pia -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[0] -in @('set','connect') }
 }
 It 'honors an existing recovery cooldown' {
  $auditOnly=$false
  @{LastAttemptUtc=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $InstallPath 'region-state.json')
  Invoke-VpnRecovery
  Assert-MockCalled Invoke-Pia -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[0] -in @('set','connect') }
 }
 It 'blocks recovery if the cooldown state is corrupt' {
  'invalid json' | Set-Content (Join-Path $InstallPath 'region-state.json')
  { Invoke-VpnRecovery } | Should Throw
  Assert-MockCalled Invoke-Pia -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[0] -in @('set','connect') }
 }
 It 'rejects region IDs containing shell syntax' {
  $c.PiaRegions=@('region-a','bad;command')
  { Invoke-VpnRecovery } | Should Throw
 }
}
Describe 'Saved startup binding' {
 It 'requires the configured VPN interface in the selected profile' {
  $path=Join-Path $TestDrive 'qbt.ini'
  'Connection\Interface=VPN adapter' | Set-Content $path
  $c=[pscustomobject]@{QbtSettingsPath=$path;VpnInterface='VPN adapter'}
  Test-StartupBinding | Should Be $true
 }
 It 'rejects the unrestricted interface' {
  $path=Join-Path $TestDrive 'unbound.ini'
  'Connection\Interface=' | Set-Content $path
  $c=[pscustomobject]@{QbtSettingsPath=$path;VpnInterface='VPN adapter'}
  Test-StartupBinding | Should Be $false
 }
}

Describe 'VPN exit IP and local tunnel readiness' {
 BeforeEach {
  $c=[pscustomobject]@{VpnInterface='test-tunnel'}
  Mock Invoke-Pia { if ($Arguments[1] -eq 'connectionstate') { 'Connected' } else { '203.0.113.8' } }
  Mock Get-NetAdapter { @([pscustomobject]@{Name='test-tunnel';Status='Up';InterfaceIndex=42}) }
  Mock Get-NetIPAddress { @([pscustomobject]@{IPAddress='10.8.0.2';AddressState='Preferred'}) }
 }
 It 'accepts a private tunnel IP different from the public VPN exit IP' {
  Test-VpnReady | Should Be $true
  Assert-MockCalled Get-NetIPAddress -Times 1 -Exactly -Scope It -ParameterFilter { $InterfaceIndex -eq 42 -and $AddressFamily -eq 'IPv4' }
 }
 It 'rejects a disconnected VPN even when the adapter is up' {
  Mock Invoke-Pia { 'Reconnecting' }
  Test-VpnReady | Should Be $false
 }
 It 'rejects a down configured adapter' {
  Mock Get-NetAdapter { @([pscustomobject]@{Name='test-tunnel';Status='Disconnected';InterfaceIndex=42}) }
  Test-VpnReady | Should Be $false
 }
 It 'rejects a missing configured adapter' {
  Mock Get-NetAdapter { @() }
  Test-VpnReady | Should Be $false
 }
 It 'rejects an adapter with only a link local address' {
  Mock Get-NetIPAddress { @([pscustomobject]@{IPAddress='169.254.1.2';AddressState='Preferred'}) }
  Test-VpnReady | Should Be $false
 }
 It 'rejects an unready tunnel address' {
  Mock Get-NetIPAddress { @([pscustomobject]@{IPAddress='10.8.0.2';AddressState='Tentative'}) }
  Test-VpnReady | Should Be $false
 }
 It 'accepts healthy tunnel checks when public exit IP telemetry would be Unknown' {
  Mock Invoke-Pia { if ($Arguments[1] -eq 'connectionstate') { 'Connected' } else { 'Unknown' } }
  Test-VpnReady | Should Be $true
  Assert-MockCalled Invoke-Pia -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[1] -eq 'vpnip' }
 }
}

Describe 'Windows qBittorrent interface name and ID' {
 BeforeEach {
  $path=Join-Path $TestDrive 'windows-binding.ini'
  @('Connection\InterfaceName=test-tunnel','Connection\Interface=iftype53_12345') | Set-Content $path
  $c=[pscustomobject]@{QbtSettingsPath=$path;VpnInterface='test-tunnel'}
 }
 It 'accepts a matching saved display name with a distinct internal ID' {
  Test-StartupBinding | Should Be $true
 }
 It 'compares the live API binding to the saved internal ID' {
  Test-LiveBinding ([pscustomobject]@{current_network_interface='iftype53_12345'}) | Should Be $true
 }
 It 'rejects an unrelated live internal ID' {
  Test-LiveBinding ([pscustomobject]@{current_network_interface='iftype53_99999'}) | Should Be $false
 }
 It 'rejects a saved name that does not match the configured adapter' {
  $c.VpnInterface='different-tunnel'
  Test-StartupBinding | Should Be $false
 }
 It 'rejects a name without an internal ID' {
  'Connection\InterfaceName=test-tunnel' | Set-Content $path
  Test-StartupBinding | Should Be $false
 }
 It 'rejects duplicate binding names' {
  'Connection\InterfaceName=another-tunnel' | Add-Content $path
  Test-StartupBinding | Should Be $false
 }
}

Describe 'VPN readiness fail-closed diagnostics' {
 BeforeEach {
  $c=[pscustomobject]@{VpnInterface='test-tunnel'}
  Mock Write-GuardLog {}
  Mock Invoke-Pia { 'Connected' }
  Mock Get-NetAdapter { @([pscustomobject]@{Name='test-tunnel';Status='Up';InterfaceIndex=42}) }
  Mock Get-NetIPAddress { @([pscustomobject]@{IPAddress='10.8.0.2';AddressState='Preferred'}) }
 }
 It 'reports a disconnected VPN and blocks readiness' {
  Mock Invoke-Pia { 'Reconnecting' }
  Test-VpnReady | Should Be $false
  Assert-MockCalled Write-GuardLog -Times 1 -Exactly -Scope It -ParameterFilter { $Message -match 'connection state is Reconnecting' }
 }
 It 'blocks readiness when the configured interface is empty' {
  $c.VpnInterface=''
  Test-VpnReady | Should Be $false
  Assert-MockCalled Get-NetAdapter -Times 0 -Exactly -Scope It
 }
 It 'blocks readiness when only an unrelated Up adapter exists' {
  Mock Get-NetAdapter { @([pscustomobject]@{Name='Ethernet';Status='Up';InterfaceIndex=2}) }
  Test-VpnReady | Should Be $false
 }
 It 'fails when local adapter inspection throws' {
  Mock Get-NetAdapter { throw 'adapter inspection failed' }
  { Test-VpnReady } | Should Throw
 }
 It 'fails when local address inspection throws' {
  Mock Get-NetIPAddress { throw 'address inspection failed' }
  { Test-VpnReady } | Should Throw
 }
}
