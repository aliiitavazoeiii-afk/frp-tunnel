# Solo Backhaul — Maya1 first, reversible rollout

**Phase 0 implemented:** read-only inventory + private production snapshot on Maya1.
**Phase 1 implemented, but OBSERVE ONLY:** real end-to-end Xray client monitor, every 60s, two independent consecutive failed checks.
**Not deployed / not implemented yet:** Foreign4 provisioning, live X-UI routing edits, removing the gateway from production, actual remote failover switch command, and the Control Room UI.

## Baseline

- Frozen source reference: https://github.com/aliiitavazoeiii-afk/frp-tunnel/tree/backup-dual-backhaul-2026-11-28
- Development: https://github.com/aliiitavazoeiii-afk/frp-tunnel/tree/solo-backhaul
- GitHub source backup is NOT a live VPS backup.
- The existing VPN serves real users; never stop its live routing while only auditing.

## IMPORTANT: HAProxy has two DISTINCT jobs

1. Gateway to REMOVE later: local balancing proxy 127.0.0.1:18080, which distributes to two Backhaul SOCKS endpoints.
2. Internal HTTP/WSS router to KEEP: the HAProxy instance inside the original WSSMux carrier path (for example maya1-next-bh1-router.service). Removing that changes WebSocket handling and the tunnel signature.

NEVER issue a global pkill haproxy or disable every haproxy service. Preserve TLS, SNI, ALPN, WS paths, credentials, Backhaul binaries, Pool Guard and client REALITY settings.

## Phase 0: safe commands ON MAYA1 ONLY (94.184.4.38)

Use an EXACT, verified commit in REF, not a moving branch:

    REF=REPLACE_WITH_VERIFIED_SOLO_COMMIT_SHA
    curl -fsSLo /root/solo-maya1-preflight.py \
      "https://raw.githubusercontent.com/aliiitavazoeiii-afk/frp-tunnel/$REF/solo-backhaul/maya1_preflight.py"
    python3 -m py_compile /root/solo-maya1-preflight.py
    sudo python3 /root/solo-maya1-preflight.py audit --probe
    sudo python3 /root/solo-maya1-preflight.py snapshot
    sudo python3 /root/solo-maya1-preflight.py plan --probe

Audit detects the ACTIVE Backhaul local SOCKS port from the live gateway stats; old files mention both 21001 and 21101, so never assume either is currently live. It reports only service states and redacted Xray counts, and optionally probes the existing direct and gateway egress.

Snapshot uses SQLite online backup and integrity_check on /etc/x-ui/x-ui.db and archives /etc/dual-ha, /opt/dual-ha, related Xray configs and relevant systemd/HAProxy files as root-only artifacts under /root/solo-backhaul-snapshots. It records SHA256 and unit status. On PostgreSQL or nonstandard X-UI database path it stops rather than taking a partial database backup. The archive may contain credentials: NEVER post it publicly or in chat. Foreign VPS snapshots must be captured separately before remote changes.

### Proposed later direct path (NOT performed by audit)

BEFORE:
  User -> REALITY Xray -> SOCKS outbound -> 127.0.0.1:18080
       -> HAProxy leastconn -> main Backhaul SOCKS -> unchanged WSSMux -> Foreign1

AFTER:
  User -> SAME REALITY Xray -> SOCKS outbound -> main Backhaul SOCKS directly
       -> SAME unchanged WSSMux -> Foreign1

Actual SOCKS port is verified on each node. Only after a 1-user REALITY canary may the X-UI SOCKS outbound target be changed from 18080 to that port. Xray reload can disrupt existing sockets: never promise zero interruption. Once the direct route is proven, separately drain and disable gateway + old health controller, and later disable the second lane. Preserve backups and verify an end-to-end restore.

## Monitor on VPN management server (unarmed)

3x-ui is a SERVER-side panel and cannot independently perform a real VLESS/REALITY client probe. Run a genuine Xray client with 3 separate VLESS/REALITY test profiles, each exposing its own SOCKS5 listener bound only to 127.0.0.1. Those are used by solo_monitor.py. Do not post private REALITY test links or client credentials.

Sample /etc/solo-backhaul/monitor.json (owned by root, mode 0600; substitute verified PUBLIC egress IPs):

    {
      "interval_seconds": 60,
      "nodes": [
        {
          "id": "maya1",
          "socks_port": 23101,
          "primary_egress_ip": "REPLACE_WITH_VERIFIED_PRIMARY_EGRESS_IP",
          "standby_egress_ip": "REPLACE_WITH_VERIFIED_FOREIGN4_EGRESS_IP"
        }
      ]
    }

The fields allow maya1/maya3/maya4; use 3 entries when ready. Download solo_monitor.py from the same pinned commit, then run:

    sudo python3 /root/solo-monitor.py --config /etc/solo-backhaul/monitor.json --once
    sudo python3 /root/solo-monitor.py --config /etc/solo-backhaul/monitor.json

Default mode NEVER sends commands. A failed HTTPS check, unparseable output, or incorrect public exit IP counts as failed. Two failures must be from checks at least 55 seconds apart; scheduled checks start 60 seconds apart. Any successful check resets the failure count. Status is persisted privately at /var/lib/solo-backhaul/monitor-state.json, including a durable switch latch to prevent repeated actions after restart. No automatic failback.

The optional command execution is disabled unless ALL are present: --armed; root-owned /etc/solo-backhaul/AUTOMATION_APPROVED with exact text SOLO_STANDBY_TESTED_AND_APPROVED, mode 0600; a root-owned 0600 monitor config; and a tested, explicitly supplied fixed argv switch_command. The actual remote switch agent and Foreign4 setup do not exist in this phase: do not arm it now.

## Known limitations

- Management-side failed probe does not prove a foreign IP was censored: test-client problems, management network outages, remote Xray issues, and public probe destination problems can cause a false alarm.
- A single HTTPS test destination has a common failure mode. Add a second independent destination and a standby health test before allowing production switch commands.
- Standby has no normal user traffic but may have minimal synthetic health checks.
- The user configuration can stay unchanged on switchover, but established TCP sessions can disconnect.
- Never restore a stale X-UI SQLite DB over a running production database just to revert one outbound: doing so can overwrite newer user and usage records. Revert only changed settings with a verified manual rollback procedure.

Offline test suite:

    python3 -m compileall -q solo-backhaul
    python3 -m unittest discover -s solo-backhaul -p 'test_*.py' -v

These checks cannot prove real-world throughput, anti-DPI behavior, live port identity, user experience, or safe live cutover.
