# qBtGuard — 0.1.0 preview

**Status: experimental, read-only auditor. Not yet validated on independent Windows installations.**

qBtGuard is a Windows PowerShell utility for auditing torrents managed by qBittorrent. It reports potentially dangerous file extensions, extensionless files, and completed `.mkv` files that do not begin with the EBML container signature.

**This preview never deletes torrents or downloads, starts or stops qBittorrent, or changes PIA settings.** It is **not a VPN kill switch**. The source project's VPN watchdog, port-forwarding synchronization, region failover and automatic deletion are intentionally excluded pending safety and portability testing.

## Requirements

- Windows 10/11, Windows PowerShell 5.1 and the ScheduledTasks module for scheduled operation.
- qBittorrent Web UI enabled with API v2; first compatibility target is qBittorrent 4.3.6.
- Local Web UI HTTP, or remote Web UI over HTTPS with a trusted certificate.
- The scheduled-task account must be able to access downloads, including network shares.

PIA is **not required** for this audit-only preview.

## Installation

1. Download and extract the repository; inspect the PowerShell scripts before running them.
2. Open Windows PowerShell as the Windows account that will run the audit.
3. From the extracted folder, run:
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-QbtGuard.ps1`
4. Enter the Web UI address, username, and password. The password is stored with Windows DPAPI, not in the JSON configuration.
5. Test manually:
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\qBtGuard\QbtGuard.ps1"`
6. Inspect `%LOCALAPPDATA%\qBtGuard\qbtguard.log`.

The `qBtGuard Audit` scheduled task repeats every 10 minutes **while the installing Windows user is logged in**. Run the installer with `-NoTask` to omit scheduling. DPAPI credentials cannot generally be decrypted from a different user account.

## Uninstall

Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-QbtGuard.ps1` from the extracted source directory. The scheduled task is removed; the installed directory, settings and logs are retained for inspection. Downloads are never touched.

## Security limitations

- This is a **report-only** preview, not antivirus software or a guaranteed security boundary.
- An EBML header check does not establish that a file is playable or safe.
- MKV header checks apply only to files the API reports complete. Missing files are reported as unavailable.
- Blocked extensions are reported even if the torrent is incomplete.
- Logs can contain torrent and file names: treat logs as private.
- Secure your qBittorrent Web UI; do not expose it directly to the public Internet.
- The preview has **not** yet been tested on a clean Windows VM, additional qBittorrent versions, alternate PIA versions, or all UNC path arrangements.

## Development roadmap

- Validate PowerShell syntax and installer behavior on a clean Windows VM.
- Add mocked API regression tests, including nested files, path traversal, network failures, and authentication errors.
- Verify qBittorrent 4.3.6 and newer versions separately.
- Add opt-in PIA integration only after VPN-interface binding and failure-mode tests.
- Consider deletion only with explicit opt-in, clear safeguards, and recovery procedures.

## Privacy

No personal configuration, passwords, private logs, hostnames, local addresses, or paths from the original installation belong in this repository. The `.gitignore` excludes local credentials, configuration, and logs. Review all commits before making this repository public.

## Contributing

Please provide reproducible bug reports with sanitized logs and version numbers. Do not post passwords, private IP addresses, share paths, or sensitive torrent filenames.

## License

No license has been selected yet. Please do not assume permission to redistribute or modify until a LICENSE file is added.
