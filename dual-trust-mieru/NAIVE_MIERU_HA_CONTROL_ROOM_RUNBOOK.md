# NAIVE + MIERU HIGH AVAILABILITY — OPERATIONS RUNBOOK
Date: 2026-10-27
Scope: new Iran maya11, foreign Naive 141.11.181.50 and foreign Mieru 141.11.181.51.
Source branch: naive-mieru-live-safe-v1. Pin an approved Git commit when deploying.

## Why this exists
Under sustained load, Naive sometimes fails direct HTTP on local SOCKS :7993 and split TCP :7991 while UDP/XUDP continues working and the nm-naive-client daemon remains active. Restarting only nm-naive-client temporarily restores HTTP. The old nm-autoheal.sh checked only daemon and listening socket, so it did not detect this data-plane failure.
Mieru :7994 direct / :7992 split stayed healthy.

## Architecture (after explicit one-time bootstrap)
- x-ui :443 -> SOCKS localhost:7990 -> selector DUAL
- DUAL default DUAL-AUTO -> load-balance round-robin [XUDP-TRUST (Naive), XUDP-MIERU (Mieru)]
- While Naive down: DUAL selector -> XUDP-MIERU
- While Mieru down: DUAL selector -> XUDP-TRUST
- After both healthy for >=3 checks: DUAL -> DUAL-AUTO
- This changes selection for new flows; existing sessions can still be interrupted if carrier must restart, and one-time bootstrap reload can interrupt both paths.

The Mihomo API requires a Selector group for PUT /proxies/DUAL. Original DUAL is a LoadBalance and does NOT support manual selection. Do not attempt to update it directly without the guarded one-time bootstrap.

## New files
- nm-ha-agent.py: production-local HA engine, idempotent state file, read-only probes, explicit bootstrap, role restart once, Selector quarantine/recover.
- nm-ha-install.sh: guarded non-disruptive installer, creates systemd units but DOES NOT enable timer or bootstrap.
- nm-ha-telemetry.py: signed outbound HTTPS status push, no inbound port on Iran.
- nm-ha-test.py: offline state-machine tests.
- nm-helper.sh: original management menu, option 11 HA status.
- Separate panel handoff: https://github.com/aliiitavazoeiii-afk/vpn-managrer/blob/main/docs/CONTROL_ROOM_TUNNEL_TELEMETRY_HANDOFF.md

## Deploy (Iran maya11 only)
First update the checked-out repository to approved SHA and install:
  cd /opt/frp-tunnel-nm
  git diff --quiet
  git diff --cached --quiet
  git fetch --no-tags origin naive-mieru-live-safe-v1
  git checkout --detach APPROVED_COMMIT_SHA
  sudo bash dual-trust-mieru/nm-install-manager.sh
  sudo bash dual-trust-mieru/nm-ha-install.sh

During install, all five services must be active. Installer runs only dry-run health probes, creates root-only HA files, loads service definitions. It DOES NOT reload dispatcher, restart carriers, or enable auto timer. Read-only:
  sudo nm-ha status
  sudo systemctl list-timers nm-ha.timer --all

Then explicitly arm the original dispatcher once. Preferred path: when GET /connections returns zero active connections, run:
  sudo nm-ha bootstrap
  sudo systemctl enable --now nm-ha.timer

If live traffic NEVER reaches zero, operator MAY choose a maintenance window and run:
  sudo nm-ha bootstrap --allow-active-reload
  [must TYPE RELOAD-WITH-ACTIVE-USERS at interactive terminal]
  sudo systemctl enable --now nm-ha.timer

CAUTION: one-time reload may terminate both paths' existing connections; no zero-loss guarantee. DO NOT change the existing dispatcher.yaml by hand, restart shared services, or apply unattended reload with live clients. Bootstrap validates exact reviewed YAML, tests temporary config and captures rollback backup. If config differs it will refuse to act.

Verify after arming:
  sudo nm-ha status
  sudo systemctl status nm-ha.timer --no-pager
  sudo journalctl -u nm-ha.service -n 50 --no-pager
  sudo dual health --full all
  sudo helper   # option 11 reports HA state

### Health classification
Each sweep: Naive direct 7993 HTTP204, split 7991 HTTP204, Telegram 7991 HTTPS; Mieru direct 7994, split 7992, Telegram 7992.
- HEALTHY if both HTTP204 checks pass.
- DOWN if all THREE probes fail.
- DEGRADED if some partial success.
- 2 consecutive DOWN sweeps + peer confirmed HEALTHY -> restart only affected carrier ONCE; persist attempt before action.
- Re-probe; if still down choose peer in DUAL Selector by local authenticated controller API. No dispatcher/systemd restart during ongoing failover.
- 3 consecutive HEALTHY sweeps for both -> DUAL-AUTO 50/50 new flows.
- BOTH_DOWN sends one deduplicated critical event and avoids blindly switching/restarting all services.
- If Controller API missing, lock busy, or service state uncertain: fail closed; timer retries, does NOT restart shared systems.
Automatic checks run with timer OnUnitInactiveSec=40s, not exact fixed schedule. The classifier errs toward false negatives rather than dropping working sessions on one failed HTTP endpoint. Telegram result may be affected by upstream policies. Do not equate HTTP failure definitively with censorship.

### HA telemetry to Hesab panel
Create unique key per Iran host in Control Room. Config root-only /etc/dual-trust-mieru/ha-telemetry.json:
  {
    "endpoint": "https://hesab.filmjadiid.ir/api/control-room/heartbeat",
    "server_id": "maya11",
    "secret": "REPLACE_WITH_RANDOM_UNIQUE_SECRET_FROM_PANEL"
  }
Then chmod 600 and run:
  sudo nm-ha-telemetry
  sudo systemctl enable --now nm-ha-telemetry.timer
The panel heartbeat endpoint MUST exist and HMAC validation MUST be implemented BEFORE enabling sender; otherwise sender will fail independently and local failover will still work. NEVER paste secrets/bundles into chat or GitHub. HMAC defined in panel handoff. Users are alerted via existing SMS service in Hesab platform; SMS has not been enabled solely by tunnel agent installation.

### Incident response and rollback
  sudo journalctl -u nm-ha.service --since '-1h' --no-pager
  sudo nm-ha status
  sudo dual health --full all
  sudo dual audit --seconds 60

To disable automated role actions without any network restart:
  sudo systemctl disable --now nm-ha.timer
This does NOT automatically change an already quarantined selector. For manual selection in an incident, use a carefully reviewed local Controller action; do NOT paste API secret into chat.

Initial bootstrap saves original config to:
  /var/lib/dual-trust-mieru/naive-mieru/ha/dispatcher-before-ha.yaml
For full config rollback, schedule maintenance; stop HA timer, verify backup and server, restore with tested Mihomo /configs API and disk backup. Reload may interrupt users. Do not run automated rollback without verification.

### What is NOT yet done
- This runbook and code do not prove behavior on maya11 until installer + bootstrap are executed by operator and a controlled live outage simulation passes.
- Control Room UI + SMS integration belongs to vpn-managrer project and requires separate, non-destructive implementation, staging and data backup.
- Guaranteed zero packet loss is not possible when the active transport's carrier process must restart or when an established flow is routed through a failed foreign node.
