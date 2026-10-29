#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ss -ltn '( sport = :18080 )' | grep -q ':18080'; then
 echo "Port 18080 occupied. Aborting without changes."; exit 1
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y haproxy curl python3
install -d -m 0750 /etc/dual-ha
install -d -m 0755 /usr/local/lib/dual-ha
install -m 0640 "$BASE/haproxy.cfg" /etc/dual-ha/haproxy.cfg
install -m 0755 "$BASE/health.py" /usr/local/lib/dual-ha/health.py
cat >/etc/systemd/system/dual-ha-haproxy.service <<'EOF'
[Unit]
Description=Isolated HAProxy for dual tunnel SOCKS egress
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
RuntimeDirectory=dual-ha
RuntimeDirectoryMode=0750
ExecStartPre=/usr/sbin/haproxy -c -f /etc/dual-ha/haproxy.cfg
ExecStart=/usr/sbin/haproxy -W -db -f /etc/dual-ha/haproxy.cfg
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/dual-ha-health.service <<'EOF'
[Unit]
Description=Dual tunnel end-to-end SOCKS egress health controller
After=dual-ha-haproxy.service
Requires=dual-ha-haproxy.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 -u /usr/local/lib/dual-ha/health.py
Restart=always
RestartSec=5
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
/usr/sbin/haproxy -c -f /etc/dual-ha/haproxy.cfg
systemctl daemon-reload
systemctl enable --now dual-ha-haproxy.service dual-ha-health.service
echo "Staging gateway on 127.0.0.1:18080; Xray :443 unchanged."
