#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$B/common.sh"
require_root

ROLE=''; PUBLIC_IP=''; DOMAIN=''; EMAIL=''; PORT_RANGE='20000-20020'; UUID_FILE=''; NONINTERACTIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE=${2:-}; shift 2 ;;
    --public-ip) PUBLIC_IP=${2:-}; shift 2 ;;
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --email) EMAIL=${2:-}; shift 2 ;;
    --port-range) PORT_RANGE=${2:-}; shift 2 ;;
    --xudp-uuid-file) UUID_FILE=${2:-}; shift 2 ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

banner(){
  echo '============================================================'
  echo '              DUAL MIERU TRUST TUNNEL'
  echo '                 powered by ali tavazoei'
  echo '============================================================'
}
banner

if [[ -z "$ROLE" && $NONINTERACTIVE -eq 0 ]]; then
  echo '1) Trust foreign'
  echo '2) Mieru foreign'
  read -r -p 'Select role [1/2]: ' x
  case "$x" in 1) ROLE=trust;; 2) ROLE=mieru;; *) die 'invalid role';; esac
fi
[[ "$ROLE" == trust || "$ROLE" == mieru ]] || die 'role must be trust or mieru'

if [[ -z "$PUBLIC_IP" && $NONINTERACTIVE -eq 0 ]]; then read -r -p 'Public IPv4: ' PUBLIC_IP; fi
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'valid IPv4 required'

if [[ "$ROLE" == trust ]]; then
  if [[ -z "$DOMAIN" && $NONINTERACTIVE -eq 0 ]]; then read -r -p 'Trust domain: ' DOMAIN; fi
  if [[ -z "$EMAIL" && $NONINTERACTIVE -eq 0 ]]; then read -r -p "Let's Encrypt email: " EMAIL; fi
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die 'valid Trust domain required'
  [[ "$EMAIL" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]] || die 'valid email required'
else
  if [[ $NONINTERACTIVE -eq 0 ]]; then
    read -r -p "Mieru port range [$PORT_RANGE]: " x || true
    [[ -z "${x:-}" ]] || PORT_RANGE=$x
  fi
  [[ "$PORT_RANGE" =~ ^([0-9]{4,5})-([0-9]{4,5})$ ]] || die 'invalid Mieru port range'
fi

LIVE_UUID=''
if [[ -n "$UUID_FILE" ]]; then
  [[ -s "$UUID_FILE" ]] || die "UUID file missing: $UUID_FILE"
  LIVE_UUID=$(tr -d '\r\n ' < "$UUID_FILE")
  [[ "$LIVE_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die 'UUID file is invalid'
fi

if [[ "$ROLE" == trust ]]; then
  bash "$B/install-foreign-trust.sh" --public-ip "$PUBLIC_IP" --domain "$DOMAIN" --email "$EMAIL"
  D="$CONFIG_DIR/trust"; BUNDLE=/root/dual-trust-client.json; XSVC=dual-xudp-trust.service
  tmp=$(mktemp); jq --arg email "$EMAIL" '.cert_email=$email' "$BUNDLE" > "$tmp"; install -m 0600 "$tmp" "$BUNDLE"; rm -f "$tmp"
else
  bash "$B/install-foreign-mieru-final.sh" --public-ip "$PUBLIC_IP" --port-range "$PORT_RANGE"
  D="$CONFIG_DIR/mieru"; BUNDLE=/root/dual-mieru-client.json; XSVC=dual-xudp-mieru.service
fi

# For carrier replacement, install the live Iran XUDP UUID directly on the new
# foreign role before cutover. This removes the old manual UUID migration race.
if [[ -n "$LIVE_UUID" ]]; then
  log "Applying supplied live XUDP UUID without printing it"
  cp -a "$D/xray.json" "$D/xray.json.before-live-uuid"
  cp -a "$BUNDLE" "${BUNDLE}.before-live-uuid"
  tmp=$(mktemp)
  jq --arg uuid "$LIVE_UUID" '(.inbounds[] | select(.tag=="xudp-in").settings.users[0].id)=$uuid' "$D/xray.json" > "$tmp"
  "$BIN_DIR/xray" run -test -c "$tmp" >/dev/null
  install -m 0600 "$tmp" "$D/xray.json"; rm -f "$tmp"
  tmp=$(mktemp)
  jq --arg uuid "$LIVE_UUID" '.xudp_uuid=$uuid' "$BUNDLE" > "$tmp"
  install -m 0600 "$tmp" "$BUNDLE"; rm -f "$tmp"
  systemctl restart "$XSVC"; sleep 2; systemctl is-active --quiet "$XSVC" || die "$XSVC failed after UUID apply"
  a=$(jq -r '.xudp_uuid' "$BUNDLE")
  b=$(jq -r '.inbounds[] | select(.tag=="xudp-in").settings.users[0].id' "$D/xray.json")
  [[ "$a" == "$LIVE_UUID" && "$b" == "$LIVE_UUID" ]] || die 'UUID verification failed'
  rm -f "$UUID_FILE" 2>/dev/null || true
fi

socks_connect_test(){
  local port=$1 target=$2 target_port=$3
  PROBE_SOCKS_PORT="$port" PROBE_TARGET="$target" PROBE_TARGET_PORT="$target_port" python3 <<'PY'
import os,socket,struct,ipaddress
p=int(os.environ['PROBE_SOCKS_PORT']); host=os.environ['PROBE_TARGET']; dp=int(os.environ['PROBE_TARGET_PORT'])
def r(s,n):
 b=b''
 while len(b)<n:
  x=s.recv(n-len(b))
  if not x: raise RuntimeError('closed')
  b+=x
 return b
s=socket.create_connection(('127.0.0.1',p),timeout=5); s.sendall(b'\x05\x01\x00')
if r(s,2)!=b'\x05\x00': raise RuntimeError('SOCKS auth')
try:
 ip=ipaddress.ip_address(host)
 if ip.version==4: req=b'\x05\x01\x00\x01'+ip.packed
 else: req=b'\x05\x01\x00\x04'+ip.packed
except ValueError:
 hb=host.encode(); req=b'\x05\x01\x00\x03'+bytes([len(hb)])+hb
s.sendall(req+struct.pack('!H',dp)); h=r(s,4)
if h[1]!=0: raise RuntimeError(f'SOCKS CONNECT reply={h[1]}')
at=h[3]
if at==1:r(s,4)
elif at==3:r(s,r(s,1)[0])
elif at==4:r(s,16)
r(s,2)
PY
}

# End-to-end local preflight of the foreign protocol into the loopback XUDP
# endpoint. This catches the historical "service is up but :2443 cannot be
# reached through the carrier" failure before Iran is cut over.
if [[ "$ROLE" == trust ]]; then
  install_trust_client
  free_port 17993
  U=$(jq -r '.username' "$BUNDLE"); P=$(jq -r '.password' "$BUNDLE")
  TCFG=$(mktemp)
  cat > "$TCFG" <<EOT
loglevel = "warning"
vpn_mode = "general"
killswitch_enabled = false
post_quantum_group_enabled = true
exclusions_tcp_early_ack_enabled = false
exclusions_preresolve_enabled = false
exclusions = []
[endpoint]
hostname = "$DOMAIN"
addresses = ["127.0.0.1:443"]
has_ipv6 = false
username = "$U"
password = "$P"
client_random = ""
skip_verification = false
certificate = ""
dns_upstreams = []
upstream_protocol = "http2"
tls_profile = "chrome"
anti_dpi = false
[listener.socks]
address = "127.0.0.1:17993"
EOT
  chmod 0600 "$TCFG"
  "$BIN_DIR/trusttunnel_client" --config "$TCFG" >/tmp/dual-trust-local-preflight.log 2>&1 & pid=$!
  for _ in $(seq 1 60); do ss -H -ltn 'sport = :17993' 2>/dev/null | grep -q . && break; kill -0 "$pid" 2>/dev/null || break; sleep .2; done
  if ! socks_connect_test 17993 xudp-trust.internal 2443; then tail -n 30 /tmp/dual-trust-local-preflight.log >&2 || true; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f "$TCFG" /tmp/dual-trust-local-preflight.log; die 'Trust tunneled XUDP backend preflight failed'; fi
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f "$TCFG" /tmp/dual-trust-local-preflight.log
else
  install_mihomo
  free_port 17994
  U=$(jq -r '.username' "$BUNDLE"); P=$(jq -r '.password' "$BUNDLE"); PR=$(jq -r '.port_range' "$BUNDLE")
  MCFG=$(mktemp)
  cat > "$MCFG" <<EOT
mode: rule
log-level: warning
ipv6: false
listeners:
  - name: local-preflight
    type: socks
    listen: 127.0.0.1
    port: 17994
    udp: true
    proxy: MIERU
proxies:
  - name: MIERU
    type: mieru
    server: 127.0.0.1
    port-range: "$PR"
    transport: TCP
    username: "$U"
    password: "$P"
    multiplexing: MULTIPLEXING_OFF
    handshake-mode: HANDSHAKE_STANDARD
    traffic-pattern: ""
rules:
  - MATCH,MIERU
EOT
  MD=$(mktemp -d)
  "$BIN_DIR/mihomo" -d "$MD" -f "$MCFG" >/tmp/dual-mieru-local-preflight.log 2>&1 & pid=$!
  for _ in $(seq 1 60); do ss -H -ltn 'sport = :17994' 2>/dev/null | grep -q . && break; kill -0 "$pid" 2>/dev/null || break; sleep .2; done
  socks_connect_test 17994 127.0.0.1 2443 || { tail -n 30 /tmp/dual-mieru-local-preflight.log >&2 || true; kill "$pid" 2>/dev/null || true; rm -rf "$MD" "$MCFG"; die 'Mieru tunneled XUDP backend preflight failed'; }
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -rf "$MD" "$MCFG" /tmp/dual-mieru-local-preflight.log
fi

log "SUCCESS: $ROLE foreign passed carrier + loopback XUDP backend preflight"
echo "Bundle ready: $BUNDLE"
