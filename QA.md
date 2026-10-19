# qBtGuard 0.2.0 pilot validation

## Tested implementation

Engine commit: `f9fc69e96df5a8fb2137c1a1a2e75e1bb138f87f`.
Environment: Windows, Windows PowerShell 5.1, Pester 3.4.0, qBittorrent 4.3.6 and local PIA/WireGuard integration.
No addresses, account names, credentials, personal torrent names or raw logs are included in this report.

## Evidence

| Check | Observed result |
|---|---|
| Windows CI syntax and regression suite | 84 passed; 0 failed/skipped/pending |
| Pilot regression suite | 84 passed; 0 failed/skipped/pending |
| Audit action gate | Mocked regressions plus scoped live audits proposed actions without deletion |
| VPN profile/interface compatibility | Saved display name and distinct internal ID accepted; live API binding checked |
| qBittorrent restart | Missing process restarted in an isolated enforcement test after readiness and binding checks |
| PIA port synchronization | Deliberately mismatched listening port changed to the forwarded port and verified |
| VPN recovery | Revised bounded connect/retry implementation completed an unattended region recovery |
| Prohibited-extension fixture | Scoped audit flagged the file; enforcement removed torrent; both fixture data files verified absent |
| Extensionless fixture | Repeated using a verified 100% complete torrent; scoped enforcement removed torrent and both data files |
| Invalid MKV header fixture | Scoped audit inspected one completed MKV and reported invalid EBML signature; enforcement removed torrent and both data files |
| Initial whole-queue enforcement | 1,499 files, 358 MKVs inspected, 13 skipped; no findings/unreadable MKVs/removals |
| Silent scheduled execution | Replacement task returned 0 and continued on its ten-minute schedule |
| October 19 check | Latest task run 09:07 local returned 0; next run 09:17; both legacy tasks disabled |
| Quiet log observation | Successful heartbeats October 17 and 19; no errors or findings in the supplied log; latest heartbeat inspected 1,906 files and 503 MKVs, with 7 skipped |

The pilot cutover occurred October 15, 2026, after exporting old task definitions and copying installations into a private rollback directory. Production enabled PIA recovery, port synchronization, guarded restart and prohibited/extensionless deletion. Invalid-MKV deletion remained disabled after its isolated fixture test. The active installation retained its original QA directory name.

## Interpretation and limits

The observation covers October 15–19, not an independently verified history of every scheduled execution. Quiet logging omits uneventful enforcement summaries, and Task Scheduler's latest result establishes only the latest run. No organic prohibited-file event was recorded during the supplied observation; deletion evidence comes from controlled fixtures.

The first recovery test needed a manual reconnect and did not pass unattended QA. The implementation was revised and the subsequent recovery test completed without that assistance. The initial extensionless deletion attempt left files behind with unresolved location/completion issues; it was repeated from torrent creation with correct source data and verified completion. Do not count the initial attempt as a successful data-deletion test.

MKV inspection checks the EBML signature only. It does not establish complete container integrity, valid codecs, playability or absence of malware. Skipped and unreadable MKVs are not deletion triggers. A valid file in another container renamed as MKV can be flagged.

The original heartbeat rule writes only if the log is missing or older than 00:01 on the previous local calendar day; every-other-day heartbeats can therefore be expected. Findings, notices, actions and failures log immediately.

Clean-machine installation, different Windows/qBittorrent/PIA versions, remote API installations and alternate profile layouts are not established by this pilot. The task requires the installing user to be logged in and the computer awake. Following a reboot, user sign-in is required. No age-based disk cleanup is included.
