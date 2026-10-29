#!/usr/bin/env bash
# Isolated Custom Backhaul V2 WSS endpoint on alternate public TCP/18443.
# NEVER modifies public TCP/443, existing Xray, x-ui, /etc/haproxy/haproxy.cfg.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
DOMAIN="$1"
[[ "$DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]] || { echo "Usage: sudo bash iran-backhaul.sh backbone.example.com"; exit 2; }
[[ -x /opt/dual-ha/bin/backhaul ]] || { echo "First run: sudo bash build-backhaul.sh"; exit 2; }
for p in 18443 19080 19081 21001; do
 if ss -Hlnpt "( sport = :$p )" | grep -q LISTEN; then
   echo "Port $p already has a listener; refusing overwrite"; exit 3
 fi
done
IRAN_IP="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org)"
[[ "$IRAN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Cannot determine public Iran IP"; exit 3; }
DNS_IPS="$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)"
grep -Fxq "$IRAN_IP" <<<"$DNS_IPS" || {
  echo "$DOMAIN must resolve directly to Iran IP $IRAN_IP (DNS only, no CDN orange-cloud). Found: $DNS_IPS"; exit 3
}
if [[ ! -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" || ! -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]]; then
 if ss -Hlnpt '( sport = :80 )' | grep -q LISTEN; then
   echo "Port 80 occupied: issue trusted certificate for $DOMAIN externally first"; exit 3
 fi
 export DEBIAN_FRONTEND=noninteractive
 apt-get update
 apt-get install -y certbot
 certbot certonly --standalone -d "$DOMAIN" --agree-tos --register-unsafely-without-email --non-interactive
fi
CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
openssl x509 -in "$CERT" -noout -checkhost "$DOMAIN"
openssl x509 -in "$CERT" -noout -checkend 604800
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y stunnel4 haproxy
mkdir -p /etc/dual-ha /opt/dual-ha /run/dual-ha-bh
chmod 0700 /etc/dual-ha
TOKEN="$(openssl rand -hex 32)"
CONTROL="/assets/$(openssl rand -hex 16)"
TUNNEL="/socket/$(openssl rand -hex 16)"
cat >/etc/dual-ha/backhaul-bundle.env <<EOF
BH_DOMAIN='$DOMAIN'
BH_IRAN_IP='$IRAN_IP'
BH_TOKEN='$TOKEN'
BH_CONTROL_PATH='$CONTROL'
BH_TUNNEL_PATH='$TUNNEL'
BH_FOREIGN_IP='152.237.230.159'
BH_TLS_PORT='18443'
EOF
chmod 0600 /etc/dual-ha/backhaul-bundle.env
cat >/etc/dual-ha/backhaul-iran.toml <<EOF
[server]
bind_addr = "127.0.0.1:19081"
transport = "wsmux"
token = "$TOKEN"
ws_control_path = "$CONTROL"
ws_tunnel_path = "$TUNNEL"
keepalive_period = 75
heartbeat = 40
nodelay = true
channel_size = 4096
mux_con = 16
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536
sniffer = false
web_port = 0
log_level = "info"
ports = [
  "127.0.0.1:21001=127.0.0.1:11080"
]
EOF
chmod 0600 /etc/dual-ha/backhaul-iran.toml
cat >/etc/dual-ha/backhaul-router.cfg <<EOF
global
  maxconn 20000
defaults
  mode http
  timeout connect 5s
  timeout client 1h
  timeout server 1h
  timeout tunnel 12h
  timeout http-request 10s
frontend ingress
  bind 127.0.0.1:19080
  acl control_path path -i $CONTROL
  acl tunnel_path path_beg $TUNNEL/
  http-request return status 200 content-type text/html string "<!doctype html><html><head><title>Welcome</title></head><body>Welcome</body></html>" if { path / }
  http-request return status 404 content-type text/plain string "Not Found" unless control_path or tunnel_path
  use_backend wsmux if control_path or tunnel_path
backend wsmux
  server backhaul 127.0.0.1:19081
EOF
cat >/etc/dual-ha/backhaul-stunnel.conf <<EOF
foreground = yes
syslog = no
debug = notice
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
[dual-ha-custom-backhaul-v2]
accept = 0.0.0.0:18443
connect = 127.0.0.1:19080
cert = $CERT
key = $KEY
sslVersionMin = TLSv1.2
TIMEOUTconnect = 10
TIMEOUTidle = 43200
EOF
chmod 0600 /etc/dual-ha/backhaul-stunnel.conf
cat >/etc/systemd/system/dual-ha-backhaul.service <<'EOF'
[Unit]
Description=Dual HA Custom Backhaul V2 Iran reverse WSMux
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
ExecStart=/opt/dual-ha/bin/backhaul -c /etc/dual-ha/backhaul-iran.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/dual-ha-backhaul-router.service <<'EOF'
[Unit]
Description=Dual HA isolated Backhaul HTTP/WebSocket decoy router
Wants=network-online.target
After=network-online.target dual-ha-backhaul.service
[Service]
Type=simple
RuntimeDirectory=dual-ha-bh
ExecStartPre=/usr/sbin/haproxy -c -f /etc/dual-ha/backhaul-router.cfg
ExecStart=/usr/sbin/haproxy -W -db -f /etc/dual-ha/backhaul-router.cfg
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/dual-ha-backhaul-tls.service <<'EOF'
[Unit]
Description=Dual HA isolated stunnel for Backhaul HTTPS
Wants=network-online.target
After=network-online.target dual-ha-backhaul-router.service
[Service]
Type=simple
ExecStart=/usr/bin/stunnel /etc/dual-ha/backhaul-stunnel.conf
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/dual-ha-backhaul.sh <<'EOF'
#!/usr/bin/env bash
systemctl try-restart dual-ha-backhaul-tls.service >/dev/null 2>&1 || true
EOF
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/dual-ha-backhaul.sh
haproxy -c -f /etc/dual-ha/backhaul-router.cfg
systemctl daemon-reload
systemctl enable --now dual-ha-backhaul dual-ha-backhaul-router dual-ha-backhaul-tls
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow from 152.237.230.159 to any port 18443 proto tcp
fi
sleep 2
for service in dual-ha-backhaul dual-ha-backhaul-router dual-ha-backhaul-tls; do
  systemctl is-active --quiet "$service" || { journalctl -u "$service" -n 60 --no-pager; exit 1; }
done
curl -fsS --resolve "$DOMAIN:18443:$IRAN_IP" --max-time 10 "https://$DOMAIN:18443/" >/dev/null
echo "Iran Backhaul isolated staging ready; NO Xray/443 change. Copy bundle to Foreign-1:"
echo "scp /etc/dual-ha/backhaul-bundle.env root@152.237.230.159:/root/dual-ha-backhaul-bundle.env"
echo "Foreign-1 will connect to Iran:18443. Open this port in the Iran provider firewall if required."
