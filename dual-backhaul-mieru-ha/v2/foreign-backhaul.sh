#!/usr/bin/env bash
# Foreign-1: custom Backhaul V2 WSS reverse client + loopback SOCKS5 egress.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
[[ -x /opt/dual-ha/bin/backhaul ]] || { echo "First run: sudo bash build-backhaul.sh"; exit 2; }
BUNDLE="$1"
[[ -r "$BUNDLE" ]] || { echo "Usage: sudo bash foreign-backhaul.sh /root/dual-ha-backhaul-bundle.env"; exit 2; }
grep -Eq "^BH_FOREIGN_IP='152[.]237[.]230[.]159'$" "$BUNDLE" || { echo "Foreign-1 IP mismatch"; exit 3; }
# shellcheck source=/dev/null
source "$BUNDLE"
[[ "$BH_TOKEN" =~ ^[0-9a-f]{64}$ && "$BH_TLS_PORT" == 18443 ]] || { echo "Invalid secret bundle"; exit 3; }
[[ "$BH_DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]] || exit 3
[[ "$BH_CONTROL_PATH" =~ ^/[a-z0-9/]+$ && "$BH_TUNNEL_PATH" =~ ^/[a-z0-9/]+$ ]] || exit 3
if ss -Hlnpt '( sport = :11080 )' | grep -q LISTEN; then echo "Foreign SOCKS port 11080 occupied"; exit 3; fi
if systemctl is-active --quiet danted 2>/dev/null; then echo "danted already running; refusing to alter existing setup"; exit 3; fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y dante-server curl ca-certificates
# Stop only newly installed distro danted, then configure its single canonical service.
systemctl stop danted.service 2>/dev/null || true
EXTDEV="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
[[ "$EXTDEV" =~ ^[A-Za-z0-9_.:-]+$ ]] || { echo "Cannot determine network interface"; exit 3; }
mkdir -p /etc/dual-ha
chmod 0700 /etc/dual-ha
if [[ -e /etc/danted.conf ]]; then
  install -m 0600 /etc/danted.conf "/etc/dual-ha/danted.backup.$(date +%Y%m%d-%H%M%S)"
fi
cat >/etc/danted.conf <<EOF
logoutput: syslog
internal: 127.0.0.1 port = 11080
external: $EXTDEV
socksmethod: none
clientmethod: none
user.privileged: root
user.unprivileged: nobody
client pass {
  from: 127.0.0.1/32 to: 0.0.0.0/0
  log: error
}
socks pass {
  from: 127.0.0.1/32 to: 0.0.0.0/0
  command: connect
  protocol: tcp
  log: error
}
EOF
chmod 0640 /etc/danted.conf
systemctl enable --now danted.service
sleep 2
systemctl is-active --quiet danted || { journalctl -u danted -n 60 --no-pager; exit 3; }
echo "Checking real local SOCKS egress before enabling transport..."
curl --socks5-hostname 127.0.0.1:11080 --connect-timeout 5 --max-time 12 -fsS \
  https://www.cloudflare.com/cdn-cgi/trace | grep '^ip='
cat >/etc/dual-ha/backhaul-foreign.toml <<EOF
[client]
remote_addr = "$BH_DOMAIN:18443"
edge_ip = ""
transport = "wssmux"
token = "$BH_TOKEN"
ws_control_path = "$BH_CONTROL_PATH"
ws_tunnel_path = "$BH_TUNNEL_PATH"
tls_skip_verify = false
tls_server_name = "$BH_DOMAIN"
connection_pool = 16
aggressive_pool = false
keepalive_period = 75
dial_timeout = 10
retry_interval = 3
nodelay = true
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
sniffer = false
web_port = 0
log_level = "info"
EOF
chmod 0600 /etc/dual-ha/backhaul-foreign.toml
cat >/etc/systemd/system/dual-ha-backhaul-client.service <<'EOF'
[Unit]
Description=Dual HA Custom Backhaul V2 Foreign-1 reverse WSS client
Wants=network-online.target
After=network-online.target danted.service
Requires=danted.service
[Service]
Type=simple
ExecStart=/opt/dual-ha/bin/backhaul -c /etc/dual-ha/backhaul-foreign.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now dual-ha-backhaul-client
sleep 4
systemctl is-active --quiet dual-ha-backhaul-client || { journalctl -u dual-ha-backhaul-client -n 70 --no-pager; exit 3; }
echo "Foreign-1 client is running; verify through Iran SOCKS 127.0.0.1:21001."
echo "Server public :443, Xray and user identities were not modified."
