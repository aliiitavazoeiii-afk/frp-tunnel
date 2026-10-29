#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) -eq 0 ]] || { echo "Run as root"; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y stunnel4 dante-server openssl
install -d -m 700 /etc/dual-tcp-ha
if [[ ! -f /etc/dual-tcp-ha/server.key ]]; then
IP=$(hostname -I | awk '{print $1}')
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 -keyout /etc/dual-tcp-ha/server.key -out /etc/dual-tcp-ha/server.crt -subj "/CN=$IP" -addext "subjectAltName=IP:$IP"
chmod 600 /etc/dual-tcp-ha/server.key
fi
IFACE=$(ip -4 route show default | awk '/default/{print $5;exit}')
cat >/etc/danted.conf <<EOF
logoutput: syslog
internal: 127.0.0.1 port = 11080
external: $IFACE
socksmethod: none
clientmethod: none
client pass {
 from: 127.0.0.1/32 to: 0.0.0.0/0
 log: error
}
socks pass {
 from: 127.0.0.1/32 to: 0.0.0.0/0
 command: connect
 log: error
}
EOF
cat >/etc/dual-tcp-ha/server.conf <<'EOF'
foreground = yes
pid =
[remote-socks]
accept = 0.0.0.0:443
connect = 127.0.0.1:11080
cert = /etc/dual-tcp-ha/server.crt
key = /etc/dual-tcp-ha/server.key
sslVersionMin = TLSv1.2
EOF
cat >/etc/systemd/system/dual-stunnel-server.service <<'EOF'
[Unit]
Description=Dual TCP HA TLS server
After=network-online.target danted.service
Wants=network-online.target
[Service]
ExecStart=/usr/bin/stunnel4 /etc/dual-tcp-ha/server.conf
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now danted dual-stunnel-server
echo "Certificate fingerprint (verify independently):"
openssl x509 -in /etc/dual-tcp-ha/server.crt -noout -fingerprint -sha256
echo "Copy certificate securely to Iran; DO NOT copy private key."
