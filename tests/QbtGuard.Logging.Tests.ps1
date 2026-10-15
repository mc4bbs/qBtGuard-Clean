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
