#!/usr/bin/env bash
# Installs isolated HAProxy with both backends DISABLED until real egress passes.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ -x /usr/sbin/haproxy ]] || { echo "HAProxy required (already installed by old staging)"; exit 2; }
command -v curl >/dev/null || { echo "curl required"; exit 2; }
if ss -Hlnpt '( sport = :18080 )' | grep -q LISTEN; then
 echo "Local 18080 occupied. First stop old staging with: systemctl disable --now dual-ha-health dual-ha-haproxy"
 exit 3
fi
install -d -m 0750 /etc/dual-ha/v2
install -d -m 0755 /opt/dual-ha
install -m 0640 "$HERE/haproxy.cfg" /etc/dual-ha/v2/haproxy.cfg
install -m 0750 "$HERE/controller.py" /opt/dual-ha/controller.py
/usr/sbin/haproxy -c -f /etc/dual-ha/v2/haproxy.cfg
cat >/etc/systemd/system/dual-ha-v2-gateway.service <<'EOF'
[Unit]
Description=Isolated Dual Backhaul/Mieru HAProxy SOCKS switch
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
RuntimeDirectory=dual-ha-v2
RuntimeDirectoryMode=0750
ExecStartPre=/usr/sbin/haproxy -c -f /etc/dual-ha/v2/haproxy.cfg
ExecStart=/usr/sbin/haproxy -W -db -f /etc/dual-ha/v2/haproxy.cfg
Restart=on-failure
RestartSec=2
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/dual-ha-v2-health.service <<'EOF'
[Unit]
Description=Dual HA HTTPS end-to-end failover controller
Requires=dual-ha-v2-gateway.service
After=dual-ha-v2-gateway.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 -u /opt/dual-ha/controller.py
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
python3 -m py_compile "$HERE/controller.py"
systemctl daemon-reload
systemctl enable --now dual-ha-v2-gateway dual-ha-v2-health
sleep 2
systemctl is-active --quiet dual-ha-v2-gateway || exit 3
systemctl is-active --quiet dual-ha-v2-health || exit 3
echo "Isolated HAProxy 127.0.0.1:18080 running. Backend servers start in MAINT."
echo "Existing Xray :443 is unchanged. Check: cat /run/dual-ha-v2/health.json"
