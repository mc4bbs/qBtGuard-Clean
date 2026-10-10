# Pester 3.4 tests for the qBtGuard uninstaller.
# Only mocked ScheduledTasks commands are invoked. No actual task is removed.
$uninstaller = Join-Path (Split-Path -Parent $PSScriptRoot) 'Uninstall-QbtGuard.ps1'
Describe 'qBtGuard uninstaller ownership safeguards' {
    BeforeEach {
        $destination = Join-Path $TestDrive 'qBtGuard'
        $launcher = Join-Path $destination 'Run-QbtGuard.vbs'
        $expectedArgs = '//B //Nologo "' + $launcher + '"'
        Mock Get-ScheduledTask { $null }
        Mock Unregister-ScheduledTask { }
    }

    It 'does not unregister a task when none exists' {
        & $uninstaller -Destination $destination
        Assert-MockCalled Unregister-ScheduledTask -Times 0 -Exactly -Scope It
    }

    It 'removes only the matching qBtGuard task' {
        Mock Get-ScheduledTask { [pscustomobject]@{ Actions = @([pscustomobject]@{ Execute='wscript.exe'; Arguments=$expectedArgs }) } }
        & $uninstaller -Destination $destination
        Assert-MockCalled Unregister-ScheduledTask -Times 1 -Exactly -Scope It -ParameterFilter { $TaskName -eq 'qBtGuard Audit' }
    }

    It 'refuses an unrelated task with the same name' {
        Mock Get-ScheduledTask { [pscustomobject]@{ Actions = @([pscustomobject]@{ Execute='powershell.exe'; Arguments='-File C:\\Other.ps1' }) } }
        { & $uninstaller -Destination $destination } | Should Throw 'does not match'
        Assert-MockCalled Unregister-ScheduledTask -Times 0 -Exactly -Scope It
    }

    It 'refuses a launcher from another installation directory' {
        Mock Get-ScheduledTask { [pscustomobject]@{ Actions = @([pscustomobject]@{ Execute='wscript.exe'; Arguments='//B //Nologo "C:\\Other\\Run-QbtGuard.vbs"' }) } }
        { & $uninstaller -Destination $destination } | Should Throw 'does not match'
        Assert-MockCalled Unregister-ScheduledTask -Times 0 -Exactly -Scope It
    }

    It 'refuses tasks with additional actions' {
        Mock Get-ScheduledTask { [pscustomobject]@{ Actions = @([pscustomobject]@{ Execute='wscript.exe'; Arguments=$expectedArgs }, [pscustomobject]@{ Execute='cmd.exe'; Arguments='/c echo unexpected' }) } }
        { & $uninstaller -Destination $destination } | Should Throw 'does not match'
        Assert-MockCalled Unregister-ScheduledTask -Times 0 -Exactly -Scope It
    }
}
