# Exercise production logging, not the mock used by isolated control tests.
$engine=Join-Path (Split-Path -Parent $PSScriptRoot) 'QbtGuard.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($engine,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
Describe 'Production logger preserves control return values' {
 BeforeEach {
  foreach ($name in @('Write-GuardLog','Invoke-GuardAction')) {
   $definition=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true) | Select-Object -First 1
   . ([scriptblock]::Create($definition.Extent.Text))
  }
  $log=Join-Path $TestDrive 'control.log'
 }
 It 'returns exactly one false value when audit mode logs a proposed action' {
  $auditOnly=$true
  $values=@(Invoke-GuardAction 'fixture' { throw 'Must not run' })
  $values.Count | Should Be 1
  $values[0] | Should Be $false
  (Get-Content $log -Raw) | Should Match 'WOULD fixture'
 }
 It 'returns exactly one true value when enforcement logs success' {
  $auditOnly=$false
  $values=@(Invoke-GuardAction 'fixture' { 'discard action output' })
  $values.Count | Should Be 1
  $values[0] | Should Be $true
 }
 It 'does not return a success-stream value from logging alone' {
  @(Write-GuardLog 'fixture').Count | Should Be 0
 }
}

Describe 'Quiet completion heartbeat' {
 BeforeEach {
  foreach ($name in @('Write-GuardLog','Write-GuardCompletion')) {
   $definition=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true) | Select-Object -First 1
   . ([scriptblock]::Create($definition.Extent.Text))
  }
  $log=Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.log')
  $now=[datetime]'2026-10-16T12:00:00'
 }
 It 'writes a heartbeat for a missing log without returning pipeline output' {
  @(Write-GuardCompletion 'ENFORCE completed' $true $now).Count | Should Be 0
  (Get-Content $log -Raw) | Should Match 'HEARTBEAT: ENFORCE completed'
 }
 It 'leaves a recent log untouched' {
  [IO.File]::WriteAllText($log,'previous action')
  (Get-Item $log).LastWriteTime=$now.AddHours(-1)
  Write-GuardCompletion 'ENFORCE completed' $true $now
  (Get-Content $log -Raw) | Should Be 'previous action'
 }
 It 'writes after the previous calendar day cutoff even under 24 hours of inactivity' {
  [IO.File]::WriteAllText($log,'old')
  (Get-Item $log).LastWriteTime=[datetime]'2026-10-15T00:00:30'
  Write-GuardCompletion 'ENFORCE completed' $true ([datetime]'2026-10-16T00:00:00')
  (Get-Content $log -Raw) | Should Match 'HEARTBEAT'
 }
 It 'does not write at the exact cutoff' {
  [IO.File]::WriteAllText($log,'previous')
  (Get-Item $log).LastWriteTime=$now.Date.AddDays(-1).AddMinutes(1)
  Write-GuardCompletion 'ENFORCE completed' $true $now
  (Get-Content $log -Raw) | Should Be 'previous'
 }
 It 'retains full summaries when quiet is disabled' {
  Write-GuardCompletion 'AUDIT completed' $false $now
  (Get-Content $log -Raw) | Should Match 'AUDIT completed'
 }
}
