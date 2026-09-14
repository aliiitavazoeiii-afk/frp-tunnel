#!/usr/bin/env bash
set -Eeuo pipefail

XUI_DB="/etc/x-ui/x-ui.db"
XUI_RUNTIME="/usr/local/x-ui/bin/config.json"
STATE_DIR="/var/lib/anytls-tunnel/backups"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f "$XUI_DB" ]] || die "x-ui DB missing"

systemctl is-active --quiet anytls-tunnel || die "anytls-tunnel inactive"
systemctl is-active --quiet anytls-xudp-bridge || die "anytls-xudp-bridge inactive"
systemctl is-active --quiet x-ui || die "x-ui inactive"
ss -H -ltn 'sport = :7891' | grep -q . || die "XUDP SOCKS 7891 is not listening"

# Prove remote-name resolution over the XUDP SOCKS path before changing x-ui.
for url in https://www.gstatic.com/generate_204 https://i.ytimg.com/ https://www.instagram.com/; do
  code=$(curl -4 -sS -L --socks5-hostname 127.0.0.1:7891 --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' "$url" || true)
  [[ -n "$code" && "$code" != "000" ]] || die "remote-resolution precheck failed for $url"
done

# Sniffing must be on, otherwise an IP already resolved by the client cannot be
# recovered back to a hostname before the AsIs SOCKS hop.
python3 <<'PY'
import json
cfg=json.load(open('/usr/local/x-ui/bin/config.json'))
ins=[]
for i in cfg.get('inbounds',[]):
    try: p=int(i.get('port',0))
    except Exception: continue
    if p==443 and str(i.get('listen','')) not in ('127.0.0.1','::1','localhost'):
        ins.append(i)
if len(ins)!=1:
    raise SystemExit(f'expected exactly one public :443 inbound, found {len(ins)}')
s=ins[0].get('sniffing') or {}
if s.get('enabled') is not True:
    raise SystemExit('public :443 sniffing is not enabled; run sync-xui-sniffing.sh first')
need={'http','tls','quic','fakedns'}
have=set(s.get('destOverride') or [])
if not {'http','tls'}.issubset(have):
    raise SystemExit(f'public :443 sniffing missing http/tls: {sorted(have)}')
print(f'PRECHECK OK: sniffing enabled on {ins[0].get("tag")}')
PY

mkdir -p "$STATE_DIR"
B="$STATE_DIR/xui-remote-dns-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$B"
cp -a "$XUI_DB" "$B/x-ui.db"
log "Backup: $B/x-ui.db"

restore(){
  systemctl stop x-ui >/dev/null 2>&1 || true
  cp -a "$B/x-ui.db" "$XUI_DB"
  systemctl start x-ui >/dev/null 2>&1 || true
}
trap 'rc=$?; if (( rc != 0 )); then log "ERROR: restoring x-ui DB"; restore; fi' EXIT

log "Switching anytls-tunnel targetStrategy from local ForceIPv4 resolution to remote AsIs"
systemctl stop x-ui
XUI_DB="$XUI_DB" python3 <<'PY'
import json, os, sqlite3
p=os.environ['XUI_DB']
con=sqlite3.connect(p)
try:
    con.execute('BEGIN IMMEDIATE')
    row=con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if not row: raise RuntimeError('xrayTemplateConfig not found')
    cfg=json.loads(row[0])
    matches=[o for o in cfg.get('outbounds',[]) if o.get('tag')=='anytls-tunnel']
    if len(matches)!=1: raise RuntimeError(f'expected exactly one anytls-tunnel outbound, found {len(matches)}')
    o=matches[0]
    if o.get('protocol')!='socks': raise RuntimeError('anytls-tunnel is not SOCKS')
    st=o.setdefault('settings',{})
    if isinstance(st.get('servers'),list) and st['servers']:
        st['servers'][0]['address']='127.0.0.1'
        st['servers'][0]['port']=7891
        st['servers'][0].setdefault('users',[])
    else:
        st.clear(); st.update({'servers':[{'address':'127.0.0.1','port':7891,'users':[]}]})
    o['targetStrategy']='AsIs'
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
cfg=json.load(open('/usr/local/x-ui/bin/config.json'))
obs=[o for o in cfg.get('outbounds',[]) if o.get('tag')=='anytls-tunnel']
if len(obs)!=1: raise SystemExit(f'expected one runtime anytls-tunnel outbound, found {len(obs)}')
o=obs[0]
st=o.get('settings',{})
port=None
if isinstance(st.get('servers'),list) and st['servers']:
    port=st['servers'][0].get('port')
else:
    port=st.get('port')
if int(port or 0)!=7891: raise SystemExit(f'wrong runtime port {port}')
if o.get('targetStrategy')!='AsIs': raise SystemExit(f'wrong runtime targetStrategy {o.get("targetStrategy")}')
ins=[]
for i in cfg.get('inbounds',[]):
    try: p=int(i.get('port',0))
    except Exception: continue
    if p==443 and str(i.get('listen','')) not in ('127.0.0.1','::1','localhost'):
        ins.append(i)
if len(ins)!=1 or not (ins[0].get('sniffing') or {}).get('enabled'):
    raise SystemExit('public :443 sniffing not enabled in runtime')
print('RUNTIME OK: sniffing=ON; anytls-tunnel -> 127.0.0.1:7891 targetStrategy=AsIs')
PY

trap - EXIT
log "SUCCESS: x-ui now preserves sniffed hostnames for remote resolution through XUDP/AnyTLS"
log "Fully reconnect the client, then test YouTube, Instagram, Google, and adult-site/CDN access."
