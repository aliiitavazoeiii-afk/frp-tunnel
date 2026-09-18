#!/usr/bin/env bash
set -Eeuo pipefail
B=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT=dual-trust-mieru
XUI_DB=/etc/x-ui/x-ui.db
XUI_RUNTIME=/usr/local/x-ui/bin/config.json
XUI_BIN=/usr/local/x-ui/x-ui
PROBE="$B/dual-probe.sh"
STATE=/var/lib/$PROJECT
ENTRY=7990
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
[[ -f "$XUI_DB" && -f "$XUI_RUNTIME" && -x "$XUI_BIN" ]] || die "x-ui DB/runtime/binary missing"
[[ -x "$PROBE" ]] || die "repo dual-probe.sh missing or not executable"
systemctl is-active --quiet x-ui || die "x-ui inactive"
for s in dual-trust-client dual-mieru-carrier dual-xudp-bridge dual-dispatcher; do
  systemctl is-active --quiet "$s" || die "$s inactive"
done
ss -H -ltn 'sport = :7990' 2>/dev/null | grep -q . || die "dual entry SOCKS/7990 missing"

XUI_VERSION=$($XUI_BIN -v 2>&1 || true)
XUI_VERSION=${XUI_VERSION%%$'\n'*}
XUI_VERSION=${XUI_VERSION//$'\r'/}
[[ -n "$XUI_VERSION" ]] || die "could not determine x-ui version"
log "Detected x-ui version: $XUI_VERSION"

log "Full dual-path precheck before touching x-ui"
"$PROBE" --full

INBOUND_TAG=$(python3 <<'PY'
import json
cfg=json.load(open('/usr/local/x-ui/bin/config.json'))
xs=[]
for i in cfg.get('inbounds',[]):
    try: p=int(i.get('port',0))
    except Exception: continue
    if p==443 and str(i.get('listen','')) not in ('127.0.0.1','::1','localhost') and i.get('tag'):
        xs.append(i)
if len(xs)!=1: raise SystemExit(f'expected exactly one public :443 inbound, found {len(xs)}')
print(xs[0]['tag'])
PY
) || die "could not uniquely discover public :443 inbound"
log "Public x-ui inbound: $INBOUND_TAG"

mkdir -p "$STATE/backups"
BK="$STATE/backups/xui-attach-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BK"; chmod 0700 "$BK"
cp -a "$XUI_DB" "$BK/x-ui.db"
log "Backup: $BK/x-ui.db"

restore(){
  set +e
  log "ROLLBACK: restoring x-ui DB"
  systemctl stop x-ui >/dev/null 2>&1 || true
  cp -a "$BK/x-ui.db" "$XUI_DB"
  systemctl start x-ui >/dev/null 2>&1 || true
}
trap 'rc=$?; if ((rc!=0)); then restore; fi' EXIT

systemctl stop x-ui
XUI_DB="$XUI_DB" INBOUND_TAG="$INBOUND_TAG" ENTRY="$ENTRY" XUI_VERSION="$XUI_VERSION" python3 <<'PY'
import json, os, sqlite3
p=os.environ['XUI_DB']
tag=os.environ['INBOUND_TAG']
port=int(os.environ['ENTRY'])
version=os.environ['XUI_VERSION'].strip()

DEFAULT_294 = {
  "log": {"access":"none","dnsLog":False,"error":"","loglevel":"warning","maskAddress":""},
  "api": {"tag":"api","services":["HandlerService","LoggerService","StatsService"]},
  "inbounds": [
    {"tag":"api","listen":"127.0.0.1","port":62789,"protocol":"tunnel","settings":{"address":"127.0.0.1"}}
  ],
  "outbounds": [
    {"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"AsIs","redirect":"","noises":[]}},
    {"tag":"blocked","protocol":"blackhole","settings":{}}
  ],
  "policy": {
    "levels":{"0":{"statsUserDownlink":True,"statsUserUplink":True}},
    "system":{"statsInboundDownlink":True,"statsInboundUplink":True,"statsOutboundDownlink":False,"statsOutboundUplink":False}
  },
  "routing": {
    "domainStrategy":"AsIs",
    "rules":[
      {"type":"field","inboundTag":["api"],"outboundTag":"api"},
      {"type":"field","outboundTag":"blocked","ip":["geoip:private"]},
      {"type":"field","outboundTag":"blocked","protocol":["bittorrent"]}
    ]
  },
  "stats":{},
  "metrics":{"tag":"metrics_out","listen":"127.0.0.1:11111"}
}

con=sqlite3.connect(p)
try:
    con.execute('BEGIN IMMEDIATE')
    row=con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    seeded=False
    if row:
        cfg=json.loads(row[0])
    else:
        if version != '2.9.4':
            raise RuntimeError(f'xrayTemplateConfig missing; safe default seeding is only pinned for x-ui 2.9.4, found {version!r}')
        cfg=json.loads(json.dumps(DEFAULT_294))
        seeded=True

    obs=cfg.setdefault('outbounds',[])
    matches=[o for o in obs if o.get('tag')=='dual-tunnel']
    if len(matches)>1:
        raise RuntimeError('multiple dual-tunnel outbounds found')
    desired={
      'tag':'dual-tunnel','protocol':'socks','targetStrategy':'AsIs',
      'settings':{'servers':[{'address':'127.0.0.1','port':port,'users':[]}]},
      'mux':{'enabled':False}
    }
    if matches:
        matches[0].clear(); matches[0].update(desired)
    else:
        obs.append(desired)

    routing=cfg.setdefault('routing',{})
    rules=routing.setdefault('rules',[])
    rules=[r for r in rules if r.get('outboundTag')!='dual-tunnel']
    api_idx=None
    for idx,r in enumerate(rules):
        tags=r.get('inboundTag') or []
        if isinstance(tags,str): tags=[tags]
        if r.get('outboundTag')=='api' and 'api' in tags:
            api_idx=idx
            break
    if api_idx is None:
        raise RuntimeError('x-ui template has no api -> api routing rule; refusing unsafe attach')
    api_rule=rules.pop(api_idx)
    dual_rule={'type':'field','inboundTag':[tag],'outboundTag':'dual-tunnel'}
    routing['rules']=[api_rule,dual_rule] + rules

    payload=json.dumps(cfg,separators=(',',':'))
    if row:
        con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'",(payload,))
    else:
        con.execute("INSERT INTO settings(key,value) VALUES(?,?)",('xrayTemplateConfig',payload))

    tables=[r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")]
    candidates=[]
    for t in tables:
        cols={r[1] for r in con.execute(f'PRAGMA table_info("{t}")')}
        if {'port','listen','sniffing'}.issubset(cols): candidates.append((t,cols))
    preferred=[x for x in candidates if x[0]=='inbounds']
    if preferred: table,cols=preferred[0]
    elif len(candidates)==1: table,cols=candidates[0]
    else: raise RuntimeError(f'could not uniquely locate inbound table: {[x[0] for x in candidates]}')
    cols_to=['rowid','port','listen','sniffing']+[x for x in ('enable','tag','protocol') if x in cols]
    rows=[dict(zip(cols_to,r)) for r in con.execute(f'SELECT {",".join(cols_to)} FROM "{table}" WHERE port=443')]
    def public(x):
        if str(x.get('listen') or '') in ('127.0.0.1','::1','localhost'): return False
        if 'enable' in x and int(x.get('enable') or 0)!=1: return False
        return True
    rows=[x for x in rows if public(x)]
    if len(rows)!=1: raise RuntimeError(f'expected one DB public :443 inbound, got {len(rows)}')
    item=rows[0]
    try: sniff=json.loads(item.get('sniffing') or '{}')
    except Exception: sniff={}
    sniff.update({'enabled':True,'destOverride':['http','tls','quic','fakedns'],'metadataOnly':False,'routeOnly':False})
    con.execute(f'UPDATE "{table}" SET sniffing=? WHERE rowid=?',(json.dumps(sniff,separators=(',',':')),item['rowid']))
    con.commit()
    if seeded:
        print('SEEDED: xrayTemplateConfig from official x-ui 2.9.4 embedded default')
finally:
    con.close()
PY

systemctl start x-ui
sleep 4
systemctl is-active --quiet x-ui || die "x-ui inactive after attach"
ss -H -ltn 'sport = :443' 2>/dev/null | grep -q . || die "public x-ui TCP/443 missing"

INBOUND_TAG="$INBOUND_TAG" python3 <<'PY'
import json,os
cfg=json.load(open('/usr/local/x-ui/bin/config.json')); tag=os.environ['INBOUND_TAG']
obs=[o for o in cfg.get('outbounds',[]) if o.get('tag')=='dual-tunnel']
if len(obs)!=1: raise SystemExit(f'expected one dual-tunnel outbound, found {len(obs)}')
o=obs[0]; sv=o.get('settings',{}).get('servers') or []
if not sv or sv[0].get('address')!='127.0.0.1' or int(sv[0].get('port',0))!=7990: raise SystemExit('runtime dual-tunnel SOCKS target wrong')
if o.get('targetStrategy')!='AsIs': raise SystemExit('runtime targetStrategy is not AsIs')
rules=cfg.get('routing',{}).get('rules',[])
if not rules: raise SystemExit('runtime routing rules missing')
api_tags=rules[0].get('inboundTag') or []
if isinstance(api_tags,str): api_tags=[api_tags]
if rules[0].get('outboundTag')!='api' or 'api' not in api_tags:
    raise SystemExit('runtime api -> api route is not first')
if not any(r.get('outboundTag')=='dual-tunnel' and tag in (r.get('inboundTag') or []) for r in rules): raise SystemExit('runtime dual-tunnel route missing')
ins=[]
for i in cfg.get('inbounds',[]):
    try:p=int(i.get('port',0))
    except:continue
    if p==443 and str(i.get('listen','')) not in ('127.0.0.1','::1','localhost'): ins.append(i)
if len(ins)!=1: raise SystemExit('runtime public :443 inbound ambiguous')
s=ins[0].get('sniffing') or {}
if s.get('enabled') is not True or not {'http','tls'}.issubset(set(s.get('destOverride') or [])): raise SystemExit(f'runtime sniffing invalid: {s}')
print('RUNTIME OK: api route preserved; public :443 -> dual-tunnel -> 127.0.0.1:7990; sniffing ON; targetStrategy=AsIs')
PY

ROLLBACK=/usr/local/sbin/dual-tunnel-xui-rollback
cat > "$ROLLBACK" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \${EUID:-\$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
systemctl stop x-ui
cp -a '$BK/x-ui.db' '$XUI_DB'
systemctl start x-ui
sleep 3
systemctl is-active --quiet x-ui
echo 'SUCCESS: x-ui DB restored from $BK/x-ui.db'
EOF2
chmod 0700 "$ROLLBACK"

trap - EXIT
log "SUCCESS: x-ui attached to dual Trust/Mieru entry"
log "Rollback DB retained at $BK/x-ui.db"
log "Rollback command: sudo $ROLLBACK"
