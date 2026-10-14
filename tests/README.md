# Windows QA

Run in Windows PowerShell 5.1 with Pester 4.10.1:

```powershell
Import-Module Pester -RequiredVersion 4.10.1; Invoke-Pester -Script .\tests
```

Tests use disposable local fixtures, DPAPI test credentials and mocked API/process/VPN/task commands. They never contact real qBittorrent or PIA. They cover path traversal and reparse points, header findings/privacy, API failure handling, shared audit action gating, deletion policy and hash targeting, disabled/unhealthy restart, remote-local separation, forwarding-port validation and recovery cooldown.

CI checks syntax and runs these tests on Windows. Real VPN/interface/profile behavior, clean installation, scheduler registration and destructive policies still require isolated Windows integration QA using disposable downloads. A mocked test pass is not permission to deploy enforcement.
