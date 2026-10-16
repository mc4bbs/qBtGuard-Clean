# Mocked asynchronous PIA state transitions; no real VPN calls or waits.
$engine=Join-Path (Split-Path -Parent $PSScriptRoot) 'QbtGuard.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($engine,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
function Invoke-Pia { param($Arguments) }
function Write-GuardLog { param($Message) }
function Test-VpnReady { }
function Get-ForwardedPort { }
Describe 'Asynchronous PIA recovery' {
 BeforeEach {
  foreach ($name in @('Get-Setting','Invoke-GuardAction','Invoke-VpnRecovery')) {
   $definition=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true) | Select-Object -First 1
   . ([scriptblock]::Create($definition.Extent.Text))
  }
  $InstallPath=Join-Path $TestDrive ([guid]::NewGuid().ToString())
  New-Item -ItemType Directory $InstallPath | Out-Null
  $c=[pscustomobject]@{EnableVpnRecovery=$true;PiaRegions=@('region-a','region-b');RegionCooldownMinutes=10}
  $auditOnly=$false
  $script:piaState='Disconnecting'
  $script:piaRegion='region-a'
  $script:stateReads=0
  $script:settleAt=4
  $script:connectCount=0
  $script:connectSucceedsAt=1
  $script:commandStates=New-Object 'System.Collections.Generic.List[string]'
  Mock Start-Sleep {}
  Mock Write-GuardLog {}
  Mock Test-VpnReady { $true }
  Mock Get-ForwardedPort { 12345 }
  Mock Invoke-Pia {
   if ($Arguments[0] -eq 'get') {
    switch ($Arguments[1]) {
     'connectionstate' {
      $script:stateReads++
      if ($script:piaState -eq 'Disconnecting' -and $script:stateReads -ge $script:settleAt) { $script:piaState='Disconnected' }
      return $script:piaState
     }
     'portforward' { return 'Failed' }
     'region' { return $script:piaRegion }
    }
   }
   if ($Arguments[0] -eq 'disconnect') {
    $script:commandStates.Add('disconnect:'+$script:piaState)
    $script:piaState='Disconnecting'; return
   }
   if ($Arguments[0] -eq 'set') {
    $script:commandStates.Add('set:'+$script:piaState)
    $script:piaRegion=$Arguments[2]; return
   }
   if ($Arguments[0] -eq 'connect') {
    $script:commandStates.Add('connect:'+$script:piaState)
    $script:connectCount++
    if ($script:connectCount -ge $script:connectSucceedsAt) { $script:piaState='Connected' }
   }
  }
 }
 It 'waits for Disconnected before setting the region and connecting' {
  Invoke-VpnRecovery
  ($script:commandStates -join ',') | Should Be 'set:Disconnected,connect:Disconnected'
  $script:piaRegion | Should Be 'region-b'
  Assert-MockCalled Write-GuardLog -Times 1 -Exactly -Scope It -ParameterFilter { $Message -eq 'VPN recovery verified' }
 }
 It 'retries a connect request that returns success but leaves PIA Disconnected' {
  $script:connectSucceedsAt=2
  Invoke-VpnRecovery
  $script:connectCount | Should Be 2
  ($script:commandStates -join ',') | Should Not Match 'connect:Disconnecting'
 }
 It 'withholds region and connect commands if disconnect never settles' {
  $script:settleAt=9999
  { Invoke-VpnRecovery } | Should Throw 'did not finish disconnecting'
  $script:commandStates.Count | Should Be 0
 }
 It 'explicitly disconnects a connected tunnel after forwarding failure' {
  $script:piaState='Connected'
  Invoke-VpnRecovery
  $script:commandStates[0] | Should Be 'disconnect:Connected'
  $script:commandStates[1] | Should Be 'set:Disconnected'
 }
 It 'bounds connect retries and reports a timeout without success' {
  $script:connectSucceedsAt=9999
  { Invoke-VpnRecovery } | Should Throw 'timed out'
  $script:connectCount | Should Be 4
  Assert-MockCalled Write-GuardLog -Times 0 -Exactly -Scope It -ParameterFilter { $Message -eq 'VPN recovery verified' }
 }
 It 'does not declare recovery verified without a forwarded port' {
  Mock Get-ForwardedPort { $null }
  { Invoke-VpnRecovery } | Should Throw 'timed out'
  Assert-MockCalled Write-GuardLog -Times 0 -Exactly -Scope It -ParameterFilter { $Message -eq 'VPN recovery verified' }
 }
 It 'does not mutate PIA or wait in audit mode' {
  $auditOnly=$true
  Invoke-VpnRecovery
  $script:commandStates.Count | Should Be 0
  Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
  Test-Path (Join-Path $InstallPath 'region-state.json') | Should Be $false
 }
}
