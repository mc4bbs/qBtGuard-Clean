# Test plan (not yet automated)

The preview is **not validated on other machines**. Before public release, test on a clean Windows 10/11 VM with qBittorrent 4.3.6 and Web UI API v2.

1. Installation with and without a scheduled task; repeat installation; uninstallation.
2. Correct DPAPI authentication and wrong password, server unavailable, TLS failure.
3. Completed and incomplete torrents, nested directories, extensionless and prohibited files.
4. Valid EBML header, invalid header, unreadable file, missing UNC share.
5. Path traversal attempts, including absolute paths, dot-dot segments and alternate separators.
6. Scheduled task running under the intended user and while logged out.
7. Verify no delete, PIA, or qBittorrent lifecycle actions occur.
8. Scan all source and commit history for secrets before changing visibility to public.
