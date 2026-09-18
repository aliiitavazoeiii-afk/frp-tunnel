#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$B/common.sh"
require_root

PUBLIC_IP=""; DOMAIN=""; EMAIL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-ip) PUBLIC_IP=${2:-}; shift 2 ;;
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --email) EMAIL=${2:-}; shift 2 ;;
    *) die "usage: $0 --public-ip IP --domain trust.example.com --email you@example.com" ;;
  esac
done
[[ "$PUBLIC_IP" =~ ^[0-9a-fA-F:.]+$ ]] || die "invalid --public-ip"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ && "$DOMAIN" == *.* ]] || die "invalid --domain"
[[ "$EMAIL" == *@*.* ]] || die "invalid --email"

D="$CONFIG_DIR/trust"
BUNDLE=/root/dual-trust-client.json
for x in "$D" "$BUNDLE" /etc/systemd/system/dual-xudp-trust.service /etc/systemd/system/dual-trust-endpoint.service; do
  [[ ! -e "$x" ]] || die "existing Trust dual-tunnel state found at $x; use a clean/dedicated test server or remove the prior install first"
done

CPID=""
cleanup_install(){
  rc=$?
  trap - EXIT
  if [[ -n "$CPID" ]]; then kill "$CPID" 2>/dev/null || true; wait "$CPID" 2>/dev/null || true; fi
  if (( rc != 0 )); then
    log "Install failed; removing partial dual Trust services/config (certificate, if issued, is retained)"
    systemctl disable --now dual-trust-endpoint.service dual-xudp-trust.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/dual-trust-endpoint.service /etc/systemd/system/dual-xudp-trust.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf "$D"
    rm -f "$BUNDLE"
  fi
  exit "$rc"
}
trap cleanup_install EXIT

install_base_packages
apt-get install -y --no-install-recommends certbot
mkdirs
free_port 80
free_port 443

log "Checking DNS before certificate request"
mapfile -t resolved < <(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)
printf '%s\n' "${resolved[@]:-}" | grep -Fxq "$PUBLIC_IP" || die "$DOMAIN does not resolve to $PUBLIC_IP yet"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 80/tcp comment 'dual-trust-certbot' >/dev/null
  ufw allow 443/tcp comment 'dual-trust-h2' >/dev/null
fi

log "Obtaining/refreshing Let's Encrypt certificate for $DOMAIN"
certbot certonly --standalone --non-interactive --agree-tos --keep-until-expiring \
  --email "$EMAIL" -d "$DOMAIN"
CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
[[ -s "$CERT" && -s "$KEY" ]] || die "certificate files missing"

install_trust_endpoint
install_xray

# TrustTunnel resolves tunneled hostname destinations on the foreign endpoint.
# Keep the XUDP backend loopback-only while giving it a stable hostname that
# resolves locally on the Trust foreign.
TRUST_XUDP_HOST=xudp-trust.internal
TRUST_XUDP_MARKER='# dual-trust-mieru trust-xudp-backend'
if ! getent ahostsv4 "$TRUST_XUDP_HOST" 2>/dev/null | awk '{print $1}' | grep -Fxq '127.0.0.1'; then
  printf '127.0.0.1 %s %s\n' "$TRUST_XUDP_HOST" "$TRUST_XUDP_MARKER" >> /etc/hosts
fi
getent ahostsv4 "$TRUST_XUDP_HOST" | awk '{print $1}' | grep -Fxq '127.0.0.1' || die "$TRUST_XUDP_HOST does not resolve to 127.0.0.1 on Trust foreign"

mkdir -p "$D"; chmod 0700 "$D"
USER_NAME="dtm-$(openssl rand -hex 4)"
USER_PASS=$(openssl rand -hex 32)
XUDP_UUID=$(json_uuid)

cat > "$D/vpn.toml" <<EOF2
listen_address = "0.0.0.0:443"
ipv6_available = false
allow_private_network_connections = true
tls_handshake_timeout_secs = 10
client_listener_timeout_secs = 600
connection_establishment_timeout_secs = 20
tcp_connections_timeout_secs = 604800
udp_connections_timeout_secs = 300
credentials_file = "$D/credentials.toml"

[listen_protocols.http2]
initial_connection_window_size = 8388608
initial_stream_window_size = 131072
max_concurrent_streams = 1000
max_frame_size = 16384
header_table_size = 65536

[forward_protocol]
direct = {}
EOF2

cat > "$D/hosts.toml" <<EOF2
[[main_hosts]]
hostname = "$DOMAIN"
cert_chain_path = "$CERT"
private_key_path = "$KEY"
EOF2

cat > "$D/credentials.toml" <<EOF2
[[client]]
username = "$USER_NAME"
password = "$USER_PASS"
EOF2
chmod 0600 "$D"/*.toml

cat > "$D/xray.json" <<EOF2
{
  "log":{"loglevel":"warning"},
  "inbounds":[{
    "tag":"xudp-in","listen":"127.0.0.1","port":2443,"protocol":"vless",
    "settings":{"users":[{"id":"$XUDP_UUID","email":"dual-trust-xudp"}],"decryption":"none"},
    "streamSettings":{"network":"raw"}
  }],
  "outbounds":[{"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIP"}}],
  "routing":{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["xudp-in"],"outboundTag":"direct"}]}
}
EOF2
chmod 0600 "$D/xray.json"

log "Validating Xray config"
"$BIN_DIR/xray" run -test -c "$D/xray.json" >/dev/null

# TrustTunnel has no dedicated dry-run flag. Start a loopback candidate on a
# temporary port before installing the persistent service.
cp "$D/vpn.toml" "$D/vpn.candidate.toml"
sed -i 's#listen_address = "0.0.0.0:443"#listen_address = "127.0.0.1:18443"#' "$D/vpn.candidate.toml"
log "Starting short-lived TrustTunnel candidate"
"$BIN_DIR/trusttunnel_endpoint" "$D/vpn.candidate.toml" "$D/hosts.toml" >"$D/candidate.log" 2>&1 & CPID=$!
for _ in $(seq 1 40); do
  ss -H -ltn 'sport = :18443' 2>/dev/null | grep -q . && break
  kill -0 "$CPID" 2>/dev/null || { tail -n 80 "$D/candidate.log" >&2 || true; die "TrustTunnel candidate exited"; }
  sleep 0.2
done
ss -H -ltn 'sport = :18443' 2>/dev/null | grep -q . || { tail -n 80 "$D/candidate.log" >&2 || true; die "TrustTunnel candidate did not listen"; }
kill "$CPID" 2>/dev/null || true
wait "$CPID" 2>/dev/null || true
CPID=""
rm -f "$D/vpn.candidate.toml" "$D/candidate.log"

cat > /etc/systemd/system/dual-xudp-trust.service <<EOF2
[Unit]
Description=Dual Trust/Mieru XUDP endpoint (Trust foreign)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$BIN_DIR/xray run -c $D/xray.json
Restart=always
RestartSec=2s
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF2

cat > /etc/systemd/system/dual-trust-endpoint.service <<EOF2
[Unit]
Description=TrustTunnel HTTP/2 endpoint for dual tunnel
After=network-online.target dual-xudp-trust.service
Wants=network-online.target
Requires=dual-xudp-trust.service
[Service]
Type=simple
ExecStart=$BIN_DIR/trusttunnel_endpoint $D/vpn.toml $D/hosts.toml
Restart=always
RestartSec=2s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=false
ProtectSystem=full
ReadOnlyPaths=/etc/letsencrypt
[Install]
WantedBy=multi-user.target
EOF2

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/dual-trust-restart.sh <<'EOF2'
#!/usr/bin/env bash
systemctl try-restart dual-trust-endpoint.service
EOF2
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/dual-trust-restart.sh

systemd-analyze verify /etc/systemd/system/dual-xudp-trust.service /etc/systemd/system/dual-trust-endpoint.service >/dev/null
systemctl daemon-reload
systemctl enable --now dual-xudp-trust.service dual-trust-endpoint.service >/dev/null
sleep 2
systemctl is-active --quiet dual-xudp-trust.service || die "dual-xudp-trust inactive"
systemctl is-active --quiet dual-trust-endpoint.service || { journalctl -u dual-trust-endpoint -n 100 --no-pager >&2 || true; die "dual-trust-endpoint inactive"; }
ss -H -ltn 'sport = :2443' | grep -q '127.0.0.1:2443' || die "XUDP loopback :2443 missing"
ss -H -ltn 'sport = :443' | grep -q . || die "TrustTunnel TCP/443 missing"

export PUBLIC_IP DOMAIN USER_NAME USER_PASS XUDP_UUID
python3 - "$BUNDLE" <<'PY'
import json,os,sys
p=sys.argv[1]; e=os.environ
obj={"version":1,"kind":"trust","public_ip":e["PUBLIC_IP"],"domain":e["DOMAIN"],"port":443,
     "username":e["USER_NAME"],"password":e["USER_PASS"],"xudp_uuid":e["XUDP_UUID"]}
with open(p,'w') as f: json.dump(obj,f,indent=2,sort_keys=True)
os.chmod(p,0o600)
PY
unset USER_PASS XUDP_UUID
log "SUCCESS: TrustTunnel H2 foreign is healthy on TCP/443"
log "Client bundle: $BUNDLE (0600; do not paste into chat/repo)"
log "Bundle SHA256: $(sha256sum "$BUNDLE" | awk '{print $1}')"
trap - EXIT
