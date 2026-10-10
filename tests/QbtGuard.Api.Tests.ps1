# Mocked qBittorrent API tests for Pester 3.4 / Windows PowerShell 5.1.
# No network requests, torrent changes, scheduled-task changes, or PIA actions.
$enginePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'QbtGuard.ps1'
$engineSource = Get-Content -LiteralPath $enginePath -Raw
# The production script exits with code 1 on failure. For in-process tests,
# replace only that exit statement with a terminating exception.
if ($engineSource -notmatch 'exit 1') { throw 'Audit error handler changed; review test harness.' }
$testSource = $engineSource.Replace('exit 1', "throw 'qBtGuard test: audit aborted'")
$engineScript = [scriptblock]::Create($testSource)

Describe 'qBtGuard mocked API behavior' {
    BeforeEach {
        $install = Join-Path $TestDrive 'audit'
        New-Item -ItemType Directory -Path $install -Force | Out-Null
        @{ QbtUrl='http://127.0.0.1:8080'; QbtUser='test-user'; BlockNoExtension=$true; VerifyMkvSignatures=$true; BlockedExtensions=@('.exe'); AuditOnly=$true } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $install 'config.json')
        ConvertTo-SecureString 'test-password' -AsPlainText -Force |
            ConvertFrom-SecureString | Set-Content -LiteralPath (Join-Path $install 'credential.dpapi')
    }

    It 'completes an empty audit without findings' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content='Ok.' } }
        Mock Invoke-RestMethod { @() }
        & $engineScript -InstallPath $install
        (Get-Content -LiteralPath (Join-Path $install 'qbtguard.log') -Raw) | Should Match 'AUDIT completed: files=0 findings=0'
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It
    }

    It 'rejects an incorrect Web UI password and records an error' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content='Fails.' } }
        Mock Invoke-RestMethod { throw 'Torrent API should not be called after failed login' }
        { & $engineScript -InstallPath $install } | Should Throw 'qBtGuard test: audit aborted'
        (Get-Content -LiteralPath (Join-Path $install 'qbtguard.log') -Raw) | Should Match 'qBittorrent authentication failed'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }

    It 'handles a Web UI server connection failure' {
        Mock Invoke-WebRequest { throw 'Simulated connection refused' }
        Mock Invoke-RestMethod { throw 'Torrent API should not be called' }
        { & $engineScript -InstallPath $install } | Should Throw 'qBtGuard test: audit aborted'
        (Get-Content -LiteralPath (Join-Path $install 'qbtguard.log') -Raw) | Should Match 'Simulated connection refused'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }

    It 'handles a torrent API failure after successful login' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content='Ok.' } }
        Mock Invoke-RestMethod { throw 'Simulated torrent API timeout' }
        { & $engineScript -InstallPath $install } | Should Throw 'qBtGuard test: audit aborted'
        (Get-Content -LiteralPath (Join-Path $install 'qbtguard.log') -Raw) | Should Match 'Simulated torrent API timeout'
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It
    }
}
