# qBtGuard — 0.2.0 candidate

One Windows PowerShell 5.1 engine for torrent inspection, opt-in deletion, PIA recovery, forwarded-port synchronization, and qBittorrent restart. **This branch is a QA candidate, not an enforcement release.**

## Defaults and operation

Installation starts in audit mode (`AuditOnly: true`). All corrective actions pass through a shared action gate: audit mode logs what would happen without switching VPN regions, changing ports, starting qBittorrent, or deleting torrents. Authentication/logout, logs and a temporary execution lock still operate.

Set `AuditOnly: false` only after QA and enable each desired action separately. Flags default to false, including on older configurations. `DeleteProhibitedTorrents` removes the **entire offending torrent AND its downloaded data** through qBittorrent. `DeleteInvalidMkvTorrents` is separate and defaults off. An unreadable MKV alone never causes deletion.

| Setting | Meaning |
|---|---|
| `QbtUrl`, `QbtUser` | User-supplied Web UI connection |
| `RemoteEndpoint` | Explicit remote API mode; skips local MKV inspection and blocks local PIA/restart controls |
| `EnablePia` | Require local PIA tunnel and qBittorrent interface binding |
| `EnableVpnRecovery` | Rotate configured PIA regions after disconnection or explicit forwarding failure |
| `EnablePortSync` | Apply and verify PIA's forwarded port |
| `EnableQbtRestart` | Start a missing local process after VPN and saved profile binding checks |
| `VpnInterface` | Exact local VPN adapter name; must match the saved display name; the live qBittorrent binding is checked against its saved internal ID |
| `QbtSettingsPath` | Intended user's qBittorrent INI file; restart requires its saved interface name (or legacy alias) to match; the live API must match the saved internal ID |
| `PiaCtl`, `QbtExe`, `QbtProcessName` | Local installation paths and process name |
| `PiaRegions`, `RegionCooldownMinutes` | User-selected region IDs and persistent recovery cooldown |
| `BlockNoExtension`, `BlockedExtensions` | File-name inspection policy |
| `VerifyMkvSignatures` | Inspect completed local MKV headers |
| `DeleteProhibitedTorrents`, `DeleteInvalidMkvTorrents` | Separate opt-in deletion policies |

PIA integration is optional. With it enabled, the API endpoint must resolve exclusively to this machine. The tunnel must report Connected, have a Preferred, non-link-local IPv4 address on the configured Up adapter, and qBittorrent must report the configured interface binding. qBtGuard is **not a kill switch**: configure PIA's kill switch and qBittorrent's interface binding independently. It does not stop an already running qBittorrent if the tunnel fails. Recovery can take up to 120 seconds; the scheduler prevents concurrent scheduled instances and the engine locks each installation against concurrent manual runs.

The first compatibility target is qBittorrent 4.3.6. Profile/interface naming, PIA behavior, x86/x64 paths and other versions require Windows validation. No user's addresses, credentials, logs, or preferred region list are embedded in the engine.

## Installation

Keep the installer, engine, launcher and `config.example.json` together. Run as the Windows user who will run the task:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-QbtGuard.ps1
```

The installer asks for URL/user/password and saves the password with Windows DPAPI. The default destination is `%LOCALAPPDATA%\qBtGuard`. It refuses existing destinations and existing task names. Use `-NoTask` for isolated QA; `-TaskName` permits a distinct test task. The task repeats every ten minutes while the installing user is logged on and runs hidden. Do not schedule multiple installations against the same qBittorrent instance.

After installation edit only the installed `config.json`. Paths, interface names, and PIA regions are configuration, not repository edits. For remote Web UI use set `RemoteEndpoint: true`; deletion still acts on that remote server if explicitly enabled. Remote downloads are not mapped into local paths by this candidate.

Run the installed engine manually and inspect its `qbtguard.log`. Completion entries include file findings, MKVs checked/skipped/unreadable, and torrent removals. A zero finding count with skipped MKVs does not mean every video was inspected. Header inspection accepts EBML, not full container integrity, codec validity, playable media, or absence of malware. MP4 or another legitimate format renamed `.mkv` will be flagged, so leave invalid-MKV deletion off until that policy is reviewed. No age-based disk cleanup is included.

API calls and PIA commands have timeouts. Failures log a stage and exception type rather than raw credential-bearing exceptions. Logs contain file/torrent names and must remain private. The engine rechecks torrent existence before deletion and verifies API removal; it does not independently establish all downloaded data has disappeared from disk.

## Migration and rollback

See [MIGRATION.md](MIGRATION.md). The candidate installer does not automatically disable any existing task or turn enforcement on. Preserve old scripts, credentials, task XML and state until the new installation has passed Windows QA. Do not copy personal logs/configuration into this repository.

Uninstall with `Uninstall-QbtGuard.ps1 -Destination <installed-directory>` and optional `-TaskName`. It removes only a task whose action matches that installation and retains installed files. Downloads are untouched.

## QA status

The prior audit preview was exercised on one Windows installation. That evidence does not validate these new corrective actions. Windows CI parses all scripts and runs mocked Pester regressions. Clean-machine installation, real PIA failover, adapter/profile binding and qBittorrent restart are manual QA requirements. See [tests/README.md](tests/README.md).

HTTP Web UI credentials are unencrypted in transit; use HTTPS or a trusted local connection. Do not expose the Web UI directly to the Internet. DPAPI files are tied to the installing Windows account and machine.

## License

[MIT](LICENSE).

### PIA public-IP discovery

The VPN readiness gate uses PIA's Connected state and the configured Up adapter with a usable Preferred local IPv4 address. The saved and live qBittorrent interface bindings remain separately checked. Public exit-IP discovery (`piactl get vpnip`) is not a gate: a live integration test observed `Unknown` alongside Connected, a usable WireGuard tunnel and an assigned forwarded port. This change avoids blocking port synchronization on unavailable address telemetry; it does not independently prove end-to-end Internet reachability. PIA CLI failures and unavailable local tunnel checks still fail the cycle. VPN BLOCKED log messages identify unsuccessful readiness checks.
