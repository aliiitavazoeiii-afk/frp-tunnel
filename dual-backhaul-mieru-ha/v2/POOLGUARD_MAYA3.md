# Maya3: experimental Backhaul1 physical-pool guard (2026-11-19)

## Evidence and scope
- The Iran server measured 892 **ESTABLISHED TCP sessions from 152.237.230.140** on port 18443 and only 40 from 82.152.132.112 on port 18445.
- Both backends remained UP and handled approximately 300 active SOCKS/TCP connections each. The measurements do **not** demonstrate that the 892 carrier sessions were all idle.
- Direct foreign1 to Instagram TTFB was 140–271 ms across eight tests; Iran to Instagram via Backhaul1 had median TTFB about 670–690 ms. These tests were not simultaneous and cannot attribute all latency to the tunnel.
- Custom Backhaul WSSMux client code responds to each server extra-session request by starting another physical tunnel dial. It had no hard in-flight+active pool cap. The pool management attempts to adjust load but does not bound session creation in that path.

## Proposed mitigation, not yet proven under production
- Apply client-pool-guard.py after the **unchanged** anti-DPI source patch stack, with pinned Backhaul source commit df7966f8f725837a680ea7b90bd37ea52666c277.
- Atomically reserve a slot BEFORE TLS/WebSocket dialing and retain the slot for the lifetime of the physical reverse connection.
- Limit client physical tunnel connections to max(64, min(128, 4*connection_pool)). With default connection_pool=16, cap is 64.
- Keep mux_con=16, existing WebSocket path, ALPN, TLS/SNI, heartbeats, keepalive, transport frame sizes and all anti-DPI patches unchanged.
- Build with pinned Go 1.23.1 (same pinned version used in the original helper).
- Build a separate inactive binary named /opt/dual-ha/bin/backhaul-poolguard-v1 on the **foreign1 VPS only**. No live binary is touched during build.
- Go test/build CI passed after the patch. This is **not** proof that long-lived Instagram behavior improves; the benefit and side effects must be measured after guarded rollout.

## Build only on FOREIGN1 152.237.230.140
On foreign1, fetch build-backhaul-poolguard.sh from an immutable branch commit and run with that same SHA. It refuses if the original client service is inactive or if the candidate binary already exists. Builds and hashes an inactive candidate, with no service restart.

## Guarded activation from IRAN Maya3 (requires downtime permission)
Fetch poolguard-cutover-maya3.py from the same immutable commit. It:
1. Verifies Backhaul1 and Backhaul2 identities and fresh, complete 1MiB transfers on surviving Backhaul2;
2. Verifies ownership/active state and candidate binary on the foreign1 VPS;
3. Discloses live socket count and requires the exact phrase CUTOVER BACKHAUL1;
4. Sets **only** Backhaul1 HAProxy runtime weight to 0 for NEW connections; waits briefly, leaving Backhaul2 unchanged;
5. Saves original foreign binary in /root/dual-backhaul-backups and atomically installs the candidate before restarting only the FOREIGN1 Backhaul client;
6. Verifies Backhaul1 egress + full 1MiB transfers, checks reverse socket count is <=68 and restores original weight;
7. Attempts to restore old foreign binary and weight on failure, keeping Backhaul2 enabled.

**WARNING**: Restarting foreign1 Backhaul disconnects any active streams carried by it. HAProxy cannot migrate established TCP streams. Only do the final activation during an agreed maintenance window; an automatic failover is not a lossless migration.

## Post-deployment checks
- From Iran, ss -Htn state established '( sport = :18443 )' and confirm physical sockets are close to <=65 (64 data+control, allowing brief transient).
- sudo dual status: Backhaul1 UP and weight 1, Backhaul2 UP and weight 1.
- sudo dual jitter 24, then --load 1, compare TTFB p95 and max to baseline. Note provider/user load conditions can differ.
- Check controller logs for enable/disable loops and app experience for at least one peak period.
- If responsiveness deteriorates after the guarded change, run the same poolguard-cutover-maya3.py with --rollback EXACT_FOREIGN_BACKUP_PATH. It verifies the surviving lane again and requires the exact ROLLBACK BACKHAUL1 confirmation before restarting the old foreign client. This again disconnects current Backhaul1 streams.

**Not touched**: Xray/REALITY, HAProxy leastconn config, Backhaul2, TLS/SNI, secret WS paths, other anti-DPI elements.
