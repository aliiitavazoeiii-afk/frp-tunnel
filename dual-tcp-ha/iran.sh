#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) -eq 0 && $# -eq 2 ]] || { echo "Usage: sudo bash iran.sh FOREIGN1_IP FOREIGN2_IP"; exit 1; }
IP1="$1"; IP2="$2"
for i in 1 2; do [[ -s /etc/dual-tcp-ha/foreign$i.crt ]] || { echo "Missing foreign$i.crt"; exit 1; }; done
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y stunnel4 haproxy
cat >/etc/dual-tcp-ha/client.conf <<EOF
foreground = yes
pid =
client = yes
[foreign1]
accept = 127.0.0.1:21001
connect = $IP1:443
CAfile = /etc/dual-tcp-ha/foreign1.crt
verifyChain = yes
checkIP = $IP1
[foreign2]
accept = 127.0.0.1:21002
connect = $IP2:443
CAfile = /etc/dual-tcp-ha/foreign2.crt
verifyChain = yes
checkIP = $IP2
EOF
cat >/etc/systemd/system/dual-stunnel-client.service <<'EOF'
[Unit]
Description=Dual TCP HA TLS clients
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/bin/stunnel4 /etc/dual-tcp-ha/client.conf
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
cp -a /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.backup.$(date +%s)"
cat >/etc/haproxy/haproxy.cfg <<'EOF'
global
    log /dev/log local0
    maxconn 12000
defaults
    log global
    mode tcp
    option tcplog
    timeout connect 8s
    timeout client 5m
    timeout server 5m
frontend socks_in
    bind 127.0.0.1:1080
    default_backend socks_out
backend socks_out
    balance leastconn
    server foreign1 127.0.0.1:21001 check inter 2s fall 3 rise 5
    server foreign2 127.0.0.1:21002 check inter 2s fall 3 rise 5
EOF
haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl daemon-reload
systemctl enable --now dual-stunnel-client haproxy
systemctl restart haproxy
echo "Local SOCKS5: 127.0.0.1:1080"
echo "WARNING: HAProxy checks local listeners, NOT remote egress. Staging only."
