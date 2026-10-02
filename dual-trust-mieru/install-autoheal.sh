#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'ERROR: run as root' >&2; exit 1; }
install -m 0755 "$B/dual-autoheal.sh" /usr/local/sbin/dual-tunnel-autoheal
cat > /etc/systemd/system/dual-tunnel-autoheal.service <<'EOT'
[Unit]
Description=Dual Naive/Mieru conservative auto-heal
After=network-online.target dual-naive-client.service dual-trust-client.service dual-mieru-carrier.service dual-xudp-bridge.service
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
EOT
cat > /etc/systemd/system/dual-tunnel-autoheal.timer <<'EOT'
[Unit]
Description=Run dual tunnel auto-heal with low-frequency jitter
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=90s
AccuracySec=30s
Persistent=false
Unit=dual-tunnel-autoheal.service
[Install]
WantedBy=timers.target
EOT
systemd-analyze verify /etc/systemd/system/dual-tunnel-autoheal.service /etc/systemd/system/dual-tunnel-autoheal.timer >/dev/null
systemctl daemon-reload
systemctl enable --now dual-tunnel-autoheal.timer
systemctl start dual-tunnel-autoheal.service || true
echo 'SUCCESS: low-frequency randomized auto-heal enabled (5m + up to 90s jitter)'
echo 'Policy: selective carrier restart; shared bridge restart only if BOTH UDP/XUDP paths repeatedly fail.'
