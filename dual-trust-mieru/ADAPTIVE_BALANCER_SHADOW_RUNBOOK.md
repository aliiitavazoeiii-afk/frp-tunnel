# Adaptive Naive + Mieru byte balancing — SHADOW / isolated CANARY

## Current production: LEAVE UNCHANGED

- Iran x-ui TCP/443 -> existing Mihomo dual-dispatcher SOCKS 127.0.0.1:7990
- Members: XUDP-TRUST (historical compatibility label for Naive :7991/:7993), XUDP-MIERU (:7992/:7994)
- Strategy: round-robin. Proven to yield approximately 50/50 by newly observed connections, NOT by bytes.
- Do not restart x-ui, dual-dispatcher, dual-xudp-bridge, or either production carrier.
- Do not repurpose port 7990 or use iptables/nftables/TPROXY in this stage.

## Adaptive v1 deliverables

1. `nm-adaptive-core.py`: read-only GET /connections and GET /proxies/XUDP-TRUST + XUDP-MIERU (Mihomo local Controller); polls every 2 seconds, tracks per-session *deltas*; discards the cumulative initial baseline. Persists a root-readable status at /var/lib/dual-trust-mieru/naive-mieru/adaptive/status.json.
2. A 10-minute rolling window of *observable bytes* (not accurate physical wire bytes: flows created and closed entirely between polls are missed, and after a process restart the window resets).
3. Bounded proportional feedback: if both healthy and warm-up finished, new SOCKS selection weights = clamp(0.5 + 0.5 - observed_naive_share, 0.2, 0.8). This is not a guarantee of 50/50 volume. Before the first 120 seconds and 1 MiB: equal weights. A one-sided unhealthy state selects the other role; both unavailable -> reject new CANARY connections.
4. `nm-adaptive-canary.py`: optional real SOCKS5 CONNECT and UDP ASSOCIATE proxy, **127.0.0.1:17990 only**, forwarding via forced-role SOCKS :7991 and :7992. A session is pinned to its selected role, never moved mid-transfer. Canary is bounded to 100 concurrent sessions, intentionally NOT production scale.
5. Self-tests on isolated loopback mock SOCKS servers verify byte counter logic, feedback policy, no stale-data routing, TCP CONNECT, and UDP ASSOCIATE.
6. `nm-adaptive-install.sh`: verifies active protected services and round-robin, runs tests, installs Python and new unit definitions, starts **only** the separate nm-adaptive-shadow service. Installs but DOES NOT start or enable nm-adaptive-canary. Updates `dual adaptive` CLI, backed up before replacement.

## Installation on production Iran (once per version)

From a verified commit in /opt/frp-tunnel-nm, run:

    cd /opt/frp-tunnel-nm/dual-trust-mieru
    sudo bash nm-adaptive-install.sh

Observations:

    dual adaptive
    systemctl status nm-adaptive-shadow --no-pager
    sudo journalctl -u nm-adaptive-shadow --since '-10 min' --no-pager -n 40
    dual status
    dual health --full all

Allow >2 minutes for model warm-up before evaluating decisions. Better gather at least 10–15 min before using the next-connection weights.

## OPTIONAL localhost-only canary tests

If the shadow process is healthy and tests are green:

    sudo systemctl start nm-adaptive-canary
    systemctl is-active nm-adaptive-canary
    curl -4 -sS --socks5-hostname 127.0.0.1:17990 --max-time 12 -o /dev/null -w '%{http_code}\n' https://www.gstatic.com/generate_204
    sudo systemctl stop nm-adaptive-canary

The canary is NOT in user traffic. Never point x-ui or dispatcher at :17990 until independently load tested. The canary's backend endpoint selection is *based on existing dispatcher telemetry*, not on a fully integrated controller of production bytes. For large-scale 45–55% byte targets, further work needs a proven full-traffic proxy, real carrier byte accounting, UDP resilience, and a tested connection-preserving migration. Do not promise exact ratios or zero outages.

## Rollback

To stop the SHADOW service without changing user traffic:

    sudo systemctl disable --now nm-adaptive-shadow.service

Do NOT disable other production services. Existing production traffic stays on Mihomo :7990. There is no firewall/route change to roll back. Previously deployed `dual` command backups are retained under /var/lib/dual-trust-mieru/naive-mieru/adaptive/installer-backup-*/.
