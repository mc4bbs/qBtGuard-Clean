# Consolidation and enforcement QA

This procedure is for anyone replacing older qBittorrent/PIA scripts. No production changes have been performed by this branch.

1. Inventory all tasks and startup launchers targeting qBittorrent or PIA. Record their accounts, paths, intervals, current configuration and capabilities. Back up task XML, scripts, credentials and persistent state privately.
2. Install this candidate into a new directory with `-NoTask`. Retain the old working installation. Configure the candidate for the actual machine and VPN adapter; keep audit mode enabled. Do not reuse another Windows user's DPAPI credential.
3. Run Windows syntax and mocked regression tests. Run a live audit and confirm API authentication, interface binding, forwarded-port discovery and MKV coverage. Compare results to the existing script. Concurrent old automation can remove findings before an audit sees them.
4. On an isolated test instance, exercise each enforced action independently: prohibited extension, extensionless file, invalid header, unreadable/missing MKV, healthy restart, blocked restart, port change, reconnecting VPN, explicit forwarding failure, recovery timeout and corrupt cooldown file. Use disposable torrent data. Verify no mutation in audit mode and no unintended deletion on failures.
5. Confirm the intended qBittorrent profile and adapter names agree before enabling restart. This candidate supports the 4.3.6 `Connection\Interface` profile key; other profile layouts fail closed and need an explicit implementation/test update.
6. For cutover, first disable the verified old tasks and wait for all their active runs to finish. Keep backups and do not delete the old installation. Enable the desired candidate action flags and enforcement mode, manually verify a cycle, then register exactly one task using the candidate launcher and intended Windows account. The stock installer refuses existing destinations/tasks; task replacement must be performed separately after review.
7. Verify the hidden launcher propagates a failure exit code, the task succeeds every ten minutes, and log summaries show actual coverage. Confirm kill-switch and qBittorrent binding behavior while PIA is disconnected.
8. For rollback, disable and stop the new task/run before re-enabling the old task. Restore old configuration/state if altered. Deleted torrent data is irreversible through this script; recover from independent backups if available.

Keep audit mode on and existing production protection in place until the candidate clears QA. The old deletion script may remain enforced during read-only comparison; never leave both enforcement engines scheduled after cutover.
