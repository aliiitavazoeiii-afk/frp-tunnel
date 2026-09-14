#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="anytls-tunnel"
CONFIG_DIR="/etc/${PROJECT}"
STATE_DIR="/var/lib/${PROJECT}"
XUI_DB="/etc/x-ui/x-ui.db"
XUI_RUNTIME="/usr/local/x-ui/bin/config.json"
XUDP_PORT="${XUDP_SOCKS_PORT:-7891}"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f "$XUI_DB" ]] || die "x-ui DB missing: $XUI_DB"
[[ -f "$CONFIG_DIR/role" ]] || die "AnyTLS role file missing"
[[ "$(tr -d '[:space:]' < "$CONFIG_DIR/role")" == "iran" ]] || die "this repair is Iran-only"
systemctl is-active --quiet anytls-tunnel || die "anytls-tunnel is not active"
systemctl is-active --quiet anytls-xudp-bridge || die "anytls-xudp-bridge is not active"
ss -H -ltn "sport = :${XUDP_PORT}" | grep -q . || die "XUDP SOCKS ${XUDP_PORT} is not listening"

# A failed older installer could leave x-ui stopped before its DB transaction committed.
if ! systemctl is-active --quiet x-ui; then
  log "x-ui is stopped; starting it before runtime discovery"
  systemctl start x-ui
  sleep 3
fi
systemctl is-active --quiet x-ui || die "x-ui could not be started"
[[ -f "$XUI_RUNTIME" ]] || die "x-ui runtime config missing: $XUI_RUNTIME"

log "Verifying XUDP TCP path before touching x-ui"
code=$(curl -sS --socks5-hostname "127.0.0.1:${XUDP_PORT}" --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
[[ "$code" == "204" ]] || die "XUDP TCP path is not healthy (HTTP=${code:-none})"

log "Verifying XUDP UDP round-trip before touching x-ui"
XUDP_PORT="$XUDP_PORT" python3 <<'PY'
import os, random, socket, struct, sys
host='127.0.0.1'; port=int(os.environ['XUDP_PORT'])
def recvn(s,n):
    b=b''
    while len(b)<n:
        x=s.recv(n-len(b))
        if not x: raise RuntimeError('SOCKS TCP closed')
        b+=x
    return b
s=socket.create_connection((host,port),timeout=5)
s.sendall(b'\x05\x01\x00')
if recvn(s,2)!=b'\x05\x00': raise RuntimeError('SOCKS auth failed')
s.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
_,rep,_,atyp=recvn(s,4)
if rep: raise RuntimeError(f'UDP ASSOCIATE reply={rep}')
if atyp==1: relay=socket.inet_ntoa(recvn(s,4))
elif atyp==3: relay=recvn(s,recvn(s,1)[0]).decode()
elif atyp==4: relay=socket.inet_ntop(socket.AF_INET6,recvn(s,16))
else: raise RuntimeError('bad relay ATYP')
rport=struct.unpack('!H',recvn(s,2))[0]
if relay in ('0.0.0.0','::'): relay=host
qid=random.randrange(65536)
qname=b''.join(bytes([len(x)])+x.encode() for x in 'youtube.com'.split('.'))+b'\0'
dns=struct.pack('!HHHHHH',qid,0x0100,1,0,0,0)+qname+struct.pack('!HH',1,1)
pkt=b'\0\0\0\1'+socket.inet_aton('1.1.1.1')+struct.pack('!H',53)+dns
u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.settimeout(8); u.sendto(pkt,(relay,rport))
try: data,_=u.recvfrom(65535)
except socket.timeout:
    print('UDP XUDP REPAIR TEST = FAIL (timeout)'); sys.exit(2)
pos=4; ratyp=data[3]
if ratyp==1: pos+=4
elif ratyp==3: pos+=1+data[pos]
elif ratyp==4: pos+=16
else: sys.exit(2)
pos+=2; reply=data[pos:]
if len(reply)<12: sys.exit(2)
rid,flags=struct.unpack('!HH',reply[:4])
if rid!=qid or not(flags & 0x8000): sys.exit(2)
print('UDP XUDP REPAIR TEST = OK')
PY

INBOUND_TAG=$(python3 <<'PY'
import json
p='/usr/local/x-ui/bin/config.json'
cfg=json.load(open(p))
cs=[]
for i in cfg.get('inbounds',[]):
    try: port=int(i.get('port',0))
    except Exception: continue
    if port!=443: continue
    listen=str(i.get('listen',''))
    if listen in ('127.0.0.1','::1','localhost'): continue
    tag=i.get('tag')
    if tag: cs.append((tag,i.get('protocol','?'),listen))
if len(cs)!=1:
    raise SystemExit('ERROR: expected exactly one public inbound on TCP/443, found %d: %r' % (len(cs),cs))
print(cs[0][0])
PY
) || die "could not uniquely discover public x-ui inbound on port 443"
log "Detected public x-ui inbound tag: ${INBOUND_TAG}"

mkdir -p "$STATE_DIR/backups"
BACKUP_DIR="$STATE_DIR/backups/xui-bootstrap-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP_DIR"
cp -a "$XUI_DB" "$BACKUP_DIR/x-ui.db"
log "x-ui DB backup: $BACKUP_DIR/x-ui.db"

restore(){
  log "Restoring previous x-ui DB"
  systemctl stop x-ui >/dev/null 2>&1 || true
  cp -a "$BACKUP_DIR/x-ui.db" "$XUI_DB"
  systemctl start x-ui >/dev/null 2>&1 || true
}
trap 'rc=$?; if (( rc != 0 )); then restore; fi' EXIT

log "Creating/updating anytls-tunnel outbound and routing rule"
systemctl stop x-ui
XUI_DB="$XUI_DB" INBOUND_TAG="$INBOUND_TAG" XUDP_PORT="$XUDP_PORT" python3 <<'PY'
import json, os, sqlite3
p=os.environ['XUI_DB']; tag=os.environ['INBOUND_TAG']; port=int(os.environ['XUDP_PORT'])
con=sqlite3.connect(p)
try:
    con.execute('BEGIN IMMEDIATE')
    row=con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if not row: raise RuntimeError('xrayTemplateConfig not found')
    cfg=json.loads(row[0])
    obs=cfg.setdefault('outbounds',[])
    matches=[o for o in obs if o.get('tag')=='anytls-tunnel']
    if len(matches)>1: raise RuntimeError(f'multiple anytls-tunnel outbounds found: {len(matches)}')
    desired={
      'tag':'anytls-tunnel',
      'protocol':'socks',
      'targetStrategy':'AsIs',
      'settings':{'servers':[{'address':'127.0.0.1','port':port,'users':[]}]},
      'mux':{'enabled':False}
    }
    if matches:
        o=matches[0]
        o.clear(); o.update(desired)
    else:
        obs.append(desired)

    routing=cfg.setdefault('routing',{})
    rules=routing.setdefault('rules',[])
    # Remove stale/duplicate rules targeting this outbound, then make the public
    # 443 inbound route explicit and first so old XHTTP rules cannot capture it.
    rules[:]=[r for r in rules if r.get('outboundTag')!='anytls-tunnel']
    rules.insert(0,{'type':'field','inboundTag':[tag],'outboundTag':'anytls-tunnel'})

    con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'",
                (json.dumps(cfg,separators=(',',':')),))
    con.commit()
finally:
    con.close()
PY

systemctl start x-ui
sleep 4
systemctl is-active --quiet x-ui || die "x-ui inactive after bootstrap"
ss -H -ltn 'sport = :443' | grep -q . || die "public TCP/443 listener missing after bootstrap"

INBOUND_TAG="$INBOUND_TAG" XUDP_PORT="$XUDP_PORT" python3 <<'PY'
import json, os
cfg=json.load(open('/usr/local/x-ui/bin/config.json'))
tag=os.environ['INBOUND_TAG']; port=int(os.environ['XUDP_PORT'])
obs=[o for o in cfg.get('outbounds',[]) if o.get('tag')=='anytls-tunnel']
if len(obs)!=1: raise SystemExit(f'expected one runtime anytls-tunnel outbound, found {len(obs)}')
o=obs[0]
st=o.get('settings',{})
p=None
if isinstance(st.get('servers'),list) and st['servers']:
    p=st['servers'][0].get('port')
else:
    p=st.get('port')
if int(p or 0)!=port: raise SystemExit(f'wrong runtime SOCKS port: {p}')
rules=cfg.get('routing',{}).get('rules',[])
ok=any(r.get('outboundTag')=='anytls-tunnel' and tag in (r.get('inboundTag') or []) for r in rules)
if not ok: raise SystemExit('runtime routing rule to anytls-tunnel is missing')
print(f'RUNTIME OK: {tag} -> anytls-tunnel -> 127.0.0.1:{port}')
PY

trap - EXIT
log "SUCCESS: fresh x-ui bootstrapped for AnyTLS/XUDP"
log "Route: ${INBOUND_TAG} -> anytls-tunnel -> 127.0.0.1:${XUDP_PORT}"
