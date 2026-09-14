#!/usr/bin/env bash
set -Eeuo pipefail

XUI_DB="/etc/x-ui/x-ui.db"
XUI_RUNTIME="/usr/local/x-ui/bin/config.json"
STATE_DIR="/var/lib/anytls-tunnel/backups"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f "$XUI_DB" ]] || die "x-ui DB missing"
command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 missing"

systemctl is-active --quiet anytls-tunnel || die "anytls-tunnel inactive"
systemctl is-active --quiet anytls-xudp-bridge || die "anytls-xudp-bridge inactive"
ss -H -ltn 'sport = :7891' | grep -q . || die "XUDP SOCKS 7891 is not listening"

# Verify the already-proven XUDP carrier before touching x-ui.
code=$(curl -sS --socks5-hostname 127.0.0.1:7891 --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
[[ "$code" == "204" ]] || die "XUDP path unhealthy (HTTP=${code:-none})"

mkdir -p "$STATE_DIR"
B="$STATE_DIR/xui-working-state-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$B"
cp -a "$XUI_DB" "$B/x-ui.db"
log "Backup: $B/x-ui.db"

restore(){
  systemctl stop x-ui >/dev/null 2>&1 || true
  cp -a "$B/x-ui.db" "$XUI_DB"
  systemctl start x-ui >/dev/null 2>&1 || true
}
trap 'rc=$?; if (( rc != 0 )); then log "ERROR: restoring x-ui DB"; restore; fi' EXIT

systemctl stop x-ui
XUI_DB="$XUI_DB" python3 <<'PY'
import json, os, sqlite3
p=os.environ['XUI_DB']
con=sqlite3.connect(p)
try:
    con.execute('BEGIN IMMEDIATE')
    row=con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if not row:
        raise RuntimeError('xrayTemplateConfig not found')
    cfg=json.loads(row[0])
    matches=[o for o in cfg.get('outbounds',[]) if o.get('tag')=='anytls-tunnel']
    if len(matches)!=1:
        raise RuntimeError(f'expected exactly one anytls-tunnel outbound, found {len(matches)}')
    o=matches[0]
    if o.get('protocol')!='socks':
        raise RuntimeError('anytls-tunnel is not SOCKS')
    st=o.setdefault('settings',{})
    if isinstance(st.get('servers'),list) and st['servers']:
        st['servers'][0]['address']='127.0.0.1'
        st['servers'][0]['port']=7891
        st['servers'][0].setdefault('users',[])
    else:
        st.clear(); st.update({'servers':[{'address':'127.0.0.1','port':7891,'users':[]}]})
    # Match the known-good production server.
    o['targetStrategy']='ForceIPv4'
    o['mux']={'enabled':False}
    con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'",
                (json.dumps(cfg,separators=(',',':')),))
    con.commit()
finally:
    con.close()
PY

systemctl start x-ui
sleep 4
systemctl is-active --quiet x-ui || die "x-ui inactive after patch"
ss -H -ltn 'sport = :443' | grep -q . || die "public TCP/443 missing"

python3 <<'PY'
import json
p='/usr/local/x-ui/bin/config.json'
cfg=json.load(open(p))
obs=[o for o in cfg.get('outbounds',[]) if o.get('tag')=='anytls-tunnel']
if len(obs)!=1: raise SystemExit(f'expected one anytls-tunnel outbound, found {len(obs)}')
o=obs[0]
st=o.get('settings',{})
port=None
if isinstance(st.get('servers'),list) and st['servers']:
    port=st['servers'][0].get('port')
else:
    port=st.get('port')
if int(port or 0)!=7891: raise SystemExit(f'wrong port {port}')
if o.get('targetStrategy')!='ForceIPv4': raise SystemExit(f'wrong targetStrategy {o.get("targetStrategy")}')
print('RUNTIME OK: anytls-tunnel -> 127.0.0.1:7891 targetStrategy=ForceIPv4')

ins=[]
for i in cfg.get('inbounds',[]):
    try: port=int(i.get('port',0))
    except Exception: continue
    if port==443 and str(i.get('listen','')) not in ('127.0.0.1','::1','localhost'):
        ins.append(i)
print('PUBLIC 443 INBOUND STATE:')
for i in ins:
    print(json.dumps({'tag':i.get('tag'),'protocol':i.get('protocol'),'listen':i.get('listen'),'sniffing':i.get('sniffing')},ensure_ascii=False))
PY

trap - EXIT
log "SUCCESS: x-ui AnyTLS outbound synced to known-good ForceIPv4 state"
log "Reconnect the client completely, then test Google and YouTube."
