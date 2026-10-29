# Mieru UDP/XUDP diagnostic and native SOCKS-UDP shadow canary

Date: 2026-10-29. Iran server maya11, Mieru foreign didi2 (141.11.181.51), Naive foreign didi1 (141.11.181.50).

## Confirmed observations
- On Mieru foreign didi2: `mita` and `dual-xudp-mieru` active. TCP loopback Xray `127.0.0.1:2443` listening. Direct DNS via UDP/53 to three resolvers passed 6/6.
- On Iran maya11: Xray Bridge and Mieru Carrier active. Through Mieru SOCKS `:7994`, TCP CONNECT to foreign `127.0.0.1:2443` succeeded. However this tests TCP *reachability* only, not successful VLESS authentication or XUDP data forwarding.
- On Iran maya11: Naive XUDP :7991 passed 6/6, Mieru XUDP :7992 failed 0/6 (all timeout), Mieru native SOCKS UDP on :7994 passed 6/6, dual selected :7990 passed 2/6.
- Mieru TCP/HTTPS and Telegram healthy. HA still shows Mieru HEALTHY because existing classifier does not inspect UDP, and DUAL-AUTO is still selecting Mieru for some UDP traffic.
- Direct Mieru UDP and foreign UDP egress are good; failure is isolated to the extra `Xray VLESS/XUDP` branch, its VLESS authentication/configuration, XUDP framing or relay; not proof of censorship or a specific bug.

## Current production design
Iran dual-xudp-bridge `:7992` UDP routing rule:
`mieru-in,network=udp -> xudp-mieru`; Xray VLESS outbound dials foreign loopback :2443 through SOCKS :7994.
Direct Mieru `:7994` SOCKS already supports UDP over its encrypted foreign transport, according to live DNS tests.

## Non-disruptive alternative
`nm-mieru-native-udp-canary.py` creates an isolated *temporary* Xray bridge bound only to 127.0.0.1:17992 with `mieru-in` SOCKS UDP and the existing local `carrier-mieru` SOCKS outbound at :7994. No VLESS/XUDP hop is used for this shadow branch.
The candidate reads `/etc/dual-trust-mieru/iran/xudp.json` (never prints it), checks exact known input and SOCKS outbounds, creates a mode 0600 temporary JSON, validates with Xray -test, runs a temporary Xray subprocess, probes 3 DNS resolvers and HTTP via 4 independent ports, then terminates subprocess and deletes config.
It does NOT edit x-ui, dispatcher, bridge, Mieru carrier, HA state, panel, or user config.

Run on maya11 (pinned tested commit):
```sh
cd /opt/frp-tunnel-nm
sudo python3 dual-trust-mieru/nm-mieru-native-udp-canary.py --rounds 3
```
Ensure the companion file `nm-mieru-udp-diagnose.py` is present at the same revision. If local checkout not updated, fetch both via raw GitHub with exact approved commit into a root-owned temporary directory. No live cutover is authorized by this runbook.

### Interpretation
- If native bridge :17992 UDP DNS passes 9/9 and HTTPS also passes while current :7992 fails, the new topology is a strong targeted *workaround candidate*. Long-term UDP443/QUIC and performance testing still needed; DNS success does not prove all UDP payloads.
- If :17992 also fails, DO NOT edit live Xray configuration. Investigate Xray SOCKS UDP outbound compatibility, Mux/XUDP settings, VLESS UUID handshake and the remote Xray service logs.
- If Mieru direct :7994 fails, treat as carrier issue, not native-bridge fix.

### Production safety and future work
Once candidate passes, build a separately reviewed `cutover` utility with atomic backup, strict preflight checks (both Naive and Mieru, HA active, exact config schema), interactive confirmation, test and automatic rollback. Switching live Xray Bridge will restart `dual-xudp-bridge` and can interrupt BOTH Naive and Mieru TCP/UDP users, since :7991 and :7992 share the service. Schedule in low traffic and do not claim zero disruption. Alternatively, design a more complex zero-shared-restart listener migration. NEVER automatically execute a production bridge restart just from a green synthetic test.
HA must eventually monitor TCP and UDP separately; do not blindly quarantine otherwise working Mieru TCP due to UDP-only failure. For Control Room show an independent UDP/XUDP health field with last successful test.

## Shadow validation — confirmed on real maya11
At 2026-10-29, user ran the candidate on Iran maya11:
- NAIVE_CURRENT_XUDP :7991 = 9/9 DNS successes.
- MIERU_CURRENT_XUDP :7992 = 0/9 DNS successes (all timeouts).
- MIERU_NATIVE_DIRECT :7994 = 9/9 DNS successes.
- MIERU_NATIVE_BRIDGE_CANDIDATE :17992 = 9/9 DNS successes.
- HTTPS regression: Mieru production :7992 PASS; isolated native Mieru :17992 PASS.
The candidate was deleted after tests. This is compelling evidence that native Mieru SOCKS UDP via Xray works in this environment. DNS success does not prove all QUIC, games or sustained load.

## Guarded production change (AVAILABLE, NOT YET APPLIED)
File: `nm-mieru-native-udp-cutover.py` (plan / status / cutover / rollback).
Change is EXACTLY one existing live Xray rule: inbound `mieru-in`, `network=udp`, outbound `xudp-mieru` -> `carrier-mieru`. All other config is kept untouched. The original Xray :7991 Naive TCP/UDP and Mieru TCP :7992 remain routed as before.

CLI on Iran maya11 after pinned checkout:
```
sudo python3 dual-trust-mieru/nm-mieru-native-udp-cutover.py status
sudo python3 dual-trust-mieru/nm-mieru-native-udp-cutover.py plan
# During low traffic, after operator acknowledges both lanes can have interrupted sessions:
sudo python3 dual-trust-mieru/nm-mieru-native-udp-cutover.py cutover
# If later manual rollback needed (will reintroduce old broken Mieru UDP):
sudo python3 dual-trust-mieru/nm-mieru-native-udp-cutover.py rollback
```
The tool runs the shadow canary again, verifies known exact topology, active production units, HA timer + Selector DUAL-AUTO, and validates the replacement config via Xray -test. It prints the current live connection count and requires interactive `FIX-MIERU-UDP` approval. It serializes with the HA lock; writes an immutable restricted original backup under `/var/lib/dual-trust-mieru/naive-mieru/mieru-udp-native/original.json`, and only then atomically updates `xudp.json` and restarts shared `dual-xudp-bridge.service` ONCE.

Postflight checks UDP to 3 independent DNS resolvers for Naive :7991, Mieru :7992 and Dispatcher :7990, and HTTP over all three. Failing these tests triggers attempted automatic restoration of original config and SECOND Bridge restart. If both are broken, report critical error and investigate manually (backup is preserved). Successful cutover records state LIVE. Manual rollback requires exact backup/current SHA checks and an additional interactive confirmation.

Caution: Restarting dual-xudp-bridge disrupts established sessions on BOTH branches. Do NOT perform during peak traffic or when the other role is unhealthy. The one-time interruption is deliberate and cannot be advertised as zero downtime. No changes to x-ui, Mieru carrier process, Naive carrier, dispatcher or HA selection. The old HA still only checks HTTP, not UDP; extend telemetry and healthy-state criteria separately after proven cutover. No automated route changes based only on short DNS probes.
