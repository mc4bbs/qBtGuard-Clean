# Pester 3.4.0 regression tests for the read-only audit helpers.
# These tests DO NOT run QbtGuard.ps1, contact qBittorrent, or touch scheduled tasks.
$engine = Join-Path (Split-Path -Parent $PSScriptRoot) 'QbtGuard.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($engine, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('QbtGuard.ps1 parse errors: ' + ($parseErrors | Out-String)) }
foreach ($functionName in @('Get-MkvIssue','Test-NoReparsePoint','Resolve-TorrentFile')) {
    $definition = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true) | Select-Object -First 1
    if (-not $definition) { throw "Missing function: $functionName" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

Describe 'qBtGuard MKV header inspection' {
    It 'accepts a valid EBML signature' {
        $p = Join-Path $TestDrive 'valid.mkv'
        [IO.File]::WriteAllBytes($p, [byte[]]@(0x1a,0x45,0xdf,0xa3,0,0,0,0))
        Get-MkvIssue $p | Should BeNullOrEmpty
    }
    It 'detects a Windows executable masquerading as MKV' {
        $p = Join-Path $TestDrive 'fake.mkv'
        [IO.File]::WriteAllBytes($p, [byte[]]@(0x4d,0x5a,0,0,0,0))
        Get-MkvIssue $p | Should Match 'Windows MZ executable header'
    }
    It 'detects a truncated header' {
        $p = Join-Path $TestDrive 'short.mkv'
        [IO.File]::WriteAllBytes($p, [byte[]]@(0x1a,0x45))
        Get-MkvIssue $p | Should Match 'Too short'
    }
    It 'detects an invalid non-EBML header' {
        $p = Join-Path $TestDrive 'invalid.mkv'
        [IO.File]::WriteAllBytes($p, [byte[]]@(1,2,3,4,5))
        Get-MkvIssue $p | Should Match 'Not an EBML header'
    }
    It 'reports missing files as unreadable without modifying anything' {
        Get-MkvIssue (Join-Path $TestDrive 'missing.mkv') | Should Match '^UNREADABLE:'
    }
    It 'does not expose a missing file path in the unreadable finding' {
        $p = Join-Path $TestDrive 'PRIVATE-LOCATION-DO-NOT-LOG.mkv'
        $issue = Get-MkvIssue $p
        $issue | Should Match '^UNREADABLE:'
        $issue | Should Not Match 'PRIVATE-LOCATION-DO-NOT-LOG'
        $issue | Should Not Match ([regex]::Escape($TestDrive))
    }
}

Describe 'qBtGuard torrent path validation' {
    It 'resolves a nested file inside the save directory' {
        $root = Join-Path $TestDrive 'downloads'
        $nested = Join-Path $root 'Season 1'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        $p = Join-Path $nested 'episode.mkv'
        [IO.File]::WriteAllBytes($p, [byte[]]@(0x1a,0x45,0xdf,0xa3))
        $torrent = [pscustomobject]@{ save_path=$root; content_path='' }
        Resolve-TorrentFile $torrent 'Season 1/episode.mkv' | Should Be $p
    }
    It 'rejects a file marked as a symbolic link or junction' {
        $root = Join-Path $TestDrive 'links'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $p = Join-Path $root 'episode.mkv'
        [IO.File]::WriteAllBytes($p, [byte[]]@(0x1a,0x45,0xdf,0xa3))
        Mock Get-Item { [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint } }
        $torrent = [pscustomobject]@{ save_path=$root; content_path='' }
        Resolve-TorrentFile $torrent 'episode.mkv' | Should BeNullOrEmpty
    }
    It 'rejects an inaccessible path component rather than following it' {
        $root = Join-Path $TestDrive 'inaccessible'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $p = Join-Path $root 'episode.mkv'
        [IO.File]::WriteAllBytes($p, [byte[]]@(0x1a,0x45,0xdf,0xa3))
        Mock Get-Item { throw 'Simulated access denied' }
        $torrent = [pscustomobject]@{ save_path=$root; content_path='' }
        Resolve-TorrentFile $torrent 'episode.mkv' | Should BeNullOrEmpty
    }
    It 'rejects parent traversal with forward slashes' {
        $torrent = [pscustomobject]@{ save_path=$TestDrive; content_path='' }
        Resolve-TorrentFile $torrent '../outside.mkv' | Should BeNullOrEmpty
    }
    It 'rejects parent traversal with backslashes' {
        $torrent = [pscustomobject]@{ save_path=$TestDrive; content_path='' }
        Resolve-TorrentFile $torrent '..\outside.mkv' | Should BeNullOrEmpty
    }
    It 'rejects absolute paths' {
        $torrent = [pscustomobject]@{ save_path=$TestDrive; content_path='' }
        Resolve-TorrentFile $torrent 'C:\Windows\notepad.exe' | Should BeNullOrEmpty
    }
    It 'rejects an empty save path' {
        $torrent = [pscustomobject]@{ save_path=''; content_path='' }
        Resolve-TorrentFile $torrent 'episode.mkv' | Should BeNullOrEmpty
    }
}

Describe 'qBtGuard read-only source safeguards' {
    It 'contains no torrent mutation API endpoints' {
        $source = Get-Content -LiteralPath $engine -Raw
        $source | Should Not Match '/api/v2/torrents/(delete|add|pause|resume|recheck|renameFile|setLocation)'
    }
    It 'does not invoke filesystem deletion or PIA controls' {
        $source = Get-Content -LiteralPath $engine -Raw
        $source | Should Not Match '(?i)\b(Remove-Item|DeleteFile|Stop-Process|Start-Process|piactl)\b'
    }
}
