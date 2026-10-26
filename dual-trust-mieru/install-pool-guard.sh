#!/usr/bin/env bash
# Install sidecar to EXISTING Dual pool; no tunnel reinstalls or restarts.
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
MODE=${1:---observe}
[[ "$MODE" == --observe || "$MODE" == --auto ]] || {
  echo 'usage: install-pool-guard.sh [--observe|--auto]' >&2; exit 2;
}
if [[ "$MODE" == --auto && "${DUAL_POOL_GUARD_LIVE_APPROVED:-}" != "YES" ]]; then
  echo 'AUTO mode requires explicit DUAL_POOL_GUARD_LIVE_APPROVED=YES after observe and canary validation' >&2
  exit 3
fi
for p in /etc/dual-trust-mieru/iran/dispatcher.yaml /etc/dual-trust-mieru/iran/controller.secret; do
  [[ -s "$p" ]] || { echo "Missing existing Dual runtime file: $p" >&2; exit 1; }
done
[[ -x /usr/local/lib/dual-trust-mieru/mihomo ]] || { echo 'Existing Mihomo not found' >&2; exit 1; }
command -v curl >/dev/null
command -v python3 >/dev/null
python3 -m py_compile "$B/dual-pool-guard.py"
bash -n "$B/dual-autoheal.sh"

# Never install the Dual-only monitor on unified Triple.
python3 - /etc/dual-trust-mieru/iran/dispatcher.yaml <<'PY'
from pathlib import Path
import sys
x=Path(sys.argv[1]).read_text()
for needle in ('  - name: DUAL', '    type: load-balance', '    strategy: sticky-sessions'):
    if needle not in x:
        raise SystemExit('Unrecognized Dual dispatcher; refusal: '+needle)
if 'XUDP-NAIVE' in x:
    raise SystemExit('Triple/Naive pool detected; refusing Dual-only installer')
if not any(node in x for node in ('      - XUDP-TRUST','      - XUDP-MIERU')):
    raise SystemExit('No active Dual pool carrier')
PY

install -m 0755 "$B/dual-pool-guard.py" /usr/local/sbin/dual-pool-guard
if [[ "$MODE" == --auto ]]; then
  install -m 0755 "$B/dual-autoheal.sh" /usr/local/sbin/dual-tunnel-autoheal
fi
cat >/etc/systemd/system/dual-pool-guard.service <<EOF
[Unit]
Description=Dual pool guard (forced-path health, isolated quarantine)
After=network-online.target dual-dispatcher.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dual-pool-guard --mode ${MODE#--}
Nice=10
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/etc/dual-trust-mieru/iran /var/lib/dual-trust-mieru /run
PrivateTmp=true
TimeoutStartSec=120
EOF
cat >/etc/systemd/system/dual-pool-guard.timer <<'EOF'
[Unit]
Description=Low-noise Dual forced-path health guard
[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
RandomizedDelaySec=15s
AccuracySec=5s
Persistent=false
Unit=dual-pool-guard.service
[Install]
WantedBy=timers.target
EOF
systemd-analyze verify /etc/systemd/system/dual-pool-guard.service /etc/systemd/system/dual-pool-guard.timer >/dev/null
systemctl daemon-reload
systemctl enable --now dual-pool-guard.timer
echo "Installed Dual pool guard in ${MODE#--} mode."
echo 'No x-ui, carrier, bridge or dispatcher restart was requested.'
echo 'Inspect: systemctl list-timers dual-pool-guard.timer'
echo 'Logs: journalctl -u dual-pool-guard.service --since "-10 minutes" --no-pager'
