#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'ERROR: run as root' >&2; exit 1; }
[[ -x "$B/dual-autoheal.sh" ]] || chmod 0755 "$B/dual-autoheal.sh"

install -m 0755 "$B/dual-autoheal.sh" /usr/local/sbin/dual-tunnel-autoheal

cat > /etc/systemd/system/dual-tunnel-autoheal.service <<'EOF2'
[Unit]
Description=Dual Trust/Mieru conservative auto-heal probe
After=network-online.target dual-trust-client.service dual-mieru-carrier.service dual-xudp-bridge.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dual-tunnel-autoheal
Nice=10
IOSchedulingClass=idle
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/dual-trust-mieru /run
PrivateTmp=true
EOF2

cat > /etc/systemd/system/dual-tunnel-autoheal.timer <<'EOF2'
[Unit]
Description=Run dual tunnel auto-heal every 30 seconds

[Timer]
OnBootSec=45s
OnUnitActiveSec=30s
AccuracySec=5s
Persistent=false
Unit=dual-tunnel-autoheal.service

[Install]
WantedBy=timers.target
EOF2

systemd-analyze verify /etc/systemd/system/dual-tunnel-autoheal.service /etc/systemd/system/dual-tunnel-autoheal.timer
systemctl daemon-reload
systemctl enable --now dual-tunnel-autoheal.timer
systemctl start dual-tunnel-autoheal.service
systemctl is-enabled --quiet dual-tunnel-autoheal.timer

echo 'SUCCESS: conservative dual tunnel auto-heal enabled'
echo 'Policy: 2 consecutive bad cycles; restart only failed carrier; bridge restart only for repeated path-only failures.'
echo 'Logs: journalctl -t dual-autoheal -n 100 --no-pager'
