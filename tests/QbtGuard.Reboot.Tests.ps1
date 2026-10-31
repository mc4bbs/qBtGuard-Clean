# All native shutdown/VPN/boot calls are mocked. Never reboots the test host.
$engine=Join-Path (Split-Path -Parent $PSScriptRoot) 'QbtGuard.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($engine,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
function Write-GuardLog { param($Message) }
function Invoke-Pia { param($Arguments) }
function Test-VpnReady {}
function Invoke-VpnRecovery {}
# Never load the native reboot body into the test session, even if mock setup fails.
function Invoke-SystemReboot { throw 'Native shutdown must be mocked in tests.' }
  foreach ($name in @('Get-Setting','Invoke-GuardAction','Get-RebootPolicy','Get-GuardBootUtc','Save-VpnWatchdogState','Update-VpnWatchdog','Invoke-GuardVpnCycle')) {
   $definition=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true) | Select-Object -First 1
   . ([scriptblock]::Create($definition.Extent.Text))
  }
Describe 'Sustained VPN outage reboot fallback' {
 BeforeEach {
  $InstallPath=Join-Path $TestDrive ([guid]::NewGuid().ToString())
  New-Item -ItemType Directory $InstallPath | Out-Null
  $path=Join-Path $InstallPath 'vpn-watchdog-state.json'
  $now=[DateTimeOffset]::Parse('2026-10-30T12:00:00Z')
  $script:boot=$now.AddHours(-2)
  $auditOnly=$false; $OnlyTorrentHash=$null
  $c=[pscustomobject]@{EnableVpnReboot=$true;EnablePia=$true;EnableVpnRecovery=$true;RemoteEndpoint=$false;RegionCooldownMinutes=10}
  Mock Get-GuardBootUtc { $script:boot }
  Mock Invoke-SystemReboot {}
  Mock Write-GuardLog { Write-Host $Message }
  Mock Invoke-Pia { 'Connecting' }
  Mock Test-VpnReady { $false }
  Mock Invoke-VpnRecovery { $script:vpnRecoveryAttempted=$true; throw 'VPN timeout fixture' }
  function Set-OutageFixture {
   param([int]$Age=35,[int]$Count=2)
   [pscustomobject]@{Version=1;FirstFailureUtc=$now.AddMinutes(-$Age).ToString('o');LastFailureUtc=$now.AddMinutes(-10).ToString('o');FailedRecoveries=$Count;FailureBootUtc=$script:boot.ToString('o');LastRebootAttemptUtc=$null;LastRebootBootUtc=$null} | ConvertTo-Json | Set-Content $path -Encoding UTF8
  }
 }
 It 'does nothing when reboot fallback is disabled' {
  $c.EnableVpnReboot=$false
  Update-VpnWatchdog $false $true $now | Should Be $false
  Test-Path $path | Should Be $false
  Assert-MockCalled Get-GuardBootUtc -Times 0 -Exactly -Scope It
  Assert-MockCalled Invoke-SystemReboot -Times 0 -Exactly -Scope It
 }
 It 'does nothing for remote endpoints' {
  $c.RemoteEndpoint=$true
  Update-VpnWatchdog $false $true $now | Should Be $false
  Test-Path $path | Should Be $false
 }
 It 'does nothing when normal recovery is disabled' {
  $c.EnableVpnRecovery=$false
  Update-VpnWatchdog $false $true $now | Should Be $false
  Test-Path $path | Should Be $false
 }
 It 'does nothing for a scoped torrent test' {
  $OnlyTorrentHash='a'*40
  Update-VpnWatchdog $false $true $now | Should Be $false
  Test-Path $path | Should Be $false
 }
 It 'starts tracking an outage without rebooting' {
  Update-VpnWatchdog $false $true $now | Should Be $false
  $s=Get-Content $path -Raw | ConvertFrom-Json
  $s.FailedRecoveries | Should Be 1
  Assert-MockCalled Invoke-SystemReboot -Times 0 -Exactly -Scope It
 }
 It 'requires the outage duration as well as recovery failures' {
  Set-OutageFixture -Age 20 -Count 5
  Update-VpnWatchdog $false $true $now | Should Be $false
  Assert-MockCalled Invoke-SystemReboot -Times 0 -Exactly -Scope It
 }
 It 'requires failed recovery attempts as well as duration' {
  Set-OutageFixture -Age 35 -Count 1
  Update-VpnWatchdog $false $true $now | Should Be $false
  Assert-MockCalled Invoke-SystemReboot -Times 0 -Exactly -Scope It
 }
 It 'does not count a cooldown-only cycle as another recovery attempt' {
  Set-OutageFixture
  Update-VpnWatchdog $false $false $now | Should Be $false
  (Get-Content $path -Raw | ConvertFrom-Json).FailedRecoveries | Should Be 2
 }
 It 'preserves fractional boot timestamps across JSON round trips' {
  $script:boot=$now.AddHours(-2).AddTicks(1234567)
  Set-OutageFixture
  Update-VpnWatchdog $false $true $now | Should Be $true
  Update-VpnWatchdog $false $true $now.AddMinutes(10) | Should Be $false
  Assert-MockCalled Invoke-SystemReboot -Times 1 -Exactly -Scope It
 }
 It 'persists the reboot attempt before invoking Windows' {
  Set-OutageFixture
  Mock Invoke-SystemReboot {
   $s=Get-Content $path -Raw | ConvertFrom-Json
   $s.LastRebootAttemptUtc | Should Not BeNullOrEmpty
   $s.LastRebootBootUtc | Should Not BeNullOrEmpty
  }
  Update-VpnWatchdog $false $true $now | Should Be $true
  Assert-MockCalled Invoke-SystemReboot -Times 1 -Exactly -Scope It
 }
 It 'does not write state or call shutdown in audit mode' {
  Set-OutageFixture
  $before=[IO.File]::ReadAllText($path)
  $auditOnly=$true
  Update-VpnWatchdog $false $true $now | Should Be $false
  [IO.File]::ReadAllText($path) | Should Be $before
  Assert-MockCalled Invoke-SystemReboot -Times 0 -Exactly -Scope It
  Assert-MockCalled Write-GuardLog -Times 1 -Exactly -Scope It -ParameterFilter { $Message -like 'WOULD request computer restart*' }
 }
 It 'does not create state for an audited new outage' {
  $auditOnly=$true
  Update-VpnWatchdog $false $true $now | Should Be $false
  Test-Path $path | Should Be $false
 }
 It 'blocks a second attempt during the same boot' {
  Set-OutageFixture
  Update-VpnWatchdog $false $true $now | Out-Null
  Update-VpnWatchdog $false $true $now.AddMinutes(10) | Should Be $false
  Assert-MockCalled Invoke-SystemReboot -Times 1 -Exactly -Scope It
 }
 It 'retains attempt throttling when Windows rejects the restart' {
  Set-OutageFixture
  Mock Invoke-SystemReboot { throw 'fixture permission denied' }
  { Update-VpnWatchdog $false $true $now } | Should Throw
  Update-VpnWatchdog $false $true $now.AddMinutes(10) | Should Be $false
  Assert-MockCalled Invoke-SystemReboot -Times 1 -Exactly -Scope It
 }
 It 'blocks a reboot within 24 hours of an attempt on an earlier boot' {
  Set-OutageFixture
  $s=Get-Content $path -Raw | ConvertFrom-Json
  $s.LastRebootAttemptUtc=$now.AddHours(-3).ToString('o'); $s.LastRebootBootUtc=$now.AddDays(-1).ToString('o')
  $s | ConvertTo-Json | Set-Content $path
  Update-VpnWatchdog $false $true $now | Should Be $false
  Assert-MockCalled Invoke-SystemReboot -Times 0 -Exactly -Scope It
 }
 It 'permits an eligible later boot after the interval has expired' {
  Set-OutageFixture
  $s=Get-Content $path -Raw | ConvertFrom-Json
  $s.LastRebootAttemptUtc=$now.AddHours(-25).ToString('o'); $s.LastRebootBootUtc=$now.AddDays(-2).ToString('o')
  $s | ConvertTo-Json | Set-Content $path
  Update-VpnWatchdog $false $true $now | Should Be $true
 }
 It 'resets outage counters on health but retains reboot history' {
  Set-OutageFixture
  Update-VpnWatchdog $false $true $now | Out-Null
  Update-VpnWatchdog $true $false $now.AddMinutes(1) | Out-Null
  $s=Get-Content $path -Raw | ConvertFrom-Json
  $s.FailedRecoveries | Should Be 0
  $s.FirstFailureUtc | Should BeNullOrEmpty
  $s.LastRebootAttemptUtc | Should Not BeNullOrEmpty
 }
 It 'starts a fresh outage after a reboot' {
  Set-OutageFixture
  $script:boot=$now.AddMinutes(-40)
  Update-VpnWatchdog $false $true $now | Should Be $false
  (Get-Content $path -Raw | ConvertFrom-Json).FailedRecoveries | Should Be 1
 }
 It 'honors startup grace even with already mature outage state' {
  $script:boot=$now.AddMinutes(-10)
  Set-OutageFixture
  Update-VpnWatchdog $false $true $now | Should Be $false
  Assert-MockCalled Invoke-SystemReboot -Times 0 -Exactly -Scope It
 }
 It 'restarts tracking after a long gap in observations' {
  Set-OutageFixture -Age 120 -Count 9
  $s=Get-Content $path -Raw | ConvertFrom-Json
  $s.LastFailureUtc=$now.AddMinutes(-60).ToString('o')
  $s | ConvertTo-Json | Set-Content $path
  Update-VpnWatchdog $false $true $now | Should Be $false
  (Get-Content $path -Raw | ConvertFrom-Json).FailedRecoveries | Should Be 1
 }
 It 'blocks reboot when PIA becomes connected immediately before the action' {
  Set-OutageFixture
  Mock Invoke-Pia { 'Connected' }
  { Update-VpnWatchdog $false $true $now } | Should Throw
  (Get-Content $path -Raw | ConvertFrom-Json).LastRebootAttemptUtc | Should BeNullOrEmpty
  Assert-MockCalled Invoke-SystemReboot -Times 0 -Exactly -Scope It
 }
 It 'blocks reboot on an unknown final PIA state' {
  Set-OutageFixture
  Mock Invoke-Pia { 'Unknown' }
  { Update-VpnWatchdog $false $true $now } | Should Throw
  Assert-MockCalled Invoke-SystemReboot -Times 0 -Exactly -Scope It
 }
 It 'blocks reboot on corrupt persistent state' {
  '{broken' | Set-Content $path
  { Update-VpnWatchdog $false $true $now } | Should Throw
  Assert-MockCalled Invoke-SystemReboot -Times 0 -Exactly -Scope It
 }
 It 'blocks reboot on future persistent timestamps' {
  Set-OutageFixture
  $s=Get-Content $path -Raw | ConvertFrom-Json
  $s.LastFailureUtc=$now.AddDays(1).ToString('o')
  $s | ConvertTo-Json | Set-Content $path
  { Update-VpnWatchdog $false $true $now } | Should Throw
  Assert-MockCalled Invoke-SystemReboot -Times 0 -Exactly -Scope It
 }
 It 'rejects a string in place of a numeric threshold' {
  $c | Add-Member NoteProperty VpnRebootAfterMinutes '30'
  { Get-RebootPolicy } | Should Throw
 }
 It 'rejects a dangerously short reboot interval' {
  $c | Add-Member NoteProperty VpnRebootMinimumIntervalMinutes 0
  { Get-RebootPolicy } | Should Throw
 }
 It 'routes known PIA outages and failed recovery attempts into escalation' {
  Mock Update-VpnWatchdog { $false }
  { Invoke-GuardVpnCycle } | Should Throw 'VPN timeout fixture'
  Assert-MockCalled Update-VpnWatchdog -Times 1 -Exactly -Scope It -ParameterFilter { -not $Healthy -and $RecoveryFailed }
 }
 It 'does not advance escalation when the PIA CLI cannot report its state' {
  Mock Invoke-Pia { throw 'CLI unavailable fixture' }
  Mock Update-VpnWatchdog { $false }
  { Invoke-GuardVpnCycle } | Should Throw 'VPN timeout fixture'
  Assert-MockCalled Update-VpnWatchdog -Times 0 -Exactly -Scope It
 }
 It 'does not advance outage escalation for connected forwarding-only failure' {
  Mock Invoke-Pia { 'Connected' }
  Mock Update-VpnWatchdog { $false }
  { Invoke-GuardVpnCycle } | Should Throw
  Assert-MockCalled Update-VpnWatchdog -Times 0 -Exactly -Scope It -ParameterFilter { -not $Healthy }
 }
 It 'clears outage state when VPN readiness succeeds' {
  Mock Invoke-VpnRecovery {}
  Mock Test-VpnReady { $true }
  Mock Update-VpnWatchdog { $false }
  Invoke-GuardVpnCycle
  Assert-MockCalled Update-VpnWatchdog -Times 1 -Exactly -Scope It -ParameterFilter { $Healthy }
 }
 It 'does not block a healthy cycle when watchdog state is corrupt' {
  '{broken' | Set-Content $path
  Mock Invoke-VpnRecovery {}
  Mock Test-VpnReady { $true }
  { Invoke-GuardVpnCycle } | Should Not Throw
  Assert-MockCalled Invoke-SystemReboot -Times 0 -Exactly -Scope It
 }
 It 'leaves no temporary state files after atomic writes' {
  Update-VpnWatchdog $false $true $now | Out-Null
  Update-VpnWatchdog $false $false $now.AddMinutes(10) | Out-Null
  @(Get-ChildItem $InstallPath -Filter '*.tmp').Count | Should Be 0
 }
}
