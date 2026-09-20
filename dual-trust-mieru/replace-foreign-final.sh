#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=${1:-}
BUNDLE=${2:-}
D=/etc/dual-trust-mieru/iran
BIN=/usr/local/lib/dual-trust-mieru
STATE=/var/lib/dual-trust-mieru

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ "$ROLE" == trust || "$ROLE" == mieru ]] || die "usage: $0 trust|mieru /root/new-client-bundle.json"
[[ -s "$BUNDLE" ]] || die "bundle missing: $BUNDLE"
[[ -d "$D" ]] || die "Iran dual tunnel is not installed"
[[ -x "$BIN/xray" && -x "$BIN/mihomo" ]] || die "dual binaries missing"

for s in dual-trust-client dual-mieru-carrier dual-xudp-bridge dual-dispatcher; do
  systemctl is-active --quiet "$s.service" || die "$s is not active"
done

if [[ "$ROLE" == trust ]]; then
  jq -e '.version==1 and .kind=="trust" and .public_ip and .domain and .port and .username and .password and .xudp_uuid' "$BUNDLE" >/dev/null || die "invalid Trust bundle"
  PORT=7991
  CARRIER=dual-trust-client.service
  LIVE_BUNDLE="$D/trust-bundle.json"
else
  jq -e '.version==1 and .kind=="mieru" and .public_ip and .port_range and .username and .password and .xudp_uuid' "$BUNDLE" >/dev/null || die "invalid Mieru bundle"
  PORT=7992
  CARRIER=dual-mieru-carrier.service
  LIVE_BUNDLE="$D/mieru-bundle.json"
fi

BK="$STATE/backups/foreign-replace-${ROLE}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BK"; chmod 0700 "$BK"
cp -a "$D/xudp.json" "$BK/xudp.json"
cp -a "$LIVE_BUNDLE" "$BK/$(basename "$LIVE_BUNDLE")"
if [[ "$ROLE" == trust ]]; then cp -a "$D/trust-client.toml" "$BK/trust-client.toml"; else cp -a "$D/mieru-carrier.yaml" "$BK/mieru-carrier.yaml"; fi

rollback(){
  rc=$?
  trap - ERR INT TERM
  log "ROLLBACK: restoring previous $ROLE foreign configuration"
  cp -a "$BK/xudp.json" "$D/xudp.json"
  cp -a "$BK/$(basename "$LIVE_BUNDLE")" "$LIVE_BUNDLE"
  if [[ "$ROLE" == trust ]]; then cp -a "$BK/trust-client.toml" "$D/trust-client.toml"; else cp -a "$BK/mieru-carrier.yaml" "$D/mieru-carrier.yaml"; fi
  systemctl restart "$CARRIER" >/dev/null 2>&1 || true
  systemctl restart dual-xudp-bridge.service >/dev/null 2>&1 || true
  sleep 2
  log "Previous configuration restored. Backup retained at $BK"
  exit "$rc"
}
trap rollback ERR INT TERM

NEW_UUID=$(jq -r '.xudp_uuid' "$BUNDLE")
TMP_XUDP=$(mktemp "$D/.xudp.replace.XXXXXX.json")
jq --arg role "$ROLE" --arg uuid "$NEW_UUID" '(.outbounds[] | select(.tag==("xudp-"+$role)).settings.id) = $uuid' "$D/xudp.json" > "$TMP_XUDP"
chmod 0600 "$TMP_XUDP"
"$BIN/xray" run -test -c "$TMP_XUDP" >/dev/null

if [[ "$ROLE" == trust ]]; then
  TRUST_IP=$(jq -r '.public_ip' "$BUNDLE"); TRUST_DOMAIN=$(jq -r '.domain' "$BUNDLE"); TRUST_PORT=$(jq -r '.port' "$BUNDLE")
  TRUST_USER=$(jq -r '.username' "$BUNDLE"); TRUST_PASS=$(jq -r '.password' "$BUNDLE")
  cat > "$D/trust-client.toml.new" <<EOF2
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
EOF2
  chmod 0600 "$D/trust-client.toml.new"
  grep -qE '^[[:space:]]*127\.0\.0\.1[[:space:]]+xudp-trust\.internal([[:space:]]|$)' /etc/hosts || echo '127.0.0.1 xudp-trust.internal # dual-trust-mieru trust-xudp-hostname' >> /etc/hosts
  mv "$D/trust-client.toml.new" "$D/trust-client.toml"
else
  MIERU_IP=$(jq -r '.public_ip' "$BUNDLE"); MIERU_RANGE=$(jq -r '.port_range' "$BUNDLE")
  MIERU_USER=$(jq -r '.username' "$BUNDLE"); MIERU_PASS=$(jq -r '.password' "$BUNDLE")
  cat > "$D/mieru-carrier.yaml.new" <<EOF2
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
EOF2
  chmod 0600 "$D/mieru-carrier.yaml.new"
  "$BIN/mihomo" -t -d "$D/mieru-data" -f "$D/mieru-carrier.yaml.new" >/dev/null
  mv "$D/mieru-carrier.yaml.new" "$D/mieru-carrier.yaml"
fi

mv "$TMP_XUDP" "$D/xudp.json"
cp -a "$BUNDLE" "$LIVE_BUNDLE"
chmod 0600 "$LIVE_BUNDLE" "$D/xudp.json"

log "Restarting only $ROLE carrier and shared split/XUDP router"
systemctl restart "$CARRIER"; sleep 2; systemctl is-active --quiet "$CARRIER"
systemctl restart dual-xudp-bridge.service; sleep 2; systemctl is-active --quiet dual-xudp-bridge.service
ss -H -ltn "sport = :$PORT" | grep -q .

log "Strict TCP probe of replaced $ROLE path on SOCKS/$PORT"
for attempt in $(seq 1 10); do
  code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$PORT" --connect-timeout 5 --max-time 8 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
  [[ "$code" == 204 ]] || die "$ROLE TCP replacement probe $attempt/10 failed HTTP=${code:-000}"
done

log "UDP/XUDP probe of replaced $ROLE path"
PROBE_SOCKS_PORT="$PORT" python3 <<'PY'
import os,random,socket,struct
h='127.0.0.1'; p=int(os.environ['PROBE_SOCKS_PORT'])
def recvn(s,n):
    b=b''
    while len(b)<n:
        x=s.recv(n-len(b))
        if not x: raise RuntimeError('SOCKS closed')
        b+=x
    return b
s=socket.create_connection((h,p),timeout=5); s.sendall(b'\x05\x01\x00')
if recvn(s,2)!=b'\x05\x00': raise RuntimeError('SOCKS auth')
s.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
_,rep,_,at=recvn(s,4)
if rep: raise RuntimeError('UDP ASSOCIATE failed')
if at==1: relay=socket.inet_ntoa(recvn(s,4))
elif at==3: relay=recvn(s,recvn(s,1)[0]).decode()
elif at==4: relay=socket.inet_ntop(socket.AF_INET6,recvn(s,16))
else: raise RuntimeError('bad ATYP')
rport=struct.unpack('!H',recvn(s,2))[0]
if relay in ('0.0.0.0','::'): relay=h
qid=random.randrange(65536); qname=b''.join(bytes([len(x)])+x.encode() for x in 'youtube.com'.split('.'))+b'\0'
dns=struct.pack('!HHHHHH',qid,0x0100,1,0,0,0)+qname+struct.pack('!HH',1,1)
pkt=b'\0\0\0\1'+socket.inet_aton('1.1.1.1')+struct.pack('!H',53)+dns
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(6); u.sendto(pkt,(relay,rport)); data,_=u.recvfrom(65535)
if len(data)<12: raise RuntimeError('short UDP reply')
PY

trap - ERR INT TERM
log "SUCCESS: $ROLE foreign replaced; TCP direct + UDP/XUDP path healthy"
log "Backup retained at $BK"
log "x-ui and public :443 were not modified"
