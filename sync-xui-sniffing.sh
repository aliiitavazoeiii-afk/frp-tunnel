#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="anytls-tunnel"
CONFIG_DIR="/etc/${PROJECT}"
STATE_DIR="/var/lib/${PROJECT}"
XUI_DB="/etc/x-ui/x-ui.db"
XUI_RUNTIME="/usr/local/x-ui/bin/config.json"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f "$XUI_DB" ]] || die "x-ui DB missing: $XUI_DB"
[[ -f "$CONFIG_DIR/role" ]] || die "AnyTLS role file missing"
[[ "$(tr -d '[:space:]' < "$CONFIG_DIR/role")" == "iran" ]] || die "this command is Iran-only"
systemctl is-active --quiet anytls-tunnel || die "anytls-tunnel is not active"
systemctl is-active --quiet anytls-xudp-bridge || die "anytls-xudp-bridge is not active"

if ! systemctl is-active --quiet x-ui; then
  log "x-ui is stopped; starting it first"
  systemctl start x-ui
  sleep 3
fi
systemctl is-active --quiet x-ui || die "x-ui is not active"

log "Preflight: checking known-good AnyTLS/XUDP outbound"
python3 <<'PY'
import json
p='/usr/local/x-ui/bin/config.json'
cfg=json.load(open(p))
obs=[o for o in cfg.get('outbounds',[]) if o.get('tag')=='anytls-tunnel']
if len(obs)!=1:
    raise SystemExit(f'ERROR: expected one anytls-tunnel outbound, found {len(obs)}')
o=obs[0]
st=o.get('settings',{})
port=None
if isinstance(st.get('servers'),list) and st['servers']:
    port=st['servers'][0].get('port')
else:
    port=st.get('port')
if int(port or 0)!=7891:
    raise SystemExit(f'ERROR: anytls-tunnel is not using 7891 (got {port})')
if o.get('targetStrategy')!='ForceIPv4':
    raise SystemExit(f"ERROR: targetStrategy is {o.get('targetStrategy')!r}, expected ForceIPv4")
print('PRECHECK OK: anytls-tunnel -> 127.0.0.1:7891 targetStrategy=ForceIPv4')
PY

code=$(curl -sS --socks5-hostname 127.0.0.1:7891 --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 || true)
[[ "$code" == "204" ]] || die "XUDP TCP path unhealthy (HTTP=${code:-none})"

mkdir -p "$STATE_DIR/backups"
BACKUP_DIR="$STATE_DIR/backups/xui-sniffing-$(date -u +%Y%m%dT%H%M%SZ)"
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

log "Enabling sniffing only on the public TCP/443 inbound"
systemctl stop x-ui
XUI_DB="$XUI_DB" python3 <<'PY'
import json, os, sqlite3
p=os.environ['XUI_DB']
con=sqlite3.connect(p)
try:
    tables=[r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")]
    candidates=[]
    for t in tables:
        cols={r[1] for r in con.execute(f'PRAGMA table_info("{t}")')}
        if {'port','listen','sniffing'}.issubset(cols):
            candidates.append((t,cols))
    if not candidates:
        raise RuntimeError('could not find inbound table containing port/listen/sniffing')
    preferred=[x for x in candidates if x[0]=='inbounds']
    if preferred:
        table,cols=preferred[0]
    elif len(candidates)==1:
        table,cols=candidates[0]
    else:
        raise RuntimeError(f'ambiguous inbound tables: {[x[0] for x in candidates]}')

    select_cols=['rowid','port','listen','sniffing']
    for optional in ('id','tag','protocol','enable'):
        if optional in cols:
            select_cols.append(optional)
    rows=con.execute(f'SELECT {",".join(select_cols)} FROM "{table}" WHERE port=443').fetchall()
    names=select_cols
    items=[dict(zip(names,r)) for r in rows]
    def public(x):
        listen=str(x.get('listen') or '')
        if listen in ('127.0.0.1','::1','localhost'):
            return False
        if 'enable' in x and int(x.get('enable') or 0)!=1:
            return False
        return True
    items=[x for x in items if public(x)]
    if len(items)!=1:
        raise RuntimeError(f'expected exactly one enabled public inbound on port 443, found {len(items)}: {items}')
    item=items[0]
    raw=item.get('sniffing') or '{}'
    try:
        sniff=json.loads(raw) if isinstance(raw,str) else dict(raw)
    except Exception:
        sniff={}
    sniff['enabled']=True
    sniff['destOverride']=['http','tls','quic','fakedns']
    sniff['metadataOnly']=False
    sniff['routeOnly']=False
    new=json.dumps(sniff,separators=(',',':'))
    con.execute('BEGIN IMMEDIATE')
    con.execute(f'UPDATE "{table}" SET sniffing=? WHERE rowid=?',(new,item['rowid']))
    con.commit()
    print('DB UPDATED:', {k:item.get(k) for k in ('id','tag','protocol','listen','port') if k in item})
    print('SNIFFING:', new)
finally:
    con.close()
PY

systemctl start x-ui
sleep 4
systemctl is-active --quiet x-ui || die "x-ui inactive after sniffing update"
ss -H -ltn 'sport = :443' | grep -q . || die "public TCP/443 listener missing after sniffing update"

log "Validating runtime"
python3 <<'PY'
import json
cfg=json.load(open('/usr/local/x-ui/bin/config.json'))
ins=[]
for i in cfg.get('inbounds',[]):
    try: port=int(i.get('port',0))
    except Exception: continue
    if port!=443: continue
    if str(i.get('listen','')) in ('127.0.0.1','::1','localhost'): continue
    ins.append(i)
if len(ins)!=1:
    raise SystemExit(f'ERROR: expected one public runtime :443 inbound, found {len(ins)}')
i=ins[0]; s=i.get('sniffing') or {}
if s.get('enabled') is not True:
    raise SystemExit(f'ERROR: runtime sniffing still disabled: {s}')
expected={'http','tls','quic','fakedns'}
if not expected.issubset(set(s.get('destOverride') or [])):
    raise SystemExit(f'ERROR: runtime destOverride incomplete: {s}')
if s.get('metadataOnly') is not False or s.get('routeOnly') is not False:
    raise SystemExit(f'ERROR: runtime sniffing flags differ from known-good state: {s}')
print('RUNTIME OK:', i.get('tag'), 'sniffing=', json.dumps(s,separators=(',',':')))

obs=[o for o in cfg.get('outbounds',[]) if o.get('tag')=='anytls-tunnel']
if len(obs)!=1 or obs[0].get('targetStrategy')!='ForceIPv4':
    raise SystemExit('ERROR: known-good anytls-tunnel outbound changed unexpectedly')
print('OUTBOUND OK: anytls-tunnel targetStrategy=ForceIPv4')
PY

trap - EXIT
log "SUCCESS: x-ui public :443 sniffing matches known-good Google/YouTube state"
log "Disconnect the client completely, force-close NPV Tunnel, reconnect, then test Google and YouTube."
