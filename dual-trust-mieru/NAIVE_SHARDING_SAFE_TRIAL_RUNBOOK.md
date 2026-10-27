# Naive instability repair — isolated two-client pilot (2026-10-27)

## Current incident evidence
Iran host: maya11; foreign Naive: 141.11.181.50; Mieru: 141.11.181.51.
Naive intermittently has BOTH failed direct SOCKS :7993 and split :7991 HTTP204 probes while UDP continues working. Role-local nm-naive-client restart restores it. HA agent on Oct 27 15:16:17 UTC performed a real Naive restart and recovered it, then Naive displayed sporadic further SUSPECT states while Mieru stayed healthy. Real sampled new-flow ratio was 349/351 (almost 50/50) but sampled Naive bytes were 19.2%. A 60-second traffic snapshot is NOT proof of a particular cause.

The live Iran architecture starts ONE NaiveProxy client process on 127.0.0.1:7993 and uses many HTTP/2 CONNECT streams. The remote Naive foreign is Caddy forwardproxy :443 and Xray loopback :2443. A single long-lived multiplexed upstream path MAY be vulnerable to saturation or stalls, but resource limits, upstream IPv4 path and foreign Caddy bottlenecks are unproven. Do not claim the root cause is known.

## Fix candidate
Stage TWO independent NaiveProxy clients with the SAME existing credentials/foreign endpoint:
- :17993 Naive shard A
- :17994 Naive shard B
- isolated Mihomo sharding front on an automatically chosen :17995/:17996/... (stored in /etc/dual-trust-mieru/naive-shards/stage-port)
- original production :7993, :7991, :7990, HA timer, x-ui, Mieru, XUDP bridge, dispatcher remain unchanged during STAGE and A/B trial.

The pilot separates Naive client process/socket state; it does NOT add a second independent foreign server, change censorship, or create additional outbound IP diversity. Mieru should NOT become the sole failover strategy long-term; an independent 2nd Naive foreign with its own hostname and IP would be necessary to remove single-foreign concentration.

## Safety
- Never use fresh installers, do not reload live dispatcher, x-ui, bridge, foreign Caddy, or sysctl during the pilot.
- Replacing the Naive foreign from the old single-client wizard after a sharded cutover is blocked: the old wizard would otherwise modify an unused single-client config.
- HA remains armed in production; this test is OFF the production routing path.
- Shadow trial creates extra isolated processes and minor synthetic load against SAME foreign. It may indicate client-side problems but cannot prove performance under full live traffic.
- Do not run CUTOVER until A/B and foreign resource reports are assessed. Cutover stops/restarts ONLY the Naive-facing role at :7993 and existing Naive sessions will reconnect; a rollback exists, but no zero-loss promise. Existing HA currently restarts Naive gateway only and is not yet shard-aware; review before production cutover.

## Commands on Iran maya11 after updating to tested commit
Read-only status:
  sudo bash /opt/frp-tunnel-nm/dual-trust-mieru/nm-naive-inspect.sh iran
  sudo bash /opt/frp-tunnel-nm/dual-trust-mieru/nm-naive-shards-maintenance.sh status

To stage isolated Naive clients without moving real users:
  sudo bash /opt/frp-tunnel-nm/dual-trust-mieru/nm-naive-shards-maintenance.sh stage
  sudo python3 /opt/frp-tunnel-nm/dual-trust-mieru/nm-naive-shards-compare.py --rounds 24 --gap 2

If staging already happened, do NOT run it again. Use status + comparison.
For the operator menu:
  sudo helper
  12 = confirm isolated stage (no live cutover)
  13 = A/B probe
  14 = stage status

## Commands on CURRENT Naive Foreign 141.11.181.50
On a trusted root SSH session use read-only inspection script pinned to approved GitHub SHA:
  bash /opt/frp-tunnel-nm/dual-trust-mieru/nm-naive-inspect.sh foreign
If repo absent on foreign, fetch ONLY the inspected diagnostic from same commit via raw.githubusercontent.com into a temporary file, verify URL and inspect it, then execute as root. Do not run install-foreign scripts again.

Report CPU, memory pressure, TCP retrans/timeouts, Caddy service NRestarts/RSS/FD and inbound TCP443 established counts; do not share foreign bundle/password or Caddyfile containing credentials.

## Interpretation
- Original :7993 bad while shadow gateway healthy under same network/foreign => client-side state or saturation is plausible. Repeated A/B should support sharding deployment after additional HA shard-aware upgrade.
- Both original and shadow bad simultaneously while Mieru healthy => foreign Naive Caddy/transport, common upstream or IP path is suspect; sharding to same foreign won't fix it. Diagnose Caddy memory/CPU/TCP and network, consider adding 2nd Naive foreign with separate provider.
- Foreign CPU throttling/pressure/file exhaustion => repair that resource bottleneck BEFORE cutover, with isolated canary and maintenance approval.
- Both A/B paths healthy => do not infer defect fixed. Need observe at peak traffic and correlate failures.
- Observed failures are application-path failures, NOT conclusive proof of network censorship.

## Future work after evidence
If sharding convincingly helps, update HA logic to be sharding-aware (restart failing Naive shard rather than merely local gateway) before any production cutover, and add long-duration canary measurements. Document tests and provide explicit maintenance rollback.
