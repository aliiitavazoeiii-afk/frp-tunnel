#!/usr/bin/env bash
set -Eeuo pipefail
LIB=/usr/local/lib/dual-trust-mieru-manager
# shellcheck source=common.sh
source "$LIB/common.sh"
require_root

D=/etc/dual-trust-mieru/iran
STATE=/var/lib/dual-trust-mieru/naive-migrate
SSH_OPTS=(-o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPersist=600 -o ControlPath=/run/dual-naive-ssh-%C)
mkdir -p "$STATE"; chmod 0700 "$STATE"
[[ -s "$D/xudp.json" ]] || die 'Iran dual tunnel is not installed'
for s in dual-mieru-carrier dual-xudp-bridge dual-dispatcher x-ui; do
  systemctl is-active --quiet "$s.service" || die "$s is inactive; repair base stack first"
done

valid_ipv4(){
  local IFS=. a b c d extra o
  read -r a b c d extra <<<"$1"
  [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
  for o in "$a" "$b" "$c" "$d"; do [[ "$o" =~ ^[0-9]{1,3}$ ]] && (( 10#$o <= 255 )) || return 1; done
}
probe_http(){
  local port=$1 url=${2:-https://www.gstatic.com/generate_204} expect=${3:-204} code
  code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" --connect-timeout 5 --max-time 12 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
  [[ "$code" == "$expect" ]]
}
probe_http_stable(){
  local port=$1 label=$2 attempts=${3:-8} needed=${4:-3} i streak=0
  for i in $(seq 1 "$attempts"); do
    if probe_http "$port"; then streak=$((streak+1)); log "$label $i/$attempts OK streak=$streak/$needed"; (( streak >= needed )) && return 0
    else streak=0; log "$label $i/$attempts FAIL"; fi
    sleep .6
  done
  return 1
}
probe_telegram(){
  local port=$1 i code good=0
  for i in 1 2 3; do
    code=$(curl -4 -sS --socks5-hostname "127.0.0.1:$port" --connect-timeout 5 --max-time 12 -o /dev/null -w '%{http_code}' https://api.telegram.org/ 2>/dev/null || true)
    [[ "$code" =~ ^(200|301|302)$ ]] && good=$((good+1))
    sleep .25
  done
  log "Naive Telegram success=$good/3"
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
probe_udp(){ local i good=0; for i in 1 2 3; do udp_once 7991 && good=$((good+1)) || true; sleep .3; done; log "Naive UDP/XUDP success=$good/3"; (( good>=2 )); }

LIVE_UUID=$(jq -r '.outbounds[] | select(.tag=="xudp-trust") | .settings.id // empty' "$D/xudp.json")
[[ "$LIVE_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die 'live legacy-A XUDP UUID missing'

OLD_KIND=none
if [[ -s "$D/naive-bundle.json" ]] && systemctl is-active --quiet dual-naive-client.service 2>/dev/null; then
  OLD_KIND=naive; OLD_IP=$(jq -r '.public_ip // "unknown"' "$D/naive-bundle.json")
elif [[ -s "$D/trust-bundle.json" ]] && systemctl is-active --quiet dual-trust-client.service 2>/dev/null; then
  OLD_KIND=trust; OLD_IP=$(jq -r '.public_ip // "unknown"' "$D/trust-bundle.json")
else
  die 'no healthy current role-A carrier (Trust/Naive) found'
fi
echo "Current role-A carrier: $OLD_KIND $OLD_IP"
read -r -p 'New Naive foreign IPv4: ' NEW_IP
valid_ipv4 "$NEW_IP" || die 'invalid IPv4'
[[ "$NEW_IP" != "$OLD_IP" || "$OLD_KIND" != naive ]] || die 'new Naive IP equals current Naive IP'

echo 'Connecting to Naive foreign. SSH should ask for root password once.'
ssh "${SSH_OPTS[@]}" "root@$NEW_IP" 'echo NEW-NAIVE-SSH=OK' || die 'cannot SSH to Naive foreign'
cleanup_master(){ ssh "${SSH_OPTS[@]}" -O exit "root@$NEW_IP" >/dev/null 2>&1 || true; }
trap cleanup_master EXIT

TMP_BUNDLE=$(mktemp /root/.dual-naive-bundle.XXXXXX.json)
scp "${SSH_OPTS[@]}" "root@$NEW_IP:/root/dual-naive-client.json" "$TMP_BUNDLE" || die 'cannot fetch Naive bundle; install foreign Naive first'
chmod 0600 "$TMP_BUNDLE"
jq -e '.version==1 and .kind=="naive" and .public_ip and .domain and .port==443 and .username and .password and .xudp_uuid' "$TMP_BUNDLE" >/dev/null || die 'invalid Naive bundle'
[[ $(jq -r '.public_ip' "$TMP_BUNDLE") == "$NEW_IP" ]] || die 'Naive bundle public IP mismatch'
DOMAIN=$(jq -r '.domain' "$TMP_BUNDLE")
mapfile -t dnsips < <(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)
printf '%s\n' "${dnsips[@]:-}" | grep -Fxq "$NEW_IP" || die "DNS A record for $DOMAIN does not point to $NEW_IP"

UUID_FILE=$(mktemp /root/.dual-live-uuid.XXXXXX); chmod 0600 "$UUID_FILE"; printf '%s\n' "$LIVE_UUID" > "$UUID_FILE"
scp "${SSH_OPTS[@]}" "$UUID_FILE" "root@$NEW_IP:/root/dual-live-uuid.txt"
rm -f "$UUID_FILE"

log 'Syncing live Maya XUDP UUID onto Naive foreign without printing it'
ssh "${SSH_OPTS[@]}" "root@$NEW_IP" bash -s <<'REMOTE'
set -Eeuo pipefail
D=/etc/dual-trust-mieru/naive
B=/root/dual-naive-client.json
X=/usr/local/lib/dual-trust-mieru/xray
U=$(tr -d '\r\n ' </root/dual-live-uuid.txt)
[[ "$U" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo 'ERROR: invalid supplied UUID' >&2; exit 1; }
[[ -s "$D/xray.json" && -s "$B" && -x "$X" ]] || { echo 'ERROR: Naive foreign state incomplete' >&2; exit 1; }
C=$(mktemp --suffix=.json)
python3 - "$D/xray.json" "$C" "$U" <<'PY'
import json,sys
src,dst,u=sys.argv[1:4]
o=json.load(open(src))
m=[x for x in o.get('inbounds',[]) if x.get('tag')=='xudp-in']
if len(m)!=1 or not m[0].get('settings',{}).get('users'): raise SystemExit('xudp-in user missing')
m[0]['settings']['users'][0]['id']=u
json.dump(o,open(dst,'w'),indent=2)
PY
"$X" run -test -c "$C" >/dev/null
install -m 0600 "$C" "$D/xray.json"; rm -f "$C"
T=$(mktemp)
python3 - "$B" "$T" "$U" <<'PY'
import json,sys
p,t,u=sys.argv[1:4]; o=json.load(open(p)); o['xudp_uuid']=u; json.dump(o,open(t,'w'),indent=2,sort_keys=True)
PY
install -m 0600 "$T" "$B"; rm -f "$T" /root/dual-live-uuid.txt
systemctl restart dual-xudp-naive.service
sleep 2
systemctl is-active --quiet dual-xudp-naive.service
REMOTE

scp "${SSH_OPTS[@]}" "root@$NEW_IP:/root/dual-naive-client.json" "$TMP_BUNDLE"
[[ $(jq -r '.xudp_uuid' "$TMP_BUNDLE") == "$LIVE_UUID" ]] || die 'Naive foreign UUID does not match live Maya UUID'

install_naive_client
USER_NAME=$(jq -r '.username' "$TMP_BUNDLE")
USER_PASS=$(jq -r '.password' "$TMP_BUNDLE")
DOMAIN=$(jq -r '.domain' "$TMP_BUNDLE")

make_cfg(){
  local out=$1 port=$2
  CFG_OUT="$out" CFG_PORT="$port" CFG_USER="$USER_NAME" CFG_PASS="$USER_PASS" CFG_DOMAIN="$DOMAIN" CFG_IP="$NEW_IP" python3 <<'PY'
import json,os
o={"listen":f"socks://127.0.0.1:{os.environ['CFG_PORT']}",
   "proxy":f"https://{os.environ['CFG_USER']}:{os.environ['CFG_PASS']}@{os.environ['CFG_DOMAIN']}",
   "host-resolver-rules":f"MAP {os.environ['CFG_DOMAIN']} {os.environ['CFG_IP']}"}
with open(os.environ['CFG_OUT'],'w') as f: json.dump(o,f,indent=2)
PY
  chmod 0600 "$out"
}

PREF=$(mktemp /root/.dual-naive-preflight.XXXXXX.json); PLOG=$(mktemp)
make_cfg "$PREF" 17993
"$BIN_DIR/naive" "$PREF" >"$PLOG" 2>&1 & NP_PID=$!
cleanup_preflight(){ kill "$NP_PID" >/dev/null 2>&1 || true; wait "$NP_PID" 2>/dev/null || true; rm -f "$PREF" "$PLOG"; }
for _ in $(seq 1 80); do
  kill -0 "$NP_PID" 2>/dev/null || { tail -n 60 "$PLOG" >&2 || true; cleanup_preflight; die 'Naive preflight client exited'; }
  ss -H -ltn 'sport = :17993' 2>/dev/null | grep -q . && break
  sleep .2
done
ss -H -ltn 'sport = :17993' 2>/dev/null | grep -q . || { cleanup_preflight; die 'Naive preflight SOCKS did not open'; }
probe_http_stable 17993 naive-preflight 8 3 || { tail -n 60 "$PLOG" >&2 || true; cleanup_preflight; die 'Naive direct preflight failed'; }
cleanup_preflight
trap cleanup_master EXIT

BK="$STATE/$(date -u +%Y%m%dT%H%M%SZ)-$OLD_KIND"
mkdir -p "$BK"; chmod 0700 "$BK"
[[ -s "$D/naive-client.json" ]] && cp -a "$D/naive-client.json" "$BK/" || true
[[ -s "$D/naive-bundle.json" ]] && cp -a "$D/naive-bundle.json" "$BK/" || true
[[ -s /etc/systemd/system/dual-naive-client.service ]] && cp -a /etc/systemd/system/dual-naive-client.service "$BK/" || true

LIVE_CFG="$D/naive-client.json"
make_cfg "$LIVE_CFG.new" 7993
install -m 0600 "$LIVE_CFG.new" "$LIVE_CFG"; rm -f "$LIVE_CFG.new"
install -m 0600 "$TMP_BUNDLE" "$D/naive-bundle.json"

cat > /etc/systemd/system/dual-naive-client.service <<EOF2
[Unit]
Description=Dual tunnel NaiveProxy HTTPS client
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$BIN_DIR/naive $LIVE_CFG
Restart=always
RestartSec=2s
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=full
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF2
systemd-analyze verify /etc/systemd/system/dual-naive-client.service >/dev/null
systemctl daemon-reload

rollback(){
  local rc=${1:-1}
  trap - ERR INT TERM
  log "ROLLBACK: restoring previous $OLD_KIND role-A carrier"
  systemctl disable --now dual-naive-client.service >/dev/null 2>&1 || true
  if [[ "$OLD_KIND" == naive ]]; then
    [[ -s "$BK/naive-client.json" ]] && cp -a "$BK/naive-client.json" "$D/naive-client.json"
    [[ -s "$BK/naive-bundle.json" ]] && cp -a "$BK/naive-bundle.json" "$D/naive-bundle.json"
    [[ -s "$BK/dual-naive-client.service" ]] && cp -a "$BK/dual-naive-client.service" /etc/systemd/system/dual-naive-client.service
    systemctl daemon-reload; systemctl enable --now dual-naive-client.service >/dev/null
  else
    systemctl start dual-trust-client.service >/dev/null
  fi
  sleep 3
  log 'Previous role-A carrier restored; Mieru, bridge, dispatcher and x-ui were untouched'
  rm -f "$TMP_BUNDLE"
  cleanup_master
  exit "$rc"
}
trap 'rollback $?' ERR; trap 'rollback 130' INT; trap 'rollback 143' TERM

if [[ "$OLD_KIND" == trust ]]; then
  log 'Cutover: stopping ONLY legacy Trust client and starting Naive on SOCKS/7993'
  systemctl stop dual-trust-client.service
else
  log 'Cutover: restarting ONLY Naive carrier on SOCKS/7993'
  systemctl stop dual-naive-client.service
fi
systemctl enable --now dual-naive-client.service >/dev/null
sleep 4
systemctl is-active --quiet dual-naive-client.service || rollback 1
ss -H -ltn 'sport = :7993' 2>/dev/null | grep -q . || rollback 1
probe_http_stable 7993 naive-direct 10 3 || rollback 1
probe_http_stable 7991 naive-tcp-path 8 2 || rollback 1
probe_telegram 7991 || rollback 1
probe_udp || rollback 1

if [[ "$OLD_KIND" == trust ]]; then
  systemctl disable dual-trust-client.service >/dev/null 2>&1 || true
  [[ -s "$D/trust-bundle.json" ]] && mv "$D/trust-bundle.json" "$D/trust-bundle.retired.json"
fi
trap - ERR INT TERM
rm -f "$TMP_BUNDLE"
cleanup_master
trap - EXIT
log 'SUCCESS: role-A migrated/replaced with Naive; direct, TCP, Telegram and UDP/XUDP checks passed'
log 'Mieru, shared Xray bridge, dispatcher and x-ui were not restarted'
log "Local rollback backup: $BK"
if [[ "$OLD_KIND" == trust ]]; then
  log "Legacy Trust foreign $OLD_IP was NOT deleted; keep it temporarily for emergency rollback"
fi
