#!/usr/bin/env bash
set -Eeuo pipefail
ROLE=${1:-}; BUNDLE=${2:-}
D=/etc/dual-trust-mieru/iran
STATE=/var/lib/dual-trust-mieru
BIN=/usr/local/lib/dual-trust-mieru
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'run as root'
[[ "$ROLE" == trust || "$ROLE" == mieru ]] || die "usage: $0 trust|mieru /root/new-client-bundle.json"
[[ -s "$BUNDLE" && -s "$D/xudp.json" ]] || die 'bundle or Iran dual state missing'
# Role-local replacement: the sibling carrier may be down while this role
# is being repaired. Shared bridge + dispatcher must remain healthy.
for s in dual-xudp-bridge dual-dispatcher; do
  systemctl is-active --quiet "$s.service" || die "$s inactive"
done

if [[ "$ROLE" == trust ]]; then
  jq -e '.version==1 and .kind=="trust" and .public_ip and .domain and .port and .username and .password and .xudp_uuid' "$BUNDLE" >/dev/null || die 'invalid Trust bundle'
  LIVE_BUNDLE="$D/trust-bundle.json"; LIVE_CFG="$D/trust-client.toml"; CARRIER=dual-trust-client.service; DIRECT_PORT=7993; PATH_PORT=7991; TAG=xudp-trust
else
  jq -e '.version==1 and .kind=="mieru" and .public_ip and .port_range and .username and .password and .xudp_uuid' "$BUNDLE" >/dev/null || die 'invalid Mieru bundle'
  LIVE_BUNDLE="$D/mieru-bundle.json"; LIVE_CFG="$D/mieru-carrier.yaml"; CARRIER=dual-mieru-carrier.service; DIRECT_PORT=7994; PATH_PORT=7992; TAG=xudp-mieru
fi
CURRENT_UUID=$(jq -r --arg tag "$TAG" '.outbounds[] | select(.tag==$tag) | .settings.id' "$D/xudp.json")
NEW_UUID=$(jq -r '.xudp_uuid' "$BUNDLE")
[[ -n "$CURRENT_UUID" && "$CURRENT_UUID" != null && "$NEW_UUID" == "$CURRENT_UUID" ]] || die 'bundle XUDP UUID does not match live role UUID'

BK="$STATE/backups/carrier-only-${ROLE}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BK"; chmod 0700 "$BK"
cp -a "$LIVE_CFG" "$BK/$(basename "$LIVE_CFG")"; cp -a "$LIVE_BUNDLE" "$BK/$(basename "$LIVE_BUNDLE")"
rollback(){
  local rc=${1:-1}; trap - ERR INT TERM
  log "ROLLBACK: restoring previous $ROLE carrier"
  cp -a "$BK/$(basename "$LIVE_CFG")" "$LIVE_CFG"; cp -a "$BK/$(basename "$LIVE_BUNDLE")" "$LIVE_BUNDLE"
  systemctl restart "$CARRIER" >/dev/null 2>&1 || true; sleep 3
  log "Previous $ROLE carrier restored; other carrier, bridge, dispatcher and x-ui were untouched"
  exit "$rc"
}
trap 'rollback $?' ERR; trap 'rollback 130' INT; trap 'rollback 143' TERM

probe_http_stable(){
  local port=$1 label=$2 attempts=$3 needed=$4 code i streak=0
  for i in $(seq 1 "$attempts"); do
    code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null || true)
    if [[ "$code" == 204 ]]; then streak=$((streak+1)); log "$label $i/$attempts OK streak=$streak/$needed"; (( streak>=needed )) && return 0; else streak=0; log "$label $i/$attempts HTTP=${code:-000}"; fi
    sleep 1
  done
  return 1
}
probe_telegram(){
  local port=$1 i code good=0
  for i in 1 2 3; do
    code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' https://api.telegram.org/ 2>/dev/null || true)
    [[ "$code" =~ ^(200|301|302)$ ]] && good=$((good+1))
    sleep .3
  done
  log "$ROLE Telegram path success=$good/3"
  (( good >= 2 ))
}
udp_once(){
  local port=$1
  PROBE_SOCKS_PORT="$port" python3 <<'PY' >/dev/null 2>&1
import os,random,socket,struct
h='127.0.0.1'; p=int(os.environ['PROBE_SOCKS_PORT'])
def r(s,n):
 b=b''
 while len(b)<n:
  x=s.recv(n-len(b))
  if not x: raise RuntimeError
  b+=x
 return b
s=socket.create_connection((h,p),timeout=5); s.sendall(b'\x05\x01\x00')
if r(s,2)!=b'\x05\x00': raise RuntimeError
s.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
_,rep,_,at=r(s,4)
if rep: raise RuntimeError
if at==1: relay=socket.inet_ntoa(r(s,4))
elif at==3: relay=r(s,r(s,1)[0]).decode()
elif at==4: relay=socket.inet_ntop(socket.AF_INET6,r(s,16))
else: raise RuntimeError
rp=struct.unpack('!H',r(s,2))[0]
if relay in ('0.0.0.0','::'): relay=h
q=random.randrange(65536); dns=struct.pack('!HHHHHH',q,0x100,1,0,0,0)+b'\x07youtube\x03com\x00'+struct.pack('!HH',1,1)
pkt=b'\0\0\0\1'+socket.inet_aton('1.1.1.1')+struct.pack('!H',53)+dns
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(6); u.sendto(pkt,(relay,rp)); data,_=u.recvfrom(4096)
if len(data)<12: raise RuntimeError
PY
}
probe_udp_stable(){ local good=0 i; for i in 1 2 3; do udp_once "$PATH_PORT" && good=$((good+1)) || true; sleep .4; done; log "$ROLE UDP/XUDP success=$good/3"; (( good>=2 )); }

if [[ "$ROLE" == trust ]]; then
  TRUST_IP=$(jq -r '.public_ip' "$BUNDLE"); TRUST_DOMAIN=$(jq -r '.domain' "$BUNDLE"); TRUST_PORT=$(jq -r '.port' "$BUNDLE"); TRUST_USER=$(jq -r '.username' "$BUNDLE"); TRUST_PASS=$(jq -r '.password' "$BUNDLE")
  cat > "$LIVE_CFG.new" <<EOT
loglevel = "info"
vpn_mode = "general"
killswitch_enabled = false
post_quantum_group_enabled = true
exclusions_tcp_early_ack_enabled = false
exclusions_preresolve_enabled = false
exclusions = []
[endpoint]
hostname = "$TRUST_DOMAIN"
addresses = ["$TRUST_IP:$TRUST_PORT"]
has_ipv6 = false
username = "$TRUST_USER"
password = "$TRUST_PASS"
client_random = ""
skip_verification = false
certificate = ""
dns_upstreams = []
upstream_protocol = "http2"
tls_profile = "chrome"
anti_dpi = true
[listener.socks]
address = "127.0.0.1:7993"
EOT
else
  MIERU_IP=$(jq -r '.public_ip' "$BUNDLE"); MIERU_RANGE=$(jq -r '.port_range' "$BUNDLE"); MIERU_USER=$(jq -r '.username' "$BUNDLE"); MIERU_PASS=$(jq -r '.password' "$BUNDLE")
  cat > "$LIVE_CFG.new" <<EOT
mode: rule
log-level: info
ipv6: false
listeners:
  - name: mieru-carrier-socks
    type: socks
    listen: 127.0.0.1
    port: 7994
    udp: true
    proxy: MIERU
proxies:
  - name: MIERU
    type: mieru
    server: "$MIERU_IP"
    port-range: "$MIERU_RANGE"
    transport: TCP
    username: "$MIERU_USER"
    password: "$MIERU_PASS"
    multiplexing: MULTIPLEXING_OFF
    handshake-mode: HANDSHAKE_STANDARD
    traffic-pattern: ""
rules:
  - MATCH,MIERU
EOT
  "$BIN/mihomo" -t -d "$D/mieru-data" -f "$LIVE_CFG.new" >/dev/null
fi
chmod 0600 "$LIVE_CFG.new"; mv "$LIVE_CFG.new" "$LIVE_CFG"; cp -a "$BUNDLE" "$LIVE_BUNDLE"; chmod 0600 "$LIVE_CFG" "$LIVE_BUNDLE"

log "Restarting ONLY $CARRIER"
systemctl restart "$CARRIER"; sleep 5
systemctl is-active --quiet "$CARRIER" || rollback 1
ss -H -ltn "sport = :$DIRECT_PORT" 2>/dev/null | grep -q . || rollback 1
probe_http_stable "$DIRECT_PORT" "$ROLE-direct" 10 3 || rollback 1
probe_http_stable "$PATH_PORT" "$ROLE-tcp-path" 8 2 || rollback 1
probe_telegram "$PATH_PORT" || rollback 1
probe_udp_stable || rollback 1
trap - ERR INT TERM
log "SUCCESS: $ROLE carrier replaced; TCP, Telegram and UDP/XUDP role checks passed"
log 'No restart issued for shared bridge, dispatcher, x-ui or the other carrier'
log "Backup retained at $BK"
